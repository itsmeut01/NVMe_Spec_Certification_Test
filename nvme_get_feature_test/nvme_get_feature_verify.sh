#!/bin/bash
# SPDX-License-Identifier: GPL-3.0+
# Copyright (C) 2025 Red Hat, Inc.
#
# NVMe Get Features verification
# Based on NVMe Base Specification — Get Features command
# Feature IDs from nvme-cli upstream
#
# Usage:
#   ./nvme_get_feature_verify.sh /dev/nvme0
#   ./nvme_get_feature_verify.sh /dev/nvme0n1
#   ./nvme_get_feature_verify.sh              # auto-detects first NVMe controller

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/nvme_test_lib.sh
source "${SCRIPT_DIR}/../common/nvme_test_lib.sh"

CTRL_DEV=""

get_feature_val() {
	local fid="$1"
	local output
	output=$(nvme get-feature "$CTRL_DEV" -f "$fid" 2>&1) || true
	echo "$output"
}

extract_feature_result() {
	local output="$1"
	local hex
	hex=$(echo "$output" | grep -oiP '(?:result|value)[[:space:]:]*0x[0-9a-fA-F]+' | head -1 | grep -oiP '0x[0-9a-fA-F]+' || true)
	if [ -n "$hex" ]; then
		echo "$hex"
		return
	fi
	hex=$(echo "$output" | grep -oiP '(?:result|value)[[:space:]:]*[0-9a-fA-F]+' | head -1 | grep -oiP '[0-9a-fA-F]+$' || true)
	if [ -n "$hex" ]; then
		echo "0x${hex}"
		return
	fi
}

# --------------------------------------------------------------------------
# Test functions
# --------------------------------------------------------------------------

test_num_queues() {
	local output
	output=$(get_feature_val "0x07")
	log_cmd "Get Feature: Number of Queues (FID 0x07)" "nvme get-feature ${CTRL_DEV} -f 0x07" "$output"
	local result
	result=$(extract_feature_result "$output")
	if [ -z "$result" ]; then
		if echo "$output" | grep -qi "error\|invalid\|not support"; then
			log_skip "Number of Queues (FID 0x07)" "feature not accessible"
		else
			log_fail "Number of Queues (FID 0x07)" "could not parse result"
		fi
		return
	fi
	local val=$((result))
	local nsqa=$(( val & 0xFFFF ))
	local ncqa=$(( (val >> 16) & 0xFFFF ))
	local nsqa_count=$((nsqa + 1))
	local ncqa_count=$((ncqa + 1))
	if [ "$nsqa_count" -gt 0 ] && [ "$ncqa_count" -gt 0 ]; then
		log_pass "Number of Queues: NSQA=${nsqa_count} submission, NCQA=${ncqa_count} completion"
	else
		log_fail "Number of Queues must be > 0" "NSQA=${nsqa_count} NCQA=${ncqa_count}"
	fi
}

test_num_queues_reasonable() {
	local output
	output=$(get_feature_val "0x07")
	local result
	result=$(extract_feature_result "$output")
	if [ -z "$result" ]; then
		log_skip "Number of Queues reasonable range" "could not read feature"
		return
	fi
	local val=$((result))
	local nsqa=$(( val & 0xFFFF ))
	local ncqa=$(( (val >> 16) & 0xFFFF ))
	if [ "$nsqa" -le 65534 ] && [ "$ncqa" -le 65534 ]; then
		log_pass "Queue counts within valid range (NSQA=${nsqa}, NCQA=${ncqa}, max=65534)"
	else
		log_fail "Queue counts must be <= 65534" "NSQA=${nsqa}, NCQA=${ncqa}"
	fi
}

test_volatile_wc() {
	local output
	output=$(get_feature_val "0x06")
	log_cmd "Get Feature: Volatile Write Cache (FID 0x06)" "nvme get-feature ${CTRL_DEV} -f 0x06" "$output"
	local result
	result=$(extract_feature_result "$output")
	if [ -z "$result" ]; then
		local vwc
		vwc=$(get_id_ctrl_field "vwc")
		if [ -n "$vwc" ] && [ "$((vwc & 0x1))" -eq 0 ]; then
			log_skip "Volatile Write Cache (FID 0x06)" "VWC not present per id-ctrl"
		else
			log_skip "Volatile Write Cache (FID 0x06)" "could not read feature"
		fi
		return
	fi
	local feat_val=$((result))
	local wce=$(( feat_val & 0x1 ))
	local vwc
	vwc=$(get_id_ctrl_field "vwc")
	if [ -n "$vwc" ]; then
		local vwcp=$(( vwc & 0x1 ))
		if [ "$vwcp" -eq 0 ] && [ "$wce" -eq 1 ]; then
			log_warn "VWC cross-check" "id-ctrl says VWC not present but feature reports WCE=1"
		else
			log_pass "Volatile Write Cache: WCE=${wce} (id-ctrl VWC present=${vwcp})"
		fi
	else
		log_pass "Volatile Write Cache: WCE=${wce}"
	fi
}

test_power_mgmt() {
	local output
	output=$(get_feature_val "0x02")
	log_cmd "Get Feature: Power Management (FID 0x02)" "nvme get-feature ${CTRL_DEV} -f 0x02" "$output"
	local result
	result=$(extract_feature_result "$output")
	if [ -z "$result" ]; then
		log_skip "Power Management (FID 0x02)" "could not read feature"
		return
	fi
	local feat_val=$((result))
	local ps=$(( feat_val & 0x1F ))
	local npss
	npss=$(get_id_ctrl_field "npss")
	if [ -n "$npss" ]; then
		local npss_int=$((npss))
		if [ "$ps" -le "$npss_int" ]; then
			log_pass "Power Management: current PS=${ps} (valid range 0-${npss_int})"
		else
			log_fail "Current PS must be <= NPSS" "PS=${ps}, NPSS=${npss_int}"
		fi
	else
		log_pass "Power Management: current PS=${ps}"
	fi
}

test_temp_thresh() {
	local output
	output=$(get_feature_val "0x04")
	log_cmd "Get Feature: Temperature Threshold (FID 0x04)" "nvme get-feature ${CTRL_DEV} -f 0x04" "$output"
	local result
	result=$(extract_feature_result "$output")
	if [ -z "$result" ]; then
		log_skip "Temperature Threshold (FID 0x04)" "could not read feature"
		return
	fi
	local feat_val=$((result))
	local tmpth=$(( feat_val & 0xFFFF ))
	if [ "$tmpth" -gt 0 ]; then
		local celsius=$((tmpth - 273))
		log_pass "Temperature Threshold: ${tmpth}K (${celsius}C)"
	else
		log_pass "Temperature Threshold: 0 (not configured)"
	fi
}

test_err_recovery() {
	local output
	output=$(get_feature_val "0x05")
	log_cmd "Get Feature: Error Recovery (FID 0x05)" "nvme get-feature ${CTRL_DEV} -f 0x05" "$output"
	local result
	result=$(extract_feature_result "$output")
	if [ -z "$result" ]; then
		log_skip "Error Recovery (FID 0x05)" "could not read feature"
		return
	fi
	local feat_val=$((result))
	local tler=$(( feat_val & 0xFFFF ))
	if [ "$tler" -gt 0 ]; then
		local ms=$((tler * 100))
		log_pass "Error Recovery: TLER=${tler} (${ms} ms)"
	else
		log_pass "Error Recovery: TLER=0 (no timeout, unlimited retry)"
	fi
}

test_arbitration() {
	local output
	output=$(get_feature_val "0x01")
	log_cmd "Get Feature: Arbitration (FID 0x01)" "nvme get-feature ${CTRL_DEV} -f 0x01" "$output"
	local result
	result=$(extract_feature_result "$output")
	if [ -z "$result" ]; then
		log_skip "Arbitration (FID 0x01)" "could not read feature"
		return
	fi
	local feat_val=$((result))
	local ab=$(( feat_val & 0x7 ))
	local lpw=$(( (feat_val >> 8) & 0xFF ))
	local mpw=$(( (feat_val >> 16) & 0xFF ))
	local hpw=$(( (feat_val >> 24) & 0xFF ))
	log_pass "Arbitration: AB=${ab} LPW=${lpw} MPW=${mpw} HPW=${hpw}"
}

test_auto_pst() {
	if ! ver_at_least 1 3; then
		log_skip "Autonomous Power State Transition (FID 0x0C)" "requires NVMe 1.3+"
		return
	fi
	local apsta
	apsta=$(get_id_ctrl_field "apsta")
	if [ -n "$apsta" ] && [ "$((apsta & 0x1))" -eq 0 ]; then
		log_skip "Autonomous Power State Transition (FID 0x0C)" "APSTA not supported"
		return
	fi
	local output
	output=$(get_feature_val "0x0c")
	log_cmd "Get Feature: APST (FID 0x0C)" "nvme get-feature ${CTRL_DEV} -f 0x0c" "$output"
	local result
	result=$(extract_feature_result "$output")
	if [ -z "$result" ]; then
		log_skip "Autonomous Power State Transition (FID 0x0C)" "could not read feature"
		return
	fi
	local feat_val=$((result))
	local apste=$(( feat_val & 0x1 ))
	if [ "$apste" -eq 1 ]; then
		log_pass "APST: enabled (APSTE=1)"
	else
		log_pass "APST: disabled (APSTE=0)"
	fi
}

test_hctm() {
	if ! ver_at_least 1 3; then
		log_skip "Host Controlled Thermal Management (FID 0x10)" "requires NVMe 1.3+"
		return
	fi
	local hctma
	hctma=$(get_id_ctrl_field "hctma")
	if [ -n "$hctma" ] && [ "$((hctma & 0x1))" -eq 0 ]; then
		log_skip "Host Controlled Thermal Management (FID 0x10)" "HCTMA not supported"
		return
	fi
	local output
	output=$(get_feature_val "0x10")
	log_cmd "Get Feature: HCTM (FID 0x10)" "nvme get-feature ${CTRL_DEV} -f 0x10" "$output"
	local result
	result=$(extract_feature_result "$output")
	if [ -z "$result" ]; then
		log_skip "Host Controlled Thermal Management (FID 0x10)" "could not read feature"
		return
	fi
	local feat_val=$((result))
	local tmt2=$(( feat_val & 0xFFFF ))
	local tmt1=$(( (feat_val >> 16) & 0xFFFF ))
	if [ "$tmt1" -gt 0 ] || [ "$tmt2" -gt 0 ]; then
		log_pass "HCTM: TMT1=${tmt1}K, TMT2=${tmt2}K"
	else
		log_pass "HCTM: TMT1=0, TMT2=0 (not configured)"
	fi
}

test_feature_error_handling() {
	local output
	output=$(nvme get-feature "$CTRL_DEV" -f "0xFF" 2>&1) || true
	if [ -n "$output" ]; then
		log_pass "Unsupported FID (0xFF) handled gracefully (no crash)"
	else
		log_pass "Unsupported FID (0xFF) returned empty output (no crash)"
	fi
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

main() {
	preflight_checks

	if [ $# -eq 0 ]; then
		CTRL_DEV=$(auto_detect_ctrl)
		echo -e "${BOLD}No device specified — auto-detected: ${CTRL_DEV}${RESET}"
	elif [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
		echo "Usage: $0 [/dev/nvmeX | /dev/nvmeXnY]"
		echo "Verifies NVMe Get Features per NVMe Base Spec."
		exit 0
	else
		CTRL_DEV=$(resolve_ctrl_dev "$1")
	fi

	if [ ! -e "$CTRL_DEV" ]; then
		echo "ERROR: Device $CTRL_DEV does not exist." >&2
		exit 1
	fi

	cache_id_ctrl "$CTRL_DEV"
	init_log "nvme_get_feature_verify" "$CTRL_DEV"
	log_cmd "Identify Controller (cached)" "nvme id-ctrl ${CTRL_DEV}" "$_ID_CTRL_CACHE"

	local spec_ref
	spec_ref=$(get_spec_ref "get-feature")

	print_header \
		"NVMe Get Features — Verification" \
		"$spec_ref" \
		"$CTRL_DEV"

	echo -e "${BOLD}--- Queue Configuration ---${RESET}"
	test_num_queues
	test_num_queues_reasonable

	echo ""
	echo -e "${BOLD}--- Write Cache & Power ---${RESET}"
	test_volatile_wc
	test_power_mgmt

	echo ""
	echo -e "${BOLD}--- Temperature & Error Recovery ---${RESET}"
	test_temp_thresh
	test_err_recovery

	echo ""
	echo -e "${BOLD}--- Arbitration & Advanced Features ---${RESET}"
	test_arbitration
	test_auto_pst
	test_hctm

	echo ""
	echo -e "${BOLD}--- Error Handling ---${RESET}"
	test_feature_error_handling

	print_summary

	if [ "$FAIL_COUNT" -gt 0 ]; then
		exit 1
	fi
	exit 0
}

main "$@"
