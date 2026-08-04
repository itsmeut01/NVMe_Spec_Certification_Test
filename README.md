# NVMe Certification Test Suite

[![GitHub](https://img.shields.io/badge/GitHub-NVMe__Spec__Certification__Test-blue)](https://github.com/itsmeut01/NVMe_Spec_Certification_Test)

## Problem Statement

NVMe SSDs claim compliance with the NVMe Base Specification, but there is no lightweight, standalone way to verify that claim outside of the NVMe-IF's official (and expensive) compliance testing programs. Key questions go unanswered:

- **Does the device correctly report all mandatory fields** defined by the NVMe specification for its reported version?
- **Does `nvme-cli` get back valid, spec-compliant data** from every admin and I/O command the controller claims to support?
- **Do features actually work as specified?** A controller may accept a Set Features command and return success, but does it actually change behavior — does disabling the volatile write cache affect I/O, does a temperature threshold trigger a critical warning, does a format erase user data?
- **Are cross-field relationships consistent?** (e.g., SMART temperature vs WCTEMP/CCTEMP, available spare vs threshold, capacity fields vs namespace sizes)
- **Does the controller handle destructive operations safely?** Format, Sanitize, Namespace Management, Reservations, Controller/Subsystem Resets — do they complete without data corruption and leave the device in a usable state?

This project solves these problems with a comprehensive, open-source test framework that validates NVMe devices against the spec using `nvme-cli` commands — from simple field-presence checks all the way to behavioral validation of features that modify device state.

## What This Suite Tests

### Read-Only Validation (Suites 1-12, 15-16)
Verifies that every mandatory and optional field returned by `nvme-cli` commands matches the NVMe Base Specification for the device's reported version. Checks presence, valid ranges, bit-field correctness, and cross-field consistency. These tests never modify device state. Includes extended log pages (telemetry lifecycle, persistent event log, endurance/reservation/boot-partition logs) and all Identify variants (list-ctrl, list-subsys, primary-ctrl-caps, NVM command-set IDs, domains, NVM sets, UUID, LBA formats).

### Functional / Behavioral Validation (Suites 13-14, 17-27)
Goes beyond readback — actually exercises NVMe features and verifies that the device **behaves** as the spec requires. Every test that can follow the **save → change → action → verify behavior → restore** pattern does so. This includes set-feature cycling, I/O write+read+compare round-trips, firmware re-commit, directive enable/disable, lockdown lock/unlock, and telemetry generate/read cycles. Read-only tests are used only where no write counterpart exists (e.g., Identify structures). Destructive suites require an explicit `--destructive` flag and refuse to run on the OS drive.

## Features

- **27 test suites** covering all major NVMe data structures, commands, and functional behaviors
- **~399 individual tests** including presence checks, bit-field decoding, cross-validation, range checks, and behavioral verification
- **Version-aware testing** — automatically gates checks on the device's reported NVMe version (1.0 through 2.1)
- **Dynamic spec references** — maps the device's NVMe version to the correct spec revision, section, and figure
- **Safe device infrastructure** — OS drive detection via `findmnt`, `lsblk`, and LVM symlink resolution; destructive tests always refuse the boot drive
- **Behavioral validation** — set-feature tests verify actual behavior changes (I/O under different cache/power/arbitration settings), not just readback
- **Save/restore pattern** — every feature modification saves the original value and restores it after testing
- **Graceful degradation** — features unsupported by the controller produce SKIP, not false failures
- **Detailed logging** — every command output and test result is logged to timestamped files under `logs/`
- **KCIDB-compliant result codes** — PASS, FAIL, SKIP, WARN

## Test Suites

### Read-Only Suites (always run)

| # | Suite | Command | Tests | Description |
|---|-------|---------|-------|-------------|
| 1 | Identify Controller | `nvme id-ctrl` | ~62 | Mandatory fields, OACS/ONCS/CTRATT/LPA/SGLS bit decode, thermal cross-checks, capacity validation |
| 2 | SMART / Health Log | `nvme smart-log` | ~22 | All SMART fields, spare vs threshold, temperature vs WCTEMP, percentage used, error count cross-validation |
| 3 | Error Information Log | `nvme error-log` | ~13 | Error entries, status field decode, cross-check with SMART num_err_log_entries |
| 4 | Firmware Slot Info | `nvme fw-log` | ~9 | Firmware slot fields, active slot validation |
| 5 | Identify Namespace | `nvme id-ns` | ~38 | Namespace fields, NSFEAT/MC/DPC/DPS/RESCAP/FPI/DLFEAT bit decode, LBA format validation |
| 6 | Power State Descriptors | `nvme id-ctrl` (ps) | ~15 | Power state fields, idle/active vs max power, latency trend, APSTA consistency |
| 7 | Controller Registers | `nvme show-regs` | 11 | CSTS.RDY, CSTS.CFS, CSTS.SHST, CC.EN, CAP.MQES, CAP.CSS, CAP.TO (timeout), CAP.CRMS (ready modes), CRTO (ready timeouts), VS vs id-ctrl VER |
| 8 | Supported Log Pages | `nvme supported-log-pages` | 9 | Mandatory LIDs (01h-05h incl. Changed NS List, Commands Effects), conditional DST/Effects logs (NVMe 2.0+) |
| 9 | Commands Effects Log | `nvme effects-log` | 10 | Mandatory admin commands (Identify, Get/Set Features, Abort), I/O commands (Read, Write, Flush) |
| 10 | Get Features | `nvme get-feature` | 13 | Number of Queues, Volatile Write Cache, Power Management, Temperature Threshold, Arbitration, APST, HCTM, Interrupt Vector Config (0x09), Async Event Config (0x0B), Keep Alive Timer (0x0F) |
| 11 | NS ID Descriptors | `nvme ns-descs` | 7 | EUI-64, NGUID, UUID presence, at least one non-zero, CSI (2.0+), descriptor lengths |
| 12 | Device Self-test Log | `nvme self-test-log` | 6 | Current operation, completed results, result codes, segment numbers, POH timestamps |

### Non-Destructive Functional Suites (always run)

| # | Suite | Command | Tests | Description |
|---|-------|---------|-------|-------------|
| 13 | DST Functional | `nvme device-self-test` | 6 | Start/poll/verify short DST, abort DST, start extended, abort extended |
| 14 | Async Event | `nvme get-feature`, `admin-passthru` | 7 | AERL check, temperature threshold event trigger, error log increment via invalid opcode, SMART consistency after error injection, Abort command (opcode 0x08), Abort with invalid SQID, AEC feature readback |
| 15 | Additional Logs | `nvme telemetry-log`, `nvme persistent-event-log`, misc | 16 | Telemetry behavioral cycle (generate→verify→read), persistent event log lifecycle (establish→read→release), endurance, changed-ns, reservation-notif, FID-effects, LBA-status, predictable-lat, boot-part, endurance-event-agg |
| 16 | Additional Identify | `nvme list-ctrl`, `nvme nvm-id-ctrl`, misc | 16 | list-ctrl, list-subsys, primary-ctrl-caps, list-secondary, id-uuid, nvm-id-ctrl, nvm-id-ns, cmdset-ind-id-ns, id-domain, id-iocs, id-nvmset, id-ns-granularity, id-ns-lba-format, list-endgrp, nvm-id-ns-lba-format |

### Destructive Suites (require `--destructive`)

| # | Suite | Command | Tests | Description |
|---|-------|---------|-------|-------------|
| 17 | Feature Set (Behavioral) | `nvme set-feature` | 55 | VWC toggle + I/O, TMPTH + critical_warning, PM cycle all PS + I/O, ERR TLER, ARB + I/O, APST, HCTM, INTC + I/O, NQ + I/O, Async Event Config (0x0B) save/set/restore, Keep Alive Timer (0x0F) save/set/restore |
| 18 | I/O Test | `nvme write/read/compare` | 9 | Sequential + offset write+read, compare, write-zeroes, trim, flush, MDTS boundary, multi-namespace |
| 19 | Format NVM | `nvme format` | 4 | Format current LBAF, user data erase (SES=1), alternate LBAF, post-format I/O |
| 20 | Sanitize | `nvme sanitize` | 5 | Block erase, poll progress (600s), verify result, overwrite sanitize, post-sanitize I/O |
| 21 | Namespace Management | `nvme create-ns/delete-ns` | 6 | Create NS, attach, I/O on new NS, detach, delete, verify original NS unaffected |
| 22 | Reservation | `nvme resv-register/acquire` | 5 | Register key, acquire exclusive, report reservations, release, post-release I/O |
| 23 | Reset | `nvme reset` | 7 | Controller reset + re-enumerate, post-reset identify (MN/SN match), post-reset I/O, post-reset register state (CSTS.RDY/CFS, CC.EN), post-reset feature persistence (FID 0x07), post-reset SMART, subsystem reset |
| 24 | Firmware Management | `nvme fw-log`, `nvme fw-commit` | 8 | Read slot info, re-commit active slot (safe no-op), verify unchanged, slot revisions, error cases (slot 0, no-download), fw-download /dev/zero |
| 25 | Additional I/O | `nvme verify`, `nvme write-uncor`, `nvme copy`, `nvme io-passthru` | 11 | Verify command, write-uncor+recovery, copy round-trip, get-lba-status, io-passthru write+read, compare match/mismatch |
| 26 | Security & Directives | `nvme security-recv`, `nvme dir-send/dir-receive` | 10 | Security recv safe probe (SPC-4 discovery), directives enable/disable Streams cycle, admin passthru round-trip |
| 27 | Advanced Admin | `nvme lockdown`, `nvme io-mgmt-recv/send`, `nvme virt-mgmt` | 7 | Lockdown lock/unlock Keep Alive cycle, I/O management recv/send (FDP), virt-mgmt query, capacity-mgmt probe |

## Prerequisites

- Linux with NVMe device(s)
- `nvme-cli` (version 2.x recommended)
- Root privileges (`sudo`)
- Bash 4.0+

```bash
# Install nvme-cli
sudo dnf install nvme-cli      # RHEL/Fedora/CentOS
sudo apt install nvme-cli       # Debian/Ubuntu
```

## Quick Start

```bash
# Run read-only + non-destructive suites (suites 1-16)
sudo ./run_all.sh /dev/nvme0

# Run ALL suites including destructive tests (suites 1-27)
sudo ./run_all.sh /dev/nvme0 --destructive

# Auto-detect first NVMe controller
sudo ./run_all.sh

# Test all NVMe controllers (auto-detects all drives, skips OS drive)
sudo ./run_all.sh --all
sudo ./run_all.sh --all --destructive

# Run a single suite
sudo ./nvme_id_ctrl_test/nvme_id_ctrl_verify.sh /dev/nvme0
sudo ./nvme_feature_set_test/nvme_feature_set_verify.sh /dev/nvme0 --allow-destructive
sudo ./nvme_io_test/nvme_io_verify.sh /dev/nvme0 --allow-destructive
```

### OS Drive Protection

All destructive suites detect and refuse the OS drive:

```
ERROR: /dev/nvme1 is the OS drive — destructive tests REFUSED.
  Root filesystem or /boot is on this controller.
  Use a different NVMe device that does not host the OS.
```

Detection uses `findmnt /`, `lsblk` mount-point scanning, and LVM symlink resolution.

## Repository Structure

```
NVMe_Spec_Certification_Test/
├── run_all.sh                              # Master runner — 27 suites, --destructive, --all flags
├── common/
│   └── nvme_test_lib.sh                    # Shared library (logging, version checks, spec refs,
│                                           #   safe device checks, feature save/restore, write_read_verify)
├── nvme_id_ctrl_test/                      # Suite 1:  Identify Controller
├── nvme_smart_log_test/                    # Suite 2:  SMART / Health Log
├── nvme_error_log_test/                    # Suite 3:  Error Information Log
├── nvme_fw_log_test/                       # Suite 4:  Firmware Slot Info
├── nvme_id_ns_test/                        # Suite 5:  Identify Namespace
├── nvme_power_state_test/                  # Suite 6:  Power State Descriptors
├── nvme_show_regs_test/                    # Suite 7:  Controller Registers
├── nvme_supported_logs_test/               # Suite 8:  Supported Log Pages
├── nvme_effects_log_test/                  # Suite 9:  Commands Effects Log
├── nvme_get_feature_test/                  # Suite 10: Get Features
├── nvme_ns_descs_test/                     # Suite 11: NS ID Descriptors
├── nvme_self_test_log_test/                # Suite 12: Device Self-test Log
├── nvme_dst_functional_test/               # Suite 13: DST Functional
├── nvme_async_event_test/                  # Suite 14: Async Event
├── nvme_additional_logs_test/              # Suite 15: Additional Logs (Behavioral + Read-Only)
├── nvme_additional_id_test/                # Suite 16: Additional Identify (Read-Only)
├── nvme_feature_set_test/                  # Suite 17: Feature Set (Behavioral)
├── nvme_io_test/                           # Suite 18: I/O Test
├── nvme_format_test/                       # Suite 19: Format NVM
├── nvme_sanitize_test/                     # Suite 20: Sanitize
├── nvme_ns_mgmt_test/                      # Suite 21: Namespace Management
├── nvme_reservation_test/                  # Suite 22: Reservation
├── nvme_reset_test/                        # Suite 23: Reset
├── nvme_fw_mgmt_test/                      # Suite 24: Firmware Management (Behavioral)
├── nvme_additional_io_test/                # Suite 25: Additional I/O (Behavioral)
├── nvme_security_directives_test/          # Suite 26: Security & Directives (Behavioral)
├── nvme_advanced_admin_test/               # Suite 27: Advanced Admin (Behavioral)
├── docs/                                   # RST test plan documentation (per-suite step-by-step)
│   ├── index.rst                           #   Master index with toctree
│   └── suite_01_id_ctrl.rst … suite_27_advanced_admin.rst
├── logs/                                   # Auto-generated test logs (not in repo)
└── .gitignore
```

## Output Format

Each test produces color-coded terminal output:

```
  PASS  TEST 1 - VID (PCI Vendor ID) is non-zero (0x144d)
  PASS  TEST 2 - VWC: write+read succeeded with cache disabled
  SKIP  TEST 3 - APST: save current APSTE [APSTA not supported or NVMe < 1.3]
  WARN  TEST 4 - Temperature AER: critical_warning bit 1 not set [controller may batch events]
  FAIL  TEST 5 - VWC: enable write cache [readback did not confirm WCE=1]
```

Result codes follow KCIDB conventions:
- **PASS** — test finished successfully
- **FAIL** — actual test failure (device non-compliance with the NVMe specification)
- **SKIP** — test requirements not fulfilled (incompatible NVMe version, missing hardware feature)
- **WARN** — advisory condition (not a hard failure, but worth noting)

## Logs

Every run generates detailed log files under `logs/`:

```
logs/nvme_id_ctrl_verify_nvme0_20260724_113920.log
logs/nvme_feature_set_verify_nvme0_20260724_114530.log
logs/nvme_io_verify_nvme0_20260724_114600.log
...
```

Each log includes:
- Full command output captured from `nvme-cli`
- Every test result with pass/fail/skip/warn status
- Summary counts

## Documentation

The `docs/` directory contains RST (reStructuredText) test plan files for all 27 suites. Each file documents the sequential execution steps, NVMe commands issued, and pass/fail/skip criteria for every test.

```
docs/
├── index.rst                    # Master index with table of contents
├── suite_01_id_ctrl.rst         # Suite 1:  Identify Controller (45 tests)
├── suite_02_smart_log.rst       # Suite 2:  SMART / Health Log (27 tests)
├── ...
└── suite_27_advanced_admin.rst  # Suite 27: Advanced Admin (7 tests)
```

Each RST file includes:
- **Overview** — what the suite validates and its spec relevance
- **Prerequisites** — root, nvme-cli, device, destructive flag requirements
- **Test Steps** — every test in execution order with `:Command:`, `:Pass:`, `:Fail:`, `:Skip:` fields
- **Result Codes** — KCIDB-compliant PASS/FAIL/SKIP/WARN definitions

## Shared Library

`common/nvme_test_lib.sh` provides:

- `preflight_checks` — verifies root, nvme-cli installed
- `auto_detect_ctrl` / `resolve_ctrl_dev` — device resolution
- `auto_detect_safe_ctrl` / `safe_device_check` / `is_os_drive` — OS drive protection
- `cache_id_ctrl` / `get_id_ctrl_field` / `get_id_ctrl_string_field` — cached Identify Controller data
- `ver_at_least <major> <minor>` — NVMe version gating
- `get_spec_ref <topic>` — dynamic spec section/figure lookup by device version
- `save_feature` / `restore_feature` / `set_feature` / `verify_feature` — feature save/restore for behavioral tests
- `write_read_verify <ns_dev> <lba> <blocks> [block_size]` — write urandom data, read back, compare
- `log_pass` / `log_fail` / `log_skip` / `log_warn` / `log_cmd` — structured output and logging
- `print_header` / `print_summary` — report formatting

## NVMe Spec Coverage

Test output includes the exact spec revision, section, and figure number matched to the device's reported NVMe version. Supported spec revisions: 1.0, 1.1, 1.2, 1.3, 1.4, 2.0, 2.1.

## Development

### Adding a New Test Suite

1. Create a directory: `nvme_<name>_test/`
2. Create the script: `nvme_<name>_verify.sh`
3. Source the shared library: `source "${SCRIPT_DIR}/../common/nvme_test_lib.sh"`
4. Add a `get_spec_ref` entry in `common/nvme_test_lib.sh`
5. Add a `run_suite` call in `run_all.sh`
6. For destructive suites: call `safe_device_check` in `main()`, accept `--allow-destructive`

### Code Quality

```bash
# Syntax check all scripts
find . -name '*.sh' -exec bash -n {} \;

# Lint with shellcheck
find . -name '*.sh' -exec shellcheck -S error {} \;
```

### Field Name Reference

All NVMe field names and bit-field layouts are derived from the [nvme-cli](https://github.com/linux-nvme/nvme-cli) upstream source (`nvme-print-stdout.c`), ensuring consistency with `nvme-cli` output parsing.

## License

GPL-3.0+

## Author

**Utkarsh Singh** (utsingh@redhat.com)

## Tool

Built with [Claude Code](https://claude.ai/code) (Claude Opus 4.6) by Anthropic.
