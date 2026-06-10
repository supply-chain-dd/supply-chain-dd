#!/usr/bin/env bash
# Validates that the sigstore-tuf-root ConfigMap in the ci namespace matches
# the live TUF mirror. Source this file and call check_tuf_root before any
# demo that relies on cosign / Fulcio / Rekor.
#
# Requires: kubectl, curl, jq, and TUF_HOST (from domains.sh).

check_tuf_root() {
    local cm_key live_key

    cm_key=$(kubectl get configmap sigstore-tuf-root -n ci \
        -o jsonpath='{.data.root\.json}' 2>/dev/null \
        | jq -r '.signed.roles.timestamp.keyids[0]' 2>/dev/null)

    live_key=$(curl -sS "http://${TUF_HOST}/root.json" 2>/dev/null \
        | jq -r '.signed.roles.timestamp.keyids[0]' 2>/dev/null)

    if [ -z "$cm_key" ] || [ "$cm_key" = "null" ] || [ -z "$live_key" ] || [ "$live_key" = "null" ]; then
        echo "ERROR: Could not fetch TUF root metadata."
        echo "  Ensure the Sigstore stack is deployed:"
        echo "    make setup-sigstore-local"
        exit 1
    fi

    if [ "$cm_key" != "$live_key" ]; then
        echo "ERROR: TUF root mismatch detected!"
        echo "  ConfigMap timestamp key: ${cm_key:0:16}..."
        echo "  Live TUF mirror key:     ${live_key:0:16}..."
        echo ""
        echo "  The sigstore-tuf-root ConfigMap is stale. Re-deploy Sigstore:"
        echo "    make setup-sigstore-local"
        exit 1
    fi

    echo "✓ TUF root ConfigMap matches live TUF mirror"
}
