#!/usr/bin/env bash
set -euo pipefail

NS="${ENFORCER_NS:-demo}"
SELECTOR="${ENFORCER_SELECTOR:-app=demo-app}"
DEBUG="${ENFORCER_DEBUG:-1}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}[enforcer] Starting ULTIMATE enforcer (detects both syscalls and kubectl exec)...${NC}"

# Function to check if process is a shell
is_shell() {
    case "${1##*/}" in
        sh|bash|ash|dash|zsh|ksh|tcsh|csh)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Function to delete pod
delete_pod() {
    local ns=$1
    local pod_name=$2
    echo -e "${RED}[enforcer] KILLING POD: ${ns}/${pod_name}${NC}"
    kubectl --context kind-tf-immu -n "$ns" delete pod "$pod_name" --grace-period=0 --force >/dev/null 2>&1 &
}

# Get Tetragon pod
pod=$(kubectl --context kind-tf-immu -n kube-system get pods -l app.kubernetes.io/name=tetragon -o jsonpath='{.items[0].metadata.name}')
echo -e "${GREEN}[enforcer] Connected to Tetragon pod: $pod${NC}"

# Monitor Tetragon events
kubectl --context kind-tf-immu -n kube-system logs -f "$pod" -c export-stdout --tail=0 2>/dev/null | while IFS= read -r line; do
    # Only process JSON lines
    [[ "$line" =~ ^[[:space:]]*\{ ]] || continue

    # Parse JSON
    json_parsed=$(echo "$line" | jq -r '.' 2>/dev/null) || continue

    # Extract fields
    ns=$(echo "$json_parsed" | jq -r '.process_exec.process.pod.namespace // empty' 2>/dev/null)
    pod_name=$(echo "$json_parsed" | jq -r '.process_exec.process.pod.name // empty' 2>/dev/null)
    binary=$(echo "$json_parsed" | jq -r '.process_exec.process.binary // empty' 2>/dev/null)
    args=$(echo "$json_parsed" | jq -r '.process_exec.process.arguments // [] | join(" ")' 2>/dev/null)

    # Method 1: Direct shell execution in demo namespace
    if [ "$ns" == "demo" ] && [ -n "$binary" ] && is_shell "$binary"; then
        echo -e "${RED}[enforcer] DIRECT SHELL DETECTED: ${binary} in ${ns}/${pod_name}${NC}"
        delete_pod "$ns" "$pod_name"
        continue
    fi

    # Method 2: Detect kubectl exec commands targeting demo namespace
    if [[ "$binary" == *"kubectl"* ]] && [[ "$args" == *"exec"* ]] && [[ "$args" == *"demo"* ]] && [[ "$args" == *"/bin/sh"* ]]; then
        echo -e "${YELLOW}[enforcer] KUBECTL EXEC ATTEMPT DETECTED: $args${NC}"
        
        # Extract target pod name from kubectl command
        target_pod=$(echo "$args" | grep -oP 'exec.*?-it\s+\K[^\s]+' || echo "")
        if [ -n "$target_pod" ]; then
            echo -e "${RED}[enforcer] PREEMPTIVE KILL: Stopping kubectl exec target${NC}"
            delete_pod "demo" "$target_pod"
        else
            # Kill all demo pods if we can't identify specific target
            echo -e "${RED}[enforcer] KILLING ALL DEMO PODS${NC}"
            kubectl --context kind-tf-immu -n demo delete pods -l "$SELECTOR" --grace-period=0 --force >/dev/null 2>&1 &
        fi
    fi

    if [ "$DEBUG" == "1" ] && [ -n "$ns" ]; then
        echo "[debug] ns=$ns pod=$pod_name bin=$binary"
    fi
done
