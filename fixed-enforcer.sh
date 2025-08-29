#!/usr/bin/env bash
set -euo pipefail

# Configuration
NS="${ENFORCER_NS:-demo}"
SELECTOR="${ENFORCER_SELECTOR:-app=demo-app}"
COOLDOWN="${ENFORCER_COOLDOWN:-2}"
DEBUG="${ENFORCER_DEBUG:-1}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}[enforcer] Starting with FIXED JSON parsing...${NC}"
echo "[enforcer] Configuration: NS=${NS}, SELECTOR=${SELECTOR}"

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

# Get Tetragon pod
get_tetragon_pod() {
    kubectl --context kind-tf-immu -n kube-system get pods \
        -l app.kubernetes.io/name=tetragon \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null
}

# Main enforcement loop
last_action=0
event_count=0

pod=$(get_tetragon_pod)
echo -e "${GREEN}[enforcer] Connected to Tetragon pod: $pod${NC}"

kubectl --context kind-tf-immu -n kube-system logs -f "$pod" -c export-stdout --tail=0 2>/dev/null | while IFS= read -r line; do
    # Only process JSON lines
    if [[ ! "$line" =~ ^[[:space:]]*\{ ]]; then
        continue
    fi

    event_count=$((event_count + 1))
    
    # Parse JSON
    if ! json_parsed=$(echo "$line" | jq -r '.' 2>/dev/null); then
        continue
    fi

    # Extract fields using CORRECT paths from your Tetragon events
    ns=$(echo "$json_parsed" | jq -r '.process_exec.process.pod.namespace // empty' 2>/dev/null)
    pod_name=$(echo "$json_parsed" | jq -r '.process_exec.process.pod.name // empty' 2>/dev/null)  
    binary=$(echo "$json_parsed" | jq -r '.process_exec.process.binary // empty' 2>/dev/null)
    
    if [ "$DEBUG" == "1" ] && [ -n "$ns" ]; then
        echo "[debug-$event_count] Event: ns=$ns pod=$pod_name bin=$binary"
    fi

    # Check for shell execution in demo namespace
    if [ "$ns" == "demo" ] && [ -n "$binary" ] && is_shell "$binary"; then
        echo -e "${RED}[enforcer] SHELL DETECTED: ${binary} in ${ns}/${pod_name}${NC}"
        
        # Kill the pod immediately
        if [ -n "$pod_name" ]; then
            echo -e "${RED}[enforcer] KILLING POD: ${pod_name}${NC}"
            kubectl --context kind-tf-immu -n "$ns" delete pod "$pod_name" --grace-period=0 --force &
        else
            echo "[enforcer] Pod name unknown, killing all pods with selector: ${SELECTOR}"
            kubectl --context kind-tf-immu -n "$NS" delete pods -l "$SELECTOR" --grace-period=0 --force &
        fi
        
        last_action=$(date +%s)
    fi
done
