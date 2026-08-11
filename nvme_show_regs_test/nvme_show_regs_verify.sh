#!/bin/bash
# SPDX-License-Identifier: GPL-3.0+
# Copyright (C) 2025 Red Hat, Inc.
#
# NVMe Controller Registers verification
# Based on NVMe Base Specification — Controller Registers section
# Field names from nvme-cli upstream nvme-print-stdout.c
#
# Usage:
#   ./nvme_show_regs_verify.sh /dev/nvme0
#   ./nvme_show_regs_verify.sh /dev/nvme0n1
#   ./nvme_show_regs_verify.sh              # auto-detects first NVMe controller

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/nvme_test_lib.sh
source "${SCRIPT_DIR}/../common/nvme_test_lib.sh"

REGS_OUTPUT=""

regs_get_value() {
	echo "$REGS_OUTPUT" | grep "^${1}[[:space:]]" | awk -F': ' '{ print $2 }' | awk '{ print $1 }' || true
}

regs_get_human_line() {
	echo "$REGS_OUTPUT" | grep -i "$1" | head -1 || true
}

# --------------------------------------------------------------------------
# Test functions
# --------------------------------------------------------------------------

test_show_regs_command() {
	if [ -z "$REGS_OUTPUT" ]; then
		log_fail "nvme show-regs command executes successfully" "empty output"
	elif echo "$REGS_OUTPUT" | grep -qi "Invalid Command Opcode\|not support"; then
		log_skip "nvme show-regs command" "not supported by this controller"
	else
		log_pass "nvme show-regs command executes successfully"
	fi
}

test_csts_rdy() {
	local rdy_line
	rdy_line=$(regs_get_human_line "Controller Ready.*RDY")
	if [ -z "$rdy_line" ]; then
		local csts_val
		csts_val=$(regs_get_value "csts")
		if [ -n "$csts_val" ]; then
			local csts_int=$((csts_val))
			local rdy=$(( csts_int & 0x1 ))
			if [ "$rdy" -eq 1 ]; then
				log_pass "CSTS.RDY=1 (controller ready)"
			else
				log_fail "CSTS.RDY must be 1" "RDY=0 (controller not ready)"
			fi
		else
			log_skip "CSTS.RDY check" "could not read CSTS register"
		fi
		return
	fi
	if echo "$rdy_line" | grep -qi "Yes"; then
		log_pass "CSTS.RDY=1 (controller ready)"
	else
		log_fail "CSTS.RDY must be 1" "controller not ready"
	fi
}

test_csts_cfs() {
	local cfs_line
	cfs_line=$(regs_get_human_line "Controller Fatal Status.*CFS")
	if [ -z "$cfs_line" ]; then
		local csts_val
		csts_val=$(regs_get_value "csts")
		if [ -n "$csts_val" ]; then
			local csts_int=$((csts_val))
			local cfs=$(( (csts_int >> 1) & 0x1 ))
			if [ "$cfs" -eq 0 ]; then
				log_pass "CSTS.CFS=0 (no fatal status)"
			else
				log_fail "CSTS.CFS must be 0" "CFS=1 (fatal controller status!)"
			fi
		else
			log_skip "CSTS.CFS check" "could not read CSTS register"
		fi
		return
	fi
	if echo "$cfs_line" | grep -qi "False"; then
		log_pass "CSTS.CFS=0 (no fatal status)"
	else
		log_fail "CSTS.CFS must be 0" "fatal controller status detected"
	fi
}

test_csts_shst() {
	local shst_line
	shst_line=$(regs_get_human_line "Shutdown Status.*SHST")
	if [ -z "$shst_line" ]; then
		local csts_val
		csts_val=$(regs_get_value "csts")
		if [ -n "$csts_val" ]; then
			local csts_int=$((csts_val))
			local shst=$(( (csts_int >> 2) & 0x3 ))
			if [ "$shst" -eq 0 ]; then
				log_pass "CSTS.SHST=00b (normal operation)"
			else
				log_warn "CSTS.SHST not normal operation" "SHST=${shst}"
			fi
		else
			log_skip "CSTS.SHST check" "could not read CSTS register"
		fi
		return
	fi
	if echo "$shst_line" | grep -qi "Normal"; then
		log_pass "CSTS.SHST=00b (normal operation)"
	else
		log_warn "CSTS.SHST not normal operation" "$(echo "$shst_line" | sed 's/.*: //')"
	fi
}

test_cc_en() {
	local en_line
	en_line=$(regs_get_human_line "Enable.*EN")
	if [ -z "$en_line" ]; then
		local cc_val
		cc_val=$(regs_get_value "cc")
		if [ -n "$cc_val" ]; then
			local cc_int=$((cc_val))
			local en=$(( cc_int & 0x1 ))
			if [ "$en" -eq 1 ]; then
				log_pass "CC.EN=1 (controller enabled)"
			else
				log_fail "CC.EN must be 1" "EN=0 (controller disabled)"
			fi
		else
			log_skip "CC.EN check" "could not read CC register"
		fi
		return
	fi
	if echo "$en_line" | grep -qi "Yes\|Enabled\|Set"; then
		log_pass "CC.EN=1 (controller enabled)"
	else
		log_fail "CC.EN must be 1" "controller not enabled"
	fi
}

test_cap_mqes() {
	local cap_val
	cap_val=$(regs_get_value "cap")
	if [ -z "$cap_val" ]; then
		log_skip "CAP.MQES check" "could not read CAP register"
		return
	fi
	local cap_int=$((cap_val))
	local mqes=$(( cap_int & 0xFFFF ))
	local max_entries=$((mqes + 1))
	if [ "$max_entries" -gt 0 ]; then
		log_pass "CAP.MQES: max queue entries supported = ${max_entries}"
	else
		log_fail "CAP.MQES must be > 0" "got ${max_entries}"
	fi
}

test_vs_matches_id_ctrl() {
	local vs_val
	vs_val=$(regs_get_value "vs")
	if [ -z "$vs_val" ]; then
		log_skip "VS register vs id-ctrl VER" "could not read VS register"
		return
	fi
	local ver_from_ctrl
	ver_from_ctrl=$(get_id_ctrl_field "ver")
	if [ -z "$ver_from_ctrl" ]; then
		log_skip "VS register vs id-ctrl VER" "could not read VER from id-ctrl"
		return
	fi
	local vs_int=$((vs_val))
	local ver_int=$((ver_from_ctrl))
	if [ "$vs_int" -eq "$ver_int" ]; then
		log_pass "VS register (0x$(printf '%08x' "$vs_int")) matches id-ctrl VER"
	else
		log_warn "VS register mismatch with id-ctrl VER" "VS=0x$(printf '%08x' "$vs_int") VER=0x$(printf '%08x' "$ver_int")"
	fi
}

test_cap_css() {
	local cap_val
	cap_val=$(regs_get_value "cap")
	if [ -z "$cap_val" ]; then
		log_skip "CAP.CSS check" "could not read CAP register"
		return
	fi
	local cap_int=$((cap_val))
	local css=$(( (cap_int >> 37) & 0xFF ))
	local nvm_css=$(( css & 0x1 ))
	if [ "$nvm_css" -eq 1 ]; then
		log_pass "CAP.CSS: NVM command set supported (CSS=0x$(printf '%02x' "$css"))"
	else
		log_pass "CAP.CSS: command set support = 0x$(printf '%02x' "$css")"
	fi
}

test_cap_to() {
	local cap_val
	cap_val=$(regs_get_value "cap")
	if [ -z "$cap_val" ]; then
		log_skip "CAP.TO (Timeout) check" "could not read CAP register"
		return
	fi
	local cap_int=$((cap_val))
	local to=$(( (cap_int >> 24) & 0xFF ))
	if [ "$to" -gt 0 ]; then
		local timeout_ms=$((to * 500))
		log_pass "CAP.TO: worst-case ready timeout = ${to} (${timeout_ms} ms)"
	else
		log_fail "CAP.TO must be non-zero" "TO=0 (spec violation: controller shall set this field)"
	fi
}

test_cap_crms() {
	if ! ver_at_least 2 0; then
		log_skip "CAP.CRMS (Controller Ready Modes)" "requires NVMe 2.0+"
		return
	fi
	local cap_val
	cap_val=$(regs_get_value "cap")
	if [ -z "$cap_val" ]; then
		log_skip "CAP.CRMS check" "could not read CAP register"
		return
	fi
	local cap_int=$((cap_val))
	local crwms=$(( (cap_int >> 58) & 0x1 ))
	local crims=$(( (cap_int >> 59) & 0x1 ))
	if [ "$crwms" -eq 1 ]; then
		log_pass "CAP.CRMS: CRWMS=1 (Controller Ready With Media supported), CRIMS=${crims}"
	else
		log_warn "CAP.CRMS" "CRWMS=0 (spec 2.0+ says shall be 1)"
	fi
}

test_crto() {
	if ! ver_at_least 2 0; then
		log_skip "CRTO (Controller Ready Timeouts)" "requires NVMe 2.0+"
		return
	fi
	local crto_val
	crto_val=$(regs_get_value "crto")
	if [ -z "$crto_val" ]; then
		local crto_line
		crto_line=$(regs_get_human_line "CRTO\|Controller Ready Timeout")
		if [ -z "$crto_line" ]; then
			log_skip "CRTO check" "CRTO register not found in show-regs output"
			return
		fi
		crto_val=$(echo "$crto_line" | grep -oP '0x[0-9a-fA-F]+' | head -1 || true)
		if [ -z "$crto_val" ]; then
			log_skip "CRTO check" "could not parse CRTO value"
			return
		fi
	fi
	local crto_int=$((crto_val))
	local crwmt=$(( crto_int & 0xFFFF ))
	local crimt=$(( (crto_int >> 16) & 0xFFFF ))
	local crwmt_ms=$((crwmt * 500))
	local crimt_ms=$((crimt * 500))
	if [ "$crwmt" -gt 0 ]; then
		log_pass "CRTO: CRWMT=${crwmt} (${crwmt_ms} ms), CRIMT=${crimt} (${crimt_ms} ms)"
	else
		log_warn "CRTO" "CRWMT=0 (expected non-zero for Controller Ready With Media timeout)"
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
		echo "Verifies NVMe Controller Registers per NVMe Base Spec."
		exit 0
	else
		ctrl_dev=$(resolve_ctrl_dev "$1")
	fi

	if [ ! -e "$ctrl_dev" ]; then
		echo "ERROR: Device $ctrl_dev does not exist." >&2
		exit 1
	fi

	cache_id_ctrl "$ctrl_dev"
	init_log "nvme_show_regs_verify" "$ctrl_dev"
	log_cmd "Identify Controller (cached)" "nvme id-ctrl ${ctrl_dev}" "$_ID_CTRL_CACHE"

	local spec_ref
	spec_ref=$(get_spec_ref "show-regs")

	print_header \
		"NVMe Controller Registers — Verification" \
		"$spec_ref" \
		"$ctrl_dev"

	REGS_OUTPUT=$(nvme show-regs "$ctrl_dev" -H 2>&1) || true
	if [ -z "$REGS_OUTPUT" ] || echo "$REGS_OUTPUT" | grep -qi "Invalid Command Opcode\|not support"; then
		REGS_OUTPUT=$(nvme show-regs "$ctrl_dev" 2>&1) || true
	fi
	log_cmd "Controller Registers" "nvme show-regs ${ctrl_dev} -H" "$REGS_OUTPUT"

	echo -e "${BOLD}--- Register Access ---${RESET}"
	test_show_regs_command

	if echo "$REGS_OUTPUT" | grep -qi "Invalid Command Opcode\|not support\|error"; then
		echo -e "  ${YELLOW}NOTE${RESET}  Register access not supported on this controller — skipping remaining tests"
		print_summary
		exit 0
	fi

	echo ""
	echo -e "${BOLD}--- Controller Status (CSTS) ---${RESET}"
	test_csts_rdy
	test_csts_cfs
	test_csts_shst

	echo ""
	echo -e "${BOLD}--- Controller Configuration (CC) ---${RESET}"
	test_cc_en

	echo ""
	echo -e "${BOLD}--- Controller Capabilities (CAP) ---${RESET}"
	test_cap_mqes
	test_cap_css
	test_cap_to
	test_cap_crms

	echo ""
	echo -e "${BOLD}--- Controller Ready Timeouts (NVMe 2.0+) ---${RESET}"
	test_crto

	echo ""
	echo -e "${BOLD}--- Version Register ---${RESET}"
	test_vs_matches_id_ctrl

	print_summary

	if [ "$FAIL_COUNT" -gt 0 ]; then
		exit 1
	fi
	exit 0
}

main "$@"
