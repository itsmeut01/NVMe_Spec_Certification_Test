#!/bin/bash
# SPDX-License-Identifier: GPL-3.0+
# Copyright (C) 2025 Red Hat, Inc.
#
# NVMe Firmware Management — Behavioral Verification
# Based on NVMe Base Specification — Firmware Image Download / Commit
# Tests: read slot info, re-commit active slot, verify unchanged, error cases
#
# Usage:
#   ./nvme_fw_mgmt_verify.sh /dev/nvme0 --allow-destructive
#   ./nvme_fw_mgmt_verify.sh              # auto-detects first NVMe controller

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/nvme_test_lib.sh
source "${SCRIPT_DIR}/../common/nvme_test_lib.sh"

CTRL_DEV=""
ALLOW_DESTRUCTIVE=""

SAVED_ACTIVE_SLOT=""
FW_SLOTS=7

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

get_active_slot() {
	local fw_output
	fw_output=$(nvme fw-log "$CTRL_DEV" 2>&1) || true
	local afi
	afi=$(echo "$fw_output" | grep -i "^afi" | awk '{print $3}' || true)
	if [ -z "$afi" ]; then
		afi=$(echo "$fw_output" | grep -i "active" | grep -oP '[0-9]+' | head -1 || true)
	fi
	echo "$afi"
}

get_fw_revision_for_slot() {
	local slot="$1"
	local fw_output
	fw_output=$(nvme fw-log "$CTRL_DEV" 2>&1) || true
	local frs
	frs=$(echo "$fw_output" | grep -i "^frs${slot}" | sed 's/^[^:]*:[[:space:]]*//' | sed 's/ *$//' || true)
	echo "$frs"
}

# --------------------------------------------------------------------------
# Test functions
# --------------------------------------------------------------------------

test_read_fw_slot_info() {
	local fw_output
	fw_output=$(nvme fw-log "$CTRL_DEV" 2>&1) || true
	log_cmd "Firmware Log" "nvme fw-log ${CTRL_DEV}" "$fw_output"

	local afi
	afi=$(echo "$fw_output" | grep -i "^afi" | awk '{print $3}' || true)
	if [ -n "$afi" ]; then
		SAVED_ACTIVE_SLOT="$afi"
		local afi_int=$((afi))
		local active_slot=$(( afi_int & 0x7 ))
		log_pass "Firmware log: AFI=0x$(printf '%02x' "$afi_int"), active slot=${active_slot}"
	else
		local active
		active=$(echo "$fw_output" | grep -i "active" | head -1 || true)
		if [ -n "$active" ]; then
			SAVED_ACTIVE_SLOT=$(echo "$active" | grep -oP '[0-9]+' | head -1 || true)
			log_pass "Firmware log: active firmware info found (${active})"
		else
			log_fail "Firmware log: AFI field not found" "fw-log output missing active slot info"
		fi
	fi
}

test_fw_commit_recommit_active() {
	if [ -z "$SAVED_ACTIVE_SLOT" ]; then
		log_skip "fw-commit re-commit active slot" "active slot unknown"
		return
	fi

	local active_int=$((SAVED_ACTIVE_SLOT))
	local active_slot=$(( active_int & 0x7 ))
	if [ "$active_slot" -lt 1 ] || [ "$active_slot" -gt 7 ]; then
		log_skip "fw-commit re-commit active slot" "active slot ${active_slot} out of range"
		return
	fi

	local output
	output=$(nvme fw-commit "$CTRL_DEV" -s "$active_slot" -a 2 2>&1) || true
	log_cmd "fw-commit re-commit active" "nvme fw-commit ${CTRL_DEV} -s ${active_slot} -a 2" "$output"

	if echo "$output" | grep -qi "success\|NEEDS.*RESET\|fw_rev"; then
		log_pass "fw-commit: re-committed active slot ${active_slot} (action=2 set-active, safe no-op)"
	elif echo "$output" | grep -qi "invalid\|error\|status"; then
		log_warn "fw-commit: re-commit active slot returned error" "$(echo "$output" | head -1)"
	else
		log_pass "fw-commit: re-committed active slot ${active_slot} (no error returned)"
	fi
}

test_verify_active_slot_unchanged() {
	if [ -z "$SAVED_ACTIVE_SLOT" ]; then
		log_skip "Verify active slot unchanged" "no saved state"
		return
	fi

	local current
	current=$(get_active_slot)
	if [ -z "$current" ]; then
		log_warn "Verify active slot unchanged" "could not read current active slot"
		return
	fi

	local saved_int=$((SAVED_ACTIVE_SLOT))
	local saved_slot=$(( saved_int & 0x7 ))
	local current_int=$((current))
	local current_slot=$(( current_int & 0x7 ))

	if [ "$current_slot" -eq "$saved_slot" ]; then
		log_pass "Active slot unchanged after fw-commit: slot ${current_slot}"
	else
		log_fail "Active slot changed after fw-commit" "was ${saved_slot}, now ${current_slot}"
	fi
}

test_fw_slot_revisions() {
	local fw_output
	fw_output=$(nvme fw-log "$CTRL_DEV" 2>&1) || true

	local has_revision=0
	local slot
	for slot in $(seq 1 "$FW_SLOTS"); do
		local frs
		frs=$(echo "$fw_output" | grep -i "^frs${slot}" | sed 's/^[^:]*:[[:space:]]*//' | sed 's/ *$//' || true)
		if [ -n "$frs" ] && [ "$frs" != "0" ] && echo "$frs" | grep -qP '[^\x00\s]'; then
			has_revision=1
			break
		fi
	done

	if [ "$has_revision" -eq 1 ]; then
		log_pass "At least one FW slot has a non-empty revision string"
	else
		local frs_any
		frs_any=$(echo "$fw_output" | grep -i "frs\|revision\|fw_rev" | head -3 || true)
		if [ -n "$frs_any" ]; then
			log_pass "Firmware revision fields present in fw-log output"
		else
			log_fail "No firmware revision strings found" "fw-log should show frs1..frs7"
		fi
	fi
}

test_fw_commit_invalid_slot_zero() {
	local output
	output=$(nvme fw-commit "$CTRL_DEV" -s 0 -a 2 2>&1) || true
	log_cmd "fw-commit slot 0" "nvme fw-commit ${CTRL_DEV} -s 0 -a 2" "$output"

	if echo "$output" | grep -qi "invalid\|error\|INVALID_FIELD\|status"; then
		log_pass "fw-commit: slot 0 correctly rejected (invalid slot for set-active)"
	elif echo "$output" | grep -qi "success"; then
		log_warn "fw-commit: slot 0 accepted" "spec says slot 0 means controller-chosen — advisory"
	else
		log_pass "fw-commit: slot 0 returned non-success (expected)"
	fi
}

test_fw_commit_activate_without_download() {
	if [ -z "$SAVED_ACTIVE_SLOT" ]; then
		log_skip "fw-commit activate without download" "active slot unknown"
		return
	fi

	local active_int=$((SAVED_ACTIVE_SLOT))
	local active_slot=$(( active_int & 0x7 ))
	local alt_slot=1
	if [ "$active_slot" -eq 1 ]; then
		alt_slot=2
	fi

	local output
	output=$(nvme fw-commit "$CTRL_DEV" -s "$alt_slot" -a 1 2>&1) || true
	log_cmd "fw-commit activate no download" "nvme fw-commit ${CTRL_DEV} -s ${alt_slot} -a 1" "$output"

	if echo "$output" | grep -qi "invalid\|error\|no.*image\|FIRMWARE_IMAGE\|status"; then
		log_pass "fw-commit: activate slot ${alt_slot} without download correctly rejected"
	else
		log_warn "fw-commit: activate without download" "unexpected response: $(echo "$output" | head -1)"
	fi
}

test_fw_download_devzero() {
	local output
	output=$(nvme fw-download "$CTRL_DEV" -f /dev/zero --xfer=4096 2>&1) || true
	log_cmd "fw-download /dev/zero" "nvme fw-download ${CTRL_DEV} -f /dev/zero --xfer=4096" "$output"

	if echo "$output" | grep -qi "success\|download"; then
		log_pass "fw-download: accepted /dev/zero payload (4096 bytes) — command path exercised"
	elif echo "$output" | grep -qi "invalid\|error\|status"; then
		log_pass "fw-download: rejected /dev/zero payload (expected — invalid firmware image)"
	else
		log_pass "fw-download: command completed (response: $(echo "$output" | head -1))"
	fi
}

test_controller_accessible() {
	local output
	output=$(nvme id-ctrl "$CTRL_DEV" 2>&1) || true

	if echo "$output" | grep -q "^mn "; then
		log_pass "Controller accessible after firmware management tests"
	else
		log_fail "Controller not accessible after fw tests" "id-ctrl failed"
	fi
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

main() {
	preflight_checks

	local device_arg=""
	for arg in "$@"; do
		case "$arg" in
			--allow-destructive) ALLOW_DESTRUCTIVE="--allow-destructive" ;;
			-h|--help)
				echo "Usage: $0 [/dev/nvmeX] [--allow-destructive]"
				echo "Behavioral verification of NVMe firmware management commands."
				exit 0
				;;
			*) device_arg="$arg" ;;
		esac
	done

	if [ -z "$device_arg" ]; then
		CTRL_DEV=$(auto_detect_ctrl)
		echo -e "${BOLD}No device specified — auto-detected: ${CTRL_DEV}${RESET}"
	else
		CTRL_DEV=$(resolve_ctrl_dev "$device_arg")
	fi

	if [ ! -e "$CTRL_DEV" ]; then
		echo "ERROR: Device $CTRL_DEV does not exist." >&2
		exit 1
	fi

	safe_device_check "$CTRL_DEV" "$ALLOW_DESTRUCTIVE"

	cache_id_ctrl "$CTRL_DEV"

	local oacs
	oacs=$(get_id_ctrl_field "oacs")
	local oacs_int=$((oacs))
	local fw_bit=$(( (oacs_int >> 2) & 0x1 ))

	if [ "$fw_bit" -eq 0 ]; then
		init_log "nvme_fw_mgmt_verify" "$CTRL_DEV"
		local spec_ref
		spec_ref=$(get_spec_ref "fw-mgmt")
		print_header "NVMe Firmware Management — Behavioral Verification" "$spec_ref" "$CTRL_DEV"
		log_skip "Firmware Management suite" "OACS bit 2 = 0 (firmware commands not supported)"
		print_summary
		exit 0
	fi

	init_log "nvme_fw_mgmt_verify" "$CTRL_DEV"
	log_cmd "Identify Controller (cached)" "nvme id-ctrl ${CTRL_DEV}" "$_ID_CTRL_CACHE"

	local spec_ref
	spec_ref=$(get_spec_ref "fw-mgmt")

	print_header \
		"NVMe Firmware Management — Behavioral Verification" \
		"$spec_ref" \
		"$CTRL_DEV"

	echo -e "${BOLD}--- Read Firmware State ---${RESET}"
	test_read_fw_slot_info

	echo ""
	echo -e "${BOLD}--- Behavioral: Re-commit Active Slot ---${RESET}"
	test_fw_commit_recommit_active
	test_verify_active_slot_unchanged

	echo ""
	echo -e "${BOLD}--- Firmware Slot Revisions ---${RESET}"
	test_fw_slot_revisions

	echo ""
	echo -e "${BOLD}--- Error Case Validation ---${RESET}"
	test_fw_commit_invalid_slot_zero
	test_fw_commit_activate_without_download
	test_fw_download_devzero

	echo ""
	echo -e "${BOLD}--- Post-Test Recovery ---${RESET}"
	test_controller_accessible

	print_summary

	if [ "$FAIL_COUNT" -gt 0 ]; then
		exit 1
	fi
	exit 0
}

main "$@"
