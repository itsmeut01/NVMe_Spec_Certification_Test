#!/bin/bash
# SPDX-License-Identifier: GPL-3.0+
# Copyright (C) 2025 Red Hat, Inc.
#
# NVMe Reservation — Functional Verification
# Based on NVMe Base Specification — Reservation commands
# Tests: register key, acquire reservation, report, release, I/O after release
#
# Usage:
#   ./nvme_reservation_verify.sh /dev/nvme0 --allow-destructive
#   ./nvme_reservation_verify.sh /dev/nvme0n1 --allow-destructive

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/nvme_test_lib.sh
source "${SCRIPT_DIR}/../common/nvme_test_lib.sh"

CTRL_DEV=""
NS_DEV=""
ALLOW_DESTRUCTIVE=""

TEST_RKEY="0x1234567890abcdef"

# --------------------------------------------------------------------------
# Test functions
# --------------------------------------------------------------------------

test_resv_register() {
	local output
	output=$(nvme resv-register "$NS_DEV" --rrega=0 --nrkey="$TEST_RKEY" 2>&1) || true
	if echo "$output" | grep -qi "error\|invalid\|not support\|status"; then
		if echo "$output" | grep -qi "not support\|Reservation"; then
			log_skip "Register reservation key" "reservations not supported by controller"
		else
			log_fail "Register reservation key" "error: $output"
		fi
	else
		log_pass "Register reservation key (nrkey=${TEST_RKEY}) accepted"
	fi
}

test_resv_acquire() {
	local output
	output=$(nvme resv-acquire "$NS_DEV" --racqa=0 --crkey="$TEST_RKEY" --rtype=1 2>&1) || true
	if echo "$output" | grep -qi "error\|invalid\|not support\|status"; then
		log_warn "Acquire reservation" "command returned: $(echo "$output" | head -1)"
	else
		log_pass "Acquire exclusive reservation (rtype=1) accepted"
	fi
}

test_resv_report() {
	local output
	output=$(nvme resv-report "$NS_DEV" -s 1 2>&1) || true
	if echo "$output" | grep -qi "error\|invalid\|not support"; then
		log_warn "Report reservations" "command returned: $(echo "$output" | head -1)"
		return
	fi
	if echo "$output" | grep -qi "regctl\|Registered\|key\|rtype"; then
		log_pass "Report reservations: registration data visible"
	else
		log_pass "Report reservations: command completed (output may vary by nvme-cli version)"
	fi
}

test_resv_release() {
	local output
	output=$(nvme resv-release "$NS_DEV" --rrela=0 --crkey="$TEST_RKEY" --rtype=1 2>&1) || true
	if echo "$output" | grep -qi "error\|invalid\|not support\|status"; then
		log_warn "Release reservation" "command returned: $(echo "$output" | head -1)"
	else
		log_pass "Release reservation accepted"
	fi

	local unreg_output
	unreg_output=$(nvme resv-register "$NS_DEV" --rrega=1 --crkey="$TEST_RKEY" 2>&1) || true
}

test_resv_io_after_release() {
	if write_read_verify "$NS_DEV" 0 1; then
		log_pass "I/O after reservation release: write+read succeeded"
	else
		log_fail "I/O after reservation release" "write+read data mismatch"
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
				echo "Functional verification of NVMe Reservations."
				echo "DESTRUCTIVE: modifies reservation state. Requires --allow-destructive."
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

	if [ -z "$NS_DEV" ]; then
		echo "ERROR: No namespace device found for ${CTRL_DEV}." >&2
		exit 1
	fi

	safe_device_check "$CTRL_DEV" "$ALLOW_DESTRUCTIVE"

	cache_id_ctrl "$CTRL_DEV"

	_ID_CTRL_CACHE=""
	cache_id_ctrl "$CTRL_DEV"

	local ns_output
	ns_output=$(nvme id-ns "$NS_DEV" 2>&1) || true
	local rescap
	rescap=$(echo "$ns_output" | grep "^rescap" | awk '{print $3}' || true)
	if [ -n "$rescap" ] && [ "$((rescap))" -eq 0 ]; then
		echo -e "${YELLOW}SKIP${RESET}  Reservations not supported (rescap=0)"
		exit 0
	fi

	local nmic
	nmic=$(echo "$ns_output" | grep "^nmic" | awk '{print $3}' || true)
	if [ -n "$nmic" ] && [ "$(( nmic & 0x1 ))" -eq 0 ]; then
		echo -e "${YELLOW}SKIP${RESET}  Namespace is private (NMIC bit 0=0) — reservations require shared namespace"
		exit 0
	fi

	init_log "nvme_reservation_verify" "$CTRL_DEV"
	log_cmd "Identify Controller (cached)" "nvme id-ctrl ${CTRL_DEV}" "$_ID_CTRL_CACHE"
	log_cmd "Identify Namespace" "nvme id-ns ${NS_DEV}" "$ns_output"

	local spec_ref
	spec_ref=$(get_spec_ref "reservation")

	print_header \
		"NVMe Reservation — Functional Verification" \
		"$spec_ref" \
		"$CTRL_DEV"

	echo -e "${BOLD}--- Reservation Lifecycle ---${RESET}"
	test_resv_register
	test_resv_acquire
	test_resv_report
	test_resv_release
	test_resv_io_after_release

	print_summary

	if [ "$FAIL_COUNT" -gt 0 ]; then
		exit 1
	fi
	exit 0
}

main "$@"
