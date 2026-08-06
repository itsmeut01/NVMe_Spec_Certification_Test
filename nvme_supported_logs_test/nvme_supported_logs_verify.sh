#!/bin/bash
# SPDX-License-Identifier: GPL-3.0+
# Copyright (C) 2025 Red Hat, Inc.
#
# NVMe Supported Log Pages verification
# Based on NVMe Base Specification (NVMe 2.0+ feature)
# Field names from nvme-cli upstream nvme-print-stdout.c
#
# Usage:
#   ./nvme_supported_logs_verify.sh /dev/nvme0
#   ./nvme_supported_logs_verify.sh /dev/nvme0n1
#   ./nvme_supported_logs_verify.sh              # auto-detects first NVMe controller

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/nvme_test_lib.sh
source "${SCRIPT_DIR}/../common/nvme_test_lib.sh"

SLOG_OUTPUT=""

slog_lid_present() {
	echo "$SLOG_OUTPUT" | grep -qi "0x$(printf '%02x' "$1")\|LID $1\|lid=$1\|LID 0x$(printf '%04x' "$1")" || true
}

# --------------------------------------------------------------------------
# Test functions
# --------------------------------------------------------------------------

test_supported_logs_command() {
	if [ -n "$SLOG_OUTPUT" ]; then
		if echo "$SLOG_OUTPUT" | grep -qi "invalid\|not support\|unknown\|error"; then
			log_skip "nvme supported-log-pages command" "command not supported by this nvme-cli or controller"
		else
			log_pass "nvme supported-log-pages command executes successfully"
		fi
	else
		log_skip "nvme supported-log-pages command" "empty output — command may not be supported"
	fi
}

test_error_info_log_listed() {
	if echo "$SLOG_OUTPUT" | grep -qi "0x01\|Error Information"; then
		log_pass "LID 0x01 (Error Information Log) is listed as supported"
	else
		log_fail "LID 0x01 (Error Information Log) must be supported" "not found in supported-log-pages"
	fi
}

test_smart_health_log_listed() {
	if echo "$SLOG_OUTPUT" | grep -qi "0x02\|SMART.*Health"; then
		log_pass "LID 0x02 (SMART / Health Information Log) is listed as supported"
	else
		log_fail "LID 0x02 (SMART / Health Information Log) must be supported" "not found"
	fi
}

test_fw_slot_log_listed() {
	if echo "$SLOG_OUTPUT" | grep -qi "0x03\|Firmware Slot"; then
		log_pass "LID 0x03 (Firmware Slot Information Log) is listed as supported"
	else
		log_fail "LID 0x03 (Firmware Slot Information Log) must be supported" "not found"
	fi
}

test_changed_ns_list_log_listed() {
	if echo "$SLOG_OUTPUT" | grep -qi "0x04\|Changed Namespace"; then
		log_pass "LID 0x04 (Changed Namespace List Log) is listed as supported"
	else
		log_fail "LID 0x04 (Changed Namespace List Log) must be supported" "not found in supported-log-pages"
	fi
}

test_cmd_effects_log_listed() {
	if echo "$SLOG_OUTPUT" | grep -qi "0x05\|Command.*Effects\|Commands Supported"; then
		log_pass "LID 0x05 (Commands Supported and Effects Log) is listed as supported"
	else
		log_fail "LID 0x05 (Commands Supported and Effects Log) must be supported" "not found in supported-log-pages"
	fi
}

test_dst_log_if_supported() {
	local oacs
	oacs=$(get_id_ctrl_field "oacs")
	if [ -z "$oacs" ]; then
		log_skip "LID 0x06 (DST Log) check" "OACS not available"
		return
	fi
	local oacs_int=$((oacs))
	local dst_bit=$(( (oacs_int >> 4) & 0x1 ))
	if [ "$dst_bit" -eq 0 ]; then
		log_skip "LID 0x06 (DST Log) check" "DST not supported (OACS bit 4=0)"
		return
	fi
	if echo "$SLOG_OUTPUT" | grep -qi "0x06\|Device Self-test"; then
		log_pass "LID 0x06 (Device Self-test Log) listed — consistent with OACS bit 4=1"
	else
		log_warn "LID 0x06 (Device Self-test Log) not listed" "OACS bit 4=1 but log not in supported-log-pages"
	fi
}

test_cmd_effects_if_supported() {
	local lpa
	lpa=$(get_id_ctrl_field "lpa")
	if [ -z "$lpa" ]; then
		log_skip "LID 0x05 (Command Effects Log) check" "LPA not available"
		return
	fi
	local lpa_int=$((lpa))
	local celp=$(( (lpa_int >> 1) & 0x1 ))
	if [ "$celp" -eq 0 ]; then
		log_skip "LID 0x05 (Command Effects Log) check" "not supported (LPA bit 1=0)"
		return
	fi
	if echo "$SLOG_OUTPUT" | grep -qi "0x05\|Command.*Effects\|Commands Supported"; then
		log_pass "LID 0x05 (Command Effects Log) listed — consistent with LPA bit 1=1"
	else
		log_warn "LID 0x05 (Command Effects Log) not listed" "LPA bit 1=1 but log not in supported-log-pages"
	fi
}

test_endurance_group_log_if_supported() {
	local ctratt
	ctratt=$(get_id_ctrl_field "ctratt")
	if [ -z "$ctratt" ]; then
		log_skip "LID 0x09 (Endurance Group Information) check" "CTRATT not available"
		return
	fi
	local ctratt_int=$((ctratt))
	local eg_bit=$(( (ctratt_int >> 4) & 0x1 ))
	if [ "$eg_bit" -eq 0 ]; then
		log_skip "LID 0x09 (Endurance Group Information) check" "EG not supported (CTRATT bit 4=0)"
		return
	fi
	if echo "$SLOG_OUTPUT" | grep -qi "0x09\|Endurance Group"; then
		log_pass "LID 0x09 (Endurance Group Information Log) listed — consistent with CTRATT bit 4=1"
	else
		log_warn "LID 0x09 (Endurance Group Information Log) not listed" "CTRATT bit 4=1 but log not in supported-log-pages"
	fi
}

test_power_measurement_log_if_24() {
	if ! ver_at_least 2 4; then
		log_skip "LID 0x17 (Power Measurement) check" "requires NVMe 2.4+"
		return
	fi
	if echo "$SLOG_OUTPUT" | grep -qi "0x17\|Power Measurement"; then
		log_pass "LID 0x17 (Power Measurement Log) is listed — NVMe 2.4 feature"
	else
		log_skip "LID 0x17 (Power Measurement Log) not listed" "optional NVMe 2.4 log page"
	fi
}

test_voltage_measurement_log_if_24() {
	if ! ver_at_least 2 4; then
		log_skip "LID 0x18 (Voltage Measurement) check" "requires NVMe 2.4+"
		return
	fi
	if echo "$SLOG_OUTPUT" | grep -qi "0x18\|Voltage Measurement"; then
		log_pass "LID 0x18 (Voltage Measurement Log) is listed — NVMe 2.4 feature"
	else
		log_skip "LID 0x18 (Voltage Measurement Log) not listed" "optional NVMe 2.4 log page"
	fi
}

test_eom_log_if_pcie_transport() {
	if ! ver_at_least 2 0; then
		log_skip "LID 0x19 (EOM) check" "requires NVMe 2.0+"
		return
	fi
	if echo "$SLOG_OUTPUT" | grep -qi "0x19\|Eye Opening\|EOM"; then
		log_pass "LID 0x19 (Eye Opening Measurement Log) is listed — PCIe Transport 1.4 feature"
	else
		log_skip "LID 0x19 (Eye Opening Measurement Log) not listed" "optional PCIe Transport log page"
	fi
}

test_rate_limiting_log_if_nvm_cs() {
	if ! ver_at_least 2 0; then
		log_skip "LID 0x28 (Rate Limiting) check" "requires NVMe 2.0+"
		return
	fi
	if echo "$SLOG_OUTPUT" | grep -qi "0x28\|Rate Limiting"; then
		log_pass "LID 0x28 (Rate Limiting Log) is listed — NVM CS 1.3 feature"
	else
		log_skip "LID 0x28 (Rate Limiting Log) not listed" "optional NVM CS 1.3 log page"
	fi
}

test_supported_logs_summary() {
	local total_count
	total_count=$(echo "$SLOG_OUTPUT" | grep -ci "0x[0-9a-fA-F]" || true)
	if [ "$total_count" -gt 0 ]; then
		log_pass "Total supported log pages reported: ${total_count}"
	else
		log_pass "Supported log pages summary: could not determine count from output format"
	fi
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

main() {
	preflight_checks

	local ctrl_dev

	if [ $# -eq 0 ]; then
		ctrl_dev=$(auto_detect_ctrl)
		echo -e "${BOLD}No device specified — auto-detected: ${ctrl_dev}${RESET}"
	elif [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
		echo "Usage: $0 [/dev/nvmeX | /dev/nvmeXnY]"
		echo "Verifies NVMe Supported Log Pages per NVMe Base Spec 2.0+."
		exit 0
	else
		ctrl_dev=$(resolve_ctrl_dev "$1")
	fi

	if [ ! -e "$ctrl_dev" ]; then
		echo "ERROR: Device $ctrl_dev does not exist." >&2
		exit 1
	fi

	cache_id_ctrl "$ctrl_dev"

	if ! ver_at_least 2 0; then
		echo -e "${YELLOW}SKIP${RESET}  Supported Log Pages requires NVMe 2.0+ (device reports $(get_nvme_version_str))"
		echo -e "  Skipping entire suite."
		exit 0
	fi

	init_log "nvme_supported_logs_verify" "$ctrl_dev"
	log_cmd "Identify Controller (cached)" "nvme id-ctrl ${ctrl_dev}" "$_ID_CTRL_CACHE"

	local spec_ref
	spec_ref=$(get_spec_ref "supported-logs")

	print_header \
		"NVMe Supported Log Pages — Verification" \
		"$spec_ref" \
		"$ctrl_dev"

	SLOG_OUTPUT=$(nvme supported-log-pages "$ctrl_dev" 2>&1) || true
	log_cmd "Supported Log Pages" "nvme supported-log-pages ${ctrl_dev}" "$SLOG_OUTPUT"

	echo -e "${BOLD}--- Command Access ---${RESET}"
	test_supported_logs_command

	echo ""
	echo -e "${BOLD}--- Mandatory Log Pages ---${RESET}"
	test_error_info_log_listed
	test_smart_health_log_listed
	test_fw_slot_log_listed
	test_changed_ns_list_log_listed
	test_cmd_effects_log_listed

	echo ""
	echo -e "${BOLD}--- Conditional Log Pages ---${RESET}"
	test_dst_log_if_supported
	test_cmd_effects_if_supported
	test_endurance_group_log_if_supported

	echo ""
	echo -e "${BOLD}--- NVM CS 1.3 / PCIe Transport 1.4 Log Pages ---${RESET}"
	test_rate_limiting_log_if_nvm_cs
	test_eom_log_if_pcie_transport

	echo ""
	echo -e "${BOLD}--- NVMe 2.4 Log Pages ---${RESET}"
	test_power_measurement_log_if_24
	test_voltage_measurement_log_if_24

	echo ""
	echo -e "${BOLD}--- Summary ---${RESET}"
	test_supported_logs_summary

	print_summary

	if [ "$FAIL_COUNT" -gt 0 ]; then
		exit 1
	fi
	exit 0
}

main "$@"
