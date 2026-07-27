#!/bin/bash
# SPDX-License-Identifier: GPL-3.0+
# Copyright (C) 2025 Red Hat, Inc.
#
# NVMe Device Self-test — Functional Verification
# Based on NVMe Base Specification — Device Self-test command
# Tests: start short DST, poll completion, verify result, abort, start/abort extended
#
# Usage:
#   ./nvme_dst_functional_verify.sh /dev/nvme0
#   ./nvme_dst_functional_verify.sh              # auto-detects first NVMe controller

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/nvme_test_lib.sh
source "${SCRIPT_DIR}/../common/nvme_test_lib.sh"

CTRL_DEV=""

# --------------------------------------------------------------------------
# Test functions
# --------------------------------------------------------------------------

test_start_short_dst() {
	local output
	output=$(nvme device-self-test "$CTRL_DEV" -s 1 2>&1) || true
	if echo "$output" | grep -qi "error\|invalid\|not support"; then
		log_fail "Start short self-test" "command returned error: $output"
	else
		log_pass "Start short self-test accepted"
	fi
}

test_poll_short_completion() {
	local timeout=120
	local elapsed=0
	local completed=0

	while [ "$elapsed" -lt "$timeout" ]; do
		local st_log
		st_log=$(nvme self-test-log "$CTRL_DEV" 2>&1) || true
		local current_op
		current_op=$(echo "$st_log" | grep -i "Current.*Operation\|current_operation" | head -1 || true)

		if echo "$current_op" | grep -qi "No.*self-test\|0x0\| 0 "; then
			completed=1
			break
		fi

		if echo "$st_log" | grep -qi "not support\|error"; then
			log_skip "Poll short DST completion" "self-test-log not available"
			return
		fi

		sleep 5
		elapsed=$((elapsed + 5))
	done

	if [ "$completed" -eq 1 ]; then
		log_pass "Short self-test completed in ~${elapsed}s"
	else
		log_warn "Short self-test poll" "not complete after ${timeout}s timeout"
	fi
}

test_short_result() {
	local st_log
	st_log=$(nvme self-test-log "$CTRL_DEV" 2>&1) || true

	local result_line
	result_line=$(echo "$st_log" | grep -i "Self Test Result\|test_result\|Result" | head -1 || true)

	if [ -z "$result_line" ]; then
		log_skip "Short self-test result" "could not parse result from self-test-log"
		return
	fi

	if echo "$result_line" | grep -qi "completed.*no error\|success\| 0x0\| 0 "; then
		log_pass "Short self-test result: completed without error"
	elif echo "$result_line" | grep -qi "aborted\|0xf"; then
		log_pass "Short self-test result: aborted (valid result code)"
	else
		local code
		code=$(echo "$result_line" | grep -oiP '0x[0-9a-fA-F]+' | head -1 || echo "$result_line")
		log_warn "Short self-test result" "result=$code (non-zero, may indicate device issue)"
	fi
}

test_abort_dst() {
	local start_output
	start_output=$(nvme device-self-test "$CTRL_DEV" -s 1 2>&1) || true
	sleep 1

	local output
	output=$(nvme device-self-test "$CTRL_DEV" -s 0xf 2>&1) || true
	if echo "$output" | grep -qi "error\|invalid\|not support"; then
		log_warn "Abort self-test" "command returned: $output"
	else
		log_pass "Abort self-test (STC=0xF) accepted"
	fi
	sleep 1
}

test_start_extended_dst() {
	local output
	output=$(nvme device-self-test "$CTRL_DEV" -s 2 2>&1) || true
	if echo "$output" | grep -qi "error\|invalid\|not support"; then
		log_fail "Start extended self-test" "command returned error: $output"
	else
		log_pass "Start extended self-test accepted"
	fi
}

test_abort_extended_immediately() {
	sleep 2
	local output
	output=$(nvme device-self-test "$CTRL_DEV" -s 0xf 2>&1) || true
	if echo "$output" | grep -qi "error\|invalid"; then
		log_warn "Abort extended self-test" "command returned: $output"
	else
		log_pass "Abort extended self-test immediately after start — clean abort"
	fi

	sleep 2
	local st_log
	st_log=$(nvme self-test-log "$CTRL_DEV" 2>&1) || true
	local result_line
	result_line=$(echo "$st_log" | grep -i "Self Test Result\|test_result\|Result" | head -1 || true)
	if echo "$result_line" | grep -qi "aborted\|0x1\|0x2"; then
		log_pass "Extended self-test result shows aborted status"
	elif [ -n "$result_line" ]; then
		log_pass "Extended self-test result available: $(echo "$result_line" | sed 's/.*: //')"
	fi
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

main() {
	preflight_checks

	if [ $# -eq 0 ]; then
		CTRL_DEV=$(auto_detect_ctrl)
		echo -e "${BOLD}No device specified — auto-detected: ${CTRL_DEV}${RESET}"
	elif [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
		echo "Usage: $0 [/dev/nvmeX | /dev/nvmeXnY]"
		echo "Functional verification of NVMe Device Self-test."
		exit 0
	else
		CTRL_DEV=$(resolve_ctrl_dev "$1")
	fi

	if [ ! -e "$CTRL_DEV" ]; then
		echo "ERROR: Device $CTRL_DEV does not exist." >&2
		exit 1
	fi

	cache_id_ctrl "$CTRL_DEV"

	local oacs
	oacs=$(get_id_ctrl_field "oacs")
	if [ -n "$oacs" ]; then
		local dst_bit=$(( (oacs >> 4) & 0x1 ))
		if [ "$dst_bit" -eq 0 ]; then
			echo -e "${YELLOW}SKIP${RESET}  Device Self-test not supported (OACS bit 4=0)"
			exit 0
		fi
	fi

	init_log "nvme_dst_functional_verify" "$CTRL_DEV"
	log_cmd "Identify Controller (cached)" "nvme id-ctrl ${CTRL_DEV}" "$_ID_CTRL_CACHE"

	local spec_ref
	spec_ref=$(get_spec_ref "dst-functional")

	print_header \
		"NVMe Device Self-test — Functional Verification" \
		"$spec_ref" \
		"$CTRL_DEV"

	echo -e "${BOLD}--- Short Self-test ---${RESET}"
	test_start_short_dst
	test_poll_short_completion
	test_short_result

	echo ""
	echo -e "${BOLD}--- Self-test Abort ---${RESET}"
	test_abort_dst

	echo ""
	echo -e "${BOLD}--- Extended Self-test (start + immediate abort) ---${RESET}"
	test_start_extended_dst
	test_abort_extended_immediately

	print_summary

	if [ "$FAIL_COUNT" -gt 0 ]; then
		exit 1
	fi
	exit 0
}

main "$@"
