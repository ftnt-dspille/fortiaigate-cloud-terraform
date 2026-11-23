#!/usr/bin/env bash
set -euo pipefail

# license_pool.sh -- license a cloud FAIG from the shared license pool.
#
# FAIG licenses are single-occupancy: a serial live on another instance answers
# "In Use". This takes the VM's seat from the pool ledger (tools/faig_license_pool,
# keyed "<vm>.gcp", so a rebuilt VM gets its old serial back first), uploads it
# with license.sh, and on In Use parks that serial and rotates to the next one.
#
# Usage: license_pool.sh [vm-name]
#   Needs $FAIG_LICENSE_POOL (the dir of *.lic); the ledger is ~/.faig_alloc.json.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/iap.sh"

VM_NAME="${1:-$(get_vm_name)}"
POD="$VM_NAME.gcp"
REPO="$(git rev-parse --show-toplevel)"
: "${FAIG_LICENSE_POOL:?set FAIG_LICENSE_POOL to the dir of FAIG *.lic files}"

pool() { (cd "$REPO" && python3 -m tools.faig_license_pool "$@"); }

for attempt in 1 2 3 4 5; do
  LIC="$(pool alloc --pod "$POD")"
  SERIAL="$(basename "$LIC" .lic)"
  if ! head -c1 "$LIC" >/dev/null 2>&1; then
    # OneDrive "online-only" files are dataless placeholders; reading one fails.
    echo "ERROR: cannot read $LIC" >&2
    echo "  If the pool is in OneDrive, right-click the folder -> Always Keep on This Device." >&2
    exit 1
  fi
  echo "  [$attempt] $POD -> $SERIAL"
  set +e
  OUT="$("$SCRIPT_DIR/license.sh" "$LIC" "$VM_NAME" 2>&1)"
  RC=$?
  set -e
  echo "$OUT" | grep -vi numpy | sed 's/^/    /'
  if echo "$OUT" | grep -q FAIG_LICENSE_IN_USE; then
    pool quarantine --serial "$SERIAL" --reason "In Use (rotating $POD)"
    continue
  fi
  if [ "$RC" -eq 0 ]; then
    pool mark --pod "$POD" --ok
    exit 0
  fi
  pool mark --pod "$POD" --fail
  echo "ERROR: license upload failed for $SERIAL (not an In Use; not rotating)" >&2
  exit 1
done
echo "ERROR: 5 serials in a row were In Use; check: python3 -m tools.faig_license_pool status" >&2
exit 1
