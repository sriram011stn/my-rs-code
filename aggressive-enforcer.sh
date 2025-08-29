#!/usr/bin/env bash
set -euo pipefail

NS="${ENFORCER_NS:-demo}"
SELECTOR="${ENFORCER_SELECTOR:-app=demo-app}"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo -e "${GREEN}[enforcer] Starting AGGRESSIVE enforcer (kills on ANY suspicious activity)...${NC}"

# Get the baseline processes in the demo pod
baseline_procs=""
demo_pod=$(kubectl --context kind-tf-immu -n "$NS" get pod -l "$SELECTOR" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

if [ -n "$demo_pod" ]; then
    echo "[enforcer] Getting baseline processes for $demo_pod..."
    baseline_procs=$(kubectl --context kind-tf-immu -n "$NS" exec "$demo_pod" -- ps aux 2>/dev/null | wc -l)
    echo "[enforcer] Baseline process count: $baseline_procs"
fi

# Monitor for changes
while true; do
    current_pod=$(kubectl --context kind-tf-immu -n "$NS" get pod -l "$SELECTOR" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    
    if [ -n "$current_pod" ] && [ "$current_pod" != "$demo_pod" ]; then
        echo "[enforcer] New pod detected: $current_pod"
        demo_pod="$current_pod"
        baseline_procs=$(kubectl --context kind-tf-immu -n "$NS" exec "$demo_pod" -- ps aux 2>/dev/null | wc -l || echo "0")
    fi
    
    if [ -n "$demo_pod" ]; then
        current_procs=$(kubectl --context kind-tf-immu -n "$NS" exec "$demo_pod" -- ps aux 2>/dev/null | wc -l || echo "0")
        
        if [ "$current_procs" -gt "$baseline_procs" ]; then
            echo -e "${RED}[enforcer] PROCESS COUNT INCREASED ($baseline_procs -> $current_procs) - KILLING POD${NC}"
            kubectl --context kind-tf-immu -n "$NS" delete pod "$demo_pod" --grace-period=0 --force >/dev/null 2>&1
            demo_pod=""
            baseline_procs=""
        fi
    fi
    
    sleep 1
done
