#!/bin/bash
# SPDX-License-Identifier: GPL-3.0+
# Copyright (C) 2025 Red Hat, Inc.
#
# NVMe Sanitize — Functional Verification
# Based on NVMe Base Specification — Sanitize command
# Tests: block erase, poll progress, verify result, overwrite, I/O post-sanitize
#
# Usage:
#   ./nvme_sanitize_verify.sh /dev/nvme0 --allow-destructive
#   ./nvme_sanitize_verify.sh /dev/nvme0n1 --allow-destructive

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/nvme_test_lib.sh
source "${SCRIPT_DIR}/../common/nvme_test_lib.sh"

CTRL_DEV=""
NS_DEV=""
ALLOW_DESTRUCTIVE=""
SANICAP_VAL=0

poll_sanitize_completion() {
	local timeout="$1"
	local elapsed=0

	while [ "$elapsed" -lt "$timeout" ]; do
		local san_log
		san_log=$(nvme sanitize-log "$CTRL_DEV" 2>&1) || true
		local sstat
		sstat=$(echo "$san_log" | grep -i "Sanitize Status\|sstat\|SSTAT" | head -1 || true)

		if echo "$sstat" | grep -qi "success\|complete\|0x0101\| 257 "; then
			return 0
		fi

		if echo "$sstat" | grep -qi "fail\|error"; then
			return 1
		fi

		local sprog
		sprog=$(echo "$san_log" | grep -i "progress\|SPROG" | head -1 || true)
		if [ -n "$sprog" ] && [ "$((elapsed % 30))" -eq 0 ]; then
			echo -e "    Sanitize progress: $(echo "$sprog" | sed 's/.*: //')"
		fi

		sleep 10
		elapsed=$((elapsed + 10))
	done
	return 2
}

# --------------------------------------------------------------------------
# Test functions
# --------------------------------------------------------------------------

test_block_erase() {
	local bes=$(( (SANICAP_VAL >> 1) & 0x1 ))
	if [ "$bes" -eq 0 ]; then
		log_skip "Block Erase sanitize" "SANICAP BES bit not set"
		return
	fi

	local output
	output=$(nvme sanitize "$CTRL_DEV" --sanact=2 2>&1) || true
	if echo "$output" | grep -qi "error\|invalid\|fail"; then
		log_fail "Block Erase sanitize" "command failed: $(echo "$output" | head -1)"
	else
		log_pass "Block Erase sanitize (sanact=2) accepted"
	fi
}

test_poll_sanitize() {
	local bes=$(( (SANICAP_VAL >> 1) & 0x1 ))
	if [ "$bes" -eq 0 ]; then
		log_skip "Poll sanitize progress" "Block Erase not initiated"
		return
	fi

	local rc=0
	poll_sanitize_completion 600 || rc=$?

	case "$rc" in
		0) log_pass "Sanitize completed successfully" ;;
		1) log_fail "Poll sanitize progress" "sanitize reported failure" ;;
		2) log_warn "Poll sanitize progress" "timeout after 600s" ;;
	esac
}

test_sanitize_result() {
	local bes=$(( (SANICAP_VAL >> 1) & 0x1 ))
	if [ "$bes" -eq 0 ]; then
		log_skip "Sanitize result" "Block Erase not initiated"
		return
	fi

	local san_log
	san_log=$(nvme sanitize-log "$CTRL_DEV" 2>&1) || true
	local sstat
	sstat=$(echo "$san_log" | grep -i "Sanitize Status\|sstat\|SSTAT" | head -1 || true)

	if echo "$sstat" | grep -qi "success\|complete\|0x0101"; then
		log_pass "Sanitize result: completed successfully"
	elif [ -n "$sstat" ]; then
		log_warn "Sanitize result" "status: $(echo "$sstat" | sed 's/.*: //')"
	else
		log_skip "Sanitize result" "could not parse sanitize-log"
	fi
}

test_overwrite_sanitize() {
	local ows=$(( (SANICAP_VAL >> 2) & 0x1 ))
	if [ "$ows" -eq 0 ]; then
		log_skip "Overwrite sanitize" "SANICAP OWS bit not set"
		return
	fi

	local output
	output=$(nvme sanitize "$CTRL_DEV" --sanact=3 --ovrpat=0x12345678 2>&1) || true
	if echo "$output" | grep -qi "error\|invalid\|fail"; then
		log_warn "Overwrite sanitize" "command returned: $(echo "$output" | head -1)"
		return
	fi
	log_pass "Overwrite sanitize (sanact=3) accepted"

	local rc=0
	poll_sanitize_completion 600 || rc=$?
	if [ "$rc" -eq 0 ]; then
		log_pass "Overwrite sanitize completed successfully"
	elif [ "$rc" -eq 1 ]; then
		log_fail "Overwrite sanitize" "reported failure"
	else
		log_warn "Overwrite sanitize" "timeout after 600s"
	fi
}

test_io_post_sanitize() {
	if [ -z "$NS_DEV" ]; then
		log_skip "I/O post-sanitize" "no namespace device"
		return
	fi

	local ns_check
	ns_check=$(nvme id-ns "$NS_DEV" 2>&1) || true
	if ! echo "$ns_check" | grep -q "^nsze"; then
		log_fail "I/O post-sanitize" "namespace not accessible after sanitize"
		return
	fi

	local bs=512
	local lbads
	lbads=$(echo "$ns_check" | grep "lbads" | head -1 | grep -oP 'lbads\s*:\s*\K[0-9]+' || true)
	if [ -n "$lbads" ] && [ "$((lbads))" -gt 0 ]; then
		bs=$((1 << lbads))
	fi

	if write_read_verify "$NS_DEV" 0 1 "$bs"; then
		log_pass "I/O post-sanitize: write+read succeeded on ${NS_DEV}"
	else
		log_fail "I/O post-sanitize" "write+read data mismatch"
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
				echo "Functional verification of NVMe Sanitize command."
				echo "DESTRUCTIVE: erases ALL data on ALL namespaces. Requires --allow-destructive."
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

	if ! ver_at_least 1 3; then
		echo -e "${YELLOW}SKIP${RESET}  Sanitize requires NVMe 1.3+"
		exit 0
	fi

	local sanicap
	sanicap=$(get_id_ctrl_field "sanicap")
	if [ -z "$sanicap" ] || [ "$((sanicap))" -eq 0 ]; then
		echo -e "${YELLOW}SKIP${RESET}  Sanitize not supported (SANICAP=0)"
		exit 0
	fi
	SANICAP_VAL=$((sanicap))

	init_log "nvme_sanitize_verify" "$CTRL_DEV"
	log_cmd "Identify Controller (cached)" "nvme id-ctrl ${CTRL_DEV}" "$_ID_CTRL_CACHE"

	local spec_ref
	spec_ref=$(get_spec_ref "sanitize")

	print_header \
		"NVMe Sanitize — Functional Verification" \
		"$spec_ref" \
		"$CTRL_DEV"

	echo -e "  SANICAP: 0x$(printf '%08x' "$SANICAP_VAL")  BES=$(( (SANICAP_VAL >> 1) & 1 ))  OWS=$(( (SANICAP_VAL >> 2) & 1 ))  CES=$(( SANICAP_VAL & 1 ))"
	echo ""

	echo -e "${BOLD}--- Block Erase Sanitize ---${RESET}"
	test_block_erase
	test_poll_sanitize
	test_sanitize_result

	echo ""
	echo -e "${BOLD}--- Overwrite Sanitize ---${RESET}"
	test_overwrite_sanitize

	echo ""
	echo -e "${BOLD}--- Post-Sanitize I/O ---${RESET}"
	test_io_post_sanitize

	print_summary

	if [ "$FAIL_COUNT" -gt 0 ]; then
		exit 1
	fi
	exit 0
}

main "$@"
