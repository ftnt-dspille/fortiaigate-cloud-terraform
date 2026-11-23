#!/usr/bin/env bash
# IAP tunnel helper -- sourced by other scripts.
# Provides functions to start/stop IAP tunnels and SSH through them.

# This script lives in <repo>/gcp/scripts/; the terraform dir is <repo>/gcp/.
TF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Read through -json: with an empty state `output -raw` prints its "No outputs
# found" warning to stdout and exits 0, and that text ended up in --zone.
_tf_output() {
  terraform -chdir="$TF_DIR" output -json "$1" 2>/dev/null |
    python3 -c "import sys,json; v=json.load(sys.stdin); print(v if isinstance(v, str) else json.dumps(v))" 2>/dev/null
}

_no_state() {
  echo "ERROR: no FAIG VM in the terraform state ($TF_DIR) -- run 'make up' first" >&2
  exit 1
}

_tf_output_json() {
  terraform -chdir="$TF_DIR" output -json "$1" 2>/dev/null
}

get_vm_name() {
  local idx="${1:-0}"
  _tf_output_json vm_names | python3 -c "import sys,json; print(json.load(sys.stdin)[$idx])" 2>/dev/null || _no_state
}

get_zone() {
  local vm_name="$1"
  if [ -n "$vm_name" ]; then
    local zones_json
    zones_json="$(_tf_output_json zones 2>/dev/null)"
    if [ -n "$zones_json" ] && [ "$zones_json" != "null" ]; then
      local names_json
      names_json="$(_tf_output_json vm_names 2>/dev/null)"
      echo "$zones_json" | python3 -c "
import sys, json
zones = json.load(sys.stdin)
names = json.loads('''$names_json''') if '''$names_json'''.strip() else []
try:
    print(zones[names.index('$vm_name')])
except (ValueError, IndexError):
    sys.exit(1)
" 2>/dev/null && return 0
    fi
  fi
  _tf_output zone || _no_state
}

get_internal_ip() {
  local idx="${1:-0}"
  _tf_output_json internal_ips | python3 -c "import sys,json; print(json.load(sys.stdin)[$idx])"
}

# get_hostname [vm-name] -- the VM's stable DNS name (from faig_hostnames, e.g.
# faig.example.com or faig-2.example.com). Used as a TLS SAN so the
# ingress cert matches the name students use, not just an IP. Empty when DNS is
# not configured (dns_zone unset).
get_hostname() {
  local vm_name="${1:-$(get_vm_name)}"
  local names_json hostnames_json
  names_json="$(_tf_output_json vm_names 2>/dev/null)"
  hostnames_json="$(_tf_output_json faig_hostnames 2>/dev/null)"
  [ -n "$hostnames_json" ] && [ "$hostnames_json" != "null" ] || return 0
  echo "$hostnames_json" | python3 -c "
import sys, json
hostnames = json.load(sys.stdin)
if not hostnames:
    sys.exit(0)
names = json.loads('''$names_json''') if '''$names_json'''.strip() else []
try:
    idx = names.index('''$vm_name''')
except (ValueError, AttributeError):
    idx = 0
print(hostnames[idx] if idx < len(hostnames) else hostnames[0])
"
}

# First free local port at or above $1. A tunnel an earlier run left behind (or
# another session's) keeps its port; taking the next one beats dying on
# "Unable to open socket on port".
_free_port() {
  local p="$1"
  while lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; do p=$((p + 10)); done
  echo "$p"
}

# Start IAP tunnel for SSH on localhost:$SSH_PORT (default 2222; the next free
# port if that one is taken).
# Override SSH_PORT before calling to run concurrent tunnels to multiple VMs.
# Sets: IAP_PID, SSH_PORT, SSH_TARGET
iap_start_ssh() {
  local vm_name="${1:-$(get_vm_name)}"
  local zone="${2:-$(get_zone "$vm_name")}"
  local attempt
  IAP_VM="$vm_name"; IAP_ZONE="$zone"
  SSH_PORT="$(_free_port "${SSH_PORT:-2222}")"
  # A VM terraform just created (or moved) refuses IAP until sshd is up:
  # "4003: failed to connect to backend". Retry that for up to ~4 min.
  for attempt in 1 2 3 4 5 6 7 8; do
    gcloud compute start-iap-tunnel \
      --zone="$zone" "$vm_name" 22 \
      --local-host-port=localhost:$SSH_PORT \
      > /tmp/iap-tunnel-$$.log 2>&1 &
    IAP_PID=$!
    echo "Waiting for IAP tunnel to establish..."
    for i in $(seq 1 15); do
      sleep 2
      if kill -0 "$IAP_PID" 2>/dev/null; then
        if command ssh -p "$SSH_PORT" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
             -o ConnectTimeout=3 ubuntu@localhost "true" </dev/null 2>/dev/null; then
          echo "IAP tunnel established on localhost:$SSH_PORT"
          SSH_TARGET="ubuntu@localhost"
          return 0
        fi
      else
        break
      fi
    done
    kill "$IAP_PID" 2>/dev/null || true
    if grep -qE "4003|failed to connect to backend" /tmp/iap-tunnel-$$.log 2>/dev/null ||
       ! grep -q . /tmp/iap-tunnel-$$.log 2>/dev/null; then
      echo "  $vm_name not accepting SSH yet (booting?) -- retry $attempt/8 in 15s"
      sleep 15
      continue
    fi
    echo "ERROR: IAP tunnel process died for $vm_name"
    cat /tmp/iap-tunnel-$$.log
    _explain_tls_inspection /tmp/iap-tunnel-$$.log
    exit 1
  done
  echo "ERROR: no IAP SSH to $vm_name after ~4 min"
  cat /tmp/iap-tunnel-$$.log
  exit 1
}

# ssh through the tunnel, surviving a dropped tunnel. IAP drops long-lived
# tunnels now and then ("kex_exchange_identification: Connection reset by
# peer"), and a deploy makes dozens of ssh calls through one. On a connection
# failure (exit 255) restart the tunnel if it died and run the same command
# again with the same stdin (heredocs are captured first). Shadows `ssh` for
# every script that sources this file.
ssh() {
  local in rc try
  in=$(mktemp)
  if [ -t 0 ]; then : > "$in"; else cat > "$in"; fi
  for try in 1 2 3; do
    command ssh "$@" < "$in"; rc=$?
    [ "$rc" -ne 255 ] && break
    [ -z "${IAP_VM:-}" ] && break
    echo "  ssh lost the IAP tunnel to $IAP_VM (try $try/3); reconnecting..." >&2
    if ! kill -0 "${IAP_PID:-0}" 2>/dev/null; then
      ( iap_start_ssh "$IAP_VM" "$IAP_ZONE" >/dev/null ) || true
      # iap_start_ssh ran in a subshell: find the tunnel it left on our port.
      IAP_PID=$(lsof -nP -t -iTCP:"$SSH_PORT" -sTCP:LISTEN 2>/dev/null | head -1)
    fi
    sleep 5
  done
  rm -f "$in"
  return $rc
}

# A CERTIFICATE_VERIFY_FAILED from start-iap-tunnel means the local network
# decrypts TLS: gcloud API calls still work, only tunnel.cloudproxy.app fails.
# The VM is not at fault; name who signed the cert so the fix is obvious.
_explain_tls_inspection() {
  grep -q CERTIFICATE_VERIFY_FAILED "$1" 2>/dev/null || return 0
  local issuer
  issuer="$(echo | openssl s_client -connect tunnel.cloudproxy.app:443 \
    -servername tunnel.cloudproxy.app 2>/dev/null | sed -n 's/^issuer=//p' | head -1)"
  cat >&2 <<EOF

The IAP tunnel was refused locally, before it reached the VM: this network
inspects TLS, and tunnel.cloudproxy.app is presented with a cert issued by
  ${issuer:-<unknown>}
Use a network without TLS inspection (or have *.cloudproxy.app exempted), or
point gcloud at a CA bundle that includes that issuer:
  gcloud config set core/custom_ca_certs_file <bundle.pem>
EOF
}

# Start IAP tunnel for an arbitrary port
# Args: vm_name remote_port local_port
# Sets: IAP_PID_<port>
iap_start_port() {
  local vm_name="${1:-$(get_vm_name)}"
  local zone
  zone="$(get_zone "$vm_name")"
  local remote_port="$2"
  local local_port="$3"
  gcloud compute start-iap-tunnel \
    --zone="$zone" "$vm_name" "$remote_port" \
    --local-host-port=localhost:"$local_port" \
    > /tmp/iap-tunnel-$$-"$local_port".log 2>&1 &
  local pid=$!
  sleep 3
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "ERROR: IAP tunnel failed for $vm_name:$remote_port" >&2
    _explain_tls_inspection /tmp/iap-tunnel-$$-"$local_port".log
    exit 1
  fi
  echo "$pid"
}

iap_cleanup() {
  [ -n "${IAP_PID:-}" ] && kill "$IAP_PID" 2>/dev/null || true
}

# The FAIG admin password: $FAIG_ADMIN_PASS, else the macOS Keychain item
# `faig-lab-admin` (account $FAIG_KEYCHAIN_ACCOUNT, default "faig-admin").
# No built-in default -- the image ships with a strong password that lives
# only in those two places.
get_admin_pass() {
  if [ -n "${FAIG_ADMIN_PASS:-}" ]; then
    printf '%s' "$FAIG_ADMIN_PASS"
    return
  fi
  if command -v security >/dev/null 2>&1 &&
     security find-generic-password -s faig-lab-admin -a "${FAIG_KEYCHAIN_ACCOUNT:-faig-admin}" -w 2>/dev/null; then
    return
  fi
  echo "ERROR: no FAIG admin password -- export FAIG_ADMIN_PASS or add Keychain item faig-lab-admin" >&2
  return 1
}
