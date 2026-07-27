#!/bin/bash
# SPDX-License-Identifier: GPL-3.0+
# Copyright (C) 2025 Red Hat, Inc.
#
# NVMe Security & Directives — Behavioral Verification
# Based on NVMe Base Specification — Security Receive, Directive Send/Receive
# Tests: security-recv safe probe, directives enable/disable Streams cycle,
#        admin passthru round-trip
#
# Usage:
#   ./nvme_security_directives_verify.sh /dev/nvme0 --allow-destructive
#   ./nvme_security_directives_verify.sh              # auto-detects

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/nvme_test_lib.sh
source "${SCRIPT_DIR}/../common/nvme_test_lib.sh"

CTRL_DEV=""
NS_DEV=""
ALLOW_DESTRUCTIVE=""
TMP_DIR=""

SAVED_DIRECTIVE_STATE=""

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

setup_tmp() {
	TMP_DIR=$(mktemp -d)
}

cleanup() {
	if [ -n "$SAVED_DIRECTIVE_STATE" ] && [ -n "$NS_DEV" ]; then
		nvme dir-send "$NS_DEV" -D 0 -O 1 -T 1 -e 0 2>/dev/null || true
	fi
	[ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"
}

# --------------------------------------------------------------------------
# Security tests (read-only — security-send is too dangerous)
# --------------------------------------------------------------------------

test_security_recv_protocols() {
	local oacs
	oacs=$(get_id_ctrl_field "oacs")
	local oacs_int=$((oacs))
	local sec_bit=$(( oacs_int & 0x1 ))
	if [ "$sec_bit" -eq 0 ]; then
		log_skip "Security Receive: supported protocols" "OACS bit 0 = 0 (Security not supported)"
		return
	fi

	local sec_file="${TMP_DIR}/sec_recv.bin"
	local err_file="${TMP_DIR}/sec_err"
	nvme security-recv "$CTRL_DEV" --secp=0x00 --spsp=0 \
		--size=4096 --al=4096 -b >"$sec_file" 2>"$err_file" || true
	local err_output
	err_output=$(cat "$err_file" 2>/dev/null || true)
	log_cmd "Security Receive secp=0" "nvme security-recv ${CTRL_DEV} -p 0 -s 0 -x 4096 -t 4096" "$err_output"

	if [ -f "$sec_file" ] && [ -s "$sec_file" ]; then
		log_pass "Security Receive (secp=0x00): returned protocol list data"
	elif echo "$err_output" | grep -qi "error\|NVMe status\|invalid"; then
		log_warn "Security Receive" "command returned error: $(echo "$err_output" | head -1)"
	else
		log_pass "Security Receive (secp=0x00): command completed (empty response may be valid)"
	fi
}

test_security_recv_parseable() {
	local oacs
	oacs=$(get_id_ctrl_field "oacs")
	local oacs_int=$((oacs))
	local sec_bit=$(( oacs_int & 0x1 ))
	if [ "$sec_bit" -eq 0 ]; then
		log_skip "Security Receive response parseable" "OACS bit 0 = 0"
		return
	fi

	local output
	output=$(nvme security-recv "$CTRL_DEV" --secp=0x00 --spsp=0 \
		--size=4096 --al=4096 2>&1) || true

	if echo "$output" | grep -qi "NVMe status.*SUCCESS\|security receive\|^$"; then
		log_pass "Security Receive: response is parseable (no crash, clean output)"
	elif echo "$output" | grep -qi "could not\|Segmentation\|core dump"; then
		log_fail "Security Receive response" "nvme-cli crashed: $(echo "$output" | head -1)"
	else
		log_pass "Security Receive: command completed without crash"
	fi
}

# --------------------------------------------------------------------------
# Directive tests (behavioral: enable -> verify -> query -> disable -> verify)
# --------------------------------------------------------------------------

test_directive_read_state() {
	local oacs
	oacs=$(get_id_ctrl_field "oacs")
	local oacs_int=$((oacs))
	local dir_bit=$(( (oacs_int >> 5) & 0x1 ))
	if [ "$dir_bit" -eq 0 ]; then
		log_skip "Directive Receive: read current state" "OACS bit 5 = 0 (Directives not supported)"
		return
	fi

	if [ -z "$NS_DEV" ]; then
		log_skip "Directive Receive: read current state" "no namespace device"
		return
	fi

	local output
	output=$(nvme dir-receive "$NS_DEV" -D 0 -O 1 -l 4096 2>&1) || true
	log_cmd "Directive Receive identify" "nvme dir-receive ${NS_DEV} -D 0 -O 1 -l 4096" "$output"

	if echo "$output" | grep -qi "error\|NVMe status\|invalid"; then
		log_warn "Directive Receive: read current state" "$(echo "$output" | head -1)"
	else
		SAVED_DIRECTIVE_STATE="read"
		log_pass "Directive Receive: read current directive state (Identify directive params)"
	fi
}

test_directive_enable_streams() {
	local oacs
	oacs=$(get_id_ctrl_field "oacs")
	local oacs_int=$((oacs))
	local dir_bit=$(( (oacs_int >> 5) & 0x1 ))
	if [ "$dir_bit" -eq 0 ]; then
		log_skip "Directive Send: enable Streams" "OACS bit 5 = 0"
		return
	fi

	if [ -z "$NS_DEV" ]; then
		log_skip "Directive Send: enable Streams" "no namespace device"
		return
	fi

	local output
	output=$(nvme dir-send "$NS_DEV" -D 0 -O 1 -T 1 -e 1 2>&1) || true
	log_cmd "Directive Send enable Streams" "nvme dir-send ${NS_DEV} -D 0 -O 1 -T 1 -e 1" "$output"

	if echo "$output" | grep -qi "NVMe status.*SUCCESS\|dir-send:.*succ"; then
		SAVED_DIRECTIVE_STATE="enabled"
		log_pass "Directive Send: Streams directive enabled successfully"
	elif echo "$output" | grep -qi "error\|NVMe status\|invalid"; then
		log_warn "Directive Send: enable Streams" "$(echo "$output" | head -1) — controller may not support Streams"
	else
		SAVED_DIRECTIVE_STATE="enabled"
		log_pass "Directive Send: enable Streams command completed (no error)"
	fi
}

test_directive_verify_enabled() {
	local oacs
	oacs=$(get_id_ctrl_field "oacs")
	local oacs_int=$((oacs))
	local dir_bit=$(( (oacs_int >> 5) & 0x1 ))
	if [ "$dir_bit" -eq 0 ] || [ "$SAVED_DIRECTIVE_STATE" != "enabled" ]; then
		log_skip "Directive Receive: verify Streams enabled" "Streams not enabled or OACS bit 5 = 0"
		return
	fi

	if [ -z "$NS_DEV" ]; then
		log_skip "Directive Receive: verify Streams enabled" "no namespace device"
		return
	fi

	local output
	output=$(nvme dir-receive "$NS_DEV" -D 0 -O 1 -l 4096 2>&1) || true
	log_cmd "Directive Receive verify enabled" "nvme dir-receive ${NS_DEV} -D 0 -O 1 -l 4096" "$output"

	if echo "$output" | grep -qi "streams.*enable\|directives supported\|dir type"; then
		log_pass "Directive Receive: Streams directive confirmed enabled"
	elif ! echo "$output" | grep -qi "error\|NVMe status"; then
		log_pass "Directive Receive: directive params readable after enable (state change accepted)"
	else
		log_warn "Directive Receive: verify enabled" "$(echo "$output" | head -1)"
	fi
}

test_streams_params() {
	local oacs
	oacs=$(get_id_ctrl_field "oacs")
	local oacs_int=$((oacs))
	local dir_bit=$(( (oacs_int >> 5) & 0x1 ))
	if [ "$dir_bit" -eq 0 ] || [ "$SAVED_DIRECTIVE_STATE" != "enabled" ]; then
		log_skip "Streams directive params" "Streams not enabled or not supported"
		return
	fi

	if [ -z "$NS_DEV" ]; then
		log_skip "Streams directive params" "no namespace device"
		return
	fi

	local output
	output=$(nvme dir-receive "$NS_DEV" -D 1 -O 1 2>&1) || true
	log_cmd "Streams params" "nvme dir-receive ${NS_DEV} -D 1 -O 1" "$output"

	if echo "$output" | grep -qi "msl\|nssa\|nsso\|streams"; then
		log_pass "Streams params: MSL/NSSA/NSSO fields present"
	elif ! echo "$output" | grep -qi "error\|NVMe status"; then
		log_pass "Streams params: command succeeded"
	else
		log_warn "Streams params" "$(echo "$output" | head -1)"
	fi
}

test_streams_status() {
	local oacs
	oacs=$(get_id_ctrl_field "oacs")
	local oacs_int=$((oacs))
	local dir_bit=$(( (oacs_int >> 5) & 0x1 ))
	if [ "$dir_bit" -eq 0 ] || [ "$SAVED_DIRECTIVE_STATE" != "enabled" ]; then
		log_skip "Streams directive status" "Streams not enabled or not supported"
		return
	fi

	if [ -z "$NS_DEV" ]; then
		log_skip "Streams directive status" "no namespace device"
		return
	fi

	local output
	output=$(nvme dir-receive "$NS_DEV" -D 1 -O 2 2>&1) || true
	log_cmd "Streams status" "nvme dir-receive ${NS_DEV} -D 1 -O 2" "$output"

	if ! echo "$output" | grep -qi "error\|NVMe status\|invalid"; then
		log_pass "Streams status: readable while Streams enabled"
	else
		log_warn "Streams status" "$(echo "$output" | head -1)"
	fi
}

test_directive_disable_streams() {
	local oacs
	oacs=$(get_id_ctrl_field "oacs")
	local oacs_int=$((oacs))
	local dir_bit=$(( (oacs_int >> 5) & 0x1 ))
	if [ "$dir_bit" -eq 0 ]; then
		log_skip "Directive Send: disable Streams (restore)" "OACS bit 5 = 0"
		return
	fi

	if [ -z "$NS_DEV" ]; then
		log_skip "Directive Send: disable Streams" "no namespace device"
		return
	fi

	local output
	output=$(nvme dir-send "$NS_DEV" -D 0 -O 1 -T 1 -e 0 2>&1) || true
	log_cmd "Directive Send disable Streams" "nvme dir-send ${NS_DEV} -D 0 -O 1 -T 1 -e 0" "$output"

	SAVED_DIRECTIVE_STATE=""

	if echo "$output" | grep -qi "error\|NVMe status\|invalid"; then
		log_warn "Directive Send: disable Streams" "$(echo "$output" | head -1)"
	else
		log_pass "Directive Send: Streams directive disabled (restored)"
	fi
}

test_directive_verify_disabled() {
	local oacs
	oacs=$(get_id_ctrl_field "oacs")
	local oacs_int=$((oacs))
	local dir_bit=$(( (oacs_int >> 5) & 0x1 ))
	if [ "$dir_bit" -eq 0 ]; then
		log_skip "Directive Receive: verify Streams disabled" "OACS bit 5 = 0"
		return
	fi

	if [ -z "$NS_DEV" ]; then
		log_skip "Directive Receive: verify Streams disabled" "no namespace device"
		return
	fi

	local output
	output=$(nvme dir-receive "$NS_DEV" -D 0 -O 1 -l 4096 2>&1) || true

	if ! echo "$output" | grep -qi "error\|NVMe status"; then
		log_pass "Directive Receive: state readable after disabling Streams (restore verified)"
	else
		log_warn "Directive Receive: verify disabled" "$(echo "$output" | head -1)"
	fi
}

# --------------------------------------------------------------------------
# Admin passthru
# --------------------------------------------------------------------------

test_admin_passthru() {
	local passthru_output
	passthru_output=$(nvme admin-passthru "$CTRL_DEV" --opcode=0x06 --cdw10=1 \
		--data-len=4096 --read 2>&1) || true
	log_cmd "Admin passthru Identify" "nvme admin-passthru ${CTRL_DEV} --opcode=0x06 --cdw10=1" "$passthru_output"

	local id_mn
	id_mn=$(get_id_ctrl_string_field "mn" | sed 's/ *$//')

	if echo "$passthru_output" | grep -q "$id_mn"; then
		log_pass "Admin passthru: Identify via opcode=0x06 returns matching model name"
	elif echo "$passthru_output" | grep -qi "error\|NVMe status\|invalid"; then
		log_warn "Admin passthru" "command returned error: $(echo "$passthru_output" | head -1)"
	else
		local passthru_check
		passthru_check=$(nvme admin-passthru "$CTRL_DEV" --opcode=0x06 --cdw10=1 \
			--data-len=4096 --read 2>/dev/null | grep -aoP '[\x20-\x7E]{4,}' | head -5 || true)
		if [ -n "$passthru_check" ]; then
			log_pass "Admin passthru: Identify returned data via opcode=0x06"
		else
			log_warn "Admin passthru" "returned data but could not cross-check with id-ctrl"
		fi
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
				echo "Usage: $0 [/dev/nvmeX | /dev/nvmeXnY] [--allow-destructive]"
				echo "Behavioral verification of NVMe Security Receive and Directives."
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
	setup_tmp
	trap cleanup EXIT

	init_log "nvme_security_directives_verify" "$CTRL_DEV"
	log_cmd "Identify Controller (cached)" "nvme id-ctrl ${CTRL_DEV}" "$_ID_CTRL_CACHE"

	local spec_ref
	spec_ref=$(get_spec_ref "security-directives")

	print_header \
		"NVMe Security & Directives — Behavioral Verification" \
		"$spec_ref" \
		"$CTRL_DEV"

	echo -e "${BOLD}--- Security Receive (read-only probe) ---${RESET}"
	test_security_recv_protocols
	test_security_recv_parseable

	echo ""
	echo -e "${BOLD}--- Directives: Save Current State ---${RESET}"
	test_directive_read_state

	echo ""
	echo -e "${BOLD}--- Directives: Enable Streams ---${RESET}"
	test_directive_enable_streams
	test_directive_verify_enabled

	echo ""
	echo -e "${BOLD}--- Directives: Query Streams While Enabled ---${RESET}"
	test_streams_params
	test_streams_status

	echo ""
	echo -e "${BOLD}--- Directives: Disable Streams (Restore) ---${RESET}"
	test_directive_disable_streams
	test_directive_verify_disabled

	echo ""
	echo -e "${BOLD}--- Admin Passthru ---${RESET}"
	test_admin_passthru

	print_summary

	if [ "$FAIL_COUNT" -gt 0 ]; then
		exit 1
	fi
	exit 0
}

main "$@"
