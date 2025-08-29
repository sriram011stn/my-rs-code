# Ensure Kind cluster exists
resource "null_resource" "kind_cluster" {
  triggers = { 
    cfg = filesha1("${path.module}/kind-config.yaml")
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
    null_resource.cluster_ready
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
    replicas = 2
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
    null_resource.cluster_ready
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
