#!/bin/bash
# SPDX-License-Identifier: GPL-3.0+
# Copyright (C) 2025 Red Hat, Inc.
#
# NVMe Certification — Run All Test Suites
#
# Usage:
#   sudo ./run_all.sh /dev/nvme0
#   sudo ./run_all.sh /dev/nvme0n1
#   sudo ./run_all.sh              # auto-detects first NVMe controller

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
RESET='\033[0m'

TOTAL_SUITES=0
PASSED_SUITES=0
FAILED_SUITES=0
SUITE_RESULTS=()

usage() {
	echo "Usage: $0 [/dev/nvmeX | /dev/nvmeXnY]"
	echo ""
	echo "Runs all NVMe certification test suites and produces a combined report."
	echo "Requires root privileges and the nvme-cli package."
	echo ""
	echo "If no device is given, the first NVMe controller found is used."
	echo ""
	echo "Test suites:"
	echo "  1.  Identify Controller      (nvme id-ctrl)"
	echo "  2.  SMART / Health Log       (nvme smart-log)"
	echo "  3.  Error Information Log    (nvme error-log)"
	echo "  4.  Firmware Slot Info Log   (nvme fw-log)"
	echo "  5.  Identify Namespace       (nvme id-ns)"
	echo "  6.  Power State Descriptors  (nvme id-ctrl ps)"
	echo "  7.  Controller Registers     (nvme show-regs)"
	echo "  8.  Supported Log Pages      (nvme supported-log-pages, 2.0+)"
	echo "  9.  Commands Effects Log     (nvme effects-log)"
	echo "  10. Get Features             (nvme get-feature)"
	echo "  11. NS ID Descriptors        (nvme ns-descs)"
	echo "  12. Device Self-test Log     (nvme self-test-log)"
}

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
	usage
	exit 0
fi

if [ "$(id -u)" -ne 0 ]; then
	echo "ERROR: This script must be run as root." >&2
	exit 1
fi

if ! command -v nvme &>/dev/null; then
	echo "ERROR: nvme-cli is not installed. Install with: dnf install nvme-cli" >&2
	exit 1
fi

CTRL_DEV=""
NS_DEV=""

resolve_devices() {
	local dev="${1:-}"

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
		NS_DEV=$(ls -1 "${CTRL_DEV}n"* 2>/dev/null | grep -E "^${CTRL_DEV}n[0-9]+$" | head -1)
	fi
}

run_suite() {
	local name="$1"
	local script="$2"
	local device="$3"

	TOTAL_SUITES=$((TOTAL_SUITES + 1))

	echo ""
	echo -e "${BOLD}>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>${RESET}"
	echo -e "${BOLD}>>> Suite ${TOTAL_SUITES}: ${name}${RESET}"
	echo -e "${BOLD}>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>${RESET}"

	local exit_code=0
	"${SCRIPT_DIR}/${script}" "$device" || exit_code=$?

	if [ "$exit_code" -eq 0 ]; then
		PASSED_SUITES=$((PASSED_SUITES + 1))
		SUITE_RESULTS+=("$(printf "  ${GREEN}PASS${RESET}  Suite %d: %s" "$TOTAL_SUITES" "$name")")
	else
		FAILED_SUITES=$((FAILED_SUITES + 1))
		SUITE_RESULTS+=("$(printf "  ${RED}FAIL${RESET}  Suite %d: %s (exit code %d)" "$TOTAL_SUITES" "$name" "$exit_code")")
	fi
}

resolve_devices "${1:-}"

TS_START=$(date '+%Y-%m-%d %H:%M:%S %Z')

echo ""
echo -e "${BOLD}####################################################################${RESET}"
echo -e "${BOLD}#          NVMe Certification — Full Test Run                      #${RESET}"
echo -e "${BOLD}####################################################################${RESET}"
echo -e "  Controller:  ${CTRL_DEV}"
if [ -n "$NS_DEV" ]; then
	echo -e "  Namespace:   ${NS_DEV}"
fi
echo -e "  Started:     ${TS_START}"
echo -e "  Hostname:    $(hostname)"
echo -e "  Kernel:      $(uname -r)"
echo -e "  nvme-cli:    $(nvme version 2>/dev/null || echo 'unknown')"
echo -e "${BOLD}####################################################################${RESET}"

run_suite "Identify Controller — Mandatory Fields" \
	"nvme_id_ctrl_test/nvme_id_ctrl_verify.sh" "$CTRL_DEV"

run_suite "SMART / Health Information Log" \
	"nvme_smart_log_test/nvme_smart_log_verify.sh" "$CTRL_DEV"

run_suite "Error Information Log" \
	"nvme_error_log_test/nvme_error_log_verify.sh" "$CTRL_DEV"

run_suite "Firmware Slot Information Log" \
	"nvme_fw_log_test/nvme_fw_log_verify.sh" "$CTRL_DEV"

if [ -n "$NS_DEV" ]; then
	run_suite "Identify Namespace" \
		"nvme_id_ns_test/nvme_id_ns_verify.sh" "$NS_DEV"
else
	echo ""
	echo -e "  ${YELLOW}SKIP${RESET}  Suite 5: Identify Namespace — no namespace device found for ${CTRL_DEV}"
	TOTAL_SUITES=$((TOTAL_SUITES + 1))
	SUITE_RESULTS+=("$(printf "  ${YELLOW}SKIP${RESET}  Suite %d: Identify Namespace — no namespace device" "$TOTAL_SUITES")")
fi

run_suite "Power State Descriptors" \
	"nvme_power_state_test/nvme_power_state_verify.sh" "$CTRL_DEV"

run_suite "Controller Registers" \
	"nvme_show_regs_test/nvme_show_regs_verify.sh" "$CTRL_DEV"

run_suite "Supported Log Pages" \
	"nvme_supported_logs_test/nvme_supported_logs_verify.sh" "$CTRL_DEV"

run_suite "Commands Supported and Effects Log" \
	"nvme_effects_log_test/nvme_effects_log_verify.sh" "$CTRL_DEV"

run_suite "Get Features" \
	"nvme_get_feature_test/nvme_get_feature_verify.sh" "$CTRL_DEV"

if [ -n "$NS_DEV" ]; then
	run_suite "Namespace ID Descriptors" \
		"nvme_ns_descs_test/nvme_ns_descs_verify.sh" "$NS_DEV"
else
	echo ""
	echo -e "  ${YELLOW}SKIP${RESET}  Suite: Namespace ID Descriptors — no namespace device found for ${CTRL_DEV}"
	TOTAL_SUITES=$((TOTAL_SUITES + 1))
	SUITE_RESULTS+=("$(printf "  ${YELLOW}SKIP${RESET}  Suite %d: NS ID Descriptors — no namespace device" "$TOTAL_SUITES")")
fi

run_suite "Device Self-test Log" \
	"nvme_self_test_log_test/nvme_self_test_log_verify.sh" "$CTRL_DEV"

TS_END=$(date '+%Y-%m-%d %H:%M:%S %Z')

echo ""
echo -e "${BOLD}####################################################################${RESET}"
echo -e "${BOLD}#          NVMe Certification — Combined Results                   #${RESET}"
echo -e "${BOLD}####################################################################${RESET}"
echo ""

for result in "${SUITE_RESULTS[@]}"; do
	echo -e "$result"
done

echo ""
echo -e "${BOLD}--------------------------------------------------------------------${RESET}"
echo -e "  Suites:  ${GREEN}PASS: ${PASSED_SUITES}${RESET}  ${RED}FAIL: ${FAILED_SUITES}${RESET}  Total: ${TOTAL_SUITES}"
echo -e "  Started: ${TS_START}"
echo -e "  Ended:   ${TS_END}"
echo -e "${BOLD}--------------------------------------------------------------------${RESET}"

LOG_FILES=$(ls -1t "${SCRIPT_DIR}/logs/"*"$(echo "$CTRL_DEV" | sed 's|/dev/||')"* 2>/dev/null | head -12)
if [ -n "$LOG_FILES" ]; then
	echo ""
	echo -e "${BOLD}  Log files:${RESET}"
	echo "$LOG_FILES" | while IFS= read -r f; do
		echo "    $f"
	done
fi

echo ""

if [ "$FAILED_SUITES" -gt 0 ]; then
	exit 1
fi
exit 0
