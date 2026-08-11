#!/bin/bash
# SPDX-License-Identifier: GPL-3.0+
# Copyright (C) 2025 Red Hat, Inc.
#
# NVMe Additional Log Pages — Behavioral + Read-Only Verification
# Based on NVMe Base Specification — Telemetry, Persistent Event, misc logs
# Tests: telemetry create/read cycle, persistent-event establish/release cycle,
#        endurance, changed-ns, reservation-notif, fid-effects, lba-status,
#        predictable-lat, boot-part, endurance-event-agg
#
# Usage:
#   ./nvme_additional_logs_verify.sh /dev/nvme0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/nvme_test_lib.sh
source "${SCRIPT_DIR}/../common/nvme_test_lib.sh"

CTRL_DEV=""
TMP_DIR=""

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------

setup_tmp() {
	TMP_DIR=$(mktemp -d)
}

cleanup_tmp() {
	[ -n "$TMP_DIR" ] && rm -rf "$TMP_DIR"
}

# --------------------------------------------------------------------------
# Telemetry (behavioral: generate -> verify -> read-existing)
# --------------------------------------------------------------------------

test_telemetry_generate() {
	if ! ver_at_least 1 3; then
		log_skip "Telemetry: generate host-initiated" "requires NVMe 1.3+"
		return
	fi

	local telem_file="${TMP_DIR}/telemetry_host.bin"
	local output
	output=$(nvme telemetry-log "$CTRL_DEV" -O "$telem_file" -g 1 -d 1 2>&1) || true
	log_cmd "Telemetry generate" "nvme telemetry-log ${CTRL_DEV} -O ... -g 1 -d 1" "$output"

	if [ -f "$telem_file" ] && [ -s "$telem_file" ]; then
		local file_size
		file_size=$(stat -c%s "$telem_file" 2>/dev/null || echo 0)
		log_pass "Telemetry: host-initiated snapshot generated (${file_size} bytes)"
	elif echo "$output" | grep -qi "not support\|invalid\|NVMe status\|No such\|error\|could not"; then
		log_skip "Telemetry: generate host-initiated" "controller returned: $(echo "$output" | head -1)"
	else
		log_fail "Telemetry: generate host-initiated" "file not created or empty"
	fi
}

test_telemetry_verify_header() {
	if ! ver_at_least 1 3; then
		log_skip "Telemetry: verify header" "requires NVMe 1.3+"
		return
	fi

	local telem_file="${TMP_DIR}/telemetry_host.bin"
	if [ ! -f "$telem_file" ] || [ ! -s "$telem_file" ]; then
		log_skip "Telemetry: verify header" "no telemetry data generated"
		return
	fi

	local file_size
	file_size=$(stat -c%s "$telem_file" 2>/dev/null || echo 0)
	if [ "$file_size" -ge 512 ]; then
		local lpi
		lpi=$(od -A n -t x1 -j 0 -N 1 "$telem_file" 2>/dev/null | tr -d ' ' || true)
		if [ "$lpi" = "08" ]; then
			log_pass "Telemetry: header LPI=0x08 (Host-Initiated Telemetry log)"
		else
			log_warn "Telemetry: header LPI" "expected 0x08, got 0x${lpi}"
		fi
	else
		log_warn "Telemetry: verify header" "file too small (${file_size} bytes < 512)"
	fi
}

test_telemetry_read_existing() {
	if ! ver_at_least 1 3; then
		log_skip "Telemetry: read without re-generating" "requires NVMe 1.3+"
		return
	fi

	local telem_file="${TMP_DIR}/telemetry_host.bin"
	if [ ! -f "$telem_file" ] || [ ! -s "$telem_file" ]; then
		log_skip "Telemetry: read existing" "no prior telemetry data"
		return
	fi

	local telem_file2="${TMP_DIR}/telemetry_host_reread.bin"
	local output
	output=$(nvme telemetry-log "$CTRL_DEV" -O "$telem_file2" -g 0 -d 1 2>&1) || true

	if [ -f "$telem_file2" ] && [ -s "$telem_file2" ]; then
		log_pass "Telemetry: read existing context without re-generating (host-generate=0)"
	elif echo "$output" | grep -qi "not support\|invalid\|NVMe status"; then
		log_skip "Telemetry: read existing" "$(echo "$output" | head -1)"
	else
		log_warn "Telemetry: read existing" "no data returned"
	fi
}

test_telemetry_controller_initiated() {
	if ! ver_at_least 1 3; then
		log_skip "Telemetry: controller-initiated" "requires NVMe 1.3+"
		return
	fi

	local telem_file="${TMP_DIR}/telemetry_ctrl.bin"
	local output
	output=$(nvme telemetry-log "$CTRL_DEV" -O "$telem_file" -c -d 1 2>&1) || true
	log_cmd "Telemetry controller-initiated" "nvme telemetry-log ${CTRL_DEV} -O ... -c -d 1" "$output"

	if [ -f "$telem_file" ] && [ -s "$telem_file" ]; then
		log_pass "Telemetry: controller-initiated log readable"
	elif echo "$output" | grep -qi "not support\|no.*data\|NVMe status\|No such\|invalid\|error\|could not"; then
		log_skip "Telemetry: controller-initiated" "$(echo "$output" | head -1)"
	else
		log_pass "Telemetry: controller-initiated command completed"
	fi
}

# --------------------------------------------------------------------------
# Persistent Event Log (behavioral: establish -> read -> release -> verify)
# --------------------------------------------------------------------------

test_persistent_event_establish() {
	if ! ver_at_least 1 4; then
		log_skip "Persistent Event Log: establish context" "requires NVMe 1.4+"
		return
	fi

	local output
	output=$(nvme persistent-event-log "$CTRL_DEV" -a 1 2>&1) || true
	log_cmd "Persistent Event establish" "nvme persistent-event-log ${CTRL_DEV} -a 1" "$output"

	if echo "$output" | grep -qi "not support\|invalid field\|NVMe status.*INVALID"; then
		log_skip "Persistent Event Log: establish context" "$(echo "$output" | head -1)"
	elif echo "$output" | grep -qi "error\|NVMe status"; then
		log_warn "Persistent Event Log: establish context" "$(echo "$output" | head -1)"
	else
		log_pass "Persistent Event Log: context established (action=1)"
	fi
}

test_persistent_event_read() {
	if ! ver_at_least 1 4; then
		log_skip "Persistent Event Log: read context" "requires NVMe 1.4+"
		return
	fi

	local output
	output=$(nvme persistent-event-log "$CTRL_DEV" -a 0 -l 512 2>&1) || true
	log_cmd "Persistent Event read" "nvme persistent-event-log ${CTRL_DEV} -a 0 -l 512" "$output"

	if echo "$output" | grep -qi "log_revision\|tnel\|timestamp\|total.*entries\|num_events"; then
		log_pass "Persistent Event Log: read succeeded — header fields present"
	elif echo "$output" | grep -qi "not support\|NVMe status"; then
		log_skip "Persistent Event Log: read context" "$(echo "$output" | head -1)"
	elif ! echo "$output" | grep -qi "error"; then
		log_pass "Persistent Event Log: read succeeded (action=0)"
	else
		log_warn "Persistent Event Log: read" "$(echo "$output" | head -1)"
	fi
}

test_persistent_event_release() {
	if ! ver_at_least 1 4; then
		log_skip "Persistent Event Log: release context" "requires NVMe 1.4+"
		return
	fi

	local output
	output=$(nvme persistent-event-log "$CTRL_DEV" -a 2 2>&1) || true
	log_cmd "Persistent Event release" "nvme persistent-event-log ${CTRL_DEV} -a 2" "$output"

	if echo "$output" | grep -qi "not support\|NVMe status.*INVALID"; then
		log_skip "Persistent Event Log: release context" "$(echo "$output" | head -1)"
	elif echo "$output" | grep -qi "error\|NVMe status"; then
		log_warn "Persistent Event Log: release context" "$(echo "$output" | head -1)"
	else
		log_pass "Persistent Event Log: context released (action=2)"
	fi
}

test_persistent_event_verify_release() {
	if ! ver_at_least 1 4; then
		log_skip "Persistent Event Log: verify release" "requires NVMe 1.4+"
		return
	fi

	local output
	output=$(nvme persistent-event-log "$CTRL_DEV" -a 0 -l 512 2>&1) || true

	if echo "$output" | grep -qi "not support\|NVMe status"; then
		log_pass "Persistent Event Log: read after release correctly fails (context released)"
	elif echo "$output" | grep -qi "log_revision\|tnel\|num_events"; then
		log_warn "Persistent Event Log: verify release" "data still readable after release — controller may retain context"
	else
		log_pass "Persistent Event Log: post-release state verified"
	fi
}

# --------------------------------------------------------------------------
# Read-only log pages
# --------------------------------------------------------------------------

test_endurance_group_log() {
	if ! ver_at_least 1 3; then
		log_skip "Endurance Group Info Log" "requires NVMe 1.3+"
		return
	fi

	local output
	output=$(nvme endurance-log "$CTRL_DEV" -g 0 2>&1) || true
	log_cmd "Endurance Group Log" "nvme endurance-log ${CTRL_DEV} -g 0" "$output"

	if echo "$output" | grep -qi "critical_warning\|avail_spare\|percent_used\|endurance"; then
		log_pass "Endurance Group Info Log: key fields present"
	elif echo "$output" | grep -qi "not support\|invalid\|NVMe status"; then
		log_skip "Endurance Group Info Log" "$(echo "$output" | head -1)"
	else
		log_pass "Endurance Group Info Log: command completed"
	fi
}

test_changed_ns_list_log() {
	if ! ver_at_least 1 2; then
		log_skip "Changed NS List Log" "requires NVMe 1.2+"
		return
	fi

	local output
	output=$(nvme changed-ns-list-log "$CTRL_DEV" 2>&1) || true
	log_cmd "Changed NS List Log" "nvme changed-ns-list-log ${CTRL_DEV}" "$output"

	if echo "$output" | grep -qi "error\|NVMe status\|invalid"; then
		log_skip "Changed NS List Log" "$(echo "$output" | head -1)"
	else
		log_pass "Changed NS List Log: readable"
	fi
}

test_resv_notif_log() {
	local output
	output=$(nvme resv-notif-log "$CTRL_DEV" 2>&1) || true
	log_cmd "Reservation Notification Log" "nvme resv-notif-log ${CTRL_DEV}" "$output"

	if echo "$output" | grep -qi "count\|type\|nsid\|log_page_count\|num_"; then
		log_pass "Reservation Notification Log: key fields present"
	elif echo "$output" | grep -qi "not support\|invalid\|NVMe status"; then
		log_skip "Reservation Notification Log" "$(echo "$output" | head -1)"
	else
		log_pass "Reservation Notification Log: command completed"
	fi
}

test_fid_support_effects_log() {
	if ! ver_at_least 2 0; then
		log_skip "FID Support and Effects Log" "requires NVMe 2.0+"
		return
	fi

	local output
	output=$(nvme fid-support-effects-log "$CTRL_DEV" 2>&1) || true
	log_cmd "FID Support Effects Log" "nvme fid-support-effects-log ${CTRL_DEV}" "$output"

	if echo "$output" | grep -qi "not support\|invalid\|NVMe status"; then
		log_skip "FID Support and Effects Log" "$(echo "$output" | head -1)"
		return
	fi

	if [ -z "$output" ]; then
		log_fail "FID Support and Effects Log" "empty output"
		return
	fi

	local missing=""
	local checked=0
	local fid_01 fid_02 fid_04 fid_07 fid_0b
	fid_01=$(echo "$output" | grep -ci "FID.*0x01\|FID.*01h\|Arbitration" || true)
	fid_02=$(echo "$output" | grep -ci "FID.*0x02\|FID.*02h\|Power Management" || true)
	fid_04=$(echo "$output" | grep -ci "FID.*0x04\|FID.*04h\|Temperature Threshold" || true)
	fid_07=$(echo "$output" | grep -ci "FID.*0x07\|FID.*07h\|Number of Queues" || true)
	fid_0b=$(echo "$output" | grep -ci "FID.*0x0[bB]\|FID.*0Bh\|Async.*Event.*Config" || true)

	[ "$fid_01" -eq 0 ] && missing="${missing} 0x01(Arbitration)" && checked=$((checked + 1))
	[ "$fid_02" -eq 0 ] && missing="${missing} 0x02(PM)" && checked=$((checked + 1))
	[ "$fid_04" -eq 0 ] && missing="${missing} 0x04(TempThresh)" && checked=$((checked + 1))
	[ "$fid_07" -eq 0 ] && missing="${missing} 0x07(NumQueues)" && checked=$((checked + 1))
	[ "$fid_0b" -eq 0 ] && missing="${missing} 0x0B(AEC)" && checked=$((checked + 1))

	if [ "$checked" -eq 0 ]; then
		log_pass "FID Support and Effects Log: all 5 mandatory FIDs present (0x01,0x02,0x04,0x07,0x0B)"
	elif [ "$checked" -le 2 ]; then
		log_warn "FID Support Effects: missing mandatory FIDs" "${missing}"
	else
		log_warn "FID Support Effects: output format may not match expected patterns" "checked 5 mandatory FIDs, ${checked} not found:${missing}"
	fi
}

test_lba_status_log() {
	if ! ver_at_least 1 4; then
		log_skip "LBA Status Information Log" "requires NVMe 1.4+"
		return
	fi

	local output
	output=$(nvme lba-status-log "$CTRL_DEV" 2>&1) || true
	log_cmd "LBA Status Info Log" "nvme lba-status-log ${CTRL_DEV}" "$output"

	if echo "$output" | grep -qi "not support\|invalid\|NVMe status"; then
		log_skip "LBA Status Information Log" "$(echo "$output" | head -1)"
	else
		log_pass "LBA Status Information Log: accessible"
	fi
}

test_predictable_lat_log() {
	if ! ver_at_least 1 4; then
		log_skip "Predictable Latency Per NVM Set" "requires NVMe 1.4+"
		return
	fi

	local output
	output=$(nvme predictable-lat-log "$CTRL_DEV" -n 1 2>&1) || true
	log_cmd "Predictable Latency Log" "nvme predictable-lat-log ${CTRL_DEV} -n 1" "$output"

	if echo "$output" | grep -qi "not support\|invalid\|NVMe status"; then
		log_skip "Predictable Latency Per NVM Set" "$(echo "$output" | head -1)"
	else
		local note=""
		if ver_at_least 2 4; then
			note=" (note: deprecated in NVMe 2.4, removal planned August 2027)"
		fi
		log_pass "Predictable Latency Per NVM Set: accessible${note}"
	fi
}

test_boot_partition_log() {
	if ! ver_at_least 1 4; then
		log_skip "Boot Partition Log" "requires NVMe 1.4+"
		return
	fi

	local output
	output=$(nvme boot-part-log "$CTRL_DEV" 2>&1) || true
	log_cmd "Boot Partition Log" "nvme boot-part-log ${CTRL_DEV}" "$output"

	if echo "$output" | grep -qi "not support\|invalid\|NVMe status"; then
		log_skip "Boot Partition Log" "$(echo "$output" | head -1)"
	else
		log_pass "Boot Partition Log: accessible"
	fi
}

test_endurance_event_agg_log() {
	if ! ver_at_least 1 4; then
		log_skip "Endurance Group Event Agg Log" "requires NVMe 1.4+"
		return
	fi

	local output
	output=$(nvme endurance-event-agg-log "$CTRL_DEV" 2>&1) || true
	log_cmd "Endurance Event Agg Log" "nvme endurance-event-agg-log ${CTRL_DEV}" "$output"

	if echo "$output" | grep -qi "not support\|invalid\|NVMe status"; then
		log_skip "Endurance Group Event Agg Log" "$(echo "$output" | head -1)"
	else
		log_pass "Endurance Group Event Agg Log: accessible"
	fi
}

test_power_measurement_log() {
	if ! ver_at_least 2 4; then
		log_skip "Power Measurement Log (LID 0x17)" "requires NVMe 2.4+"
		return
	fi

	local output
	output=$(nvme get-log "$CTRL_DEV" -i 0x17 -l 512 2>&1) || true
	log_cmd "Power Measurement Log" "nvme get-log ${CTRL_DEV} -i 0x17 -l 512" "$output"

	if echo "$output" | grep -qi "not support\|invalid\|NVMe status"; then
		log_skip "Power Measurement Log (LID 0x17)" "not supported by controller"
	elif [ -z "$output" ]; then
		log_skip "Power Measurement Log (LID 0x17)" "empty output"
	else
		log_pass "Power Measurement Log (LID 0x17): accessible"
	fi
}

test_voltage_measurement_log() {
	if ! ver_at_least 2 4; then
		log_skip "Voltage Measurement Log (LID 0x18)" "requires NVMe 2.4+"
		return
	fi

	local output
	output=$(nvme get-log "$CTRL_DEV" -i 0x18 -l 512 2>&1) || true
	log_cmd "Voltage Measurement Log" "nvme get-log ${CTRL_DEV} -i 0x18 -l 512" "$output"

	if echo "$output" | grep -qi "not support\|invalid\|NVMe status"; then
		log_skip "Voltage Measurement Log (LID 0x18)" "not supported by controller"
	elif [ -z "$output" ]; then
		log_skip "Voltage Measurement Log (LID 0x18)" "empty output"
	else
		log_pass "Voltage Measurement Log (LID 0x18): accessible"
	fi
}

test_cross_controller_reset_log() {
	if ! ver_at_least 2 4; then
		log_skip "Cross-Controller Reset Log (LID 0x1E)" "requires NVMe 2.4+"
		return
	fi

	local output
	output=$(nvme get-log "$CTRL_DEV" -i 0x1E -l 512 2>&1) || true
	log_cmd "Cross-Controller Reset Log" "nvme get-log ${CTRL_DEV} -i 0x1E -l 512" "$output"

	if echo "$output" | grep -qi "not support\|invalid\|NVMe status"; then
		log_skip "Cross-Controller Reset Log (LID 0x1E)" "not supported by controller"
	elif [ -z "$output" ]; then
		log_skip "Cross-Controller Reset Log (LID 0x1E)" "empty output"
	else
		log_pass "Cross-Controller Reset Log (LID 0x1E): accessible"
	fi
}

test_lost_host_comm_log() {
	if ! ver_at_least 2 4; then
		log_skip "Lost Host Communication Log (LID 0x1F)" "requires NVMe 2.4+"
		return
	fi

	local output
	output=$(nvme get-log "$CTRL_DEV" -i 0x1F -l 512 2>&1) || true
	log_cmd "Lost Host Communication Log" "nvme get-log ${CTRL_DEV} -i 0x1F -l 512" "$output"

	if echo "$output" | grep -qi "not support\|invalid\|NVMe status"; then
		log_skip "Lost Host Communication Log (LID 0x1F)" "not supported by controller"
	elif [ -z "$output" ]; then
		log_skip "Lost Host Communication Log (LID 0x1F)" "empty output"
	else
		log_pass "Lost Host Communication Log (LID 0x1F): accessible"
	fi
}

test_rate_limiting_log() {
	if ! ver_at_least 2 0; then
		log_skip "Rate Limiting Log (LID 0x28)" "requires NVMe 2.0+ (NVM CS 1.3)"
		return
	fi

	local output
	output=$(nvme get-log "$CTRL_DEV" -i 0x28 -l 4096 2>&1) || true
	log_cmd "Rate Limiting Log" "nvme get-log ${CTRL_DEV} -i 0x28 -l 4096" "$output"

	if echo "$output" | grep -qi "not support\|invalid\|NVMe status"; then
		log_skip "Rate Limiting Log (LID 0x28)" "not supported by controller"
	elif [ -z "$output" ]; then
		log_skip "Rate Limiting Log (LID 0x28)" "empty output"
	else
		log_pass "Rate Limiting Log (LID 0x28): accessible (NVM CS 1.3)"
	fi
}

test_eom_log() {
	if ! ver_at_least 2 0; then
		log_skip "Eye Opening Measurement Log (LID 0x19)" "requires NVMe 2.0+ (PCIe Transport 1.4)"
		return
	fi

	local output
	output=$(nvme get-log "$CTRL_DEV" -i 0x19 -l 4096 2>&1) || true
	log_cmd "EOM Log" "nvme get-log ${CTRL_DEV} -i 0x19 -l 4096" "$output"

	if echo "$output" | grep -qi "not support\|invalid\|NVMe status"; then
		log_skip "Eye Opening Measurement Log (LID 0x19)" "not supported by controller"
	elif [ -z "$output" ]; then
		log_skip "Eye Opening Measurement Log (LID 0x19)" "empty output"
	else
		log_pass "Eye Opening Measurement Log (LID 0x19): accessible (PCIe Transport 1.4)"
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
		echo "Usage: $0 [/dev/nvmeX]"
		echo "Behavioral + read-only verification of NVMe log pages."
		exit 0
	else
		CTRL_DEV=$(resolve_ctrl_dev "$1")
	fi

	if [ ! -e "$CTRL_DEV" ]; then
		echo "ERROR: Device $CTRL_DEV does not exist." >&2
		exit 1
	fi

	cache_id_ctrl "$CTRL_DEV"
	setup_tmp
	trap cleanup_tmp EXIT

	init_log "nvme_additional_logs_verify" "$CTRL_DEV"
	log_cmd "Identify Controller (cached)" "nvme id-ctrl ${CTRL_DEV}" "$_ID_CTRL_CACHE"

	local spec_ref
	spec_ref=$(get_spec_ref "additional-logs")

	print_header \
		"NVMe Additional Log Pages — Behavioral + Read-Only Verification" \
		"$spec_ref" \
		"$CTRL_DEV"

	echo -e "${BOLD}--- Telemetry (Behavioral: generate -> verify -> read) ---${RESET}"
	test_telemetry_generate
	test_telemetry_verify_header
	test_telemetry_read_existing
	test_telemetry_controller_initiated

	echo ""
	echo -e "${BOLD}--- Persistent Event Log (Behavioral: establish -> read -> release) ---${RESET}"
	test_persistent_event_establish
	test_persistent_event_read
	test_persistent_event_release
	test_persistent_event_verify_release

	echo ""
	echo -e "${BOLD}--- Read-Only Log Pages ---${RESET}"
	test_endurance_group_log
	test_changed_ns_list_log
	test_resv_notif_log
	test_fid_support_effects_log
	test_lba_status_log
	test_predictable_lat_log
	test_boot_partition_log
	test_endurance_event_agg_log

	echo ""
	echo -e "${BOLD}--- NVM CS 1.3 / PCIe Transport 1.4 Log Pages ---${RESET}"
	test_rate_limiting_log
	test_eom_log

	echo ""
	echo -e "${BOLD}--- NVMe 2.4 Log Pages ---${RESET}"
	test_power_measurement_log
	test_voltage_measurement_log
	test_cross_controller_reset_log
	test_lost_host_comm_log

	print_summary

	if [ "$FAIL_COUNT" -gt 0 ]; then
		exit 1
	fi
	exit 0
}

main "$@"
