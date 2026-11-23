#!/usr/bin/env bash
set -uo pipefail

# Decide where every FAIG VM runs and HOLD its GPU there, so nothing downstream
# can STOCKOUT. The Makefile calls this; nobody should edit zones by hand.
#
#   gpu_place.sh                 place VMs, write placement.tfvars.json
#   gpu_place.sh --hold [N...]   hold the GPU of running VM(s) N in their zone
#                                (no N: every running VM without one; best effort)
#   gpu_place.sh --release [N..] delete the holds of VMs N, or (no N) of VMs that
#                                no longer exist, plus the old faig-gpu-hold
#   gpu_place.sh --release-all   delete every hold
#
# Why holds: a probe that creates and deletes a reservation hands the L4 back to
# the pool, and in a tight week it is gone 2-6 min later when terraform asks for
# it. A kept reservation is consumed by the VM (default affinity ANY matches an
# automatic reservation of the same shape in its zone), so create/start cannot
# STOCKOUT. GCP has no API that shows free GPUs per zone; trying to reserve is
# the only test, and a failed try is free.
#
# A hold costs nothing while its VM runs (the VM is what consumes it), so every
# running VM keeps one: a stop + start can then never STOCKOUT. It bills like a
# running VM only while its VM is stopped or missing, so stop.sh releases it
# (unless KEEP_GPU_HOLD=1), as do the nightly unreserve job and `make down`.
#
# Per VM n (1..vm_count), in place mode:
#   running             -> stays in its zone (zone is ForceNew: moving = replacing)
#   held (faig-n-hold)  -> goes where the hold is
#   stopped, targeted   -> claim in every zone from the FIRST tick, own zone
#                          ranked first. Own zone has an L4 -> it wins, no
#                          replacement. Only another zone has one -> keep that
#                          hold as a BACKUP and keep retrying the own zone for
#                          STAY_MIN; then move to the backup at once: terraform
#                          REPLACES the VM there (new disk from the baseline
#                          image -- student workspaces are lost; make up
#                          redeploys + relicenses, DNS follows). STAY_MIN=0:
#                          move on the first tick. FAIG_RELOCATE=0: own zone
#                          only, for up to RETRY_MIN.
#   stopped, untargeted -> stays put, nothing held
#   missing             -> claim anywhere
# "Claim" tries the hold in candidate zones in parallel batches of MAX_PARALLEL
# (0 = all at once), best-ranked first, stops launching batches once one
# succeeds, keeps the best-ranked winner and deletes the rest; retries every
# RETRY_SEC until RETRY_MIN runs out. Rank: the VM's own zone (stopped) or the
# zone gpu.tfvars prefers, then that region (keeps a regional static IP), then
# any zone matching GPU_REGIONS.
#
# Quota: every hold counts against NVIDIA_L4_GPUS (per region) and
# GPUS_ALL_REGIONS. If that quota is small, set MAX_PARALLEL to what is left
# (e.g. 1 = strictly sequential in rank order). If a whole round fails on quota
# alone, waiting will not help, so claim stops with an error instead of retrying.
#
# Interruption safety: every hold this run creates is tracked; on exit, Ctrl-C
# or kill, any it created but did not keep is deleted, so none are left billing.
#
# placement.tfvars.json gets vm_count + zones; the Makefile passes it after
# gpu.tfvars, so it wins. vm_count = COUNT if given, else the last placement,
# else gpu.tfvars -- and never below the highest targeted instance.
#
# MOVE="2": relocate VM 2 now to another zone (same path as a dry zone).
# Env: ONLY="1 3" (VMs to bring up; default all), COUNT, GPU_REGIONS (default
# us-), RETRY_MIN (30), STAY_MIN (10), RETRY_SEC (60), FAIG_RELOCATE (1),
# MAX_PARALLEL (0 = all)

cd "$(dirname "$0")/.."
GPU_REGIONS="${GPU_REGIONS:-us-}"
RETRY_MIN="${RETRY_MIN:-30}"
STAY_MIN="${STAY_MIN:-10}"
RETRY_SEC="${RETRY_SEC:-60}"
FAIG_RELOCATE="${FAIG_RELOCATE:-1}"
MAX_PARALLEL="${MAX_PARALLEL:-0}"
OUT=placement.tfvars.json

tfvar() { sed -nE "s/^$1[[:space:]]*=[[:space:]]*\"?([^\"#]*[^\"#[:space:]])\"?.*/\1/p" "$2" 2>/dev/null | head -1; }
PROJECT=$(tfvar project_id terraform.tfvars)
PROJECT=${PROJECT:-$(gcloud config get-value project 2>/dev/null)}
PREFIX=$(tfvar name_prefix terraform.tfvars); PREFIX=${PREFIX:-faig}
MACHINE=$(tfvar machine_type gpu.tfvars)
GPU=$(tfvar gpu_type gpu.tfvars)
DEFAULT_ZONE=$(tfvar zone gpu.tfvars)
: "${MACHINE:?machine_type missing from gpu.tfvars}" "${GPU:?gpu_type missing from gpu.tfvars}"
# zones = ["a", "b"] -> one per line
WANT_ZONES=$(sed -nE 's/^zones[[:space:]]*=[[:space:]]*\[([^]]*)\].*/\1/p' gpu.tfvars | tr -d '" ' | tr ',' '\n')
LAST_COUNT=$(python3 -c "import json; print(json.load(open('$OUT')).get('vm_count',''))" 2>/dev/null)
VM_COUNT=${COUNT:-${LAST_COUNT:-$(tfvar vm_count gpu.tfvars)}}
VM_COUNT=${VM_COUNT:-1}
for n in ${ONLY:-}; do [ "$n" -gt "$VM_COUNT" ] && VM_COUNT=$n; done

hold() { echo "$PREFIX-$1-hold"; }
want_zone() { local z; z=$(echo "$WANT_ZONES" | sed -n "${1}p"); echo "${z:-$DEFAULT_ZONE}"; }
moving() { case " ${MOVE:-} " in *" $1 "*) return 0 ;; esac; return 1; }
targeted() { [ -z "${ONLY:-}" ] && return 0; case " $ONLY " in *" $1 "*) return 0 ;; esac; return 1; }

# One listing of each, not a gcloud call per VM.
VMS=$(gcloud compute instances list --project "$PROJECT" --filter="name~^$PREFIX-[0-9]+\$" \
  --format='value(name,zone.basename(),status)' 2>/dev/null)
HOLDS=$(gcloud compute reservations list --project "$PROJECT" --filter="name~^$PREFIX-" \
  --format='value(name,zone.basename())' 2>/dev/null)
vm_zone()   { echo "$VMS" | awk -v n="$PREFIX-$1" '$1==n {print $2}'; }
vm_status() { echo "$VMS" | awk -v n="$PREFIX-$1" '$1==n {print $3}'; }
hold_zone() { echo "$HOLDS" | awk -v n="$(hold "$1")" '$1==n {print $2}'; }

new_hold() {  # new_hold <n> <zone> [errfile]: 0 = held
  gcloud compute reservations create "$(hold "$1")" --project "$PROJECT" --zone "$2" \
    --vm-count 1 --machine-type "$MACHINE" --accelerator "count=1,type=$GPU" >/dev/null 2>"${3:-/dev/null}"
}
drop() {  # drop <name> <zone>
  gcloud compute reservations delete "$1" --project "$PROJECT" --zone "$2" --quiet >/dev/null 2>&1 &&
    echo "released $1 ($2)" || echo "WARNING: could not delete $1 in $2 -- it bills like a running VM" >&2
}

case "${1:-}" in
  --release-all)
    echo "$HOLDS" | while read -r name zone; do
      case "$name" in "$PREFIX"-*-hold|"$PREFIX"-gpu-hold) drop "$name" "$zone" ;; esac
    done
    exit 0 ;;
  --release)
    shift
    # faig-gpu-hold is the old single-zone hold; per-VM holds replace it.
    lz=$(echo "$HOLDS" | awk -v n="$PREFIX-gpu-hold" '$1==n {print $2}')
    [ -n "$lz" ] && drop "$PREFIX-gpu-hold" "$lz"
    if [ $# -gt 0 ]; then
      for n in "$@"; do hz=$(hold_zone "$n"); [ -n "$hz" ] && drop "$(hold "$n")" "$hz"; done
      exit 0
    fi
    # Orphans: a hold whose VM is gone (deleted, or vm_count shrank) only bills.
    echo "$HOLDS" | while read -r name zone; do
      case "$name" in "$PREFIX"-*-hold) ;; *) continue ;; esac
      n=${name#"$PREFIX"-}; n=${n%-hold}
      [ -z "$(vm_zone "$n")" ] && drop "$name" "$zone"
    done
    exit 0 ;;
  --hold)
    shift; rc=0; explicit=$#
    for n in ${*:-$(echo "$VMS" | awk '$3=="RUNNING" {print $1}' | sed "s/^$PREFIX-//")}; do
      z=$(vm_zone "$n")
      if [ -z "$z" ]; then echo "no VM $PREFIX-$n to hold for" >&2; rc=1; continue; fi
      [ -n "$(hold_zone "$n")" ] && { [ "$explicit" -gt 0 ] && echo "$(hold "$n") already held"; continue; }
      # The running VM attaches to the new hold, but creating one still needs a
      # free slot for a moment; in a dry zone that comes and goes, so retry briefly.
      ok=0
      for _ in 1 2 3 4 5 6; do new_hold "$n" "$z" && { ok=1; break; }; sleep 10; done
      if [ $ok = 1 ]; then echo "held $(hold "$n") in $z (free while $PREFIX-$n runs)"
      else echo "WARNING: could not hold $PREFIX-$n's GPU in $z yet (its zone is dry); next make up retries" >&2; rc=1; fi
    done
    [ "$explicit" -gt 0 ] && exit $rc
    exit 0 ;;
esac

CANDIDATES=$(gcloud compute accelerator-types list --project "$PROJECT" \
  --filter="name=$GPU AND zone~zones/$GPU_REGIONS" --format='value(zone.basename())' 2>/dev/null | sort)
[ -z "$CANDIDATES" ] && { echo "no zone matching '$GPU_REGIONS*' offers $GPU" >&2; exit 1; }

ranked() {  # candidate zones, best first, for VM n (never $AVOID); $PREFER overrides the top zone
  local w r; w=${PREFER:-$(want_zone "$1")}; r=${w%-*}
  { echo "$CANDIDATES" | grep -x "$w"; echo "$CANDIDATES" | grep "^$r-" | grep -vx "$w"; echo "$CANDIDATES" | grep -v "^$r-"; } |
    sed '/^$/d' | grep -vx "${AVOID:-^}"
}
AVOID=""; PREFER=""

TMP=$(mktemp -d)
# pending-<zone> holds the VM number of a hold this run may have created and
# not yet kept. Anything still pending at exit is deleted.
CLEANED=0
cleanup() {
  [ "$CLEANED" = 1 ] && return; CLEANED=1
  wait 2>/dev/null
  local f z
  for f in "$TMP"/pending-*; do
    [ -f "$f" ] || continue
    z=${f##*/pending-}
    gcloud compute reservations delete "$(hold "$(cat "$f")")" --project "$PROJECT" --zone "$z" \
      --quiet >/dev/null 2>&1 && echo "cleanup: released unkept $(hold "$(cat "$f")") ($z)" >&2
  done
  rm -rf "$TMP"
}
trap cleanup EXIT
trap 'echo "interrupted -- releasing unkept holds" >&2; cleanup; exit 130' INT TERM

attempt() {  # attempt <n> <zone>: runs in the background
  echo "$1" > "$TMP/pending-$2"
  if new_hold "$1" "$2" "$TMP/err-$2"; then touch "$TMP/ok-$2"; else rm -f "$TMP/pending-$2"; fi
}
launch() {  # launch <n> <zone...>: attempt all in parallel, wait
  local n=$1 z; shift
  for z in "$@"; do attempt "$n" "$z" & done
  wait
}
any_ok() { compgen -G "$TMP/ok-*" >/dev/null; }

# claim_round <n> <zone...>: ONE try of the hold in ranked batches, keep the
# best-ranked winner, delete the rest. Prints the zone. On failure writes the
# why to $TMP/why (+ $TMP/other): rc 1 = no L4 (retry), rc 2 = quota only.
claim_round() {
  local n=$1 z win="" q=0 s=0 o=0 other="" batch=(); shift
  rm -f "$TMP"/ok-* "$TMP"/err-* "$TMP/why" "$TMP/other"
  for z in "$@"; do
    batch+=("$z")
    if [ "$MAX_PARALLEL" -gt 0 ] && [ "${#batch[@]}" -ge "$MAX_PARALLEL" ]; then
      launch "$n" "${batch[@]}"; batch=()
      any_ok && break
    fi
  done
  [ "${#batch[@]}" -gt 0 ] && ! any_ok && launch "$n" "${batch[@]}"
  for z in "$@"; do
    [ -f "$TMP/ok-$z" ] || continue
    if [ -z "$win" ]; then win=$z; rm -f "$TMP/pending-$z"
    else drop "$(hold "$n")" "$z" >&2; rm -f "$TMP/pending-$z"; fi
  done
  [ -n "$win" ] && { echo "$win"; return 0; }
  # Why did each zone fail? Stockout passes; quota does not.
  for z in "$@"; do
    [ -s "$TMP/err-$z" ] || continue
    if grep -qiE 'quota' "$TMP/err-$z"; then q=$((q + 1))
    elif grep -qiE 'RESOURCE_POOL_EXHAUSTED|enough resources|stockout|currently unavailable' "$TMP/err-$z"; then s=$((s + 1))
    else o=$((o + 1)); other="$z: $(tr '\n' ' ' < "$TMP/err-$z" | cut -c1-200)"; fi
  done
  echo "$s stockout, $q quota, $o other" > "$TMP/why"
  [ -n "$other" ] && echo "$other" > "$TMP/other"
  [ "$q" -gt 0 ] && [ "$s" -eq 0 ] && [ "$o" -eq 0 ] && return 2
  return 1
}

until_hm() { date -r "$1" +%H:%M 2>/dev/null || date -d "@$1" +%H:%M; }
retry_note() {  # retry_note <n> <deadline> [what]: the per-tick line, to stderr
  local why; why=$(cat "$TMP/why" 2>/dev/null)
  echo "  $PREFIX-$1: no $GPU ${3:-yet}${why:+ ($why)}; retrying in ${RETRY_SEC}s (until $(until_hm "$2"))" >&2
  [ -s "$TMP/other" ] && echo "    other error -- $(cat "$TMP/other")" >&2
  return 0
}
quota_error() {
  echo "ERROR: $PREFIX-$1: every attempt hit GPU quota. Waiting will not fix this:" >&2
  echo "  check NVIDIA_L4_GPUS / GPUS_ALL_REGIONS (gcloud compute project-info describe), release stray holds, or raise the quota" >&2
}

# claim <n> <minutes> <zone...>: claim_round until one wins or the minutes run
# out. Prints the zone. rc 1 = stockout everywhere, rc 2 = blocked by quota.
claim() {
  local n=$1 mins=$2 deadline win rc; shift 2
  deadline=$(( $(date +%s) + mins * 60 ))
  while :; do
    win=$(claim_round "$n" "$@"); rc=$?
    [ $rc = 0 ] && { echo "$win"; return 0; }
    [ $rc = 2 ] && { quota_error "$n"; return 2; }
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    retry_note "$n" "$deadline"
    sleep "$RETRY_SEC"
  done
}

# claim_stay <n> <own-zone>: for a stopped VM. Race every zone from the first
# tick, own zone ranked first. Own zone wins -> keep it (no replacement). Only
# another zone wins -> keep that hold as a BACKUP and keep retrying the own zone
# until STAY_MIN runs out, then move to the backup at once (no second search).
# The backup bills like a running VM for at most STAY_MIN. Prints the zone.
claim_stay() {
  local n=$1 vz=$2 now stay_end find_end backup="" win rc
  now=$(date +%s); stay_end=$(( now + STAY_MIN * 60 )); find_end=$(( now + RETRY_MIN * 60 ))
  while :; do
    if [ -z "$backup" ]; then
      # shellcheck disable=SC2046
      win=$(claim_round "$n" $(PREFER=$vz ranked "$n")); rc=$?
      [ $rc = 2 ] && { quota_error "$n"; return 1; }
      if [ $rc = 0 ]; then
        [ "$win" = "$vz" ] && { echo "$win"; return 0; }
        backup=$win
        # Unkept until used: Ctrl-C during the wait must release it too.
        echo "$n" > "$TMP/pending-$backup"
        [ "$STAY_MIN" -gt 0 ] &&
          echo "  $vz has no $GPU yet: backup hold in $backup; retrying $vz until $(until_hm "$stay_end")" >&2
      fi
    else
      win=$(claim_round "$n" "$vz"); rc=$?
      if [ $rc = 0 ]; then
        drop "$(hold "$n")" "$backup" >&2; rm -f "$TMP/pending-$backup"
        echo "$win"; return 0
      fi
      # The backup can use up the quota the own zone needs (same region, or
      # GPUS_ALL_REGIONS): then waiting cannot help, so take the backup now.
      if [ $rc = 2 ]; then
        echo "  $vz blocked by quota while the backup holds a $GPU: moving to $backup now" >&2
        rm -f "$TMP/pending-$backup"; echo "$backup"; return 0
      fi
    fi
    now=$(date +%s)
    if [ -n "$backup" ] && [ "$now" -ge "$stay_end" ]; then
      rm -f "$TMP/pending-$backup"; echo "$backup"; return 0
    fi
    [ -z "$backup" ] && [ "$now" -ge "$find_end" ] && {
      echo "ERROR: no $GPU in any '$GPU_REGIONS*' zone for $RETRY_MIN min. Retry, or widen: GPU_REGIONS= (all regions)" >&2
      return 1; }
    if [ -n "$backup" ]; then retry_note "$n" "$stay_end" "in $vz"; else retry_note "$n" "$find_end"; fi
    sleep "$RETRY_SEC"
  done
}

claim_anywhere() {
  local n=$1 z rc
  # shellcheck disable=SC2046
  z=$(claim "$n" "$RETRY_MIN" $(ranked "$n")); rc=$?
  if [ $rc = 1 ]; then
    echo "ERROR: no $GPU in any '$GPU_REGIONS*' zone for $RETRY_MIN min. Retry, or widen: GPU_REGIONS= (all regions)" >&2
  fi
  [ $rc = 0 ] || return 1
  echo "$z"
}

EXISTING=$(echo "$VMS" | awk 'NF' | wc -l | tr -d ' ')
[ "$EXISTING" -gt "$VM_COUNT" ] &&
  echo "WARNING: $EXISTING FAIG VMs exist but vm_count=$VM_COUNT: terraform will DELETE $PREFIX-$((VM_COUNT + 1))+" >&2

ZONES=()
for n in $(seq 1 "$VM_COUNT"); do
  vz=$(vm_zone "$n"); st=$(vm_status "$n"); hz=$(hold_zone "$n")
  # MOVE: relocate on demand (drain a zone before class) -- the same path a
  # stopped VM takes when its zone is dry, minus trying the own zone.
  if moving "$n" && [ -n "$vz" ] && { [ -z "$hz" ] || [ "$hz" = "$vz" ]; }; then
    [ -n "$hz" ] && drop "$(hold "$n")" "$hz" >/dev/null
    echo "$PREFIX-$n: MOVE requested -- leaving $vz (its disk is rebuilt from the baseline image)"
    AVOID=$vz
    z=$(claim_anywhere "$n") || exit 1
    AVOID=""
    [ "${z%-*}" != "${vz%-*}" ] && echo "  NOTE: new region: new static IP; the DNS name follows it"
    echo "  held $(hold "$n") in $z"
    ZONES+=("$z"); continue
  fi
  if [ -n "$hz" ]; then
    if [ -n "$vz" ] && [ "$hz" != "$vz" ]; then
      echo "$PREFIX-$n: held in $hz, VM in $vz -> terraform moves (replaces) it to $hz"
    else
      echo "$PREFIX-$n: GPU held in $hz"
    fi
    ZONES+=("$hz"); continue
  fi
  if [ "$st" = RUNNING ] || { [ -n "$vz" ] && ! targeted "$n"; }; then
    echo "$PREFIX-$n: ${st:-?} in $vz"; ZONES+=("$vz"); continue
  fi
  if [ -n "$vz" ]; then
    # Stopped and targeted.
    if [ "$FAIG_RELOCATE" = 0 ]; then
      echo "$PREFIX-$n: $st in $vz -- holding its GPU there only (FAIG_RELOCATE=0)..."
      if z=$(claim "$n" "$RETRY_MIN" "$vz"); then echo "  held $(hold "$n") in $z"; ZONES+=("$z"); continue; fi
      echo "ERROR: $vz has had no $GPU for $RETRY_MIN min and FAIG_RELOCATE=0" >&2; exit 1
    fi
    echo "$PREFIX-$n: $st in $vz -- claiming across $(PREFER=$vz ranked "$n" | wc -l | tr -d ' ') zones, own zone first (backup elsewhere for up to ${STAY_MIN} min)..."
    z=$(claim_stay "$n" "$vz") || exit 1
    if [ "$z" = "$vz" ]; then
      echo "  held $(hold "$n") in $z (own zone, no replacement)"
    else
      echo "  $vz dry: relocating $PREFIX-$n to $z (its disk is rebuilt from the baseline image)"
      [ "${z%-*}" != "${vz%-*}" ] && echo "  NOTE: new region: new static IP; the DNS name follows it"
    fi
    ZONES+=("$z"); continue
  fi
  echo "$PREFIX-$n: missing -- claiming $MACHINE + 1x $GPU across $(ranked "$n" | wc -l | tr -d ' ') zones (prefer $(want_zone "$n"))..."
  z=$(claim_anywhere "$n") || exit 1
  [ "${z%-*}" != "$(want_zone "$n" | sed 's/-[a-z]$//')" ] &&
    echo "  NOTE: outside $(want_zone "$n")'s region: new static IP; the DNS name follows it"
  echo "  held $(hold "$n") in $z"
  ZONES+=("$z")
done

python3 -c 'import json,sys; json.dump({"vm_count": int(sys.argv[2]), "zones": sys.argv[3:]}, open(sys.argv[1], "w"), indent=2)' \
  "$OUT" "$VM_COUNT" "${ZONES[@]}"
echo "placement: vm_count=$VM_COUNT zones=${ZONES[*]}"
