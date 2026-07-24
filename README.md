# NVMe Certification Test Suite

[![GitHub](https://img.shields.io/badge/GitHub-NVMe__Spec__Certification__Test-blue)](https://github.com/itsmeut01/NVMe_Spec_Certification_Test)

A comprehensive standalone test framework for verifying NVMe SSD compliance against the NVMe Base Specification (revisions 1.0 through 2.1). The suite validates mandatory fields, optional features, cross-field consistency, and deep semantic correctness using `nvme-cli` commands.

## Features

- **12 test suites** covering all major NVMe data structures and commands
- **~218 individual tests** including presence checks, bit-field decoding, cross-validation, and range checks
- **Version-aware testing** — automatically gates checks on the device's reported NVMe version (1.0 through 2.1)
- **Dynamic spec references** — maps the device's NVMe version to the correct spec revision, section, and figure
- **Graceful degradation** — features unsupported by the controller produce SKIP, not false failures
- **Detailed logging** — every command output and test result is logged to timestamped files under `logs/`
- **KCIDB-compliant result codes** — PASS, FAIL, SKIP, WARN

## Test Suites

| # | Suite | Command | Tests | Description |
|---|-------|---------|-------|-------------|
| 1 | Identify Controller | `nvme id-ctrl` | ~62 | Mandatory fields, OACS/ONCS/CTRATT/LPA/SGLS bit decode, thermal cross-checks, capacity validation, reserved bit checks |
| 2 | SMART / Health Log | `nvme smart-log` | ~22 | All SMART fields, spare vs threshold, temperature vs WCTEMP, percentage used, error count cross-validation |
| 3 | Error Information Log | `nvme error-log` | ~13 | Error entries, status field decode, cross-check with SMART num_err_log_entries |
| 4 | Firmware Slot Info | `nvme fw-log` | ~9 | Firmware slot fields, active slot validation |
| 5 | Identify Namespace | `nvme id-ns` | ~38 | Namespace fields, NSFEAT/MC/DPC/DPS/RESCAP/FPI/DLFEAT bit decode, LBA format validation, capacity checks |
| 6 | Power State Descriptors | `nvme id-ctrl` (ps) | ~15 | Power state fields, idle/active vs max power, latency trend, APSTA consistency |
| 7 | Controller Registers | `nvme show-regs` | 8 | CSTS.RDY, CSTS.CFS, CSTS.SHST, CC.EN, CAP.MQES, CAP.CSS, VS vs id-ctrl VER |
| 8 | Supported Log Pages | `nvme supported-log-pages` | 7 | Mandatory LIDs (01h-03h), conditional DST/Effects logs (NVMe 2.0+) |
| 9 | Commands Effects Log | `nvme effects-log` | 10 | Mandatory admin commands (Identify, Get/Set Features, Abort, etc.), I/O commands (Read, Write, Flush) |
| 10 | Get Features | `nvme get-feature` | 10 | Number of Queues, Volatile Write Cache, Power Management, Temperature Threshold, Arbitration, APST, HCTM |
| 11 | NS ID Descriptors | `nvme ns-descs` | 7 | EUI-64, NGUID, UUID presence, at least one non-zero, CSI (2.0+), descriptor lengths |
| 12 | Device Self-test Log | `nvme self-test-log` | 6 | Current operation, completed results, result codes, segment numbers, POH timestamps |

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
# Run all 12 suites against auto-detected NVMe controller
sudo ./run_all.sh

# Run all suites against a specific controller
sudo ./run_all.sh /dev/nvme0

# Run all suites against a specific namespace
sudo ./run_all.sh /dev/nvme0n1

# Run a single suite
sudo ./nvme_id_ctrl_test/nvme_id_ctrl_verify.sh /dev/nvme0
sudo ./nvme_smart_log_test/nvme_smart_log_verify.sh /dev/nvme0
sudo ./nvme_get_feature_test/nvme_get_feature_verify.sh /dev/nvme0
```

## Repository Structure

```
NVME_CETIFICATION/
├── run_all.sh                          # Master runner — executes all 12 suites
├── common/
│   └── nvme_test_lib.sh                # Shared library (logging, version checks, spec refs)
├── nvme_id_ctrl_test/
│   └── nvme_id_ctrl_verify.sh          # Suite 1: Identify Controller
├── nvme_smart_log_test/
│   └── nvme_smart_log_verify.sh        # Suite 2: SMART / Health Log
├── nvme_error_log_test/
│   └── nvme_error_log_verify.sh        # Suite 3: Error Information Log
├── nvme_fw_log_test/
│   └── nvme_fw_log_verify.sh           # Suite 4: Firmware Slot Info
├── nvme_id_ns_test/
│   └── nvme_id_ns_verify.sh            # Suite 5: Identify Namespace
├── nvme_power_state_test/
│   └── nvme_power_state_verify.sh      # Suite 6: Power State Descriptors
├── nvme_show_regs_test/
│   └── nvme_show_regs_verify.sh        # Suite 7: Controller Registers
├── nvme_supported_logs_test/
│   └── nvme_supported_logs_verify.sh   # Suite 8: Supported Log Pages
├── nvme_effects_log_test/
│   └── nvme_effects_log_verify.sh      # Suite 9: Commands Effects Log
├── nvme_get_feature_test/
│   └── nvme_get_feature_verify.sh      # Suite 10: Get Features
├── nvme_ns_descs_test/
│   └── nvme_ns_descs_verify.sh         # Suite 11: NS ID Descriptors
├── nvme_self_test_log_test/
│   └── nvme_self_test_log_verify.sh    # Suite 12: Device Self-test Log
├── logs/                               # Auto-generated test logs (not in repo)
└── .gitignore
```

## Output Format

Each test produces color-coded terminal output:

```
  PASS  TEST 1 - VID (PCI Vendor ID) is non-zero (0x144d)
  PASS  TEST 2 - SN (Serial Number) is non-empty (S4EUNF0N123456)
  SKIP  TEST 3 - CQT (Command Quiesce Time) is reported [requires NVMe 2.1+]
  WARN  TEST 4 - Temperature out of expected range [advisory]
  FAIL  TEST 5 - CSTS.RDY must be 1 [RDY=0 (controller not ready)]
```

Result codes follow KCIDB conventions:
- **PASS** — test finished successfully
- **FAIL** — actual test failure (device non-compliance)
- **SKIP** — test requirements not fulfilled (incompatible NVMe version, missing hardware feature)
- **WARN** — advisory condition (not a hard failure, but worth noting)

## Logs

Every run generates detailed log files under `logs/`:

```
logs/nvme_id_ctrl_verify_nvme0_20260724_113920.log
logs/nvme_smart_log_verify_nvme0_20260724_113920.log
...
```

Each log includes:
- Full command output captured from `nvme-cli`
- Every test result with pass/fail/skip/warn status
- Summary counts

## Shared Library

`common/nvme_test_lib.sh` provides:

- `preflight_checks` — verifies root, nvme-cli installed
- `auto_detect_ctrl` / `resolve_ctrl_dev` — device resolution
- `cache_id_ctrl` / `get_id_ctrl_field` — cached Identify Controller data
- `ver_at_least <major> <minor>` — NVMe version gating
- `get_spec_ref <topic>` — dynamic spec section/figure lookup by device version
- `log_pass` / `log_fail` / `log_skip` / `log_warn` / `log_cmd` — structured output and logging
- `print_header` / `print_summary` — report formatting

## NVMe Spec Coverage

Test output includes the exact spec revision, section, and figure number matched to the device's reported NVMe version.

## Development

### Adding a New Test Suite

1. Create a directory: `nvme_<name>_test/`
2. Create the script: `nvme_<name>_verify.sh`
3. Source the shared library: `source "${SCRIPT_DIR}/../common/nvme_test_lib.sh"`
4. Add a `get_spec_ref` entry in `common/nvme_test_lib.sh`
5. Add a `run_suite` call in `run_all.sh`

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
