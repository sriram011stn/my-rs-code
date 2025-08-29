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
	@echo "  make enforcer   - Run the enforcer (for blocking shell execs)"
	@echo "  make test-exec  - Test by executing shell in demo pod"
	@echo "  make down       - Destroy everything"
	@echo "  make clean      - Clean all state and clusters"

# Full deployment
up: init apply wait-tetragon
	@echo "Deployment complete. Run 'make enforcer' in another terminal."

# Initialize Terraform
init:
	@echo "Initializing Terraform..."
	@terraform init -upgrade

# Apply Terraform configuration
apply: wait-cluster
	@echo "Applying Terraform configuration..."
	@TF_LOG=$(TF_LOG) terraform apply -auto-approve

# Ensure cluster exists and is ready
wait-cluster:
	@echo "Ensuring Kind cluster is ready..."
	@if ! kind get clusters 2>/dev/null | grep -q $(KIND_NAME); then \
		echo "Creating Kind cluster..."; \
		kind create cluster --name $(KIND_NAME) --config kind-config.yaml; \
	fi
	@kubectl config use-context $(KUBE_CONTEXT)
	@for i in $$(seq 1 30); do \
		if kubectl --context $(KUBE_CONTEXT) get nodes >/dev/null 2>&1; then \
			echo "Cluster is ready"; \
			break; \
		fi; \
		echo "Waiting for cluster... ($$i/30)"; \
		sleep 2; \
	done

# Wait for Tetragon to be ready
wait-tetragon:
	@echo "Waiting for Tetragon..."
	@kubectl --context $(KUBE_CONTEXT) -n kube-system wait --for=condition=Ready pod -l app.kubernetes.io/name=tetragon --timeout=180s
	@kubectl --context $(KUBE_CONTEXT) wait --for=condition=Established crd/tracingpolicies.cilium.io --timeout=60s
	@echo "Tetragon is ready"

# Run enforcer (blocking)
enforcer: export ENFORCER_DEBUG=1
enforcer: export ENFORCER_NS=$(NS)
enforcer: export ENFORCER_SELECTOR=$(APP_LABEL)
enforcer:
	@echo "tarting enforcer (Ctrl+C to stop)..."
	@chmod +x enforcer.sh
	@./enforcer.sh

# Test enforcement by executing shell
test-exec:
	@echo "Testing enforcement by executing shell in demo pod..."
	@POD=$$(kubectl --context $(KUBE_CONTEXT) -n $(NS) get pod -l $(APP_LABEL) -o jsonpath='{.items[0].metadata.name}' 2>/dev/null); \
	if [ -z "$$POD" ]; then \
		echo "No demo pod found"; \
		exit 1; \
	fi; \
	echo "Attempting to exec into $$POD..."; \
	kubectl --context $(KUBE_CONTEXT) -n $(NS) exec -it "$$POD" -- /bin/sh || \
		echo "Shell execution was blocked"

# Check status
status:
	@echo "Cluster Status:"
	@kubectl --context $(KUBE_CONTEXT) get nodes
	@echo ""
	@echo "Demo Application:"
	@kubectl --context $(KUBE_CONTEXT) -n $(NS) get pods -l $(APP_LABEL)
	@echo ""
	@echo "Tetragon Status:"
	@kubectl --context $(KUBE_CONTEXT) -n kube-system get pods -l app.kubernetes.io/name=tetragon
	@echo ""
	@echo "Tracing Policies:"
	@kubectl --context $(KUBE_CONTEXT) get tracingpolicies

# Teardown
down:
	@echo "Destroying deployment..."
	@terraform destroy -auto-approve 2>/dev/null || true
	@kind delete cluster --name $(KIND_NAME) 2>/dev/null || true

# Complete cleanup
clean: down
	@echo "Cleaning all state..."
	@rm -rf .terraform .terraform.lock.hcl terraform.tfstate terraform.tfstate.backup
	@rm -f enforcer.out
	@echo "Cleanup complete"

# Watch logs
logs-tetragon:
	@kubectl --context $(KUBE_CONTEXT) -n kube-system logs -f ds/tetragon --tail=50

logs-demo:
	@kubectl --context $(KUBE_CONTEXT) -n $(NS) logs -f -l $(APP_LABEL) --tail=50
