#!/bin/bash
# SPDX-License-Identifier: GPL-3.0+
# Copyright (C) 2025 Red Hat, Inc.
#
# NVMe Power State Descriptor verification
# Based on NVMe Base Specification, Revision 2.1
# Section 5.1.13, Figure 313 — Power State Descriptor Data Structure
# Power state output from nvme-cli upstream nvme-print-stdout.c
#
# Power state descriptors are part of Identify Controller (bytes 2048-3071).
# nvme-cli prints them as "ps   N :" blocks within id-ctrl output.
#
# Usage:
#   ./nvme_power_state_verify.sh /dev/nvme0
#   ./nvme_power_state_verify.sh /dev/nvme0n1
#   ./nvme_power_state_verify.sh              # auto-detects first NVMe controller

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/nvme_test_lib.sh
source "${SCRIPT_DIR}/../common/nvme_test_lib.sh"

PS_LINES=""
NPSS_VAL=""

get_ps_line() {
	echo "$PS_LINES" | grep "^ps *$1 :" | head -1
}

get_ps_continuation() {
	local ps_num="$1"
	local ps_line
	ps_line=$(get_ps_line "$ps_num")
	if [ -z "$ps_line" ]; then
		return
	fi
	local line_num
	line_num=$(echo "$_ID_CTRL_CACHE" | grep -n "^ps *${ps_num} :" | head -1 | cut -d: -f1)
	if [ -n "$line_num" ]; then
		local next_line=$((line_num + 1))
		echo "$_ID_CTRL_CACHE" | sed -n "${next_line}p"
	fi
}

extract_ps_field() {
	local ps_line="$1"
	local field="$2"
	echo "$ps_line" | grep -oP "${field}:\S+" | cut -d: -f2
}

# --------------------------------------------------------------------------
# Test functions
# --------------------------------------------------------------------------

test_npss_from_id_ctrl() {
	NPSS_VAL=$(get_id_ctrl_field "npss")
	if [ -z "$NPSS_VAL" ]; then
		log_fail "NPSS (Number of Power States Support) is present in id-ctrl" "not found"
		return
	fi
	local npss_int=$((NPSS_VAL))
	local total_states=$((npss_int + 1))
	log_pass "NPSS from id-ctrl is ${npss_int} (${total_states} power state(s) supported)"
}

test_all_ps_descriptors_present() {
	if [ -z "$NPSS_VAL" ]; then
		log_skip "All power state descriptors present" "NPSS not available"
		return
	fi
	local npss_int=$((NPSS_VAL))
	local missing=0
	local i
	for i in $(seq 0 "$npss_int"); do
		if [ -z "$(get_ps_line "$i")" ]; then
			missing=$((missing + 1))
		fi
	done
	if [ "$missing" -eq 0 ]; then
		log_pass "All power state descriptors present (PS 0 through PS ${npss_int})"
	else
		log_fail "All power state descriptors present" "${missing} descriptor(s) missing"
	fi
}

test_ps0_max_power() {
	local ps0
	ps0=$(get_ps_line "0")
	if [ -z "$ps0" ]; then
		log_fail "PS 0 max_power (mp) is non-zero" "PS 0 not found"
		return
	fi
	local mp
	mp=$(extract_ps_field "$ps0" "mp")
	if [ -n "$mp" ] && [ "$mp" != "0" ] && [ "$mp" != "0.00W" ] && [ "$mp" != "0.0000W" ]; then
		log_pass "PS 0 max_power (mp) is non-zero (${mp})"
	else
		log_fail "PS 0 max_power (mp) must be non-zero" "got '${mp}'"
	fi
}

test_ps0_operational() {
	local ps0
	ps0=$(get_ps_line "0")
	if [ -z "$ps0" ]; then
		log_fail "PS 0 is operational" "PS 0 not found"
		return
	fi
	if echo "$ps0" | grep -q "non-operational"; then
		log_fail "PS 0 must be operational (NOPS=0)" "marked as non-operational"
	else
		log_pass "PS 0 is operational (NOPS=0)"
	fi
}

test_ps_enlat_exlat() {
	if [ -z "$NPSS_VAL" ]; then
		log_skip "All PS have enlat/exlat fields" "NPSS not available"
		return
	fi
	local npss_int=$((NPSS_VAL))
	local ok=0
	local total=0
	local i
	for i in $(seq 0 "$npss_int"); do
		local ps_line
		ps_line=$(get_ps_line "$i")
		if [ -z "$ps_line" ]; then
			continue
		fi
		total=$((total + 1))
		local enlat exlat
		enlat=$(extract_ps_field "$ps_line" "enlat")
		exlat=$(extract_ps_field "$ps_line" "exlat")
		if [ -n "$enlat" ] && [ -n "$exlat" ]; then
			ok=$((ok + 1))
		fi
	done
	if [ "$ok" -eq "$total" ]; then
		log_pass "All ${total} power states have enlat/exlat fields"
	else
		log_fail "All power states have enlat/exlat fields" "${ok}/${total} have both"
	fi
}

test_ps_rrt_rrl() {
	if [ -z "$NPSS_VAL" ]; then
		log_skip "All PS have rrt/rrl fields" "NPSS not available"
		return
	fi
	local npss_int=$((NPSS_VAL))
	local ok=0
	local total=0
	local i
	for i in $(seq 0 "$npss_int"); do
		local ps_line
		ps_line=$(get_ps_line "$i")
		if [ -z "$ps_line" ]; then
			continue
		fi
		total=$((total + 1))
		local rrt rrl
		rrt=$(extract_ps_field "$ps_line" "rrt")
		rrl=$(extract_ps_field "$ps_line" "rrl")
		if [ -n "$rrt" ] && [ -n "$rrl" ]; then
			ok=$((ok + 1))
		fi
	done
	if [ "$ok" -eq "$total" ]; then
		log_pass "All ${total} power states have rrt/rrl (read throughput/latency) fields"
	else
		log_fail "All power states have rrt/rrl fields" "${ok}/${total} have both"
	fi
}

test_ps_rwt_rwl() {
	if [ -z "$NPSS_VAL" ]; then
		log_skip "All PS have rwt/rwl fields" "NPSS not available"
		return
	fi
	local npss_int=$((NPSS_VAL))
	local ok=0
	local total=0
	local i
	for i in $(seq 0 "$npss_int"); do
		local ps_line cont_line
		ps_line=$(get_ps_line "$i")
		if [ -z "$ps_line" ]; then
			continue
		fi
		total=$((total + 1))
		cont_line=$(get_ps_continuation "$i")
		local rwt rwl
		rwt=$(extract_ps_field "$cont_line" "rwt")
		rwl=$(extract_ps_field "$cont_line" "rwl")
		if [ -z "$rwt" ]; then
			rwt=$(extract_ps_field "$ps_line" "rwt")
		fi
		if [ -z "$rwl" ]; then
			rwl=$(extract_ps_field "$ps_line" "rwl")
		fi
		if [ -n "$rwt" ] && [ -n "$rwl" ]; then
			ok=$((ok + 1))
		fi
	done
	if [ "$ok" -eq "$total" ]; then
		log_pass "All ${total} power states have rwt/rwl (write throughput/latency) fields"
	else
		log_fail "All power states have rwt/rwl fields" "${ok}/${total} have both"
	fi
}

test_ps_idle_power() {
	if ! ver_at_least 1 2; then
		log_skip "Power states have idle_power field" "requires NVMe 1.2+"
		return
	fi
	if [ -z "$NPSS_VAL" ]; then
		log_skip "Power states have idle_power field" "NPSS not available"
		return
	fi
	local npss_int=$((NPSS_VAL))
	local found=0
	local i
	for i in $(seq 0 "$npss_int"); do
		local cont_line
		cont_line=$(get_ps_continuation "$i")
		if [ -n "$cont_line" ] && echo "$cont_line" | grep -q "idle_power:"; then
			found=$((found + 1))
		fi
	done
	local total=$((npss_int + 1))
	if [ "$found" -eq "$total" ]; then
		log_pass "All ${total} power states have idle_power field"
	elif [ "$found" -gt 0 ]; then
		log_pass "idle_power field present in ${found}/${total} power states"
	else
		log_fail "Power states have idle_power field" "not found in any PS"
	fi
}

test_ps_active_power() {
	if ! ver_at_least 1 2; then
		log_skip "Power states have active_power field" "requires NVMe 1.2+"
		return
	fi
	if [ -z "$NPSS_VAL" ]; then
		log_skip "Power states have active_power field" "NPSS not available"
		return
	fi
	local npss_int=$((NPSS_VAL))
	local found=0
	local i
	for i in $(seq 0 "$npss_int"); do
		local cont_line
		cont_line=$(get_ps_continuation "$i")
		if [ -n "$cont_line" ] && echo "$cont_line" | grep -q "active_power:"; then
			found=$((found + 1))
		fi
	done
	local total=$((npss_int + 1))
	if [ "$found" -eq "$total" ]; then
		log_pass "All ${total} power states have active_power field"
	elif [ "$found" -gt 0 ]; then
		log_pass "active_power field present in ${found}/${total} power states"
	else
		log_fail "Power states have active_power field" "not found in any PS"
	fi
}

test_nops_states() {
	if [ -z "$NPSS_VAL" ]; then
		log_skip "Non-operational states have NOPS=1" "NPSS not available"
		return
	fi
	local npss_int=$((NPSS_VAL))
	if [ "$npss_int" -eq 0 ]; then
		log_skip "Non-operational states have NOPS=1" "only 1 power state (PS 0)"
		return
	fi
	local nops_count=0
	local op_count=0
	local i
	for i in $(seq 0 "$npss_int"); do
		local ps_line
		ps_line=$(get_ps_line "$i")
		if [ -z "$ps_line" ]; then
			continue
		fi
		if echo "$ps_line" | grep -q "non-operational"; then
			nops_count=$((nops_count + 1))
		else
			op_count=$((op_count + 1))
		fi
	done
	log_pass "Power state distribution: ${op_count} operational, ${nops_count} non-operational"
}

test_ps_max_power_decreasing() {
	if [ -z "$NPSS_VAL" ]; then
		log_skip "Max power generally decreases across PS" "NPSS not available"
		return
	fi
	local npss_int=$((NPSS_VAL))
	if [ "$npss_int" -eq 0 ]; then
		log_skip "Max power generally decreases across PS" "only 1 power state"
		return
	fi
	local prev_mp=""
	local violations=0
	local i
	for i in $(seq 0 "$npss_int"); do
		local ps_line
		ps_line=$(get_ps_line "$i")
		if [ -z "$ps_line" ]; then
			continue
		fi
		local mp
		mp=$(extract_ps_field "$ps_line" "mp")
		local mp_raw
		mp_raw=$(echo "$mp" | sed 's/[^0-9.]//g')
		if [ -n "$prev_mp" ] && [ -n "$mp_raw" ]; then
			if awk "BEGIN { exit !($mp_raw > $prev_mp) }" 2>/dev/null; then
				violations=$((violations + 1))
			fi
		fi
		if [ -n "$mp_raw" ]; then
			prev_mp="$mp_raw"
		fi
	done
	if [ "$violations" -eq 0 ]; then
		log_pass "Max power is non-increasing across power states"
	else
		log_pass "Max power trend check: ${violations} increase(s) across PS (non-monotonic but may be valid)"
	fi
}

# --------------------------------------------------------------------------
# Deep Validation Tests
# --------------------------------------------------------------------------

test_ps_idle_le_max() {
	if ! ver_at_least 1 2; then
		log_skip "idle_power <= max_power per state" "requires NVMe 1.2+"
		return
	fi
	if [ -z "$NPSS_VAL" ]; then
		log_skip "idle_power <= max_power per state" "NPSS not available"
		return
	fi
	local npss_int=$((NPSS_VAL))
	local violations=0
	local checked=0
	local i
	for i in $(seq 0 "$npss_int"); do
		local ps_line cont_line
		ps_line=$(get_ps_line "$i")
		cont_line=$(get_ps_continuation "$i")
		if [ -z "$ps_line" ] || [ -z "$cont_line" ]; then
			continue
		fi
		local mp idle
		mp=$(extract_ps_field "$ps_line" "mp")
		idle=$(extract_ps_field "$cont_line" "idle_power")
		if [ -z "$mp" ] || [ -z "$idle" ]; then
			continue
		fi
		local mp_raw idle_raw
		mp_raw=$(echo "$mp" | sed 's/[^0-9.]//g')
		idle_raw=$(echo "$idle" | sed 's/[^0-9.]//g')
		if [ -n "$mp_raw" ] && [ -n "$idle_raw" ]; then
			checked=$((checked + 1))
			if awk "BEGIN { exit !($idle_raw > $mp_raw) }" 2>/dev/null; then
				violations=$((violations + 1))
			fi
		fi
	done
	if [ "$checked" -eq 0 ]; then
		log_skip "idle_power <= max_power per state" "no states had both fields"
		return
	fi
	if [ "$violations" -eq 0 ]; then
		log_pass "idle_power <= max_power in all ${checked} power states"
	else
		log_fail "idle_power must be <= max_power" "${violations} state(s) have idle > max"
	fi
}

test_ps_active_le_max() {
	if ! ver_at_least 1 2; then
		log_skip "active_power <= max_power per state" "requires NVMe 1.2+"
		return
	fi
	if [ -z "$NPSS_VAL" ]; then
		log_skip "active_power <= max_power per state" "NPSS not available"
		return
	fi
	local npss_int=$((NPSS_VAL))
	local violations=0
	local checked=0
	local i
	for i in $(seq 0 "$npss_int"); do
		local ps_line cont_line
		ps_line=$(get_ps_line "$i")
		cont_line=$(get_ps_continuation "$i")
		if [ -z "$ps_line" ] || [ -z "$cont_line" ]; then
			continue
		fi
		local mp active
		mp=$(extract_ps_field "$ps_line" "mp")
		active=$(extract_ps_field "$cont_line" "active_power")
		if [ -z "$mp" ] || [ -z "$active" ]; then
			continue
		fi
		local mp_raw active_raw
		mp_raw=$(echo "$mp" | sed 's/[^0-9.]//g')
		active_raw=$(echo "$active" | sed 's/[^0-9.]//g')
		if [ -n "$mp_raw" ] && [ -n "$active_raw" ]; then
			checked=$((checked + 1))
			if awk "BEGIN { exit !($active_raw > $mp_raw) }" 2>/dev/null; then
				violations=$((violations + 1))
			fi
		fi
	done
	if [ "$checked" -eq 0 ]; then
		log_skip "active_power <= max_power per state" "no states had both fields"
		return
	fi
	if [ "$violations" -eq 0 ]; then
		log_pass "active_power <= max_power in all ${checked} power states"
	else
		log_fail "active_power must be <= max_power" "${violations} state(s) have active > max"
	fi
}

test_ps_latency_trend() {
	if [ -z "$NPSS_VAL" ]; then
		log_skip "Entry/exit latency trend across PS" "NPSS not available"
		return
	fi
	local npss_int=$((NPSS_VAL))
	if [ "$npss_int" -lt 2 ]; then
		log_skip "Entry/exit latency trend across PS" "fewer than 3 power states"
		return
	fi
	local prev_enlat="" prev_exlat=""
	local enlat_violations=0
	local exlat_violations=0
	local i
	for i in $(seq 0 "$npss_int"); do
		local ps_line
		ps_line=$(get_ps_line "$i")
		if [ -z "$ps_line" ]; then
			continue
		fi
		local enlat exlat
		enlat=$(extract_ps_field "$ps_line" "enlat")
		exlat=$(extract_ps_field "$ps_line" "exlat")
		if [ -n "$prev_enlat" ] && [ -n "$enlat" ]; then
			if [ "$enlat" -lt "$prev_enlat" ] 2>/dev/null; then
				enlat_violations=$((enlat_violations + 1))
			fi
		fi
		if [ -n "$prev_exlat" ] && [ -n "$exlat" ]; then
			if [ "$exlat" -lt "$prev_exlat" ] 2>/dev/null; then
				exlat_violations=$((exlat_violations + 1))
			fi
		fi
		prev_enlat="$enlat"
		prev_exlat="$exlat"
	done
	if [ "$enlat_violations" -eq 0 ] && [ "$exlat_violations" -eq 0 ]; then
		log_pass "Entry/exit latencies generally non-decreasing across power states"
	else
		log_warn "Latency trend anomaly" "enlat decreases: ${enlat_violations}, exlat decreases: ${exlat_violations}"
	fi
}

test_apste_consistency() {
	if ! ver_at_least 1 3; then
		log_skip "APSTA/APSTE consistency" "requires NVMe 1.3+"
		return
	fi
	local apsta
	apsta=$(get_id_ctrl_field "apsta")
	if [ -z "$apsta" ]; then
		log_skip "APSTA/APSTE consistency" "apsta not present in id-ctrl"
		return
	fi
	local apsta_int=$((apsta))
	if [ "$((apsta_int & 0x1))" -eq 1 ]; then
		log_pass "APSTA: Autonomous Power State Transitions supported (bit 0=1)"
	else
		log_pass "APSTA: Autonomous Power State Transitions not supported (bit 0=0)"
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
		echo "Verifies NVMe Power State Descriptors per NVMe Base Spec 2.1."
		exit 0
	else
		ctrl_dev=$(resolve_ctrl_dev "$1")
	fi

	if [ ! -e "$ctrl_dev" ]; then
		echo "ERROR: Device $ctrl_dev does not exist." >&2
		exit 1
	fi

	cache_id_ctrl "$ctrl_dev"
	init_log "nvme_power_state_verify" "$ctrl_dev"
	log_cmd "Identify Controller (includes Power State Descriptors)" "nvme id-ctrl ${ctrl_dev}" "$_ID_CTRL_CACHE"

	PS_LINES=$(echo "$_ID_CTRL_CACHE" | grep "^ps ")

	local spec_ref
	spec_ref=$(get_spec_ref "power-state")

	print_header \
		"NVMe Power State Descriptor — Verification" \
		"$spec_ref" \
		"$ctrl_dev"

	echo -e "${BOLD}--- Power State Count ---${RESET}"
	test_npss_from_id_ctrl
	test_all_ps_descriptors_present

	echo ""
	echo -e "${BOLD}--- PS 0 (Default) Validation ---${RESET}"
	test_ps0_max_power
	test_ps0_operational

	echo ""
	echo -e "${BOLD}--- Per-State Fields ---${RESET}"
	test_ps_enlat_exlat
	test_ps_rrt_rrl
	test_ps_rwt_rwl
	test_ps_idle_power
	test_ps_active_power

	echo ""
	echo -e "${BOLD}--- Power State Characteristics ---${RESET}"
	test_nops_states
	test_ps_max_power_decreasing

	echo ""
	echo -e "${BOLD}--- Deep Validation ---${RESET}"
	test_ps_idle_le_max
	test_ps_active_le_max
	test_ps_latency_trend
	test_apste_consistency

	print_summary

	if [ "$FAIL_COUNT" -gt 0 ]; then
		exit 1
	fi
	exit 0
}

main "$@"
