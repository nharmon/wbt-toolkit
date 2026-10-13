#!/usr/bin/env bash
# Phase 1 - write-protection tests (procedure section 4).
# Attempts every write-type command class it can against a REFERENCE drive connected through the
# device under test (DUT), then checks that nothing on the drive changed.
set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/wbt_lib.sh"

usage() {
  cat <<'EOF'
Usage: sudo ./01_phase1_write_protection.sh --dut DEVICE [options]

  --dut DEVICE        reference drive as seen THROUGH the write blocker (required)
  --baseline FILE     baseline JSON from 00_baseline.sh (used to pre-check the drive and for the final check)
  --direct DEVICE     the SAME drive on a second, unblocked path (rare: dual-port SAS, second host bay).
                      Without it, the script cannot trust what the DUT reports, so results are marked
                      REVIEW until you re-hash on the direct path with 05_verify_direct.sh.
  --destructive       also try SCSI UNMAP, ATA SET MAX (HPA), ATA security set-password, NVMe write-zeroes/deallocate
  --wipe-class        also try FORMAT UNIT / NVMe Format NVM (will ERASE the reference drive if the DUT fails)
  --mount-test        also try an OS-level read-write mount, file create/delete, unmount
  --keep-ro           do not clear the Linux read-only flag (tests the OS, not the DUT - not recommended)
  --full-each         full-drive hash before/after EVERY test instead of a region window (slow, most rigorous)
  --only IDS          comma list of test IDs to run (for example P1-01,P1-07)
  --list              list test IDs and exit
  --skip-precheck     skip the baseline pre-check (needs --direct to apply at all)
  --yes-reference     skip the typed confirmation (after you have checked the target)
  --outdir DIR        where to put the run folder

Test ONE command class per DUT session if you want per-test attribution on the direct path
(use --only), otherwise run all and verify once at the end.
EOF
}

DUT=""; BASELINE=""; DIRECT=""; DESTR=0; WIPE=0; MOUNT=0; KEEPRO=0; FULLEACH=0; ONLY=""; LIST=0
PRECHECK=1; YES=0; OUTDIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dut) DUT="$2"; shift 2;;
    --baseline) BASELINE="$2"; shift 2;;
    --direct) DIRECT="$2"; shift 2;;
    --destructive) DESTR=1; shift;;
    --wipe-class) WIPE=1; shift;;
    --mount-test) MOUNT=1; shift;;
    --keep-ro) KEEPRO=1; shift;;
    --full-each) FULLEACH=1; shift;;
    --only) ONLY="$2"; shift 2;;
    --list) LIST=1; shift;;
    --skip-precheck) PRECHECK=0; shift;;
    --yes-reference) YES=1; shift;;
    --outdir) OUTDIR="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "unknown option: $1" >&2; usage; exit 2;;
  esac
done

declare -a T_IDS=() T_DESC=() T_FN=() T_TIER=()
add_test() { T_IDS+=("$1"); T_DESC+=("$2"); T_FN+=("$3"); T_TIER+=("$4"); }
add_test P1-01 "Direct write at LBA 0 (O_DIRECT)"                         t_write_start    basic
add_test P1-02 "Direct write mid-drive"                                   t_write_mid      basic
add_test P1-03 "Direct write at the last sectors"                         t_write_last     basic
add_test P1-04 "Direct write straddling the 1 MiB boundary"               t_write_boundary basic
add_test P1-05 "Buffered write + fsync at LBA 0"                          t_write_buffered basic
add_test P1-06 "Direct write straddling the 2 TiB boundary"               t_write_2tib     basic
add_test P1-07 "Discard / TRIM (blkdiscard)"                              t_discard        basic
add_test P1-08 "Write-zeroes (blkdiscard -z)"                             t_zeroout        basic
add_test P1-09 "ATA write-sector (hdparm --write-sector)"                 t_hdparm_ws      basic
add_test P1-10 "SCSI WRITE SAME (sg_write_same)"                          t_sg_write_same  basic
add_test P1-11 "SCSI UNMAP (sg_unmap)"                                    t_sg_unmap       destructive
add_test P1-12 "ATA SET MAX / HPA change (hdparm -N)"                     t_hpa            destructive
add_test P1-13 "ATA security set-password"                                t_secpass        destructive
add_test P1-14 "NVMe write-zeroes (nvme-cli)"                             t_nvme_wz        destructive
add_test P1-15 "NVMe dataset management deallocate (nvme-cli)"            t_nvme_dsm       destructive
add_test P1-16 "OS-level read-write mount, create/delete file, unmount"   t_mount          mount
add_test P1-17 "SCSI FORMAT UNIT (sg_format)"                             t_sg_format      wipe
add_test P1-18 "NVMe Format NVM (nvme-cli)"                               t_nvme_format    wipe

if (( LIST )); then
  for i in "${!T_IDS[@]}"; do printf '%s  [%s]  %s\n' "${T_IDS[$i]}" "${T_TIER[$i]}" "${T_DESC[$i]}"; done
  exit 0
fi
[[ -n "$DUT" ]] || { usage; exit 2; }

need_root
guard_reference "$DUT" "$YES"
[[ -z "$DIRECT" ]] || target_check "$DIRECT"
init_run phase1 "$OUTDIR"

SIZE="$(dev_size "$DUT")"; SS="$(dev_ss "$DUT")"; WLEN="$(wlen_for_ss "$SS")"
VDEV="${DIRECT:-$DUT}"                 # path used to judge whether the drive changed
log "DUT=$DUT size=$SIZE logical_sector=$SS write_len=$WLEN verify_path=$VDEV"
[[ -n "$DIRECT" ]] || log "NOTE: judging via the DUT path only; results are REVIEW until verified on a direct path"

if [[ -n "$DIRECT" && -n "$BASELINE" && "$PRECHECK" == "1" ]]; then
  log "pre-check: full hash of the drive on the direct path against the baseline"
  "${WBT_PY[@]}" hash "$DIRECT" --out "$RUN_DIR/precheck.json" || die "pre-check read failed"
  if ! "${WBT_PY[@]}" compare "$BASELINE" "$RUN_DIR/precheck.json" | grep -q 'P2-01|PASS'; then
    die "reference drive no longer matches its baseline - rebuild it before testing"
  fi
fi

PATFILE="$RUN_DIR/pattern.bin"; head -c "$SS" /dev/zero | tr '\0' '\245' > "$PATFILE"
snapshot_state "$DUT" "$RUN_DIR/state_before.txt"
if (( KEEPRO )); then
  log "keep-ro: the Linux read-only flag is left as found, so write attempts may be stopped by the OS before they reach the DUT"
else
  force_rw "$DUT"
fi

T_CMD=""; T_RESP=""; T_SKIP=""; T_OFF=0; T_LEN=0

capture() { # run a command, fill T_CMD / T_RESP
  T_CMD="$*"
  local out rc
  out="$("$@" 2>&1)"; rc=$?
  T_RESP="rc=$rc: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
}
do_pwrite() { # offset [extra pwrite args...]
  local off="$1"; shift
  T_CMD="wbt_hash.py pwrite $DUT --offset $off --length $WLEN --readback $*"
  T_RESP="$("${WBT_PY[@]}" pwrite "$DUT" --offset "$off" --length "$WLEN" --readback \
             --json-out "$RUN_DIR/pwrite.jsonl" --tag "$CUR_ID" "$@" 2>&1)"
}
need_tool() { have "$1" || { T_SKIP="$1 not installed"; return 1; }; return 0; }

# ---- test bodies: each is called twice, "plan" (set T_OFF/T_LEN/T_SKIP) then "run" ----
t_write_start()    { if [[ $1 == plan ]]; then T_OFF=0; T_LEN=$WLEN; else do_pwrite "$T_OFF"; fi; }
t_write_mid()      { if [[ $1 == plan ]]; then T_OFF=$(( (SIZE / 2 / MIB) * MIB )); T_LEN=$WLEN; else do_pwrite "$T_OFF"; fi; }
t_write_last()     { if [[ $1 == plan ]]; then T_OFF=$(( SIZE - WLEN )); T_LEN=$WLEN; else do_pwrite "$T_OFF"; fi; }
t_write_boundary() { if [[ $1 == plan ]]; then T_OFF=$(( MIB - WLEN / 2 )); T_LEN=$WLEN; else do_pwrite "$T_OFF"; fi; }
t_write_buffered() { if [[ $1 == plan ]]; then T_OFF=0; T_LEN=$WLEN; else do_pwrite "$T_OFF" --buffered; fi; }
t_write_2tib() {
  local b=$(( 2 * 1024 * 1024 * 1024 * 1024 ))
  if [[ $1 == plan ]]; then
    if (( SIZE < b + WLEN )); then T_SKIP="drive is smaller than 2 TiB"; return; fi
    T_OFF=$(( b - WLEN / 2 )); T_LEN=$WLEN
  else do_pwrite "$T_OFF"; fi
}
t_discard() {
  if [[ $1 == plan ]]; then need_tool blkdiscard || return; T_OFF=$(( (SIZE / 4 / MIB) * MIB )); T_LEN=$MIB
  else capture blkdiscard -o "$T_OFF" -l "$T_LEN" "$DUT"; fi
}
t_zeroout() {
  if [[ $1 == plan ]]; then need_tool blkdiscard || return; T_OFF=$(( (SIZE / 5 / MIB) * MIB )); T_LEN=$MIB
  else capture blkdiscard -z -o "$T_OFF" -l "$T_LEN" "$DUT"; fi
}
t_hdparm_ws() {
  if [[ $1 == plan ]]; then need_tool hdparm || return; T_OFF=$(( (SIZE / 3 / MIB) * MIB )); T_LEN=$SS
  else capture hdparm --write-sector $(( T_OFF / SS )) --yes-i-know-that-what-i-am-doing "$DUT"; fi
}
t_sg_write_same() {
  if [[ $1 == plan ]]; then need_tool sg_write_same || return; T_OFF=$(( (SIZE / 6 / MIB) * MIB )); T_LEN=$(( SS * 8 ))
  else capture sg_write_same --lba=$(( T_OFF / SS )) --num=8 --xferlen="$SS" --in="$PATFILE" "$DUT"; fi
}
t_sg_unmap() {
  if [[ $1 == plan ]]; then need_tool sg_unmap || return; T_OFF=$(( (SIZE / 7 / MIB) * MIB )); T_LEN=$(( SS * 8 ))
  else capture sg_unmap --lba=$(( T_OFF / SS )) --num=8 "$DUT"; fi
}
t_hpa() {
  if [[ $1 == plan ]]; then
    need_tool hdparm || return
    T_LEN=0
    local line; line="$(hdparm -N "$DUT" 2>&1 | grep -i 'max sectors' || true)"
    HPA_CUR="$(sed -n 's/.*max sectors *= *\([0-9]*\)\/\([0-9]*\).*/\1/p' <<< "$line")"
    [[ -n "$HPA_CUR" ]] || { T_SKIP="HPA state not readable on this path (not ATA, or the DUT hides it)"; return; }
  else
    capture hdparm -N $(( HPA_CUR - 2048 )) --yes-i-know-that-what-i-am-doing "$DUT"
    hdparm -N "$HPA_CUR" --yes-i-know-that-what-i-am-doing "$DUT" >/dev/null 2>&1 || true   # undo if it took effect
  fi
}
t_secpass() {
  if [[ $1 == plan ]]; then need_tool hdparm || return; T_LEN=0
  else
    capture hdparm --user-master u --security-set-pass wbtTest1 "$DUT"
    hdparm --user-master u --security-disable wbtTest1 "$DUT" >/dev/null 2>&1 || true        # undo if it took effect
  fi
}
t_nvme_wz() {
  if [[ $1 == plan ]]; then need_tool nvme || return; T_OFF=$(( (SIZE / 3 / MIB) * MIB )); T_LEN=$(( SS * 8 ))
  else capture nvme write-zeroes "$DUT" --start-block=$(( T_OFF / SS )) --block-count=7; fi
}
t_nvme_dsm() {
  if [[ $1 == plan ]]; then need_tool nvme || return; T_OFF=$(( (SIZE / 4 / MIB) * MIB )); T_LEN=$(( SS * 8 ))
  else capture nvme dsm "$DUT" --ad --slbs=$(( T_OFF / SS )) --blocks=8; fi
}
t_sg_format() {
  if [[ $1 == plan ]]; then need_tool sg_format || return; T_OFF=0; T_LEN=$(( 16 * MIB ))
  else capture sg_format --format "$DUT"; fi
}
t_nvme_format() {
  if [[ $1 == plan ]]; then need_tool nvme || return; T_OFF=0; T_LEN=$(( 16 * MIB ))
  else capture nvme format "$DUT" --ses=0; fi
}
t_mount() {
  if [[ $1 == plan ]]; then
    T_OFF=0; T_LEN=$(( 16 * MIB ))
    (( T_LEN > SIZE )) && T_LEN=$SIZE
    PART="$(lsblk -nrpo NAME,TYPE "$DUT" 2>/dev/null | awk '$2=="part"{print $1; exit}')"
    [[ -n "${PART:-}" ]] || T_SKIP="no partition found on the drive"
  else
    local mp="$RUN_DIR/mnt" out="" rc=0
    mkdir -p "$mp"
    T_CMD="mount -o rw $PART; create/modify/delete a file; umount"
    if out="$(mount -o rw "$PART" "$mp" 2>&1)"; then
      out+=" | mounted rw;"
      out+=" create: $( { echo wbt-test > "$mp/wbt_test.txt" && sync; } 2>&1 && echo ok)"
      out+=" delete: $( { rm -f "$mp/wbt_test.txt" && sync; } 2>&1 && echo ok)"
      umount "$mp" 2>&1 || true
    else rc=$?; out="mount rc=$rc: $out"; fi
    T_RESP="$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
  fi
}

want_test() { # id tier
  if [[ -n "$ONLY" ]]; then [[ ",$ONLY," == *",$1,"* ]]; return; fi
  case "$2" in
    basic) return 0;;
    destructive) (( DESTR ));;
    mount) (( MOUNT ));;
    wipe) (( WIPE ));;
  esac
}

for i in "${!T_IDS[@]}"; do
  id="${T_IDS[$i]}"; desc="${T_DESC[$i]}"; fn="${T_FN[$i]}"
  want_test "$id" "${T_TIER[$i]}" || continue
  CUR_ID="$id"; T_CMD=""; T_RESP=""; T_SKIP=""; T_OFF=0; T_LEN=0
  "$fn" plan
  if [[ -n "$T_SKIP" ]]; then record_result "$id" "$desc" "" "skipped: $T_SKIP" "" "" "SKIPPED" ""; continue; fi

  hb=""; ha=""
  if (( FULLEACH )); then
    hb="$(full_hash_value "$VDEV")"
  elif (( T_LEN > 0 )); then
    read -r w0 wl < <(window "$T_OFF" "$T_LEN" "$SIZE"); hb="$(region_hash "$VDEV" "$w0" "$wl")"
  fi
  sig_b="$(state_sig "$VDEV")"

  "$fn" run
  flush_cache "$DUT"; [[ -z "$DIRECT" ]] || flush_cache "$DIRECT"

  if (( FULLEACH )); then
    ha="$(full_hash_value "$VDEV")"
  elif (( T_LEN > 0 )); then
    ha="$(region_hash "$VDEV" "$w0" "$wl")"
  fi
  sig_a="$(state_sig "$VDEV")"

  result=""
  if [[ "$T_RESP" == *"readback_shows_new_data=True"* ]]; then
    result="FAIL - read-back through the DUT returned the data just written"
  elif [[ "$hb" != "$ha" ]]; then
    result="FAIL - drive content changed"
  elif [[ "$sig_b" != "$sig_a" ]]; then
    result="FAIL - drive state changed (capacity/HPA/security/identify)"
  elif [[ -n "$DIRECT" ]]; then
    result="PASS"
  else
    result="REVIEW - no change seen via the DUT; verify on a direct path"
  fi
  record_result "$id" "$desc" "$T_CMD" "$T_RESP" "${hb:0:16}" "${ha:0:16}" "$result" "$RUN_DIR/pwrite.jsonl"
done

# ---- wrap-up -----------------------------------------------------------------
restore_ro "$DUT"
snapshot_state "$DUT" "$RUN_DIR/state_after.txt"
log "state before/after (smartctl power-on hours and temperature are allowed to differ): diff $RUN_DIR/state_before.txt $RUN_DIR/state_after.txt"

if [[ -n "$DIRECT" && -n "$BASELINE" ]]; then
  log "final check: full hash of the drive on the direct path against the baseline"
  "${WBT_PY[@]}" hash "$DIRECT" --with-meta --out "$RUN_DIR/final_direct.json" || die "final hash failed"
  compare_and_record "$BASELINE" "$RUN_DIR/final_direct.json" "Phase 1 final check (direct path)"
else
  log "NEXT: disconnect the blocker, connect the drive DIRECTLY, then run:"
  log "      sudo ./05_verify_direct.sh --direct <direct-device> --baseline ${BASELINE:-<baseline.json>}"
  log "      Any difference from the baseline is an automatic FAIL for this blocker configuration."
fi
summary
(( FAIL_COUNT == 0 ))
