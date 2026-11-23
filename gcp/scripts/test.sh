#!/usr/bin/env bash
set -euo pipefail

# Test FAIG 8.0.2 scanning functionality.
#
# The post-deploy check for the lab image: everything a class needs before
# the class tooling (../api) adds the students.
#
# Prerequisites:
#   - FAIG deployed from the lab image (deploy_gpu.sh)
#   - License uploaded (license.sh)
#
# This script:
#   1. Checks pod health (FAIG + the llamacpp upstream)
#   2. Checks license status
#   3. Checks GPU availability
#   4. Logs in as the org admin
#   5. Checks the local-llamacpp provider has an enabled model
#   6. Gets a completion from llama.cpp directly
#   7. Checks the public gateway route answers (401 with no key)
#
# Usage: test.sh [vm-name] [admin-password]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/iap.sh"

VM_NAME="${1:-$(get_vm_name)}"
ZONE="$(get_zone "$VM_NAME")"
ADMIN_PASS="${2:-$(get_admin_pass)}"
HTTP_PORT="${HTTP_PORT:-8080}"
API_BASE="http://localhost:$HTTP_PORT"

echo "=== Starting IAP tunnels to $VM_NAME ==="
iap_start_ssh "$VM_NAME" "$ZONE"
trap iap_cleanup EXIT

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

# Start HTTP port-forward through SSH tunnel
echo "=== Starting HTTP port-forward (localhost:$HTTP_PORT → VM:80) ==="
ssh -p "$SSH_PORT" $SSH_OPTS -L $HTTP_PORT:localhost:80 -N -f "$SSH_TARGET" 2>/dev/null
sleep 5

PASS=0
FAIL=0
check() {
  local name="$1"
  local result="$2"
  if [ "$result" = "0" ]; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name"
    FAIL=$((FAIL + 1))
  fi
}

echo ""
echo "=== 1. Pod Health ==="
# fortiaigate = the product; llamacpp = the workshop's upstream model.
PODS_OUTPUT=$(ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_TARGET" \
  "sudo -u ubuntu sudo k3s kubectl get pods -n fortiaigate --no-headers 2>&1; sudo -u ubuntu sudo k3s kubectl get pods -n llamacpp --no-headers 2>&1")
echo "$PODS_OUTPUT" | head -20
# Ready = every container up (N/N): the llamacpp pod is 2/2 with its proxy sidecar.
NOT_READY=$(echo "$PODS_OUTPUT" | grep -v "Completed" | awk '{split($2, r, "/"); if (r[1] != r[2] || $3 != "Running") print}' || true)
if [ -z "$NOT_READY" ]; then
  check "All FAIG + llamacpp pods Running" 0
else
  check "All FAIG + llamacpp pods Running" 1
  echo "  Not ready: $NOT_READY"
fi
if echo "$PODS_OUTPUT" | awk '$1 ~ /^llamacpp/ {split($2, r, "/"); if (r[1] == r[2] && $3 == "Running") ok = 1} END {exit !ok}'; then
  check "llamacpp (upstream model) is up" 0
else
  check "llamacpp (upstream model) is up" 1
fi

echo ""
echo "=== 2. License Status ==="
# --tail=200, not 5: fds update-failure WARNs (no valid_licences= on them) can
# flood the tail and make an ACTIVE licence read as missing. Judge the latest
# valid_licences= line from a wide window, like ready.sh does (--tail=1000).
LICENSE_LOG=$(ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_TARGET" \
  "sudo -u ubuntu sudo k3s kubectl logs -n fortiaigate -l app=license-manager --tail=200 2>&1")
echo "$LICENSE_LOG" | grep -i "licence\|license\|valid\|active\|NO USABLE" | tail -3
# Judge the LATEST licence line: a "NO USABLE LICENCE" from before the upload
# stays in the log after the licence is accepted.
LAST_LIC=$(echo "$LICENSE_LOG" | grep -E "valid_licences=" | tail -1)
if [ -z "$LAST_LIC" ] || echo "$LAST_LIC" | grep -qE "NO USABLE LICENCE|valid_licences=0( |$)"; then
  check "License active" 1
  echo "  WARNING: No license uploaded -- run ./scripts/license.sh <file.lic>"
else
  check "License active" 0
fi
# A licensed FAIG still passes traffic UNSCANNED while an engine pod is unreadable
# (e.g. a stale triton-server stuck in Unknown), and says so only in this log.
# license-manager runs 2 replicas and only one may have logged a scanning line:
# read both (-l), sort by timestamp, take the newest; `|| true` so an empty grep
# does not end the script under set -e/pipefail.
SCAN_STATE=$(ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_TARGET" \
  "sudo -u ubuntu sudo k3s kubectl logs -n fortiaigate -l app=license-manager --tail=500 2>/dev/null" |
  { grep -E "scanning enabled|security scanning is disabled" || true; } | sort | tail -1)
if echo "$SCAN_STATE" | grep -q "scanning enabled"; then
  check "Guardrail scanning enabled" 0
else
  check "Guardrail scanning enabled" 1
  echo "  Last state: ${SCAN_STATE:-none logged yet}"
fi

echo ""
echo "=== 3. GPU Status ==="
GPU_OUTPUT=$(ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_TARGET" "nvidia-smi --query-gpu=name,memory.total,memory.used --format=csv,noheader 2>&1")
echo "  $GPU_OUTPUT"
if echo "$GPU_OUTPUT" | grep -q "L4\|T4\|A100\|V100"; then
  check "GPU detected" 0
else
  check "GPU detected" 1
fi

echo ""
echo "=== 4. API Login ==="
LOGIN_RESP=$(curl -s -c /tmp/faig_test_cookies.txt \
  -X POST "$API_BASE/api/login" \
  -H "Content-Type: application/json" \
  -d "{\"username\":\"admin\",\"password\":\"$ADMIN_PASS\"}")
CSRF=$(echo "$LOGIN_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('csrf_token',''))" 2>/dev/null || echo "")
if [ -n "$CSRF" ]; then
  check "API login" 0
else
  check "API login" 1
  echo "  Response: $LOGIN_RESP"
fi

echo ""
echo "=== 5. Workshop provider + model ==="
PROVIDERS=$(curl -s -b /tmp/faig_test_cookies.txt "$API_BASE/api/v1/admin/ai-providers" 2>&1)
if echo "$PROVIDERS" | python3 -c "
import sys, json
p = {x['providerId']: x for x in json.load(sys.stdin)}
l = p.get('local-llamacpp')
sys.exit(0 if l and l.get('enabledModelCount', 0) >= 1 else 1)" 2>/dev/null; then
  check "Provider local-llamacpp with an enabled model" 0
else
  check "Provider local-llamacpp with an enabled model" 1
  echo "  Providers: $(echo "$PROVIDERS" | head -c 300)"
fi

echo ""
echo "=== 6. llama.cpp answers (in-cluster, no gateway) ==="
LLM_RESP=$(ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_TARGET" \
  "sudo -u ubuntu sudo k3s kubectl -n llamacpp exec deploy/llamacpp -- curl -s --max-time 60 http://localhost:8080/v1/chat/completions -H 'Content-Type: application/json' -d '{\"model\":\"llama3.2:1b\",\"messages\":[{\"role\":\"user\",\"content\":\"Say hello in one word.\"}],\"max_tokens\":10}'" 2>&1)
echo "  Response: $(echo "$LLM_RESP" | head -c 200)"
if echo "$LLM_RESP" | grep -q '"choices"'; then
  check "llama.cpp completion" 0
else
  check "llama.cpp completion" 1
fi

echo ""
echo "=== 6b. Class-outage guards (2026-11-11) ==="
# The workshop model is the one llamacpp_model.sh serves (the image ships the 1B, whose
# malformed tool calls started a class-wide outage), and the proxy turns llama.cpp's
# per-reply 500 into a 422 so one bad reply cannot open the gateway's breaker.
WANT_MODEL="$(basename "${LLAMACPP_MODEL_URL:-Qwen2.5-3B-Instruct-Q4_K_M.gguf}")"
GUARDS=$(ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_TARGET" \
  "k='sudo -u ubuntu sudo k3s kubectl -n llamacpp'; \
   echo MODEL=\$(\$k get deploy llamacpp -o jsonpath='{.spec.template.spec.containers[*].args}' | grep -o '/models/[^\"]*'); \
   echo MAP=\$(\$k get cm llamacpp-proxy -o jsonpath='{.data.nginx\\.conf}' | grep -c 'error_page 500'); \
   echo WANT=\$(\$k get cm llamacpp-proxy -o jsonpath='{.data.nginx\\.conf}' | sha256sum | cut -c1-16); \
   echo HAVE=\$(\$k get deploy llamacpp -o jsonpath='{.spec.template.metadata.annotations.faig-proxy-conf}')" 2>&1)
echo "$GUARDS" | sed 's/^/  /'
if echo "$GUARDS" | grep -q "^MODEL=/models/$WANT_MODEL"; then
  check "Workshop model is $WANT_MODEL" 0
else
  check "Workshop model is $WANT_MODEL (run llamacpp_model.sh)" 1
fi
WANT_H=$(echo "$GUARDS" | sed -n 's/^WANT=//p'); HAVE_H=$(echo "$GUARDS" | sed -n 's/^HAVE=//p')
if echo "$GUARDS" | grep -q "^MAP=[1-9]" && [ -n "$WANT_H" ] && [ "$WANT_H" = "$HAVE_H" ]; then
  check "Proxy maps llama.cpp 500 -> 422 (loaded)" 0
else
  check "Proxy maps llama.cpp 500 -> 422 (loaded; run llamacpp_proxy.sh)" 1
fi

echo ""
echo "=== 7. Public gateway is up (no key -> 401) ==="
# A student's key and guardrails are per class (make faig-class), so the image
# has none to test with; a 401 here proves the gateway route is served.
GW_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$API_BASE/ai/openai/v1/chat/completions" \
  -H "Content-Type: application/json" \
  -d '{"model":"llama3.2-1b","messages":[{"role":"user","content":"hi"}]}' 2>&1)
echo "  HTTP $GW_CODE"
if [ "$GW_CODE" = "401" ]; then
  check "Gateway /ai/openai/v1/chat/completions" 0
else
  check "Gateway /ai/openai/v1/chat/completions" 1
fi

# Only with a real cert configured (DNS name + FAIG_ACME_EMAIL): the ingress
# serves the image's self-signed fallback until cert-manager issues, and every
# check above goes through the IAP tunnel, so none of them would notice.
HOSTNAME_FQDN="$(get_hostname "$VM_NAME")"
if [ -n "$HOSTNAME_FQDN" ] && [ -n "${FAIG_ACME_EMAIL:-}" ]; then
  echo ""
  echo "=== 8. Let's Encrypt cert issued for $HOSTNAME_FQDN ==="
  # DNS-01 takes a minute or three after a deploy (record + propagation + issue).
  for _ in $(seq 1 20); do
  CERT_STATE=$(ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_TARGET" \
    "sudo k3s kubectl get certificate -A -o jsonpath='{range .items[*]}{.spec.dnsNames[0]} {.status.conditions[?(@.type==\"Ready\")].status} {.status.conditions[?(@.type==\"Ready\")].message}{\"\\n\"}{end}'" 2>/dev/null |
    grep "^$HOSTNAME_FQDN " | head -1)
  echo "$CERT_STATE" | grep -q "^$HOSTNAME_FQDN True" && break
  sleep 15
  done
  echo "  ${CERT_STATE:-no Certificate for $HOSTNAME_FQDN}"
  echo "$CERT_STATE" | grep -q "^$HOSTNAME_FQDN True"
  check "Public cert issued (cert-manager Certificate Ready)" $?
fi

echo ""
echo "==============================================="
echo "Results: $PASS passed, $FAIL failed"
echo "==============================================="

rm -f /tmp/faig_test_cookies.txt
exit $FAIL
