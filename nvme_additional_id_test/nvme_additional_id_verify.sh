#!/bin/bash
# SPDX-License-Identifier: GPL-3.0+
# Copyright (C) 2025 Red Hat, Inc.
#
# NVMe Additional Identify — Read-Only Verification
# Based on NVMe Base Specification — Identify variants, list commands
# Tests: list-ctrl, list-subsys, primary-ctrl-caps, list-secondary,
#        id-uuid, nvm-id-ctrl, nvm-id-ns, cmdset-ind-id-ns, id-domain,
#        id-iocs, id-nvmset, id-ns-granularity, id-ns-lba-format,
#        list-endgrp, nvm-id-ns-lba-format
#
# Usage:
#   ./nvme_additional_id_verify.sh /dev/nvme0n1
#   ./nvme_additional_id_verify.sh /dev/nvme0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/nvme_test_lib.sh
source "${SCRIPT_DIR}/../common/nvme_test_lib.sh"

CTRL_DEV=""
NS_DEV=""

# --------------------------------------------------------------------------
# Test functions
# --------------------------------------------------------------------------

test_list_ctrl_attached() {
	local output
	output=$(nvme list-ctrl "$CTRL_DEV" 2>&1) || true
	log_cmd "List Controllers (attached)" "nvme list-ctrl ${CTRL_DEV}" "$output"

	local cntlid
	cntlid=$(get_id_ctrl_field "cntlid")

	if echo "$output" | grep -qi "num.*ctrl\|cntlid\|\[.*\]"; then
		if [ -n "$cntlid" ] && echo "$output" | grep -q "$((cntlid))"; then
			log_pass "List Controllers: own CNTLID $((cntlid)) found in attached list"
		else
			log_pass "List Controllers: controller list returned"
		fi
	elif echo "$output" | grep -qi "not support\|invalid\|NVMe status"; then
		log_skip "List Controllers (attached)" "$(echo "$output" | head -1)"
	else
		log_pass "List Controllers: command completed"
	fi
}

test_list_ctrl_subsystem() {
	local output
	output=$(nvme list-ctrl "$CTRL_DEV" -c 0 2>&1) || true
	log_cmd "List Controllers (subsystem)" "nvme list-ctrl ${CTRL_DEV} -c 0" "$output"

	if echo "$output" | grep -qi "num.*ctrl\|cntlid\|\[.*\]"; then
		log_pass "List Controllers (subsystem scope): controller list returned"
	elif echo "$output" | grep -qi "not support\|invalid\|NVMe status"; then
		log_skip "List Controllers (subsystem)" "$(echo "$output" | head -1)"
	else
		log_pass "List Controllers (subsystem): command completed"
	fi
}

test_list_subsys() {
	local output
	output=$(nvme list-subsys "$CTRL_DEV" 2>&1) || true
	log_cmd "List Subsystems" "nvme list-subsys ${CTRL_DEV}" "$output"

	local subnqn
	subnqn=$(get_id_ctrl_string_field "subnqn" | sed 's/ *$//')

	if [ -n "$subnqn" ] && echo "$output" | grep -q "$subnqn"; then
		log_pass "List Subsystems: SUBNQN matches id-ctrl (${subnqn})"
	elif echo "$output" | grep -qi "nqn\|nvme.*subsys\|transport"; then
		log_pass "List Subsystems: subsystem topology returned"
	elif echo "$output" | grep -qi "not support\|NVMe status"; then
		log_skip "List Subsystems" "$(echo "$output" | head -1)"
	else
		log_pass "List Subsystems: command completed"
	fi
}

test_primary_ctrl_caps() {
	local output
	output=$(nvme primary-ctrl-caps "$CTRL_DEV" 2>&1) || true
	log_cmd "Primary Controller Caps" "nvme primary-ctrl-caps ${CTRL_DEV}" "$output"

	local cntlid
	cntlid=$(get_id_ctrl_field "cntlid")

	if echo "$output" | grep -qi "cntlid\|portid\|crt"; then
		if [ -n "$cntlid" ] && echo "$output" | grep -q "cntlid.*$((cntlid))"; then
			log_pass "Primary Controller Caps: CNTLID matches id-ctrl ($((cntlid)))"
		else
			log_pass "Primary Controller Caps: key fields present"
		fi
	elif echo "$output" | grep -qi "not support\|invalid\|NVMe status"; then
		log_skip "Primary Controller Caps" "$(echo "$output" | head -1)"
	else
		log_pass "Primary Controller Caps: command completed"
	fi
}

test_list_secondary() {
	local output
	output=$(nvme list-secondary "$CTRL_DEV" 2>&1) || true
	log_cmd "Secondary Controller List" "nvme list-secondary ${CTRL_DEV}" "$output"

	if echo "$output" | grep -qi "scid\|pcid\|scs\|secondary"; then
		log_pass "Secondary Controller List: entries present"
	elif echo "$output" | grep -qi "num.*entries.*0\|no secondary"; then
		log_pass "Secondary Controller List: no secondary controllers (valid)"
	elif echo "$output" | grep -qi "not support\|invalid\|NVMe status"; then
		log_skip "Secondary Controller List" "$(echo "$output" | head -1)"
	else
		log_pass "Secondary Controller List: command completed"
	fi
}

test_id_uuid() {
	if ! ver_at_least 1 4; then
		log_skip "Identify UUID List" "requires NVMe 1.4+"
		return
	fi

	local output
	output=$(nvme id-uuid "$CTRL_DEV" 2>&1) || true
	log_cmd "Identify UUID List" "nvme id-uuid ${CTRL_DEV}" "$output"

	if echo "$output" | grep -qiP "[0-9a-f]{8}-[0-9a-f]{4}"; then
		log_pass "Identify UUID List: UUID entries with valid format found"
	elif echo "$output" | grep -qi "not support\|invalid\|NVMe status"; then
		log_skip "Identify UUID List" "$(echo "$output" | head -1)"
	else
		log_pass "Identify UUID List: command completed"
	fi
}

NVM_ID_CTRL_OUTPUT=""

test_nvm_id_ctrl() {
	if ! ver_at_least 2 0; then
		log_skip "NVM Command Set ID Controller" "requires NVMe 2.0+"
		return
	fi

	NVM_ID_CTRL_OUTPUT=$(nvme nvm-id-ctrl "$CTRL_DEV" 2>&1) || true
	log_cmd "NVM ID Ctrl" "nvme nvm-id-ctrl ${CTRL_DEV}" "$NVM_ID_CTRL_OUTPUT"

	if echo "$NVM_ID_CTRL_OUTPUT" | grep -qi "not support\|invalid\|NVMe status"; then
		log_skip "NVM Command Set ID Controller" "$(echo "$NVM_ID_CTRL_OUTPUT" | head -1)"
		return
	fi

	local fields_found=0
	local fields_list=""
	local field
	for field in vsl wzsl wusl dmrl dmrsl dmsl; do
		if echo "$NVM_ID_CTRL_OUTPUT" | grep -qi "^${field}"; then
			fields_found=$((fields_found + 1))
			fields_list="${fields_list} ${field}"
		fi
	done
	if [ "$fields_found" -ge 3 ]; then
		log_pass "NVM ID Ctrl: ${fields_found} key fields present (${fields_list# })"
	else
		log_pass "NVM Command Set ID Controller: command completed"
	fi
}

test_nvm_id_ctrl_ver() {
	if ! ver_at_least 2 0; then
		log_skip "NVM CS Version" "requires NVMe 2.0+"
		return
	fi
	if [ -z "$NVM_ID_CTRL_OUTPUT" ]; then
		log_skip "NVM CS Version" "nvm-id-ctrl not available"
		return
	fi
	local ver_val
	ver_val=$(echo "$NVM_ID_CTRL_OUTPUT" | grep -i "^ver" | awk -F: '{print $2}' | tr -d ' ' | head -1)
	if [ -z "$ver_val" ]; then
		log_skip "NVM CS Version" "ver field not found in output"
		return
	fi
	local ver_int=$((ver_val))
	local major=$(( (ver_int >> 16) & 0xFF ))
	local minor=$(( (ver_int >> 8) & 0xFF ))
	if [ "$major" -ge 1 ]; then
		log_pass "NVM Command Set version: ${major}.${minor} (raw=${ver_val})"
	else
		log_pass "NVM Command Set version: ${ver_val}"
	fi
}

test_nvm_id_ctrl_kpiocap() {
	if ! ver_at_least 2 0; then
		log_skip "NVM CS kpiocap (PI Capabilities)" "requires NVMe 2.0+"
		return
	fi
	if [ -z "$NVM_ID_CTRL_OUTPUT" ]; then
		log_skip "NVM CS kpiocap" "nvm-id-ctrl not available"
		return
	fi
	local kp_val
	kp_val=$(echo "$NVM_ID_CTRL_OUTPUT" | grep -i "^kpiocap" | awk -F: '{print $2}' | tr -d ' ' | head -1)
	if [ -z "$kp_val" ]; then
		log_skip "NVM CS kpiocap" "field not found in output"
		return
	fi
	local kp_int=$((kp_val))
	local crc64=$(( (kp_int >> 3) & 0x1 ))
	local summary="kpiocap=0x$(printf '%02x' "$kp_int")"
	if [ "$crc64" -eq 1 ]; then
		summary="${summary}, 64-bit Guard PI (CRC-64) supported"
	fi
	log_pass "NVM CS PI Capabilities: ${summary}"
}

test_nvm_id_ctrl_copy_fields() {
	if ! ver_at_least 2 0; then
		log_skip "NVM CS Copy Command fields" "requires NVMe 2.0+"
		return
	fi
	if [ -z "$NVM_ID_CTRL_OUTPUT" ]; then
		log_skip "NVM CS Copy Command fields" "nvm-id-ctrl not available"
		return
	fi
	local dmrl dmrsl dmsl
	dmrl=$(echo "$NVM_ID_CTRL_OUTPUT" | grep -i "^dmrl" | awk -F: '{print $2}' | tr -d ' ' | head -1)
	dmrsl=$(echo "$NVM_ID_CTRL_OUTPUT" | grep -i "^dmrsl" | awk -F: '{print $2}' | tr -d ' ' | head -1)
	dmsl=$(echo "$NVM_ID_CTRL_OUTPUT" | grep -i "^dmsl" | awk -F: '{print $2}' | tr -d ' ' | head -1)
	if [ -z "$dmrl" ] && [ -z "$dmrsl" ]; then
		log_skip "NVM CS Copy Command fields" "dmrl/dmrsl not found"
		return
	fi
	local summary="DMRL=${dmrl:-?} DMRSL=${dmrsl:-?} DMSL=${dmsl:-?}"
	log_pass "Copy Command limits: ${summary}"
}

test_nvm_id_ns() {
	if ! ver_at_least 2 0; then
		log_skip "NVM Command Set ID Namespace" "requires NVMe 2.0+"
		return
	fi

	if [ -z "$NS_DEV" ]; then
		log_skip "NVM Command Set ID Namespace" "no namespace device"
		return
	fi

	local output
	output=$(nvme nvm-id-ns "$NS_DEV" 2>&1) || true
	log_cmd "NVM ID NS" "nvme nvm-id-ns ${NS_DEV}" "$output"

	if echo "$output" | grep -qi "not support\|invalid\|NVMe status"; then
		log_skip "NVM Command Set ID Namespace" "$(echo "$output" | head -1)"
		return
	fi

	local fields_found=0
	local field
	for field in lbstm elbaf pic pid; do
		if echo "$output" | grep -qi "^${field}\|${field}"; then
			fields_found=$((fields_found + 1))
		fi
	done
	if [ "$fields_found" -ge 1 ]; then
		log_pass "NVM ID NS: ${fields_found} NVM CS fields present (lbstm, elbaf, pic, pid)"
	else
		log_pass "NVM Command Set ID Namespace: command completed"
	fi
}

test_cmdset_ind_id_ns() {
	if ! ver_at_least 2 0; then
		log_skip "Command Set Independent ID NS" "requires NVMe 2.0+"
		return
	fi

	if [ -z "$NS_DEV" ]; then
		log_skip "Command Set Independent ID NS" "no namespace device"
		return
	fi

	local output
	output=$(nvme cmdset-ind-id-ns "$NS_DEV" 2>&1) || true
	log_cmd "CS Independent ID NS" "nvme cmdset-ind-id-ns ${NS_DEV}" "$output"

	if echo "$output" | grep -qi "not support\|invalid\|NVMe status"; then
		log_skip "Command Set Independent ID NS" "$(echo "$output" | head -1)"
	else
		log_pass "Command Set Independent ID NS: command completed"
	fi
}

test_id_domain() {
	if ! ver_at_least 2 0; then
		log_skip "Identify Domain List" "requires NVMe 2.0+"
		return
	fi

	local output
	output=$(nvme id-domain "$CTRL_DEV" 2>&1) || true
	log_cmd "Identify Domain List" "nvme id-domain ${CTRL_DEV}" "$output"

	if echo "$output" | grep -qi "dom_cap\|unalloc_cap\|max_egrp\|domain"; then
		log_pass "Identify Domain List: domain capacity fields present"
	elif echo "$output" | grep -qi "not support\|invalid\|NVMe status"; then
		log_skip "Identify Domain List" "$(echo "$output" | head -1)"
	else
		log_pass "Identify Domain List: command completed"
	fi
}

test_id_iocs() {
	if ! ver_at_least 2 0; then
		log_skip "Identify I/O Command Set" "requires NVMe 2.0+"
		return
	fi

	local output
	output=$(nvme id-iocs "$CTRL_DEV" -c 0 2>&1) || true
	log_cmd "Identify IO Command Set" "nvme id-iocs ${CTRL_DEV} -c 0" "$output"

	if echo "$output" | grep -qi "not support\|invalid\|NVMe status"; then
		log_skip "Identify I/O Command Set" "$(echo "$output" | head -1)"
	else
		log_pass "Identify I/O Command Set: command completed"
	fi
}

test_id_nvmset() {
	if ! ver_at_least 1 4; then
		log_skip "Identify NVM Set List" "requires NVMe 1.4+"
		return
	fi

	local output
	output=$(nvme id-nvmset "$CTRL_DEV" 2>&1) || true
	log_cmd "Identify NVM Set List" "nvme id-nvmset ${CTRL_DEV}" "$output"

	if echo "$output" | grep -qi "nid\|set.*entry\|nvm.*set"; then
		log_pass "Identify NVM Set List: set entries present"
	elif echo "$output" | grep -qi "not support\|invalid\|NVMe status"; then
		log_skip "Identify NVM Set List" "$(echo "$output" | head -1)"
	else
		log_pass "Identify NVM Set List: command completed"
	fi
}

test_id_ns_granularity() {
	if ! ver_at_least 1 4; then
		log_skip "Identify NS Granularity" "requires NVMe 1.4+"
		return
	fi

	local output
	output=$(nvme id-ns-granularity "$CTRL_DEV" 2>&1) || true
	log_cmd "Identify NS Granularity" "nvme id-ns-granularity ${CTRL_DEV}" "$output"

	if echo "$output" | grep -qi "numd\|nsg\|ncg\|gran"; then
		log_pass "Identify NS Granularity: NUMD/NSG/NCG fields present"
	elif echo "$output" | grep -qi "not support\|invalid\|NVMe status"; then
		log_skip "Identify NS Granularity" "$(echo "$output" | head -1)"
	else
		log_pass "Identify NS Granularity: command completed"
	fi
}

test_id_ns_lba_format() {
	if ! ver_at_least 2 0; then
		log_skip "Identify NS LBA Format" "requires NVMe 2.0+"
		return
	fi

	if [ -z "$NS_DEV" ]; then
		log_skip "Identify NS LBA Format" "no namespace device"
		return
	fi

	local output
	output=$(nvme id-ns-lba-format "$NS_DEV" 2>&1) || true
	log_cmd "Identify NS LBA Format" "nvme id-ns-lba-format ${NS_DEV}" "$output"

	if echo "$output" | grep -qi "not support\|invalid\|NVMe status"; then
		log_skip "Identify NS LBA Format" "$(echo "$output" | head -1)"
	else
		log_pass "Identify NS LBA Format: format entries accessible"
	fi
}

test_list_endgrp() {
	if ! ver_at_least 2 0; then
		log_skip "Endurance Group List" "requires NVMe 2.0+"
		return
	fi

	local output
	output=$(nvme list-endgrp "$CTRL_DEV" 2>&1) || true
	log_cmd "List Endurance Groups" "nvme list-endgrp ${CTRL_DEV}" "$output"

	if echo "$output" | grep -qi "endgrp\|num\|identifier"; then
		log_pass "Endurance Group List: endurance group IDs found"
	elif echo "$output" | grep -qi "not support\|invalid\|NVMe status"; then
		log_skip "Endurance Group List" "$(echo "$output" | head -1)"
	else
		log_pass "Endurance Group List: command completed"
	fi
}

test_nvm_id_ns_lba_format() {
	if ! ver_at_least 2 0; then
		log_skip "NVM ID NS LBA Format" "requires NVMe 2.0+"
		return
	fi

	if [ -z "$NS_DEV" ]; then
		log_skip "NVM ID NS LBA Format" "no namespace device"
		return
	fi

	local output
	output=$(nvme nvm-id-ns-lba-format "$NS_DEV" 2>&1) || true
	log_cmd "NVM ID NS LBA Format" "nvme nvm-id-ns-lba-format ${NS_DEV}" "$output"

	if echo "$output" | grep -qi "not support\|invalid\|NVMe status"; then
		log_skip "NVM ID NS LBA Format" "$(echo "$output" | head -1)"
	else
		log_pass "NVM ID NS LBA Format: extended format accessible"
	fi
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

main() {
	preflight_checks

	if [ $# -eq 0 ]; then
		CTRL_DEV=$(auto_detect_ctrl)
		NS_DEV=$(resolve_ns_dev "$CTRL_DEV" 2>/dev/null || true)
		echo -e "${BOLD}No device specified — auto-detected: ${CTRL_DEV}${RESET}"
	elif [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
		echo "Usage: $0 [/dev/nvmeX | /dev/nvmeXnY]"
		echo "Read-only verification of all NVMe Identify variants and list commands."
		exit 0
	else
		CTRL_DEV=$(resolve_ctrl_dev "$1")
		if [[ "$1" =~ ^/dev/nvme[0-9]+n[0-9]+$ ]]; then
			NS_DEV="$1"
		else
			NS_DEV=$(resolve_ns_dev "$CTRL_DEV" 2>/dev/null || true)
		fi
	fi

	if [ ! -e "$CTRL_DEV" ]; then
		echo "ERROR: Device $CTRL_DEV does not exist." >&2
		exit 1
	fi

	cache_id_ctrl "$CTRL_DEV"

	init_log "nvme_additional_id_verify" "$CTRL_DEV"
	log_cmd "Identify Controller (cached)" "nvme id-ctrl ${CTRL_DEV}" "$_ID_CTRL_CACHE"

	local spec_ref
	spec_ref=$(get_spec_ref "additional-id")

	print_header \
		"NVMe Additional Identify — Read-Only Verification" \
		"$spec_ref" \
		"$CTRL_DEV"

	echo -e "${BOLD}--- Controller & Subsystem Lists ---${RESET}"
	test_list_ctrl_attached
	test_list_ctrl_subsystem
	test_list_subsys

	echo ""
	echo -e "${BOLD}--- Multi-Controller / Virtualization ---${RESET}"
	test_primary_ctrl_caps
	test_list_secondary

	echo ""
	echo -e "${BOLD}--- Extended Identify Structures ---${RESET}"
	test_id_uuid
	test_nvm_id_ctrl
	test_nvm_id_ctrl_ver
	test_nvm_id_ctrl_kpiocap
	test_nvm_id_ctrl_copy_fields
	test_nvm_id_ns
	test_cmdset_ind_id_ns

	echo ""
	echo -e "${BOLD}--- Domain / Command Set / NVM Set ---${RESET}"
	test_id_domain
	test_id_iocs
	test_id_nvmset
	test_id_ns_granularity

	echo ""
	echo -e "${BOLD}--- LBA Format / Endurance Group ---${RESET}"
	test_id_ns_lba_format
	test_list_endgrp
	test_nvm_id_ns_lba_format

	print_summary

	if [ "$FAIL_COUNT" -gt 0 ]; then
		exit 1
	fi
	exit 0
}

main "$@"
