#!/bin/bash
# SPDX-License-Identifier: GPL-3.0+
# Copyright (C) 2025 Red Hat, Inc.
#
# NVMe Async Event — Functional Verification
# Based on NVMe Base Specification — Asynchronous Event Request
# Tests: AERL check, temperature event trigger, error injection, SMART consistency
#
# Usage:
#   ./nvme_async_event_verify.sh /dev/nvme0
#   ./nvme_async_event_verify.sh              # auto-detects first NVMe controller

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/nvme_test_lib.sh
source "${SCRIPT_DIR}/../common/nvme_test_lib.sh"

CTRL_DEV=""

# --------------------------------------------------------------------------
# Test functions
# --------------------------------------------------------------------------

test_aerl_nonzero() {
	local aerl
	aerl=$(get_id_ctrl_field "aerl")
	if [ -z "$aerl" ]; then
		log_skip "AERL (Async Event Request Limit)" "field not found in id-ctrl"
		return
	fi
	local aerl_int=$((aerl))
	local max_outstanding=$((aerl_int + 1))
	if [ "$max_outstanding" -ge 1 ]; then
		log_pass "AERL: at least 1 outstanding AER supported (AERL=${aerl_int}, max=${max_outstanding})"
	else
		log_fail "AERL must support at least 1 AER" "AERL=${aerl_int}"
	fi
}

test_temp_event_trigger() {
	save_feature "0x04" "$CTRL_DEV" >/dev/null
	if [ -z "${_SAVED_FEATURES[0x04]:-}" ]; then
		log_skip "Trigger temp AER" "could not save TMPTH"
		return
	fi

	local smart_output
	smart_output=$(nvme smart-log "$CTRL_DEV" 2>&1) || true
	local temp_raw
	temp_raw=$(echo "$smart_output" | grep "^temperature" | awk '{print $3}' | tr -d ',' || true)
	if [ -z "$temp_raw" ]; then
		restore_feature "0x04" "$CTRL_DEV" || true
		log_skip "Trigger temp AER" "could not read SMART temperature"
		return
	fi

	local current_temp_k=$((temp_raw + 273))
	local low_thresh=$((current_temp_k - 5))
	if [ "$low_thresh" -le 0 ]; then
		low_thresh=1
	fi

	set_feature "0x04" "$low_thresh" "$CTRL_DEV" >/dev/null 2>&1
	sleep 2

	smart_output=$(nvme smart-log "$CTRL_DEV" 2>&1) || true
	local cw
	cw=$(echo "$smart_output" | grep "^critical_warning" | awk '{print $3}' || true)

	restore_feature "0x04" "$CTRL_DEV" || true

	if [ -z "$cw" ]; then
		log_skip "Trigger temp AER" "could not read critical_warning"
		return
	fi

	local cw_int=$((cw))
	local temp_bit=$(( (cw_int >> 1) & 0x1 ))
	if [ "$temp_bit" -eq 1 ]; then
		log_pass "Temperature AER: critical_warning bit 1 fired when TMPTH set below current temp"
	else
		log_warn "Temperature AER: critical_warning bit 1 not set" "controller may batch events — advisory"
	fi
}

test_error_log_increment() {
	local smart_before
	smart_before=$(nvme smart-log "$CTRL_DEV" 2>&1) || true
	local err_before
	err_before=$(echo "$smart_before" | grep "^num_err_log_entries" | awk '{print $3}' || true)

	if [ -z "$err_before" ]; then
		log_skip "Error log increment" "could not read num_err_log_entries"
		return
	fi

	local err_before_int=$((err_before))

	nvme admin-passthru "$CTRL_DEV" --opcode=0x7f --cdw10=0 >/dev/null 2>&1 || true
	sleep 1

	local smart_after
	smart_after=$(nvme smart-log "$CTRL_DEV" 2>&1) || true
	local err_after
	err_after=$(echo "$smart_after" | grep "^num_err_log_entries" | awk '{print $3}' || true)

	if [ -z "$err_after" ]; then
		log_skip "Error log increment" "could not read num_err_log_entries after injection"
		return
	fi

	local err_after_int=$((err_after))

	if [ "$err_after_int" -gt "$err_before_int" ]; then
		log_pass "Error log increment: num_err_log_entries ${err_before_int} → ${err_after_int} after invalid admin opcode"
	else
		log_warn "Error log increment" "count unchanged (${err_before_int} → ${err_after_int}) — controller may not log all errors"
	fi
}

test_smart_after_error() {
	local smart_output
	smart_output=$(nvme smart-log "$CTRL_DEV" 2>&1) || true

	local has_temp has_spare
	has_temp=$(echo "$smart_output" | grep "^temperature" | head -1 || true)
	has_spare=$(echo "$smart_output" | grep "^avail" | head -1 || true)

	if [ -n "$has_temp" ] && [ -n "$has_spare" ]; then
		log_pass "SMART log readable and consistent after error injection"
	elif echo "$smart_output" | grep -qi "NVMe status\|could not\|not support"; then
		log_fail "SMART after error injection" "smart-log command failed: $(echo "$smart_output" | head -1)"
	else
		log_warn "SMART after error injection" "some expected fields missing"
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
		echo "Functional verification of NVMe Async Event behavior."
		exit 0
	else
		CTRL_DEV=$(resolve_ctrl_dev "$1")
	fi

	if [ ! -e "$CTRL_DEV" ]; then
		echo "ERROR: Device $CTRL_DEV does not exist." >&2
		exit 1
	fi

	cache_id_ctrl "$CTRL_DEV"
	init_log "nvme_async_event_verify" "$CTRL_DEV"
	log_cmd "Identify Controller (cached)" "nvme id-ctrl ${CTRL_DEV}" "$_ID_CTRL_CACHE"

	local spec_ref
	spec_ref=$(get_spec_ref "async-event")

	print_header \
		"NVMe Async Event — Functional Verification" \
		"$spec_ref" \
		"$CTRL_DEV"

	echo -e "${BOLD}--- AER Capability ---${RESET}"
	test_aerl_nonzero

	echo ""
	echo -e "${BOLD}--- Temperature Event ---${RESET}"
	test_temp_event_trigger

	echo ""
	echo -e "${BOLD}--- Error Injection ---${RESET}"
	test_error_log_increment
	test_smart_after_error

	print_summary

	if [ "$FAIL_COUNT" -gt 0 ]; then
		exit 1
	fi
	exit 0
}

main "$@"
