#!/usr/bin/env bash
set -euo pipefail

echo "=== 0) Sanity"
command -v kind >/dev/null || { echo "kind not installed"; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl not installed"; exit 1; }
command -v jq >/dev/null || { echo "jq not installed (sudo apt-get install -y jq)"; exit 1; }
docker ps >/dev/null || { echo "Docker not running?"; exit 1; }

echo "=== 1) Delete any old cluster"
kind delete cluster --name tf-immu || true

echo "=== 2) Create Kind cluster and set context"
kind create cluster --name tf-immu --config kind-config.yaml
kubectl config use-context kind-tf-immu
kubectl cluster-info --context kind-tf-immu

echo "=== 3) Terraform init/apply (original providers.tf, no context pin)"
terraform init -upgrade
terraform apply -auto-approve

echo "=== 4) Ensure Tetragon is ready and CRD present"
kubectl -n kube-system rollout status ds/tetragon --timeout=180s
kubectl wait --for=condition=Established crd/tracingpolicies.cilium.io --timeout=180s

echo "=== 5) (Re)apply shell policy explicitly (ok if unchanged)"
kubectl apply -f k8s/demo-deny-policy.yaml
kubectl get tracingpolicies.cilium.io -A

echo "=== 6) Verify demo resources"
kubectl -n demo get deploy,po,svc -o wide

echo "=== 7) Start enforcer (background) and show its tail"
pkill -f '^./enforcer.sh' || true
chmod +x enforcer.sh
( ./enforcer.sh ) > enforcer.out 2>&1 & disown
sleep 2
echo "---- enforcer.out (tail) ----"
tail -n 40 enforcer.out || true
echo "-----------------------------"

echo "=== 8) Trigger interactive /bin/sh (nginx has sh, not bash)"
APP=$(kubectl -n demo get pod -l app=demo-app -o jsonpath='{.items[0].metadata.name}')
echo "(pod: $APP)"
set +e
kubectl -n demo exec -it "$APP" -- /bin/sh <<'EOSH'
echo "inside shell briefly"
sleep 1
EOSH
set -e

echo "=== 9) Give enforcer a moment to delete, then show evidence"
sleep 3
echo "---- enforcer.out (tail) ----"
tail -n 100 enforcer.out || true
echo "-----------------------------"
kubectl -n demo get pods -o wide

echo "=== DONE: If you see '[enforcer] deleting demo/<pod>' and a new pod in 'kubectl get pods', you're good."
