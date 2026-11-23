#!/usr/bin/env bash
set -euo pipefail

# issue_cert.sh -- (re)issue the FortiAIGate UI's TLS cert for a VM's hostname.
#
# Two modes, selected by FAIG_ACME_EMAIL (same as deploy_gpu.sh Step 1b):
#   - cert-manager + Let's Encrypt (FAIG_ACME_EMAIL set): a trusted cert for THIS
#     VM's hostname via Cloud DNS (DNS-01) into the ingress default TLS Secret.
#     No inbound ports; works behind the allowlist; cert-manager renews it.
#   - self-signed fallback (no email): regenerate the self-signed ingress cert
#     with this VM's hostname as a SAN. Name matches; browser still warns.
#
# Unlike deploy_gpu.sh this does NOT restart k3s or run helm -- it only touches
# the cert, so ready.sh can self-heal a wrong/self-signed UI cert on a VM that is
# otherwise converged (deploy_gpu.sh was skipped because the VM did not change).
#
# Usage: issue_cert.sh [vm-name]
#   Needs FAIG_ACME_EMAIL + FAIG_DNS_SA_SECRET + gcp/.env.dns-sa-key.json
#   for the Let's Encrypt path (the Makefile exports these from .env).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/iap.sh"

VM_NAME="${1:-$(get_vm_name)}"
ZONE="$(get_zone "$VM_NAME")"
INTERNAL_IP=$(terraform -chdir="$TF_DIR" output -json internal_ips 2>/dev/null | \
  python3 -c "import sys,json; vms=json.load(sys.stdin); names=$(terraform -chdir="$TF_DIR" output -json vm_names 2>/dev/null); print(vms[names.index('$VM_NAME')])" 2>/dev/null || get_internal_ip)
HOSTNAME="$(get_hostname "$VM_NAME")"
PROJECT_ID="$(terraform -chdir="$TF_DIR" output -raw project_id 2>/dev/null || true)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
FAIG_SEED="${FAIG_SEED_DIR:-$REPO_ROOT/faig_seed}"

if [ -z "$HOSTNAME" ]; then
  echo "issue_cert.sh: no DNS name for $VM_NAME (dns_zone unset) -- nothing to issue." >&2
  exit 0
fi

echo "=== issue_cert.sh: TLS cert for $HOSTNAME on $VM_NAME ==="
iap_start_ssh "$VM_NAME" "$ZONE"
trap iap_cleanup EXIT
SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

IFACE=$(ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_TARGET" \
  "ip -4 addr show | grep -v 'docker0\|lo\|cni\|flannel' | grep -oP '^\d+: \K\S+' | head -1" | tr -d ':' | tr -d '[:space:]')

# Step A: provision the cert-manager DNS-01 solver SA key Secret if missing.
if [ -n "${FAIG_DNS_SA_SECRET:-}" ] && [ -f "$TF_DIR/.env.dns-sa-key.json" ]; then
  echo "--- Ensuring cert-manager DNS-01 solver Secret exists ---"
  ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_TARGET" \
    "sudo k3s kubectl -n cert-manager get secret '$FAIG_DNS_SA_SECRET' >/dev/null 2>&1 && echo 'present' || echo 'missing'" \
  | grep -q present || {
    ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_TARGET" \
      "sudo k3s kubectl get ns cert-manager >/dev/null 2>&1 || sudo k3s kubectl create ns cert-manager"
    scp -P "$SSH_PORT" $SSH_OPTS "$TF_DIR/.env.dns-sa-key.json" "$SSH_TARGET":/tmp/cm-dns-key.json
    ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_TARGET" \
      "sudo k3s kubectl -n cert-manager create secret generic '$FAIG_DNS_SA_SECRET' \
         --from-file=key.json=/tmp/cm-dns-key.json --dry-run=client -o yaml \
       | sudo k3s kubectl apply -f - && rm -f /tmp/cm-dns-key.json"
    ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_TARGET" \
      "sudo k3s kubectl delete challenges.acme.cert-manager.io -A --all >/dev/null 2>&1 || true"
  }
fi

# Step B: issue (Let's Encrypt via cert-manager) or regenerate (self-signed).
if [ -n "${FAIG_ACME_EMAIL:-}" ]; then
  echo "--- Issuing Let's Encrypt cert for $HOSTNAME (cert-manager, DNS-01) ---"
  CERT_TAGS="certmanager"
else
  echo "--- Regenerating self-signed ingress cert for $HOSTNAME ---"
  CERT_TAGS="ingress"
fi
CERT_INV=$(mktemp /tmp/faig-issue-cert.XXXX.yml)
trap 'rm -f "$CERT_INV"; iap_cleanup' EXIT
cat > "$CERT_INV" <<EOF
---
all:
  children:
    k3s_node:
      hosts:
        cloud-faig:
          ansible_host: localhost
          ansible_port: $SSH_PORT
          ansible_user: ubuntu
          ansible_ssh_common_args: $SSH_OPTS
      vars:
        gpu_enabled: false
        primary_interface: $IFACE
        faig_primary_interface: $IFACE
        primary_iface_ip: $INTERNAL_IP
        external_address: $HOSTNAME
        extra_tls_sans:
          - $HOSTNAME
        cert_manager_dns_project: $PROJECT_ID
        cert_manager_email: ${FAIG_ACME_EMAIL:-}
        cert_manager_dns_sa_secret: ${FAIG_DNS_SA_SECRET:-}
EOF
ansible-playbook -i "$CERT_INV" "$FAIG_SEED/site.yml" --tags "$CERT_TAGS" \
  -e faig_primary_interface=$IFACE -e primary_interface=$IFACE \
  -e external_address=$HOSTNAME -e cert_manager_cert_hostname=$HOSTNAME
