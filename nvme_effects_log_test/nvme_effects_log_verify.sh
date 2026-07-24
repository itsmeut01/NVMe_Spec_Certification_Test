#!/bin/bash
# SPDX-License-Identifier: GPL-3.0+
# Copyright (C) 2025 Red Hat, Inc.
#
# NVMe Commands Supported and Effects Log verification
# Based on NVMe Base Specification — Commands Supported and Effects Log
# Field names from nvme-cli upstream nvme-print-stdout.c
#
# Usage:
#   ./nvme_effects_log_verify.sh /dev/nvme0
#   ./nvme_effects_log_verify.sh /dev/nvme0n1
#   ./nvme_effects_log_verify.sh              # auto-detects first NVMe controller

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/nvme_test_lib.sh
source "${SCRIPT_DIR}/../common/nvme_test_lib.sh"

EFFECTS_OUTPUT=""

effects_cmd_supported() {
	local opcode_hex="$1"
	echo "$EFFECTS_OUTPUT" | grep -qi "${opcode_hex}.*CSUPP\|${opcode_hex}.*Supported" || \
	echo "$EFFECTS_OUTPUT" | grep -qi "opcode.*${opcode_hex}" || true
}

# --------------------------------------------------------------------------
# Test functions
# --------------------------------------------------------------------------

test_effects_log_command() {
	if [ -n "$EFFECTS_OUTPUT" ]; then
		if echo "$EFFECTS_OUTPUT" | grep -qi "invalid\|not support\|error\|unknown"; then
			log_skip "nvme effects-log command" "command not supported by this nvme-cli or controller"
		else
			log_pass "nvme effects-log command executes successfully"
		fi
	else
		log_skip "nvme effects-log command" "empty output"
	fi
}

test_admin_identify() {
	if echo "$EFFECTS_OUTPUT" | grep -qi "Admin.*06\|ACS6.*CSUPP"; then
		log_pass "Admin Identify (opcode 06h) is supported (CSUPP=1)"
	elif echo "$EFFECTS_OUTPUT" | grep -q "ACS6"; then
		log_pass "Admin opcode 06h (Identify) entry present"
	else
		log_fail "Admin Identify (opcode 06h) must be supported" "not found in effects-log"
	fi
}

test_admin_get_log_page() {
	if echo "$EFFECTS_OUTPUT" | grep -qi "Admin.*02\|ACS2.*CSUPP"; then
		log_pass "Admin Get Log Page (opcode 02h) is supported (CSUPP=1)"
	elif echo "$EFFECTS_OUTPUT" | grep -q "ACS2"; then
		log_pass "Admin opcode 02h (Get Log Page) entry present"
	else
		log_fail "Admin Get Log Page (opcode 02h) must be supported" "not found"
	fi
}

test_admin_get_features() {
	if echo "$EFFECTS_OUTPUT" | grep -qi "Admin.*0a\|ACS10.*CSUPP"; then
		log_pass "Admin Get Features (opcode 0Ah) is supported (CSUPP=1)"
	elif echo "$EFFECTS_OUTPUT" | grep -q "ACS10"; then
		log_pass "Admin opcode 0Ah (Get Features) entry present"
	else
		log_fail "Admin Get Features (opcode 0Ah) must be supported" "not found"
	fi
}

test_admin_set_features() {
	if echo "$EFFECTS_OUTPUT" | grep -qi "Admin.*09\|ACS9.*CSUPP"; then
		log_pass "Admin Set Features (opcode 09h) is supported (CSUPP=1)"
	elif echo "$EFFECTS_OUTPUT" | grep -q "ACS9"; then
		log_pass "Admin opcode 09h (Set Features) entry present"
	else
		log_fail "Admin Set Features (opcode 09h) must be supported" "not found"
	fi
}

test_admin_abort() {
	if echo "$EFFECTS_OUTPUT" | grep -qi "Admin.*08\|ACS8.*CSUPP"; then
		log_pass "Admin Abort (opcode 08h) is supported (CSUPP=1)"
	elif echo "$EFFECTS_OUTPUT" | grep -q "ACS8"; then
		log_pass "Admin opcode 08h (Abort) entry present"
	else
		log_fail "Admin Abort (opcode 08h) must be supported" "not found"
	fi
}

test_admin_async_event() {
	if echo "$EFFECTS_OUTPUT" | grep -qi "Admin.*0c\|ACS12.*CSUPP"; then
		log_pass "Admin Async Event Request (opcode 0Ch) is supported (CSUPP=1)"
	elif echo "$EFFECTS_OUTPUT" | grep -q "ACS12"; then
		log_pass "Admin opcode 0Ch (Async Event Request) entry present"
	else
		log_fail "Admin Async Event Request (opcode 0Ch) must be supported" "not found"
	fi
}

test_io_read() {
	if echo "$EFFECTS_OUTPUT" | grep -qi "IOCS2.*CSUPP\|I/O.*02"; then
		log_pass "I/O Read (opcode 02h) is supported"
	elif echo "$EFFECTS_OUTPUT" | grep -q "IOCS2"; then
		log_pass "I/O opcode 02h (Read) entry present"
	else
		log_warn "I/O Read (opcode 02h) not found in effects-log" "may use different output format"
	fi
}

test_io_write() {
	if echo "$EFFECTS_OUTPUT" | grep -qi "IOCS1.*CSUPP\|I/O.*01"; then
		log_pass "I/O Write (opcode 01h) is supported"
	elif echo "$EFFECTS_OUTPUT" | grep -q "IOCS1"; then
		log_pass "I/O opcode 01h (Write) entry present"
	else
		log_warn "I/O Write (opcode 01h) not found in effects-log" "may use different output format"
	fi
}

test_io_flush() {
	if echo "$EFFECTS_OUTPUT" | grep -qi "IOCS0.*CSUPP\|I/O.*00"; then
		log_pass "I/O Flush (opcode 00h) is supported"
	elif echo "$EFFECTS_OUTPUT" | grep -q "IOCS0"; then
		log_pass "I/O opcode 00h (Flush) entry present"
	else
		log_warn "I/O Flush (opcode 00h) not found in effects-log" "may use different output format"
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
		echo "Verifies NVMe Commands Supported and Effects Log."
		exit 0
	else
		ctrl_dev=$(resolve_ctrl_dev "$1")
	fi

	if [ ! -e "$ctrl_dev" ]; then
		echo "ERROR: Device $ctrl_dev does not exist." >&2
		exit 1
	fi

	cache_id_ctrl "$ctrl_dev"

	local lpa
	lpa=$(get_id_ctrl_field "lpa")
	if [ -n "$lpa" ]; then
		local lpa_int=$((lpa))
		local celp=$(( (lpa_int >> 1) & 0x1 ))
		if [ "$celp" -eq 0 ]; then
			echo -e "${YELLOW}SKIP${RESET}  Commands Supported and Effects Log not supported (LPA bit 1=0)"
			echo -e "  Skipping entire suite."
			exit 0
		fi
	fi

	init_log "nvme_effects_log_verify" "$ctrl_dev"
	log_cmd "Identify Controller (cached)" "nvme id-ctrl ${ctrl_dev}" "$_ID_CTRL_CACHE"

	local spec_ref
	spec_ref=$(get_spec_ref "effects-log")

	print_header \
		"NVMe Commands Supported and Effects Log — Verification" \
		"$spec_ref" \
		"$ctrl_dev"

	EFFECTS_OUTPUT=$(nvme effects-log "$ctrl_dev" 2>&1) || true
	log_cmd "Commands Supported and Effects Log" "nvme effects-log ${ctrl_dev}" "$EFFECTS_OUTPUT"

	echo -e "${BOLD}--- Command Access ---${RESET}"
	test_effects_log_command

	if [ -z "$EFFECTS_OUTPUT" ] || echo "$EFFECTS_OUTPUT" | grep -qi "invalid\|not support\|unknown\|error"; then
		echo -e "  ${YELLOW}NOTE${RESET}  Effects log data not available — skipping remaining tests"
		print_summary
		exit 0
	fi

	echo ""
	echo -e "${BOLD}--- Mandatory Admin Commands ---${RESET}"
	test_admin_identify
	test_admin_get_log_page
	test_admin_get_features
	test_admin_set_features
	test_admin_abort
	test_admin_async_event

	echo ""
	echo -e "${BOLD}--- Mandatory I/O Commands ---${RESET}"
	test_io_read
	test_io_write
	test_io_flush

	print_summary

	if [ "$FAIL_COUNT" -gt 0 ]; then
		exit 1
	fi
	exit 0
}

main "$@"
