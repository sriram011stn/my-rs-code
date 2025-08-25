# ----- Config -----
NS            ?= demo
APP_LABEL     ?= app=demo-app
KIND_NAME     ?= tf-immu
KUBE_CONTEXT  ?= kind-$(KIND_NAME)

.PHONY: kubecontext init plan apply2 apply up wait-tetragon policy-all-exec down clean

# Ensure Kind cluster exists and kubectl context is set
kubecontext:
	@if ! kind get clusters | grep -qx $(KIND_NAME); then \
		echo "[make] creating Kind cluster $(KIND_NAME)"; \
		kind create cluster --name $(KIND_NAME) --config kind-config.yaml; \
	fi
	kubectl config use-context $(KUBE_CONTEXT)

# Terraform basics
init:
	terraform init

plan: kubecontext
	terraform plan

# Idempotent apply (no fragile -target): ensures cluster/context first
apply2: kubecontext
	terraform apply -auto-approve

apply:
	terraform apply -auto-approve

# Bring-up: init -> apply2 -> wait for Tetragon/CRD -> apply guaranteed policy
up: init apply2 wait-tetragon policy-all-exec
	@echo "[make] Cluster ready with guaranteed exec signal."

# Avoid race conditions
wait-tetragon:
	kubectl -n kube-system rollout status ds/tetragon --timeout=180s
	kubectl wait --for=condition=Established crd/tracingpolicies.cilium.io --timeout=180s

# Guaranteed-signal policy
policy-all-exec:
	@test -s k8s/log-all-exec.yaml || (echo "[make] ERROR: k8s/log-all-exec.yaml missing"; exit 1)
	kubectl delete tracingpolicy --all || true
	kubectl apply -f k8s/log-all-exec.yaml
	kubectl get tracingpolicies

# Teardown / reset
down:
	terraform destroy -auto-approve || true
	-kind delete cluster --name $(KIND_NAME) || true

clean: down
	@echo "[make] Cleaning Terraform state and Kind leftovers..."
	-kind delete cluster --name $(KIND_NAME) || true
	rm -rf .terraform .terraform.lock.hcl terraform.tfstate terraform.tfstate.backup
	@echo "[make] Clean complete."
