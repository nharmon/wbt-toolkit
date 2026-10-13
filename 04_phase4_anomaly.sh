#!/usr/bin/env bash
# Phase 4 - anomaly, power, and hot-plug behavior (procedure section 7).
# Automated: concurrent read + write attempts, long idle soak, simulated hot-plug cycles (Linux).
# Guided: power loss, drive power cycle, reboot/sleep, error injection (you perform the event, the script
# attempts writes afterwards and records what the blocker did).
set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/wbt_lib.sh"

usage() {
  cat <<'EOF'
Usage: sudo ./04_phase4_anomaly.sh --dut DEVICE --baseline FILE [mode] [options]

Modes (pick one or more):
  --concurrent               heavy full-drive read while write attempts are fired in parallel (test 6)
  --soak MINUTES             idle for MINUTES with periodic state checks, then a full read compare (test 8)
  --hotplug N                N simulated unplug/replug cycles via sysfs, with write attempts after each (test 3)
  --event "LABEL"            guided: you perform an event (power loss, DUT unplug, drive power cycle, reboot...);
                             the script then attempts writes and records the result. Add --with-read to start a
                             read workload first and be prompted to trigger the event DURING the read (tests 1, 2, 4, 5, 7).
  --list-events              print the event checklist from the procedure and exit

Options:
  --dut DEVICE      reference drive through the blocker (required; for --event after a reboot, give the new device name)
  --baseline FILE   baseline JSON (required)
  --direct DEVICE   same drive on an unblocked second path, if you have one (otherwise verify afterwards with 05_verify_direct.sh)
  --with-read       (with --event) run a read workload during the event
  --yes-reference   skip the typed confirmation
  --outdir DIR      where to put the run folder
EOF
}

list_events() {
  cat <<'EOF'
Events to run with --event "<label>" (re-hash the reference drive on a direct path after each, or at least at the end):
  1. Power loss to the HOST during a read, then restore power      (use --with-read; the script ends with the host, so re-run with --event after reboot)
  2. Power loss / unplug of the DUT during a read                  (--with-read)
  3. Power loss / unplug of the DUT during a blocked write attempt (run --concurrent, pull power meanwhile)
  4. Drive power cycle (separately powered drives) while connected (--with-read)
  5. Host reboot, or sleep and resume, with the drive attached
  6. Hot-plug / hot-unplug of the drive and of the host cable, several times (--hotplug N for a software simulation)
  7. Error injection with a bus analyzer or fault injector: malformed / truncated commands (record the analyzer capture as evidence)
After EVERY event the DUT must come back read-only and must never default to writable.
EOF
}

DUT=""; BASELINE=""; DIRECT=""; CONC=0; SOAK=""; HOT=""; EVENT=""; WITHREAD=0; YES=0; OUTDIR=""; LISTEV=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dut) DUT="$2"; shift 2;;
    --baseline) BASELINE="$2"; shift 2;;
    --direct) DIRECT="$2"; shift 2;;
    --concurrent) CONC=1; shift;;
    --soak) SOAK="$2"; shift 2;;
    --hotplug) HOT="$2"; shift 2;;
    --event) EVENT="$2"; shift 2;;
    --with-read) WITHREAD=1; shift;;
    --list-events) LISTEV=1; shift;;
    --yes-reference) YES=1; shift;;
    --outdir) OUTDIR="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "unknown option: $1" >&2; usage; exit 2;;
  esac
done
if (( LISTEV )); then list_events; exit 0; fi
[[ -n "$DUT" && -n "$BASELINE" ]] || { usage; exit 2; }
[[ -f "$BASELINE" ]] || { echo "baseline not found: $BASELINE" >&2; exit 2; }
(( CONC )) || [[ -n "$SOAK" || -n "$HOT" || -n "$EVENT" ]] || { echo "pick at least one mode" >&2; usage; exit 2; }

need_root
guard_reference "$DUT" "$YES"
[[ -z "$DIRECT" ]] || target_check "$DIRECT"
init_run phase4 "$OUTDIR"
SIZE="$(dev_size "$DUT")"; SS="$(dev_ss "$DUT")"; WLEN="$(wlen_for_ss "$SS")"
VDEV="${DIRECT:-$DUT}"
force_rw "$DUT"
snapshot_state "$DUT" "$RUN_DIR/state_before.txt"

# judge ID DESC CMD RESP -- decide a result after write attempts (AW_APPLIED) and a state check
judge() { # id desc cmd resp sig_before
  local id="$1" desc="$2" cmd="$3" resp="$4" sig_b="$5" sig_a result
  sig_a="$(state_sig "$VDEV")"
  if (( AW_APPLIED )); then result="FAIL - read-back returned the data just written"
  elif [[ "$sig_b" != "$sig_a" ]]; then result="FAIL - drive state changed"
  elif [[ -n "$DIRECT" ]]; then result="PASS"
  else result="REVIEW - nothing seen via the DUT; verify on a direct path"; fi
  record_result "$id" "$desc" "$cmd" "$resp" "" "" "$result" "$RUN_DIR/pwrite.jsonl"
}

# ------------------------------------------------------------------ concurrent
if (( CONC )); then
  log "P4-06: full read through the DUT with write attempts fired in parallel"
  sig_b="$(state_sig "$VDEV")"
  "${WBT_PY[@]}" hash "$DUT" --regions-from "$BASELINE" --with-meta --out "$RUN_DIR/concurrent_read.json" &
  rpid=$!
  n=0; applied=0; slots=$(( SIZE / WLEN )); (( slots < 1 )) && slots=1
  while kill -0 "$rpid" 2>/dev/null; do
    off=$(( ( (RANDOM * 32768 + RANDOM) % slots ) * WLEN ))
    sum="$("${WBT_PY[@]}" pwrite "$DUT" --offset "$off" --length "$WLEN" --readback --json-out "$RUN_DIR/pwrite.jsonl" --tag concurrent 2>&1)"
    n=$((n + 1))
    [[ "$sum" == *"readback_shows_new_data=True"* ]] && applied=$((applied + 1))
    sleep 0.1
  done
  wait "$rpid"; rrc=$?
  log "fired $n write attempts during the read; $applied showed new data on read-back"
  if (( rrc == 0 || rrc == 3 )); then compare_and_record "$BASELINE" "$RUN_DIR/concurrent_read.json" "P4-06 read integrity during write attempts"; fi
  AW_APPLIED=$(( applied > 0 ? 1 : 0 ))
  judge P4-06 "Write attempts during heavy reads" "$n parallel pwrite attempts" "attempts=$n applied_on_readback=$applied" "$sig_b"
fi

# ------------------------------------------------------------------ soak
if [[ -n "$SOAK" ]]; then
  log "P4-08: idle soak for $SOAK minute(s), checking drive state every minute"
  sig_b="$(state_sig "$VDEV")"; drift=0
  for (( m = 1; m <= SOAK; m++ )); do
    sleep 60
    [[ "$(state_sig "$VDEV")" == "$sig_b" ]] || { drift=1; log "state changed at minute $m"; }
  done
  log "soak finished; reading the whole drive and comparing"
  "${WBT_PY[@]}" hash "$DUT" --regions-from "$BASELINE" --with-meta --out "$RUN_DIR/soak_read.json"
  compare_and_record "$BASELINE" "$RUN_DIR/soak_read.json" "P4-08 read after soak"
  attempt_writes "$DUT" soak
  AW_APPLIED=$(( AW_APPLIED || drift ))
  judge P4-08 "Idle soak ($SOAK min) then reads and write attempts" "sleep ${SOAK}m; hash; pwrite" "$AW_SUMMARY" "$sig_b"
fi

# ------------------------------------------------------------------ hot-plug simulation
find_usb_node() { # sysfs path walking up to the USB device that owns the disk
  local p="$1"
  while [[ "$p" != "/" && -n "$p" ]]; do
    [[ -f "$p/authorized" ]] && { echo "$p"; return 0; }
    p="$(dirname "$p")"
  done
  return 1
}
find_by_serial() { # serial -> device path
  lsblk -dnpo NAME,SERIAL 2>/dev/null | awk -v s="$1" '$2==s {print $1; exit}'
}
if [[ -n "$HOT" ]]; then
  name="$(basename "$(readlink -f "$DUT")")"
  serial="$(lsblk -dno SERIAL "$DUT" 2>/dev/null | head -1)"
  if [[ -z "$serial" || ! -d "/sys/block/$name/device" ]]; then
    record_result P4-03 "Simulated hot-plug" "" "skipped: cannot identify the DUT by serial / sysfs (try physical unplugging with --event)" "" "" SKIPPED ""
  else
    syspath="$(readlink -f "/sys/block/$name/device")"
    usbnode="$(find_usb_node "$syspath" || true)"
    host="$(grep -o 'host[0-9]*' <<< "$syspath" | head -1)"
    sig_b="$(state_sig "$VDEV")"
    allsum=""; failed=0
    for (( c = 1; c <= HOT; c++ )); do
      log "hot-plug cycle $c of $HOT"
      if [[ -n "$usbnode" ]]; then
        echo 0 > "$usbnode/authorized"; sleep 3; echo 1 > "$usbnode/authorized"
      else
        echo 1 > "/sys/block/$name/device/delete"; sleep 2
        [[ -n "$host" ]] && echo "- - -" > "/sys/class/scsi_host/$host/scan"
      fi
      new=""
      for _ in $(seq 1 30); do new="$(find_by_serial "$serial")"; [[ -n "$new" ]] && break; sleep 1; done
      if [[ -z "$new" ]]; then allsum+="[cycle $c: drive did not return] "; failed=1; break; fi
      DUT="$new"; name="$(basename "$(readlink -f "$DUT")")"
      force_rw "$DUT"
      attempt_writes "$DUT" "hotplug-$c"
      allsum+="[cycle $c $DUT ro_flag_on_return=${ORIG_RO:-?}: $AW_SUMMARY] "
      (( AW_APPLIED )) && failed=1
    done
    AW_APPLIED=$failed
    judge P4-03 "Simulated hot-plug x$HOT, writes attempted after each return" "sysfs unplug/replug + pwrite" "$allsum" "$sig_b"
  fi
fi

# ------------------------------------------------------------------ guided events
if [[ -n "$EVENT" ]]; then
  sig_b="$(state_sig "$VDEV")"
  rpid=""
  if (( WITHREAD )); then
    log "starting a read workload on $DUT"
    ( while true; do cat "$DUT" > /dev/null 2>&1 || sleep 1; done ) &
    rpid=$!
    echo
    echo ">>> Perform the event NOW: $EVENT"
    echo ">>> When the DUT and drive are connected again, press ENTER."
    if [[ -t 0 ]]; then read -r _ < /dev/tty; else sleep 30; fi
    pkill -P "$rpid" 2>/dev/null; kill "$rpid" 2>/dev/null; wait "$rpid" 2>/dev/null
  else
    log "event '$EVENT' is assumed to have already happened; testing the DUT's state now"
  fi
  [[ -b "$DUT" || "$WBT_ALLOW_FILE" == "1" ]] || die "$DUT is not present - give the new device name with --dut"
  force_rw "$DUT"
  attempt_writes "$DUT" "event: $EVENT"
  judge P4-EV "Event: $EVENT - writes attempted afterwards" "pwrite after event" "ro_flag_after_event=${ORIG_RO:-?} $AW_SUMMARY" "$sig_b"
  log "Did the DUT need a manual reset, show odd lights/log output, or come back writable? Note it in the record."
fi

restore_ro "$DUT"
snapshot_state "$DUT" "$RUN_DIR/state_after.txt"
if [[ -n "$DIRECT" ]]; then
  log "final check: full hash on the direct path against the baseline"
  "${WBT_PY[@]}" hash "$DIRECT" --with-meta --out "$RUN_DIR/final_direct.json" && \
    compare_and_record "$BASELINE" "$RUN_DIR/final_direct.json" "Phase 4 final check (direct path)"
else
  log "NEXT: remove the blocker, connect the drive directly and run 05_verify_direct.sh --direct <dev> --baseline $BASELINE"
fi
summary
(( FAIL_COUNT == 0 ))
