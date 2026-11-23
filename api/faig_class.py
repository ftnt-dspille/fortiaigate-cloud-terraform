#!/usr/bin/env python3
"""Build, run and tear down a FortiAIGate 8.0.2 workshop class from one roster CSV.

The instructor side of the cloud-FAIG workshop. Every student gets their own
user + workspace + starting objects (see faig_workshop.py) on the one shared FAIG.

  faig_class.py --vars config/vars.cloud.yml --roster config/class.csv setup
  faig_class.py --vars ... --roster ... status                # health check (FAIG guards + each pod)
  faig_class.py --vars ... --roster ... score                 # progress scorecard, 0 = start state
  faig_class.py --vars ... --roster ... handout --out F       # each student's login (URL, email, password)
  faig_class.py --vars ... --roster ... approve --watch       # leave running during class
  faig_class.py --vars ... --roster ... reset [--student ID]  # delete + rebuild each workspace (accounts kept)
  faig_class.py --vars ... --roster ... teardown              # delete everything for the roster

Roster CSV columns: student_id,email,full_name,pod_host[,instance]
  student_id  workspace + object-name prefix, e.g. student03 (letters, digits, -, _)
  email       the student's WORK email: their FAIG login, and the owner of every key they
              create, so the FortiSOAR chapter's "suspend key + email owner" playbook
              mails it. A lab address never receives that warning.
  pod_host    the student's FortiDemo pod; its A record is the pod's egress IP and
              belongs in cloud/faig_gcp/gpu.tfvars public_access_cidrs (`allowlist`)
  instance    optional: which cloud FAIG (1, 2, ...) the student uses

With several cloud FAIGs, one roster serves them all: `--instance N --instances
COUNT` keeps the students of FAIG N -- the `instance` column if set, else
round-robin by roster order (appending a student never moves another one).

`setup` is the ONE command you need: it is idempotent (re-running converges, never
duplicates) and auto-creates every student's user + workspace + the STARTER objects
(baseline detector, log-only DLP/Custom Rules starters, guardrails wired to baseline
so everything MISMATCHes, and the policy). Students then configure their own guards
during Module 2 (set DLP categories, add built-in detectors, write custom rules) and
create their own virtual key in Lab 0. `setup` prints each newly-created student's
sign-up link for handout. Accounts are created by invitation and accepted with
`lab_password` from the vars file, so students just sign in. FAIG sends no invite email.
Use `status` to check the current state of the class.

WHY an approver: every change a workspace member makes to a guardrail or detector
is held as a pending change until an org admin approves it, and 8.0.2 has no
setting to turn that off. `approve --watch` approves pending changes from roster
workspaces only, so a student's click goes live within seconds -- and the
"submitted, awaiting approval" step is itself a governance talking point.
`make faig-up` installs it as a systemd service on the FAIG VM itself
(cloud/faig_gcp/scripts/approver.sh), so it does not depend on a laptop.

ALWAYS-ON FAIG (vars `faig_workspace: <existing workspace>`): the student's objects
go into that workspace, still named `<student_id> ...`. The workspace and the user
must already exist and are NEVER created, changed or deleted: `reset` and `teardown`
remove only the `<student_id> `-prefixed detectors, guardrails, policies and the
`<student_id>`-prefixed keys, and `approve` only approves changes to those objects.
`faig_credentials_env` (see faig802.load_vars) supplies the existing account.

Stdlib only, except that `status` reads each pod's FMG/FAZ password from the
pod through the repo's tools when the vars file sets no `fmg_pass`.
"""
from __future__ import annotations

import argparse
import concurrent.futures as cf
import csv
import os
import re
import socket
import sys
import time
from pathlib import Path

from faig802 import QUEUE_KIND, Faig802, FaigError, approve_new, load_vars
from faig_workshop import baseline_body, names, starter_dlp_body, starter_rules_body


def load_roster(path: str) -> list[dict]:
    with open(path, newline="") as fh:
        rows = [{k.strip(): (v or "").strip() for k, v in r.items()} for r in csv.DictReader(fh)]
    rows = [r for r in rows if r.get("student_id") and not r["student_id"].startswith("#")]
    for r in rows:
        if not r.get("email"):
            sys.exit(f"roster: {r['student_id']} has no email")
    return rows


def say(sid: str, msg: str) -> None:
    print(f"[{sid}] {msg}", flush=True)


# -- setup -------------------------------------------------------------------------
def ensure_user(a: Faig802, row: dict, password: str) -> tuple[dict, str | None]:
    """Ensure the student has an account; auto-accept the invite so setup is fully
    instructor-driven. Returns (user, invite_link) where invite_link is the sign-up
    link (for handout) only when the account was just created."""
    u = a.user_by_email(row["email"])
    if u:
        return u, None
    inv = a.invite(row["email"])
    a.accept_invite(inv["id"], row["email"], password, row.get("full_name") or row["student_id"])
    say(row["student_id"], f"user {row['email']} created")
    return a.user_by_email(row["email"]), inv.get("invitePath")


def ensure_detector(a: Faig802, ws: str, name: str, body: dict) -> dict:
    d = a.detector_by_name(ws, name)
    if not d:
        d = a.create_detector(ws, body)
    if d.get("approvalStatus") != "active":
        d = approve_new(a, ws, "detectors", d)
    return d


def ensure_guardrail(a: Faig802, ws: str, name: str, detector_ids: list[str]) -> dict:
    g = a.guardrail_by_name(ws, name) or a.create_guardrail(ws, name, detector_ids)
    return g if g.get("status") == "active" else approve_new(a, ws, "guardrails", g)


def _is_member(a: Faig802, ws_id: str, email: str) -> bool:
    return any(m["email"].lower() == email.lower() for m in a.workspace_members(ws_id)["items"])


def workspace_grants(v: dict) -> dict[str, list[str] | None]:
    """The providers each workspace gets (`faig_providers`, comma list; default
    `faig_provider_id`) and, per provider, the model ids it allows
    (`faig_models_<provider>`, comma list; unset = all of them)."""
    pids = [p.strip() for p in (v.get("faig_providers") or v["faig_provider_id"]).split(",") if p.strip()]
    out: dict[str, list[str] | None] = {}
    for pid in pids:
        raw = v.get(f"faig_models_{pid.replace('-', '_')}")
        out[pid] = [m.strip() for m in raw.split(",") if m.strip()] if raw else None
    return out


def workspace_budget(v: dict) -> float | None:
    """Each workspace's spend cap in USD (`faig_workspace_budget`; unset = none)."""
    raw = v.get("faig_workspace_budget")
    return float(raw) if raw not in (None, "", "none") else None


def setup_student(a: Faig802, row: dict, v: dict, print_invite: bool = True) -> dict:
    sid = row["student_id"]
    shared = v.get("faig_workspace")
    n = names(sid, shared)
    if shared:
        # Always-on FAIG: use the existing account and workspace as they are.
        if not a.user_by_email(row["email"]):
            sys.exit(f"[{sid}] no FAIG account {row['email']} -- faig_workspace mode never creates users")
        ws = a.workspace_by_name(n["workspace"])
        if not ws:
            sys.exit(f"[{sid}] no workspace {n['workspace']} -- faig_workspace mode never creates workspaces")
        w = ws["id"]
        if not _is_member(a, w, row["email"]):
            sys.exit(f"[{sid}] {row['email']} is not a member of {n['workspace']}")
    else:
        user, invite_path = ensure_user(a, row, v["lab_password"])
        if print_invite and invite_path:
            say(sid, f"sign-up link: {v['faig_base_url'].rstrip('/')}/ui{invite_path}")
        admin_id = a.user_by_email(v.get("faig_admin_email", "")) if v.get("faig_admin_email") else None
        ws = a.workspace_by_name(n["workspace"])
        if not ws:
            # admins must be existing users; start with the org admin, add the student next.
            seed = (admin_id or next(u for u in a.users() if u.get("orgRole") == "super_admin"))["id"]
            ws = a.create_workspace(n["workspace"], [seed], list(workspace_grants(v)), f"Workshop workspace for {sid}")
            say(sid, f"workspace {n['workspace']} created")
        w = ws["id"]
        budget = workspace_budget(v)
        if a.set_workspace_access(w, workspace_grants(v), budget, v.get("faig_workspace_budget_cycle", "monthly")):
            say(sid, f"workspace access: {workspace_grants(v)}, budget {budget if budget is not None else 'none'}")
        if not _is_member(a, w, row["email"]):
            a.make_workspace_admin(user["id"], w)
            say(sid, "student is workspace admin")
    base = ensure_detector(a, w, n["baseline"], baseline_body(sid))
    ensure_detector(a, w, n["dlp"], starter_dlp_body(sid))
    ensure_detector(a, w, n["rules"], starter_rules_body(sid))
    gi = ensure_guardrail(a, w, n["input"], [base["uuid"]])
    go = ensure_guardrail(a, w, n["output"], [base["uuid"]])
    p = a.policy_by_name(w, n["policy"]) or a.create_policy(
        w, n["policy"], [gi["id"]], [go["id"]], list(workspace_grants(v)))
    if p.get("status") != "active":
        p = approve_new(a, w, "policies", p)
    say(sid, "ready")
    return {"student_id": sid, "email": row["email"], "pod_host": row.get("pod_host", ""),
            "workspace_id": w, "policy_id": p["id"], "input_guardrail_id": gi["id"],
            "output_guardrail_id": go["id"]}


def handout_student(a: Faig802, row: dict, v: dict) -> dict:
    """What the student is handed: the login, checked against the box. `setup`
    accepts every invite itself, so the sign-up link is spent -- students sign in
    directly with their email and the lab password."""
    sid = row["student_id"]
    ws_name = names(sid, v.get("faig_workspace"))["workspace"]
    problems = []
    if not a.user_by_email(row["email"]):
        problems.append("no account")
    if not a.workspace_by_name(ws_name):
        problems.append("no workspace")
    return {"student_id": sid, "login_url": f"{v['faig_base_url'].rstrip('/')}/ui/login",
            "username": row["email"], "password": v["lab_password"], "workspace": ws_name,
            "status": "; ".join(problems) + " -- run setup" if problems else "ok"}


def invite_student(a: Faig802, row: dict, base_url: str) -> None:
    """Instructor side of the student's own sign-up: FAIG sends no email, so the
    link is handed out (or opened by config/student/files/student_ui.py accept)."""
    sid = row["student_id"]
    if a.user_by_email(row["email"]):
        say(sid, f"{row['email']} already has an account -- nothing to invite")
        return
    inv = a.invite(row["email"])
    print(f"{sid} {row['email']} {base_url.rstrip('/')}/ui{inv['invitePath']}", flush=True)


# -- approve -----------------------------------------------------------------------
def approve_pending(a: Faig802, ws_ids: set[str], prefixes: tuple[str, ...] = ()) -> int:
    """Approve the class's pending changes. `prefixes` (always-on FAIG): approve only
    objects named `<student_id> ...`, never the workspace owner's own changes."""
    done = 0
    for item in a.review_queue():
        if item.get("ownerWorkspaceId") not in ws_ids:
            continue  # never approve anything outside the class
        if prefixes and not str(item.get("name", "")).startswith(prefixes):
            continue
        kind = QUEUE_KIND.get(item.get("type", ""))
        if not kind:
            continue
        try:
            a.approve(kind, item["id"])
            who = (item.get("submittedBy") or {}).get("email", "?")
            print(f"approved {item['type']} '{item['name']}' ({item.get('changeKind')}) from {who}", flush=True)
            done += 1
        except FaigError as e:
            print(f"could not approve {item['type']} '{item['name']}': {e}", file=sys.stderr)
    return done


# -- reset / teardown ----------------------------------------------------------------
def _admin_edit(a: Faig802, kind: str, obj_id: str, fn):
    """An admin edit or delete on an object holding a student's pending change is
    refused (409); reject the pending change first, then retry."""
    try:
        return fn()
    except FaigError as e:
        if e.status != 409:
            raise
        a.reject(kind, obj_id)
        return fn()


def _remove(dry: list | None, what: tuple[str, str, str], fn) -> None:
    """Delete via `fn`, or -- when `dry` is a list -- only record (kind, id, name)."""
    if dry is None:
        fn()
    else:
        dry.append(what)


def delete_workspace(a: Faig802, sid: str, dry: list | None = None) -> bool:
    """Delete the student's workspace and everything it owns. The user account is
    left alone. False when there was no workspace. `dry`: record, do not delete."""
    ws = a.workspace_by_name(names(sid)["workspace"])
    if not ws:
        return False
    w = ws["id"]
    for k in a.virtual_keys(w):
        _remove(dry, ("key", k["id"], k.get("keyName", "")), lambda i=k["id"]: a.delete_virtual_key(i))
    # The workspace delete 409s ("projects still reference it") while any of its
    # own objects exist; remove them in dependency order: policy, guardrails, detectors.
    # (The workspace listings also include org-scope objects -- skip those.)
    for kind, objs, key in (("policies", a.policies(w), "id"), ("guardrails", a.guardrails(w), "id"),
                            ("detectors", a.detectors(w), "uuid")):
        for o in objs:
            if o.get("ownerWorkspaceId") == w:
                _remove(dry, (kind, o[key], o.get("name", "")),
                        lambda k=kind, i=o[key]: _admin_edit(
                            a, k, i, lambda: a.delete(f"/api/v1/workspaces/{w}/{k}/{i}")))
    _remove(dry, ("WORKSPACE", w, names(sid)["workspace"]), lambda: a.delete_workspace(w))
    return True


def delete_student_objects(a: Faig802, sid: str, workspace: str, dry: list | None = None) -> int:
    """Always-on FAIG: remove only what the student made in the shared `workspace` --
    keys named `<sid>...`, and the workspace-owned policies, guardrails and detectors
    named `<sid> ...` -- in dependency order. The workspace, its other objects and
    the account are never touched. Returns how many objects were (or, with `dry`,
    would be) removed."""
    ws = a.workspace_by_name(workspace)
    if not ws:
        return 0
    w, mine, n = ws["id"], f"{sid} ", 0
    for k in a.virtual_keys(w):
        # "student00-key", never "student001-key": the name must continue with a separator.
        if str(k.get("keyName", "")).startswith((f"{sid}-", f"{sid} ")):
            _remove(dry, ("key", k["id"], k.get("keyName", "")), lambda i=k["id"]: a.delete_virtual_key(i))
            n += 1
    for kind, objs, key in (("policies", a.policies(w), "id"), ("guardrails", a.guardrails(w), "id"),
                            ("detectors", a.detectors(w), "uuid")):
        for o in objs:
            if o.get("ownerWorkspaceId") == w and str(o.get("name", "")).startswith(mine):
                _remove(dry, (kind, o[key], o.get("name", "")),
                        lambda k=kind, i=o[key]: _admin_edit(
                            a, k, i, lambda: a.delete(f"/api/v1/workspaces/{w}/{k}/{i}")))
                n += 1
    return n


def removal_plan(a: Faig802, row: dict, v: dict, *, teardown: bool) -> list[tuple[str, str, str]]:
    """What `reset` (teardown=False) or `teardown` would delete for this student,
    without deleting anything: (kind, id, name) rows in the order they would go."""
    sid, shared, dry = row["student_id"], v.get("faig_workspace"), []
    if shared:
        delete_student_objects(a, sid, shared, dry)
        return dry
    delete_workspace(a, sid, dry)
    u = a.user_by_email(row["email"]) if teardown else None
    if u:
        dry.append(("USER", u["id"], row["email"]))
    return dry


def reset_student(a: Faig802, row: dict, v: dict) -> None:
    """Back to the first-time start state: delete the workspace and rebuild it with
    `setup`, so nothing the student made (keys, extra detectors, guardrails,
    policies, pending changes) survives. The account and its password are kept.
    On an always-on FAIG only the student's own objects are removed and rebuilt."""
    sid = row["student_id"]
    if v.get("faig_workspace"):
        say(sid, f"{delete_student_objects(a, sid, v['faig_workspace'])} student object(s) removed "
                 f"from {v['faig_workspace']} (workspace kept)")
    elif delete_workspace(a, sid):
        say(sid, "workspace deleted")
    setup_student(a, row, v, print_invite=False)
    say(sid, "reset to the student start state (workspace rebuilt, keys removed)")


# -- status / teardown ---------------------------------------------------------------
def guards_student(a: Faig802, row: dict, workspace: str | None = None) -> tuple[bool, str]:
    """Is the student's FAIG side what `setup` builds? Workspace, the three starter
    detectors, both guardrails (each with a detector) and the policy wiring them,
    all active. Read-only. What the student changed since (detectors on a
    guardrail, DLP categories, keys) is reported, not judged."""
    n = names(row["student_id"], workspace)
    ws = a.workspace_by_name(n["workspace"])
    if not ws:
        return False, "no workspace -- run setup"
    w = ws["id"]
    problems, info = [], []
    for key in ("baseline", "dlp", "rules"):
        d = a.detector_by_name(w, n[key])
        if not d:
            problems.append(f"no detector '{n[key]}'")
        elif d.get("approvalStatus") != "active":
            problems.append(f"'{n[key]}' {d.get('approvalStatus')}")
    dn = {d["uuid"]: d["name"] for d in a.detectors(w)}
    gids = {}
    for key in ("input", "output"):
        g = a.guardrail_by_name(w, n[key])
        if not g:
            problems.append(f"no guardrail '{n[key]}'")
            continue
        gids[key] = g["id"]
        if g.get("status") != "active":
            problems.append(f"'{n[key]}' {g.get('status')}")
        if not g.get("detectorIds"):
            problems.append(f"'{n[key]}' has no detector")
        if g.get("hasPendingChange"):
            info.append(f"{key} change pending approval")
        info.append(f"{key}=[{', '.join(dn.get(i, i) for i in g.get('detectorIds') or [])}]")
    p = a.policy_by_name(w, n["policy"])
    if not p:
        problems.append(f"no policy '{n['policy']}'")
    else:
        if p.get("status") != "active":
            problems.append(f"policy {p.get('status')}")
        for key, field in (("input", "inputGuardrailIds"), ("output", "outputGuardrailIds")):
            if key in gids and gids[key] not in (p.get(field) or []):
                problems.append(f"policy is not wired to '{n[key]}'")
    info.append(f"keys={len(a.virtual_keys(w))}")
    return not problems, "; ".join(problems) + (" -- run setup" if problems else "") or ", ".join(info)


def _fabric_password(pod_host: str) -> str | None:
    """The FMG/FAZ admin password on a Fabric Studio pod is the fabric's own
    password, read from the pod (repo tools, Keychain pod login). None when the
    repo tools or the pod are unreachable."""
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
    if root not in sys.path:
        sys.path.insert(0, root)
    try:
        from fabric_studio.keychain import resolve_pod_login

        from tools.fabric_license import _resolve_fabric_password_ssh

        user, pw = resolve_pod_login(pod_host)
        return _resolve_fabric_password_ssh(pod_host, user, pw)
    except Exception:  # any failure means "could not read it"
        return None


def pod_student(row: dict, v: dict) -> list:
    """Module 3's read-only checks against the student's pod: ADOM mode on FMG and
    FAZ, FortiGate managed in the ADOM, its traffic logs reaching FAZ -- plus the
    pod baseline that ws-badguy's egress is on the FAIG allowlist and that FAZ's
    lab ADOM is a Fabric ADOM (faig-ready converts it)."""
    from validate_workshop import Check, faig_reach, faz_fabric_adom, module3
    if not row.get("pod_host"):
        return []  # no pod assigned yet: nothing to check, not a failure
    pv = pod_vars(row, v)
    if pv is None:
        c = Check("pod")
        c.fail(f"could not read the fabric password from {row['pod_host']} (pod down?)")
        return [c]
    checks: list = []
    module3(pv, checks)
    faig_reach(pv, checks)
    faz_fabric_adom(pv, checks)
    return checks


def pod_vars(row: dict, v: dict) -> dict | None:
    """The vars for one student's pod checks: its host, the FMG/FAZ web ports and
    the fabric password (read from the pod when the vars set none). None when the
    password cannot be read."""
    host = row["pod_host"]
    pv = dict(v, pod_host=host, fmg_port=v.get("fmg_port", 13002), faz_port=v.get("faz_port", 13003))
    if "fmg_pass" not in v:
        pw = _fabric_password(host)
        if not pw:
            return None
        pv["fmg_pass"] = pw
    pv.setdefault("ws_pass", pv["fmg_pass"])  # the pod's workstations use the fabric password too
    return pv


def status_class(a: Faig802 | None, roster: list[dict], v: dict, *, faig_error: str = "",
                 pods_check: bool = True) -> int:
    """One row per student: FAIG guard setup + pod (ADOM mode, FGT managed, logs).
    Pods are checked in parallel. Exit 1 if anything fails. pods_check=False skips
    the pod columns (workshop-prep has just run lab-health over the same pods)."""
    if pods_check:
        with cf.ThreadPoolExecutor(max_workers=min(20, max(1, len(roster)))) as ex:
            pods = list(ex.map(lambda r: pod_student(r, v), roster))
    else:
        pods = [[] for _ in roster]
    pod_cols = ("adom", "fmg", "faz-logs", "allowlist", "fabric")
    cols = ("student", "faig", *pod_cols)
    rows, details, skipped = [], [], 0
    for r, checks in zip(roster, pods, strict=True):
        sid = r["student_id"]
        if a is None:
            gok, gdetail = False, faig_error
        else:
            try:
                gok, gdetail = guards_student(a, r, v.get("faig_workspace"))
            except (FaigError, OSError) as e:
                gok, gdetail = False, f"FAIG API error: {e}"
        cells = {"student": sid, "faig": "PASS" if gok else "FAIL", **dict.fromkeys(pod_cols, "-")}
        if not gok:
            details.append(f"[{sid}] faig: {gdetail}")
        if not checks:  # no pod_host: pod checks skipped
            cells.update(dict.fromkeys(pod_cols, "-"))
            skipped += 1
        elif len(checks) == 1 and checks[0].name == "pod":  # the pod was never checked
            cells.update(dict.fromkeys(pod_cols, "-"))
            details.append(f"[{sid}] pod: {checks[0].detail}")
        else:
            for key, c in zip(pod_cols, checks, strict=False):
                cells[key] = "PASS" if c.passed else "FAIL"
                if not c.passed:
                    details.append(f"[{sid}] {c.name}: {c.detail}")
        rows.append(cells)
        r["_ok"] = gok and all(c.passed for c in checks)
    width = {c: max(len(c), *(len(x[c]) for x in rows)) for c in cols}
    for x in [dict(zip(cols, cols, strict=True)), *rows]:
        print("  ".join(x[c].ljust(width[c]) for c in cols).rstrip())
    if details:
        print()
        for d in details:
            print(d)
    bad = sum(1 for r in roster if not r["_ok"])
    if not pods_check:
        print("\npod checks skipped (--no-pods): lab-health covers them")
    elif skipped:
        print(f"\n{skipped} student(s) have no pod_host in the roster: pod checks skipped")
    print(f"\n{len(roster) - bad}/{len(roster)} students ready")
    return 1 if bad else 0


def score_class(a: Faig802 | None, roster: list[dict], v: dict, *, faig_error: str = "",
                detail: bool = False, fortiai: bool = True) -> int:
    """Progress scorecard (faig_scorecard.py): points per chapter, 0 = start state.
    Students are scored in parallel."""
    from faig_scorecard import print_cards, score_student

    def one(row: dict):
        host = row.get("pod_host")
        pod = None
        if host:
            pw = v.get("fmg_pass") or _fabric_password(host)
            pod = {"host": host, "password": pw, "adom": v.get("fmg_adom", "corp"),
                   "fgt_ssh_port": int(v.get("fgt_ssh_port", 11001)),
                   "ws_ssh_port": int(v.get("ws_ssh_port", 11005)), "ws_user": v.get("ws_user", "admin"),
                   "fmg_port": int(v.get("fmg_port", 13002)), "faz_port": int(v.get("faz_port", 13003))}
            if not pw:
                pod = None
                row["_pod_error"] = f"could not read the fabric password from {host} (pod down?)"
        return score_student(a, row, pod, faig_error=faig_error, fortiai=fortiai)

    with cf.ThreadPoolExecutor(max_workers=8) as ex:
        cards = list(ex.map(one, roster))
    print_cards(cards, detail=detail or len(cards) == 1)
    for r in roster:
        if not r.get("pod_host"):
            print(f"[{r['student_id']}] no pod_host in the roster: pod chapters not scored")
        elif r.get("_pod_error"):
            print(f"[{r['student_id']}] {r['_pod_error']}")
    return 0


def teardown_student(a: Faig802, row: dict, workspace: str | None = None, *,
                     keep_user: bool = False) -> None:
    sid = row["student_id"]
    if workspace:
        # Always-on FAIG: the workspace and the account are not the class's to delete.
        say(sid, f"{delete_student_objects(a, sid, workspace)} student object(s) removed "
                 f"from {workspace} (workspace and user kept)")
        return
    if delete_workspace(a, sid):
        say(sid, "workspace deleted")
    u = None if keep_user else a.user_by_email(row["email"])
    if u:
        a.delete_user(u["id"])
        say(sid, "user deleted")


def split_roster(roster: list[dict], instance: int, count: int) -> list[dict]:
    """The students of FAIG `instance` out of `count`: the row's `instance` column,
    else round-robin by roster position."""
    if count <= 1:
        return roster
    return [r for i, r in enumerate(roster)
            if (int(r["instance"]) if (r.get("instance") or "").strip() else i % count + 1) == instance]


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--vars", action="append", required=True,
                    help="vars file(s), merged in order: faig_base_url, admin creds, lab_password")
    ap.add_argument("--roster", help="class roster CSV (default: the single student_id/student_email "
                                     "in the vars -- how the student walkthrough drives one pod)")
    ap.add_argument("--instance", type=int, default=1, help="which cloud FAIG this run targets")
    ap.add_argument("--instances", type=int, default=1,
                    help="how many cloud FAIGs share the roster (1 = every student is on this one)")
    ap.add_argument("--out", help="setup: write per-student ids here; handout: write the logins "
                                  "here (gitignored path -- it holds the lab password)")
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("setup")
    sub.add_parser("invite")
    sub.add_parser("handout")
    ap_apr = sub.add_parser("approve")
    ap_apr.add_argument("--watch", action="store_true", help="keep approving until interrupted")
    ap_apr.add_argument("--interval", type=float, default=3.0)
    ap_reset = sub.add_parser("reset", help="delete and rebuild each workspace (accounts kept)")
    ap_reset.add_argument("--dry-run", action="store_true", help="list what would be deleted; change nothing")
    ap_reset.add_argument("--student", action="append", metavar="ID",
                          help="only this student_id (repeatable); default: the whole roster")
    ap_st = sub.add_parser("status")
    ap_st.add_argument("--no-pods", action="store_true",
                       help="FAIG side only; skip the per-pod checks (lab-health covers them)")
    ap_score = sub.add_parser("score", help="read-only progress scorecard, 0 points = start state")
    ap_score.add_argument("--detail", action="store_true", help="every check per student")
    ap_score.add_argument("--no-fortiai", action="store_true",
                          help="skip the FMG/FAZ FortiAI token-pool reads (GUI logins)")
    ap_chk = sub.add_parser("check", help="read-only: per student, which Module 2 tests will be "
                                         "blocked and why the others won't")
    ap_chk.add_argument("--student", action="append", metavar="ID",
                        help="only this student_id (repeatable); default: the whole roster")
    ap_td = sub.add_parser("teardown")
    ap_td.add_argument("--dry-run", action="store_true", help="list what would be deleted; change nothing")
    ap_td.add_argument("--keep-users", action="store_true",
                       help="delete the workspaces only; keep the accounts (returning students)")
    sub.add_parser("allowlist")
    args = ap.parse_args()

    v = load_vars(args.vars)
    shared = v.get("faig_workspace")
    # cloud/faig_gcp/scripts/faig_api.sh (the make faig-class* targets) points these
    # at the live VM: the admin API through an IAP tunnel, and the public URL that
    # students are sent. Without it, the vars file's faig_base_url is both.
    if os.environ.get("FAIG_BASE_URL"):
        v["faig_base_url"] = os.environ["FAIG_BASE_URL"]
    api_url = os.environ.get("FAIG_API_URL") or v["faig_base_url"]
    if args.roster:
        roster = load_roster(args.roster)
    elif v.get("student_id") and v.get("student_email"):
        roster = [{"student_id": v["student_id"], "email": v["student_email"],
                   "full_name": v.get("student_name", v["student_id"]), "pod_host": v.get("pod_host", "")}]
    else:
        sys.exit("give --roster, or student_id + student_email in the vars")
    roster = split_roster(roster, args.instance, args.instances)
    if not roster:
        print(f"no students on FAIG {args.instance} of {args.instances}")
        return 0

    if args.cmd == "allowlist":
        # Pure DNS: the pod's A record is its egress IP (both via the FGT and OOB).
        for r in roster:
            host = r.get("pod_host")
            ip = socket.gethostbyname(host) if host else None
            print(f'  "{ip}/32", # {host} ({r["student_id"]})' if ip else f"  # {r['student_id']}: no pod_host")
        return 0

    if args.cmd == "check":
        from faig_scorecard import explain_student
        a = Faig802(api_url, v.get("faig_admin_user", "admin"), v["faig_admin_pass"])
        rows = [r for r in roster if not args.student or r["student_id"] in args.student]
        bad = 0
        for r in rows:
            res = explain_student(a, r["student_id"])
            fails = [x for x in res if not x[0]]
            bad += bool(fails)
            print(f"\n[{r['student_id']}] {len(res) - len(fails)}/{len(res)} will block")
            for ok, test, why in res:
                print(f"  {'BLOCK' if ok else 'MISS '}  {test:<38} {why}")
        return 1 if bad else 0

    if args.cmd in ("status", "score"):
        # The pod half of the check does not need the FAIG: report what it can
        # even when the FAIG is unreachable (allowlist, VM stopped).
        try:
            a = Faig802(api_url, v.get("faig_admin_user", "admin"), v["faig_admin_pass"])
            a.workspaces()  # one probe, not a timeout per student
            err = ""
        except (FaigError, OSError) as e:
            a, err = None, f"cannot reach the FAIG at {api_url}: {e}"
        if args.cmd == "score":
            return score_class(a, roster, v, faig_error=err, detail=args.detail,
                               fortiai=not args.no_fortiai)
        return status_class(a, roster, v, faig_error=err, pods_check=not args.no_pods)

    a = Faig802(api_url, v.get("faig_admin_user", "admin"), v["faig_admin_pass"])
    if args.cmd in ("reset", "teardown") and args.dry_run:
        if args.cmd == "reset" and args.student:
            roster = [r for r in roster if r["student_id"] in args.student]
        for r in roster:
            where = f"in {shared} (workspace and user kept)" if shared else "(its own workspace)"
            plan = removal_plan(a, r, v, teardown=args.cmd == "teardown" and not getattr(args, "keep_users", False))
            say(r["student_id"], f"DRY RUN {args.cmd} {where}: {len(plan)} deletion(s)")
            for kind, i, name in plan:
                print(f"    would delete {kind:<10} {name!r:<40} {i}", flush=True)
        return 0
    if args.cmd == "setup":
        # The image ships the model unpriced, so Cost pages, per-log Cost and key
        # budgets all read $0. A frontier-model price makes them mean something.
        price = (float(v.get("faig_model_input_cost", 3)), float(v.get("faig_model_output_cost", 15)))
        if a.set_model_price("local-llamacpp", *price):
            print(f"priced local-llamacpp models at ${price[0]:g} in / ${price[1]:g} out per 1M tokens")
        # A second, paid provider (OpenAI) next to the self-hosted one, with only the
        # cheap models students may call. The key stays in a gitignored file.
        key_file = v.get("faig_openai_key_file")
        if key_file:
            text = Path(key_file).expanduser().read_text()
            m = re.search(r"^(?:OPENAI_API_KEY=)?[\"']?(sk-[A-Za-z0-9_-]+)", text, re.M)
            if not m:
                sys.exit(f"no OpenAI key in {key_file}")
            models = workspace_grants(v).get("openai") or ["gpt-4.1-mini"]
            if a.ensure_provider("openai", "openai", "OpenAI", m.group(1), models):
                print(f"added provider openai with {models}")
        out = [setup_student(a, r, v) for r in roster]
        if args.out:
            with open(args.out, "w", newline="") as fh:
                wr = csv.DictWriter(fh, fieldnames=list(out[0]))
                wr.writeheader()
                wr.writerows(out)
            print(f"wrote {args.out}")
    elif args.cmd == "handout":
        rows = [handout_student(a, r, v) for r in roster]
        cols = ("student_id", "login_url", "username", "password", "workspace", "status")
        width = {c: max(len(c), *(len(r[c]) for r in rows)) for c in cols}
        for r in [dict(zip(cols, cols, strict=True)), *rows]:
            print("  ".join(r[c].ljust(width[c]) for c in cols).rstrip())
        if args.out:
            with open(args.out, "w", newline="") as fh:
                wr = csv.DictWriter(fh, fieldnames=cols)
                wr.writeheader()
                wr.writerows(rows)
            print(f"wrote {args.out}")
        return 0 if all(r["status"] == "ok" for r in rows) else 1
    elif args.cmd == "invite":
        for r in roster:
            if shared:
                say(r["student_id"], f"faig_workspace mode: {r['email']} is an existing account -- nothing to invite")
            else:
                invite_student(a, r, v["faig_base_url"])
    elif args.cmd == "approve":
        # Re-read the workspace ids every pass: the on-VM approver service
        # (cloud/faig_gcp/scripts/approver.sh) starts at boot, before `setup` has
        # created the workspaces on a rebuilt VM, and would otherwise watch none.
        wanted = {names(r["student_id"], shared)["workspace"] for r in roster}
        prefixes = tuple(f"{r['student_id']} " for r in roster) if shared else ()
        n = approve_pending(a, {w["id"] for w in a.workspaces() if w["workspaceName"] in wanted}, prefixes)
        while args.watch:
            time.sleep(args.interval)
            n += approve_pending(a, {w["id"] for w in a.workspaces() if w["workspaceName"] in wanted}, prefixes)
        print(f"approved {n} change(s)")
    elif args.cmd == "reset":
        if args.student:
            unknown = set(args.student) - {r["student_id"] for r in roster}
            if unknown:
                sys.exit(f"not on this FAIG's roster: {', '.join(sorted(unknown))}")
            roster = [r for r in roster if r["student_id"] in args.student]
        for r in roster:
            reset_student(a, r, v)
    elif args.cmd == "teardown":
        for r in roster:
            teardown_student(a, r, shared, keep_user=args.keep_users)
    return 0


if __name__ == "__main__":
    sys.exit(main())
