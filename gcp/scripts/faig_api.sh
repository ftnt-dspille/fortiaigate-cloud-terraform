#!/usr/bin/env bash
set -euo pipefail

# faig_api.sh -- run a FAIG admin command against cloud instance N, from anywhere.
#
# The class tools (faig_class.py) talk to the FAIG admin API. Going straight to
# the public IP needs this laptop's egress in gpu.tfvars public_access_cidrs, and
# a rebuilt VM has a new IP that a hand-kept vars file never learns. So: open an
# IAP tunnel to the VM's 443 and export
#   FAIG_API_URL   https://localhost:<port>   (the admin calls go here)
#   FAIG_BASE_URL  https://<dns name>         (what students are sent: links, handout;
#                                             the public IP when dns_zone is unset)
# then run the command. faig_class.py prefers these over the vars file.
#
# Usage: faig_api.sh <instance> <command...>

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/iap.sh"

INSTANCE="${1:?Usage: faig_api.sh <instance> <command...>}"
shift
VM_NAME="$(get_vm_name $((INSTANCE - 1)))"
PUBLIC_IP="$(_tf_output_json public_ips | python3 -c "import sys,json; print(json.load(sys.stdin)[$((INSTANCE - 1))])")"
PORT=$((8439 + INSTANCE))

# The DNS name when there is one: the Let's Encrypt cert is issued for it (the
# IP gets a browser warning), and it survives a VM moving to a new IP.
HOST="$(get_hostname "$VM_NAME")"
export FAIG_BASE_URL="https://${HOST:-$PUBLIC_IP}"
# The live public-HTTPS firewall rule's source ranges (comma-separated), so the
# pod checks judge a pod's egress against what GCP enforces, not what gpu.tfvars
# says. Empty when gcloud cannot read it; the checks then fall back to gpu.tfvars.
FAIG_ALLOWED_CIDRS="$(gcloud compute firewall-rules list --project "$(_tf_output project_id)" \
  --filter="name~allow-public-https" --format="value(sourceRanges.list())" 2>/dev/null | head -1)" || true
export FAIG_ALLOWED_CIDRS
# No tunnel (VM stopped, IAP refused) still runs the command against the public
# URL: `status` reports the pod half either way and says why the FAIG failed.
if PID="$(iap_start_port "$VM_NAME" 443 "$PORT")"; then
  trap 'kill "$PID" 2>/dev/null || true' EXIT
  for _ in $(seq 1 10); do
    curl -sk -o /dev/null -m 3 "https://localhost:$PORT/" && break
    sleep 1
  done
  export FAIG_API_URL="https://localhost:$PORT"
else
  echo "WARNING: no IAP tunnel to $VM_NAME; using $FAIG_BASE_URL directly" >&2
fi
"$@"
