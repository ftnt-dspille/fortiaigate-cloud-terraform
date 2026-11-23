"""CLI for the FortiAIGate license pool (see faig_pool.py alongside).

Grabs distinct license serials from a pool directory of ``.lic`` files and tracks
allocations in a locked ledger, so each cloud FAIG VM is licensed with a unique,
single-occupancy seat and never double-assigned. cloud/faig_gcp's `make up` /
`make license` drive it (scripts/license_pool.sh, key ``<vm>.gcp``); by hand:

    # one-time: point at the pool (or pass --pool each time / set $FAIG_LICENSE_POOL)
    export FAIG_LICENSE_POOL="/path/to/Lab Licenses/FAIG"

    # allocate a seat (idempotent -- the same key returns the same serial):
    LIC=$(python -m tools.faig_license_pool alloc --pod faig-1.gcp)

    # record the outcome, and release on teardown:
    python -m tools.faig_license_pool mark --pod faig-1.gcp --ok
    python -m tools.faig_license_pool release --pod faig-1.gcp

    python -m tools.faig_license_pool status         # counts + per-key table

The ledger defaults to ~/.faig_alloc.json (override with --ledger or
$FAIG_LICENSE_LEDGER). Allocation is done under an exclusive fcntl lock, so a
driver may fan `alloc` out across many VMs in parallel from one machine safely.
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import sys
from contextlib import contextmanager

from tools import faig_pool as pool

_DEFAULT_LEDGER = os.path.expanduser("~/.faig_alloc.json")


def _ledger_path(args) -> str:
    return (getattr(args, "ledger", None)
            or os.environ.get("FAIG_LICENSE_LEDGER") or _DEFAULT_LEDGER)


def _pool_dir(args) -> str:
    d = getattr(args, "pool", None) or os.environ.get("FAIG_LICENSE_POOL")
    if not d:
        sys.exit("no license pool: pass --pool or set $FAIG_LICENSE_POOL")
    return os.path.expanduser(d)


@contextmanager
def _locked_ledger(path: str):
    """Yield ``(data, save)`` under an exclusive lock held for the whole
    read-modify-write. ``save(new_data)`` persists atomically. The lock is on a
    sidecar ``.lock`` so it is held even when the ledger file doesn't exist yet."""
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    lockf = open(path + ".lock", "w")
    try:
        fcntl.flock(lockf, fcntl.LOCK_EX)
        try:
            with open(path) as fh:
                data = json.load(fh)
        except (FileNotFoundError, json.JSONDecodeError):
            data = pool.empty_ledger()

        def save(new_data: dict) -> None:
            tmp = path + ".tmp"
            with open(tmp, "w") as fh:
                json.dump(new_data, fh, indent=2, sort_keys=True)
            os.replace(tmp, path)

        yield data, save
    finally:
        fcntl.flock(lockf, fcntl.LOCK_UN)
        lockf.close()


# ── commands ──────────────────────────────────────────────────────────────────

def cmd_alloc(args) -> None:
    serials = pool.pool_serials(_pool_dir(args))
    with _locked_ledger(_ledger_path(args)) as (data, save):
        try:
            new, ser = pool.allocate_in(data, list(serials), args.pod, args.uuid)
        except pool.PoolError as e:
            sys.exit(f"alloc: {e}")
        save(new)
    # stdout = the .lic path (for `LIC=$(... alloc ...)`); notes to stderr.
    print(f"[alloc] {args.pod} -> {ser}", file=sys.stderr)
    print(serials[ser])


def cmd_release(args) -> None:
    with _locked_ledger(_ledger_path(args)) as (data, save):
        try:
            new, freed = pool.release_in(data, pod=args.pod, serial=args.serial)
        except pool.PoolError as e:
            sys.exit(f"release: {e}")
        save(new)
    print(f"[release] freed: {', '.join(freed) or '(none)'}", file=sys.stderr)


def cmd_mark(args) -> None:
    if not args.serial:
        # resolve serial from pod
        with _locked_ledger(_ledger_path(args)) as (data, save):
            ser = next((s for s, r in data.get("allocations", {}).items()
                        if r.get("pod") == args.pod and r.get("state") == "allocated"), None)
            if not ser:
                sys.exit(f"mark: no active allocation for pod {args.pod!r}")
            save(pool.mark_applied_in(data, ser, args.ok))
    else:
        with _locked_ledger(_ledger_path(args)) as (data, save):
            save(pool.mark_applied_in(data, args.serial, args.ok))
    print(f"[mark] applied={args.ok}", file=sys.stderr)


def cmd_quarantine(args) -> None:
    with _locked_ledger(_ledger_path(args)) as (data, save):
        save(pool.quarantine_in(data, args.serial, reason=args.reason or ""))
    print(f"[quarantine] {args.serial} parked ({args.reason or 'no reason'})",
          file=sys.stderr)


def cmd_status(args) -> None:
    serials = pool.pool_serials(_pool_dir(args))
    with _locked_ledger(_ledger_path(args)) as (data, _save):
        summ = pool.summarize(data, serials)
    if args.json:
        print(json.dumps(summ, indent=2))
        return
    print(f"pool: {summ['pool_total']} total  "
          f"{summ['allocated']} allocated  {summ.get('quarantined', 0)} quarantined  "
          f"{summ['free']} free"
          + (f"  ({len(summ['orphans'])} orphaned)" if summ["orphans"] else ""))
    for ser, r in summ["allocations"].items():
        applied = "applied" if r["applied"] else "pending"
        print(f"  {ser}  {r['pod'] or '?':<40} {applied}  {r['allocated_at'] or ''}")
    if summ["orphans"]:
        print("  orphaned (allocated but not in pool dir): "
              + ", ".join(summ["orphans"]))


def build_parser() -> argparse.ArgumentParser:
    ap = argparse.ArgumentParser(prog="faig_license_pool",
                                 description="allocate FortiAIGate licenses from a pool")
    ap.add_argument("--pool", help="pool dir of .lic files ($FAIG_LICENSE_POOL)")
    ap.add_argument("--ledger", help=f"ledger path (default {_DEFAULT_LEDGER}; "
                                     f"$FAIG_LICENSE_LEDGER)")
    sub = ap.add_subparsers(dest="cmd", required=True)

    a = sub.add_parser("alloc", help="allocate a serial for a pod (idempotent); prints the .lic path")
    a.add_argument("--pod", required=True)
    a.add_argument("--uuid", default=None, help="the faig instance UUID (recorded for traceability)")
    a.set_defaults(func=cmd_alloc)

    r = sub.add_parser("release", help="free a pod's / serial's seat back to the pool")
    r.add_argument("--pod", default=None)
    r.add_argument("--serial", default=None)
    r.set_defaults(func=cmd_release)

    m = sub.add_parser("mark", help="record whether a license actually applied+activated")
    m.add_argument("--pod", default=None)
    m.add_argument("--serial", default=None)
    grp = m.add_mutually_exclusive_group(required=True)
    grp.add_argument("--ok", dest="ok", action="store_true")
    grp.add_argument("--fail", dest="ok", action="store_false")
    m.set_defaults(func=cmd_mark)

    q = sub.add_parser("quarantine", help="park a serial as unusable (e.g. In Use elsewhere)")
    q.add_argument("--serial", required=True)
    q.add_argument("--reason", default=None)
    q.set_defaults(func=cmd_quarantine)

    s = sub.add_parser("status", help="counts + per-pod allocation table")
    s.add_argument("--json", action="store_true")
    s.set_defaults(func=cmd_status)
    return ap


def main(argv=None) -> None:
    args = build_parser().parse_args(argv)
    args.func(args)


if __name__ == "__main__":
    main()
