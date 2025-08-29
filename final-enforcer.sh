#!/usr/bin/env bash
set -euo pipefail

NS="${ENFORCER_NS:-demo}"
SELECTOR="${ENFORCER_SELECTOR:-app=demo-app}"

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${GREEN}[enforcer] Starting FINAL enforcer - monitoring pod connectivity changes...${NC}"

# Function to delete pod
delete_pod() {
    local pod_name=$1
    echo -e "${RED}[enforcer] KILLING POD: ${NS}/${pod_name}${NC}"
    kubectl --context kind-tf-immu -n "$NS" delete pod "$pod_name" --grace-period=0 --force >/dev/null 2>&1
}

# Get initial pod
get_demo_pod() {
    kubectl --context kind-tf-immu -n "$NS" get pod -l "$SELECTOR" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo ""
}

demo_pod=$(get_demo_pod)
echo "[enforcer] Monitoring pod: $demo_pod"

# Monitor approach: Check if the pod becomes "unresponsive" to simple commands
# This indicates someone is attached via kubectl exec
while true; do
    current_pod=$(get_demo_pod)
    
    # If pod changed, update tracking
    if [ "$current_pod" != "$demo_pod" ]; then
        demo_pod="$current_pod"
        echo "[enforcer] Now monitoring: $demo_pod"
    fi
    
    if [ -n "$demo_pod" ]; then
        # Try a simple command that should always work quickly
        # If it times out, someone is likely exec'd into the pod
        if ! timeout 2 kubectl --context kind-tf-immu -n "$NS" exec "$demo_pod" -- echo "test" >/dev/null 2>&1; then
            echo -e "${BLUE}[enforcer] Pod $demo_pod appears to be in use (kubectl exec detected)${NC}"
            delete_pod "$demo_pod"
            sleep 3  # Give time for pod to be deleted and recreated
            demo_pod=""
        fi
    fi
    
    sleep 1
done
