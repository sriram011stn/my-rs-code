#!/usr/bin/env bash
set -euo pipefail

echo "Starting simple debug..."

# Get Tetragon pod
POD=$(kubectl --context kind-tf-immu -n kube-system get pods -l app.kubernetes.io/name=tetragon -o jsonpath='{.items[0].metadata.name}')
echo "Tetragon pod: $POD"

# Stream logs and filter for demo namespace
kubectl --context kind-tf-immu -n kube-system logs -f "$POD" -c export-stdout --tail=0 2>/dev/null | while IFS= read -r line; do
    # Only process lines that look like JSON (start with {)
    if [[ "$line" =~ ^[[:space:]]*\{ ]]; then
        # Check if it mentions demo namespace
        if echo "$line" | jq -e 'select(.kubernetes.namespace == "demo")' >/dev/null 2>&1; then
            echo "=== DEMO EVENT ==="
            echo "$line" | jq '.'
            echo "=================="
        elif echo "$line" | grep -q "demo" 2>/dev/null; then
            echo "=== DEMO MENTION (not kubernetes.namespace) ==="
            echo "$line" | head -c 300
            echo "..."
            echo "=================="
        fi
    fi
done
