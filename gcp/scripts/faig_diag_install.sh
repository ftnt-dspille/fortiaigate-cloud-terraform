#!/usr/bin/env bash
set -euo pipefail

# faig_diag_install.sh -- install `faig-diag` on the FAIG VM: a systemd timer that records
# a health line every minute and keeps gateway / llama.cpp / pod events past pod restarts,
# plus a one-command diagnostic bundle. Idempotent; ready.sh calls it on every `make up`.
#
# On the VM (as root):   faig-diag status | events [N] | snapshot
# Logs: /var/log/faig-diag (daily rotation, 14 days). Details: the docstring in faig-diag.
#
# Usage: faig_diag_install.sh [vm-name]

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/iap.sh"

VM_NAME="${1:-$(get_vm_name)}"
ZONE="$(get_zone "$VM_NAME")"
PROJECT="$(gcloud config get-value project 2>/dev/null || true)"

gcloud compute scp --tunnel-through-iap --zone="$ZONE" --project="$PROJECT" \
  "$SCRIPT_DIR/faig-diag" "$VM_NAME:/tmp/faig-diag" >/dev/null

gcloud compute ssh --tunnel-through-iap --zone="$ZONE" --project="$PROJECT" "$VM_NAME" \
  --command="sudo bash -s" << 'REMOTE'
set -euo pipefail
install -m 0755 /tmp/faig-diag /usr/local/bin/faig-diag
cat >/etc/systemd/system/faig-diag.service <<'U'
[Unit]
Description=FAIG lab health sample and event capture
[Service]
Type=oneshot
ExecStart=/usr/local/bin/faig-diag sample
U
cat >/etc/systemd/system/faig-diag.timer <<'U'
[Unit]
Description=FAIG lab health sample every minute
[Timer]
OnBootSec=2min
OnUnitActiveSec=60s
AccuracySec=5s
[Install]
WantedBy=timers.target
U
cat >/etc/logrotate.d/faig-diag <<'U'
/var/log/faig-diag/*.log {
  daily
  rotate 14
  compress
  missingok
  notifempty
  copytruncate
}
U
systemctl daemon-reload
systemctl enable --now faig-diag.timer >/dev/null
echo "  faig-diag installed (timer: $(systemctl is-active faig-diag.timer))"
REMOTE
