#!/usr/bin/env bash
# Phase 3 - interface, capacity, and configuration edge cases (procedure section 6).
# One run = ONE case (a particular drive + interface + adapter/cable + host OS + DUT mode).
# It fingerprints the configuration, checks geometry / HPA visibility / boundary regions, can chain
# Phase 1 and Phase 2 for the same case, and appends a row to a cumulative phase3_cases.csv.
set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/wbt_lib.sh"

usage() {
  cat <<'EOF'
Usage: sudo ./03_phase3_edge_cases.sh --case LABEL --dut DEVICE --baseline FILE [options]

  --case LABEL        name of this case, for example "SATA 4Kn 16TB, UASP bridge, kernel 6.8"  (required)
  --dut DEVICE        reference drive through the write blocker (required)
  --baseline FILE     baseline JSON taken for THIS reference drive on a direct path (required)
  --note TEXT         free text: adapter, cable, DUT mode switch position, firmware, ...
  --run-p2            also run the full Phase 2 read-fidelity script for this case
  --run-p1 "ARGS"     also run Phase 1 with these extra arguments (for example "--destructive --yes-reference")
  --table FILE        cumulative CSV of cases (default ./wbt-results/phase3_cases.csv)
  --outdir DIR        where to put the run folder

Run once per case in the table of procedure section 6: hidden areas (HPA/DCO), >2 TB drives, 512n/512e/4Kn,
each interface/bridge/speed, each host OS, locked or standby drives, DUT mode switches, each cable/adapter.
Software write blockers: also check that the blocking state survives a reboot and cannot be silently switched off.
EOF
}

CASE=""; DUT=""; BASELINE=""; NOTE=""; RUNP2=0; RUNP1=""; TABLE=""; OUTDIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --case) CASE="$2"; shift 2;;
    --dut) DUT="$2"; shift 2;;
    --baseline) BASELINE="$2"; shift 2;;
    --note) NOTE="$2"; shift 2;;
    --run-p2) RUNP2=1; shift;;
    --run-p1) RUNP1="$2"; shift 2;;
    --table) TABLE="$2"; shift 2;;
    --outdir) OUTDIR="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "unknown option: $1" >&2; usage; exit 2;;
  esac
done
[[ -n "$CASE" && -n "$DUT" && -n "$BASELINE" ]] || { usage; exit 2; }
[[ -f "$BASELINE" ]] || { echo "baseline not found: $BASELINE" >&2; exit 2; }

need_root
guard_reference "$DUT" 1
init_run phase3 "$OUTDIR"
TABLE="${TABLE:-$PWD/wbt-results/phase3_cases.csv}"
mkdir -p "$(dirname "$TABLE")"
log "case: $CASE"

# ---- configuration fingerprint --------------------------------------------------
name="$(basename "$(readlink -f "$DUT")")"
tran="$(lsblk -dno TRAN "$DUT" 2>/dev/null | head -1)"
model="$(lsblk -dno MODEL "$DUT" 2>/dev/null | head -1 | sed 's/ *$//')"
driver=""
if [[ -d "/sys/block/$name/device" ]]; then
  p="$(readlink -f "/sys/block/$name/device")"
  while [[ "$p" != "/" && -n "$p" ]]; do
    if [[ -L "$p/driver" ]]; then
      d="$(basename "$(readlink -f "$p/driver")")"
      case "$d" in uas|usb-storage) driver="$d"; break;; esac
    fi
    p="$(dirname "$p")"
  done
fi
osname="$(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}")"
kernel="$(uname -r)"
{
  echo "case: $CASE"; echo "note: $NOTE"; echo "device: $DUT"
  echo "transport: ${tran:-unknown}"; echo "usb_driver: ${driver:-n/a}"; echo "model_seen_through_dut: ${model:-unknown}"
  echo "os: $osname"; echo "kernel: $kernel"
  echo "os_read_only_flag: $(blockdev --getro "$DUT" 2>/dev/null || echo unknown)"
  udevadm info --query=property --name="$DUT" 2>/dev/null | grep -E '^(ID_BUS|ID_MODEL|ID_VENDOR|ID_SERIAL|ID_USB_DRIVER|ID_ATA_.*)=' || true
} > "$RUN_DIR/fingerprint.txt"
log "fingerprint saved: $RUN_DIR/fingerprint.txt"

# ---- geometry, HPA/DCO visibility and boundary regions (quick: no full-drive read) ----
"${WBT_PY[@]}" hash "$DUT" --quick --regions-from "$BASELINE" --with-meta --out "$RUN_DIR/quick.json" || die "quick hash failed"
compare_and_record "$BASELINE" "$RUN_DIR/quick.json" "$CASE (quick)"

geom_ok="yes"; hpa_ok="n/a"; reg_ok="yes"
grep -q '^P2-04|FAIL' "$RUN_DIR/compare_quick.txt" && geom_ok="NO (capacity)"
grep -q '^P2-04|REVIEW' "$RUN_DIR/compare_quick.txt" && geom_ok="differs (sector size)"
grep -q '^P2-07|PASS' "$RUN_DIR/compare_quick.txt" && hpa_ok="matches"
grep -q '^P2-07|REVIEW' "$RUN_DIR/compare_quick.txt" && hpa_ok="not matching / not visible"
grep -q '^P2-03|FAIL' "$RUN_DIR/compare_quick.txt" && reg_ok="NO"

# DCO visibility: the baseline can only help if hdparm could read it directly.
if have hdparm; then
  hdparm --dco-identify "$DUT" > "$RUN_DIR/dco_through_dut.txt" 2>&1 || true
  log "DCO identify through the DUT saved to $RUN_DIR/dco_through_dut.txt - compare it with the direct-path output by hand"
fi

# ---- chained phases -------------------------------------------------------------
p1="not run"; p2="not run"
if [[ -n "$RUNP1" ]]; then
  log "running Phase 1 for this case"
  # shellcheck disable=SC2086
  "$WBT_DIR/01_phase1_write_protection.sh" --dut "$DUT" --baseline "$BASELINE" --outdir "$RUN_DIR/phase1" $RUNP1
  rc=$?
  if (( rc == 0 )); then p1="no change seen (verify on direct path)"; else p1="FAIL/ERROR (exit $rc)"; fi
fi
if (( RUNP2 )); then
  log "running Phase 2 for this case"
  "$WBT_DIR/02_phase2_read_fidelity.sh" --dut "$DUT" --baseline "$BASELINE" --case "$CASE" --outdir "$RUN_DIR/phase2"
  rc=$?
  if (( rc == 0 )); then p2="PASS"; else p2="FAIL (exit $rc)"; fi
fi

# ---- cumulative table -------------------------------------------------------------
if [[ ! -f "$TABLE" ]]; then
  echo 'timestamp,case,note,transport,usb_driver,os,kernel,geometry_matches,hpa_visibility,boundary_regions,phase1,phase2,run_dir' > "$TABLE"
fi
printf '%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n' "$(csvq "$(ts)")" "$(csvq "$CASE")" "$(csvq "$NOTE")" "$(csvq "${tran:-unknown}")" \
  "$(csvq "${driver:-n/a}")" "$(csvq "$osname")" "$(csvq "$kernel")" "$(csvq "$geom_ok")" "$(csvq "$hpa_ok")" "$(csvq "$reg_ok")" \
  "$(csvq "$p1")" "$(csvq "$p2")" "$(csvq "$RUN_DIR")" >> "$TABLE"
log "case row appended to $TABLE"
log "REMINDER: if Phase 1 ran, verify on a direct path with 05_verify_direct.sh before calling this case a pass."
summary
(( FAIL_COUNT == 0 ))
