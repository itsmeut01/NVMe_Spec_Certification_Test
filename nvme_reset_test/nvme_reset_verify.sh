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

test_controller_reset() {
	local output
	output=$(nvme reset "$CTRL_DEV" 2>&1) || true
	if echo "$output" | grep -qi "error\|invalid\|fail\|not support"; then
		log_fail "Controller reset" "command failed: $(echo "$output" | head -1)"
		return
	fi

	sleep 3

	if [ -e "$CTRL_DEV" ]; then
		log_pass "Controller reset: device ${CTRL_DEV} exists after reset"
	else
		sleep 5
		if [ -e "$CTRL_DEV" ]; then
			log_pass "Controller reset: device ${CTRL_DEV} re-appeared after 8s"
		else
			log_fail "Controller reset" "device ${CTRL_DEV} not found after reset"
		fi
	fi
}

test_post_reset_identify() {
	_ID_CTRL_CACHE=""
	local id_out
	id_out=$(nvme id-ctrl "$CTRL_DEV" 2>&1) || true

	if ! echo "$id_out" | grep -q "^mn "; then
		sleep 3
		id_out=$(nvme id-ctrl "$CTRL_DEV" 2>&1) || true
	fi

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
		sleep 3
		nvme ns-rescan "$CTRL_DEV" 2>/dev/null || true
		sleep 1
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
	if echo "$output" | grep -qi "error\|invalid\|fail\|not support"; then
		log_warn "Subsystem reset" "command returned: $(echo "$output" | head -1)"
		return
	fi

	sleep 5

	local id_out
	id_out=$(nvme id-ctrl "$CTRL_DEV" 2>&1) || true
	if ! echo "$id_out" | grep -q "^mn "; then
		sleep 5
		id_out=$(nvme id-ctrl "$CTRL_DEV" 2>&1) || true
	fi

	if echo "$id_out" | grep -q "^mn "; then
		log_pass "Subsystem reset: id-ctrl succeeds after subsystem reset"
	else
		log_fail "Subsystem reset" "id-ctrl failed after subsystem reset"
	fi
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

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
	echo -e "${BOLD}--- Subsystem Reset ---${RESET}"
	test_subsystem_reset

	print_summary

	if [ "$FAIL_COUNT" -gt 0 ]; then
		exit 1
	fi
	exit 0
}

main "$@"
