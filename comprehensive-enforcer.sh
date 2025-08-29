#!/usr/bin/env bash
set -euo pipefail

NS="${ENFORCER_NS:-demo}"
SELECTOR="${ENFORCER_SELECTOR:-app=demo-app}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}[enforcer] Starting COMPREHENSIVE enforcer...${NC}"
echo "[enforcer] Monitoring: 1) Tetragon for direct shells, 2) API for exec attempts"

delete_pod() {
    local pod_name=$1
    echo -e "${RED}[enforcer] KILLING POD: ${NS}/${pod_name}${NC}"
    kubectl --context kind-tf-immu -n "$NS" delete pod "$pod_name" --grace-period=0 --force >/dev/null 2>&1 &
}

# Start Tetragon monitoring in background
(
    echo "[enforcer] Starting Tetragon syscall monitoring..."
    pod=$(kubectl --context kind-tf-immu -n kube-system get pods -l app.kubernetes.io/name=tetragon -o jsonpath='{.items[0].metadata.name}')
    kubectl --context kind-tf-immu -n kube-system logs -f "$pod" -c export-stdout --tail=0 2>/dev/null | while read -r line; do
        [[ "$line" =~ ^[[:space:]]*\{ ]] || continue
        json_parsed=$(echo "$line" | jq -r '.' 2>/dev/null) || continue
        
        ns=$(echo "$json_parsed" | jq -r '.process_exec.process.pod.namespace // empty')
        pod_name=$(echo "$json_parsed" | jq -r '.process_exec.process.pod.name // empty')
        binary=$(echo "$json_parsed" | jq -r '.process_exec.process.binary // empty')
        
        if [ "$ns" == "demo" ] && [[ "${binary##*/}" =~ ^(sh|bash|ash|dash|zsh|ksh|tcsh|csh)$ ]]; then
            echo -e "${RED}[syscall] Shell detected: ${binary} in ${pod_name}${NC}"
            delete_pod "$pod_name"
        fi
    done
) &

# Monitor for exec attempts by checking for "connection refused" or similar errors
# When someone is exec'd into a pod, new exec attempts often fail
echo "[enforcer] Starting exec attempt monitoring..."
while true; do
    demo_pod=$(kubectl --context kind-tf-immu -n "$NS" get pod -l "$SELECTOR" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -n "$demo_pod" ]; then
        # Try a simple exec - if it fails with specific errors, someone might be using the pod
        error_output=$(kubectl --context kind-tf-immu -n "$NS" exec "$demo_pod" -c nginx -- echo "test" 2>&1)
        exit_code=$?
        
        if [ $exit_code -ne 0 ]; then
            if [[ "$error_output" == *"already in use"* ]] || [[ "$error_output" == *"resource busy"* ]] || [[ "$error_output" == *"timeout"* ]]; then
                echo -e "${YELLOW}[api] Exec interference detected in ${demo_pod}${NC}"
                delete_pod "$demo_pod"
                sleep 5
            fi
        fi
    fi
    
    sleep 2
done
