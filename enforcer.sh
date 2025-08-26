#!/usr/bin/env bash
set -euo pipefail

# Configuration
NS="${ENFORCER_NS:-demo}"
SELECTOR="${ENFORCER_SELECTOR:-app=demo-app}"
COOLDOWN="${ENFORCER_COOLDOWN:-2}"
DEBUG="${ENFORCER_DEBUG:-1}"
RETRY_COUNT=3
RETRY_DELAY=2

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Check dependencies
command -v jq >/dev/null 2>&1 || { 
    echo -e "${RED}[enforcer] ERROR: jq is required. Install with: sudo apt-get install -y jq${NC}"
    exit 1
}

command -v kubectl >/dev/null 2>&1 || { 
    echo -e "${RED}[enforcer] ERROR: kubectl is required${NC}"
    exit 1
}

echo -e "${GREEN}[enforcer] Starting...${NC}"
echo "[enforcer] Configuration: NS=${NS}, SELECTOR=${SELECTOR}, COOLDOWN=${COOLDOWN}s"

# Verify cluster connectivity
if ! kubectl --context kind-tf-immu cluster-info >/dev/null 2>&1; then
    echo -e "${RED}[enforcer] ERROR: Cannot connect to cluster${NC}"
    exit 1
fi

# Check if namespace exists
if ! kubectl --context kind-tf-immu get namespace "${NS}" >/dev/null 2>&1; then
    echo -e "${RED}[enforcer] ERROR: Namespace '${NS}' does not exist${NC}"
    exit 1
fi

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

# Function to get Tetragon pod with retry
get_tetragon_pod() {
    local attempts=0
    local pod=""
    
    while [ $attempts -lt $RETRY_COUNT ]; do
        pod=$(kubectl --context kind-tf-immu -n kube-system get pods \
              -l app.kubernetes.io/name=tetragon \
              -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)
        
        if [ -n "$pod" ]; then
            echo "$pod"
            return 0
        fi
        
        attempts=$((attempts + 1))
        echo -e "${YELLOW}[enforcer] Waiting for Tetragon pod... (attempt $attempts/$RETRY_COUNT)${NC}" >&2
        sleep $RETRY_DELAY
    done
    
    echo -e "${RED}[enforcer] ERROR: No Tetragon pod found after $RETRY_COUNT attempts${NC}" >&2
    return 1
}

# Function to stream logs with automatic reconnection
stream_logs() {
    local pod
    pod=$(get_tetragon_pod) || exit 1
    
    echo -e "${GREEN}[enforcer] Connected to Tetragon pod: $pod${NC}"
    
    # Try export-stdout first, fall back to main container
    if kubectl --context kind-tf-immu -n kube-system logs "$pod" -c export-stdout --tail=1 >/dev/null 2>&1; then
        echo "[enforcer] Using export-stdout container"
        kubectl --context kind-tf-immu -n kube-system logs -f "$pod" -c export-stdout --tail=0 2>/dev/null
    else
        echo "[enforcer] Using main tetragon container"
        kubectl --context kind-tf-immu -n kube-system logs -f "$pod" -c tetragon --tail=0 2>/dev/null
    fi
}

# Function to delete pod with retry
delete_pod() {
    local ns=$1
    local pod=$2
    local attempts=0
    
    while [ $attempts -lt $RETRY_COUNT ]; do
        if kubectl --context kind-tf-immu -n "$ns" delete pod "$pod" \
           --grace-period=0 --force >/dev/null 2>&1; then
            echo -e "${GREEN}[enforcer] Successfully deleted pod: ${ns}/${pod}${NC}"
            return 0
        fi
        
        attempts=$((attempts + 1))
        if [ $attempts -lt $RETRY_COUNT ]; then
            sleep $RETRY_DELAY
        fi
    done
    
    echo -e "${YELLOW}[enforcer] Failed to delete pod after $RETRY_COUNT attempts${NC}"
    return 1
}

# Main enforcement loop with reconnection logic
last_action=0

while true; do
    # Stream logs and process them
    while IFS= read -r line; do
        # Skip non-exec events
        case "$line" in
            *process_exec*|*process_kprobe*|*execve*|*execveat*)
                ;;
            *)
                continue
                ;;
        esac
        
        # Parse the JSON event
        if ! json_parsed=$(echo "$line" | jq -r '.' 2>/dev/null); then
            [ "$DEBUG" == "1" ] && echo "[debug] Failed to parse JSON: $line"
            continue
        fi
        
        # Extract fields with multiple fallback paths
        ns=$(echo "$json_parsed" | jq -r '
            .process_exec.process.pod.namespace //
            .process_kprobe.process.pod.namespace //
            .kprobe_event.pod.namespace //
            .k8s.namespace //
            empty
        ' 2>/dev/null || true)
        
        pod=$(echo "$json_parsed" | jq -r '
            .process_exec.process.pod.name //
            .process_kprobe.process.pod.name //
            .kprobe_event.pod.name //
            .k8s.podName //
            empty
        ' 2>/dev/null || true)
        
        bin=$(echo "$json_parsed" | jq -r '
            .process_exec.process.binary //
            .process_kprobe.process.binary //
            .process.binary //
            empty
        ' 2>/dev/null || true)
        
        args=$(echo "$json_parsed" | jq -r '
            if .process_exec.process.arguments then
                .process_exec.process.arguments | join(" ")
            elif .process_kprobe.process.arguments then
                .process_kprobe.process.arguments | join(" ")
            elif .process.arguments then
                .process.arguments | join(" ")
            else
                ""
            end
        ' 2>/dev/null || true)
        
        # Debug output
        if [ "$DEBUG" == "1" ]; then
            echo "[debug] Event: ns=${ns:-_} pod=${pod:-_} bin=${bin:-_} args='${args}'"
        fi
        
        # Skip if no binary detected
        [ -z "$bin" ] && continue
        
        # Check if it's a shell execution
        is_shell "$bin" || continue
        
        # Skip shell commands with -c flag (usually legitimate)
        echo " $args " | grep -q ' -c ' && {
            [ "$DEBUG" == "1" ] && echo "[debug] Skipping shell with -c flag"
            continue
        }
        
        # Apply cooldown
        now=$(date +%s)
        if (( now - last_action < COOLDOWN )); then
            [ "$DEBUG" == "1" ] && echo "[debug] Cooldown active, skipping"
            continue
        fi
        
        # Take action
        if [ -n "$ns" ] && [ -n "$pod" ] && [ "$ns" == "$NS" ]; then
            echo -e "${RED}[enforcer] VIOLATION DETECTED: Interactive shell in ${ns}/${pod}${NC}"
            delete_pod "$ns" "$pod"
            last_action=$now
        elif [ "$ns" == "$NS" ]; then
            echo -e "${RED}[enforcer] VIOLATION DETECTED: Interactive shell in namespace ${NS} (pod name unknown)${NC}"
            echo "[enforcer] Deleting all pods matching selector: ${SELECTOR}"
            kubectl --context kind-tf-immu -n "$NS" get pods -l "$SELECTOR" -o name | \
                xargs -r -I{} kubectl --context kind-tf-immu -n "$NS" delete {} --grace-period=0 --force >/dev/null 2>&1
            last_action=$now
        fi
        
    done < <(stream_logs || true)
    
    # If we get here, the log stream was interrupted
    echo -e "${YELLOW}[enforcer] Log stream interrupted, reconnecting in 5 seconds...${NC}"
    sleep 5
done
