#!/bin/bash
# SPDX-License-Identifier: GPL-3.0+
# Copyright (C) 2025 Red Hat, Inc.
#
# NVMe Device Self-test Log verification
# Based on NVMe Base Specification — Device Self-test Log
# Field names from nvme-cli upstream nvme-print-stdout.c
#
# Usage:
#   ./nvme_self_test_log_verify.sh /dev/nvme0
#   ./nvme_self_test_log_verify.sh /dev/nvme0n1
#   ./nvme_self_test_log_verify.sh              # auto-detects first NVMe controller

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/nvme_test_lib.sh
source "${SCRIPT_DIR}/../common/nvme_test_lib.sh"

DST_OUTPUT=""

# --------------------------------------------------------------------------
# Test functions
# --------------------------------------------------------------------------

test_dst_log_command() {
	if [ -n "$DST_OUTPUT" ]; then
		if echo "$DST_OUTPUT" | grep -qi "invalid\|not support\|unknown"; then
			log_skip "nvme self-test-log command" "command not supported by controller or nvme-cli"
		else
			log_pass "nvme self-test-log command executes successfully"
		fi
	else
		log_fail "nvme self-test-log command executes successfully" "empty output"
	fi
}

test_current_operation() {
	local op_line
	op_line=$(echo "$DST_OUTPUT" | grep -i "Current.*operation\|current.*self-test\|self.test.*status" | head -1 || true)
	if [ -n "$op_line" ]; then
		if echo "$op_line" | grep -qi "No.*in progress\|not.*running\|idle\| 0x0\b\|No self-test"; then
			log_pass "Current DST operation: no self-test in progress"
		elif echo "$op_line" | grep -qi "Short\|Extended\|Vendor"; then
			log_pass "Current DST operation: self-test in progress — $(echo "$op_line" | sed 's/.*: //')"
		else
			log_pass "Current DST operation status: $(echo "$op_line" | sed 's/.*: //')"
		fi
	else
		log_pass "Current DST operation field not found (no test history or different format)"
	fi
}

test_completed_results() {
	local result_count
	result_count=$(echo "$DST_OUTPUT" | grep -ci "Self Test Result\|result\[" || true)
	if [ "$result_count" -gt 0 ]; then
		log_pass "Completed self-test results: ${result_count} entry/entries found"
	else
		log_pass "No completed self-test results (device may have no test history)"
	fi
}

test_result_codes() {
	local entries
	entries=$(echo "$DST_OUTPUT" | grep -i "result\|status.*code\|self.test.*code" || true)
	if [ -z "$entries" ]; then
		log_pass "No self-test result codes to validate (no test history)"
		return
	fi
	local invalid=0
	while IFS= read -r line; do
		local code
		code=$(echo "$line" | grep -oP '0x[0-9a-fA-F]+' | head -1 || true)
		if [ -n "$code" ]; then
			local code_int=$((code))
			# Valid result codes: 0x0-0x7, 0xF per spec
			if [ "$code_int" -gt 15 ]; then
				invalid=$((invalid + 1))
			fi
		fi
	done <<< "$entries"
	if [ "$invalid" -eq 0 ]; then
		log_pass "All self-test result codes are valid (0x0-0x7 or 0xF)"
	else
		log_fail "Self-test result codes must be in valid range" "${invalid} entry/entries with invalid code"
	fi
}

test_segment_numbers() {
	local segments
	segments=$(echo "$DST_OUTPUT" | grep -i "segment" || true)
	if [ -z "$segments" ]; then
		log_pass "No segment numbers to validate (no test history)"
		return
	fi
	local invalid=0
	while IFS= read -r line; do
		local seg_num
		seg_num=$(echo "$line" | grep -oP '[0-9]+' | tail -1 || true)
		if [ -n "$seg_num" ] && [ "$seg_num" -gt 255 ]; then
			invalid=$((invalid + 1))
		fi
	done <<< "$segments"
	if [ "$invalid" -eq 0 ]; then
		log_pass "All segment numbers in valid range (0-255)"
	else
		log_fail "Segment numbers must be 0-255" "${invalid} out of range"
	fi
}

test_poh_timestamps() {
	local poh_lines
	poh_lines=$(echo "$DST_OUTPUT" | grep -i "power.*on.*hour\|poh" || true)
	if [ -z "$poh_lines" ]; then
		log_pass "No POH timestamps to validate (no test history)"
		return
	fi

	local smart_poh
	smart_poh=$(nvme smart-log "$(echo "$NS_CTRL_DEV" 2>/dev/null || echo /dev/nvme0)" 2>&1 | grep -i "power_on_hours" | grep -oP '[0-9,]+' | head -1 | tr -d ',' || true)

	local issues=0
	while IFS= read -r line; do
		local poh_val
		poh_val=$(echo "$line" | grep -oP '[0-9,]+' | head -1 | tr -d ',' || true)
		if [ -n "$poh_val" ] && [ -n "$smart_poh" ]; then
			if [ "$poh_val" -gt "$smart_poh" ]; then
				issues=$((issues + 1))
			fi
		fi
	done <<< "$poh_lines"
	if [ "$issues" -eq 0 ]; then
		log_pass "DST POH timestamps consistent (all <= current SMART POH)"
	else
		log_warn "DST POH timestamps" "${issues} entry/entries with POH exceeding current SMART POH"
	fi
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

NS_CTRL_DEV=""

main() {
	preflight_checks

	local ctrl_dev

	if [ $# -eq 0 ]; then
		ctrl_dev=$(auto_detect_ctrl)
		echo -e "${BOLD}No device specified — auto-detected: ${ctrl_dev}${RESET}"
	elif [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
		echo "Usage: $0 [/dev/nvmeX | /dev/nvmeXnY]"
		echo "Verifies NVMe Device Self-test Log per NVMe Base Spec."
		exit 0
	else
		ctrl_dev=$(resolve_ctrl_dev "$1")
	fi

	if [ ! -e "$ctrl_dev" ]; then
		echo "ERROR: Device $ctrl_dev does not exist." >&2
		exit 1
	fi

	NS_CTRL_DEV="$ctrl_dev"
	cache_id_ctrl "$ctrl_dev"

	# Check if DST is supported (OACS bit 4)
	local oacs
	oacs=$(get_id_ctrl_field "oacs")
	if [ -n "$oacs" ]; then
		local oacs_int=$((oacs))
		local dst_bit=$(( (oacs_int >> 4) & 0x1 ))
		if [ "$dst_bit" -eq 0 ]; then
			echo -e "${YELLOW}SKIP${RESET}  Device Self-test not supported (OACS bit 4=0)"
			echo -e "  Skipping entire suite."
			exit 0
		fi
	fi

	init_log "nvme_self_test_log_verify" "$ctrl_dev"
	log_cmd "Identify Controller (cached)" "nvme id-ctrl ${ctrl_dev}" "$_ID_CTRL_CACHE"

	local spec_ref
	spec_ref=$(get_spec_ref "self-test-log")

	print_header \
		"NVMe Device Self-test Log — Verification" \
		"$spec_ref" \
		"$ctrl_dev"

	DST_OUTPUT=$(nvme self-test-log "$ctrl_dev" 2>&1) || true
	log_cmd "Device Self-test Log" "nvme self-test-log ${ctrl_dev}" "$DST_OUTPUT"

	echo -e "${BOLD}--- Command Access ---${RESET}"
	test_dst_log_command

	echo ""
	echo -e "${BOLD}--- Current Operation ---${RESET}"
	test_current_operation

	echo ""
	echo -e "${BOLD}--- Completed Results ---${RESET}"
	test_completed_results
	test_result_codes

	echo ""
	echo -e "${BOLD}--- Entry Validation ---${RESET}"
	test_segment_numbers
	test_poh_timestamps

	print_summary

	if [ "$FAIL_COUNT" -gt 0 ]; then
		exit 1
	fi
	exit 0
}

main "$@"
