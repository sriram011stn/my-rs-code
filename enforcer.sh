#!/usr/bin/env bash
set -euo pipefail

NS_TETRA="kube-system"
NS_PROTECT="demo"

COOLDOWN=15   # avoid duplicate deletes for the same pod quickly

command -v jq >/dev/null 2>&1 || { echo "[enforcer] install jq: sudo apt-get install -y jq"; exit 1; }

echo "[enforcer] Following Tetragon DaemonSet logs; protecting namespace: ${NS_PROTECT}"
echo "[enforcer] Cooldown per pod: ${COOLDOWN}s; acting immediately on interactive shells"

# simple de-dup cache: podName -> lastActionEpoch
declare -A LAST_ACT

# Follow all Tetragon pods via DaemonSet logs (covers multi-node)
kubectl -n "$NS_TETRA" logs -f ds/tetragon -c export-stdout --since=1s --tail=10 | \
while read -r line; do
  # Only consider execve events
  [[ "$line" == *'"flags":"execve"'* ]] || continue

  # Parse fields (best-effort)
  NS=$(echo "$line"  | jq -r '.process_exec.process.pod.namespace // empty' 2>/dev/null || true)
  POD=$(echo "$line" | jq -r '.process_exec.process.pod.name // empty'      2>/dev/null || true)
  BIN=$(echo "$line" | jq -r '.process_exec.process.binary // empty'         2>/dev/null || true)
  ARGS=$(echo "$line"| jq -r '.process_exec.process.arguments // ""'         2>/dev/null || true)

  [[ -n "$NS" && -n "$POD" && -n "$BIN" ]] || continue
  [[ "$NS" == "$NS_PROTECT" ]] || continue

  # Only act on likely interactive shells (not scripts with -c)
  case "$BIN" in
    /bin/sh|/usr/bin/sh|/bin/bash|/usr/bin/bash|/bin/ash|/usr/bin/ash|/bin/dash|/usr/bin/dash) ;;
    *) continue ;;
  esac
  if echo "$ARGS" | grep -q -- ' -c '; then
    # non-interactive shell (script/init) — ignore
    continue
  fi

  now=$(date +%s)
  last=${LAST_ACT[$POD]:-0}
  if (( now - last < COOLDOWN )); then
    # recently acted on this pod; skip duplicates
    continue
  fi
  LAST_ACT[$POD]=$now

  echo "[enforcer] Interactive shell detected -> deleting: ${NS}/${POD} (BIN=${BIN} ARGS='${ARGS}')"
  kubectl -n "$NS" delete pod "$POD" --grace-period=0 --force >/dev/null 2>&1 || true
done
