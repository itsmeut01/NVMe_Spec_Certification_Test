#!/bin/bash
# SPDX-License-Identifier: GPL-3.0+
# Copyright (C) 2025 Red Hat, Inc.
#
# NVMe Certification — Run All Test Suites
#
# Usage:
#   sudo ./run_all.sh /dev/nvme0
#   sudo ./run_all.sh /dev/nvme0 --destructive
#   sudo ./run_all.sh --all
#   sudo ./run_all.sh --all --destructive

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/common/nvme_test_lib.sh"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

DESTRUCTIVE_MODE=0
ALL_DEVICES_MODE=0

TOTAL_SUITES=0
PASSED_SUITES=0
FAILED_SUITES=0
SUITE_RESULTS=()

OVERALL_DEVICES=0
OVERALL_PASSED_DEVICES=0
OVERALL_FAILED_DEVICES=0
DEVICE_SUMMARIES=()

usage() {
	cat <<'HELPTEXT'
NVMe Certification Test Suite — Master Runner
==============================================

USAGE
    sudo ./run_all.sh [DEVICE] [OPTIONS]

ARGUMENTS
    DEVICE              NVMe controller or namespace device path.
                        Accepts /dev/nvmeX or /dev/nvmeXnY (namespace is
                        resolved to its parent controller automatically).
                        If omitted, the first NVMe controller is auto-detected.

OPTIONS
    --all               Test ALL detected NVMe controllers in sequence.
                        OS drives are auto-detected and skipped.
                        Cannot be combined with a specific device argument.
    --destructive       Also run destructive suites (17-27) that modify device
                        state (format, sanitize, reset, set-feature, etc.).
                        Requires a non-OS NVMe device — the OS drive is always
                        refused regardless of this flag.
    -h, --help          Show this help message and exit.

EXAMPLES
    # Run read-only + non-destructive suites on /dev/nvme0
    sudo ./run_all.sh /dev/nvme0

    # Run ALL suites including destructive tests
    sudo ./run_all.sh /dev/nvme0 --destructive

    # Auto-detect the first NVMe controller (read-only suites only)
    sudo ./run_all.sh

    # Test every NVMe controller on the system
    sudo ./run_all.sh --all

    # Test every NVMe controller with destructive suites
    sudo ./run_all.sh --all --destructive

    # Pass a namespace path (controller is resolved automatically)
    sudo ./run_all.sh /dev/nvme2n1 --destructive

    # Run a single suite directly (each suite has its own --help)
    sudo ./nvme_id_ctrl_test/nvme_id_ctrl_verify.sh /dev/nvme0
    sudo ./nvme_io_test/nvme_io_verify.sh /dev/nvme0 --allow-destructive

OUTPUT
    Each test prints color-coded results: PASS (green), FAIL (red),
    SKIP (yellow), WARN (yellow). Detailed logs are saved under logs/.

OS DRIVE PROTECTION
    Destructive suites detect and refuse the OS drive using findmnt,
    lsblk mount-point scanning, and LVM symlink resolution. This
    protection cannot be overridden.
HELPTEXT
}

DEVICE_ARG=""
for arg in "$@"; do
	case "$arg" in
		-h|--help)
			usage
			exit 0
			;;
		--destructive)
			DESTRUCTIVE_MODE=1
			;;
		--all)
			ALL_DEVICES_MODE=1
			;;
		*)
			DEVICE_ARG="$arg"
			;;
	esac
done

if [ "$(id -u)" -ne 0 ]; then
	echo "ERROR: This script must be run as root." >&2
	exit 1
fi

if ! command -v nvme &>/dev/null; then
	echo "ERROR: nvme-cli is not installed. Install with: dnf install nvme-cli" >&2
	exit 1
fi

if [ "$ALL_DEVICES_MODE" -eq 1 ] && [ -n "$DEVICE_ARG" ]; then
	echo "ERROR: --all cannot be combined with a specific device." >&2
	exit 1
fi

# --------------------------------------------------------------------------
# Device resolution helpers
# --------------------------------------------------------------------------

resolve_devices() {
	local dev="${1:-}"

	CTRL_DEV=""
	NS_DEV=""

	if [ -z "$dev" ]; then
		CTRL_DEV=$(ls -1 /dev/nvme[0-9] 2>/dev/null | head -1)
		if [ -z "$CTRL_DEV" ]; then
			echo "ERROR: No NVMe controllers found in /dev/." >&2
			exit 1
		fi
		echo -e "${BOLD}No device specified — auto-detected: ${CTRL_DEV}${RESET}"
	elif [[ "$dev" =~ ^/dev/nvme[0-9]+n[0-9]+$ ]]; then
		CTRL_DEV="${dev%n*}"
		NS_DEV="$dev"
	elif [[ "$dev" =~ ^/dev/nvme[0-9]+$ ]]; then
		CTRL_DEV="$dev"
	else
		echo "ERROR: '$dev' does not look like an NVMe device (/dev/nvmeX or /dev/nvmeXnY)" >&2
		exit 1
	fi

	if [ ! -e "$CTRL_DEV" ]; then
		echo "ERROR: Device $CTRL_DEV does not exist." >&2
		exit 1
	fi

	if [ -z "$NS_DEV" ]; then
		NS_DEV=$(ls -1 "${CTRL_DEV}n"* 2>/dev/null | grep -E "^${CTRL_DEV}n[0-9]+$" | head -1 || true)
	fi
}

detect_all_controllers() {
	local all_ctrls=()
	local ctrl
	for ctrl in /dev/nvme[0-9]*; do
		[[ "$ctrl" =~ ^/dev/nvme[0-9]+$ ]] || continue
		[ -e "$ctrl" ] || continue
		all_ctrls+=("$ctrl")
	done

	if [ "${#all_ctrls[@]}" -eq 0 ]; then
		echo "ERROR: No NVMe controllers found in /dev/." >&2
		exit 1
	fi

	local safe_ctrls=()
	local skipped_ctrls=()
	for ctrl in "${all_ctrls[@]}"; do
		if is_os_drive "$ctrl"; then
			skipped_ctrls+=("$ctrl")
		else
			safe_ctrls+=("$ctrl")
		fi
	done

	echo -e "${BOLD}Detected ${#all_ctrls[@]} NVMe controller(s):${RESET}"
	for ctrl in "${all_ctrls[@]}"; do
		local model serial
		model=$(nvme id-ctrl "$ctrl" 2>/dev/null | grep "^mn " | sed 's/^mn *: *//' || echo "unknown")
		serial=$(nvme id-ctrl "$ctrl" 2>/dev/null | grep "^sn " | sed 's/^sn *: *//' || echo "unknown")
		if is_os_drive "$ctrl"; then
			local skip_reason="mounted filesystem"
			local root_dev
			root_dev=$(findmnt -n -o SOURCE / 2>/dev/null || true)
			if [ -n "$root_dev" ] && echo "$root_dev" | grep -qw "$(basename "$ctrl")"; then
				skip_reason="OS root drive"
			fi
			echo -e "  ${YELLOW}SKIP${RESET}  ${ctrl}  ${model}  (SN: ${serial})  [${skip_reason}]"
		else
			echo -e "  ${GREEN} OK ${RESET}  ${ctrl}  ${model}  (SN: ${serial})"
		fi
	done

	if [ "${#safe_ctrls[@]}" -eq 0 ]; then
		echo ""
		echo "ERROR: All detected controllers are OS drives. Nothing to test." >&2
		exit 1
	fi

	echo ""
	echo -e "${BOLD}Testing ${#safe_ctrls[@]} drive(s), skipping ${#skipped_ctrls[@]} OS drive(s)${RESET}"

	DETECTED_CONTROLLERS=("${safe_ctrls[@]}")
}

# --------------------------------------------------------------------------
# Device health check and recovery
# --------------------------------------------------------------------------

recover_device() {
	local ctrl="$1"
	if [ -e "$ctrl" ]; then
		nvme ns-rescan "$ctrl" 2>/dev/null || true
		sleep 1
		return 0
	fi

	echo -e "  ${YELLOW}RECOVERING${RESET}  ${ctrl} disappeared — triggering PCI rescan..."
	echo 1 > /sys/bus/pci/rescan 2>/dev/null || true
	local waited=0
	while [ "$waited" -lt 30 ]; do
		if [ -e "$ctrl" ]; then
			nvme ns-rescan "$ctrl" 2>/dev/null || true
			sleep 2
			echo -e "  ${GREEN}RECOVERED${RESET}  ${ctrl} is back"
			return 0
		fi
		sleep 2
		waited=$((waited + 2))
	done

	echo -e "  ${RED}UNRECOVERABLE${RESET}  ${ctrl} did not come back after 30s"
	return 1
}

# --------------------------------------------------------------------------
# Suite runner
# --------------------------------------------------------------------------

run_suite() {
	local name="$1"
	local script="$2"
	local device="$3"
	shift 3

	TOTAL_SUITES=$((TOTAL_SUITES + 1))

	echo ""
	echo -e "${BOLD}>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>${RESET}"
	echo -e "${BOLD}>>> Suite ${TOTAL_SUITES}: ${name}${RESET}"
	echo -e "${BOLD}>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>${RESET}"

	local exit_code=0
	"${SCRIPT_DIR}/${script}" "$device" "$@" || exit_code=$?

	if [ "$exit_code" -eq 0 ]; then
		PASSED_SUITES=$((PASSED_SUITES + 1))
		SUITE_RESULTS+=("$(printf "  ${GREEN}PASS${RESET}  Suite %d: %s" "$TOTAL_SUITES" "$name")")
	else
		FAILED_SUITES=$((FAILED_SUITES + 1))
		SUITE_RESULTS+=("$(printf "  ${RED}FAIL${RESET}  Suite %d: %s (exit code %d)" "$TOTAL_SUITES" "$name" "$exit_code")")
	fi
}

# --------------------------------------------------------------------------
# Run all suites for a single device
# --------------------------------------------------------------------------

run_suites_for_device() {
	local ctrl="$1"
	local ns=""

	ns=$(ls -1 "${ctrl}n"* 2>/dev/null | grep -E "^${ctrl}n[0-9]+$" | head -1 || true)

	TOTAL_SUITES=0
	PASSED_SUITES=0
	FAILED_SUITES=0
	SUITE_RESULTS=()

	local dev_ts_start
	dev_ts_start=$(date '+%Y-%m-%d %H:%M:%S %Z')

	local model serial
	model=$(nvme id-ctrl "$ctrl" 2>/dev/null | grep "^mn " | sed 's/^mn *: *//' || echo "unknown")
	serial=$(nvme id-ctrl "$ctrl" 2>/dev/null | grep "^sn " | sed 's/^sn *: *//' || echo "unknown")

	echo ""
	echo -e "${BOLD}####################################################################${RESET}"
	echo -e "${BOLD}#          NVMe Certification — ${ctrl}${RESET}"
	echo -e "${BOLD}####################################################################${RESET}"
	echo -e "  Controller:  ${ctrl}"
	echo -e "  Model:       ${model}"
	echo -e "  Serial:      ${serial}"
	if [ -n "$ns" ]; then
		echo -e "  Namespace:   ${ns}"
	fi
	if [ "$DESTRUCTIVE_MODE" -eq 1 ]; then
		echo -e "  Mode:        ${RED}DESTRUCTIVE${RESET} (read-only + functional + destructive)"
	else
		echo -e "  Mode:        Read-only + non-destructive functional"
	fi
	echo -e "  Started:     ${dev_ts_start}"
	echo -e "${BOLD}####################################################################${RESET}"

	# ------------------------------------------------------------------
	# Read-only suites
	# ------------------------------------------------------------------

	run_suite "Identify Controller — Mandatory Fields" \
		"nvme_id_ctrl_test/nvme_id_ctrl_verify.sh" "$ctrl"

	run_suite "SMART / Health Information Log" \
		"nvme_smart_log_test/nvme_smart_log_verify.sh" "$ctrl"

	run_suite "Error Information Log" \
		"nvme_error_log_test/nvme_error_log_verify.sh" "$ctrl"

	run_suite "Firmware Slot Information Log" \
		"nvme_fw_log_test/nvme_fw_log_verify.sh" "$ctrl"

	if [ -n "$ns" ]; then
		run_suite "Identify Namespace" \
			"nvme_id_ns_test/nvme_id_ns_verify.sh" "$ns"
	else
		echo ""
		echo -e "  ${YELLOW}SKIP${RESET}  Suite 5: Identify Namespace — no namespace device found for ${ctrl}"
		TOTAL_SUITES=$((TOTAL_SUITES + 1))
		SUITE_RESULTS+=("$(printf "  ${YELLOW}SKIP${RESET}  Suite %d: Identify Namespace — no namespace device" "$TOTAL_SUITES")")
	fi

	run_suite "Power State Descriptors" \
		"nvme_power_state_test/nvme_power_state_verify.sh" "$ctrl"

	run_suite "Controller Registers" \
		"nvme_show_regs_test/nvme_show_regs_verify.sh" "$ctrl"

	run_suite "Supported Log Pages" \
		"nvme_supported_logs_test/nvme_supported_logs_verify.sh" "$ctrl"

	run_suite "Commands Supported and Effects Log" \
		"nvme_effects_log_test/nvme_effects_log_verify.sh" "$ctrl"

	run_suite "Get Features" \
		"nvme_get_feature_test/nvme_get_feature_verify.sh" "$ctrl"

	if [ -n "$ns" ]; then
		run_suite "Namespace ID Descriptors" \
			"nvme_ns_descs_test/nvme_ns_descs_verify.sh" "$ns"
	else
		echo ""
		echo -e "  ${YELLOW}SKIP${RESET}  Suite: Namespace ID Descriptors — no namespace device found for ${ctrl}"
		TOTAL_SUITES=$((TOTAL_SUITES + 1))
		SUITE_RESULTS+=("$(printf "  ${YELLOW}SKIP${RESET}  Suite %d: NS ID Descriptors — no namespace device" "$TOTAL_SUITES")")
	fi

	run_suite "Device Self-test Log" \
		"nvme_self_test_log_test/nvme_self_test_log_verify.sh" "$ctrl"

	# ------------------------------------------------------------------
	# Non-destructive functional suites
	# ------------------------------------------------------------------

	run_suite "DST Functional" \
		"nvme_dst_functional_test/nvme_dst_functional_verify.sh" "$ctrl"

	run_suite "Async Event" \
		"nvme_async_event_test/nvme_async_event_verify.sh" "$ctrl"

	# ------------------------------------------------------------------
	# Non-destructive — additional logs and identify
	# ------------------------------------------------------------------

	run_suite "Additional Logs" \
		"nvme_additional_logs_test/nvme_additional_logs_verify.sh" "$ctrl"

	if [ -n "$ns" ]; then
		run_suite "Additional Identify" \
			"nvme_additional_id_test/nvme_additional_id_verify.sh" "$ns"

		run_suite "ZNS Command Set" \
			"nvme_zns_test/nvme_zns_verify.sh" "$ns"

		run_suite "KV Command Set" \
			"nvme_kv_test/nvme_kv_verify.sh" "$ns"
	else
		echo ""
		echo -e "  ${YELLOW}SKIP${RESET}  Suite: Additional Identify — no namespace device found for ${ctrl}"
		TOTAL_SUITES=$((TOTAL_SUITES + 1))
		SUITE_RESULTS+=("$(printf "  ${YELLOW}SKIP${RESET}  Suite %d: Additional Identify — no namespace device" "$TOTAL_SUITES")")
		TOTAL_SUITES=$((TOTAL_SUITES + 1))
		SUITE_RESULTS+=("$(printf "  ${YELLOW}SKIP${RESET}  Suite %d: ZNS Command Set — no namespace device" "$TOTAL_SUITES")")
		TOTAL_SUITES=$((TOTAL_SUITES + 1))
		SUITE_RESULTS+=("$(printf "  ${YELLOW}SKIP${RESET}  Suite %d: KV Command Set — no namespace device" "$TOTAL_SUITES")")
	fi

	# ------------------------------------------------------------------
	# Destructive suites
	# ------------------------------------------------------------------

	if [ "$DESTRUCTIVE_MODE" -eq 1 ]; then
		echo ""
		echo -e "${BOLD}####################################################################${RESET}"
		echo -e "${BOLD}#          Destructive / Functional — ${ctrl}${RESET}"
		echo -e "${BOLD}####################################################################${RESET}"

		if [ -n "$ns" ]; then
			run_suite "Feature Set (Behavioral)" \
				"nvme_feature_set_test/nvme_feature_set_verify.sh" "$ctrl" --allow-destructive

			run_suite "I/O Test" \
				"nvme_io_test/nvme_io_verify.sh" "$ctrl" --allow-destructive

			run_suite "Format NVM" \
				"nvme_format_test/nvme_format_verify.sh" "$ctrl" --allow-destructive

			run_suite "Sanitize" \
				"nvme_sanitize_test/nvme_sanitize_verify.sh" "$ctrl" --allow-destructive

			run_suite "Namespace Management" \
				"nvme_ns_mgmt_test/nvme_ns_mgmt_verify.sh" "$ctrl" --allow-destructive

			run_suite "Reservation" \
				"nvme_reservation_test/nvme_reservation_verify.sh" "$ctrl" --allow-destructive

			run_suite "Reset" \
				"nvme_reset_test/nvme_reset_verify.sh" "$ctrl" --allow-destructive

			run_suite "Firmware Management" \
				"nvme_fw_mgmt_test/nvme_fw_mgmt_verify.sh" "$ctrl" --allow-destructive

			if ! recover_device "$ctrl"; then
				echo -e "  ${RED}SKIP${RESET}  Remaining suites — controller ${ctrl} unrecoverable after reset/fw-mgmt"
				for _skip_name in "Additional I/O" "Security & Directives" "Advanced Admin"; do
					TOTAL_SUITES=$((TOTAL_SUITES + 1))
					FAILED_SUITES=$((FAILED_SUITES + 1))
					SUITE_RESULTS+=("$(printf "  ${RED}FAIL${RESET}  Suite %d: %s (controller lost)" "$TOTAL_SUITES" "$_skip_name")")
				done
			else
				ns=$(ls -1 "${ctrl}n"* 2>/dev/null | grep -E "^${ctrl}n[0-9]+$" | head -1 || true)
			fi

			if [ -e "$ctrl" ] && [ -n "$ns" ]; then
				run_suite "Additional I/O" \
					"nvme_additional_io_test/nvme_additional_io_verify.sh" "$ctrl" --allow-destructive

				run_suite "Security & Directives" \
					"nvme_security_directives_test/nvme_security_directives_verify.sh" "$ctrl" --allow-destructive

				run_suite "Advanced Admin" \
					"nvme_advanced_admin_test/nvme_advanced_admin_verify.sh" "$ctrl" --allow-destructive
			fi
		else
			echo ""
			echo -e "  ${YELLOW}SKIP${RESET}  Destructive suites — no namespace device found for ${ctrl}"
			for _suite_name in "Feature Set" "I/O Test" "Format NVM" "Sanitize" "Namespace Management" "Reservation" "Reset" "Firmware Management" "Additional I/O" "Security & Directives" "Advanced Admin"; do
				TOTAL_SUITES=$((TOTAL_SUITES + 1))
				SUITE_RESULTS+=("$(printf "  ${YELLOW}SKIP${RESET}  Suite %d: %s — no namespace device" "$TOTAL_SUITES" "$_suite_name")")
			done
		fi
	else
		echo ""
		echo -e "  ${YELLOW}NOTE${RESET}  Destructive suites skipped (pass --destructive to run them)"
	fi

	# ------------------------------------------------------------------
	# Per-device summary
	# ------------------------------------------------------------------

	local dev_ts_end
	dev_ts_end=$(date '+%Y-%m-%d %H:%M:%S %Z')

	echo ""
	echo -e "${BOLD}--------------------------------------------------------------------${RESET}"
	echo -e "${BOLD}  Results for ${ctrl}  (${model})${RESET}"
	echo -e "${BOLD}--------------------------------------------------------------------${RESET}"
	echo ""

	for result in "${SUITE_RESULTS[@]}"; do
		echo -e "$result"
	done

	echo ""
	echo -e "  Suites:  ${GREEN}PASS: ${PASSED_SUITES}${RESET}  ${RED}FAIL: ${FAILED_SUITES}${RESET}  Total: ${TOTAL_SUITES}"
	echo -e "  Started: ${dev_ts_start}"
	echo -e "  Ended:   ${dev_ts_end}"
	echo -e "${BOLD}--------------------------------------------------------------------${RESET}"

	local log_files
	log_files=$(ls -1t "${SCRIPT_DIR}/logs/"*"$(echo "$ctrl" | sed 's|/dev/||')"* 2>/dev/null | head -30 || true)
	if [ -n "$log_files" ]; then
		echo ""
		echo -e "${BOLD}  Log files:${RESET}"
		echo "$log_files" | while IFS= read -r f; do
			echo "    $f"
		done
	fi

	OVERALL_DEVICES=$((OVERALL_DEVICES + 1))
	if [ "$FAILED_SUITES" -gt 0 ]; then
		OVERALL_FAILED_DEVICES=$((OVERALL_FAILED_DEVICES + 1))
		DEVICE_SUMMARIES+=("$(printf "  ${RED}FAIL${RESET}  %-14s  %-40s  PASS: %d  FAIL: %d  Total: %d" "$ctrl" "$model" "$PASSED_SUITES" "$FAILED_SUITES" "$TOTAL_SUITES")")
	else
		OVERALL_PASSED_DEVICES=$((OVERALL_PASSED_DEVICES + 1))
		DEVICE_SUMMARIES+=("$(printf "  ${GREEN}PASS${RESET}  %-14s  %-40s  PASS: %d  FAIL: %d  Total: %d" "$ctrl" "$model" "$PASSED_SUITES" "$FAILED_SUITES" "$TOTAL_SUITES")")
	fi
}

# ==========================================================================
# Main
# ==========================================================================

TS_START=$(date '+%Y-%m-%d %H:%M:%S %Z')

echo ""
echo -e "${BOLD}####################################################################${RESET}"
echo -e "${BOLD}#          NVMe Certification — Full Test Run                      #${RESET}"
echo -e "${BOLD}####################################################################${RESET}"
echo -e "  Started:     ${TS_START}"
echo -e "  Hostname:    $(hostname)"
echo -e "  Kernel:      $(uname -r)"
echo -e "  nvme-cli:    $(nvme version 2>/dev/null || echo 'unknown')"
if [ "$ALL_DEVICES_MODE" -eq 1 ]; then
	echo -e "  Scope:       ${CYAN}ALL NVMe drives${RESET} (OS drives auto-skipped)"
fi
if [ "$DESTRUCTIVE_MODE" -eq 1 ]; then
	echo -e "  Mode:        ${RED}DESTRUCTIVE${RESET}"
else
	echo -e "  Mode:        Read-only + non-destructive functional"
fi
echo -e "${BOLD}####################################################################${RESET}"

DETECTED_CONTROLLERS=()
ANY_FAILURES=0

if [ "$ALL_DEVICES_MODE" -eq 1 ]; then
	detect_all_controllers

	for ctrl_dev in "${DETECTED_CONTROLLERS[@]}"; do
		run_suites_for_device "$ctrl_dev"
	done
else
	resolve_devices "$DEVICE_ARG"
	run_suites_for_device "$CTRL_DEV"
fi

# --------------------------------------------------------------------------
# Overall summary (shown when testing multiple devices or always as final)
# --------------------------------------------------------------------------

TS_END=$(date '+%Y-%m-%d %H:%M:%S %Z')

if [ "$OVERALL_DEVICES" -gt 1 ]; then
	echo ""
	echo ""
	echo -e "${BOLD}####################################################################${RESET}"
	echo -e "${BOLD}#          NVMe Certification — Overall Results                    #${RESET}"
	echo -e "${BOLD}####################################################################${RESET}"
	echo ""

	for summary in "${DEVICE_SUMMARIES[@]}"; do
		echo -e "$summary"
	done

	echo ""
	echo -e "${BOLD}--------------------------------------------------------------------${RESET}"
	echo -e "  Devices: ${GREEN}PASS: ${OVERALL_PASSED_DEVICES}${RESET}  ${RED}FAIL: ${OVERALL_FAILED_DEVICES}${RESET}  Total: ${OVERALL_DEVICES}"
	echo -e "  Started: ${TS_START}"
	echo -e "  Ended:   ${TS_END}"
	echo -e "${BOLD}--------------------------------------------------------------------${RESET}"
fi

echo ""

if [ "$OVERALL_FAILED_DEVICES" -gt 0 ]; then
	exit 1
fi
exit 0
