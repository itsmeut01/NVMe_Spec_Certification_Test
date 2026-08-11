#!/bin/bash
# SPDX-License-Identifier: GPL-3.0+
# Copyright (C) 2025 Red Hat, Inc.
#
# NVMe Reset — Functional Verification
# Based on NVMe Base Specification — Resets section
# Tests: controller reset, post-reset identify, post-reset I/O, subsystem reset
#
# Usage:
#   ./nvme_reset_verify.sh /dev/nvme0 --allow-destructive
#   ./nvme_reset_verify.sh /dev/nvme0n1 --allow-destructive

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/nvme_test_lib.sh
source "${SCRIPT_DIR}/../common/nvme_test_lib.sh"

CTRL_DEV=""
NS_DEV=""
ALLOW_DESTRUCTIVE=""
PRE_RESET_MN=""
PRE_RESET_SN=""

# --------------------------------------------------------------------------
# Test functions
# --------------------------------------------------------------------------

wait_for_device() {
	local dev="$1"
	local timeout="${2:-20}"
	local waited=0
	while [ "$waited" -lt "$timeout" ]; do
		if [ -e "$dev" ]; then
			return 0
		fi
		sleep 2
		waited=$((waited + 2))
	done
	echo 1 > /sys/bus/pci/rescan 2>/dev/null || true
	sleep 3
	[ -e "$dev" ]
}

test_controller_reset() {
	local output
	output=$(nvme reset "$CTRL_DEV" 2>&1) || true
	log_cmd "Controller Reset" "nvme reset ${CTRL_DEV}" "$output"
	if echo "$output" | grep -qi "error\|invalid\|fail\|not support"; then
		log_fail "Controller reset" "command failed: $(echo "$output" | head -1)"
		return
	fi

	if wait_for_device "$CTRL_DEV" 20; then
		log_pass "Controller reset: device ${CTRL_DEV} exists after reset"
	else
		log_fail "Controller reset" "device ${CTRL_DEV} not found after reset"
	fi
}

test_post_reset_identify() {
	_ID_CTRL_CACHE=""
	local id_out=""
	local attempt
	for attempt in 1 2 3; do
		id_out=$(nvme id-ctrl "$CTRL_DEV" 2>&1) || true
		if echo "$id_out" | grep -q "^mn "; then
			break
		fi
		sleep 3
	done
	log_cmd "Post-reset Identify Controller" "nvme id-ctrl ${CTRL_DEV}" "$id_out"

	if ! echo "$id_out" | grep -q "^mn "; then
		log_fail "Post-reset identify" "id-ctrl failed after reset"
		return
	fi

	local mn sn
	mn=$(echo "$id_out" | grep "^mn " | sed 's/^mn[[:space:]]*:[[:space:]]*//' | sed 's/ *$//')
	sn=$(echo "$id_out" | grep "^sn " | sed 's/^sn[[:space:]]*:[[:space:]]*//' | sed 's/ *$//')

	if [ "$mn" = "$PRE_RESET_MN" ] && [ "$sn" = "$PRE_RESET_SN" ]; then
		log_pass "Post-reset identify: model/serial match pre-reset values"
	else
		log_warn "Post-reset identify" "model or serial changed (may be expected on some controllers)"
	fi

	_ID_CTRL_CACHE="$id_out"
}

test_post_reset_io() {
	if [ -z "$NS_DEV" ]; then
		log_skip "Post-reset I/O" "no namespace device"
		return
	fi

	if [ ! -e "$NS_DEV" ]; then
		nvme ns-rescan "$CTRL_DEV" 2>/dev/null || true
		wait_for_device "$NS_DEV" 15
	fi

	if [ ! -e "$NS_DEV" ]; then
		log_fail "Post-reset I/O" "namespace ${NS_DEV} not present after reset"
		return
	fi

	if write_read_verify "$NS_DEV" 0 1; then
		log_pass "Post-reset I/O: write+read on ${NS_DEV} succeeded after controller reset"
	else
		log_fail "Post-reset I/O" "write+read data mismatch after reset"
	fi
}

test_subsystem_reset() {
	local output
	output=$(nvme subsystem-reset "$CTRL_DEV" 2>&1) || true
	log_cmd "Subsystem Reset" "nvme subsystem-reset ${CTRL_DEV}" "$output"
	if echo "$output" | grep -qi "error\|invalid\|fail\|not support"; then
		log_warn "Subsystem reset" "command returned: $(echo "$output" | head -1)"
		return
	fi

	wait_for_device "$CTRL_DEV" 30

	if [ ! -e "$CTRL_DEV" ]; then
		echo 1 > /sys/bus/pci/rescan 2>/dev/null || true
		sleep 5
		wait_for_device "$CTRL_DEV" 30
	fi

	local id_out=""
	local attempt
	for attempt in 1 2 3 4 5 6; do
		id_out=$(nvme id-ctrl "$CTRL_DEV" 2>&1) || true
		if echo "$id_out" | grep -q "^mn "; then
			break
		fi
		sleep 5
	done
	log_cmd "Post-subsystem-reset Identify Controller" "nvme id-ctrl ${CTRL_DEV}" "$id_out"

	if echo "$id_out" | grep -q "^mn "; then
		nvme ns-rescan "$CTRL_DEV" 2>/dev/null || true
		sleep 2
		log_pass "Subsystem reset: id-ctrl succeeds after subsystem reset"
	else
		log_fail "Subsystem reset" "id-ctrl failed after subsystem reset"
	fi
}

test_post_reset_regs() {
	local regs_output
	regs_output=$(nvme show-regs "$CTRL_DEV" -H 2>&1) || true
	if [ -z "$regs_output" ] || echo "$regs_output" | grep -qi "not support\|error"; then
		regs_output=$(nvme show-regs "$CTRL_DEV" 2>&1) || true
	fi
	log_cmd "Post-reset registers" "nvme show-regs ${CTRL_DEV}" "$regs_output"

	if [ -z "$regs_output" ]; then
		log_skip "Post-reset register state" "could not read registers"
		return
	fi

	local csts_val
	csts_val=$(echo "$regs_output" | grep "^csts[[:space:]]" | awk -F': ' '{ print $2 }' | awk '{ print $1 }' || true)
	local cc_val
	cc_val=$(echo "$regs_output" | grep "^cc[[:space:]]" | awk -F': ' '{ print $2 }' | awk '{ print $1 }' || true)

	local all_ok=1

	if [ -n "$csts_val" ]; then
		local csts_int=$((csts_val))
		local rdy=$(( csts_int & 0x1 ))
		local cfs=$(( (csts_int >> 1) & 0x1 ))
		if [ "$rdy" -ne 1 ]; then
			log_fail "Post-reset CSTS.RDY must be 1" "RDY=${rdy}"
			all_ok=0
		fi
		if [ "$cfs" -ne 0 ]; then
			log_fail "Post-reset CSTS.CFS must be 0" "CFS=${cfs} (fatal status!)"
			all_ok=0
		fi
	fi

	if [ -n "$cc_val" ]; then
		local cc_int=$((cc_val))
		local en=$(( cc_int & 0x1 ))
		if [ "$en" -ne 1 ]; then
			log_fail "Post-reset CC.EN must be 1" "EN=${en}"
			all_ok=0
		fi
	fi

	if [ "$all_ok" -eq 1 ]; then
		log_pass "Post-reset registers: CSTS.RDY=1, CSTS.CFS=0, CC.EN=1"
	fi
}

test_post_reset_features_persist() {
	local output
	output=$(nvme get-feature "$CTRL_DEV" -f "0x07" 2>&1) || true
	log_cmd "Post-reset Get Feature 0x07" "nvme get-feature $CTRL_DEV -f 0x07" "$output"

	local result
	result=$(echo "$output" | grep -oiP '(?:result|value)[[:space:]:]*0x[0-9a-fA-F]+' | head -1 | grep -oiP '0x[0-9a-fA-F]+' || true)
	if [ -z "$result" ]; then
		result=$(echo "$output" | grep -oiP '(?:result|value)[[:space:]:]*[0-9a-fA-F]+' | head -1 | grep -oiP '[0-9a-fA-F]+$' || true)
		[ -n "$result" ] && result="0x${result}"
	fi

	if [ -n "$result" ]; then
		local val=$((result))
		local nsqa=$(( val & 0xFFFF ))
		local ncqa=$(( (val >> 16) & 0xFFFF ))
		if [ -n "$PRE_RESET_NQ" ]; then
			if [ "$result" = "$PRE_RESET_NQ" ]; then
				log_pass "Post-reset FID 0x07: NSQA=$((nsqa+1)) NCQA=$((ncqa+1)) (unchanged)"
			else
				log_pass "Post-reset FID 0x07: NSQA=$((nsqa+1)) NCQA=$((ncqa+1)) (changed from ${PRE_RESET_NQ} — expected per spec)"
			fi
		else
			log_pass "Post-reset FID 0x07: readable, NSQA=$((nsqa+1)) NCQA=$((ncqa+1))"
		fi
	else
		log_warn "Post-reset FID 0x07" "could not read Number of Queues after reset"
	fi
}

test_post_reset_smart() {
	local smart_output
	smart_output=$(nvme smart-log "$CTRL_DEV" 2>&1) || true
	log_cmd "Post-reset SMART log" "nvme smart-log ${CTRL_DEV}" "$smart_output"

	if [ -z "$smart_output" ]; then
		log_fail "Post-reset SMART" "smart-log returned empty output"
		return
	fi

	local has_temp has_spare has_cw
	has_temp=$(echo "$smart_output" | grep "^temperature" | head -1 || true)
	has_spare=$(echo "$smart_output" | grep "^available_spare" | head -1 || true)
	has_cw=$(echo "$smart_output" | grep "^critical_warning" | head -1 || true)

	if [ -n "$has_temp" ] && [ -n "$has_spare" ] && [ -n "$has_cw" ]; then
		log_pass "Post-reset SMART: temperature, available_spare, critical_warning all present"
	else
		log_warn "Post-reset SMART" "some expected fields missing"
	fi
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

PRE_RESET_NQ=""

main() {
	preflight_checks

	for arg in "$@"; do
		case "$arg" in
			--allow-destructive) ALLOW_DESTRUCTIVE="--allow-destructive" ;;
			-h|--help)
				echo "Usage: $0 /dev/nvmeX [--allow-destructive]"
				echo "Functional verification of NVMe controller and subsystem resets."
				echo "DISRUPTIVE: resets the controller. Requires --allow-destructive."
				exit 0
				;;
			/dev/nvme*)
				if [[ "$arg" =~ ^/dev/nvme[0-9]+n[0-9]+$ ]]; then
					CTRL_DEV="${arg%n*}"
					NS_DEV="$arg"
				elif [[ "$arg" =~ ^/dev/nvme[0-9]+$ ]]; then
					CTRL_DEV="$arg"
				fi
				;;
		esac
	done

	if [ -z "$CTRL_DEV" ]; then
		CTRL_DEV=$(auto_detect_safe_ctrl)
		echo -e "${BOLD}No device specified — auto-detected safe controller: ${CTRL_DEV}${RESET}"
	fi

	if [ -z "$NS_DEV" ]; then
		NS_DEV=$(ls -1 "${CTRL_DEV}n"* 2>/dev/null | grep -E "^${CTRL_DEV}n[0-9]+$" | head -1 || true)
	fi

	safe_device_check "$CTRL_DEV" "$ALLOW_DESTRUCTIVE"

	cache_id_ctrl "$CTRL_DEV"

	PRE_RESET_MN=$(get_id_ctrl_string_field "mn" | sed 's/ *$//')
	PRE_RESET_SN=$(get_id_ctrl_string_field "sn" | sed 's/ *$//')

	local nq_out
	nq_out=$(nvme get-feature "$CTRL_DEV" -f "0x07" 2>&1) || true
	PRE_RESET_NQ=$(echo "$nq_out" | grep -oiP '(?:result|value)[[:space:]:]*0x[0-9a-fA-F]+' | head -1 | grep -oiP '0x[0-9a-fA-F]+' || true)

	init_log "nvme_reset_verify" "$CTRL_DEV"
	log_cmd "Identify Controller (cached)" "nvme id-ctrl ${CTRL_DEV}" "$_ID_CTRL_CACHE"

	local spec_ref
	spec_ref=$(get_spec_ref "reset")

	print_header \
		"NVMe Reset — Functional Verification" \
		"$spec_ref" \
		"$CTRL_DEV"

	echo -e "${BOLD}--- Controller Reset ---${RESET}"
	test_controller_reset
	test_post_reset_identify
	test_post_reset_io

	echo ""
	echo -e "${BOLD}--- Post-Reset State Verification ---${RESET}"
	test_post_reset_regs
	test_post_reset_features_persist
	test_post_reset_smart

	echo ""
	echo -e "${BOLD}--- Subsystem Reset ---${RESET}"
	test_subsystem_reset

	print_summary

	if [ "$FAIL_COUNT" -gt 0 ]; then
		exit 1
	fi
	exit 0
}

main "$@"
