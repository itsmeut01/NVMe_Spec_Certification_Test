#!/bin/bash
# SPDX-License-Identifier: GPL-3.0+
# Copyright (C) 2025 Red Hat, Inc.
#
# NVMe Namespace Identification Descriptors verification
# Based on NVMe Base Specification — Identify Namespace Identification Descriptor list
# Field names from nvme-cli upstream nvme-print-stdout.c
#
# Usage:
#   ./nvme_ns_descs_verify.sh /dev/nvme0
#   ./nvme_ns_descs_verify.sh /dev/nvme0n1
#   ./nvme_ns_descs_verify.sh              # auto-detects first NVMe controller

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/nvme_test_lib.sh
source "${SCRIPT_DIR}/../common/nvme_test_lib.sh"

NS_DESCS_OUTPUT=""
NS_DEV=""

# --------------------------------------------------------------------------
# Test functions
# --------------------------------------------------------------------------

test_ns_descs_command() {
	if [ -n "$NS_DESCS_OUTPUT" ]; then
		if echo "$NS_DESCS_OUTPUT" | grep -qi "invalid\|not support\|unknown opcode"; then
			log_skip "nvme ns-id-desc command" "command not supported by this nvme-cli or controller"
		else
			log_pass "nvme ns-id-desc command executes successfully"
		fi
	else
		log_fail "nvme ns-id-desc command executes successfully" "empty output"
	fi
}

test_eui64_present() {
	if echo "$NS_DESCS_OUTPUT" | grep -qi "eui64"; then
		local eui64_val
		eui64_val=$(echo "$NS_DESCS_OUTPUT" | grep -i "eui64" | head -1 | grep -oP '[0-9a-fA-F]{16}' || true)
		if [ -n "$eui64_val" ]; then
			log_pass "EUI-64 descriptor present: ${eui64_val}"
		else
			log_pass "EUI-64 descriptor present"
		fi
	else
		log_pass "EUI-64 descriptor not present (optional)"
	fi
}

test_nguid_present() {
	if echo "$NS_DESCS_OUTPUT" | grep -qi "nguid"; then
		local nguid_val
		nguid_val=$(echo "$NS_DESCS_OUTPUT" | grep -i "nguid" | head -1 | grep -oP '[0-9a-fA-F]{32}' || true)
		if [ -n "$nguid_val" ]; then
			log_pass "NGUID descriptor present: ${nguid_val}"
		else
			log_pass "NGUID descriptor present"
		fi
	else
		log_pass "NGUID descriptor not present (optional)"
	fi
}

test_uuid_present() {
	if echo "$NS_DESCS_OUTPUT" | grep -qi "uuid"; then
		local uuid_val
		uuid_val=$(echo "$NS_DESCS_OUTPUT" | grep -i "uuid" | head -1 | grep -oP '[0-9a-fA-F-]{36}' || true)
		if [ -n "$uuid_val" ]; then
			log_pass "UUID descriptor present: ${uuid_val}"
		else
			log_pass "UUID descriptor present"
		fi
	else
		log_pass "UUID descriptor not present (optional)"
	fi
}

test_at_least_one_id() {
	local has_eui64=0
	local has_nguid=0
	local has_uuid=0
	if echo "$NS_DESCS_OUTPUT" | grep -qi "eui64"; then
		has_eui64=1
	fi
	if echo "$NS_DESCS_OUTPUT" | grep -qi "nguid"; then
		has_nguid=1
	fi
	if echo "$NS_DESCS_OUTPUT" | grep -qi "uuid"; then
		has_uuid=1
	fi

	local nonzero=0
	if [ "$has_eui64" -eq 1 ]; then
		local val
		val=$(echo "$NS_DESCS_OUTPUT" | grep -i "eui64" | head -1 | grep -oP '[0-9a-fA-F]{16}' || true)
		if [ -n "$val" ] && [ "$val" != "0000000000000000" ]; then
			nonzero=1
		fi
	fi
	if [ "$has_nguid" -eq 1 ]; then
		local val
		val=$(echo "$NS_DESCS_OUTPUT" | grep -i "nguid" | head -1 | grep -oP '[0-9a-fA-F]{32}' || true)
		if [ -n "$val" ] && [ "$val" != "00000000000000000000000000000000" ]; then
			nonzero=1
		fi
	fi
	if [ "$has_uuid" -eq 1 ]; then
		local val
		val=$(echo "$NS_DESCS_OUTPUT" | grep -i "uuid" | head -1 | grep -oP '[0-9a-fA-F-]{36}' || true)
		if [ -n "$val" ] && [ "$val" != "00000000-0000-0000-0000-000000000000" ]; then
			nonzero=1
		fi
	fi

	if [ "$nonzero" -eq 1 ]; then
		log_pass "At least one non-zero namespace identifier present"
	else
		log_warn "No non-zero namespace identifier found" "all EUI64/NGUID/UUID are zero or absent"
	fi
}

test_csi_nvm() {
	if ! ver_at_least 2 0; then
		log_skip "CSI descriptor (NVM command set)" "requires NVMe 2.0+"
		return
	fi
	if echo "$NS_DESCS_OUTPUT" | grep -qi "csi"; then
		local csi_val
		csi_val=$(echo "$NS_DESCS_OUTPUT" | grep -i "csi" | head -1 | grep -oP '0x[0-9a-fA-F]+' || true)
		if [ -n "$csi_val" ]; then
			local csi_int=$((csi_val))
			if [ "$csi_int" -eq 0 ]; then
				log_pass "CSI descriptor: NVM Command Set (CSI=0)"
			elif [ "$csi_int" -eq 2 ]; then
				log_pass "CSI descriptor: Zoned Namespace Command Set (CSI=2)"
			elif [ "$csi_int" -eq 3 ]; then
				log_pass "CSI descriptor: Key Value Command Set (CSI=3)"
			else
				log_pass "CSI descriptor: command set index = ${csi_int}"
			fi
		else
			log_pass "CSI descriptor present (value could not be parsed)"
		fi
	else
		log_pass "CSI descriptor not present (optional for NVM command set)"
	fi
}

test_descriptor_lengths() {
	local issues=0
	if echo "$NS_DESCS_OUTPUT" | grep -qi "eui64"; then
		local len
		len=$(echo "$NS_DESCS_OUTPUT" | grep -i "eui64" | head -1 | grep -oiP 'len[[:space:]:=]*\K[0-9]+' || true)
		if [ -n "$len" ] && [ "$len" -ne 8 ]; then
			issues=$((issues + 1))
		fi
	fi
	if echo "$NS_DESCS_OUTPUT" | grep -qi "nguid"; then
		local len
		len=$(echo "$NS_DESCS_OUTPUT" | grep -i "nguid" | head -1 | grep -oiP 'len[[:space:]:=]*\K[0-9]+' || true)
		if [ -n "$len" ] && [ "$len" -ne 16 ]; then
			issues=$((issues + 1))
		fi
	fi
	if echo "$NS_DESCS_OUTPUT" | grep -qi "uuid"; then
		local len
		len=$(echo "$NS_DESCS_OUTPUT" | grep -i "uuid" | head -1 | grep -oiP 'len[[:space:]:=]*\K[0-9]+' || true)
		if [ -n "$len" ] && [ "$len" -ne 16 ]; then
			issues=$((issues + 1))
		fi
	fi
	if [ "$issues" -eq 0 ]; then
		log_pass "Descriptor lengths correct (EUI64=8, NGUID=16, UUID=16)"
	else
		log_fail "Descriptor length validation" "${issues} descriptor(s) with incorrect length"
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
		echo "Verifies NVMe Namespace Identification Descriptors per NVMe Base Spec."
		exit 0
	else
		ctrl_dev=$(resolve_ctrl_dev "$1")
	fi

	if [ ! -e "$ctrl_dev" ]; then
		echo "ERROR: Device $ctrl_dev does not exist." >&2
		exit 1
	fi

	cache_id_ctrl "$ctrl_dev"

	# ns-descs needs a namespace device
	if echo "$ctrl_dev" | grep -qP 'nvme\d+$'; then
		NS_DEV="${ctrl_dev}n1"
	else
		NS_DEV="$ctrl_dev"
	fi

	if [ ! -e "$NS_DEV" ]; then
		echo "ERROR: Namespace device $NS_DEV does not exist." >&2
		exit 1
	fi

	init_log "nvme_ns_descs_verify" "$ctrl_dev"
	log_cmd "Identify Controller (cached)" "nvme id-ctrl ${ctrl_dev}" "$_ID_CTRL_CACHE"

	local spec_ref
	spec_ref=$(get_spec_ref "ns-descs")

	print_header \
		"NVMe Namespace Identification Descriptors — Verification" \
		"$spec_ref" \
		"$NS_DEV"

	NS_DESCS_OUTPUT=$(nvme ns-descs "$NS_DEV" 2>&1) || true
	log_cmd "Namespace ID Descriptors" "nvme ns-descs ${NS_DEV}" "$NS_DESCS_OUTPUT"

	echo -e "${BOLD}--- Command Access ---${RESET}"
	test_ns_descs_command

	echo ""
	echo -e "${BOLD}--- Descriptor Presence ---${RESET}"
	test_eui64_present
	test_nguid_present
	test_uuid_present

	echo ""
	echo -e "${BOLD}--- Cross-Validation ---${RESET}"
	test_at_least_one_id
	test_csi_nvm

	echo ""
	echo -e "${BOLD}--- Descriptor Integrity ---${RESET}"
	test_descriptor_lengths

	print_summary

	if [ "$FAIL_COUNT" -gt 0 ]; then
		exit 1
	fi
	exit 0
}

main "$@"
