#!/usr/bin/env bash
# Direct-path verification (procedure section 4, steps 6-7): with the blocker REMOVED and the reference
# drive on a known-good direct connection, hash it and compare it to the baseline.
# Run this after Phase 1 and Phase 4 - it is the check that does not depend on trusting the DUT.
set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/wbt_lib.sh"

usage() {
  cat <<'EOF'
Usage: sudo ./05_verify_direct.sh --direct DEVICE --baseline FILE [options]

  --direct DEVICE     reference drive on a DIRECT (unblocked) connection (required)
  --baseline FILE     baseline JSON from 00_baseline.sh (required)
  --label TEXT        what this verification follows (for example "after Phase 1, SATA blocker fw 2.1")
  --image FILE        baseline image: on a mismatch, locate the first differing sectors
  --quick             check geometry, HPA and boundary regions only (skip the full-drive hash; not sufficient after Phase 1)
  --outdir DIR        where to put the run folder

Any change from the baseline is an automatic FAIL for the blocker configuration that was just tested.
EOF
}

DIRECT=""; BASELINE=""; LABEL="verify direct"; IMAGE=""; QUICK=0; OUTDIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --direct) DIRECT="$2"; shift 2;;
    --baseline) BASELINE="$2"; shift 2;;
    --label) LABEL="$2"; shift 2;;
    --image) IMAGE="$2"; shift 2;;
    --quick) QUICK=1; shift;;
    --outdir) OUTDIR="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "unknown option: $1" >&2; usage; exit 2;;
  esac
done
[[ -n "$DIRECT" && -n "$BASELINE" ]] || { usage; exit 2; }
[[ -f "$BASELINE" ]] || { echo "baseline not found: $BASELINE" >&2; exit 2; }

need_root
guard_reference "$DIRECT" 1
init_run verify-direct "$OUTDIR"
log "direct=$DIRECT baseline=$BASELINE label='$LABEL'"
snapshot_state "$DIRECT" "$RUN_DIR/state_direct.txt"

args=(--regions-from "$BASELINE" --with-meta --out "$RUN_DIR/direct.json")
(( QUICK )) && args+=(--quick)
"${WBT_PY[@]}" hash "$DIRECT" "${args[@]}"
rc=$?
if (( rc != 0 && rc != 3 )); then die "hash failed (exit $rc)"; fi
compare_and_record "$BASELINE" "$RUN_DIR/direct.json" "$LABEL"

if (( FAIL_COUNT > 0 )); then
  log "RESULT: the drive differs from its baseline - the blocker configuration under test FAILED (or the baseline is void)."
  if [[ -n "$IMAGE" ]]; then
    log "locating differences against the baseline image"
    "${WBT_PY[@]}" firstdiff "$IMAGE" "$DIRECT" --limit 20 | tee "$RUN_DIR/firstdiff.txt" | tee -a "$WBT_LOG"
  else
    log "Chunk numbers above give the 1 GiB area that changed. Keep a baseline image (00_baseline.sh --image) to see exact sectors."
  fi
elif (( REVIEW_COUNT > 0 )); then
  log "RESULT: no content change; review the REVIEW items above (sector size, HPA, metadata) and document them."
else
  log "RESULT: drive identical to baseline."
fi
summary
(( FAIL_COUNT == 0 ))
