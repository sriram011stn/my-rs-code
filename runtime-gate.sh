#!/usr/bin/env bash
set -euo pipefail
NS=${1:-kube-system}
POD=$(kubectl -n "$NS" get pods -l app.kubernetes.io/name=tetragon -o jsonpath='{.items[0].metadata.name}')
echo "[gate] Checking Tetragon logs (last 120s)…"
LOGS=$(kubectl -n "$NS" logs "$POD" --since=120s || true)
echo "$LOGS" | tail -n 60
if echo "$LOGS" | grep -qi '"flags":"execve"'; then
  echo "[gate] FAIL: exec events detected."
  exit 1
fi
echo "[gate] PASS: no exec events."
