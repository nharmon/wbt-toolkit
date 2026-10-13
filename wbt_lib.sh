#!/usr/bin/env bash
# wbt_lib.sh - shared helpers for the write-blocker test toolkit.
# Source this file; do not run it.

WBT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WBT_PY=(python3 -I "$WBT_DIR/wbt_hash.py")
WBT_ALLOW_FILE="${WBT_ALLOW_FILE:-0}"   # 1 = allow regular files as "drives" (self-test only)
MIB=$((1024 * 1024))
PASS_COUNT=0; FAIL_COUNT=0; REVIEW_COUNT=0; SKIP_COUNT=0
ORIG_RO=""
RUN_DIR=""; WBT_LOG=""; RESULTS_CSV=""

ts()   { date -u +%Y-%m-%dT%H:%M:%SZ; }
log()  { local m; m="$(ts) $*"; echo "$m"; if [[ -n "$WBT_LOG" ]]; then echo "$m" >> "$WBT_LOG"; fi; return 0; }
die()  { echo "$(ts) FATAL: $*" >&2; if [[ -n "$WBT_LOG" ]]; then echo "$(ts) FATAL: $*" >> "$WBT_LOG"; fi; exit 2; }
have() { command -v "$1" >/dev/null 2>&1; }

need_root() {
  if [[ "$WBT_ALLOW_FILE" != "1" && "$EUID" -ne 0 ]]; then die "run as root (raw device access is required)"; fi
}

target_check() { # path
  local p="$1"
  [[ -e "$p" ]] || die "$p does not exist"
  if [[ -b "$p" ]]; then return 0; fi
  if [[ -f "$p" && "$WBT_ALLOW_FILE" == "1" ]]; then return 0; fi
  die "$p is not a block device (WBT_ALLOW_FILE=1 permits a regular file for self-tests only)"
}

# guard_reference DEV YES - refuse mounted / system disks; require typed confirmation unless YES=1
guard_reference() {
  local dev="$1" yes="${2:-0}" real rootsrc rootdisk ans
  target_check "$dev"
  real="$(readlink -f "$dev")"
  if [[ -b "$real" ]]; then
    if lsblk -nr -o MOUNTPOINT "$real" 2>/dev/null | grep -q .; then
      die "$dev (or one of its partitions) is mounted - unmount it first"
    fi
    rootsrc="$(findmnt -no SOURCE / 2>/dev/null || true)"
    if [[ -n "$rootsrc" ]]; then
      rootdisk="$(lsblk -no PKNAME "$rootsrc" 2>/dev/null | head -1)"
      if [[ -n "$rootdisk" && "/dev/$rootdisk" == "$real" ]]; then die "$dev holds the root filesystem - refusing"; fi
    fi
  fi
  if [[ "$yes" != "1" ]]; then
    echo
    echo "About to run WRITE ATTEMPTS against: $real"
    lsblk -o NAME,SIZE,MODEL,SERIAL,TRAN "$real" 2>/dev/null || ls -l "$real"
    echo "This must be a REFERENCE drive that holds no evidence and can be rebuilt from the baseline."
    [[ -t 0 ]] || die "not interactive: check the target, then pass --yes-reference"
    read -r -p "Type 'REFERENCE $(basename "$real")' to continue: " ans
    [[ "$ans" == "REFERENCE $(basename "$real")" ]] || die "confirmation not given"
  fi
}

init_run() { # name [outdir]
  local name="$1" out="${2:-}"
  RUN_DIR="${out:-$PWD/wbt-results/${name}-$(date -u +%Y%m%dT%H%M%SZ)}"
  mkdir -p "$RUN_DIR" || die "cannot create $RUN_DIR"
  WBT_LOG="$RUN_DIR/run.log"
  RESULTS_CSV="$RUN_DIR/results.csv"
  echo 'timestamp,test_id,phase_case,command_or_action,host_response,hash_before,hash_after,result,evidence' > "$RESULTS_CSV"
  log "run directory: $RUN_DIR"
  log "host: $(uname -srm); toolkit: $WBT_DIR"
}

csvq() { local s="${1//\"/\"\"}"; s="${s//$'\n'/ }"; printf '"%s"' "$s"; }

record_result() { # id case cmd response before after result evidence
  printf '%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$(csvq "$(ts)")" "$(csvq "$1")" "$(csvq "$2")" "$(csvq "$3")" \
    "$(csvq "$4")" "$(csvq "$5")" "$(csvq "$6")" "$(csvq "$7")" "$(csvq "${8:-}")" >> "$RESULTS_CSV"
  case "$7" in
    PASS*)   PASS_COUNT=$((PASS_COUNT + 1));;
    FAIL*)   FAIL_COUNT=$((FAIL_COUNT + 1));;
    SKIP*)   SKIP_COUNT=$((SKIP_COUNT + 1));;
    *)       REVIEW_COUNT=$((REVIEW_COUNT + 1));;
  esac
  log "[$7] $1 - $2"
}

summary() {
  log "SUMMARY: pass=$PASS_COUNT fail=$FAIL_COUNT review=$REVIEW_COUNT skipped=$SKIP_COUNT"
  log "results: $RESULTS_CSV"
}

dev_size() { "${WBT_PY[@]}" geometry "$1" --field size_bytes; }
dev_ss()   { "${WBT_PY[@]}" geometry "$1" --field logical_sector; }
wlen_for_ss() { local ss="$1"; if (( ss > 512 )); then echo $(( ss * 2 )); else echo 4096; fi; }

region_hash() { "${WBT_PY[@]}" hash "$1" --offset "$2" --length "$3" --field sha256 2>/dev/null; }
full_hash_value() { "${WBT_PY[@]}" hash "$1" --field sha256 2>/dev/null; }

# window OFF LEN SIZE -> "start length" with a 1 MiB margin each side, clamped to the device
window() {
  local off="$1" len="$2" size="$3" w0 w1
  w0=$(( off - MIB )); (( w0 < 0 )) && w0=0
  w1=$(( off + len + MIB )); (( w1 > size )) && w1=$size
  echo "$w0 $(( w1 - w0 ))"
}

flush_cache() { # dev
  sync
  if [[ -b "$1" ]] && have blockdev; then blockdev --flushbufs "$1" 2>/dev/null || true; fi
  if [[ "$EUID" -eq 0 && -w /proc/sys/vm/drop_caches ]]; then echo 3 > /proc/sys/vm/drop_caches 2>/dev/null || true; fi
}

# Signature of drive state that must not change (capacity, HPA, ATA identify/security, NVMe ns data).
state_sig() { # dev
  {
    if [[ -b "$1" ]] && have blockdev; then blockdev --getsize64 --getss "$1" 2>&1; fi
    if have hdparm; then hdparm -N "$1" 2>&1; hdparm -I "$1" 2>&1; fi
    if have nvme; then nvme id-ns "$1" 2>&1; fi
  } 2>&1 | sha256sum | cut -d' ' -f1
}

snapshot_state() { # dev outfile
  {
    echo "== $(ts) $1"
    lsblk -d -b -o NAME,SIZE,LOG-SEC,PHY-SEC,RO,MODEL,SERIAL,TRAN "$1" 2>&1
    if [[ -b "$1" ]] && have blockdev; then blockdev --getsize64 --getss --getpbsz --getro "$1" 2>&1; fi
    if have hdparm; then hdparm -N "$1" 2>&1; hdparm -I "$1" 2>&1; fi
    if have smartctl; then smartctl -i -A "$1" 2>&1; fi
    if have nvme; then nvme id-ns "$1" 2>&1; fi
  } > "$2" 2>&1
}

# Linux marks a drive read-only when the blocker reports write-protect, and then refuses writes
# before they ever reach the blocker. To test the blocker itself we clear that flag first.
force_rw() { # dev
  [[ -b "$1" ]] || return 0
  have blockdev || return 0
  ORIG_RO="$(blockdev --getro "$1" 2>/dev/null)"
  log "OS read-only flag on $1 was: ${ORIG_RO:-unknown}"
  if [[ "$ORIG_RO" == "1" ]]; then
    if blockdev --setrw "$1" 2>/dev/null; then
      log "cleared the OS read-only flag so the blocker, not the OS, is what stops the writes"
    else
      log "WARNING: could not clear the OS read-only flag; the OS may be stopping writes before the blocker sees them"
    fi
  fi
}
restore_ro() { # dev
  if [[ "$ORIG_RO" == "1" && -b "$1" ]]; then blockdev --setro "$1" 2>/dev/null || true; fi
  return 0
}

# attempt_writes DEV TAG - write at the first and last sectors with read-back; sets AW_SUMMARY, AW_APPLIED
AW_SUMMARY=""; AW_APPLIED=0
attempt_writes() {
  local dev="$1" tag="$2" size ss wlen off sum
  size="$(dev_size "$dev")"; ss="$(dev_ss "$dev")"; wlen="$(wlen_for_ss "$ss")"
  AW_SUMMARY=""; AW_APPLIED=0
  for off in 0 $(( size - wlen )); do
    sum="$("${WBT_PY[@]}" pwrite "$dev" --offset "$off" --length "$wlen" --readback \
           --json-out "${RUN_DIR:-.}/pwrite.jsonl" --tag "$tag" 2>&1)"
    AW_SUMMARY+="[off=$off $sum] "
    if [[ "$sum" == *"readback_shows_new_data=True"* ]]; then AW_APPLIED=1; fi
  done
}

# compare_and_record BASELINE RESULT_JSON CASE - run wbt_hash compare and record each P2-xx line
compare_and_record() {
  local base="$1" res="$2" case_name="$3" id st msg evid="$RUN_DIR/compare_$(basename "$2" .json).txt"
  "${WBT_PY[@]}" compare "$base" "$res" > "$evid" 2>&1 || true
  while IFS='|' read -r id st msg; do
    [[ -n "$id" && -n "$st" ]] || continue
    record_result "$id" "$case_name" "wbt_hash.py compare" "$msg" "" "" "$st" "$evid"
  done < "$evid"
}
