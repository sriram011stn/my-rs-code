#!/bin/bash
# save this as: setup_fixed_deployment.sh

cat > providers.tf << 'EOF'
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    kubernetes = { 
      source = "hashicorp/kubernetes"
      version = "~> 2.31" 
    }
    helm = { 
      source = "hashicorp/helm"
      version = "~> 2.13" 
    }
    null = { 
      source = "hashicorp/null"
      version = "~> 3.2" 
    }
  }
}

# Dynamic provider configuration that waits for cluster
provider "kubernetes" {
  host                   = data.external.cluster_info.result.endpoint
  cluster_ca_certificate = base64decode(data.external.cluster_info.result.ca_cert)
  client_certificate     = base64decode(data.external.cluster_info.result.client_cert)
  client_key             = base64decode(data.external.cluster_info.result.client_key)
}

provider "helm" {
  kubernetes {
    host                   = data.external.cluster_info.result.endpoint
    cluster_ca_certificate = base64decode(data.external.cluster_info.result.ca_cert)
    client_certificate     = base64decode(data.external.cluster_info.result.client_cert)
    client_key             = base64decode(data.external.cluster_info.result.client_key)
  }
}

# Data source to get cluster credentials dynamically
data "external" "cluster_info" {
  program = ["bash", "-c", <<-EOT
    set -e
    # Ensure cluster exists
    if ! kind get clusters 2>/dev/null | grep -q "tf-immu"; then
      kind create cluster --name tf-immu --config kind-config.yaml >&2
      sleep 5
    fi
    
    # Wait for cluster to be ready
    for i in {1..30}; do
      if kubectl --context kind-tf-immu cluster-info >/dev/null 2>&1; then
        break
      fi
      sleep 2
    done
    
    # Get cluster credentials
    CONTEXT="kind-tf-immu"
    CLUSTER=$(kubectl config view -o jsonpath="{.contexts[?(@.name=='$CONTEXT')].context.cluster}")
    
    kubectl config view --raw -o json | jq -c --arg ctx "$CONTEXT" '
      .contexts[] | select(.name == $ctx) as $context |
      .clusters[] | select(.name == $context.context.cluster) as $cluster |
      ."current-context" as $current |
      .users[] | select(.name == $context.context.user) as $user |
      {
        endpoint: $cluster.cluster.server,
        ca_cert: ($cluster.cluster."certificate-authority-data" // ""),
        client_cert: ($user.user."client-certificate-data" // ""),
        client_key: ($user.user."client-key-data" // "")
      }
    '
  EOT
  ]
  
  depends_on = [null_resource.kind_cluster]
}
EOF

cat > main.tf << 'EOF'
# Ensure Kind cluster exists
resource "null_resource" "kind_cluster" {
  triggers = { 
    cfg = filesha1("${path.module}/kind-config.yaml")
    timestamp = timestamp()
  }

  provisioner "local-exec" {
    command = <<EOT
#!/bin/bash
set -e
if ! kind get clusters 2>/dev/null | grep -q "tf-immu"; then
  echo "Creating Kind cluster..."
  kind create cluster --name tf-immu --config kind-config.yaml
  sleep 10
fi

# Wait for cluster to be ready
for i in {1..60}; do
  if kubectl --context kind-tf-immu get nodes >/dev/null 2>&1; then
    echo "Cluster is ready"
    break
  fi
  echo "Waiting for cluster... ($i/60)"
  sleep 2
done

kubectl config use-context kind-tf-immu
kubectl --context kind-tf-immu cluster-info
EOT
    interpreter = ["bash", "-c"]
  }

  provisioner "local-exec" {
    when    = destroy
    command = "kind delete cluster --name tf-immu || true"
  }
}

# Wait for cluster API to be fully ready
resource "null_resource" "cluster_ready" {
  depends_on = [null_resource.kind_cluster]
  
  provisioner "local-exec" {
    command = <<EOT
#!/bin/bash
set -e
for i in {1..30}; do
  if kubectl --context kind-tf-immu get ns default >/dev/null 2>&1; then
    echo "Kubernetes API is ready"
    break
  fi
  echo "Waiting for Kubernetes API... ($i/30)"
  sleep 2
done
EOT
    interpreter = ["bash", "-c"]
  }
}

# Demo namespace
resource "kubernetes_namespace" "demo" {
  metadata { 
    name = "demo" 
  }
  
  depends_on = [
    null_resource.cluster_ready,
    data.external.cluster_info
  ]
}

# Demo application deployment
resource "kubernetes_deployment" "demo_app" {
  metadata {
    name      = "demo-app"
    namespace = kubernetes_namespace.demo.metadata[0].name
    labels    = { app = "demo-app" }
  }

  spec {
    replicas = 1
    selector { 
      match_labels = { app = "demo-app" } 
    }
    
    template {
      metadata { 
        labels = { app = "demo-app" } 
      }
      
      spec {
        container {
          name  = "nginx"
          image = "nginx:stable"
          
          port {
            container_port = 80
          }
          
          # Add resource limits for stability
          resources {
            limits = {
              cpu    = "500m"
              memory = "128Mi"
            }
            requests = {
              cpu    = "100m"
              memory = "64Mi"
            }
          }
        }
      }
    }
  }

  timeouts {
    create = "2m"
    update = "2m"
  }
}

# Demo service
resource "kubernetes_service" "demo_svc" {
  metadata {
    name      = "demo-svc"
    namespace = kubernetes_namespace.demo.metadata[0].name
  }
  
  spec {
    selector = { app = "demo-app" }
    port {
      port        = 80
      target_port = 80
    }
    type = "ClusterIP"
  }
}

# Install Tetragon via Helm
resource "helm_release" "tetragon" {
  name       = "tetragon"
  repository = "https://helm.cilium.io/"
  chart      = "tetragon"
  version    = "1.1.0"
  namespace  = "kube-system"
  
  values = [file("${path.module}/helm/tetragon-values.yaml")]
  
  timeout = 300
  wait    = true
  
  depends_on = [
    null_resource.cluster_ready,
    data.external.cluster_info
  ]
}

# Wait for Tetragon to be fully ready
resource "null_resource" "tetragon_ready" {
  depends_on = [helm_release.tetragon]
  
  provisioner "local-exec" {
    command = <<EOT
#!/bin/bash
set -e
echo "Waiting for Tetragon DaemonSet..."
kubectl --context kind-tf-immu -n kube-system wait --for=condition=Ready pod -l app.kubernetes.io/name=tetragon --timeout=180s

echo "Waiting for CRDs..."
for i in {1..60}; do
  if kubectl --context kind-tf-immu get crd tracingpolicies.cilium.io >/dev/null 2>&1; then
    echo "CRDs are ready"
    break
  fi
  echo "Waiting for CRDs... ($i/60)"
  sleep 2
done

kubectl --context kind-tf-immu wait --for=condition=Established crd/tracingpolicies.cilium.io --timeout=60s
sleep 5
EOT
    interpreter = ["bash", "-c"]
  }
}

# Apply tracing policies
resource "null_resource" "apply_policies" {
  depends_on = [
    null_resource.tetragon_ready,
    kubernetes_deployment.demo_app
  ]
  
  triggers = {
    policy_hash = filesha1("${path.module}/k8s/log-all-exec.yaml")
  }
  
  provisioner "local-exec" {
    command = <<EOT
#!/bin/bash
set -e
kubectl --context kind-tf-immu delete tracingpolicy --all 2>/dev/null || true
sleep 2
kubectl --context kind-tf-immu apply -f ${path.module}/k8s/log-all-exec.yaml
kubectl --context kind-tf-immu get tracingpolicies
EOT
    interpreter = ["bash", "-c"]
  }
}

# Output status
output "cluster_status" {
  value = "Cluster 'tf-immu' is ready. Use: kubectl config use-context kind-tf-immu"
}

output "demo_app_status" {
  value = "Demo app deployed in namespace 'demo'"
}
EOF

cat > enforcer.sh << 'EOF'
#!/usr/bin/env bash
set -euo pipefail

# Configuration
NS="${ENFORCER_NS:-demo}"
SELECTOR="${ENFORCER_SELECTOR:-app=demo-app}"
COOLDOWN="${ENFORCER_COOLDOWN:-2}"
DEBUG="${ENFORCER_DEBUG:-1}"
RETRY_COUNT=3
RETRY_DELAY=2

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Check dependencies
command -v jq >/dev/null 2>&1 || { 
    echo -e "${RED}[enforcer] ERROR: jq is required. Install with: sudo apt-get install -y jq${NC}"
    exit 1
}

command -v kubectl >/dev/null 2>&1 || { 
    echo -e "${RED}[enforcer] ERROR: kubectl is required${NC}"
    exit 1
}

echo -e "${GREEN}[enforcer] Starting...${NC}"
echo "[enforcer] Configuration: NS=${NS}, SELECTOR=${SELECTOR}, COOLDOWN=${COOLDOWN}s"

# Verify cluster connectivity
if ! kubectl --context kind-tf-immu cluster-info >/dev/null 2>&1; then
    echo -e "${RED}[enforcer] ERROR: Cannot connect to cluster${NC}"
    exit 1
fi

# Check if namespace exists
if ! kubectl --context kind-tf-immu get namespace "${NS}" >/dev/null 2>&1; then
    echo -e "${RED}[enforcer] ERROR: Namespace '${NS}' does not exist${NC}"
    exit 1
fi

# Function to check if process is a shell
is_shell() {
    case "${1##*/}" in
        sh|bash|ash|dash|zsh|ksh|tcsh|csh)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Function to get Tetragon pod with retry
get_tetragon_pod() {
    local attempts=0
    local pod=""
    
    while [ $attempts -lt $RETRY_COUNT ]; do
        pod=$(kubectl --context kind-tf-immu -n kube-system get pods \
              -l app.kubernetes.io/name=tetragon \
              -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        
        if [ -n "$pod" ]; then
            echo "$pod"
            return 0
        fi
        
        attempts=$((attempts + 1))
        echo -e "${YELLOW}[enforcer] Waiting for Tetragon pod... (attempt $attempts/$RETRY_COUNT)${NC}" >&2
        sleep $RETRY_DELAY
    done
    
    echo -e "${RED}[enforcer] ERROR: No Tetragon pod found after $RETRY_COUNT attempts${NC}" >&2
    return 1
}

# Function to stream logs with automatic reconnection
stream_logs() {
    local pod
    pod=$(get_tetragon_pod) || exit 1
    
    echo -e "${GREEN}[enforcer] Connected to Tetragon pod: $pod${NC}"
    
    # Try export-stdout first, fall back to main container
    if kubectl --context kind-tf-immu -n kube-system logs "$pod" -c export-stdout --tail=1 >/dev/null 2>&1; then
        echo "[enforcer] Using export-stdout container"
        kubectl --context kind-tf-immu -n kube-system logs -f "$pod" -c export-stdout --tail=0 2>/dev/null
    else
        echo "[enforcer] Using main tetragon container"
        kubectl --context kind-tf-immu -n kube-system logs -f "$pod" -c tetragon --tail=0 2>/dev/null
    fi
}

# Function to delete pod with retry
delete_pod() {
    local ns=$1
    local pod=$2
    local attempts=0
    
    while [ $attempts -lt $RETRY_COUNT ]; do
        if kubectl --context kind-tf-immu -n "$ns" delete pod "$pod" \
           --grace-period=0 --force >/dev/null 2>&1; then
            echo -e "${GREEN}[enforcer] Successfully deleted pod: ${ns}/${pod}${NC}"
            return 0
        fi
        
        attempts=$((attempts + 1))
        if [ $attempts -lt $RETRY_COUNT ]; then
            sleep $RETRY_DELAY
        fi
    done
    
    echo -e "${YELLOW}[enforcer] Failed to delete pod after $RETRY_COUNT attempts${NC}"
    return 1
}

# Main enforcement loop with reconnection logic
last_action=0

while true; do
    # Stream logs and process them
    while IFS= read -r line; do
        # Skip non-exec events
        case "$line" in
            *process_exec*|*process_kprobe*|*execve*|*execveat*)
                ;;
            *)
                continue
                ;;
        esac
        
        # Parse the JSON event
        if ! json_parsed=$(echo "$line" | jq -r '.' 2>/dev/null); then
            [ "$DEBUG" == "1" ] && echo "[debug] Failed to parse JSON: $line"
            continue
        fi
        
        # Extract fields with multiple fallback paths
        ns=$(echo "$json_parsed" | jq -r '
            .process_exec.process.pod.namespace //
            .process_kprobe.process.pod.namespace //
            .kprobe_event.pod.namespace //
            .k8s.namespace //
            empty
        ' 2>/dev/null || true)
        
        pod=$(echo "$json_parsed" | jq -r '
            .process_exec.process.pod.name //
            .process_kprobe.process.pod.name //
            .kprobe_event.pod.name //
            .k8s.podName //
            empty
        ' 2>/dev/null || true)
        
        bin=$(echo "$json_parsed" | jq -r '
            .process_exec.process.binary //
            .process_kprobe.process.binary //
            .process.binary //
            empty
        ' 2>/dev/null || true)
        
        args=$(echo "$json_parsed" | jq -r '
            if .process_exec.process.arguments then
                .process_exec.process.arguments | join(" ")
            elif .process_kprobe.process.arguments then
                .process_kprobe.process.arguments | join(" ")
            elif .process.arguments then
                .process.arguments | join(" ")
            else
                ""
            end
        ' 2>/dev/null || true)
        
        # Debug output
        if [ "$DEBUG" == "1" ]; then
            echo "[debug] Event: ns=${ns:-_} pod=${pod:-_} bin=${bin:-_} args='${args}'"
        fi
        
        # Skip if no binary detected
        [ -z "$bin" ] && continue
        
        # Check if it's a shell execution
        is_shell "$bin" || continue
        
        # Skip shell commands with -c flag (usually legitimate)
        echo " $args " | grep -q ' -c ' && {
            [ "$DEBUG" == "1" ] && echo "[debug] Skipping shell with -c flag"
            continue
        }
        
        # Apply cooldown
        now=$(date +%s)
        if (( now - last_action < COOLDOWN )); then
            [ "$DEBUG" == "1" ] && echo "[debug] Cooldown active, skipping"
            continue
        fi
        
        # Take action
        if [ -n "$ns" ] && [ -n "$pod" ] && [ "$ns" == "$NS" ]; then
            echo -e "${RED}[enforcer] VIOLATION DETECTED: Interactive shell in ${ns}/${pod}${NC}"
            delete_pod "$ns" "$pod"
            last_action=$now
        elif [ "$ns" == "$NS" ]; then
            echo -e "${RED}[enforcer] VIOLATION DETECTED: Interactive shell in namespace ${NS} (pod name unknown)${NC}"
            echo "[enforcer] Deleting all pods matching selector: ${SELECTOR}"
            kubectl --context kind-tf-immu -n "$NS" get pods -l "$SELECTOR" -o name | \
                xargs -r -I{} kubectl --context kind-tf-immu -n "$NS" delete {} --grace-period=0 --force >/dev/null 2>&1
            last_action=$now
        fi
        
    done < <(stream_logs || true)
    
    # If we get here, the log stream was interrupted
    echo -e "${YELLOW}[enforcer] Log stream interrupted, reconnecting in 5 seconds...${NC}"
    sleep 5
done
EOF

cat > Makefile << 'EOF'
# Configuration
NS            ?= demo
APP_LABEL     ?= app=demo-app
KIND_NAME     ?= tf-immu
KUBE_CONTEXT  ?= kind-$(KIND_NAME)
TF_LOG        ?= ERROR

.PHONY: all up init apply wait-cluster wait-tetragon enforcer test-exec down clean help

# Default target
all: up

# Help target
help:
	@echo "Available targets:"
	@echo "  make up         - Full deployment (cluster + Terraform + policies)"
	@echo "  make enforcer   - Run the enforcer (blocking)"
	@echo "  make test-exec  - Test by executing shell in demo pod"
	@echo "  make down       - Destroy everything"
	@echo "  make clean      - Clean all state and clusters"

# Full deployment
up: init apply wait-tetragon
	@echo "✅ Deployment complete. Run 'make enforcer' in another terminal."

# Initialize Terraform
init:
	@echo "🔧 Initializing Terraform..."
	@terraform init -upgrade

# Apply Terraform configuration
apply: wait-cluster
	@echo "🚀 Applying Terraform configuration..."
	@TF_LOG=$(TF_LOG) terraform apply -auto-approve

# Ensure cluster exists and is ready
wait-cluster:
	@echo "⏳ Ensuring Kind cluster is ready..."
	@if ! kind get clusters 2>/dev/null | grep -q $(KIND_NAME); then \
		echo "Creating Kind cluster..."; \
		kind create cluster --name $(KIND_NAME) --config kind-config.yaml; \
	fi
	@kubectl config use-context $(KUBE_CONTEXT)
	@for i in $$(seq 1 30); do \
		if kubectl --context $(KUBE_CONTEXT) get nodes >/dev/null 2>&1; then \
			echo "✅ Cluster is ready"; \
			break; \
		fi; \
		echo "Waiting for cluster... ($$i/30)"; \
		sleep 2; \
	done

# Wait for Tetragon to be ready
wait-tetragon:
	@echo "⏳ Waiting for Tetragon..."
	@kubectl --context $(KUBE_CONTEXT) -n kube-system wait --for=condition=Ready pod -l app.kubernetes.io/name=tetragon --timeout=180s
	@kubectl --context $(KUBE_CONTEXT) wait --for=condition=Established crd/tracingpolicies.cilium.io --timeout=60s
	@echo "✅ Tetragon is ready"

# Run enforcer (blocking)
enforcer: export ENFORCER_DEBUG=1
enforcer: export ENFORCER_NS=$(NS)
enforcer: export ENFORCER_SELECTOR=$(APP_LABEL)
enforcer:
	@echo "🛡️  Starting enforcer (Ctrl+C to stop)..."
	@chmod +x enforcer.sh
	@./enforcer.sh

# Test enforcement by executing shell
test-exec:
	@echo "🧪 Testing enforcement by executing shell in demo pod..."
	@POD=$$(kubectl --context $(KUBE_CONTEXT) -n $(NS) get pod -l $(APP_LABEL) -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$POD" ]; then \
		echo "❌ No demo pod found"; \
		exit 1; \
	fi; \
	echo "Attempting to exec into $$POD (should be blocked)..."; \
	kubectl --context $(KUBE_CONTEXT) -n $(NS) exec -it "$$POD" -- /bin/sh || \
		echo "✅ Shell execution was blocked (expected behavior)"

# Check status
status:
	@echo "📊 Cluster Status:"
	@kubectl --context $(KUBE_CONTEXT) get nodes
	@echo ""
	@echo "📊 Demo Application:"
	@kubectl --context $(KUBE_CONTEXT) -n $(NS) get pods -l $(APP_LABEL)
	@echo ""
	@echo "📊 Tetragon Status:"
	@kubectl --context $(KUBE_CONTEXT) -n kube-system get pods -l app.kubernetes.io/name=tetragon
	@echo ""
	@echo "📊 Tracing Policies:"
	@kubectl --context $(KUBE_CONTEXT) get tracingpolicies

# Teardown
down:
	@echo "🔥 Destroying deployment..."
	@terraform destroy -auto-approve 2>/dev/null || true
	@kind delete cluster --name $(KIND_NAME) 2>/dev/null || true

# Complete cleanup
clean: down
	@echo "🧹 Cleaning all state..."
	@rm -rf .terraform .terraform.lock.hcl terraform.tfstate terraform.tfstate.backup
	@rm -f enforcer.out
	@echo "✅ Cleanup complete"

# Watch logs
logs-tetragon:
	@kubectl --context $(KUBE_CONTEXT) -n kube-system logs -f ds/tetragon --tail=50

logs-demo:
	@kubectl --context $(KUBE_CONTEXT) -n $(NS) logs -f -l $(APP_LABEL) --tail=50
EOF

cat > helm/tetragon-values.yaml << 'EOF'
tetragon:
  enableK8sAPIAccess: true
  logLevel: info
  
  # Enable process ancestry for better tracking
  enableProcessAncestors: true
  enableProcessNs: true
  
  # Export settings
  export:
    mode: stdout
    stdout:
      enabledCommand: true
      enabledArgs: true
    
  # Resource limits for stability
  resources:
    limits:
      cpu: 500m
      memory: 512Mi
    requests:
      cpu: 100m
      memory: 128Mi

# Export container configuration
tetragonOperator:
  enabled: true
  
export:
  enabled: true
  mode: stdout
  stdout:
    enabled: true
    enabledCommand: true
    enabledArgs: true
EOF

cat > k8s/log-all-exec.yaml << 'EOF'
apiVersion: cilium.io/v1alpha1
kind: TracingPolicy
metadata:
  name: log-all-exec
spec:
  kprobes:
  - call: "sys_execve"
    syscall: true
    args:
    - index: 0
      type: "string"
    returnArg:
      type: "int"
    selectors:
    - matchActions:
      - action: Post
  - call: "sys_execveat"
    syscall: true
    args:
    - index: 0
      type: "int"
    - index: 1
      type: "string"
    returnArg:
      type: "int"
    selectors:
    - matchActions:
      - action: Post
EOF

cat > kind-config.yaml << 'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  kubeadmConfigPatches:
  - |
    kind: InitConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        pod-infra-container-image: registry.k8s.io/pause:3.9
  - |
    kind: ClusterConfiguration
    apiServer:
      extraArgs:
        enable-admission-plugins: NodeRestriction,ResourceQuota
        audit-log-maxage: "30"
        audit-log-maxbackup: "3"
        audit-log-maxsize: "100"
- role: worker
  kubeadmConfigPatches:
  - |
    kind: JoinConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        pod-infra-container-image: registry.k8s.io/pause:3.9
- role: worker
  kubeadmConfigPatches:
  - |
    kind: JoinConfiguration
    nodeRegistration:
      kubeletExtraArgs:
        pod-infra-container-image: registry.k8s.io/pause:3.9
networking:
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
EOF

echo "✅ All files have been created. To deploy, run:"
echo "   make clean  # Clean any existing state"
echo "   make up     # Deploy everything"
echo ""
echo "Then in another terminal:"
echo "   make enforcer  # Run the enforcer"
echo ""
echo "To test:"
echo "   make test-exec  # Try to exec into pod (should be blocked)"
