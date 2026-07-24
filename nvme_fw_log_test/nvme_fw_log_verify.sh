#!/bin/bash
# SPDX-License-Identifier: GPL-3.0+
# Copyright (C) 2025 Red Hat, Inc.
#
# NVMe Firmware Slot Information Log verification
# Based on NVMe Base Specification, Revision 2.1
# Section 5.1.12, Figure 208 — Firmware Slot Information Log
# Field names from nvme-cli upstream nvme-print-stdout.c
#
# Usage:
#   ./nvme_fw_log_verify.sh /dev/nvme0
#   ./nvme_fw_log_verify.sh /dev/nvme0n1
#   ./nvme_fw_log_verify.sh              # auto-detects first NVMe controller

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/nvme_test_lib.sh
source "${SCRIPT_DIR}/../common/nvme_test_lib.sh"

FW_LOG=""

fw_get_field() {
	echo "$FW_LOG" | grep "^$1[[:space:]]" | awk -F': ' '{ print $2 }' | awk '{ print $1 }' || true
}

fw_field_present() {
	echo "$FW_LOG" | grep -q "^$1 "
}

# --------------------------------------------------------------------------
# Test functions
# --------------------------------------------------------------------------

test_fw_log_command() {
	if [ -n "$FW_LOG" ]; then
		log_pass "nvme fw-log command executes successfully"
	else
		log_fail "nvme fw-log command executes successfully" "empty output"
	fi
}

test_afi_present() {
	if fw_field_present "afi"; then
		local val
		val=$(fw_get_field "afi")
		log_pass "afi (Active Firmware Info) is present (${val})"
	else
		log_fail "afi (Active Firmware Info) is present" "field not found"
	fi
}

test_afi_active_slot_valid() {
	local afi
	afi=$(fw_get_field "afi")
	if [ -z "$afi" ]; then
		log_fail "afi active slot is valid (1-7)" "afi not found"
		return
	fi
	local afi_int=$((afi))
	local active_slot=$(( afi_int & 0x7 ))
	if [ "$active_slot" -ge 1 ] && [ "$active_slot" -le 7 ]; then
		log_pass "afi active slot is valid (slot ${active_slot})"
	else
		log_fail "afi active slot is valid (1-7)" "got ${active_slot}"
	fi
}

test_afi_next_slot_valid() {
	local afi
	afi=$(fw_get_field "afi")
	if [ -z "$afi" ]; then
		log_skip "afi next active slot is valid" "afi not found"
		return
	fi
	local afi_int=$((afi))
	local next_slot=$(( (afi_int >> 4) & 0x7 ))
	if [ "$next_slot" -eq 0 ]; then
		log_pass "afi next active slot: not specified (next reset uses current active slot)"
	elif [ "$next_slot" -ge 1 ] && [ "$next_slot" -le 7 ]; then
		log_pass "afi next active slot is valid (slot ${next_slot})"
	else
		log_fail "afi next active slot is valid (0-7)" "got ${next_slot}"
	fi
}

test_frs1_present() {
	if fw_field_present "frs1"; then
		local val
		val=$(echo "$FW_LOG" | grep "^frs1 " | sed 's/^frs1 *: *//')
		log_pass "frs1 (FW Revision Slot 1) is present (${val})"
	else
		log_fail "frs1 (FW Revision Slot 1) is present" "at least slot 1 must exist"
	fi
}

test_fw_slots_vs_frmw() {
	local frmw
	frmw=$(get_id_ctrl_field "frmw")
	if [ -z "$frmw" ]; then
		log_skip "FW slot count matches FRMW" "could not read frmw from id-ctrl"
		return
	fi
	local frmw_int=$((frmw))
	local num_slots=$(( (frmw_int >> 1) & 0x7 ))
	if [ "$num_slots" -eq 0 ]; then
		num_slots=1
	fi
	local populated=0
	local i
	for i in 1 2 3 4 5 6 7; do
		if fw_field_present "frs${i}"; then
			populated=$((populated + 1))
		fi
	done
	if [ "$populated" -le "$num_slots" ]; then
		log_pass "Populated FW slots (${populated}) <= FRMW.NOFS (${num_slots})"
	else
		log_fail "Populated FW slots (${populated}) <= FRMW.NOFS (${num_slots})" "more slots populated than controller supports"
	fi
}

test_active_slot_has_fw() {
	local afi
	afi=$(fw_get_field "afi")
	if [ -z "$afi" ]; then
		log_fail "Active FW slot has firmware revision" "afi not found"
		return
	fi
	local afi_int=$((afi))
	local active_slot=$(( afi_int & 0x7 ))
	if [ "$active_slot" -lt 1 ] || [ "$active_slot" -gt 7 ]; then
		log_fail "Active FW slot has firmware revision" "invalid active slot ${active_slot}"
		return
	fi
	if fw_field_present "frs${active_slot}"; then
		local fw_rev
		fw_rev=$(echo "$FW_LOG" | grep "^frs${active_slot} " | sed 's/^frs[0-9] *: *//')
		log_pass "Active FW slot ${active_slot} has firmware revision (${fw_rev})"
	else
		log_fail "Active FW slot ${active_slot} has firmware revision" "slot is empty"
	fi
}

test_active_fw_matches_id_ctrl() {
	local afi
	afi=$(fw_get_field "afi")
	if [ -z "$afi" ]; then
		log_skip "Active FW revision matches id-ctrl FR" "afi not found"
		return
	fi
	local afi_int=$((afi))
	local active_slot=$(( afi_int & 0x7 ))
	local fw_log_line
	fw_log_line=$(echo "$FW_LOG" | grep "^frs${active_slot} " | sed 's/^frs[0-9] *: *//')
	local fw_rev_from_log
	fw_rev_from_log=$(echo "$fw_log_line" | grep -oP '\(([^)]+)\)' | tr -d '()')
	if [ -z "$fw_rev_from_log" ]; then
		fw_rev_from_log=$(echo "$fw_log_line" | awk '{ print $1 }')
	fi
	local fr_from_id
	fr_from_id=$(get_id_ctrl_string_field "fr" | sed 's/ *$//')
	if [ -z "$fw_rev_from_log" ] || [ -z "$fr_from_id" ]; then
		log_skip "Active FW revision matches id-ctrl FR" "could not extract FW strings for comparison"
		return
	fi
	if echo "$fw_rev_from_log" | grep -qF "$fr_from_id"; then
		log_pass "Active FW revision matches id-ctrl FR ('${fr_from_id}')"
	elif echo "$fr_from_id" | grep -qF "$fw_rev_from_log"; then
		log_pass "Active FW revision matches id-ctrl FR ('${fr_from_id}')"
	else
		log_fail "Active FW revision matches id-ctrl FR" "fw-log='${fw_rev_from_log}' vs id-ctrl='${fr_from_id}'"
	fi
}

test_frmw_slot1_readonly() {
	local frmw
	frmw=$(get_id_ctrl_field "frmw")
	if [ -z "$frmw" ]; then
		log_skip "FRMW slot 1 read-only info" "could not read frmw from id-ctrl"
		return
	fi
	local frmw_int=$((frmw))
	local ffsro=$(( frmw_int & 0x1 ))
	if [ "$ffsro" -eq 1 ]; then
		log_pass "FRMW.FFSRO=1: Slot 1 is read-only (informational)"
	else
		log_pass "FRMW.FFSRO=0: Slot 1 is read/write (informational)"
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
		echo "Verifies NVMe Firmware Slot Information Log per NVMe Base Spec 2.1."
		exit 0
	else
		ctrl_dev=$(resolve_ctrl_dev "$1")
	fi

	if [ ! -e "$ctrl_dev" ]; then
		echo "ERROR: Device $ctrl_dev does not exist." >&2
		exit 1
	fi

	cache_id_ctrl "$ctrl_dev"
	init_log "nvme_fw_log_verify" "$ctrl_dev"
	log_cmd "Identify Controller (cached)" "nvme id-ctrl ${ctrl_dev}" "$_ID_CTRL_CACHE"

	local spec_ref
	spec_ref=$(get_spec_ref "fw-log")

	print_header \
		"NVMe Firmware Slot Information Log — Verification" \
		"$spec_ref" \
		"$ctrl_dev"

	FW_LOG=$(nvme fw-log "$ctrl_dev" 2>&1)
	if [ $? -ne 0 ]; then
		echo "ERROR: Failed to run 'nvme fw-log ${ctrl_dev}':" >&2
		echo "$FW_LOG" >&2
		exit 1
	fi
	log_cmd "Firmware Slot Information Log" "nvme fw-log ${ctrl_dev}" "$FW_LOG"

	echo -e "${BOLD}--- Firmware Log Fields ---${RESET}"
	test_fw_log_command
	test_afi_present
	test_afi_active_slot_valid
	test_afi_next_slot_valid
	test_frs1_present

	echo ""
	echo -e "${BOLD}--- Cross-Checks with Identify Controller ---${RESET}"
	test_fw_slots_vs_frmw
	test_active_slot_has_fw
	test_active_fw_matches_id_ctrl
	test_frmw_slot1_readonly

	print_summary

	if [ "$FAIL_COUNT" -gt 0 ]; then
		exit 1
	fi
	exit 0
}

main "$@"
