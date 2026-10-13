#!/usr/bin/env bash
# Phase 2 - read fidelity and access completeness (procedure section 5).
# Reads the reference drive THROUGH the write blocker and compares everything against the baseline.
set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/wbt_lib.sh"

usage() {
  cat <<'EOF'
Usage: sudo ./02_phase2_read_fidelity.sh --dut DEVICE --baseline FILE [options]

  --dut DEVICE          reference drive as seen through the write blocker (required)
  --baseline FILE       baseline JSON from 00_baseline.sh (required)
  --runs N              number of full-drive reads for the repeatability check (default 3)
  --badsector-lba N     LBA to read for the bad-sector fidelity check (the baseline must have the same one)
  --case LABEL          label for the records (for example "SATA 512e Linux 6.8")
  --image FILE          baseline image: on a mismatch, locate the first differing sectors
  --outdir DIR          where to put the run folder

Checks: full-drive SHA-256 (P2-01), first/last MiB (P2-02), per-chunk and boundary/partition regions (P2-03),
capacity and sector size (P2-04), bad-sector reporting (P2-05), metadata commands (P2-06), HPA visibility (P2-07),
throughput (P2-08), repeatability across runs (P2-09).
EOF
}

DUT=""; BASELINE=""; RUNS=3; BAD=""; CASE="Phase 2"; IMAGE=""; OUTDIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dut) DUT="$2"; shift 2;;
    --baseline) BASELINE="$2"; shift 2;;
    --runs) RUNS="$2"; shift 2;;
    --badsector-lba) BAD="$2"; shift 2;;
    --case) CASE="$2"; shift 2;;
    --image) IMAGE="$2"; shift 2;;
    --outdir) OUTDIR="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "unknown option: $1" >&2; usage; exit 2;;
  esac
done
[[ -n "$DUT" && -n "$BASELINE" ]] || { usage; exit 2; }
[[ -f "$BASELINE" ]] || { echo "baseline not found: $BASELINE" >&2; exit 2; }

need_root
guard_reference "$DUT" 1            # reads only
init_run phase2 "$OUTDIR"
log "DUT=$DUT baseline=$BASELINE runs=$RUNS case='$CASE'"
snapshot_state "$DUT" "$RUN_DIR/state_dut.txt"

hashes=()
for (( r = 1; r <= RUNS; r++ )); do
  log "full read $r of $RUNS through the DUT"
  extra=(--regions-from "$BASELINE" --with-meta)
  [[ -n "$BAD" ]] && extra+=(--badsector-lba "$BAD")
  "${WBT_PY[@]}" hash "$DUT" "${extra[@]}" --out "$RUN_DIR/run$r.json"
  rc=$?
  if (( rc == 3 )); then
    compare_and_record "$BASELINE" "$RUN_DIR/run$r.json" "$CASE (run $r)"
    log "read error on run $r - see $RUN_DIR/run$r.json"
    break
  elif (( rc != 0 )); then die "hash run $r failed (exit $rc)"; fi
  # Record every check on the first run; later runs only need to match the first (P2-09) and the baseline hash.
  if (( r == 1 )); then compare_and_record "$BASELINE" "$RUN_DIR/run$r.json" "$CASE (run 1)"; fi
  hashes+=("$("${WBT_PY[@]}" jsonget "$RUN_DIR/run$r.json" sha256)")
done

if (( ${#hashes[@]} > 1 )); then
  uniq_count="$(printf '%s\n' "${hashes[@]}" | sort -u | wc -l)"
  if (( uniq_count == 1 )); then
    record_result P2-09 "$CASE" "compare ${#hashes[@]} full-drive hashes" "all runs identical" "${hashes[0]:0:16}" "${hashes[-1]:0:16}" PASS "$RUN_DIR"
  else
    record_result P2-09 "$CASE" "compare ${#hashes[@]} full-drive hashes" "runs disagree: ${hashes[*]:0:3}" "${hashes[0]:0:16}" "${hashes[-1]:0:16}" "FAIL - reads are not repeatable" "$RUN_DIR"
  fi
fi

if (( FAIL_COUNT > 0 )) && [[ -n "$IMAGE" ]]; then
  log "locating differences against the baseline image"
  "${WBT_PY[@]}" firstdiff "$IMAGE" "$DUT" --limit 20 | tee "$RUN_DIR/firstdiff.txt" | tee -a "$WBT_LOG"
fi

summary
(( FAIL_COUNT == 0 ))
