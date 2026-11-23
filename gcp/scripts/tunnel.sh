#!/usr/bin/env bash
set -euo pipefail

# Start an IAP tunnel to a VM for SSH, HTTP, or HTTPS access.
# VMs have no public IPs -- all access goes through Google IAP.
#
# Usage:
#   tunnel.sh ssh           → localhost:2222 → VM:22
#   tunnel.sh http [vm]     → localhost:8080 → VM:80
#   tunnel.sh https [vm]    → localhost:8443 → VM:443
#   tunnel.sh <port> [vm]   → localhost:<port> → VM:<port>

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/iap.sh"

MODE="${1:?Usage: tunnel.sh ssh|http|https|<port> [vm-name]}"
VM_NAME="${2:-$(get_vm_name)}"
ZONE="$(get_zone "$VM_NAME")"

case "$MODE" in
  ssh)
    REMOTE=22
    LOCAL=2222
    ;;
  http)
    REMOTE=80
    LOCAL=8080
    ;;
  https)
    REMOTE=443
    LOCAL=8443
    ;;
  *)
    REMOTE="$MODE"
    LOCAL="$MODE"
    ;;
esac

echo "Starting IAP tunnel: localhost:$LOCAL → $VM_NAME:$REMOTE"
echo "Open another terminal to connect, Ctrl+C to stop."
echo ""
echo "  SSH:   ssh -p $LOCAL ubuntu@localhost"
echo "  HTTP:  http://localhost:$LOCAL"
echo "  HTTPS: https://localhost:$LOCAL"
echo ""

gcloud compute start-iap-tunnel \
  --zone="$ZONE" "$VM_NAME" "$REMOTE" \
  --local-host-port=localhost:"$LOCAL"
