#!/usr/bin/env bash
set -euo pipefail

echo "=== 0) Sanity checks"
command -v kind >/dev/null || { echo "kind not installed"; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl not installed"; exit 1; }
command -v jq >/dev/null || { echo "jq not installed (sudo apt-get install -y jq)"; exit 1; }
docker ps >/dev/null || { echo "Docker not running?"; exit 1; }

echo "=== 1) Force providers to use kind-tf-immu"
cat > providers.tf <<'PTF'
terraform {
  required_version = ">= 1.5.0"
  required_providers {
    kubernetes = { source = "hashicorp/kubernetes", version = "~> 2.31" }
    helm       = { source = "hashicorp/helm",       version = "~> 2.13" }
    null       = { source = "hashicorp/null",       version = "~> 3.2" }
  }
}
provider "kubernetes" {
  config_path    = pathexpand("~/.kube/config")
  config_context = "kind-tf-immu"
}
provider "helm" {
  kubernetes {
    config_path    = pathexpand("~/.kube/config")
    config_context = "kind-tf-immu"
  }
}
PTF

echo "=== 2) Clean cluster"
kind delete cluster --name tf-immu || true

echo "=== 3) Terraform init/apply (this will create cluster, deploy demo-app, install Tetragon, apply policy)"
terraform init -upgrade
terraform apply -auto-approve

echo "=== 4) Point kubectl to the right context"
kubectl config use-context kind-tf-immu

echo "=== 5) Ensure Tetragon DS ready and CRD present"
kubectl -n kube-system rollout status ds/tetragon --timeout=180s
kubectl wait --for=condition=Established crd/tracingpolicies.cilium.io --timeout=180s

echo "=== 6) (Re)apply shell policy explicitly (ok if unchanged)"
kubectl apply -f k8s/demo-deny-policy.yaml
kubectl get tracingpolicies.cilium.io -A

echo "=== 7) Verify app exists in demo namespace"
kubectl -n demo get deploy,po,svc -o wide

echo "=== 8) Start enforcer (background) with fresh log"
pkill -f '^./enforcer.sh' || true
chmod +x enforcer.sh
( ./enforcer.sh ) > enforcer.out 2>&1 & disown
sleep 2
echo "---- enforcer.out (tail) ----"
tail -n 20 enforcer.out || true
echo "-----------------------------"

echo "=== 9) Confirm Tetragon is emitting exec events at all (generic)"
echo "Open a second stream for 5s to watch exec noise if any..."
timeout 5 kubectl -n kube-system logs -f ds/tetragon -c export-stdout --tail=0 | head -n 0 || true

echo "=== 10) Attempt interactive /bin/sh (not bash) — nginx has sh"
APP=$(kubectl -n demo get pod -l app=demo-app -o jsonpath='{.items[0].metadata.name}')
echo "(pod: $APP)"
set +e
kubectl -n demo exec -it "$APP" -- /bin/sh <<'EOSH'
echo "inside shell briefly"
sleep 1
EOSH
set -e

echo "=== 11) Give enforcer a moment to delete the pod"
sleep 3
echo "---- enforcer.out (tail) ----"
tail -n 50 enforcer.out || true
echo "-----------------------------"

echo "=== 12) Watch pod replacements"
kubectl -n demo get pods -o wide

echo "=== 13) If we got here and no delete happened, print focused diagnostics"
echo "--- Current context:"
kubectl config current-context
echo "--- Policies:"
kubectl get tracingpolicies.cilium.io -A
echo "--- Tetragon export-stdout last 50 lines (exec-related):"
kubectl -n kube-system logs ds/tetragon -c export-stdout --tail=200 | grep -E '"execve"|process_exec' -n || true
echo "--- Enforcer ns/selector:"
grep -E 'NS=|SELECTOR=' enforcer.sh || true
echo "=== DONE"
