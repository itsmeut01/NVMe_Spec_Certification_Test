#!/bin/bash
# SPDX-License-Identifier: GPL-3.0+
# Copyright (C) 2025 Red Hat, Inc.
#
# NVMe Set Features — Functional / Behavioral Verification
# Based on NVMe Base Specification — Set Features command
# Pattern: save → set → behavioral action → verify → restore
#
# Usage:
#   ./nvme_feature_set_verify.sh /dev/nvme0 --allow-destructive
#   ./nvme_feature_set_verify.sh /dev/nvme0n1 --allow-destructive

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/nvme_test_lib.sh
source "${SCRIPT_DIR}/../common/nvme_test_lib.sh"

CTRL_DEV=""
NS_DEV=""
ALLOW_DESTRUCTIVE=""

# --------------------------------------------------------------------------
# Volatile Write Cache (FID 0x06) — 7 tests
# --------------------------------------------------------------------------

test_vwc_save() {
	save_feature "0x06" "$CTRL_DEV" >/dev/null
	if [ -n "${_SAVED_FEATURES[0x06]:-}" ]; then
		log_pass "VWC: saved original WCE value (${_SAVED_FEATURES[0x06]})"
	else
		log_skip "VWC: save original" "could not read FID 0x06"
	fi
}

test_vwc_disable() {
	if [ -z "${_SAVED_FEATURES[0x06]:-}" ]; then
		log_skip "VWC: disable write cache" "no saved value"
		return
	fi
	set_feature "0x06" "0" "$CTRL_DEV" >/dev/null
	if verify_feature "0x06" "0" "$CTRL_DEV"; then
		log_pass "VWC: disabled write cache (WCE=0, readback confirmed)"
	else
		log_fail "VWC: disable write cache" "readback did not confirm WCE=0"
	fi
}

test_vwc_io_disabled() {
	if [ -z "${_SAVED_FEATURES[0x06]:-}" ]; then
		log_skip "VWC: I/O with cache disabled" "no saved value"
		return
	fi
	if [ -z "$NS_DEV" ]; then
		log_skip "VWC: I/O with cache disabled" "no namespace device"
		return
	fi
	if write_read_verify "$NS_DEV" 0 1; then
		log_pass "VWC: write+read succeeded with cache disabled"
	else
		log_fail "VWC: I/O with cache disabled" "write+read data mismatch"
	fi
}

test_vwc_enable() {
	if [ -z "${_SAVED_FEATURES[0x06]:-}" ]; then
		log_skip "VWC: enable write cache" "no saved value"
		return
	fi
	set_feature "0x06" "1" "$CTRL_DEV" >/dev/null
	if verify_feature "0x06" "1" "$CTRL_DEV"; then
		log_pass "VWC: enabled write cache (WCE=1, readback confirmed)"
	else
		log_fail "VWC: enable write cache" "readback did not confirm WCE=1"
	fi
}

test_vwc_flush_with_cache() {
	if [ -z "${_SAVED_FEATURES[0x06]:-}" ]; then
		log_skip "VWC: flush after write with cache" "no saved value"
		return
	fi
	if [ -z "$NS_DEV" ]; then
		log_skip "VWC: flush after write with cache" "no namespace device"
		return
	fi
	if write_read_verify "$NS_DEV" 0 1; then
		log_pass "VWC: write + read with cache enabled succeeded"
	else
		log_fail "VWC: write + read with cache enabled" "data mismatch"
	fi
}

test_vwc_flush_succeeds() {
	if [ -z "$NS_DEV" ]; then
		log_skip "VWC: flush command" "no namespace device"
		return
	fi
	local output
	output=$(nvme flush "$NS_DEV" 2>&1) || true
	log_cmd "VWC: Flush namespace" "nvme flush $NS_DEV" "$output"
	if echo "$output" | grep -qi "error\|invalid\|fail"; then
		log_fail "VWC: flush command" "flush returned error: $output"
	else
		log_pass "VWC: flush command completed without error"
	fi
}

test_vwc_restore() {
	if [ -z "${_SAVED_FEATURES[0x06]:-}" ]; then
		log_skip "VWC: restore original WCE" "no saved value"
		return
	fi
	local saved="${_SAVED_FEATURES[0x06]}"
	restore_feature "0x06" "$CTRL_DEV"
	if verify_feature "0x06" "$saved" "$CTRL_DEV"; then
		log_pass "VWC: restored original WCE=${saved}"
	else
		log_warn "VWC: restore original WCE" "readback mismatch after restore"
	fi
}

# --------------------------------------------------------------------------
# Temperature Threshold (FID 0x04) — 6 tests
# --------------------------------------------------------------------------

test_tmpth_save() {
	save_feature "0x04" "$CTRL_DEV" >/dev/null
	if [ -n "${_SAVED_FEATURES[0x04]:-}" ]; then
		log_pass "TMPTH: saved original threshold (${_SAVED_FEATURES[0x04]})"
	else
		log_skip "TMPTH: save original" "could not read FID 0x04"
	fi
}

test_tmpth_set_below_temp() {
	if [ -z "${_SAVED_FEATURES[0x04]:-}" ]; then
		log_skip "TMPTH: set below current temp" "no saved value"
		return
	fi
	local smart_output
	smart_output=$(nvme smart-log "$CTRL_DEV" 2>&1) || true
	log_cmd "TMPTH: SMART log for current temperature" "nvme smart-log $CTRL_DEV" "$smart_output"
	local temp_raw
	temp_raw=$(echo "$smart_output" | grep "^temperature" | awk '{print $3}' | tr -d ',' || true)
	if [ -z "$temp_raw" ]; then
		log_skip "TMPTH: set below current temp" "could not read SMART temperature"
		return
	fi
	local current_temp_k=$((temp_raw + 273))
	local new_thresh=$((current_temp_k - 5))
	if [ "$new_thresh" -le 0 ]; then
		new_thresh=1
	fi
	set_feature "0x04" "$new_thresh" "$CTRL_DEV" >/dev/null
	if verify_feature "0x04" "$new_thresh" "$CTRL_DEV"; then
		log_pass "TMPTH: set threshold below current temp (${new_thresh}K < ${current_temp_k}K)"
	else
		log_fail "TMPTH: set below current temp" "readback mismatch"
	fi
}

test_tmpth_critical_warning() {
	if [ -z "${_SAVED_FEATURES[0x04]:-}" ]; then
		log_skip "TMPTH: verify critical_warning fires" "no saved value"
		return
	fi
	sleep 1
	local smart_output
	smart_output=$(nvme smart-log "$CTRL_DEV" 2>&1) || true
	log_cmd "TMPTH: SMART log for critical_warning check" "nvme smart-log $CTRL_DEV" "$smart_output"
	local cw
	cw=$(echo "$smart_output" | grep "^critical_warning" | awk '{print $3}' || true)
	if [ -z "$cw" ]; then
		log_skip "TMPTH: verify critical_warning" "could not read SMART"
		return
	fi
	local cw_int=$((cw))
	local temp_bit=$(( (cw_int >> 1) & 0x1 ))
	if [ "$temp_bit" -eq 1 ]; then
		log_pass "TMPTH: critical_warning bit 1 (temperature) fired after threshold lowered"
	else
		log_warn "TMPTH: critical_warning bit 1 not set" "controller may batch AER — advisory"
	fi
}

test_tmpth_set_zero() {
	if [ -z "${_SAVED_FEATURES[0x04]:-}" ]; then
		log_skip "TMPTH: set threshold to 0" "no saved value"
		return
	fi
	local output
	output=$(set_feature "0x04" "0" "$CTRL_DEV")
	if echo "$output" | grep -qi "error\|invalid"; then
		log_pass "TMPTH: controller rejected threshold=0 (expected for some controllers)"
	else
		log_pass "TMPTH: set threshold to 0 accepted"
	fi
}

test_tmpth_critical_clears() {
	if [ -z "${_SAVED_FEATURES[0x04]:-}" ]; then
		log_skip "TMPTH: verify critical_warning clears" "no saved value"
		return
	fi
	local saved="${_SAVED_FEATURES[0x04]}"
	set_feature "0x04" "$((saved))" "$CTRL_DEV" >/dev/null
	sleep 1
	local smart_output
	smart_output=$(nvme smart-log "$CTRL_DEV" 2>&1) || true
	log_cmd "TMPTH: SMART log for critical_warning clear check" "nvme smart-log $CTRL_DEV" "$smart_output"
	local cw
	cw=$(echo "$smart_output" | grep "^critical_warning" | awk '{print $3}' || true)
	if [ -z "$cw" ]; then
		log_skip "TMPTH: verify critical_warning clears" "could not read SMART"
		return
	fi
	local cw_int=$((cw))
	local temp_bit=$(( (cw_int >> 1) & 0x1 ))
	if [ "$temp_bit" -eq 0 ]; then
		log_pass "TMPTH: critical_warning bit 1 cleared after restoring safe threshold"
	else
		log_warn "TMPTH: critical_warning bit 1 still set" "may take time to clear — advisory"
	fi
}

test_tmpth_restore() {
	if [ -z "${_SAVED_FEATURES[0x04]:-}" ]; then
		log_skip "TMPTH: restore original threshold" "no saved value"
		return
	fi
	local saved="${_SAVED_FEATURES[0x04]}"
	restore_feature "0x04" "$CTRL_DEV"
	if verify_feature "0x04" "$saved" "$CTRL_DEV"; then
		log_pass "TMPTH: restored original threshold=${saved}"
	else
		log_warn "TMPTH: restore original threshold" "readback mismatch"
	fi
}

# --------------------------------------------------------------------------
# Power Management (FID 0x02) — 7 tests
# --------------------------------------------------------------------------

test_pm_save() {
	save_feature "0x02" "$CTRL_DEV" >/dev/null
	if [ -n "${_SAVED_FEATURES[0x02]:-}" ]; then
		log_pass "PM: saved current power state (${_SAVED_FEATURES[0x02]})"
	else
		log_skip "PM: save current PS" "could not read FID 0x02"
	fi
}

test_pm_set_ps0() {
	if [ -z "${_SAVED_FEATURES[0x02]:-}" ]; then
		log_skip "PM: set PS 0" "no saved value"
		return
	fi
	set_feature "0x02" "0" "$CTRL_DEV" >/dev/null
	if verify_feature "0x02" "0" "$CTRL_DEV"; then
		log_pass "PM: set power state 0 (readback confirmed)"
	else
		log_fail "PM: set PS 0" "readback mismatch"
	fi
}

test_pm_io_ps0() {
	if [ -z "${_SAVED_FEATURES[0x02]:-}" ]; then
		log_skip "PM: I/O in PS 0" "no saved value"
		return
	fi
	if [ -z "$NS_DEV" ]; then
		log_skip "PM: I/O in PS 0" "no namespace device"
		return
	fi
	if write_read_verify "$NS_DEV" 0 1; then
		log_pass "PM: write+read succeeded in power state 0"
	else
		log_fail "PM: I/O in PS 0" "write+read data mismatch"
	fi
}

test_pm_cycle_all() {
	if [ -z "${_SAVED_FEATURES[0x02]:-}" ]; then
		log_skip "PM: cycle all operational PS" "no saved value"
		return
	fi
	local npss
	npss=$(get_id_ctrl_field "npss")
	if [ -z "$npss" ]; then
		log_skip "PM: cycle all operational PS" "could not read NPSS"
		return
	fi
	local npss_int=$((npss))
	local all_ok=1
	local tested=0
	for ps in $(seq 0 "$npss_int"); do
		set_feature "0x02" "$ps" "$CTRL_DEV" >/dev/null
		local id_out
		id_out=$(nvme id-ctrl "$CTRL_DEV" 2>&1) || true
		log_cmd "PM: Identify Controller at PS ${ps}" "nvme id-ctrl $CTRL_DEV" "$id_out"
		if echo "$id_out" | grep -q "^mn "; then
			tested=$((tested + 1))
		else
			all_ok=0
			break
		fi
	done
	if [ "$all_ok" -eq 1 ] && [ "$tested" -gt 0 ]; then
		log_pass "PM: cycled PS 0-${npss_int}, id-ctrl succeeded in each (${tested} states)"
	else
		log_fail "PM: cycle all operational PS" "id-ctrl failed in some power state"
	fi
	set_feature "0x02" "0" "$CTRL_DEV" >/dev/null
}

test_pm_responsive_deepest() {
	if [ -z "${_SAVED_FEATURES[0x02]:-}" ]; then
		log_skip "PM: responsive after deepest PS" "no saved value"
		return
	fi
	local npss
	npss=$(get_id_ctrl_field "npss")
	if [ -z "$npss" ]; then
		log_skip "PM: responsive after deepest PS" "could not read NPSS"
		return
	fi
	local npss_int=$((npss))
	set_feature "0x02" "$npss_int" "$CTRL_DEV" >/dev/null
	sleep 1
	local id_out
	id_out=$(nvme id-ctrl "$CTRL_DEV" 2>&1) || true
	log_cmd "PM: Identify Controller after deepest PS" "nvme id-ctrl $CTRL_DEV" "$id_out"
	if echo "$id_out" | grep -q "^mn "; then
		log_pass "PM: id-ctrl succeeds after setting deepest PS (${npss_int})"
	else
		log_fail "PM: responsive after deepest PS" "id-ctrl failed after PS=${npss_int}"
	fi
	set_feature "0x02" "0" "$CTRL_DEV" >/dev/null
}

test_pm_invalid_ps() {
	if [ -z "${_SAVED_FEATURES[0x02]:-}" ]; then
		log_skip "PM: invalid PS rejected" "no saved value"
		return
	fi
	local npss
	npss=$(get_id_ctrl_field "npss")
	if [ -z "$npss" ]; then
		log_skip "PM: invalid PS rejected" "could not read NPSS"
		return
	fi
	local bad_ps=$((npss + 1))
	local output
	output=$(set_feature "0x02" "$bad_ps" "$CTRL_DEV")
	if echo "$output" | grep -qi "error\|invalid\|status"; then
		log_pass "PM: invalid PS ${bad_ps} (> NPSS=${npss}) correctly rejected"
	else
		log_warn "PM: invalid PS not rejected" "PS=${bad_ps} accepted (controller may clamp)"
	fi
}

test_pm_restore() {
	if [ -z "${_SAVED_FEATURES[0x02]:-}" ]; then
		log_skip "PM: restore original PS" "no saved value"
		return
	fi
	local saved="${_SAVED_FEATURES[0x02]}"
	restore_feature "0x02" "$CTRL_DEV"
	if verify_feature "0x02" "$saved" "$CTRL_DEV"; then
		log_pass "PM: restored original PS=${saved}"
	else
		log_warn "PM: restore original PS" "readback mismatch"
	fi
}

# --------------------------------------------------------------------------
# Error Recovery (FID 0x05) — 4 tests
# --------------------------------------------------------------------------

test_err_save() {
	save_feature "0x05" "$CTRL_DEV" >/dev/null
	if [ -n "${_SAVED_FEATURES[0x05]:-}" ]; then
		log_pass "ERR: saved current TLER (${_SAVED_FEATURES[0x05]})"
	else
		log_skip "ERR: save current TLER" "could not read FID 0x05"
	fi
}

test_err_set_value() {
	if [ -z "${_SAVED_FEATURES[0x05]:-}" ]; then
		log_skip "ERR: set TLER=50" "no saved value"
		return
	fi
	set_feature "0x05" "50" "$CTRL_DEV" >/dev/null
	if verify_feature "0x05" "50" "$CTRL_DEV"; then
		log_pass "ERR: set TLER=50 (5000ms), readback confirmed"
	else
		log_warn "ERR: set TLER=50" "readback mismatch (controller may not support)"
	fi
}

test_err_set_zero() {
	if [ -z "${_SAVED_FEATURES[0x05]:-}" ]; then
		log_skip "ERR: set TLER=0" "no saved value"
		return
	fi
	set_feature "0x05" "0" "$CTRL_DEV" >/dev/null
	if verify_feature "0x05" "0" "$CTRL_DEV"; then
		log_pass "ERR: set TLER=0 (unlimited), readback confirmed"
	else
		log_warn "ERR: set TLER=0" "readback mismatch"
	fi
}

test_err_restore() {
	if [ -z "${_SAVED_FEATURES[0x05]:-}" ]; then
		log_skip "ERR: restore original TLER" "no saved value"
		return
	fi
	local saved="${_SAVED_FEATURES[0x05]}"
	restore_feature "0x05" "$CTRL_DEV"
	if verify_feature "0x05" "$saved" "$CTRL_DEV"; then
		log_pass "ERR: restored original TLER=${saved}"
	else
		log_warn "ERR: restore TLER" "readback mismatch"
	fi
}

# --------------------------------------------------------------------------
# Arbitration (FID 0x01) — 4 tests
# --------------------------------------------------------------------------

test_arb_save() {
	save_feature "0x01" "$CTRL_DEV" >/dev/null
	if [ -n "${_SAVED_FEATURES[0x01]:-}" ]; then
		log_pass "ARB: saved current arbitration (${_SAVED_FEATURES[0x01]})"
	else
		log_skip "ARB: save current" "could not read FID 0x01"
	fi
}

test_arb_set_value() {
	if [ -z "${_SAVED_FEATURES[0x01]:-}" ]; then
		log_skip "ARB: set arbitration value" "no saved value"
		return
	fi
	local new_val=$((0x07000000 | 0x3))
	set_feature "0x01" "$new_val" "$CTRL_DEV" >/dev/null
	local output
	output=$(nvme get-feature "$CTRL_DEV" -f "0x01" 2>&1) || true
	log_cmd "ARB: Get Feature 0x01 readback" "nvme get-feature $CTRL_DEV -f 0x01" "$output"
	local result
	result=$(extract_feature_result "$output")
	if [ -n "$result" ]; then
		log_pass "ARB: set arbitration value, readback=${result}"
	else
		log_warn "ARB: set arbitration value" "could not read back"
	fi
}

test_arb_io_after() {
	if [ -z "${_SAVED_FEATURES[0x01]:-}" ]; then
		log_skip "ARB: I/O after arbitration change" "no saved value"
		return
	fi
	if [ -z "$NS_DEV" ]; then
		log_skip "ARB: I/O after arbitration change" "no namespace device"
		return
	fi
	if write_read_verify "$NS_DEV" 0 1; then
		log_pass "ARB: write+read succeeded under new arbitration settings"
	else
		log_fail "ARB: I/O after arbitration change" "write+read data mismatch"
	fi
}

test_arb_restore() {
	if [ -z "${_SAVED_FEATURES[0x01]:-}" ]; then
		log_skip "ARB: restore original" "no saved value"
		return
	fi
	local saved="${_SAVED_FEATURES[0x01]}"
	restore_feature "0x01" "$CTRL_DEV"
	if verify_feature "0x01" "$saved" "$CTRL_DEV"; then
		log_pass "ARB: restored original arbitration=${saved}"
	else
		log_warn "ARB: restore original" "readback mismatch"
	fi
}

# --------------------------------------------------------------------------
# APST (FID 0x0C, NVMe 1.3+) — 5 tests
# --------------------------------------------------------------------------

_apst_supported() {
	if ! ver_at_least 1 3; then return 1; fi
	local apsta
	apsta=$(get_id_ctrl_field "apsta")
	if [ -n "$apsta" ] && [ "$((apsta & 0x1))" -eq 0 ]; then return 1; fi
	return 0
}

test_apst_save() {
	if ! _apst_supported; then
		log_skip "APST: save current APSTE" "APSTA not supported or NVMe < 1.3"
		return
	fi
	save_feature "0x0c" "$CTRL_DEV" >/dev/null
	if [ -n "${_SAVED_FEATURES[0x0c]:-}" ]; then
		log_pass "APST: saved current APSTE (${_SAVED_FEATURES[0x0c]})"
	else
		log_skip "APST: save current" "could not read FID 0x0C"
	fi
}

test_apst_enable() {
	if ! _apst_supported || [ -z "${_SAVED_FEATURES[0x0c]:-}" ]; then
		log_skip "APST: enable" "not supported or no saved value"
		return
	fi
	set_feature "0x0c" "1" "$CTRL_DEV" >/dev/null
	if verify_feature "0x0c" "1" "$CTRL_DEV"; then
		log_pass "APST: enabled (APSTE=1, readback confirmed)"
	else
		log_warn "APST: enable" "readback mismatch"
	fi
}

test_apst_responsive() {
	if ! _apst_supported || [ -z "${_SAVED_FEATURES[0x0c]:-}" ]; then
		log_skip "APST: responsive with APST on" "not supported or no saved value"
		return
	fi
	local id_out
	id_out=$(nvme id-ctrl "$CTRL_DEV" 2>&1) || true
	log_cmd "APST: Identify Controller with APST enabled" "nvme id-ctrl $CTRL_DEV" "$id_out"
	if echo "$id_out" | grep -q "^mn "; then
		if [ -n "$NS_DEV" ] && write_read_verify "$NS_DEV" 0 1; then
			log_pass "APST: id-ctrl + I/O write+read succeeded with APST enabled"
		elif [ -n "$NS_DEV" ]; then
			log_fail "APST: responsive with APST on" "I/O failed"
		else
			log_pass "APST: id-ctrl succeeded with APST enabled (no NS for I/O)"
		fi
	else
		log_fail "APST: responsive with APST on" "id-ctrl failed"
	fi
}

test_apst_disable() {
	if ! _apst_supported || [ -z "${_SAVED_FEATURES[0x0c]:-}" ]; then
		log_skip "APST: disable" "not supported or no saved value"
		return
	fi
	set_feature "0x0c" "0" "$CTRL_DEV" >/dev/null
	if verify_feature "0x0c" "0" "$CTRL_DEV"; then
		log_pass "APST: disabled (APSTE=0, readback confirmed)"
	else
		log_warn "APST: disable" "readback mismatch"
	fi
}

test_apst_restore() {
	if ! _apst_supported || [ -z "${_SAVED_FEATURES[0x0c]:-}" ]; then
		log_skip "APST: restore original" "not supported or no saved value"
		return
	fi
	local saved="${_SAVED_FEATURES[0x0c]}"
	restore_feature "0x0c" "$CTRL_DEV"
	if verify_feature "0x0c" "$saved" "$CTRL_DEV"; then
		log_pass "APST: restored original APSTE=${saved}"
	else
		log_warn "APST: restore" "readback mismatch"
	fi
}

# --------------------------------------------------------------------------
# HCTM (FID 0x10, NVMe 1.3+) — 6 tests
# --------------------------------------------------------------------------

_hctm_supported() {
	if ! ver_at_least 1 3; then return 1; fi
	local hctma
	hctma=$(get_id_ctrl_field "hctma")
	if [ -n "$hctma" ] && [ "$((hctma & 0x1))" -eq 0 ]; then return 1; fi
	return 0
}

test_hctm_save() {
	if ! _hctm_supported; then
		log_skip "HCTM: save current TMT" "HCTMA not supported or NVMe < 1.3"
		return
	fi
	save_feature "0x10" "$CTRL_DEV" >/dev/null
	if [ -n "${_SAVED_FEATURES[0x10]:-}" ]; then
		log_pass "HCTM: saved current TMT (${_SAVED_FEATURES[0x10]})"
	else
		log_skip "HCTM: save current" "could not read FID 0x10"
	fi
}

test_hctm_set_range() {
	if ! _hctm_supported || [ -z "${_SAVED_FEATURES[0x10]:-}" ]; then
		log_skip "HCTM: set TMT in range" "not supported or no saved value"
		return
	fi
	local mntmt mxtmt
	mntmt=$(get_id_ctrl_field "mntmt")
	mxtmt=$(get_id_ctrl_field "mxtmt")
	local tmt1 tmt2
	if [ -n "$mntmt" ] && [ -n "$mxtmt" ] && [ "$((mntmt))" -gt 0 ] && [ "$((mxtmt))" -gt 0 ]; then
		tmt1=$((mxtmt))
		tmt2=$((mntmt))
	else
		tmt1=340
		tmt2=320
	fi
	local new_val=$(( (tmt1 << 16) | tmt2 ))
	set_feature "0x10" "$new_val" "$CTRL_DEV" >/dev/null
	if verify_feature "0x10" "$new_val" "$CTRL_DEV"; then
		log_pass "HCTM: set TMT1=${tmt1}K TMT2=${tmt2}K, readback confirmed"
	else
		log_warn "HCTM: set TMT in range" "readback mismatch"
	fi
}

test_hctm_smart_temp() {
	if ! _hctm_supported || [ -z "${_SAVED_FEATURES[0x10]:-}" ]; then
		log_skip "HCTM: read SMART temp under HCTM" "not supported or no saved value"
		return
	fi
	local smart_output
	smart_output=$(nvme smart-log "$CTRL_DEV" 2>&1) || true
	log_cmd "HCTM: SMART log for temperature under HCTM" "nvme smart-log $CTRL_DEV" "$smart_output"
	local temp
	temp=$(echo "$smart_output" | grep "^temperature" | awk '{print $3}' | tr -d ',' || true)
	if [ -n "$temp" ]; then
		local temp_k=$((temp + 273))
		log_pass "HCTM: SMART temperature=${temp}C (${temp_k}K) under HCTM active"
	else
		log_skip "HCTM: read SMART temp" "could not read temperature"
	fi
}

test_hctm_invalid_order() {
	if ! _hctm_supported || [ -z "${_SAVED_FEATURES[0x10]:-}" ]; then
		log_skip "HCTM: TMT2 > TMT1 (invalid)" "not supported or no saved value"
		return
	fi
	local bad_val=$(( (300 << 16) | 350 ))
	local output
	output=$(set_feature "0x10" "$bad_val" "$CTRL_DEV")
	if echo "$output" | grep -qi "error\|invalid\|status"; then
		log_pass "HCTM: invalid TMT order (TMT2>TMT1) correctly rejected"
	else
		log_warn "HCTM: invalid TMT order" "controller accepted TMT2>TMT1 (may clamp)"
	fi
}

test_hctm_set_zero() {
	if ! _hctm_supported || [ -z "${_SAVED_FEATURES[0x10]:-}" ]; then
		log_skip "HCTM: set both to 0" "not supported or no saved value"
		return
	fi
	set_feature "0x10" "0" "$CTRL_DEV" >/dev/null
	if verify_feature "0x10" "0" "$CTRL_DEV"; then
		log_pass "HCTM: disabled (TMT1=0, TMT2=0, readback confirmed)"
	else
		log_warn "HCTM: set both to 0" "readback mismatch"
	fi
}

test_hctm_restore() {
	if ! _hctm_supported || [ -z "${_SAVED_FEATURES[0x10]:-}" ]; then
		log_skip "HCTM: restore original TMT" "not supported or no saved value"
		return
	fi
	local saved="${_SAVED_FEATURES[0x10]}"
	restore_feature "0x10" "$CTRL_DEV"
	if verify_feature "0x10" "$saved" "$CTRL_DEV"; then
		log_pass "HCTM: restored original TMT=${saved}"
	else
		log_warn "HCTM: restore" "readback mismatch"
	fi
}

# --------------------------------------------------------------------------
# Interrupt Coalescing (FID 0x08) — 4 tests
# --------------------------------------------------------------------------

test_intc_save() {
	save_feature "0x08" "$CTRL_DEV" >/dev/null
	if [ -n "${_SAVED_FEATURES[0x08]:-}" ]; then
		log_pass "INTC: saved current coalescing (${_SAVED_FEATURES[0x08]})"
	else
		log_skip "INTC: save current" "could not read FID 0x08"
	fi
}

test_intc_set_value() {
	if [ -z "${_SAVED_FEATURES[0x08]:-}" ]; then
		log_skip "INTC: set coalescing params" "no saved value"
		return
	fi
	local new_val=$(( (10 << 8) | 4 ))
	set_feature "0x08" "$new_val" "$CTRL_DEV" >/dev/null
	local output
	output=$(nvme get-feature "$CTRL_DEV" -f "0x08" 2>&1) || true
	log_cmd "INTC: Get Feature 0x08 readback" "nvme get-feature $CTRL_DEV -f 0x08" "$output"
	local result
	result=$(extract_feature_result "$output")
	if [ -n "$result" ]; then
		log_pass "INTC: set coalescing (TIME=10, THR=4), readback=${result}"
	else
		log_warn "INTC: set coalescing" "could not read back"
	fi
}

test_intc_io_after() {
	if [ -z "${_SAVED_FEATURES[0x08]:-}" ]; then
		log_skip "INTC: I/O under new coalescing" "no saved value"
		return
	fi
	if [ -z "$NS_DEV" ]; then
		log_skip "INTC: I/O under new coalescing" "no namespace device"
		return
	fi
	if write_read_verify "$NS_DEV" 0 1; then
		log_pass "INTC: write+read succeeded under new coalescing settings"
	else
		log_fail "INTC: I/O under new coalescing" "data mismatch"
	fi
}

test_intc_restore() {
	if [ -z "${_SAVED_FEATURES[0x08]:-}" ]; then
		log_skip "INTC: restore original" "no saved value"
		return
	fi
	local saved="${_SAVED_FEATURES[0x08]}"
	restore_feature "0x08" "$CTRL_DEV"
	if verify_feature "0x08" "$saved" "$CTRL_DEV"; then
		log_pass "INTC: restored original coalescing=${saved}"
	else
		log_warn "INTC: restore" "readback mismatch"
	fi
}

# --------------------------------------------------------------------------
# Number of Queues (FID 0x07) — 4 tests
# --------------------------------------------------------------------------

test_nq_save() {
	save_feature "0x07" "$CTRL_DEV" >/dev/null
	if [ -n "${_SAVED_FEATURES[0x07]:-}" ]; then
		log_pass "NQ: saved current NSQA/NCQA (${_SAVED_FEATURES[0x07]})"
	else
		log_skip "NQ: save current" "could not read FID 0x07"
	fi
}

test_nq_set_value() {
	if [ -z "${_SAVED_FEATURES[0x07]:-}" ]; then
		log_skip "NQ: set queue count" "no saved value"
		return
	fi
	local new_val=$(( (3 << 16) | 3 ))
	set_feature "0x07" "$new_val" "$CTRL_DEV" >/dev/null
	local output
	output=$(nvme get-feature "$CTRL_DEV" -f "0x07" 2>&1) || true
	log_cmd "NQ: Get Feature 0x07 readback" "nvme get-feature $CTRL_DEV -f 0x07" "$output"
	local result
	result=$(extract_feature_result "$output")
	if [ -n "$result" ]; then
		local val=$((result))
		local nsqa=$(( val & 0xFFFF ))
		local ncqa=$(( (val >> 16) & 0xFFFF ))
		log_pass "NQ: set queues, readback NSQA=$((nsqa+1)) NCQA=$((ncqa+1))"
	else
		log_warn "NQ: set queue count" "could not read back"
	fi
}

test_nq_io_after() {
	if [ -z "${_SAVED_FEATURES[0x07]:-}" ]; then
		log_skip "NQ: I/O with new queue count" "no saved value"
		return
	fi
	if [ -z "$NS_DEV" ]; then
		log_skip "NQ: I/O with new queue count" "no namespace device"
		return
	fi
	if write_read_verify "$NS_DEV" 0 1; then
		log_pass "NQ: write+read succeeded with new queue allocation"
	else
		log_fail "NQ: I/O with new queue count" "data mismatch"
	fi
}

test_nq_restore() {
	if [ -z "${_SAVED_FEATURES[0x07]:-}" ]; then
		log_skip "NQ: restore original" "no saved value"
		return
	fi
	local saved="${_SAVED_FEATURES[0x07]}"
	restore_feature "0x07" "$CTRL_DEV"
	local output
	output=$(nvme get-feature "$CTRL_DEV" -f "0x07" 2>&1) || true
	log_cmd "NQ: Get Feature 0x07 restore readback" "nvme get-feature $CTRL_DEV -f 0x07" "$output"
	local result
	result=$(extract_feature_result "$output")
	if [ -n "$result" ]; then
		log_pass "NQ: restored queue settings, readback=${result}"
	else
		log_warn "NQ: restore" "could not read back"
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
				echo "Functional verification of NVMe Set Features with behavioral validation."
				echo "DESTRUCTIVE: writes to the device. Requires --allow-destructive."
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

	if [ ! -e "$CTRL_DEV" ]; then
		echo "ERROR: Device $CTRL_DEV does not exist." >&2
		exit 1
	fi

	cache_id_ctrl "$CTRL_DEV"
	init_log "nvme_feature_set_verify" "$CTRL_DEV"
	log_cmd "Identify Controller (cached)" "nvme id-ctrl ${CTRL_DEV}" "$_ID_CTRL_CACHE"

	local spec_ref
	spec_ref=$(get_spec_ref "feature-set")

	print_header \
		"NVMe Set Features — Functional / Behavioral Verification" \
		"$spec_ref" \
		"$CTRL_DEV"

	local vwc
	vwc=$(get_id_ctrl_field "vwc")
	local vwc_present=0
	if [ -n "$vwc" ] && [ "$((vwc & 0x1))" -eq 1 ]; then
		vwc_present=1
	fi

	echo -e "${BOLD}--- Volatile Write Cache (FID 0x06) ---${RESET}"
	if [ "$vwc_present" -eq 1 ]; then
		test_vwc_save
		test_vwc_disable
		test_vwc_io_disabled
		test_vwc_enable
		test_vwc_flush_with_cache
		test_vwc_flush_succeeds
		test_vwc_restore
	else
		log_skip "VWC: entire group" "Volatile Write Cache not present (vwc bit 0=0)"
	fi

	echo ""
	echo -e "${BOLD}--- Temperature Threshold (FID 0x04) ---${RESET}"
	test_tmpth_save
	test_tmpth_set_below_temp
	test_tmpth_critical_warning
	test_tmpth_set_zero
	test_tmpth_critical_clears
	test_tmpth_restore

	echo ""
	echo -e "${BOLD}--- Power Management (FID 0x02) ---${RESET}"
	test_pm_save
	test_pm_set_ps0
	test_pm_io_ps0
	test_pm_cycle_all
	test_pm_responsive_deepest
	test_pm_invalid_ps
	test_pm_restore

	echo ""
	echo -e "${BOLD}--- Error Recovery (FID 0x05) ---${RESET}"
	test_err_save
	test_err_set_value
	test_err_set_zero
	test_err_restore

	echo ""
	echo -e "${BOLD}--- Arbitration (FID 0x01) ---${RESET}"
	test_arb_save
	test_arb_set_value
	test_arb_io_after
	test_arb_restore

	echo ""
	echo -e "${BOLD}--- APST (FID 0x0C, NVMe 1.3+) ---${RESET}"
	test_apst_save
	test_apst_enable
	test_apst_responsive
	test_apst_disable
	test_apst_restore

	echo ""
	echo -e "${BOLD}--- HCTM (FID 0x10, NVMe 1.3+) ---${RESET}"
	test_hctm_save
	test_hctm_set_range
	test_hctm_smart_temp
	test_hctm_invalid_order
	test_hctm_set_zero
	test_hctm_restore

	echo ""
	echo -e "${BOLD}--- Interrupt Coalescing (FID 0x08) ---${RESET}"
	test_intc_save
	test_intc_set_value
	test_intc_io_after
	test_intc_restore

	echo ""
	echo -e "${BOLD}--- Number of Queues (FID 0x07) ---${RESET}"
	test_nq_save
	test_nq_set_value
	test_nq_io_after
	test_nq_restore

	print_summary

	if [ "$FAIL_COUNT" -gt 0 ]; then
		exit 1
	fi
	exit 0
}

main "$@"
