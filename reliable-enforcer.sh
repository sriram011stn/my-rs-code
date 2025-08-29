#!/usr/bin/env bash
set -euo pipefail

NS="${ENFORCER_NS:-demo}"
SELECTOR="${ENFORCER_SELECTOR:-app=demo-app}"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}[enforcer] Starting RELIABLE enforcer (syscall monitoring only)${NC}"

delete_pod() {
    local pod_name=$1
    echo -e "${RED}[enforcer] KILLING POD: ${NS}/${pod_name}${NC}"
    kubectl --context kind-tf-immu -n "$NS" delete pod "$pod_name" --grace-period=0 --force
}

# Get Tetragon pod
tetragon_pod=$(kubectl --context kind-tf-immu -n kube-system get pods -l app.kubernetes.io/name=tetragon -o jsonpath='{.items[0].metadata.name}')
echo "[enforcer] Monitoring Tetragon pod: $tetragon_pod"

# Simple, direct monitoring
kubectl --context kind-tf-immu -n kube-system logs -f "$tetragon_pod" -c export-stdout --tail=0 | while IFS= read -r line; do
    # Only process JSON lines
    if [[ "$line" =~ ^[[:space:]]*\{ ]]; then
        # Extract namespace and binary directly
        if echo "$line" | jq -e '.process_exec.process.pod.namespace == "demo"' >/dev/null 2>&1; then
            binary=$(echo "$line" | jq -r '.process_exec.process.binary // empty')
            pod_name=$(echo "$line" | jq -r '.process_exec.process.pod.name // empty')
            
            echo "[debug] Demo event: pod=$pod_name binary=$binary"
            
            # Check if it's a shell
            case "${binary##*/}" in
                sh|bash|ash|dash|zsh|ksh|tcsh|csh)
                    echo -e "${RED}[enforcer] SHELL DETECTED: ${binary} in demo/${pod_name}${NC}"
                    delete_pod "$pod_name"
                    ;;
            esac
        fi
    fi
done
