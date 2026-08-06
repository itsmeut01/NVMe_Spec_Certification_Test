#!/bin/bash
# SPDX-License-Identifier: GPL-3.0+
# Copyright (C) 2025 Red Hat, Inc.
#
# NVMe SMART / Health Information Log verification
# Based on NVMe Base Specification, Revision 2.1+
# Section 5.2.13 (2.4) / 5.1.12 (2.1), Figure 214 (2.4) / 206 (2.1)
# SMART / Health Information Log
# Field names from nvme-cli upstream nvme-print-stdout.c
#
# Usage:
#   ./nvme_smart_log_verify.sh /dev/nvme0
#   ./nvme_smart_log_verify.sh /dev/nvme0n1
#   ./nvme_smart_log_verify.sh              # auto-detects first NVMe controller

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/nvme_test_lib.sh
source "${SCRIPT_DIR}/../common/nvme_test_lib.sh"

SMART_LOG=""

smart_get_field() {
	echo "$SMART_LOG" | grep "^$1[[:space:]]" | awk '{ print $3 }' || true
}

smart_get_field_by_label() {
	echo "$SMART_LOG" | grep "^${1}" | sed "s/^${1}[[:space:]]*:[[:space:]]*//" | awk '{ print $1 }' || true
}

smart_field_present() {
	echo "$SMART_LOG" | grep -q "^${1}"
}

smart_get_temp_kelvin() {
	local full_line
	full_line=$(echo "$SMART_LOG" | grep "^temperature[[:space:]]" | head -1)
	[ -z "$full_line" ] && return
	local kelvin_val
	kelvin_val=$(echo "$full_line" | grep -oP '\(\K\d+(?=\s*K)' | head -1)
	if [ -n "$kelvin_val" ] && [ "$kelvin_val" -gt 0 ] 2>/dev/null; then
		echo "$kelvin_val"
		return
	fi
	local raw_val
	raw_val=$(echo "$full_line" | awk '{print $3}' | sed 's/[^0-9]//g')
	if [ -n "$raw_val" ] && [ "$raw_val" -gt 0 ] 2>/dev/null; then
		if [ "$raw_val" -lt 200 ]; then
			echo $((raw_val + 273))
		else
			echo "$raw_val"
		fi
	fi
}

# --------------------------------------------------------------------------
# Test functions
# --------------------------------------------------------------------------

test_critical_warning() {
	local val
	val=$(smart_get_field "critical_warning")
	if [ -n "$val" ]; then
		local cw=$((val))
		local spare_warn=$(( cw & 0x1 ))
		local temp_warn=$(( (cw >> 1) & 0x1 ))
		local reliability=$(( (cw >> 2) & 0x1 ))
		local read_only=$(( (cw >> 3) & 0x1 ))
		local volatile_backup=$(( (cw >> 4) & 0x1 ))
		log_pass "critical_warning is reported (0x$(printf '%02x' "$cw"), spare=${spare_warn} temp=${temp_warn} rel=${reliability} ro=${read_only} vb=${volatile_backup})"
	else
		log_fail "critical_warning is reported" "not present"
	fi
}

test_temperature() {
	local temp_k
	temp_k=$(smart_get_temp_kelvin)
	if [ -z "$temp_k" ] || [ "$temp_k" -eq 0 ] 2>/dev/null; then
		log_fail "temperature (Composite) is reported" "not present or zero"
		return
	fi
	local celsius=$((temp_k - 273))
	local wctemp
	wctemp=$(get_id_ctrl_field "wctemp")
	if [ -n "$wctemp" ] && [ "$wctemp" -gt 0 ] 2>/dev/null && [ "$temp_k" -ge "$wctemp" ]; then
		log_pass "temperature (Composite) is reported (${temp_k}K / ${celsius}C) [WARNING: at or above WCTEMP=${wctemp}K]"
	else
		log_pass "temperature (Composite) is reported (${temp_k}K / ${celsius}C)"
	fi
}

test_available_spare() {
	local val
	val=$(smart_get_field "available_spare")
	if [ -n "$val" ]; then
		local pct
		pct=$(echo "$val" | sed 's/%//')
		log_pass "available_spare is reported (${pct}%)"
	else
		log_fail "available_spare is reported" "not present"
	fi
}

test_available_spare_threshold() {
	local val
	val=$(smart_get_field "available_spare_threshold")
	if [ -n "$val" ]; then
		local pct
		pct=$(echo "$val" | sed 's/%//')
		log_pass "available_spare_threshold is reported (${pct}%)"
	else
		log_fail "available_spare_threshold is reported" "not present"
	fi
}

test_percentage_used() {
	local val
	val=$(smart_get_field "percentage_used")
	if [ -n "$val" ]; then
		local pct
		pct=$(echo "$val" | sed 's/%//')
		log_pass "percentage_used is reported (${pct}%)"
	else
		log_fail "percentage_used is reported" "not present"
	fi
}

test_data_units_read() {
	if smart_field_present "Data Units Read"; then
		local val
		val=$(smart_get_field_by_label "Data Units Read")
		log_pass "Data Units Read is reported (${val})"
	else
		log_fail "Data Units Read is reported" "not present"
	fi
}

test_data_units_written() {
	if smart_field_present "Data Units Written"; then
		local val
		val=$(smart_get_field_by_label "Data Units Written")
		log_pass "Data Units Written is reported (${val})"
	else
		log_fail "Data Units Written is reported" "not present"
	fi
}

test_host_read_commands() {
	local val
	val=$(smart_get_field "host_read_commands")
	if [ -n "$val" ]; then
		log_pass "host_read_commands is reported (${val})"
	else
		log_fail "host_read_commands is reported" "not present"
	fi
}

test_host_write_commands() {
	local val
	val=$(smart_get_field "host_write_commands")
	if [ -n "$val" ]; then
		log_pass "host_write_commands is reported (${val})"
	else
		log_fail "host_write_commands is reported" "not present"
	fi
}

test_controller_busy_time() {
	local val
	val=$(smart_get_field "controller_busy_time")
	if [ -n "$val" ]; then
		log_pass "controller_busy_time is reported (${val})"
	else
		log_fail "controller_busy_time is reported" "not present"
	fi
}

test_power_cycles() {
	local val
	val=$(smart_get_field "power_cycles")
	if [ -n "$val" ]; then
		if [ "$val" -gt 0 ] 2>/dev/null; then
			log_pass "power_cycles is reported and non-zero (${val})"
		else
			log_pass "power_cycles is reported (${val})"
		fi
	else
		log_fail "power_cycles is reported" "not present"
	fi
}

test_power_on_hours() {
	local val
	val=$(smart_get_field "power_on_hours")
	if [ -n "$val" ]; then
		log_pass "power_on_hours is reported (${val})"
	else
		log_fail "power_on_hours is reported" "not present"
	fi
}

test_unsafe_shutdowns() {
	local val
	val=$(smart_get_field "unsafe_shutdowns")
	if [ -n "$val" ]; then
		log_pass "unsafe_shutdowns is reported (${val})"
	else
		log_fail "unsafe_shutdowns is reported" "not present"
	fi
}

test_media_errors() {
	local val
	val=$(smart_get_field "media_errors")
	if [ -n "$val" ]; then
		log_pass "media_errors is reported (${val})"
	else
		log_fail "media_errors is reported" "not present"
	fi
}

test_num_err_log_entries() {
	local val
	val=$(smart_get_field "num_err_log_entries")
	if [ -n "$val" ]; then
		log_pass "num_err_log_entries is reported (${val})"
	else
		log_fail "num_err_log_entries is reported" "not present"
	fi
}

test_warning_temp_time() {
	if smart_field_present "Warning Temperature Time"; then
		local val
		val=$(smart_get_field_by_label "Warning Temperature Time")
		log_pass "Warning Temperature Time is reported (${val} minutes)"
	else
		log_fail "Warning Temperature Time is reported" "not present"
	fi
}

test_critical_comp_temp_time() {
	if smart_field_present "Critical Composite Temperature Time"; then
		local val
		val=$(smart_get_field_by_label "Critical Composite Temperature Time")
		log_pass "Critical Composite Temperature Time is reported (${val} minutes)"
	else
		log_fail "Critical Composite Temperature Time is reported" "not present"
	fi
}

test_temp_sensors() {
	local count=0
	local i
	for i in 1 2 3 4 5 6 7 8; do
		if smart_field_present "Temperature Sensor ${i}"; then
			count=$((count + 1))
		fi
	done
	if [ "$count" -gt 0 ]; then
		log_pass "Temperature Sensors reported (${count} sensor(s) present)"
	else
		log_skip "Temperature Sensors reported" "no optional temperature sensors found"
	fi
}

test_thm_t1_trans_count() {
	if ! ver_at_least 1 3; then
		log_skip "Thermal Management T1 Trans Count is reported" "requires NVMe 1.3+"
		return
	fi
	if smart_field_present "Thermal Management T1 Trans Count"; then
		local val
		val=$(smart_get_field_by_label "Thermal Management T1 Trans Count")
		log_pass "Thermal Management T1 Trans Count is reported (${val})"
	else
		log_fail "Thermal Management T1 Trans Count is reported" "not present"
	fi
}

test_thm_t2_trans_count() {
	if ! ver_at_least 1 3; then
		log_skip "Thermal Management T2 Trans Count is reported" "requires NVMe 1.3+"
		return
	fi
	if smart_field_present "Thermal Management T2 Trans Count"; then
		local val
		val=$(smart_get_field_by_label "Thermal Management T2 Trans Count")
		log_pass "Thermal Management T2 Trans Count is reported (${val})"
	else
		log_fail "Thermal Management T2 Trans Count is reported" "not present"
	fi
}

test_thm_t1_total_time() {
	if ! ver_at_least 1 3; then
		log_skip "Thermal Management T1 Total Time is reported" "requires NVMe 1.3+"
		return
	fi
	if smart_field_present "Thermal Management T1 Total Time"; then
		local val
		val=$(smart_get_field_by_label "Thermal Management T1 Total Time")
		log_pass "Thermal Management T1 Total Time is reported (${val})"
	else
		log_fail "Thermal Management T1 Total Time is reported" "not present"
	fi
}

test_thm_t2_total_time() {
	if ! ver_at_least 1 3; then
		log_skip "Thermal Management T2 Total Time is reported" "requires NVMe 1.3+"
		return
	fi
	if smart_field_present "Thermal Management T2 Total Time"; then
		local val
		val=$(smart_get_field_by_label "Thermal Management T2 Total Time")
		log_pass "Thermal Management T2 Total Time is reported (${val})"
	else
		log_fail "Thermal Management T2 Total Time is reported" "not present"
	fi
}

# --------------------------------------------------------------------------
# Deep Validation Tests (--full mode only)
# --------------------------------------------------------------------------

test_spare_vs_threshold() {
	local spare thresh cw
	spare=$(smart_get_field "available_spare")
	thresh=$(smart_get_field "available_spare_threshold")
	cw=$(smart_get_field "critical_warning")
	if [ -z "$spare" ] || [ -z "$thresh" ] || [ -z "$cw" ]; then
		log_skip "Spare vs threshold cross-check" "fields not available"
		return
	fi
	local spare_pct thresh_pct
	spare_pct=$(echo "$spare" | sed 's/%//')
	thresh_pct=$(echo "$thresh" | sed 's/%//')
	local cw_int=$((cw))
	local spare_bit=$(( cw_int & 0x1 ))
	if [ "$spare_pct" -lt "$thresh_pct" ] 2>/dev/null; then
		if [ "$spare_bit" -eq 1 ]; then
			log_pass "Spare (${spare_pct}%) < threshold (${thresh_pct}%): critical_warning bit 0 correctly set"
		else
			log_fail "Spare < threshold but critical_warning bit 0 not set" "spare=${spare_pct}% thresh=${thresh_pct}% cw=0x$(printf '%02x' "$cw_int")"
		fi
	else
		log_pass "Spare (${spare_pct}%) >= threshold (${thresh_pct}%): no spare warning expected"
	fi
}

test_temp_vs_wctemp() {
	local cw
	cw=$(smart_get_field "critical_warning")
	local temp_k
	temp_k=$(smart_get_temp_kelvin)
	local wctemp
	wctemp=$(get_id_ctrl_field "wctemp")
	if [ -z "$temp_k" ] || [ -z "$wctemp" ] || [ "$wctemp" -eq 0 ] 2>/dev/null || [ -z "$cw" ]; then
		log_skip "Temperature vs WCTEMP cross-check" "temperature or WCTEMP not available"
		return
	fi
	local cw_int=$((cw))
	local temp_bit=$(( (cw_int >> 1) & 0x1 ))
	if [ "$temp_k" -ge "$wctemp" ] 2>/dev/null; then
		if [ "$temp_bit" -eq 1 ]; then
			log_pass "Temp (${temp_k}K) >= WCTEMP (${wctemp}K): critical_warning bit 1 correctly set"
		else
			log_warn "Temp >= WCTEMP but critical_warning bit 1 not set" "temp=${temp_k}K wctemp=${wctemp}K cw=0x$(printf '%02x' "$cw_int")"
		fi
	else
		log_pass "Temp (${temp_k}K) < WCTEMP (${wctemp}K): no temperature warning expected"
	fi
}

test_temperature_range() {
	local temp_k
	temp_k=$(smart_get_temp_kelvin)
	if [ -z "$temp_k" ]; then
		log_skip "Temperature range check" "could not parse temperature"
		return
	fi
	if [ "$temp_k" -ge 250 ] && [ "$temp_k" -le 400 ]; then
		log_pass "Temperature (${temp_k}K / $(( temp_k - 273 ))C) within typical range 250K-400K"
	else
		log_warn "Temperature outside typical range" "${temp_k}K not in 250K-400K"
	fi
}

test_percentage_used_warning() {
	local val
	val=$(smart_get_field "percentage_used")
	if [ -z "$val" ]; then
		log_skip "Percentage used warning" "not available"
		return
	fi
	local pct
	pct=$(echo "$val" | sed 's/%//')
	if [ "$pct" -gt 100 ] 2>/dev/null; then
		log_warn "Percentage used exceeds 100%" "percentage_used=${pct}% — drive may be past rated endurance"
	else
		log_pass "Percentage used (${pct}%) within normal range"
	fi
}

test_num_err_cross_validate() {
	local smart_errs
	smart_errs=$(smart_get_field "num_err_log_entries")
	if [ -z "$smart_errs" ]; then
		log_skip "Error count cross-validation with error-log" "num_err_log_entries not available"
		return
	fi
	local smart_errs_int=$((smart_errs))
	local ctrl_dev
	ctrl_dev=$(echo "$_LOG_DEVICE" | sed 's|n[0-9]*$||')
	if [ -z "$ctrl_dev" ]; then
		log_skip "Error count cross-validation with error-log" "could not determine controller"
		return
	fi
	local error_log
	error_log=$(nvme error-log "$ctrl_dev" 2>/dev/null) || true
	if [ -z "$error_log" ]; then
		log_skip "Error count cross-validation with error-log" "could not read error-log"
		return
	fi
	local entry_count
	entry_count=$(echo "$error_log" | grep -c "^ Entry\[" || true)
	if [ "$smart_errs_int" -eq 0 ] && [ "$entry_count" -eq 0 ]; then
		log_pass "No errors in SMART (0) and no entries in error-log — consistent"
	elif [ "$smart_errs_int" -gt 0 ] && [ "$entry_count" -gt 0 ]; then
		log_pass "SMART num_err_log_entries=${smart_errs_int}, error-log has ${entry_count} entries — consistent"
	elif [ "$smart_errs_int" -gt 0 ] && [ "$entry_count" -eq 0 ]; then
		log_pass "SMART reports ${smart_errs_int} errors but error-log empty — entries may have been cleared"
	else
		log_warn "Error count mismatch" "SMART=0 but error-log has ${entry_count} entries"
	fi
}

# --------------------------------------------------------------------------
# NVMe 2.4 SMART fields (bytes 544+)
# --------------------------------------------------------------------------

test_olec() {
	if ! ver_at_least 2 4; then
		log_skip "Outstanding LBA Error Count (OLEC)" "requires NVMe 2.4+"
		return
	fi
	local val
	val=$(echo "$SMART_LOG" | grep -i "outstanding.*lba\|olec" | grep -oP '[0-9,]+' | head -1 | tr -d ',')
	if [ -z "$val" ]; then
		val=$(echo "$SMART_JSON" | grep -oP '"olec"\s*:\s*\K[0-9]+' 2>/dev/null || true)
	fi
	if [ -z "$val" ]; then
		log_skip "Outstanding LBA Error Count (OLEC)" "not in nvme-cli output (needs newer nvme-cli)"
		return
	fi
	if [ "$val" -eq 0 ]; then
		log_pass "Outstanding LBA Error Count (OLEC) = 0 — no outstanding LBA errors"
	else
		log_pass "Outstanding LBA Error Count (OLEC) = ${val}"
	fi
}

test_ipm() {
	if ! ver_at_least 2 4; then
		log_skip "Idle Power Mode (IPM)" "requires NVMe 2.4+"
		return
	fi
	local val
	val=$(echo "$SMART_LOG" | grep -i "idle.*power\|ipm" | grep -oP '[0-9,]+' | head -1 | tr -d ',')
	if [ -z "$val" ]; then
		val=$(echo "$SMART_JSON" | grep -oP '"ipm"\s*:\s*\K[0-9]+' 2>/dev/null || true)
	fi
	if [ -z "$val" ]; then
		log_skip "Idle Power Mode (IPM)" "not in nvme-cli output (needs newer nvme-cli)"
		return
	fi
	log_pass "Idle Power Mode (IPM) = ${val}"
}

test_infw() {
	if ! ver_at_least 2 4; then
		log_skip "Informational NVM Firmware Warnings (INFW)" "requires NVMe 2.4+"
		return
	fi
	local val
	val=$(echo "$SMART_LOG" | grep -i "informational.*nvm\|infw" | grep -oP '[0-9,]+' | head -1 | tr -d ',')
	if [ -z "$val" ]; then
		val=$(echo "$SMART_JSON" | grep -oP '"infw"\s*:\s*\K[0-9]+' 2>/dev/null || true)
	fi
	if [ -z "$val" ]; then
		log_skip "Informational NVM Firmware Warnings (INFW)" "not in nvme-cli output (needs newer nvme-cli)"
		return
	fi
	log_pass "Informational NVM Firmware Warnings (INFW) = ${val}"
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
		echo "Verifies NVMe SMART / Health Information Log per NVMe Base Spec 2.1+."
		exit 0
	else
		ctrl_dev=$(resolve_ctrl_dev "$1")
	fi

	if [ ! -e "$ctrl_dev" ]; then
		echo "ERROR: Device $ctrl_dev does not exist." >&2
		exit 1
	fi

	cache_id_ctrl "$ctrl_dev"
	init_log "nvme_smart_log_verify" "$ctrl_dev"
	log_cmd "Identify Controller (cached)" "nvme id-ctrl ${ctrl_dev}" "$_ID_CTRL_CACHE"

	local spec_ref
	spec_ref=$(get_spec_ref "smart-log")

	print_header \
		"NVMe SMART / Health Information Log — Verification" \
		"$spec_ref" \
		"$ctrl_dev"

	SMART_LOG=$(nvme smart-log "$ctrl_dev" 2>&1)
	if [ $? -ne 0 ]; then
		echo "ERROR: Failed to run 'nvme smart-log ${ctrl_dev}':" >&2
		echo "$SMART_LOG" >&2
		exit 1
	fi
	log_cmd "SMART / Health Information Log" "nvme smart-log ${ctrl_dev}" "$SMART_LOG"
	SMART_JSON=$(nvme smart-log "$ctrl_dev" -o json 2>/dev/null || true)

	echo -e "${BOLD}--- Critical Warning & Temperature ---${RESET}"
	test_critical_warning
	test_temperature
	test_available_spare
	test_available_spare_threshold
	test_percentage_used

	echo ""
	echo -e "${BOLD}--- Data Units & Host Commands ---${RESET}"
	test_data_units_read
	test_data_units_written
	test_host_read_commands
	test_host_write_commands

	echo ""
	echo -e "${BOLD}--- Controller Lifecycle ---${RESET}"
	test_controller_busy_time
	test_power_cycles
	test_power_on_hours
	test_unsafe_shutdowns
	test_media_errors
	test_num_err_log_entries

	echo ""
	echo -e "${BOLD}--- Temperature History & Thermal Management ---${RESET}"
	test_warning_temp_time
	test_critical_comp_temp_time
	test_temp_sensors
	test_thm_t1_trans_count
	test_thm_t2_trans_count
	test_thm_t1_total_time
	test_thm_t2_total_time

	echo ""
	echo -e "${BOLD}--- NVMe 2.4 Extended SMART Fields ---${RESET}"
	test_olec
	test_ipm
	test_infw

	echo ""
	echo -e "${BOLD}--- Cross-Validation Checks ---${RESET}"
	test_spare_vs_threshold
	test_temp_vs_wctemp
	test_temperature_range
	test_percentage_used_warning
	test_num_err_cross_validate

	print_summary

	if [ "$FAIL_COUNT" -gt 0 ]; then
		exit 1
	fi
	exit 0
}

main "$@"
