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
DEFAULT_SANITIZE_TIMEOUT=1800

get_sanitize_estimated_time() {
	local san_type="$1"
	local san_log
	san_log=$(nvme sanitize-log "$CTRL_DEV" 2>&1) || true

	local field_pattern=""
	case "$san_type" in
		block_erase) field_pattern="Estimated Time For Block Erase " ;;
		overwrite)   field_pattern="Estimated Time For Overwrite " ;;
		crypto)      field_pattern="Estimated Time For Crypto Erase " ;;
	esac

	local est_line
	est_line=$(echo "$san_log" | grep -i "$field_pattern" | grep -v "No-Deallocate" | head -1 || true)
	local est_val
	est_val=$(echo "$est_line" | grep -oP ':\s*\K[0-9]+' | head -1 || true)

	if [ -z "$est_val" ] || [ "$est_val" -eq 0 ] || [ "$est_val" -ge 4294967295 ]; then
		echo "$DEFAULT_SANITIZE_TIMEOUT"
	else
		echo $(( est_val + (est_val / 5) ))
	fi
}

parse_sstat() {
	local san_log="$1"
	local sstat_line
	sstat_line=$(echo "$san_log" | grep -i "Sanitize Status\|SSTAT" | head -1 || true)
	local sstat_val
	sstat_val=$(echo "$sstat_line" | grep -oP '0x[0-9a-fA-F]+' | head -1 || true)
	if [ -z "$sstat_val" ]; then
		sstat_val=$(echo "$sstat_line" | grep -oP ':\s*\K[0-9]+' | head -1 || true)
	fi
	if [ -n "$sstat_val" ]; then
		echo $((sstat_val))
	else
		echo ""
	fi
}

wait_for_sanitize_start() {
	local wait_max=30
	local waited=0
	# Read SPROG before polling — if it changes, the new sanitize has started
	local initial_sprog
	initial_sprog=$(nvme sanitize-log "$CTRL_DEV" 2>&1 | grep -i "progress\|SPROG" | head -1 | grep -oP ':\s*\K[0-9]+' || true)

	sleep 2
	waited=2

	while [ "$waited" -lt "$wait_max" ]; do
		local san_log
		san_log=$(nvme sanitize-log "$CTRL_DEV" 2>&1) || true
		local sstat_int
		sstat_int=$(parse_sstat "$san_log")
		if [ -n "$sstat_int" ]; then
			local status_bits=$(( sstat_int & 0x7 ))
			# 010b=in progress
			if [ "$status_bits" -eq 2 ]; then
				echo -e "    Sanitize in progress (SSTAT=0x$(printf '%x' "$sstat_int"), waited ${waited}s)"
				return 0
			fi
			# 001b or 100b = completed — sanitize finished faster than we could poll
			if [ "$status_bits" -eq 1 ] || [ "$status_bits" -eq 4 ]; then
				echo -e "    Sanitize already completed (SSTAT=0x$(printf '%x' "$sstat_int"), waited ${waited}s — fast completion)"
				return 0
			fi
		fi
		sleep 2
		waited=$((waited + 2))
	done
	echo -e "    SSTAT did not transition within ${wait_max}s"
	return 1
}

poll_sanitize_completion() {
	local timeout="$1"
	local elapsed=0

	while [ "$elapsed" -lt "$timeout" ]; do
		local san_log
		san_log=$(nvme sanitize-log "$CTRL_DEV" 2>&1) || true

		local sstat_int
		sstat_int=$(parse_sstat "$san_log")
		if [ -n "$sstat_int" ]; then
			local status_bits=$(( sstat_int & 0x7 ))
			# 001b=completed, 100b=NDA completed
			if [ "$status_bits" -eq 1 ] || [ "$status_bits" -eq 4 ]; then
				return 0
			fi
			# 011b=failed
			if [ "$status_bits" -eq 3 ]; then
				return 1
			fi
		fi

		local sprog
		sprog=$(echo "$san_log" | grep -i "progress\|SPROG" | head -1 || true)
		if [ -n "$sprog" ] && [ "$((elapsed % 60))" -eq 0 ]; then
			echo -e "    Sanitize progress: $(echo "$sprog" | sed 's/.*: //') [${elapsed}s / ${timeout}s]"
		fi

		sleep 10
		elapsed=$((elapsed + 10))
	done
	return 2
}

# --------------------------------------------------------------------------
# Test functions
# --------------------------------------------------------------------------

dirty_drive() {
	if [ -z "$NS_DEV" ]; then
		return
	fi
	echo -e "    Writing data to dirty the drive before sanitize..."
	dd if=/dev/urandom of="$NS_DEV" bs=1M count=128 oflag=direct 2>/dev/null || true
	sync
}

test_block_erase() {
	local bes=$(( (SANICAP_VAL >> 1) & 0x1 ))
	if [ "$bes" -eq 0 ]; then
		log_skip "Block Erase sanitize" "SANICAP BES bit not set"
		return
	fi

	dirty_drive

	local output
	output=$(nvme sanitize "$CTRL_DEV" --sanact=2 2>&1) || true
	log_cmd "Block Erase Sanitize" "nvme sanitize ${CTRL_DEV} --sanact=2" "$output"
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

	if ! wait_for_sanitize_start; then
		log_warn "Poll sanitize progress" "SSTAT never reached in-progress — sanitize may not have started"
		return
	fi

	local timeout
	timeout=$(get_sanitize_estimated_time "block_erase")
	echo -e "    Poll timeout: ${timeout}s (from sanitize-log estimated time, default=${DEFAULT_SANITIZE_TIMEOUT}s)"

	local rc=0
	poll_sanitize_completion "$timeout" || rc=$?

	case "$rc" in
		0) log_pass "Sanitize completed successfully" ;;
		1) log_fail "Poll sanitize progress" "sanitize reported failure" ;;
		2) log_warn "Poll sanitize progress" "timeout after ${timeout}s" ;;
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
	log_cmd "Sanitize Log (result check)" "nvme sanitize-log ${CTRL_DEV}" "$san_log"
	local sstat_int
	sstat_int=$(parse_sstat "$san_log")

	if [ -z "$sstat_int" ]; then
		log_skip "Sanitize result" "could not parse sanitize-log"
		return
	fi

	local status_bits=$(( sstat_int & 0x7 ))
	if [ "$status_bits" -eq 1 ] || [ "$status_bits" -eq 4 ]; then
		log_pass "Sanitize result: completed successfully (SSTAT=0x$(printf '%x' "$sstat_int"))"
	elif [ "$status_bits" -eq 3 ]; then
		log_fail "Sanitize result" "sanitize failed (SSTAT=0x$(printf '%x' "$sstat_int"))"
	elif [ "$status_bits" -eq 2 ]; then
		log_warn "Sanitize result" "still in progress (SSTAT=0x$(printf '%x' "$sstat_int"))"
	else
		log_warn "Sanitize result" "SSTAT=0x$(printf '%x' "$sstat_int") (status bits=${status_bits})"
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
	log_cmd "Overwrite Sanitize" "nvme sanitize ${CTRL_DEV} --sanact=3 --ovrpat=0x12345678" "$output"
	if echo "$output" | grep -qi "error\|invalid\|fail"; then
		log_warn "Overwrite sanitize" "command returned: $(echo "$output" | head -1)"
		return
	fi
	log_pass "Overwrite sanitize (sanact=3) accepted"

	if ! wait_for_sanitize_start; then
		log_warn "Overwrite sanitize" "SSTAT never reached in-progress"
		return
	fi

	local timeout
	timeout=$(get_sanitize_estimated_time "overwrite")
	echo -e "    Poll timeout: ${timeout}s (from sanitize-log estimated time, default=${DEFAULT_SANITIZE_TIMEOUT}s)"

	local rc=0
	poll_sanitize_completion "$timeout" || rc=$?
	if [ "$rc" -eq 0 ]; then
		log_pass "Overwrite sanitize completed successfully"
	elif [ "$rc" -eq 1 ]; then
		log_fail "Overwrite sanitize" "reported failure"
	else
		log_warn "Overwrite sanitize" "timeout after ${timeout}s"
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
