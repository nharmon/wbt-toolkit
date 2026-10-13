#!/usr/bin/env bash
# selftest.sh - proves the toolkit itself works, using regular files as fake "drives".
# It checks that the scripts (a) report PASS when writes are blocked and reads are faithful and
# (b) report FAIL when a "blocker" lets a write through or corrupts a read. It does NOT test any real blocker.
# Needs: root, python3, dd, sha256sum. The "blocked" file is made immutable (chattr +i) or, failing that, is
# tested as an unprivileged user (setpriv) if the work folder is reachable by that user; otherwise those checks are skipped.
set -uo pipefail
HERE="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/wbt-selftest.XXXXXX")"
chmod 755 "$WORK"
TK="$WORK/toolkit"; mkdir -p "$TK"; cp "$HERE"/*.sh "$HERE"/wbt_hash.py "$TK"/; chmod -R a+rX "$TK"
export WBT_ALLOW_FILE=1
SIZE_MIB=64; BAD=0; N=0
check() { # description expected(0|1) actual
  N=$((N + 1))
  if [[ "$2" == "$3" ]]; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s (expected %s, got %s)\n' "$1" "$2" "$3"; BAD=$((BAD + 1)); fi
}
as_nobody() { setpriv --reuid=65534 --regid=65534 --clear-groups env WBT_ALLOW_FILE=1 "$@"; }
rc_of() { "$@" >/dev/null 2>&1; echo $?; }
cleanup() { chattr -i "$WORK"/*.img 2>/dev/null; }
trap cleanup EXIT

# How to simulate "writes are refused": immutable file (works for root), else run as an unprivileged user.
BLOCK_MODE=none
probe="$WORK/probe.img"; echo x > "$probe"
if chattr +i "$probe" 2>/dev/null && ! (echo y > "$probe") 2>/dev/null; then BLOCK_MODE=immutable
elif have_setpriv=$(command -v setpriv) && as_nobody test -r "$TK/wbt_hash.py"; then BLOCK_MODE=nobody; fi
chattr -i "$probe" 2>/dev/null; rm -f "$probe"
echo "write-refusal simulation: $BLOCK_MODE"
block_file() { case "$BLOCK_MODE" in immutable) chattr +i "$1";; nobody) chmod 444 "$1";; esac; }
run_blocked() { if [[ "$BLOCK_MODE" == nobody ]]; then as_nobody "$@"; else "$@"; fi; }

echo "workspace: $WORK"
head -c $((SIZE_MIB * 1048576)) /dev/urandom > "$WORK/ref.img"
cp "$WORK/ref.img" "$WORK/ref_copy.img"

echo "== baseline"
check "baseline builds (2 runs + cross-check)" 0 "$(rc_of "$TK/00_baseline.sh" --dev "$WORK/ref.img" --out "$WORK/base.json" --chunk-mib 16 --image "$WORK/ref.base.img" --outdir "$WORK/r_base")"
check "baseline cross-check matched" matched "$(python3 -I "$TK/wbt_hash.py" jsonget "$WORK/base.json" cross_check)"

echo "== Phase 2 (read fidelity)"
check "faithful read passes" 0 "$(rc_of "$TK/02_phase2_read_fidelity.sh" --dut "$WORK/ref_copy.img" --baseline "$WORK/base.json" --runs 2 --outdir "$WORK/r_p2ok")"
cp "$WORK/ref.img" "$WORK/corrupt.img"
printf '\x00\x00\x00\x00' | dd of="$WORK/corrupt.img" bs=1 seek=$((20 * 1048576 + 512)) conv=notrunc status=none
check "corrupted read is caught" 1 "$(rc_of "$TK/02_phase2_read_fidelity.sh" --dut "$WORK/corrupt.img" --baseline "$WORK/base.json" --runs 1 --image "$WORK/ref.base.img" --outdir "$WORK/r_p2bad")"
grep -q 'LBA 40961' "$WORK/r_p2bad/firstdiff.txt" 2>/dev/null; check "first differing LBA located (40961)" 0 "$?"

echo "== Phase 1 (write protection)"
cp "$WORK/ref.img" "$WORK/open.img"
check "writable 'drive' (no blocker) is caught as FAIL" 1 "$(rc_of "$TK/01_phase1_write_protection.sh" --dut "$WORK/open.img" --direct "$WORK/open.img" --baseline "$WORK/base.json" --skip-precheck --yes-reference --outdir "$WORK/r_p1open")"
cp "$WORK/ref.img" "$WORK/blocked.img"; block_file "$WORK/blocked.img"
mkdir -p "$WORK/out_nobody"; chmod 777 "$WORK/out_nobody"
if [[ "$BLOCK_MODE" == none ]]; then echo "  skip blocked-drive checks (no way to simulate refused writes here)"; else
check "blocked 'drive' passes (writes refused)" 0 "$(rc_of run_blocked "$TK/01_phase1_write_protection.sh" --dut "$WORK/blocked.img" --direct "$WORK/blocked.img" --baseline "$WORK/base.json" --yes-reference --outdir "$WORK/out_nobody/p1")"
check "blocked 'drive' still hashes to baseline" 0 "$(rc_of "$TK/05_verify_direct.sh" --direct "$WORK/blocked.img" --baseline "$WORK/base.json" --outdir "$WORK/r_verify_ok")"
fi

echo "== Direct-path verification"
check "tampered drive fails verification" 1 "$(rc_of "$TK/05_verify_direct.sh" --direct "$WORK/open.img" --baseline "$WORK/base.json" --image "$WORK/ref.base.img" --outdir "$WORK/r_verify_bad")"

echo "== Phase 3 / Phase 4"
check "phase 3 quick case runs" 0 "$(rc_of "$TK/03_phase3_edge_cases.sh" --case selftest --dut "$WORK/ref_copy.img" --baseline "$WORK/base.json" --table "$WORK/cases.csv" --outdir "$WORK/r_p3")"
if [[ "$BLOCK_MODE" != none ]]; then
check "phase 4 concurrent test, blocked drive" 0 "$(rc_of run_blocked "$TK/04_phase4_anomaly.sh" --dut "$WORK/blocked.img" --direct "$WORK/blocked.img" --baseline "$WORK/base.json" --concurrent --yes-reference --outdir "$WORK/out_nobody/p4")"
fi
check "phase 4 concurrent test, writable drive is FAIL" 1 "$(rc_of "$TK/04_phase4_anomaly.sh" --dut "$WORK/open.img" --baseline "$WORK/base.json" --concurrent --yes-reference --outdir "$WORK/r_p4open")"

echo
if (( BAD == 0 )); then echo "selftest: all $N checks behaved as expected (workspace kept at $WORK)"; else echo "selftest: $BAD of $N checks misbehaved - see logs under $WORK"; fi
exit $(( BAD > 0 ))
