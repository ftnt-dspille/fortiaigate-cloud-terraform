#!/usr/bin/env bash
set -euo pipefail

# Upload a FAIG license file (.lic) to a running FAIG 8.0.2 instance.
#
# In 8.0.2, licensing is via the admin API (POST /api/v1/admin/licenses), NOT
# via helm chart file mounting (global.licenses is removed). The .lic file is
# uploaded as multipart form data and stored in the database.
#
# Prerequisites: setup.sh must have been run first (creates org + admin user).
#
# Usage: license.sh <license-file.lic> [vm-name]

LIC_FILE="${1:?Usage: license.sh <file.lic> [vm-name]}"
VM_NAME="${2:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/iap.sh"

if [ -z "$VM_NAME" ]; then
  VM_NAME="$(get_vm_name)"
fi
ZONE="$(get_zone "$VM_NAME")"
ADMIN_PASS="$(get_admin_pass)"

if [ ! -f "$LIC_FILE" ]; then
  echo "ERROR: License file not found: $LIC_FILE"
  exit 1
fi
if ! head -c1 "$LIC_FILE" >/dev/null 2>&1; then
  echo "ERROR: cannot read $LIC_FILE (an OneDrive online-only file? Always Keep on This Device)"
  exit 1
fi

LIC_BASENAME=$(basename "$LIC_FILE")
echo "License file: $LIC_BASENAME"
echo "VM: $VM_NAME"

echo "=== Starting IAP SSH tunnel to $VM_NAME ==="
iap_start_ssh "$VM_NAME" "$ZONE"
trap iap_cleanup EXIT

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Start HTTP port-forward through the SSH tunnel
HTTP_PORT="${HTTP_PORT:-8080}"
echo "=== Starting HTTP port-forward (localhost:$HTTP_PORT → VM:80) ==="
ssh -p "$SSH_PORT" $SSH_OPTS -L $HTTP_PORT:localhost:80 -N -f "$SSH_TARGET" 2>/dev/null
sleep 5

API_BASE="http://localhost:$HTTP_PORT"

echo "=== Step 1: Login ==="
LOGIN_RESP=$(curl -s -c /tmp/faig_lic_cookies.txt \
  -X POST "$API_BASE/api/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"admin\",\"password\":\"$ADMIN_PASS\"}")
CSRF=$(echo "$LOGIN_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('csrf_token',''))" 2>/dev/null || echo "")
if [ -z "$CSRF" ]; then
  echo "ERROR: Login failed: $LOGIN_RESP"
  exit 1
fi
echo "Login OK"

echo "=== Step 2: Upload license via POST /api/v1/admin/licenses ==="
RESP=$(curl -sS -b /tmp/faig_lic_cookies.txt \
  -X POST "$API_BASE/api/v1/admin/licenses" \
  -H "X-CSRF-Token: $CSRF" \
  -F "files=@${LIC_FILE};type=application/octet-stream")
echo "Response: $RESP"

# Check if active
STATUS=$(echo "$RESP" | python3 -c "import sys,json; r=json.load(sys.stdin); print(r[0].get('status','') if isinstance(r,list) else r.get('error','unknown'))" 2>/dev/null || echo "error")
if echo "$STATUS" | grep -qi "active"; then
  echo "=== License is Active! ==="
elif echo "$RESP" | grep -qi "In Use\|in_use"; then
  echo "ERROR: FAIG_LICENSE_IN_USE -- serial is active on another instance. Rotate to a different .lic"
  exit 1
else
  echo "WARNING: License status: $STATUS -- may need to wait for activation"
fi

echo "=== Step 3: Verify license-manager picks it up ==="
sleep 15
gcloud compute ssh --tunnel-through-iap --zone="$ZONE" "$VM_NAME" --command='
  sudo -u ubuntu sudo k3s kubectl logs -n fortiaigate -l app=license-manager --tail=5 2>&1
' 2>&1 | grep -iE "licen|active|valid|status|NO USABLE" | tail -3

echo ""
echo "=== License upload complete ==="
echo "License: $LIC_BASENAME → $STATUS"
echo ""
echo "Next steps:"
echo "  1. Test the platform: make test"
rm -f /tmp/faig_lic_cookies.txt
