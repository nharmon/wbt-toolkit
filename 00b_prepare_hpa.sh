#!/usr/bin/env bash
# Create an HPA on a SATA reference drive (procedure section 3, step 4). Direct connection only.
# DCO creation is NOT done here: hdparm can identify / restore / freeze a DCO but not create one,
# so use a vendor or third-party tool for that and record the exact native and hidden maximum LBAs.
set -uo pipefail
source "$(dirname "$(readlink -f "$0")")/wbt_lib.sh"

usage() {
  cat <<'EOF'
Usage: sudo ./00b_prepare_hpa.sh --dev DEVICE --hidden-mib N [--permanent] [--yes-reference]

Hides the last N MiB of the drive behind a Host Protected Area using hdparm -N.
Volatile by default (lost on power cycle); --permanent keeps it.
Re-run 00_baseline.sh afterwards: the baseline must be taken with the HPA in place.
Restore with:  hdparm -N p<native max sectors> --yes-i-know-that-what-i-am-doing DEVICE
EOF
}

DEV=""; HID=""; PERM=0; YES=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dev) DEV="$2"; shift 2;;
    --hidden-mib) HID="$2"; shift 2;;
    --permanent) PERM=1; shift;;
    --yes-reference) YES=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "unknown option: $1" >&2; usage; exit 2;;
  esac
done
[[ -n "$DEV" && -n "$HID" ]] || { usage; exit 2; }
need_root
have hdparm || die "hdparm is required"
guard_reference "$DEV" "$YES"
init_run prepare-hpa ""

line="$(hdparm -N "$DEV" 2>&1 | grep -i 'max sectors' || true)"
log "current: $line"
cur="$(sed -n 's/.*max sectors *= *\([0-9]*\)\/\([0-9]*\).*/\1/p' <<< "$line")"
nat="$(sed -n 's/.*max sectors *= *\([0-9]*\)\/\([0-9]*\).*/\2/p' <<< "$line")"
[[ -n "$cur" && -n "$nat" ]] || die "cannot read HPA state (is this an ATA device on a direct connection?)"
ss="$(dev_ss "$DEV")"
new=$(( cur - HID * MIB / ss ))
(( new > 0 )) || die "hidden size is larger than the drive"
flag="$new"; (( PERM )) && flag="p$new"
log "setting max sectors to $new of native $nat (volatile=$((1 - PERM)))"
hdparm -N "$flag" --yes-i-know-that-what-i-am-doing "$DEV" 2>&1 | tee -a "$WBT_LOG"
hdparm -N "$DEV" 2>&1 | tee -a "$WBT_LOG"
log "native max LBA count: $nat; visible: $new. Power-cycle the drive and re-check before baselining if you used a volatile HPA."
