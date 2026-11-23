#!/usr/bin/env bash
set -euo pipefail

# ready.sh -- bring the cloud FortiAIGate lab to "ready for class" in one shot.
#
# Idempotent: it inspects each state before acting, so re-running it converges
# and never duplicates work. Covers the whole chain an instructor needs, making
# `make up` a single operation from any state:
#
#   1. VM power   -> if the VM is stopped, hold its GPU (gpu_place.sh) and start
#                    it (start.sh also heals stale engine pods + waits for scanning).
#   1b. Deploy    -> k3s not deployed for THIS VM (fresh VM from an image)? deploy_gpu.sh.
#   1b2. GPU      -> accelerator but no NVIDIA driver? enable_gpu.sh (auto
#                    reboot-retry; a build-phase image has no driver yet).
#   1c. GPU model -> move the workshop llama.cpp onto the L4 (llamacpp_gpu.sh),
#                    front it with the keep-alive proxy and install faig-diag.
#   1e. Bootstrap -> fresh FAIG in needs_setup? setup.sh (org + admin user).
#   2. License   -> if not licensed: LICENSE=<file.lic> or the $FAIG_LICENSE_POOL pool.
#   3. Readiness  -> run test.sh's 11 checks (pods, license, GPU, API, model, outage guards,
#                    llama.cpp, gateway) as the authoritative gate.
#
# Usage: ready.sh [vm-name]
#   License: export FAIG_ADMIN_PASS or have the Keychain item faig-lab-admin, and
#            pass a .lic path with LICENSE=... if the instance is not licensed yet.
#
# ready.sh never runs terraform apply: `make up` places/creates/relocates the VM
# first, then calls this. A replaced VM (new zone or IP) is caught at 1b and
# redeployed, then relicensed at 2.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/iap.sh"

VM_NAME="${1:-$(get_vm_name)}"
ZONE="$(get_zone "$VM_NAME")"
PROJECT="$(gcloud config get-value project 2>/dev/null || true)"

echo "== ready.sh: cloud FortiAIGate -> ready for class =="
echo "  VM: $VM_NAME  zone: $ZONE  project: ${PROJECT:-?}"

# --- 1. VM power + GPU reservation -----------------------------------------
STATUS="$(gcloud compute instances describe "$VM_NAME" --zone="$ZONE" --project="$PROJECT" \
  --format='value(status)' 2>/dev/null || true)"
echo "  VM status: ${STATUS:-unknown}"

if [ "$STATUS" = "RUNNING" ]; then
  echo "  VM already running."
else
  # `make up` placed (and if need be relocated) the VM and holds its GPU already;
  # called on its own, hold in the VM's zone first -- never relocate from here.
  N="${VM_NAME##*-}"
  if ! gcloud compute reservations list --project="$PROJECT" --filter="name=${VM_NAME}-hold" \
      --format='value(name)' 2>/dev/null | grep -q .; then
    echo "  holding its GPU so the start cannot STOCKOUT..."
    ONLY="$N" FAIG_RELOCATE=0 "$SCRIPT_DIR/gpu_place.sh" >/dev/null || {
      echo "  ERROR: no GPU in $ZONE -- run 'make up INSTANCE=$N', which relocates the VM" >&2; exit 1; }
  fi
  echo "  starting VM + waiting for scanning (start.sh heals stale pods)..."
  "$SCRIPT_DIR/start.sh" "$VM_NAME"
fi

# A VM terraform just created or moved is RUNNING before sshd answers; every
# check below goes over IAP SSH, so wait for it (a no-op on a settled VM).
for i in $(seq 1 24); do
  gcloud compute ssh --tunnel-through-iap --zone="$ZONE" --project="$PROJECT" "$VM_NAME" \
    --command=true >/dev/null 2>&1 && break
  [ "$i" -eq 1 ] && echo "  waiting for SSH (a fresh VM takes a minute or two)..."
  [ "$i" -eq 24 ] && { echo "  ERROR: no SSH to $VM_NAME after 4 min" >&2; exit 1; }
  sleep 10
done

# --- 1b. Deployed on THIS VM? ------------------------------------------------
# A VM rebuilt from the image still carries the old VM's k3s node-ip; until
# deploy_gpu.sh rewrites it, nothing in the cluster serves. Cheap to check, and
# it catches a `make create` whose deploy half failed.
if gcloud compute ssh --tunnel-through-iap --zone="$ZONE" --project="$PROJECT" "$VM_NAME" \
    --command='ip=$(hostname -I | cut -d" " -f1); grep -q "node-ip: \"$ip\"" /etc/rancher/k3s/config.yaml &&
      [ -z "$(sudo k3s kubectl get nodes -o name 2>/dev/null | grep -vx "node/$(hostname)")" ]' 2>/dev/null; then
  echo "  k3s is deployed for this VM (its IP, and the only node)."
else
  echo "  k3s still has another VM's IP or node (from the image): deploying (deploy_gpu.sh)..."
  "$SCRIPT_DIR/deploy_gpu.sh" "$VM_NAME"
fi

# --- 1b2. GPU driver (first GPU boot from a build-phase image) ---------------
# deploy_gpu.sh runs helm but does NOT install the NVIDIA driver: a VM built
# from a CPU build-phase image has no driver, and every GPU pod stays Pending.
# enable_gpu.sh is idempotent (cert fix, gpu role, helm install), so run it
# whenever the VM has an accelerator and no working nvidia-smi. The driver
# install usually wants a reboot: on failure reset the VM, wait, retry once.
ACCEL="$(gcloud compute instances describe "$VM_NAME" --zone="$ZONE" --project="$PROJECT" \
  --format='value(guestAccelerators)' 2>/dev/null)"
if [ -n "$ACCEL" ] && ! gcloud compute ssh --tunnel-through-iap --zone="$ZONE" --project="$PROJECT" "$VM_NAME" \
    --command='sudo nvidia-smi -L' 2>/dev/null | grep -q GPU; then
  echo "  VM has an accelerator but no NVIDIA driver: running enable_gpu.sh..."
  if ! "$SCRIPT_DIR/enable_gpu.sh" "$VM_NAME"; then
    echo "  enable_gpu.sh failed -- resetting the VM (driver installs want a reboot) and retrying once..."
    gcloud compute instances reset "$VM_NAME" --zone="$ZONE" --project="$PROJECT" >/dev/null
    for i in $(seq 1 24); do
      gcloud compute ssh --tunnel-through-iap --zone="$ZONE" --project="$PROJECT" "$VM_NAME" \
        --command=true >/dev/null 2>&1 && break
      [ "$i" -eq 24 ] && { echo "  ERROR: no SSH after the reset" >&2; exit 1; }
      sleep 10
    done
    "$SCRIPT_DIR/enable_gpu.sh" "$VM_NAME" || { echo "  ERROR: enable_gpu.sh failed again" >&2; exit 1; }
  fi
fi

# --- 1b2. Cap vLLM's GPU share ---------------------------------------------------
# The chart's 80% leaves no room for the Qwen workshop model beside triton: vLLM then
# crash-loops and scanning stays off (see the script).
"$SCRIPT_DIR/vllm_gpu_budget.sh" "$VM_NAME"

# --- 1c. Workshop model on the GPU ---------------------------------------------
# The image ships llama.cpp on the CPU; ~8-11x faster on the L4 (see the script).
"$SCRIPT_DIR/llamacpp_gpu.sh" "$VM_NAME"

# --- 1c1. Workshop model = Qwen2.5-3B --------------------------------------------
# The image ships the 1B, which writes malformed tool calls (one started the 11-11 class
# outage). LLAMACPP_MODEL_URL picks another model (see the script).
"$SCRIPT_DIR/llamacpp_model.sh" "$VM_NAME"

# --- 1c2. llama.cpp proxy + diagnostics -----------------------------------------
# llama.cpp drops connections idle >5 s, which the gateway turned into 500s then a 503
# outage (see llamacpp_proxy.sh). faig-diag keeps the logs needed to troubleshoot.
"$SCRIPT_DIR/llamacpp_proxy.sh" "$VM_NAME"
"$SCRIPT_DIR/faig_diag_install.sh" "$VM_NAME"

# --- 1d. UI cert (trusted + matches the hostname students use) ---------------
# deploy_gpu.sh issues the cert, but it only runs at 1b when the VM CHANGED. On a
# VM that is otherwise converged, a wrong cert (e.g. a first deploy that ran
# without FAIG_ACME_EMAIL, so the UI is still serving the self-signed k3s cert)
# would never be fixed and nothing would fail -- students then hit
# ERR_CERT_AUTHORITY_INVALID. So verify it here and self-heal with issue_cert.sh.
HOSTNAME="$(get_hostname "$VM_NAME")"
if [ -n "$HOSTNAME" ]; then
  echo ""
  echo "== checking the UI cert for $HOSTNAME =="
  cert_ready() {
    gcloud compute ssh --tunnel-through-iap --zone="$ZONE" --project="$PROJECT" "$VM_NAME" \
      --command="sudo k3s kubectl get certificate -A -o json 2>/dev/null" 2>/dev/null |
      python3 -c "import sys,json
try: d=json.load(sys.stdin)
except Exception: print('notready'); sys.exit()
h='$HOSTNAME'
ok=any(h in (c.get('spec',{}).get('dnsNames') or []) and any(x.get('type')=='Ready' and x.get('status')=='True' for x in (c.get('status',{}).get('conditions') or [])) for c in d.get('items',[]))
print('ready' if ok else 'notready')"
  }
  if [ "$(cert_ready)" = "ready" ]; then
    echo "  trusted cert for $HOSTNAME is issued (cert-manager Certificate Ready)."
  elif [ -n "${FAIG_ACME_EMAIL:-}" ]; then
    echo "  no Ready cert for $HOSTNAME -- (re)issuing a Let's Encrypt cert (issue_cert.sh)..."
    "$SCRIPT_DIR/issue_cert.sh" "$VM_NAME"
    # DNS-01 lands async (TXT propagation): wait so "ready" never reports an
    # instance that still serves the untrusted cert.
    for i in $(seq 1 20); do
      [ "$(cert_ready)" = "ready" ] && { echo "  trusted cert issued."; break; }
      [ "$i" -eq 20 ] && echo "  WARNING: cert for $HOSTNAME is not Ready yet after ~5 min." \
        "Check on the VM: sudo k3s kubectl describe certificate -A | less  (DNS-01 can lag)."
      sleep 15
    done
  else
    echo "  NOTE: UI cert for $HOSTNAME is self-signed (FAIG_ACME_EMAIL unset)." \
      "Set it in gcp/.env for a trusted cert, then re-run: make up"
  fi
fi

# --- 1e. Org + admin bootstrap (a fresh FAIG starts in needs_setup) ---------
# setup.sh is idempotent: it checks /api/v1/setup-status first and no-ops when
# the org already exists. It needs the admin password (FAIG_ADMIN_PASS or the
# Keychain item); with neither, skip and say so -- the license step's error
# will point at the same fix.
if [ -n "${FAIG_ADMIN_PASS:-}" ] || command -v security >/dev/null 2>&1 && \
   security find-generic-password -s faig-lab-admin -a "${FAIG_KEYCHAIN_ACCOUNT:-faig-admin}" -w >/dev/null 2>&1; then
  echo ""
  echo "== checking FAIG bootstrap (org + admin user) =="
  "$SCRIPT_DIR/setup.sh" "$VM_NAME"
else
  echo ""
  echo "  NOTE: no FAIG admin password source (FAIG_ADMIN_PASS / Keychain faig-lab-admin):"
  echo "        skipping bootstrap -- run 'make setup' before licensing."
fi

# --- 2. License -------------------------------------------------------------
# Judge the LATEST licence line from license-manager (a stale "NO USABLE LICENCE"
# from before an upload stays in the log). Mirrors test.sh's check. The VM is up
# by here whether it was already running or this script just started it.
echo ""
echo "== checking license =="
LICENSED="unknown"
if line="$(gcloud compute ssh --tunnel-through-iap --zone="$ZONE" --project="$PROJECT" "$VM_NAME" \
    --command="sudo k3s kubectl logs -n fortiaigate -l app=license-manager --tail=1000 2>/dev/null" 2>/dev/null |
    grep -E 'valid_licences=|NO USABLE LICENCE' | sort | tail -1)"; then
  if echo "$line" | grep -qE 'NO USABLE LICENCE|valid_licences=0( |$)'; then
    LICENSED="no"
  else
    LICENSED="yes"
  fi
fi

if [ "$LICENSED" = "yes" ]; then
  echo "  license active."
elif [ -n "${LICENSE:-}" ]; then
  echo "  license missing; uploading $LICENSE ..."
  "$SCRIPT_DIR/license.sh" "$LICENSE" "$VM_NAME"
elif [ -n "${FAIG_LICENSE_POOL:-}" ]; then
  echo "  license missing; taking a seat from the pool ..."
  "$SCRIPT_DIR/license_pool.sh" "$VM_NAME"
else
  echo "  WARNING: license not detected, no LICENSE=<file.lic> and no FAIG_LICENSE_POOL."
  echo "           Upload it (make license FILE=...) before class,"
  echo "           or set FAIG_LICENSE_POOL in gcp/.env and re-run: make up"
fi

# --- 2b. Settle --------------------------------------------------------------
# Wait for every pod + guardrail scanning before judging: right after a deploy,
# triton builds its TensorRT engines (minutes) and the license-manager needs
# reads from every engine; start.sh also clears dead pods. Fast when settled.
echo ""
echo "== waiting for pods + guardrail scanning =="
WAIT_MIN="${WAIT_MIN:-25}" "$SCRIPT_DIR/start.sh" "$VM_NAME"

# --- 3. Authoritative readiness gate ----------------------------------------
echo ""
echo "== running the readiness checks =="
"$SCRIPT_DIR/test.sh" "$VM_NAME"

echo ""
echo "== ready: cloud FortiAIGate is up, licensed, scanning and reachable. =="
echo "   Next (optional, class day): student workspaces via ../api/faig_class.py"
