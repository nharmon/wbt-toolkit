#!/usr/bin/env bash
# Reference media baseline (procedure section 3, steps 3 and 5).
# Run with the reference drive on a DIRECT (unblocked) connection, after you have wiped and populated it.
set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/wbt_lib.sh"

usage() {
  cat <<'EOF'
Usage: sudo ./00_baseline.sh --dev DEVICE [options]

Records drive facts and hashes the whole drive: twice with wbt_hash.py (must agree), once with
dd | sha256sum as an independent cross-check, plus first/last MiB, per-1-GiB chunk hashes, and
hashes of boundary regions (128 GiB, 4 GiB, 2 TiB, LBA 2^32, partition edges).

Options:
  --dev DEVICE            reference drive on a direct connection (required)
  --out FILE              baseline JSON to write (default: <run dir>/baseline.json)
  --image FILE            also copy the drive to an image file (lets later failures be located sector by sector)
  --badsector-lba N       LBA of a known-unreadable sector, if the reference drive has one
  --chunk-mib N           chunk size for chunk hashes (default 1024)
  --no-cross-check        skip the dd | sha256sum cross-check
  --outdir DIR            where to put the run folder
EOF
}

DEV=""; OUT=""; IMAGE=""; BAD=""; CHUNK=1024; NOCROSS=0; OUTDIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dev) DEV="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --image) IMAGE="$2"; shift 2;;
    --badsector-lba) BAD="$2"; shift 2;;
    --chunk-mib) CHUNK="$2"; shift 2;;
    --no-cross-check) NOCROSS=1; shift;;
    --outdir) OUTDIR="$2"; shift 2;;
    -h|--help) usage; exit 0;;
    *) echo "unknown option: $1" >&2; usage; exit 2;;
  esac
done
[[ -n "$DEV" ]] || { usage; exit 2; }

need_root
guard_reference "$DEV" 1          # read-only work: refuse mounted/system disks, no typed confirmation needed
init_run baseline "$OUTDIR"
OUT="${OUT:-$RUN_DIR/baseline.json}"

snapshot_state "$DEV" "$RUN_DIR/facts_direct.txt"
log "drive facts saved to $RUN_DIR/facts_direct.txt"
log "hashing the full drive (this reads it 2-3 times and can take hours on large drives)"

args=(baseline "$DEV" --out "$OUT" --chunk-mib "$CHUNK")
[[ -n "$BAD" ]] && args+=(--badsector-lba "$BAD")
(( NOCROSS )) && args+=(--no-cross-check)
"${WBT_PY[@]}" "${args[@]}" 2>&1 | tee -a "$WBT_LOG"
rc=${PIPESTATUS[0]}
if (( rc != 0 )); then die "baseline failed (exit $rc) - the drive is unstable or unreadable; do not use it as a reference"; fi

if [[ -n "$IMAGE" ]]; then
  log "copying drive to image $IMAGE"
  dd if="$DEV" of="$IMAGE" bs=1M $([[ -b "$DEV" ]] && echo iflag=direct) status=progress 2>&1 | tee -a "$WBT_LOG" || true
  img_hash="$(full_hash_value "$IMAGE")"
  base_hash="$("${WBT_PY[@]}" jsonget "$OUT" sha256)"
  if [[ "$img_hash" == "$base_hash" ]]; then log "image hash matches baseline"; else die "image hash does not match baseline - recopy the image"; fi
fi

log "baseline: $OUT"
log "NEXT: copy the baseline file (and image) to offline storage, label the drive 'reference - do not use for casework',"
log "      and re-hash it with 05_verify_direct.sh before every test run."
