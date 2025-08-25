#!/usr/bin/env bash
set -euo pipefail
NS="demo"
SELECTOR="app=demo-app"
COOLDOWN=8
DEBUG="${ENFORCER_DEBUG:-1}"

command -v jq >/dev/null 2>&1 || { echo "[enforcer] please install jq (sudo apt-get install -y jq)"; exit 1; }
echo "[enforcer] ns=${NS}, selector=${SELECTOR}, cooldown=${COOLDOWN}s"

is_shell(){ case "${1##*/}" in sh|bash|ash|dash|zsh) return 0;; *) return 1;; esac; }

choose_stream() {
  local pod
  pod=$(kubectl -n kube-system get pods -l app.kubernetes.io/name=tetragon -o jsonpath='{.items[0].metadata.name}')
  [[ -n "$pod" ]] || { echo "[enforcer] no tetragon pod"; exit 1; }
  if kubectl -n kube-system logs "$pod" -c export-stdout --since=5s --tail=1 >/dev/null 2>&1; then
    echo "[enforcer] using export-stdout logs"
    kubectl -n kube-system logs -f ds/tetragon -c export-stdout --since=2s --tail=0
  else
    echo "[enforcer] using tetragon (agent) logs"
    kubectl -n kube-system logs -f "$pod" -c tetragon --since=2s --tail=0
  fi
}

last=0
choose_stream | while IFS= read -r line; do
  case "$line" in *process_exec*|*execve*|*kprobe_event* ) ;; *) continue ;; esac
  ns=$(echo "$line"  | jq -r '.process_exec.process.pod.namespace // .kprobe_event.pod.namespace // .k8s.namespace // empty' 2>/dev/null || true)
  pod=$(echo "$line" | jq -r '.process_exec.process.pod.name      // .kprobe_event.pod.name      // .k8s.podName  // empty' 2>/dev/null || true)
  bin=$(echo "$line" | jq -r '.process_exec.process.binary        // .process.binary              // empty'       2>/dev/null || true)
  args=$(echo "$line"| jq -r '.process_exec.process.arguments     // .process.arguments           // ""'          2>/dev/null || true)
  [[ "$DEBUG" == "1" ]] && echo "[dbg] ns=${ns:-_} pod=${pod:-_} bin=${bin:-_} args='${args}'"
  [[ -n "$bin" ]] || continue
  is_shell "$bin" || continue
  echo " $args " | grep -q ' -c ' && continue
  now=$(date +%s); (( now - last < COOLDOWN )) && { [[ "$DEBUG" == "1" ]] && echo "[dbg] cooldown"; continue; }; last=$now
  if [[ -n "$ns" && -n "$pod" && "$ns" == "$NS" ]]; then
    echo "[enforcer] deleting ${ns}/${pod}"
    kubectl -n "$ns" delete pod "$pod" --grace-period=0 --force >/dev/null 2>&1 || true
  else
    echo "[enforcer] fallback: delete by label ${NS}/${SELECTOR}"
    kubectl -n "$NS" get pods -l "$SELECTOR" -o name | xargs -r kubectl -n "$NS" delete --grace-period=0 --force >/dev/null 2>&1 || true
  fi
done
