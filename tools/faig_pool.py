"""Allocator for a pool of FortiAIGate licenses.

FAIG licenses are **single-occupancy**: one ``.lic`` (identified by its serial,
the filename stem ``FAIGCNSD26xxxxxx``) may be active on exactly one running
instance at a time. A serial live on two instances fails the second; it frees
~1h after the instance that held it stops using it. Licensing the cloud FAIG VMs
(cloud/faig_gcp/scripts/license_pool.sh, ledger key ``<vm>.gcp``) is therefore an
allocation problem: hand each VM a DISTINCT serial and never double-assign one.

This module owns a small on-disk ledger mapping ``serial -> pod`` so allocation
is:
  * **idempotent per pod** -- re-running for a pod already holding a serial
    returns the same one (never burns a second seat on a retry),
  * **exclusive** -- a serial allocated to one pod is not offered to another,
  * **concurrency-safe** -- the read-modify-write is done under an ``fcntl``
    exclusive lock, so a driver fanning out across many pods from one machine
    cannot double-allocate.

Release is EXPLICIT: a serial stays allocated until ``release`` is called for its
pod/serial (a torn-down VM's seat won't return to the pool on its own -- run
``release`` as part of teardown). The pure ledger transforms live here; the file
locking + CLI live in ``tools/faig_license_pool.py``.
"""
from __future__ import annotations

import glob
import os
from datetime import datetime, timezone

LEDGER_VERSION = 1


class PoolError(RuntimeError):
    """Allocation could not be satisfied (pool exhausted, bad ledger, …)."""


def _now() -> str:
    return datetime.now(timezone.utc).isoformat(timespec="seconds")


# ── pool discovery ────────────────────────────────────────────────────────────

def pool_serials(pool_dir: str) -> dict[str, str]:
    """``{serial: absolute .lic path}`` for every license file in ``pool_dir``.
    The serial is the filename stem (``FAIGCNSD26000940.lic`` -> that serial)."""
    if not os.path.isdir(pool_dir):
        raise PoolError(f"license pool dir not found: {pool_dir}")
    out: dict[str, str] = {}
    for p in sorted(glob.glob(os.path.join(pool_dir, "*.lic"))):
        out[os.path.splitext(os.path.basename(p))[0]] = os.path.abspath(p)
    if not out:
        raise PoolError(f"no .lic files in license pool dir: {pool_dir}")
    return out


# ── pure ledger transforms (no IO -- unit tested directly) ────────────────────

def empty_ledger() -> dict:
    return {"version": LEDGER_VERSION, "allocations": {}}


def _active(data: dict) -> dict[str, dict]:
    """serial -> record for every allocation currently held."""
    return {s: r for s, r in data.get("allocations", {}).items()
            if r.get("state") == "allocated"}


def _quarantined(data: dict) -> dict[str, dict]:
    """serial -> record for every serial parked as unusable (e.g. In Use on
    another instance). Excluded from allocation until explicitly released."""
    return {s: r for s, r in data.get("allocations", {}).items()
            if r.get("state") == "quarantined"}


def allocate_in(data: dict, serials: list[str], pod: str,
                uuid: str | None = None, *, now: str | None = None
                ) -> tuple[dict, str]:
    """Pure allocation. Returns ``(new_data, serial)``.

    Idempotent per pod: if ``pod`` already holds a serial that is still in the
    pool, that serial is returned unchanged. Otherwise the lowest-sorted free
    serial (in ``serials``, not currently allocated) is assigned. Raises
    ``PoolError`` when the pool is exhausted.
    """
    now = now or _now()
    data = {"version": data.get("version", LEDGER_VERSION),
            "allocations": dict(data.get("allocations", {}))}
    active = _active(data)
    pool = set(serials)

    # Idempotent: pod already holds a still-valid serial.
    for ser, rec in active.items():
        if rec.get("pod") == pod and ser in pool:
            if uuid and not rec.get("uuid"):
                rec = {**rec, "uuid": uuid}
                data["allocations"][ser] = rec
            return data, ser

    # Pick the lowest free serial: in the pool, not allocated to anyone, and not
    # quarantined (a serial found In Use on another instance stays out of the
    # rotation until explicitly released).
    taken = set(active) | set(_quarantined(data))
    free = [s for s in sorted(serials) if s not in taken]
    if not free:
        raise PoolError(
            f"license pool exhausted: {len(active)} allocated + "
            f"{len(_quarantined(data))} quarantined of {len(pool)}. "
            f"Release seats or add licenses.")
    ser = free[0]
    data["allocations"][ser] = {
        "pod": pod, "uuid": uuid, "state": "allocated",
        "allocated_at": now, "applied": False, "applied_at": None,
    }
    return data, ser


def release_in(data: dict, *, pod: str | None = None,
               serial: str | None = None) -> tuple[dict, list[str]]:
    """Pure release. Frees the seat(s) matching ``pod`` and/or ``serial`` by
    removing their ledger entries. Returns ``(new_data, freed_serials)``."""
    if not pod and not serial:
        raise PoolError("release needs a pod or a serial")
    data = {"version": data.get("version", LEDGER_VERSION),
            "allocations": dict(data.get("allocations", {}))}
    freed = []
    for ser, rec in list(data["allocations"].items()):
        if (serial and ser == serial) or (pod and rec.get("pod") == pod):
            del data["allocations"][ser]
            freed.append(ser)
    return data, freed


def quarantine_in(data: dict, serial: str, *, reason: str = "",
                  now: str | None = None) -> dict:
    """Park ``serial`` as unusable (state ``quarantined``) so it is never offered
    again until released -- used when a serial turns out to be In Use on another
    instance. Detaches it from whatever pod held it."""
    data = {"version": data.get("version", LEDGER_VERSION),
            "allocations": dict(data.get("allocations", {}))}
    prev = data["allocations"].get(serial, {})
    data["allocations"][serial] = {
        **prev, "state": "quarantined", "reason": reason,
        "pod": None,  # detach: a later release_in(pod=…) must not revive it
        "quarantined_at": now or _now(),
    }
    return data


def mark_applied_in(data: dict, serial: str, ok: bool, *,
                    now: str | None = None) -> dict:
    """Record whether the license actually applied+activated on the guest."""
    data = {"version": data.get("version", LEDGER_VERSION),
            "allocations": dict(data.get("allocations", {}))}
    rec = data["allocations"].get(serial)
    if rec is not None:
        data["allocations"][serial] = {**rec, "applied": bool(ok),
                                       "applied_at": now or _now()}
    return data


def summarize(data: dict, serials: dict[str, str]) -> dict:
    """A status view: counts + the per-pod allocation table."""
    active = _active(data)
    active_set = set(active)
    quar = set(_quarantined(data))
    pool = set(serials)
    in_pool = active_set & pool          # seats consumed from THIS pool
    quar_in_pool = quar & pool
    return {
        "pool_total": len(serials),
        "allocated": len(in_pool),
        "quarantined": len(quar_in_pool),
        "free": len(pool - in_pool - quar_in_pool),
        "orphans": sorted(active_set - pool),  # allocated but not in this pool dir
        "allocations": {
            ser: {"pod": r.get("pod"), "uuid": r.get("uuid"),
                  "applied": r.get("applied"), "allocated_at": r.get("allocated_at")}
            for ser, r in sorted(active.items())
        },
    }
