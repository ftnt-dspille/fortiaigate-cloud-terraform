#!/usr/bin/env bash
set -euo pipefail

# approver.sh -- run the class auto-approver ON the FAIG VM, as a systemd service.
#
# Every student change to a guardrail/detector/policy waits for an org admin, and
# 8.0.2 cannot turn that off. `faig_class.py approve --watch` clears roster
# workspaces' changes; run from a laptop it dies with the laptop (lid, VPN, IAP
# drop, the public_access_cidrs allowlist). Here it runs on the VM against the
# admin API on https://localhost, starts at boot, and restarts on any error (a
# FAIG still coming up, an expired session).
#
# Usage:
#   approver.sh install <instance> <vars.yml> <roster.csv> [faig_class.py args...]
#   approver.sh status  <instance>
#   approver.sh check   <instance>     exit 1 unless active and not crash-looping
#   approver.sh remove  <instance>
#
# install copies faig_class.py + its two modules, the vars file (it holds the
# admin password: root-only, 0600) and the roster to /opt/faig-approver, then
# (re)starts faig-approver.service. Re-running converges. A VM rebuilt from the
# image has none of it; `make faig-up` re-installs it every run.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/iap.sh"

ACTION="${1:?Usage: approver.sh install|status|check|remove <instance> ...}"
INSTANCE="${2:?Usage: approver.sh $ACTION <instance> ...}"
shift 2

API_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/api"
DEST=/opt/faig-approver
UNIT=faig-approver.service

VM_NAME="$(get_vm_name $((INSTANCE - 1)))"
ZONE="$(get_zone "$VM_NAME")"
SSH_PORT="${SSH_PORT:-$((2220 + INSTANCE))}"
iap_start_ssh "$VM_NAME" "$ZONE" >/dev/null
trap iap_cleanup EXIT
SSH_OPTS=(-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
on_vm() { ssh -p "$SSH_PORT" "${SSH_OPTS[@]}" "$SSH_TARGET" "$@"; }

show_status() {
  on_vm "systemctl is-active $UNIT; systemctl show $UNIT -p NRestarts -p ActiveEnterTimestamp; \
         sudo journalctl -u $UNIT -n ${LINES:-20} --no-pager -o short-iso" || true
}

case "$ACTION" in
  install)
    VARS="${1:?install needs <vars.yml>}"
    ROSTER="${2:?install needs <roster.csv>}"
    shift 2
    # The split args (--instance N --instances COUNT) go on the unit's command line
    # so this VM approves only its own students.
    EXTRA="$*"
    for f in "$API_DIR"/faig_class.py "$API_DIR"/faig802.py "$API_DIR"/faig_workshop.py "$VARS" "$ROSTER"; do
      [ -r "$f" ] || { echo "ERROR: cannot read $f" >&2; exit 1; }
    done
    on_vm "command -v python3 >/dev/null" || { echo "ERROR: no python3 on $VM_NAME" >&2; exit 1; }

    echo "=== $VM_NAME: installing $UNIT ==="
    STAGE="/tmp/faig-approver.$$"
    on_vm "rm -rf $STAGE && mkdir -m 700 $STAGE"
    command scp -q -P "$SSH_PORT" "${SSH_OPTS[@]}" \
      "$API_DIR"/faig_class.py "$API_DIR"/faig802.py "$API_DIR"/faig_workshop.py "$SSH_TARGET:$STAGE/"
    command scp -q -P "$SSH_PORT" "${SSH_OPTS[@]}" "$VARS" "$SSH_TARGET:$STAGE/vars.yml"
    command scp -q -P "$SSH_PORT" "${SSH_OPTS[@]}" "$ROSTER" "$SSH_TARGET:$STAGE/class.csv"
    on_vm "sudo install -d -m 700 -o root -g root $DEST && \
           sudo install -m 644 -o root -g root $STAGE/*.py $DEST/ && \
           sudo install -m 600 -o root -g root $STAGE/vars.yml $STAGE/class.csv $DEST/ && \
           rm -rf $STAGE"

    on_vm "sudo tee /etc/systemd/system/$UNIT >/dev/null" <<EOF
[Unit]
Description=FortiAIGate class auto-approver (roster workspaces only)
Wants=network-online.target
After=network-online.target k3s.service
StartLimitIntervalSec=0

[Service]
# The admin API on this VM's own ingress: no IAP tunnel, no allowlist.
Environment=FAIG_API_URL=https://localhost
Environment=PYTHONUNBUFFERED=1
ExecStart=/usr/bin/env python3 $DEST/faig_class.py --vars $DEST/vars.yml --roster $DEST/class.csv $EXTRA approve --watch
Restart=always
RestartSec=15
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes

[Install]
WantedBy=multi-user.target
EOF
    on_vm "sudo systemctl daemon-reload && sudo systemctl enable --quiet $UNIT && sudo systemctl restart $UNIT"
    sleep 8
    LINES=10 show_status
    on_vm "systemctl is-active --quiet $UNIT" || { echo "ERROR: $UNIT is not running" >&2; exit 1; }
    echo "== $UNIT running on $VM_NAME =="
    ;;
  status)
    show_status
    ;;
  check)
    # Healthy = active AND not crash-looping: Restart=always keeps a failing
    # approver "active" between restarts, so watch NRestarts over one restart period.
    restarts() { on_vm "systemctl show $UNIT -p NRestarts --value"; }
    on_vm "systemctl is-active --quiet $UNIT" || { LINES=20 show_status; echo "ERROR: $UNIT is not running on $VM_NAME" >&2; exit 1; }
    r1="$(restarts)"; sleep 20; r2="$(restarts)"
    if [ "$r1" != "$r2" ] || ! on_vm "systemctl is-active --quiet $UNIT"; then
      LINES=20 show_status
      echo "ERROR: $UNIT is restarting on $VM_NAME (NRestarts $r1 -> $r2)" >&2
      exit 1
    fi
    echo "== $UNIT healthy on $VM_NAME (active, NRestarts $r2) =="
    ;;
  remove)
    on_vm "sudo systemctl disable --now --quiet $UNIT 2>/dev/null; \
           sudo rm -f /etc/systemd/system/$UNIT && sudo rm -rf $DEST && sudo systemctl daemon-reload"
    echo "== $UNIT removed from $VM_NAME =="
    ;;
  *)
    echo "Usage: approver.sh install|status|check|remove <instance> ..." >&2
    exit 2
    ;;
esac
