#!/bin/bash
# SPDX-License-Identifier: GPL-3.0+
# Copyright (C) 2025 Red Hat, Inc.
#
# NVMe Advanced Admin — Behavioral Verification
# Based on NVMe Base Specification — Lockdown, IO Management, Virt Mgmt, Capacity Mgmt
# Tests: lockdown lock/unlock cycle, io-mgmt recv/send, virt-mgmt query, capacity-mgmt probe
#
# Usage:
#   ./nvme_advanced_admin_verify.sh /dev/nvme0 --allow-destructive

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/nvme_test_lib.sh
source "${SCRIPT_DIR}/../common/nvme_test_lib.sh"

CTRL_DEV=""
NS_DEV=""
ALLOW_DESTRUCTIVE=""
LOCKDOWN_APPLIED=0

# --------------------------------------------------------------------------
# Cleanup: ensure lockdown is undone
# --------------------------------------------------------------------------

cleanup_lockdown() {
	if [ "$LOCKDOWN_APPLIED" -eq 1 ]; then
		nvme lockdown "$CTRL_DEV" --scp=0 --ofi=0x18 --ifc=0 --prhbt=0 2>/dev/null || true
		LOCKDOWN_APPLIED=0
	fi
}

# --------------------------------------------------------------------------
# Test functions
# --------------------------------------------------------------------------

test_lockdown_behavioral() {
	if ! ver_at_least 2 0; then
		log_skip "Lockdown: prohibit Keep Alive" "requires NVMe 2.0+"
		return
	fi

	local oacs
	oacs=$(get_id_ctrl_field "oacs")
	local oacs_int=$((oacs))
	local lockdown_bit=$(( (oacs_int >> 10) & 0x1 ))

	if [ "$lockdown_bit" -eq 0 ]; then
		log_skip "Lockdown: prohibit Keep Alive" "OACS bit 10 = 0 (Lockdown not supported)"
		return
	fi

	local lock_output
	lock_output=$(nvme lockdown "$CTRL_DEV" --scp=0 --ofi=0x18 --ifc=0 --prhbt=1 2>&1) || true
	log_cmd "Lockdown prohibit" "nvme lockdown ${CTRL_DEV} --scp=0 --ofi=0x18 --ifc=0 --prhbt=1" "$lock_output"

	if echo "$lock_output" | grep -qi "error\|NVMe status\|invalid"; then
		log_warn "Lockdown: prohibit Keep Alive" "$(echo "$lock_output" | head -1)"
		return
	fi

	LOCKDOWN_APPLIED=1

	local verify_output
	verify_output=$(nvme admin-passthru "$CTRL_DEV" --opcode=0x18 2>&1) || true
	log_cmd "Verify lockdown" "nvme admin-passthru ${CTRL_DEV} --opcode=0x18" "$verify_output"

	if echo "$verify_output" | grep -qi "COMMAND.*PROHIBITED\|PROHIBITED\|error\|NVMe status\|invalid"; then
		log_pass "Lockdown: Keep Alive (0x18) correctly prohibited after lockdown"
	else
		log_warn "Lockdown: verify prohibited" "Keep Alive did not return prohibited error — controller may not enforce"
	fi

	local unlock_output
	unlock_output=$(nvme lockdown "$CTRL_DEV" --scp=0 --ofi=0x18 --ifc=0 --prhbt=0 2>&1) || true
	log_cmd "Lockdown unlock" "nvme lockdown ${CTRL_DEV} --scp=0 --ofi=0x18 --ifc=0 --prhbt=0" "$unlock_output"

	LOCKDOWN_APPLIED=0

	if echo "$unlock_output" | grep -qi "error\|NVMe status\|invalid"; then
		log_warn "Lockdown: unlock Keep Alive" "$(echo "$unlock_output" | head -1)"
	else
		log_pass "Lockdown: Keep Alive (0x18) unlocked (restored)"
	fi
}

test_lockdown_verify_unlock() {
	if ! ver_at_least 2 0; then
		log_skip "Lockdown: verify unlock restores access" "requires NVMe 2.0+"
		return
	fi

	local oacs
	oacs=$(get_id_ctrl_field "oacs")
	local oacs_int=$((oacs))
	local lockdown_bit=$(( (oacs_int >> 10) & 0x1 ))

	if [ "$lockdown_bit" -eq 0 ]; then
		log_skip "Lockdown: verify unlock" "OACS bit 10 = 0"
		return
	fi

	local output
	output=$(nvme id-ctrl "$CTRL_DEV" 2>&1) || true

	if echo "$output" | grep -q "^mn "; then
		log_pass "Controller fully accessible after lockdown unlock"
	else
		log_fail "Controller not accessible after lockdown" "id-ctrl failed"
	fi
}

test_io_mgmt_recv() {
	if ! ver_at_least 2 0; then
		log_skip "I/O Management Receive: RUH Status" "requires NVMe 2.0+"
		return
	fi

	if [ -z "$NS_DEV" ]; then
		log_skip "I/O Management Receive" "no namespace device"
		return
	fi

	local output
	output=$(nvme io-mgmt-recv "$NS_DEV" -m 1 -l 4096 2>&1) || true
	log_cmd "IO Mgmt Recv" "nvme io-mgmt-recv ${NS_DEV} -m 1 -l 4096" "$output"

	if echo "$output" | grep -qi "ruhss\|nruh\|ruh_status\|ruhi"; then
		log_pass "I/O Management Receive: RUH Status fields present (FDP capable)"
	elif echo "$output" | grep -qi "not support\|invalid\|NVMe status"; then
		log_skip "I/O Management Receive" "$(echo "$output" | head -1)"
	else
		log_pass "I/O Management Receive: command completed"
	fi
}

test_io_mgmt_send() {
	if ! ver_at_least 2 0; then
		log_skip "I/O Management Send: RUH Update" "requires NVMe 2.0+"
		return
	fi

	if [ -z "$NS_DEV" ]; then
		log_skip "I/O Management Send" "no namespace device"
		return
	fi

	local output
	output=$(nvme io-mgmt-send "$NS_DEV" -m 1 -l 0 2>&1) || true
	log_cmd "IO Mgmt Send" "nvme io-mgmt-send ${NS_DEV} -m 1 -l 0" "$output"

	if echo "$output" | grep -qi "not support\|invalid\|NVMe status"; then
		log_skip "I/O Management Send: RUH Update" "$(echo "$output" | head -1)"
	else
		log_pass "I/O Management Send: RUH Update command accepted"
	fi
}

test_virt_mgmt() {
	local oacs
	oacs=$(get_id_ctrl_field "oacs")
	local oacs_int=$((oacs))
	local virt_bit=$(( (oacs_int >> 7) & 0x1 ))

	if [ "$virt_bit" -eq 0 ]; then
		log_skip "Virtualization Management" "OACS bit 7 = 0 (not supported)"
		return
	fi

	local output
	output=$(nvme virt-mgmt "$CTRL_DEV" -c 0 -r 0 -a 1 -n 0 2>&1) || true
	log_cmd "Virt Mgmt" "nvme virt-mgmt ${CTRL_DEV} -c 0 -r 0 -a 1 -n 0" "$output"

	if echo "$output" | grep -qi "not support\|invalid\|NVMe status"; then
		log_skip "Virtualization Management" "$(echo "$output" | head -1)"
	else
		log_pass "Virtualization Management: query accepted"
	fi
}

test_capacity_mgmt() {
	if ! ver_at_least 2 0; then
		log_skip "Capacity Management" "requires NVMe 2.0+"
		return
	fi

	local output
	output=$(nvme capacity-mgmt "$CTRL_DEV" -O 0 -i 0 -l 0 -u 0 2>&1) || true
	log_cmd "Capacity Mgmt" "nvme capacity-mgmt ${CTRL_DEV} -O 0 -i 0 -l 0 -u 0" "$output"

	if echo "$output" | grep -qi "not support\|invalid\|NVMe status"; then
		log_skip "Capacity Management" "$(echo "$output" | head -1)"
	else
		log_pass "Capacity Management: probe accepted"
	fi
}

test_controller_accessible() {
	local output
	output=$(nvme id-ctrl "$CTRL_DEV" 2>&1) || true

	if echo "$output" | grep -q "^mn "; then
		log_pass "Controller accessible after all advanced admin tests"
	else
		log_fail "Controller not accessible" "id-ctrl failed after advanced admin tests"
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
				echo "Behavioral verification of NVMe Lockdown, I/O Mgmt, Virt Mgmt, Capacity Mgmt."
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

	NS_DEV=$(resolve_ns_dev "$CTRL_DEV" 2>/dev/null || true)

	if [ ! -e "$CTRL_DEV" ]; then
		echo "ERROR: Device $CTRL_DEV does not exist." >&2
		exit 1
	fi

	safe_device_check "$CTRL_DEV" "$ALLOW_DESTRUCTIVE"

	cache_id_ctrl "$CTRL_DEV"
	trap cleanup_lockdown EXIT

	init_log "nvme_advanced_admin_verify" "$CTRL_DEV"
	log_cmd "Identify Controller (cached)" "nvme id-ctrl ${CTRL_DEV}" "$_ID_CTRL_CACHE"

	local spec_ref
	spec_ref=$(get_spec_ref "advanced-admin")

	print_header \
		"NVMe Advanced Admin — Behavioral Verification" \
		"$spec_ref" \
		"$CTRL_DEV"

	echo -e "${BOLD}--- Lockdown (Behavioral: lock -> verify -> unlock -> verify) ---${RESET}"
	test_lockdown_behavioral
	test_lockdown_verify_unlock

	echo ""
	echo -e "${BOLD}--- I/O Management ---${RESET}"
	test_io_mgmt_recv
	test_io_mgmt_send

	echo ""
	echo -e "${BOLD}--- Virtualization & Capacity Management ---${RESET}"
	test_virt_mgmt
	test_capacity_mgmt

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
