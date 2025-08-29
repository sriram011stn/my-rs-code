#!/usr/bin/env bash
set -euo pipefail

NS="${ENFORCER_NS:-demo}"
SELECTOR="${ENFORCER_SELECTOR:-app=demo-app}"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}[enforcer] Starting IMMEDIATE enforcer${NC}"

delete_pod() {
    local pod_name=$1
    echo -e "${RED}[enforcer] IMMEDIATE KILL: ${pod_name}${NC}"
    
    kubectl --context kind-tf-immu -n "$NS" delete pod "$pod_name" --grace-period=0 --force --now &
    
    kubectl --context kind-tf-immu -n "$NS" exec "$pod_name" -- kill -9 -1 2>/dev/null &
}

tetragon_pod=$(kubectl --context kind-tf-immu -n kube-system get pods -l app.kubernetes.io/name=tetragon -o jsonpath='{.items[0].metadata.name}')
echo "[enforcer] Monitoring: $tetragon_pod"

kubectl --context kind-tf-immu -n kube-system logs -f "$tetragon_pod" -c export-stdout --tail=0 --timestamps | while read -r line; do
    if [[ "$line" =~ \{.*demo.*\} ]]; then
        echo "[debug] Demo event detected"
        if echo "$line" | grep -q '"binary":"/bin/sh"'; then
            pod_name=$(echo "$line" | jq -r '.process_exec.process.pod.name // empty' 2>/dev/null)
            echo -e "${RED}[enforcer] SHELL DETECTED: $pod_name${NC}"
            delete_pod "$pod_name"
        fi
    fi
done
