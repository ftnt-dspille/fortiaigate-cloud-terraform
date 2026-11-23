#!/usr/bin/env python3
"""FortiAIGate 8.0.2 control-plane client -- stdlib only.

8.0.2 replaced 8.0.1's model wholesale (Flows/Guards/scanners -> Policies/
Guardrails/Detectors, plus Workspaces, Users and Virtual Keys), so this is a new
client rather than a patch of the old 8.0.1 one.

The same class serves both roles in the workshop:
  * the INSTRUCTOR (org admin) -- `faig_class.py` builds each student's workspace,
  * a STUDENT (org_member + workspace admin) -- `guard_step.py` does the student's
    own clicks, so the walkthrough exercises exactly the permissions a student has.

Behaviour verified live on 8.0.2 (each one cost time to find):
  * Auth is session + CSRF only; API keys are for the data plane, never /api/v1/*.
  * Workspace objects are created as `draft` -> `submit` -> `pending` ->
    org-admin `approve` -> `active`. Editing an ACTIVE guardrail or detector
    applies immediately, with no re-approval.
  * A guardrail needs >= 1 detector.
  * A regex detector matches on the flat `rules` list; `regexRules` is only the
    editor's grouping. Sending `rules: []` stores fine and silently matches nothing.
  * DLP rule field is `disposition`, not `action`.
  * Custom-provider models are registered inside the provider body with
    `modelId` = the upstream model NAME and `isCustom: true`; the public name
    allows only letters, digits, `.`, `-`, `_`.
  * Users exist only via invitation; `POST /api/v1/invitations/{id}/accept` is
    unauthenticated and sets the password. FAIG sends no email.
  * A guardrail block on the gateway is HTTP 200 with finish_reason content_filter.
"""
from __future__ import annotations

import http.client
import http.cookiejar
import io
import json
import os
import re
import ssl
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any


# -- vars.yml loader (tiny, no yaml dep) --------------------------------------
def _parse_vars_yml(path: str) -> dict[str, str]:
    """Load a flat KEY: VALUE vars.yml (the ansible vars file). Stdlib only -- we
    do not depend on PyYAML for a flat file. Jinja templating ({{ }}) in values is
    resolved against already-parsed keys (single-pass, left-to-right)."""
    vals: dict[str, str] = {}
    with open(path) as fh:
        text = fh.read()
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#") or line.startswith("-") or ":" not in line:
            continue
        k, _, v = line.partition(":")
        k = k.strip()
        v = v.strip()
        # Trailing comments, as YAML reads them: a quoted value ends at its closing
        # quote; an unquoted one at " #". Keeping the comment turned a password
        # line with a note after it into a 55-char password and a "Login fail".
        if v[:1] in ('"', "'") and v.find(v[0], 1) > 0:
            v = v[1:v.find(v[0], 1)]
        else:
            v = re.split(r"\s+#", v, maxsplit=1)[0].strip()
        # resolve simple {{ var }} refs against already-seen keys
        for ref in re.findall(r"\{\{\s*(\w+)\s*\}\}", v):
            if ref in vals:
                v = v.replace(f"{{{{ {ref} }}}}", vals[ref]).replace(f"{{{{{ref}}}}}", vals[ref])
        vals[k] = v
    return vals


def _parse_env_file(path: str) -> dict[str, str]:
    """KEY=VALUE lines of a .env file, read as data -- never sourced, so a password
    with shell metacharacters survives intact."""
    vals: dict[str, str] = {}
    with open(os.path.expanduser(path)) as fh:
        for line in fh:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, _, v = line.partition("=")
                vals[k.strip()] = v.strip().strip('"').strip("'")
    return vals


def load_vars(paths: list[str]) -> dict[str, str]:
    """Merge vars files in order (later wins). `faig_credentials_env` names a .env
    file with FAIG_USERNAME / FAIG_PASSWORD (pyfortiaigate's format): on an
    always-on FAIG that one existing account is both the org admin and the
    "student", and its password stays in that file instead of being copied here.
    Keys already set in the vars files win."""
    v: dict[str, str] = {}
    for p in paths:
        v.update(_parse_vars_yml(p))
    if v.get("faig_credentials_env"):
        env = _parse_env_file(v["faig_credentials_env"])
        user, pw = env.get("FAIG_USERNAME"), env.get("FAIG_PASSWORD")
        if user and pw:
            v.setdefault("faig_admin_user", user)
            v.setdefault("faig_admin_pass", pw)
            # Only in faig_workspace mode is the admin ALSO the student (one
            # existing account). In create/teardown mode the student is a
            # separate user whose password is lab_password.
            if v.get("faig_workspace"):
                v.setdefault("student_email", user)
                v.setdefault("student_pass", pw)
    return v

# Invitable org roles (8.0.2 rejects plain "member").
ROLE_MEMBER = "org_member"

# Review-queue `type` -> the admin approve/reject path segment.
QUEUE_KIND = {"guardrail": "guardrails", "detector": "detectors", "policy": "policies"}


class FaigError(RuntimeError):
    def __init__(self, method: str, path: str, status: int, body: str):
        super().__init__(f"{method} {path} -> HTTP {status}: {body[:400]}")
        self.status = status
        self.body = body


class _Resp(io.BytesIO):
    def __init__(self, status: int, body: bytes):
        super().__init__(body)
        self.status = status

    def __enter__(self): return self
    def __exit__(self, *a): return False


class _KeepAliveOpener:
    """urllib's `opener.open(req, timeout)` contract on ONE reused HTTPS connection.

    urllib opens a new connection per request. From some networks a new TCP
    connect costs 1.5-2s while a request on an open connection is ~0.1s, and a
    student setup is ~30 requests (each mutation also fetches a CSRF token), so a
    class setup spent most of its time connecting. Errors keep urllib's shape for
    `_raw`'s retry rules: a failed connect or send is a URLError (never answered),
    a drop while waiting for the response is raised as-is (may have landed), and
    an HTTP status >= 400 is an HTTPError carrying the body."""

    IDLE = 30.0  # reopen rather than reuse a connection the server may have idled out

    def __init__(self, ctx: ssl.SSLContext, jar: http.cookiejar.CookieJar):
        self._ctx, self._jar = ctx, jar
        self._conn: http.client.HTTPSConnection | None = None
        self._key: tuple | None = None
        self._last = 0.0
        # One connection, so one request at a time: score_class shares this client
        # across worker threads, and an interleaved _close() left another thread's
        # _conn None mid-request ("'NoneType' object has no attribute 'request'").
        self._lock = threading.RLock()

    def _close(self) -> None:
        if self._conn:
            self._conn.close()
        self._conn = None

    def open(self, req: urllib.request.Request, timeout: float = 60):
        with self._lock:
            return self._open(req, timeout)

    def _open(self, req: urllib.request.Request, timeout: float):
        u = urllib.parse.urlsplit(req.full_url)
        key = (u.hostname, u.port or 443)
        if self._conn and (key != self._key or time.monotonic() - self._last > self.IDLE):
            self._close()
        try:
            if not self._conn:
                self._conn = http.client.HTTPSConnection(*key, context=self._ctx, timeout=timeout)
                self._key = key
                self._conn.connect()
            self._jar.add_cookie_header(req)
            path = u.path + (f"?{u.query}" if u.query else "")
            self._conn.request(req.get_method(), path, body=req.data, headers=dict(req.header_items()))
        except (OSError, http.client.HTTPException) as e:
            self._close()
            raise urllib.error.URLError(e) from e
        try:
            resp = self._conn.getresponse()
            body = resp.read()
        except BaseException:
            self._close()
            raise
        self._last = time.monotonic()
        self._jar.extract_cookies(resp, req)
        if resp.will_close:
            self._close()
        if resp.status >= 400:
            raise urllib.error.HTTPError(req.full_url, resp.status, resp.reason, resp.msg, io.BytesIO(body))
        return _Resp(resp.status, body)


class Faig802:
    """Session-authenticated 8.0.2 client. `user` is the login name: `admin` for
    the built-in org admin, the email address for invited users."""

    def __init__(self, base_url: str, user: str | None = None, password: str | None = None):
        # cloud/faig_gcp/scripts/faig_api.sh sets FAIG_API_URL to an IAP tunnel to
        # the live VM, so every admin/student call from this machine goes there:
        # no allowlist entry needed, and a rebuilt VM's new IP is picked up.
        self.base_url = (os.environ.get("FAIG_API_URL") or base_url).rstrip("/")
        self._ctx = ssl.create_default_context()
        self._ctx.check_hostname = False
        self._ctx.verify_mode = ssl.CERT_NONE  # workshop FAIG serves a self-signed cert
        self._jar = http.cookiejar.CookieJar()
        self._opener = _KeepAliveOpener(self._ctx, self._jar)
        self._creds: tuple[str, str] | None = None
        if user:
            self.login(user, password or "")

    @classmethod
    def admin_from_vars(cls, path: str) -> "Faig802":
        v = _parse_vars_yml(path)
        return cls(v["faig_base_url"], v.get("faig_admin_user", "admin"), v["faig_admin_pass"])

    # -- transport -------------------------------------------------------------
    # The IAP tunnel (FAIG_API_URL) now and then resets a new connection, often
    # mid-TLS-handshake; one reset used to abort a whole class setup. A URLError
    # means the request was never answered, so it is retried for every method. A
    # drop AFTER the request went out is retried only for GET: a POST may have
    # already landed.
    RETRIES = 5

    def _raw(self, method: str, path: str, body: Any = None, headers: dict | None = None) -> tuple[int, str]:
        data = None if body is None else json.dumps(body).encode()
        hdrs = {"Content-Type": "application/json", **(headers or {})}
        for attempt in range(self.RETRIES + 1):
            req = urllib.request.Request(self.base_url + path, data=data, headers=hdrs, method=method)
            try:
                with self._opener.open(req, timeout=60) as resp:
                    return resp.status, resp.read().decode(errors="replace")
            except urllib.error.HTTPError as e:
                return e.code, e.read().decode(errors="replace")
            except urllib.error.URLError as e:
                err: Exception = e
            except (http.client.RemoteDisconnected, ConnectionResetError, TimeoutError) as e:
                if method != "GET":
                    raise
                err = e
            if attempt == self.RETRIES:
                raise err
            wait = 2 ** attempt
            print(f"  {method} {path}: {err}; retry {attempt + 1}/{self.RETRIES} in {wait}s",
                  file=sys.stderr)
            time.sleep(wait)
        raise AssertionError("unreachable")

    def _send(self, method: str, path: str, body: Any) -> tuple[int, str]:
        headers = {}
        if method != "GET":
            # CSRF tokens are short-lived: fetch one per mutation rather than caching.
            st, txt = self._raw("GET", "/api/csrf-token")
            if st != 200:
                return st, txt
            headers["X-CSRF-Token"] = json.loads(txt)["csrf_token"]
        return self._raw(method, path, body, headers)

    def _call(self, method: str, path: str, body: Any = None) -> Any:
        st, txt = self._send(method, path, body)
        if st == 401 and self._creds:
            # The session expires (~24 min on 8.0.2): the on-VM approver died on it
            # every half hour. A 401 means nothing was applied, so log in and resend.
            self.login(*self._creds)
            st, txt = self._send(method, path, body)
        if st >= 400:
            raise FaigError(method, path, st, txt)
        return json.loads(txt) if txt.strip() else None

    def get(self, path: str) -> Any:
        return self._call("GET", path)

    def post(self, path: str, body: Any = None) -> Any:
        return self._call("POST", path, {} if body is None else body)

    def put(self, path: str, body: Any) -> Any:
        return self._call("PUT", path, body)

    def delete(self, path: str) -> Any:
        return self._call("DELETE", path)

    def login(self, user: str, password: str) -> None:
        # /api/v1/login takes `username` = the EMAIL, for every account; it is the only
        # login invited users have. The legacy /api/login accepts just the built-in
        # admin by its bare name `admin` -- kept as a fallback for older vars files.
        st, txt = self._raw("POST", "/api/v1/login", {"username": user, "password": password})
        if st != 200:
            st2, _ = self._raw("POST", "/api/login", {"username": user, "password": password})
            if st2 != 200:
                raise FaigError("POST", "/api/v1/login", st, txt)
        self._creds = (user, password)

    # -- users & invitations (org admin) ---------------------------------------
    def users(self) -> list[dict]:
        r = self.get("/api/v1/admin/users")
        return r.get("items", r) if isinstance(r, dict) else r

    def user_by_email(self, email: str) -> dict | None:
        return next((u for u in self.users() if u.get("email", "").lower() == email.lower()), None)

    def invite(self, email: str, role: str = ROLE_MEMBER) -> dict:
        return self.post("/api/v1/admin/user-invitations", {"emails": [email], "orgRole": role})

    def accept_invite(self, invitation_id: str, email: str, password: str, display_name: str = "") -> Any:
        """Unauthenticated in the product; sent with no session cookie."""
        body = {"email": email, "password": password}
        if display_name:
            body["displayName"] = display_name
        st, txt = Faig802(self.base_url)._raw("POST", f"/api/v1/invitations/{invitation_id}/accept", body)
        if st >= 400:
            raise FaigError("POST", f"/api/v1/invitations/{invitation_id}/accept", st, txt)
        return json.loads(txt) if txt.strip() else None

    def delete_user(self, user_id: str) -> Any:
        return self.delete(f"/api/v1/admin/users/{user_id}")

    def make_workspace_admin(self, user_id: str, ws_id: str) -> dict:
        """The admin user-update call replaces the user's workspace list, so keep
        any existing memberships and add this one."""
        u = self.get(f"/api/v1/admin/users/{user_id}")
        keep = [{"workspaceId": w["workspaceId"], "role": w.get("membershipRole", "workspace_member")}
                for w in u.get("workspaces") or [] if w["workspaceId"] != ws_id]
        # `orgRole` in a GET is the EFFECTIVE role (workspace_admin once they admin a
        # workspace); `orgRoleStored` is the real org role -- send that back.
        return self.put(f"/api/v1/admin/users/{user_id}", {
            "email": u["email"], "fullName": u.get("fullName") or u["email"],
            "orgRole": u.get("orgRoleStored") or u["orgRole"],
            "workspaces": keep + [{"workspaceId": ws_id, "role": "workspace_admin"}],
        })

    # -- workspaces ------------------------------------------------------------
    def workspaces(self) -> list[dict]:
        r = self.get("/api/v1/admin/workspaces")
        return r.get("items", r) if isinstance(r, dict) else r

    def workspace_by_name(self, name: str) -> dict | None:
        return next((w for w in self.workspaces() if w.get("workspaceName") == name), None)

    def my_workspaces(self) -> list[dict]:
        r = self.get("/api/v1/me/workspaces")
        return r.get("items", r) if isinstance(r, dict) else r

    def create_workspace(self, name: str, admin_ids: list[str], provider_ids: list[str],
                         description: str = "") -> dict:
        """`admins` must be EXISTING user ids (a pending invitation cannot be one)."""
        return self.post("/api/v1/admin/workspaces", {
            "workspaceName": name, "description": description,
            "admins": [{"id": i} for i in admin_ids],
            "budget": None, "budgetCycle": "monthly",
            "providerAccess": [{"providerId": p, "allKeys": True, "allModels": True} for p in provider_ids],
        })

    def set_workspace_access(self, ws_id: str, grants: dict[str, list[str] | None],
                             budget: float | None = None, cycle: str = "monthly") -> bool:
        """Which providers and models a workspace may use, and its spend cap (USD per
        `cycle`; None is unlimited). `grants` maps a provider id to the model ids it
        allows, or None for all of them. Returns False when already set. The PUT
        wants the create shape plus `updatedAt` (PATCH is 405); a cap blocks the
        whole workspace with HTTP 402 once spend reaches it."""
        w = self.get(f"/api/v1/admin/workspaces/{ws_id}")
        models = {pid: {m["modelId"]: m["uuid"] for m in self.get(f"/api/v1/admin/ai-providers/{pid}")["models"]}
                  for pid in grants}
        access = []
        for pid, allow in grants.items():
            if allow is None:
                access.append({"providerId": pid, "allKeys": True, "allModels": True})
                continue
            missing = [m for m in allow if m not in models[pid]]
            if missing:
                raise FaigError("PUT", f"workspace {ws_id}", 422, f"{pid} has no model(s) {missing}")
            access.append({"providerId": pid, "allKeys": True, "allModels": False,
                           "models": [{"uuid": models[pid][m]} for m in allow]})
        have = {pa["providerId"]: (None if pa.get("allModels") else sorted(m["uuid"] for m in pa.get("models") or []))
                for pa in w.get("providerAccess") or []}
        want = {a["providerId"]: (None if a["allModels"] else sorted(m["uuid"] for m in a["models"])) for a in access}
        if have == want and w.get("budget") == budget and (budget is None or w.get("budgetCycle") == cycle):
            return False
        self.put(f"/api/v1/admin/workspaces/{ws_id}", {
            "updatedAt": w["updatedAt"], "workspaceName": w["workspaceName"],
            "description": w.get("description", ""), "admins": [{"id": a["id"]} for a in w.get("admins") or []],
            "budget": budget, "budgetCycle": cycle, "providerAccess": access,
        })
        return True

    def delete_workspace(self, ws_id: str) -> Any:
        return self.delete(f"/api/v1/admin/workspaces/{ws_id}")

    def workspace_members(self, ws_id: str) -> Any:
        return self.get(f"/api/v1/workspaces/{ws_id}/members")

    # -- detectors -------------------------------------------------------------
    def detectors(self, ws_id: str) -> list[dict]:
        r = self.get(f"/api/v1/workspaces/{ws_id}/detectors")
        return r.get("items", r) if isinstance(r, dict) else r

    def detector_by_name(self, ws_id: str, name: str) -> dict | None:
        return next((d for d in self.detectors(ws_id) if d.get("name") == name), None)

    def create_detector(self, ws_id: str, body: dict) -> dict:
        return self.post(f"/api/v1/workspaces/{ws_id}/detectors", body)

    def update_detector(self, ws_id: str, uuid: str, body: dict) -> dict:
        return self.put(f"/api/v1/workspaces/{ws_id}/detectors/{uuid}", body)

    def test_detector(self, ws_id: str, uuid: str, text: str) -> dict:
        return self.post(f"/api/v1/workspaces/{ws_id}/detectors/{uuid}/test", {"input": text})

    # -- guardrails / policies / keys ------------------------------------------
    def guardrail(self, gid: str) -> dict:
        return self.get(f"/api/v1/admin/guardrails/{gid}")

    def guardrails(self, ws_id: str) -> list[dict]:
        r = self.get(f"/api/v1/workspaces/{ws_id}/guardrails")
        return r.get("items", r) if isinstance(r, dict) else r

    def guardrail_by_name(self, ws_id: str, name: str) -> dict | None:
        return next((g for g in self.guardrails(ws_id) if g.get("name") == name), None)

    def create_guardrail(self, ws_id: str, name: str, detector_ids: list[str], description: str = "") -> dict:
        return self.post(f"/api/v1/workspaces/{ws_id}/guardrails", guardrail_body(name, detector_ids, description))

    def update_guardrail(self, ws_id: str, gid: str, name: str, detector_ids: list[str], description: str = "") -> dict:
        return self.put(f"/api/v1/workspaces/{ws_id}/guardrails/{gid}", guardrail_body(name, detector_ids, description))

    def policies(self, ws_id: str) -> list[dict]:
        r = self.get(f"/api/v1/workspaces/{ws_id}/policies")
        return r.get("items", r) if isinstance(r, dict) else r

    def policy_by_name(self, ws_id: str, name: str) -> dict | None:
        return next((p for p in self.policies(ws_id) if p.get("name") == name), None)

    def create_policy(self, ws_id: str, name: str, input_ids: list[str], output_ids: list[str],
                      provider_id: str | list[str] | None = None) -> dict:
        """`provider_id`: grant all of that provider's (or those providers') models; the
        workspace's own model list still limits them. Some 8.0.2 builds refuse a
        policy without it (422 "a policy must grant at least one model")."""
        body = {
            "name": name, "description": name,
            "inputGuardrailIds": input_ids, "outputGuardrailIds": output_ids,
            "responseScanMode": "post_stream",
        }
        if provider_id:
            ids = [provider_id] if isinstance(provider_id, str) else provider_id
            body["providerAccess"] = [{"providerId": p, "allModels": True} for p in ids]
        return self.post(f"/api/v1/workspaces/{ws_id}/policies", body)

    def set_model_price(self, provider_id: str, input_cost: float, output_cost: float) -> bool:
        """Custom price, USD per 1M tokens, on every model of a provider. Returns False when
        it was already set. The only write is a PUT of the whole provider (PATCH is 405),
        shaped as the UI sends it: API keys by id with no credential, so the stored secret
        is kept, and `updatedAt` for the server's concurrency check."""
        path = f"/api/v1/admin/ai-providers/{provider_id}"
        d = self.get(path)
        if all(m.get("customizedCost") and m.get("customInputCost") == input_cost
               and m.get("customOutputCost") == output_cost for m in d["models"]):
            return False
        self.put(path, {
            "providerId": d["providerId"], "platform": d["platform"], "name": d["name"],
            "endpoint": d["endpoint"], "description": d.get("description"),
            "autoSyncNewModels": d.get("autoSyncNewModels", False),
            "apiKeys": [{k: key[k] for k in ("id", "name", "description", "enabled", "weight")}
                        for key in d["apiKeys"]],
            "models": [{"uuid": m["uuid"], "modelId": m["modelId"], "publicName": m["publicName"],
                        "enabled": m["enabled"], "isCustom": bool(m["isCustom"]),
                        "description": m["description"], "customizedCost": True,
                        "customInputCost": input_cost, "customOutputCost": output_cost,
                        "customCacheReadCost": None, "customCacheWriteCost": None}
                       for m in d["models"]],
            "updatedAt": d["updatedAt"],
        })
        return True

    def ensure_provider(self, provider_id: str, platform: str, name: str, api_key: str,
                        model_ids: list[str], key_name: str = "workshop") -> bool:
        """Create a provider (e.g. OpenAI) with one upstream key and only `model_ids`
        enabled. Returns False when it already exists: its key and models are then
        left as they are (rotate the key in the UI)."""
        if any(p.get("providerId") == provider_id for p in self._items(self.get("/api/v1/admin/ai-providers"))):
            return False
        self.post("/api/v1/admin/ai-providers", {
            "providerId": provider_id, "platform": platform, "name": name,
            "endpoint": {"kind": "none"}, "description": "Workshop provider", "autoSyncNewModels": False,
            "apiKeys": [{"name": key_name, "description": None, "enabled": True, "weight": 1,
                         "credential": {"kind": "apiKey", "apiKey": api_key}}],
            "models": [{"modelId": m, "publicName": f"{provider_id}-{m}", "enabled": True,
                        "isCustom": False, "description": None, "customizedCost": False}
                       for m in model_ids],
        })
        return True

    @staticmethod
    def _items(r: Any) -> list[dict]:
        return r.get("items", r) if isinstance(r, dict) else r

    def virtual_keys(self, ws_id: str) -> list[dict]:
        r = self.get(f"/api/v1/workspaces/{ws_id}/virtual-keys")
        return r.get("items", r) if isinstance(r, dict) else r

    def create_virtual_key(self, ws_id: str, name: str, policy_ids: list[str], provider_id: str,
                           rpm_limit: int | None = None, tpm_limit: int | None = None) -> dict:
        """The secret (`secretKey`) is returned ONCE, here, and never again."""
        body: dict[str, Any] = {
            "keyName": name, "policyIds": policy_ids,
            "providerAccess": [{"providerId": provider_id, "allKeys": True, "allModels": True}],
        }
        if rpm_limit is not None:
            body["rpm"] = int(rpm_limit)
        if tpm_limit is not None:
            body["tpm"] = int(tpm_limit)
        return self.post(f"/api/v1/workspaces/{ws_id}/virtual-keys", body)

    def revoke_virtual_key(self, ws_id: str, key_id: str, reason: str) -> Any:
        """Mark a key revoked; the secret stops working immediately."""
        return self.post(f"/api/v1/workspaces/{ws_id}/virtual-keys/{key_id}/revoke",
                         {"reason": reason})

    # -- approval (org admin) ---------------------------------------------------
    def submit(self, ws_id: str, kind: str, obj_id: str) -> Any:
        """kind: detectors | guardrails | policies"""
        return self.post(f"/api/v1/workspaces/{ws_id}/{kind}/{obj_id}/submit")

    def approve(self, kind: str, obj_id: str) -> Any:
        return self.post(f"/api/v1/admin/{kind}/{obj_id}/approve")

    def reject(self, kind: str, obj_id: str, reason: str = "reset by instructor") -> Any:
        return self.post(f"/api/v1/admin/{kind}/{obj_id}/reject", {"reason": reason})

    def delete_virtual_key(self, key_id: str) -> Any:
        return self.delete(f"/api/v1/admin/virtual-keys/{key_id}")

    def review_queue(self) -> list[dict]:
        r = self.get("/api/v1/admin/review-queue")
        return r.get("items", r) if isinstance(r, dict) else r

    # -- observability -----------------------------------------------------------
    def workspace_analytics(self, ws_id: str) -> Any:
        return self.get(f"/api/v1/workspaces/{ws_id}/analytics?period=last_24h")


# -- body builders ---------------------------------------------------------------
def guardrail_body(name: str, detector_ids: list[str], description: str = "") -> dict:
    if not detector_ids:
        raise ValueError("an 8.0.2 guardrail needs at least one detector")
    return {"name": name, "description": description or name,
            "detectorIds": detector_ids, "denySuspiciousCharacters": False}


def regex_detector_body(name: str, rules: list[tuple[str, str, str]], description: str = "") -> dict:
    """rules: [(rule_name, pattern, disposition)]. Fills BOTH `regexRules` (editor
    grouping) and the flat `rules` list the engine actually matches on."""
    regex_rules = [
        {"id": f"r{i}", "name": rn, "enabled": True, "description": rn,
         "conditions": [{"id": f"c{i}", "pattern": pat, "disposition": disp}]}
        for i, (rn, pat, disp) in enumerate(rules, 1)
    ]
    return {
        "name": name, "description": description or name,
        "inputGuards": ["Regex patterns"], "outputGuards": ["Regex patterns"],
        "sensitivity": None, "detectorType": "regex", "managedEngine": None, "action": None,
        "aiRules": None, "regexRules": regex_rules,
        "rules": [c for r in regex_rules if r["enabled"] for c in r["conditions"]],
    }


def ai_detector_body(name: str, rules: list[tuple], action: str = "block",
                     description: str = "") -> dict:
    """A Natural Language detector. rules: ``[(rule_name, violate_if)]`` or
    ``[(rule_name, violate_if, exempt_if)]``, where each ``if`` is one string
    or a list of them. The engine judges text against plain-language rules."""
    ai_rules = []
    for i, rule in enumerate(rules, 1):
        rn = rule[0]
        violate = rule[1]
        exempt = rule[2] if len(rule) > 2 else []
        violate_if = [violate] if isinstance(violate, str) else list(violate)
        exempt_if = [exempt] if isinstance(exempt, str) else list(exempt)
        if not violate_if:
            raise ValueError(f"NL rule {rn!r}: at least one violate_if is required")
        ai_rules.append({
            "id": f"r{i}", "name": rn, "enabled": True, "description": rn,
            "violateIf": violate_if, "exemptIf": exempt_if,
            "conditions": [{"id": f"c{i}-{j}", "description": t} for j, t in enumerate(violate_if, 1)],
        })
    return {
        "name": name, "description": description or name,
        "inputGuards": ["AI descriptions"], "outputGuards": ["AI descriptions"],
        "sensitivity": None, "detectorType": "ai", "managedEngine": None, "action": action,
        "regexRules": None, "aiRules": ai_rules,
        "rules": [c for r in ai_rules for c in r["conditions"]],
    }


def dlp_detector_body(name: str, categories: list[str], disposition: str = "block",
                      threshold: float = 0.7, description: str = "") -> dict:
    """categories: DLP label names as /api/v1/admin/dlp-labels spells them."""
    return {
        "name": name, "description": description or name,
        "inputGuards": list(categories), "outputGuards": list(categories),
        "sensitivity": None, "detectorType": "managed", "managedEngine": "dlp", "action": None,
        "regexRules": None, "aiRules": None,
        "rules": [{"id": f"d{i}", "category": c, "disposition": disposition, "threshold": threshold}
                  for i, c in enumerate(categories)],
    }


def approve_new(admin: Faig802, ws_id: str, kind: str, obj: dict) -> dict:
    """Walk a freshly created workspace object draft -> pending -> active."""
    oid = obj.get("uuid") or obj["id"]
    status = obj.get("approvalStatus") or obj.get("status")
    if status == "draft":
        admin.submit(ws_id, kind, oid)
        status = "pending"
    if status == "pending":
        try:
            return admin.approve(kind, oid)
        except FaigError as e:
            # The on-VM auto-approver (cloud/faig_gcp/scripts/approver.sh) runs during
            # setup and can approve it first; then it is no longer pending.
            if e.status != 409 or "pending submission" not in e.body:
                raise
    return obj
