#!/usr/bin/env bash
set -euo pipefail

# 0) wipe everything
echo "== Kill old enforcers =="
pkill -f enforcer.sh || true

echo "== Delete all kind clusters =="
for c in $(kind get clusters); do kind delete cluster --name "$c"; done

echo "== Clean Terraform state =="
rm -rf .terraform .terraform.lock.hcl terraform.tfstate terraform.tfstate.backup || true

# 1) recreate cluster
echo "== Create kind cluster tf-immu =="
kind create cluster --name tf-immu --config kind-config.yaml
kubectl config use-context kind-tf-immu
kubectl get nodes

# 2) ensure Helm values export JSON to stdout
mkdir -p helm
cat > helm/tetragon-values.yaml <<'YAML'
tetragon:
  enableK8sAPIAccess: true
  logLevel: info
export:
  mode: stdout
  filenames: [ "tetragon.log" ]
  stdout:
    enabledArgs: true
    enabledCommand: true
YAML

# 3) terraform deploy (ns, app, svc, tetragon)
echo "== Terraform init/apply =="
terraform init -input=false
terraform apply -auto-approve

# 4) wait for tetragon & CRD
echo "== Wait for Tetragon DS and CRD =="
kubectl -n kube-system rollout status ds/tetragon --timeout=180s
kubectl wait --for=condition=Established crd/tracingpolicies.cilium.io --timeout=180s

# 5) apply guaranteed-signal policy
echo "== Apply log-all-exec policy =="
mkdir -p k8s
cat > k8s/log-all-exec.yaml <<'YAML'
apiVersion: cilium.io/v1alpha1
kind: TracingPolicy
metadata:
  name: log-all-exec
spec:
  kprobes:
  - call: execve
    syscall: true
  - call: execveat
    syscall: true
YAML
kubectl delete tracingpolicy --all || true
kubectl apply -f k8s/log-all-exec.yaml
kubectl get tracingpolicies -A

# 6) sanity: show tetragon pods & demo pod
echo "== Components =="
kubectl -n kube-system get ds tetragon
kubectl -n kube-system get pods -l app.kubernetes.io/name=tetragon
kubectl -n demo get pods --show-labels
echo "== Reset complete =="
