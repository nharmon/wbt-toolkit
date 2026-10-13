# Write-blocker test toolkit

Scripts that carry out the phases of the "Forensic Write Blocker Test & Validation Procedure".
Linux host, run as root. Bash plus one Python 3 helper (standard library only).

**Use reference drives only.** The write-protection tests deliberately try to modify the drive, and some
(`--destructive`, `--wipe-class`) will erase it if the blocker fails. Never connect evidence.
The scripts refuse mounted drives and the system disk, and ask you to type `REFERENCE <device>` before
any write attempt (or pass `--yes-reference` after checking the target yourself).

## Files

| Script | Procedure section | What it does |
| --- | --- | --- |
| `00_baseline.sh` | 3 (steps 3, 5) | On a direct connection: records drive facts, hashes the whole drive twice with `wbt_hash.py`, once with `dd \| sha256sum`, plus first/last MiB, 1 GiB chunk hashes, boundary and partition-edge regions. Optional image copy. Writes `baseline.json`. |
| `00b_prepare_hpa.sh` | 3 (step 4) | Creates an HPA with `hdparm -N`. (DCO creation needs a vendor or third-party tool; `hdparm` cannot create one.) |
| `01_phase1_write_protection.sh` | 4 (Phase 1) | Attempts writes at several offsets, buffered and direct, TRIM, write-zeroes, ATA write-sector, SCSI WRITE SAME/UNMAP, HPA change, ATA security, NVMe write-zeroes/deallocate, OS-level mount and file create/delete, and (opt-in) FORMAT. Checks drive content and state after each. |
| `02_phase2_read_fidelity.sh` | 5 (Phase 2) | Reads the drive through the blocker N times and compares hash, regions, geometry, bad-sector reporting, metadata commands, HPA visibility, throughput, repeatability. |
| `03_phase3_edge_cases.sh` | 6 (Phase 3) | One run per case (drive, interface, host OS, mode): fingerprint, geometry/HPA/boundary checks, optionally chains Phase 1 and 2, appends a row to `phase3_cases.csv`. |
| `04_phase4_anomaly.sh` | 7 (Phase 4) | Concurrent read plus write attempts, idle soak, simulated hot-plug cycles, and guided power-loss / reboot / error-injection events. |
| `05_verify_direct.sh` | 4 (steps 6-7) | With the blocker removed, hashes the drive on a direct path and compares to the baseline. Run after Phase 1 and Phase 4. |
| `wbt_lib.sh`, `wbt_hash.py` | | Shared helpers: logging, CSV records, O_DIRECT hashing, compare, one-shot writer, sector-level diff. |
| `selftest.sh` | | Proves the toolkit works using file-backed fake drives. It does not test any real blocker. |

## Workflow

```
# 1. Reference drive on a DIRECT connection
sudo ./00_baseline.sh --dev /dev/sdX --image /secure/ref.img --out baseline.json

# 2. Connect the same drive through the write blocker; it shows up as /dev/sdY
sudo ./02_phase2_read_fidelity.sh --dut /dev/sdY --baseline baseline.json --case "SATA 512e, Linux 6.8"
sudo ./01_phase1_write_protection.sh --dut /dev/sdY --baseline baseline.json --destructive

# 3. Remove the blocker, connect the drive DIRECTLY, and verify against the baseline
sudo ./05_verify_direct.sh --direct /dev/sdX --baseline baseline.json --image /secure/ref.img

# 4. Edge cases and anomalies
sudo ./03_phase3_edge_cases.sh --case "4Kn 16TB UASP" --dut /dev/sdY --baseline baseline4k.json --run-p2
sudo ./04_phase4_anomaly.sh --dut /dev/sdY --baseline baseline.json --concurrent --hotplug 5 --soak 120
sudo ./04_phase4_anomaly.sh --list-events
sudo ./04_phase4_anomaly.sh --dut /dev/sdY --baseline baseline.json --event "DUT power loss during read" --with-read
```

Each run writes a folder under `./wbt-results/` with `results.csv` (columns match the test log table in the
procedure), `run.log`, JSON evidence, and before/after drive state. Attach the folder to the signed test record.

## Things that matter

- **Judge by the direct path.** A blocker that lies would lie in its own read-back. The strongest evidence is a
  hash taken on a direct path after the tests (`05_verify_direct.sh`). Without `--direct`, Phase 1 and 4 mark
  results `REVIEW` rather than `PASS` until you run it. With only one path, test one command class per session
  (`--only P1-07`) if you need per-test attribution; the 1 GiB chunk hashes and `--image` still locate any change.
- **The Linux read-only flag is cleared first.** When a blocker reports write-protect, Linux refuses writes before they
  reach it, which would test Linux rather than the blocker. The scripts run `blockdev --setrw` for the tests and
  restore the flag afterwards. `--keep-ro` leaves it alone.
- **Reads use O_DIRECT** so the page cache cannot hide or fake what is on the drive.
- **Results**: `PASS`, `FAIL` (automatic fail for that configuration), `REVIEW` (needs a human: a sector-size
  difference, HPA not visible through the blocker, metadata commands blocked, a DUT-path-only result), `SKIPPED`
  (tool missing or drive type not applicable).
- **Optional tools**: `hdparm`, `sg3_utils` (`sg_write_same`, `sg_unmap`, `sg_format`), `nvme-cli`, `smartctl`,
  `blkdiscard`. Missing tools mean skipped tests, which the CSV shows; install them for full coverage.
- **Not covered by script**: bus-analyzer captures, physical power events, DCO creation, Windows/macOS hosts and
  software-blocker registry state. Use the procedure for those and keep the evidence alongside the CSV.
- **Syntax of the vendor tools varies by version** (especially `nvme-cli`). A command that the tool rejects is
  recorded with its error text; check that the recorded response shows the command was understood, not just refused.
- **Self-test only proves the scripts**: run `sudo ./selftest.sh` after any change to them.
