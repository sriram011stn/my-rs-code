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
BLUE='\033[0;34m'
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

echo -e "${GREEN}[enforcer] Starting DEBUG MODE...${NC}"
echo "[enforcer] Configuration: NS=${NS}, SELECTOR=${SELECTOR}, COOLDOWN=${COOLDOWN}s"

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

# Main enforcement loop with enhanced debugging
last_action=0
event_count=0

while true; do
   # Stream logs and process them
   while IFS= read -r line; do
       event_count=$((event_count + 1))
       
       echo -e "${BLUE}[debug-$event_count] Raw line: ${line:0:200}...${NC}"

       # Try to parse as JSON first
       if ! json_parsed=$(echo "$line" | jq -r '.' 2>/dev/null); then
           echo -e "${YELLOW}[debug-$event_count] Not valid JSON, skipping${NC}"
           continue
       fi

       # Show the entire parsed JSON structure for demo namespace events
       if echo "$json_parsed" | jq -e 'select(.kubernetes.namespace == "demo" or .k8s.namespace == "demo")' >/dev/null 2>&1; then
           echo -e "${GREEN}[debug-$event_count] DEMO NAMESPACE EVENT DETECTED!${NC}"
           echo "$json_parsed" | jq '.' | head -20
           echo "..."
       fi

       # Extract all possible namespace fields and show them
       ns_fields=$(echo "$json_parsed" | jq -r '
           [
               .process_exec.process.pod.namespace // empty,
               .process_kprobe.process.pod.namespace // empty,
               .kprobe_event.pod.namespace // empty,
               .k8s.namespace // empty,
               .kubernetes.namespace // empty
           ] | map(select(. != null and . != "")) | unique | join(",")
       ' 2>/dev/null || true)

       # Extract all possible pod name fields
       pod_fields=$(echo "$json_parsed" | jq -r '
           [
               .process_exec.process.pod.name // empty,
               .process_kprobe.process.pod.name // empty,
               .kprobe_event.pod.name // empty,
               .k8s.podName // empty,
               .kubernetes.pod.name // empty
           ] | map(select(. != null and . != "")) | unique | join(",")
       ' 2>/dev/null || true)

       # Extract all possible binary fields
       bin_fields=$(echo "$json_parsed" | jq -r '
           [
               .process_exec.process.binary // empty,
               .process_kprobe.process.binary // empty,
               .process.binary // empty
           ] | map(select(. != null and . != "")) | unique | join(",")
       ' 2>/dev/null || true)

       if [ -n "$ns_fields" ] || [ -n "$pod_fields" ] || [ -n "$bin_fields" ]; then
           echo -e "${BLUE}[debug-$event_count] Fields found: ns=[$ns_fields] pod=[$pod_fields] bin=[$bin_fields]${NC}"
       fi

       # Check specifically for demo namespace and shell binaries
       if [[ "$ns_fields" == *"demo"* ]] && [[ "$bin_fields" == *"sh"* ]]; then
           echo -e "${RED}[debug-$event_count] SHELL IN DEMO DETECTED! ns=$ns_fields, bin=$bin_fields${NC}"
           
           # Try to extract the actual values using the successful path
           if [[ "$ns_fields" == *"demo"* ]]; then
               ns="demo"
               # Try different pod extraction methods
               pod=$(echo "$json_parsed" | jq -r '.kubernetes.pod.name // .k8s.podName // empty' 2>/dev/null || true)
               
               echo -e "${RED}[enforcer] VIOLATION DETECTED: Interactive shell in demo namespace, pod=$pod${NC}"
               
               if [ -n "$pod" ]; then
                   delete_pod "$ns" "$pod"
               else
                   echo "[enforcer] Pod name not found, deleting all pods matching selector: ${SELECTOR}"
                   kubectl --context kind-tf-immu -n "$NS" delete pods -l "$SELECTOR" --grace-period=0 --force >/dev/null 2>&1 || true
               fi
               
               last_action=$(date +%s)
           fi
       fi

       # Only show first 20 events to avoid spam
       if [ $event_count -ge 20 ]; then
           echo -e "${YELLOW}[debug] Switching to normal mode after 20 events...${NC}"
           break
       fi

   done < <(stream_logs || true)

   echo -e "${YELLOW}[enforcer] Log stream interrupted, reconnecting in 5 seconds...${NC}"
   sleep 5
done
