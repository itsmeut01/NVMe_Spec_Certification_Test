# NVMe Certification Project — Code Cache

Generated: 2026-07-30
Auto-updated by developer. Use instead of re-reading entire codebase.

---

## Repository Structure

```
NVME_CETIFICATION/
├── common/nvme_test_lib.sh          (886 lines — shared library, ALL suites source this)
├── run_all.sh                        (orchestrator — runs all 27 suites, supports --all --destructive)
├── logs/                             (test output logs, per-device per-suite)
├── nvme_base_specs/                  (NVMe spec PDFs 1.0e through 2.1 + spec_index_cache.md)
├── project_cache.md                  (THIS FILE)
└── nvme_*_test/                      (27 suite directories, each has one *_verify.sh script)
```

Git remote: `git@github.com:itsmeut01/NVMe_Spec_Certification_Test.git`
Branches: `main` (stable, tagged `v1.0-stable`), `dev` (active development)
Test host: `storageqe-40.fast.eng.rdu2.dc.redhat.com` (SSH port 22, root access)
Test devices: nvme0-nvme5 (6 NVMe drives), OS on /dev/sdb (LVM)

---

## Common Library (`common/nvme_test_lib.sh`) — Key Functions

### Logging (lines 1-80)
- `init_log(suite_name, device)` — creates log file in `logs/`
- `log_cmd(label, cmd, output)` — log raw command output
- `log_pass(msg)`, `log_fail(test, detail)`, `log_skip(test, reason)`, `log_warn(test, detail)`
- Counters: `$PASS_COUNT`, `$FAIL_COUNT`, `$SKIP_COUNT`, `$WARN_COUNT`

### Colors/UI (lines 80-120)
- `$RED`, `$GREEN`, `$YELLOW`, `$BOLD`, `$RESET`, `$CYAN`
- `print_header(title, spec_ref, device)`, `print_summary()`

### Preflight & Device (lines 120-200)
- `preflight_checks()` — root + nvme-cli check
- `resolve_ctrl_dev(arg)`, `resolve_ns_dev(arg)`, `auto_detect_ctrl()`, `auto_detect_safe_ctrl()`
- `list_nvme_devices()`

### Safety (lines 200-280)
- `is_os_drive(dev)` — checks root/boot/efi mounts + lsblk
- `has_mounted_partitions(dev)`
- `safe_device_check(ctrl, allow_flag)` — gatekeeper for destructive suites

### Feature Helpers (lines 280-420)
- `extract_feature_result(output)` — parse hex from get-feature output
- `save_feature(fid, ctrl)` — saves to `_SAVED_FEATURES[fid]` associative array
- `restore_feature(fid, ctrl)` — restores from saved
- `set_feature(fid, value, ctrl)` — `nvme set-feature -f $fid -V $value`
- `verify_feature(fid, expected, ctrl)` — get + compare

### I/O Helpers (lines 420-470)
- `write_read_verify(ns_dev, start_lba, block_count, [block_size])` — write random data, read back, cmp

### id-ctrl Cache (lines 470-560)
- `cache_id_ctrl(ctrl)` — stores in `$_ID_CTRL_CACHE`
- `get_id_ctrl_field(field)` — numeric field from cache
- `get_id_ctrl_string_field(field)` — string field
- `get_field(field)`, `get_string_field(field)`, `get_field_by_label(label)` — generic extractors

### Version & Spec Reference (lines 560-750)
- `ver_at_least(major, minor)` — compare device NVMe version
- `get_nvme_version_str()` — human-readable version
- `get_spec_ref(topic)` — returns spec section reference for a topic (25+ topics supported)

---

## Test Suite Inventory (27 suites, ~377 tests)

### Read-Only Suites (always run) — Suites 1-12

| # | Directory | Script | Tests | FIDs/LIDs/Areas |
|---|-----------|--------|-------|-----------------|
| 1 | nvme_id_ctrl_test | nvme_id_ctrl_verify.sh | 59 | VID,SN,MN,FR,MDTS,VER,CNTRLTYPE,OACS,ONCS,SQES,CQES,NN,etc |
| 2 | nvme_smart_log_test | nvme_smart_log_verify.sh | 27 | critical_warning,temperature(Kelvin helper),spare,percentage_used,data_units,power_cycles,THM |
| 3 | nvme_error_log_test | nvme_error_log_verify.sh | 22 | Entry structure,SQID,CMDID,status,LBA,NSID,opcode,ordering |
| 4 | nvme_fw_log_test | nvme_fw_log_verify.sh | 9 | AFI,FRS slots,active slot cross-check,FRMW ro bit |
| 5 | nvme_id_ns_test | nvme_id_ns_verify.sh | 38 | NSZE,NCAP,NLBAF,FLBAS,DPC,DPS,NMIC,RESCAP,NGUID,EUI64,LBAF validation |
| 6 | nvme_power_state_test | nvme_power_state_verify.sh | 15 | NPSS,PS descriptors,enlat/exlat,rrt/rwt,idle/active power,NOPS |
| 7 | nvme_show_regs_test | nvme_show_regs_verify.sh | 8 | CSTS(RDY,CFS,SHST),CC(EN),CAP(MQES,CSS),VS |
| 8 | nvme_supported_logs_test | nvme_supported_logs_verify.sh | 7 | LID 0x01,0x02,0x03,0x05(conditional),0x06(conditional) |
| 9 | nvme_effects_log_test | nvme_effects_log_verify.sh | 10 | Admin opcodes 06,0A,09,08,0C; I/O opcodes 02,01,00 |
| 10 | nvme_get_feature_test | nvme_get_feature_verify.sh | 10 | FID 0x01,0x02,0x04,0x05,0x06,0x07,0x0C,0x10,0xFF(error) |
| 11 | nvme_ns_descs_test | nvme_ns_descs_verify.sh | 7 | EUI64,NGUID,UUID,CSI,descriptor lengths |
| 12 | nvme_self_test_log_test | nvme_self_test_log_verify.sh | 6 | Current op,completed results,result codes,segments,POH |

### Non-Destructive Functional (always run) — Suites 13-16

| # | Directory | Tests | Area |
|---|-----------|-------|------|
| 13 | nvme_dst_functional_test | 6 | Start short/extended DST, poll, abort |
| 14 | nvme_async_event_test | 4 | AERL check, temp event trigger, error injection |
| 15 | nvme_additional_logs_test | 16 | Telemetry(behavioral),Persistent Event(behavioral),endurance,resv-notif,FID-effects,LBA-status,predictable-lat,boot-part |
| 16 | nvme_additional_id_test | 16 | list-ctrl,list-subsys,primary-ctrl-caps,nvm-id-ctrl,nvm-id-ns,cmdset-ind-id-ns,id-domain,id-nvmset,etc |

### Destructive Suites (require --destructive) — Suites 17-27

| # | Directory | Tests | FIDs/Areas |
|---|-----------|-------|------------|
| 17 | nvme_feature_set_test | 47 | FID 0x01,0x02,0x04,0x05,0x06,0x07,0x08,0x0C,0x10 (save→set→verify→I/O→restore) |
| 18 | nvme_io_test | 9 | Sequential/offset write+read, compare, write-zeroes, DSM/trim, flush, MDTS boundary |
| 19 | nvme_format_test | 4 | Format current LBAF, SES=1 erase, alternate LBAF, I/O after (uses --force) |
| 20 | nvme_sanitize_test | 5 | Block erase, overwrite, poll completion, result check |
| 21 | nvme_ns_mgmt_test | 6 | Create NS, attach, I/O on new NS, detach, delete |
| 22 | nvme_reservation_test | 5 | Register, acquire, report, release, I/O after |
| 23 | nvme_reset_test | 4 | Controller reset, post-reset id/IO, subsystem reset |
| 24 | nvme_fw_mgmt_test | 8 | Read slot info, re-commit active, verify unchanged, error cases |
| 25 | nvme_additional_io_test | 10 | Verify cmd, write-uncor, copy, get-lba-status, io-passthru, compare |
| 26 | nvme_security_directives_test | 10 | security-recv, dir-send/recv (Streams enable→verify→disable→verify), admin-passthru |
| 27 | nvme_advanced_admin_test | 7 | Lockdown (behavioral), io-mgmt recv/send, virt-mgmt, capacity-mgmt |

---

## run_all.sh Flags

| Flag | Purpose |
|------|---------|
| `--all` | Test ALL NVMe controllers (auto-skips OS drives) |
| `--destructive` | Run suites 17-27 (requires non-OS drive) |
| (planned) `--advanced` | Run stress/concurrency/perf suites (future) |

---

## Script Skeleton Pattern (every suite follows this)

```bash
#!/bin/bash
set -euo pipefail
source "${SCRIPT_DIR}/../common/nvme_test_lib.sh"

# Globals: CTRL_DEV, NS_DEV, ALLOW_DESTRUCTIVE (if destructive)

# Helper functions (suite-specific)
# test_*() functions — each calls log_pass/log_fail/log_skip/log_warn

main() {
    preflight_checks
    # Parse args (--allow-destructive, /dev/nvme*, -h)
    # resolve device
    # safe_device_check (if destructive)
    # cache_id_ctrl
    # init_log "suite_name" "$CTRL_DEV"
    # get_spec_ref, print_header
    # --- Section Headers --- with test calls
    # print_summary
    # exit with FAIL_COUNT
}
main "$@"
```

---

## Key nvme-cli Flags (bugs previously found)

- `set-feature`: `-V` = value (NOT `-v` which is verbose) — fixed in commit 41d1fc1
- `format`: `--force` required for nvme-cli v2.x (suppresses 10s confirmation prompt)
- SMART temperature: nvme-cli v2.x format is `temperature : 32 °C (305 K, 89 °F)` — use `smart_get_temp_kelvin()` helper

---

## Spec Reference

- Spec PDFs: `nvme_base_specs/NVMe_Base_Spec_*.pdf` (1.0e through 2.1)
- Spec index: `nvme_base_specs/spec_index_cache.md` — section map, PDF page offsets
- Primary reference: NVMe Base Spec 2.1 (2024-08-05), 684 pages
- PDF page offset for 2.1: spec page + 22
