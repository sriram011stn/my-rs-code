#!/usr/bin/env bash
set -euo pipefail

NS="${ENFORCER_NS:-demo}"
SELECTOR="${ENFORCER_SELECTOR:-app=demo-app}"
DEBUG="${ENFORCER_DEBUG:-1}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}[enforcer] Starting WORKING enforcer...${NC}"

# Get Tetragon pod
pod=$(kubectl --context kind-tf-immu -n kube-system get pods -l app.kubernetes.io/name=tetragon -o jsonpath='{.items[0].metadata.name}')
echo -e "${GREEN}[enforcer] Connected to Tetragon pod: $pod${NC}"

kubectl --context kind-tf-immu -n kube-system logs -f "$pod" -c export-stdout --tail=0 2>/dev/null | while IFS= read -r line; do
    # Only process JSON lines
    [[ "$line" =~ ^[[:space:]]*\{ ]] || continue

    # Parse JSON
    json_parsed=$(echo "$line" | jq -r '.' 2>/dev/null) || continue

    # Extract fields
    ns=$(echo "$json_parsed" | jq -r '.process_exec.process.pod.namespace // empty' 2>/dev/null)
    pod_name=$(echo "$json_parsed" | jq -r '.process_exec.process.pod.name // empty' 2>/dev/null)
    binary=$(echo "$json_parsed" | jq -r '.process_exec.process.binary // empty' 2>/dev/null)
    
    # The KEY insight: kubectl exec creates a 'runc' or containerd process that we can detect
    # Look for any suspicious process execution in demo namespace that might be kubectl exec related
    if [ "$ns" == "demo" ] && [ -n "$binary" ]; then
        # Method 1: Direct shell
        case "${binary##*/}" in
            sh|bash|ash|dash|zsh|ksh|tcsh|csh)
                echo -e "${RED}[enforcer] SHELL DETECTED: ${binary} in ${ns}/${pod_name}${NC}"
                kubectl --context kind-tf-immu -n "$ns" delete pod "$pod_name" --grace-period=0 --force >/dev/null 2>&1 &
                continue
                ;;
        esac
        
        # Method 2: Look for runc/containerd exec processes (these are created by kubectl exec)
        case "${binary##*/}" in
            runc|containerd-shim*|docker-runc)
                args=$(echo "$json_parsed" | jq -r '.process_exec.process.arguments // [] | join(" ")' 2>/dev/null)
                if [[ "$args" == *"exec"* ]] || [[ "$args" == *"/bin/sh"* ]]; then
                    echo -e "${RED}[enforcer] CONTAINER RUNTIME EXEC DETECTED: ${binary} in ${ns}/${pod_name}${NC}"
                    kubectl --context kind-tf-immu -n "$ns" delete pod "$pod_name" --grace-period=0 --force >/dev/null 2>&1 &
                fi
                ;;
        esac
        
        if [ "$DEBUG" == "1" ]; then
            echo "[debug] demo event: pod=$pod_name bin=$binary"
        fi
    fi
done
