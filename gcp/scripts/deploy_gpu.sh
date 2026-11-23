#!/usr/bin/env bash
set -euo pipefail

# Deploy a GPU VM from the GPU-ready image (faig-gpu-*).
# The image already has NVIDIA driver, containerd nvidia runtime, device plugin,
# and all FAIG images. This script just:
#   1. Fixes k3s cert for the new VM's internal IP
#   2. Restarts k3s
#   3. Runs helm upgrade
#   4. Waits for all pods to be Ready
#
# Usage: deploy_gpu.sh [vm-name]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/iap.sh"

VM_NAME="${1:-$(get_vm_name)}"
ZONE="$(get_zone "$VM_NAME")"
# Resolve the internal IP for this VM (match by name, not just index 0).
INTERNAL_IP=$(terraform -chdir="$TF_DIR" output -json internal_ips 2>/dev/null | \
  python3 -c "import sys,json; vms=json.load(sys.stdin); names=$(terraform -chdir="$TF_DIR" output -json vm_names 2>/dev/null); print(vms[names.index('$VM_NAME')])" 2>/dev/null || get_internal_ip)
# Stable DNS name for this VM (faig.example.com, faig-2.example.com, ...).
# Regenerated into the per-VM ingress cert below so each instance's UI cert
# matches the name students use. Empty when dns_zone is unset.
HOSTNAME="$(get_hostname "$VM_NAME")"
PROJECT_ID="$(terraform -chdir="$TF_DIR" output -raw project_id 2>/dev/null || true)"

echo "=== Starting IAP tunnel to $VM_NAME ==="
iap_start_ssh "$VM_NAME" "$ZONE"
trap iap_cleanup EXIT

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

echo "=== Detecting primary interface ==="
IFACE=$(ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_TARGET" \
  "ip -4 addr show | grep -v 'docker0\|lo\|cni\|flannel' | grep -oP '^\d+: \K\S+' | head -1" | tr -d ':' | tr -d '[:space:]')
echo "Primary interface: $IFACE"

echo "=== Step 1: Fixing k3s config for new VM internal IP ($INTERNAL_IP) ==="
ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_TARGET" IFACE="$IFACE" 'bash -s' << 'REMOTE'
set -e
IFACE="${IFACE:?}"
NEW_IP=$(ip -4 addr show "$IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
echo "New internal IP: $NEW_IP"

sudo sed -i "s|node-ip:.*|node-ip: \"$NEW_IP\"|" /etc/rancher/k3s/config.yaml
sudo sed -i "s|bind-address:.*|bind-address: \"$NEW_IP\"|" /etc/rancher/k3s/config.yaml
sudo sed -i "s|advertise-address:.*|advertise-address: \"$NEW_IP\"|" /etc/rancher/k3s/config.yaml

grep -q '127.0.0.1' /etc/rancher/k3s/config.yaml || sudo sed -i "/tls-san:/a\\  - \"127.0.0.1\"" /etc/rancher/k3s/config.yaml
grep -q "$NEW_IP" /etc/rancher/k3s/config.yaml || sudo sed -i "/tls-san:/a\\  - \"$NEW_IP\"" /etc/rancher/k3s/config.yaml

sudo rm -f /var/lib/rancher/k3s/server/tls/serving-kube-apiserver.crt
sudo rm -f /var/lib/rancher/k3s/server/tls/serving-kube-apiserver.key

sudo sed -i 's|server: https://.*:6443|server: https://127.0.0.1:6443|' /etc/rancher/k3s/k3s.yaml
sudo sed -i 's|server: https://.*:6443|server: https://127.0.0.1:6443|' ~/.kube/config 2>/dev/null || true

sudo systemctl restart k3s
sleep 10
echo "Waiting for k3s API..."
ME=$(hostname)
sudo k3s kubectl wait --for=condition=Ready "node/$ME" --timeout=120s 2>/dev/null || {
  echo "k3s not ready yet, waiting more..."
  sleep 15
  sudo k3s kubectl get nodes
}

# The image's k3s datastore still holds the node it was built on (e.g. faig-1).
# Its pods hang in Terminating forever -- and a StatefulSet pod (postgresql-0,
# redis-master-0) can't be recreated here while its old copy exists, so the
# FAIG never comes up. Delete every node that isn't this VM, then force-delete
# the pods that were bound to them.
for n in $(sudo k3s kubectl get nodes -o name | sed 's|^node/||' | grep -vx "$ME"); do
  echo "Removing stale node from the image: $n"
  sudo k3s kubectl delete node "$n" --wait=false
  sudo k3s kubectl get pods -A --field-selector "spec.nodeName=$n" --no-headers 2>/dev/null |
    while read -r ns pod _; do
      sudo k3s kubectl delete pod -n "$ns" "$pod" --force --grace-period=0 >/dev/null 2>&1 || true
    done
done
REMOTE

REPO_ROOT="$(git rev-parse --show-toplevel)"
FAIG_SEED="${FAIG_SEED_DIR:-$REPO_ROOT/faig_seed}"

# Provision the cert-manager DNS-01 solver SA key Secret on a fresh VM if it
# isn't already there. The key file is gitignored (gcp/.env.dns-sa-key.json).
# This is what makes a brand-new instance zero-touch for Let's Encrypt.
if [ -n "${FAIG_DNS_SA_SECRET:-}" ] && [ -f "$TF_DIR/.env.dns-sa-key.json" ]; then
  echo "=== Step 1a: Ensuring cert-manager DNS-01 solver Secret exists ==="
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
    # A challenge that already failed on the missing Secret sits in backoff for
    # a long time; delete it so its Order makes a fresh one that sees the Secret.
    ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_TARGET" \
      "sudo k3s kubectl delete challenges.acme.cert-manager.io -A --all >/dev/null 2>&1 || true"
  }
fi

# TLS for the UI. Two modes, selected by FAIG_ACME_EMAIL:
#   - cert-manager + Let's Encrypt (FAIG_ACME_EMAIL set): issue a trusted cert
#     for THIS VM's hostname via Cloud DNS (DNS-01) into the ingress
#     default-ssl-certificate Secret. No inbound ports needed; works behind the
#     allowlist. cert-manager renews it automatically.
#   - self-signed fallback (no email): regenerate the self-signed ingress cert
#     with this VM's hostname as a SAN. Name matches but the browser still
#     warns the cert is not trusted.
if [ -n "$HOSTNAME" ]; then
  CERT_INV=$(mktemp /tmp/faig-deploy-ingress.XXXX.yml)
  trap 'rm -f "$CERT_INV"; iap_cleanup' EXIT
  if [ -n "${FAIG_ACME_EMAIL:-}" ]; then
    echo "=== Step 1b: Issuing Let's Encrypt cert for $HOSTNAME (cert-manager, DNS-01) ==="
    CERT_TAGS="certmanager"
  else
    echo "=== Step 1b: Regenerating self-signed ingress cert for $HOSTNAME ==="
    CERT_TAGS="ingress"
  fi
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
fi

# llama.cpp is the workshop's upstream model (provider local-llamacpp): every
# student prompt goes through it, so it must be up -- not scaled away.
echo "=== Step 2: Keep llamacpp running (the lab's upstream model) ==="
ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_TARGET" \
  "sudo -u ubuntu sudo k3s kubectl scale deployment llamacpp -n llamacpp --replicas=1"

echo "=== Step 3: Helm upgrade ==="
ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_TARGET" \
  "sudo -u ubuntu bash -c 'helm upgrade fortiaigate ~/fortiaigate -n fortiaigate -f ~/my-values.yaml 2>&1' | tail -10"

echo "=== Step 3b: Clean up stale pods from old ReplicaSets ==="
ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_TARGET" 'bash -s' << 'REMOTE'
# Plain kubectl can't read k3s.yaml (root-only), and every call here sends its
# errors to /dev/null -- so this step silently did nothing until it used k3s's.
kubectl() { sudo k3s kubectl "$@"; }
# Delete pods stuck in Unknown/Pending from old ReplicaSets
kubectl get pods -n fortiaigate --no-headers 2>/dev/null | grep -E "Unknown|Pending|Error" | awk '{print $1}' | while read pod; do
  echo "Deleting stale pod: $pod"
  kubectl delete pod "$pod" -n fortiaigate --force --grace-period=0 2>/dev/null || true
done
# A rollout that changed a GPU request deadlocks on the one GPU: the old
# ReplicaSet keeps its GPU pod until the new one is Ready, and the new pods
# (triton needs the GPU; vllm has affinity to triton) never schedule. Scale
# every ReplicaSet that is not its Deployment's current revision to 0.
for d in $(kubectl get deploy -n fortiaigate -o name 2>/dev/null | sed 's|^deployment.apps/||'); do
  cur=$(kubectl get deploy "$d" -n fortiaigate -o jsonpath='{.metadata.annotations.deployment\.kubernetes\.io/revision}')
  kubectl get rs -n fortiaigate -o jsonpath="{range .items[?(@.metadata.ownerReferences[0].name=='$d')]}{.metadata.name} {.metadata.annotations.deployment\.kubernetes\.io/revision} {.spec.replicas}{'\n'}{end}" 2>/dev/null |
    while read -r rs rev n; do
      [ "$rev" != "$cur" ] && [ "${n:-0}" -gt 0 ] || continue
      echo "Scaling down old ReplicaSet $rs (rev $rev; $d is at rev $cur)"
      kubectl scale rs "$rs" -n fortiaigate --replicas=0 >/dev/null 2>&1 || true
    done
done
# Also clean up old ReplicaSets with 0 desired replicas
kubectl get rs -n fortiaigate --no-headers 2>/dev/null | grep "0[[:space:]]" | awk '{print $1}' | while read rs; do
  echo "Deleting old ReplicaSet: $rs"
  kubectl delete rs "$rs" -n fortiaigate 2>/dev/null || true
done
REMOTE

echo "=== Step 4: Waiting for all pods to be Ready ==="
ssh -p "$SSH_PORT" $SSH_OPTS "$SSH_TARGET" 'bash -s' << 'REMOTE'
set -e
echo "Waiting for pods to be ready (up to 5 min)..."
for i in $(seq 1 30); do
  # Not ready = READY count < total or STATUS not Running/Completed (never a
  # hardcoded 1/1 -- the llamacpp pod is 2/2 with the llama-proxy sidecar).
  NOT_READY=$( { sudo -u ubuntu sudo k3s kubectl get pods -n fortiaigate --no-headers 2>/dev/null
                  sudo -u ubuntu sudo k3s kubectl get pods -n llamacpp --no-headers 2>/dev/null; } |
               awk '{ split($2, r, "/"); if (r[1] != r[2] || ($3 != "Running" && $3 != "Completed")) print }' || true)
  if [ -z "$NOT_READY" ]; then
    echo "All pods are Ready!"
    sudo -u ubuntu sudo k3s kubectl get pods -n fortiaigate
    sudo -u ubuntu sudo k3s kubectl get pods -n llamacpp
    echo ""
    echo "=== GPU ==="
    nvidia-smi --query-gpu=name,memory.total,memory.used --format=csv,noheader
    echo ""
    echo "=== License status ==="
    sudo -u ubuntu sudo k3s kubectl logs -n fortiaigate -l app=license-manager --tail=3 2>&1 | grep -i "licence\|license" | tail -2
    exit 0
  fi
  # A VM booted from an image brings the old node's pods back; ones that lost the
  # GPU at admission (UnexpectedAdmissionError) or hit Unknown/Evicted never
  # recover, and their ReplicaSet has already started a replacement. They only
  # reach that state after boot, so the one-shot cleanup above can miss them.
  sudo -u ubuntu sudo k3s kubectl get pods -n fortiaigate --no-headers 2>/dev/null |
    awk '$3 ~ /AdmissionError|Unknown|Evicted|^Error$/ {print $1}' | while read -r pod; do
      echo "  deleting dead pod $pod"
      sudo -u ubuntu sudo k3s kubectl delete pod -n fortiaigate "$pod" --force --grace-period=0 >/dev/null 2>&1 || true
    done
  echo "  [$i/30] Still waiting..."
  sudo -u ubuntu sudo k3s kubectl get pods -n fortiaigate --no-headers 2>/dev/null |
    awk '{ split($2, r, "/"); if (r[1] != r[2] || ($3 != "Running" && $3 != "Completed")) print }' | head -5
  sleep 10
done
echo "TIMEOUT: Some pods not ready after 5 min"
sudo -u ubuntu sudo k3s kubectl get pods -n fortiaigate
exit 1
REMOTE

echo ""
echo "=== Deploy complete ==="
echo "Access the FAIG UI:"
echo "  ./scripts/tunnel.sh http $VM_NAME"
echo "  Open http://localhost:8080/ui/"
echo ""
echo "Next steps (the image already has the org, admin and the llama.cpp provider):"
echo "  1. Upload license:  make license FILE=<file.lic>"
echo "  2. Check it:        make test"
