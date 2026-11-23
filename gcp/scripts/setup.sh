#!/usr/bin/env bash
set -euo pipefail

# Bootstrap a fresh FAIG 8.0.2 instance: create org + admin user via /api/v1/setup,
# then seed the Workshop Guardrail + Policy (requires a license to be uploaded first
# for guardrail/policy creation -- see license.sh).
#
# 8.0.2 API changes from 8.0.1:
#   - Guards → Guardrails  (POST /api/v1/admin/guardrails, body: {name, description, detectorIds})
#   - Flows → Policies     (POST /api/v1/admin/policies, body: {name, inputGuardrailIds, outputGuardrailIds, responseScanMode})
#   - Detectors are BUILTIN compliance policies (51 available, all NATURAL_LANGUAGE type)
#   - Licensing via API (POST /api/v1/admin/licenses), not helm file mount
#
# Usage: setup.sh [vm-name] [admin-password]
#   admin-password defaults to $FAIG_ADMIN_PASS, then the Keychain (see iap.sh)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/iap.sh"

VM_NAME="${1:-$(get_vm_name)}"
ZONE="$(get_zone "$VM_NAME")"
ADMIN_PASS="${2:-$(get_admin_pass)}"
ADMIN_EMAIL="${FAIG_ADMIN_EMAIL:-admin@example.com}"
ORG_NAME="FortiAIGate Lab"

echo "=== Starting IAP SSH tunnel to $VM_NAME ==="
iap_start_ssh "$VM_NAME" "$ZONE"
trap iap_cleanup EXIT

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Start HTTP port-forward through the SSH tunnel
echo "=== Starting HTTP port-forward (localhost:8080 → VM:80) ==="
ssh -p "$SSH_PORT" $SSH_OPTS -L 8080:localhost:80 -N -f "$SSH_TARGET" 2>/dev/null
sleep 5

API_BASE="http://localhost:8080"

# Verify tunnel
if ! curl -s -o /dev/null "$API_BASE/ui/" 2>/dev/null; then
  echo "ERROR: Cannot reach FAIG UI at $API_BASE/ui/ -- tunnel may not be ready"
  exit 1
fi
echo "HTTP tunnel OK"

echo "=== Step 1: Check setup status ==="
SETUP_STATUS=$(curl -s "$API_BASE/api/v1/setup-status")
echo "Setup status: $SETUP_STATUS"
NEEDS_SETUP=$(echo "$SETUP_STATUS" | python3 -c "import sys,json; print(json.load(sys.stdin).get('needs_setup', False))" 2>/dev/null || echo "True")

if [ "$NEEDS_SETUP" = "True" ]; then
  echo "=== Step 2: Create organization + admin user via /api/v1/setup ==="
  SETUP_RESP=$(curl -s -X POST "$API_BASE/api/v1/setup" \
    -H "Content-Type: application/json" \
    -d "{
      \"email\": \"$ADMIN_EMAIL\",
      \"username\": \"admin\",
      \"password\": \"$ADMIN_PASS\",
      \"organization_name\": \"$ORG_NAME\",
      \"externalUrl\": \"http://localhost:8080\"
    }")
  echo "Setup response: $SETUP_RESP"
  if ! echo "$SETUP_RESP" | grep -q "Setup complete"; then
    echo "ERROR: Setup failed"
    exit 1
  fi
  echo "Organization + admin user created"
else
  echo "Setup already complete -- skipping"
fi

echo "=== Step 3: Login ==="
LOGIN_RESP=$(curl -s -c /tmp/faig_cookies.txt \
  -X POST "$API_BASE/api/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"admin\",\"password\":\"$ADMIN_PASS\"}")
CSRF=$(echo "$LOGIN_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('csrf_token',''))" 2>/dev/null || echo "")
if [ -z "$CSRF" ]; then
  echo "ERROR: Login failed: $LOGIN_RESP"
  exit 1
fi
echo "Login OK"

echo "=== Step 4: Check license status ==="
LICENSE_LOG=$(gcloud compute ssh --tunnel-through-iap --zone="$ZONE" "$VM_NAME" --command='
  sudo -u ubuntu sudo k3s kubectl logs -n fortiaigate -l app=license-manager --tail=5 2>&1
' 2>&1 | grep -v WARNING | grep -v "NumPy" | grep -v "increase")
if echo "$LICENSE_LOG" | grep -q "NO USABLE LICENCE"; then
  echo "WARNING: No license uploaded -- guardrail/policy creation will fail (license check L11)"
  echo "  Upload a license first: ./scripts/license.sh <file.lic>"
  echo "  Then re-run this script to seed the guardrail/policy."
  echo ""
  echo "=== Setup complete (org + admin only) ==="
  echo "Admin user: admin"
  echo "Admin email: $ADMIN_EMAIL"
  echo "Organization: $ORG_NAME"
  rm -f /tmp/faig_cookies.txt
  exit 0
fi
echo "License is active -- proceeding to seed guardrail/policy"

# 8.0.2: Use OWASP LLM Top 10 2025 detector (BUILTIN, covers prompt injection,
# data poisoning, sensitive data exposure -- good for workshop demos)
WORKSHOP_DETECTOR="owasp-llm-top-10-2025"

echo "=== Step 5: Create Workshop Guardrail ==="
# Check if guardrail already exists
EXISTING_GR=$(curl -s -b /tmp/faig_cookies.txt "$API_BASE/api/v1/admin/guardrails" \
  | python3 -c "import sys,json; items=json.load(sys.stdin); gr=[g for g in items if g.get('name')=='Workshop Guardrail']; print(gr[0]['id'] if gr else '')" 2>/dev/null || echo "")

if [ -n "$EXISTING_GR" ]; then
  echo "Guardrail already exists: $EXISTING_GR"
  GUARDRAIL_ID="$EXISTING_GR"
else
  GR_RESP=$(curl -s -b /tmp/faig_cookies.txt \
    -X POST "$API_BASE/api/v1/admin/guardrails" \
    -H "Content-Type: application/json" \
    -H "X-CSRF-Token: $CSRF" \
    -d "{
      \"name\": \"Workshop Guardrail\",
      \"description\": \"Workshop guardrail with OWASP LLM Top 10 2025 detector\",
      \"detectorIds\": [\"$WORKSHOP_DETECTOR\"]
    }")
  GUARDRAIL_ID=$(echo "$GR_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
  if [ -n "$GUARDRAIL_ID" ]; then
    echo "Guardrail created: $GUARDRAIL_ID"
  else
    echo "ERROR: Guardrail creation failed: $GR_RESP"
    rm -f /tmp/faig_cookies.txt
    exit 1
  fi
fi

echo "=== Step 6: Create Workshop Policy ==="
# Check if policy already exists
EXISTING_POL=$(curl -s -b /tmp/faig_cookies.txt "$API_BASE/api/v1/admin/policies" \
  | python3 -c "import sys,json; items=json.load(sys.stdin); p=[x for x in items if x.get('name')=='Workshop Policy']; print(p[0]['id'] if p else '')" 2>/dev/null || echo "")

if [ -n "$EXISTING_POL" ]; then
  echo "Policy already exists: $EXISTING_POL"
  POLICY_ID="$EXISTING_POL"
else
  POL_RESP=$(curl -s -b /tmp/faig_cookies.txt \
    -X POST "$API_BASE/api/v1/admin/policies" \
    -H "Content-Type: application/json" \
    -H "X-CSRF-Token: $CSRF" \
    -d "{
      \"name\": \"Workshop Policy\",
      \"description\": \"Workshop policy bound to Workshop Guardrail\",
      \"inputGuardrailIds\": [\"$GUARDRAIL_ID\"],
      \"outputGuardrailIds\": [],
      \"responseScanMode\": \"post_stream\"
    }")
  POLICY_ID=$(echo "$POL_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null || echo "")
  if [ -n "$POLICY_ID" ]; then
    echo "Policy created: $POLICY_ID"
  else
    echo "ERROR: Policy creation failed: $POL_RESP"
    rm -f /tmp/faig_cookies.txt
    exit 1
  fi
fi

echo ""
echo "=== Setup complete ==="
echo "Admin user: admin"
echo "Organization: $ORG_NAME"
echo "Guardrail: Workshop Guardrail ($GUARDRAIL_ID)"
echo "  Detector: $WORKSHOP_DETECTOR (OWASP LLM Top 10 2025)"
echo "Policy: Workshop Policy ($POLICY_ID)"
echo "  Input slot: Workshop Guardrail"
echo "  Response scan mode: post_stream"
echo ""
echo "Next steps:"
echo "  1. Test scanning: ./scripts/test.sh"
rm -f /tmp/faig_cookies.txt
