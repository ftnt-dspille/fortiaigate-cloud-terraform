#!/usr/bin/env bash
set -euo pipefail

# health.sh -- read-only system health of the k3s pods on each FortiAIGate VM.
#
# test.sh asks "is everything Running?"; this answers "is it healthy, and if not,
# which pod and why?". Per pod: ready, status, CPU/memory (metrics-server), and
# crashes SINCE THIS BOOT -- restartCount alone is useless here because every
# stop/start adds one to every pod. Per node: kubelet pressure conditions, disk,
# memory, GPU, recent Warning events, and the license-manager's scanning state
# (a licensed FAIG with a dead engine pod passes traffic UNSCANNED and says so
# only in that log).
#
# It never changes anything. Dead pods (AdmissionError/Unknown after a restart)
# are reported with the fix: `make start` heals them.
#
# Usage: health.sh [vm-name ...]   (defaults to every VM from Terraform)
# Exit:  0 healthy (warnings allowed), 1 any FAIL, 2 a VM unreachable.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/iap.sh"

if [ "$#" -gt 0 ]; then
  VM_NAMES="$*"
else
  VM_NAMES=$(terraform -chdir="$TF_DIR" output -json vm_names | python3 -c "import sys,json; [print(v) for v in json.load(sys.stdin)]")
fi

RC=0
for VM in $VM_NAMES; do
  ZONE="$(get_zone "$VM")"
  echo "=== $VM ==="
  STATUS="$(gcloud compute instances describe "$VM" --zone="$ZONE" --format='value(status)' 2>/dev/null || true)"
  if [ "$STATUS" != "RUNNING" ]; then
    echo "  FAIL: VM is ${STATUS:-unknown} -- start it with: make start"
    RC=1
    continue
  fi
  set +e
  gcloud compute ssh --tunnel-through-iap --zone="$ZONE" "$VM" --command='sudo python3 -' 2>/dev/null << 'REMOTE'
import json, re, shutil, subprocess, time
from datetime import datetime, timezone

def sh(*cmd):
    r = subprocess.run(cmd, capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else ""

def k(*args):
    return sh("k3s", "kubectl", *args)

fails, warns = [], []
boot = time.time() - float(open("/proc/uptime").read().split()[0])
SETTLE = 15 * 60  # restarts in the first minutes after boot are dependency ordering, not crashes

def ts(s):
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp() if s else 0

def mib(q):
    m = re.match(r"(\d+)(Ki|Mi|Gi)?", q or "0")
    n, u = int(m.group(1)), m.group(2)
    return n // 1024 if u == "Ki" else n * 1024 if u == "Gi" else n

usage = {}
for line in k("top", "pods", "-A", "--no-headers").splitlines():
    ns, pod, cpu, mem = line.split()[:4]
    usage[(ns, pod)] = (cpu, f"{mib(mem)}Mi")

pods = json.loads(k("get", "pods", "-A", "-o", "json") or '{"items": []}')["items"]
if not pods:
    fails.append("kubectl returned no pods -- is k3s up? (sudo systemctl status k3s)")

rows = []
for p in pods:
    ns, name = p["metadata"]["namespace"], p["metadata"]["name"]
    st = p.get("status", {})
    cs = st.get("containerStatuses", [])
    ready = sum(c.get("ready", False) for c in cs)
    status = st.get("reason") or st.get("phase", "?")
    for c in cs:
        w = c.get("state", {}).get("waiting")
        if w:
            status = w.get("reason", status)
    note = ""
    crashes = [c for c in cs
               if ts(c.get("lastState", {}).get("terminated", {}).get("finishedAt")) > boot + SETTLE]
    if st.get("phase") == "Succeeded":
        continue
    if status in ("UnexpectedAdmissionError", "Unknown", "Evicted", "Error") or st.get("reason") in ("UnexpectedAdmissionError", "Evicted"):
        note = "dead pod (fix: make start)"
        fails.append(f"{ns}/{name}: {status} -- make start deletes dead pods")
    elif ready < len(cs) or st.get("phase") != "Running":
        note = "not ready"
        fails.append(f"{ns}/{name}: {status}, {ready}/{len(cs)} ready")
    if crashes:
        t = crashes[0]["lastState"]["terminated"]
        ago = int((time.time() - ts(t.get("finishedAt"))) / 60)
        note = (note + "; " if note else "") + f"crashed {ago}m ago: {t.get('reason')} (exit {t.get('exitCode')})"
        (fails if t.get("reason") == "OOMKilled" else warns).append(f"{ns}/{name}: {note}")
    cpu, mem = usage.get((ns, name), ("-", "-"))
    rows.append((ns, name, f"{ready}/{len(cs)}", status, cpu, mem, note))

w = [max(len(str(r[i])) for r in rows + [("NAMESPACE", "POD", "READY", "STATUS", "CPU", "MEM", "")]) for i in range(6)]
print("  " + "  ".join(h.ljust(w[i]) for i, h in enumerate(("NAMESPACE", "POD", "READY", "STATUS", "CPU", "MEM"))) + "  NOTE")
for r in sorted(rows):
    print("  " + "  ".join(str(r[i]).ljust(w[i]) for i in range(6)) + "  " + r[6])

print()
up = int((time.time() - boot) / 60)
print(f"  node up {up // 60}h{up % 60:02d}m")
for node in json.loads(k("get", "nodes", "-o", "json") or '{"items": []}')["items"]:
    nn = node["metadata"]["name"]
    for c in node["status"]["conditions"]:
        bad = c["status"] != ("True" if c["type"] == "Ready" else "False")
        if bad:
            fails.append(f"node {nn}: {c['type']}={c['status']} ({c.get('message', '')})")
    gpu = node["status"].get("allocatable", {}).get("nvidia.com/gpu", "0")
    if gpu == "0":
        fails.append(f"node {nn}: no allocatable nvidia.com/gpu -- the device plugin lost the GPU")
    print(f"  node {nn}: allocatable GPU {gpu}")

d = shutil.disk_usage("/")
pct = d.used * 100 // d.total
print(f"  disk /: {pct}% used, {d.free // 2**30}G free")
if pct >= 75:
    (fails if pct >= 85 else warns).append(f"disk / {pct}% used")

mem = {l.split(":")[0]: int(l.split()[1]) for l in open("/proc/meminfo")}
avail = mem["MemAvailable"] // 1024
print(f"  memory: {avail}Mi available of {mem['MemTotal'] // 1024}Mi")
if avail < 2048:
    warns.append(f"memory: only {avail}Mi available")

g = sh("nvidia-smi", "--query-gpu=name,memory.used,memory.total,utilization.gpu,temperature.gpu", "--format=csv,noheader,nounits").strip()
if g:
    name, used, total, util, temp = [x.strip() for x in g.split(",")]
    print(f"  GPU: {name}, {used}/{total} MiB, {util}% util, {temp}C")
    if int(temp) >= 85:
        warns.append(f"GPU temperature {temp}C")
else:
    fails.append("nvidia-smi failed -- GPU driver not loaded")

log = k("logs", "-n", "fortiaigate", "-l", "app=license-manager", "--tail=1000")
scan = sorted(l for l in log.splitlines() if re.search(r"scanning enabled|security scanning is disabled", l))
lic = sorted(l for l in log.splitlines() if re.search(r"valid_licences=|NO USABLE LICENCE", l))
scan_on = bool(scan) and "scanning enabled" in scan[-1]
lic_ok = bool(lic) and not re.search(r"NO USABLE LICENCE|valid_licences=0( |$)", lic[-1])
print(f"  license: {'active' if lic_ok else 'NOT active'}; guardrail scanning: {'enabled' if scan_on else 'DISABLED'}")
if not lic_ok:
    fails.append("license not active -- make license FILE=...")
if not scan_on:
    fails.append("guardrail scanning disabled -- traffic passes UNSCANNED; make start heals stale engine pods")

ev = json.loads(k("get", "events", "-A", "--field-selector", "type=Warning", "-o", "json") or '{"items": []}')["items"]
recent = [e for e in ev if ts(e.get("lastTimestamp") or e.get("eventTime")) > time.time() - 30 * 60]
if recent:
    print(f"  Warning events, last 30 min: {len(recent)}")
    for e in recent[-8:]:
        o = e["involvedObject"]
        print(f"    {o.get('namespace', '')}/{o['name']}: {e.get('reason')} - {e.get('message', '')[:120]}")

print()
for f in fails:
    print(f"  FAIL: {f}")
for x in warns:
    print(f"  WARN: {x}")
print(f"  Result: {'UNHEALTHY' if fails else 'healthy'} ({len(fails)} fail, {len(warns)} warn)")
raise SystemExit(1 if fails else 0)
REMOTE
  r=$?
  set -e
  if [ "$r" -eq 255 ]; then
    echo "  FAIL: no SSH to $VM over IAP"
    RC=2
  elif [ "$r" -ne 0 ] && [ "$RC" -eq 0 ]; then
    RC=1
  fi
  echo
done
exit "$RC"
