#!/bin/bash
# SPDX-License-Identifier: GPL-3.0+
# Copyright (C) 2025 Red Hat, Inc.
#
# NVMe Error Information Log verification
# Based on NVMe Base Specification, Revision 2.1
# Section 5.1.12, Figure 205 — Error Information Log Entry
# Field names from nvme-cli upstream nvme-print-stdout.c
#
# Usage:
#   ./nvme_error_log_verify.sh /dev/nvme0
#   ./nvme_error_log_verify.sh /dev/nvme0n1
#   ./nvme_error_log_verify.sh              # auto-detects first NVMe controller

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/nvme_test_lib.sh
source "${SCRIPT_DIR}/../common/nvme_test_lib.sh"

ERROR_LOG=""

# --------------------------------------------------------------------------
# Test functions
# --------------------------------------------------------------------------

test_error_log_command() {
	if [ -n "$ERROR_LOG" ]; then
		log_pass "nvme error-log command executes successfully"
	else
		log_fail "nvme error-log command executes successfully" "empty output"
	fi
}

test_entry_structure() {
	local entry_count
	entry_count=$(echo "$ERROR_LOG" | grep -c "^ Entry\[" || true)
	if [ "$entry_count" -gt 0 ]; then
		log_pass "Error log contains entry structures (${entry_count} entries)"
	else
		log_pass "Error log is empty (no errors recorded — valid state)"
	fi
}

test_entry_count_within_elpe() {
	local elpe
	elpe=$(get_id_ctrl_field "elpe")
	if [ -z "$elpe" ]; then
		log_skip "Entry count <= ELPE+1" "could not read ELPE from id-ctrl"
		return
	fi
	local max_entries=$(( elpe + 1 ))
	local entry_count
	entry_count=$(echo "$ERROR_LOG" | grep -c "^ Entry\[" || true)
	if [ "$entry_count" -le "$max_entries" ]; then
		log_pass "Entry count (${entry_count}) <= ELPE+1 (${max_entries})"
	else
		log_fail "Entry count (${entry_count}) <= ELPE+1 (${max_entries})" "more entries than ELPE allows"
	fi
}

check_field_in_first_entry() {
	local field_name="$1"
	local description="$2"
	local entry_count
	entry_count=$(echo "$ERROR_LOG" | grep -c "^ Entry\[" || true)
	if [ "$entry_count" -eq 0 ]; then
		log_skip "${description}" "no error entries to validate"
		return
	fi
	local first_entry
	first_entry=$(echo "$ERROR_LOG" | awk '/^ Entry\[ *0\]/{found=1; next} found && /^ Entry\[/{exit} found{print}')
	if echo "$first_entry" | grep -q "^${field_name}"; then
		local val
		val=$(echo "$first_entry" | grep "^${field_name}" | head -1 | awk -F': ' '{ print $2 }' | awk '{ print $1 }' || true)
		log_pass "${description} is present (${val})"
	else
		log_fail "${description} is present" "field not found in first entry"
	fi
}

test_error_count() {
	check_field_in_first_entry "error_count" "error_count"
}

test_sqid() {
	check_field_in_first_entry "sqid" "sqid (Submission Queue ID)"
}

test_cmdid() {
	check_field_in_first_entry "cmdid" "cmdid (Command ID)"
}

test_status_field() {
	check_field_in_first_entry "status_field" "status_field"
}

test_phase_tag() {
	check_field_in_first_entry "phase_tag" "phase_tag"
}

test_parm_err_loc() {
	check_field_in_first_entry "parm_err_loc" "parm_err_loc (Parameter Error Location)"
}

test_lba() {
	check_field_in_first_entry "lba" "lba (Logical Block Address)"
}

test_nsid() {
	check_field_in_first_entry "nsid" "nsid (Namespace ID)"
}

test_vs() {
	check_field_in_first_entry "vs" "vs (Vendor Specific)"
}

test_trtype() {
	if ! ver_at_least 1 4; then
		log_skip "trtype (Transport Type) is present" "requires NVMe 1.4+"
		return
	fi
	check_field_in_first_entry "trtype" "trtype (Transport Type)"
}

test_csi() {
	if ! ver_at_least 2 0; then
		log_skip "csi (Command Set Identifier) is present" "requires NVMe 2.0+"
		return
	fi
	check_field_in_first_entry "csi" "csi (Command Set Identifier)"
}

test_opcode() {
	if ! ver_at_least 2 0; then
		log_skip "opcode is present" "requires NVMe 2.0+"
		return
	fi
	check_field_in_first_entry "opcode" "opcode"
}

test_cs() {
	if ! ver_at_least 2 0; then
		log_skip "cs (Command Specific) is present" "requires NVMe 2.0+"
		return
	fi
	check_field_in_first_entry "cs" "cs (Command Specific)"
}

test_trtype_spec_info() {
	if ! ver_at_least 2 0; then
		log_skip "trtype_spec_info (Transport Specific Info) is present" "requires NVMe 2.0+"
		return
	fi
	check_field_in_first_entry "trtype_spec_info" "trtype_spec_info (Transport Specific Info)"
}

test_log_page_version() {
	if ! ver_at_least 2 0; then
		log_skip "log_page_version is present" "requires NVMe 2.0+"
		return
	fi
	check_field_in_first_entry "log_page_version" "log_page_version"
}

test_status_field_decode() {
	local entry_count
	entry_count=$(echo "$ERROR_LOG" | grep -c "^ Entry\[" || true)
	if [ "$entry_count" -eq 0 ]; then
		log_skip "status_field decode" "no error entries to validate"
		return
	fi
	local first_entry
	first_entry=$(echo "$ERROR_LOG" | awk '/^ Entry\[ *0\]/{found=1; next} found && /^ Entry\[/{exit} found{print}')
	local sf
	sf=$(echo "$first_entry" | grep "^status_field" | head -1 | awk -F': ' '{ print $2 }' | awk '{ print $1 }' || true)
	if [ -z "$sf" ]; then
		log_skip "status_field decode" "could not extract status_field"
		return
	fi
	local sf_int=$((sf))
	local sct=$(( (sf_int >> 9) & 0x7 ))
	local sc=$(( sf_int & 0xFF ))
	local sct_name=""
	case "$sct" in
		0) sct_name="Generic" ;;
		1) sct_name="Cmd Specific" ;;
		2) sct_name="Media/Integrity" ;;
		3) sct_name="Path Related" ;;
		*) sct_name="Vendor/Reserved" ;;
	esac
	log_pass "status_field decode: SCT=${sct} (${sct_name}), SC=0x$(printf '%02x' "$sc")"
}

test_all_errors_zero_note() {
	local entry_count
	entry_count=$(echo "$ERROR_LOG" | grep -c "^ Entry\[" || true)
	if [ "$entry_count" -eq 0 ]; then
		log_pass "Error log: device reports zero recorded errors (clean state)"
		return
	fi
	local nonzero=0
	local counts
	counts=$(echo "$ERROR_LOG" | grep "^error_count" | awk -F': ' '{ print $2 }' | awk '{ print $1 }' || true)
	while IFS= read -r val; do
		if [ -n "$val" ] && [ "$val" != "0" ]; then
			nonzero=$((nonzero + 1))
		fi
	done <<< "$counts"
	if [ "$nonzero" -eq 0 ] && [ "$entry_count" -gt 0 ]; then
		log_pass "Error log: ${entry_count} entries present but all have error_count=0"
	else
		log_pass "Error log: ${nonzero} entries with non-zero error_count out of ${entry_count} total"
	fi
}

test_error_count_nonzero_entries() {
	local entry_count
	entry_count=$(echo "$ERROR_LOG" | grep -c "^ Entry\[" || true)
	local smart_errs
	smart_errs=$(get_id_ctrl_field "elpe")
	local num_err
	num_err=$(nvme smart-log "$(echo "$_LOG_DEVICE" | sed 's|n[0-9]*$||')" 2>/dev/null | grep "^num_err_log_entries[[:space:]]" | awk '{ print $3 }' || true)
	if [ -z "$num_err" ]; then
		log_skip "Error entry count vs SMART cross-check" "could not read SMART log"
		return
	fi
	local num_err_int=$((num_err))
	if [ "$num_err_int" -eq 0 ] && [ "$entry_count" -eq 0 ]; then
		log_pass "SMART num_err_log_entries=0, error-log empty — consistent"
	elif [ "$num_err_int" -gt 0 ] && [ "$entry_count" -gt 0 ]; then
		log_pass "SMART num_err_log_entries=${num_err_int}, error-log has ${entry_count} entries — consistent"
	elif [ "$num_err_int" -eq 0 ] && [ "$entry_count" -gt 0 ]; then
		log_warn "SMART says 0 errors but error-log has entries" "SMART=0, entries=${entry_count}"
	else
		log_pass "SMART num_err_log_entries=${num_err_int}, error-log empty — entries may have wrapped"
	fi
}

test_error_count_ordering() {
	local entry_count
	entry_count=$(echo "$ERROR_LOG" | grep -c "^ Entry\[" || true)
	if [ "$entry_count" -lt 2 ]; then
		log_skip "error_count values are monotonically ordered" "fewer than 2 entries"
		return
	fi
	local counts
	counts=$(echo "$ERROR_LOG" | grep "^error_count" | awk -F': ' '{ print $2 }' | awk '{ print $1 }' || true)
	local prev=""
	local ordered=true
	while IFS= read -r val; do
		if [ -n "$prev" ] && [ "$val" -gt "$prev" ] 2>/dev/null; then
			ordered=false
			break
		fi
		prev="$val"
	done <<< "$counts"
	if [ "$ordered" = true ]; then
		log_pass "error_count values are monotonically ordered (descending)"
	else
		log_fail "error_count values are monotonically ordered" "values not in expected descending order"
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
		echo "Verifies NVMe Error Information Log per NVMe Base Spec 2.1."
		exit 0
	else
		ctrl_dev=$(resolve_ctrl_dev "$1")
	fi

	if [ ! -e "$ctrl_dev" ]; then
		echo "ERROR: Device $ctrl_dev does not exist." >&2
		exit 1
	fi

	cache_id_ctrl "$ctrl_dev"
	init_log "nvme_error_log_verify" "$ctrl_dev"
	log_cmd "Identify Controller (cached)" "nvme id-ctrl ${ctrl_dev}" "$_ID_CTRL_CACHE"

	local spec_ref
	spec_ref=$(get_spec_ref "error-log")

	print_header \
		"NVMe Error Information Log — Verification" \
		"$spec_ref" \
		"$ctrl_dev"

	ERROR_LOG=$(nvme error-log "$ctrl_dev" 2>&1)
	if [ $? -ne 0 ]; then
		echo "ERROR: Failed to run 'nvme error-log ${ctrl_dev}':" >&2
		echo "$ERROR_LOG" >&2
		exit 1
	fi
	log_cmd "Error Information Log" "nvme error-log ${ctrl_dev}" "$ERROR_LOG"

	echo -e "${BOLD}--- Log Structure ---${RESET}"
	test_error_log_command
	test_entry_structure
	test_entry_count_within_elpe

	echo ""
	echo -e "${BOLD}--- Per-Entry Fields (checked on first entry) ---${RESET}"
	test_error_count
	test_sqid
	test_cmdid
	test_status_field
	test_phase_tag
	test_parm_err_loc
	test_lba
	test_nsid
	test_vs
	test_trtype
	test_csi
	test_opcode
	test_cs
	test_trtype_spec_info
	test_log_page_version

	echo ""
	echo -e "${BOLD}--- Ordering Checks ---${RESET}"
	test_error_count_ordering

	echo ""
	echo -e "${BOLD}--- Deep Validation ---${RESET}"
	test_status_field_decode
	test_all_errors_zero_note
	test_error_count_nonzero_entries

	print_summary

	if [ "$FAIL_COUNT" -gt 0 ]; then
		exit 1
	fi
	exit 0
}

main "$@"
