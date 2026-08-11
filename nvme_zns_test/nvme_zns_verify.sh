#!/bin/bash
# SPDX-License-Identifier: GPL-3.0+
# Copyright (C) 2025 Red Hat, Inc.
#
# NVMe ZNS (Zoned Namespace) Command Set verification
# Based on ZNS Command Set Specification 1.5
# Field names from nvme-cli upstream nvme-print-stdout.c (zns plugin)
#
# Usage:
#   ./nvme_zns_verify.sh /dev/nvme0n1
#   ./nvme_zns_verify.sh /dev/nvme0n1 --allow-destructive
#   ./nvme_zns_verify.sh /dev/nvme0
#   ./nvme_zns_verify.sh              # auto-detects first NVMe namespace

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/nvme_test_lib.sh
source "${SCRIPT_DIR}/../common/nvme_test_lib.sh"

ZNS_ID_NS_OUTPUT=""
ZNS_ID_CTRL_OUTPUT=""
ZONE_REPORT=""
NS_DEV=""
CTRL_DEV=""
ALLOW_DESTRUCTIVE=""

# --------------------------------------------------------------------------
# ZNS field helpers
# --------------------------------------------------------------------------

zns_get_field() {
	local field="$1"
	echo "$ZNS_ID_NS_OUTPUT" | grep -i "^${field}[[:space:]:]" | awk -F: '{print $2}' | tr -d ' ' | head -1
}

zns_ctrl_get_field() {
	local field="$1"
	echo "$ZNS_ID_CTRL_OUTPUT" | grep -i "^${field}[[:space:]:]" | awk -F: '{print $2}' | tr -d ' ' | head -1
}

get_first_zone_slba() {
	echo "$ZONE_REPORT" | grep -i "SLBA" | head -1 | grep -oP '0x[0-9a-fA-F]+' | head -1 || true
}

get_zone_state() {
	local slba="$1"
	local report
	report=$(nvme zns report-zones "$NS_DEV" -s "$slba" -d 1 2>&1) || true
	echo "$report" | grep -i "State" | head -1 | sed 's/.*State[[:space:]]*:[[:space:]]*//' | awk '{print $1}' || true
}

# --------------------------------------------------------------------------
# Read-Only Tests
# --------------------------------------------------------------------------

test_zns_detect() {
	local ns_descs_output
	ns_descs_output=$(nvme ns-descs "$NS_DEV" 2>&1) || true
	local csi_val=""
	if echo "$ns_descs_output" | grep -qi "csi"; then
		csi_val=$(echo "$ns_descs_output" | grep -i "csi" | head -1 | grep -oP '0x[0-9a-fA-F]+' | head -1 || true)
	fi

	if [ -n "$csi_val" ] && [ "$((csi_val))" -eq 2 ]; then
		log_pass "ZNS namespace detected via ns-descs CSI=2 (${NS_DEV})"
		return
	fi

	local zns_id_test
	zns_id_test=$(nvme zns id-ns "$NS_DEV" 2>&1) || true
	if echo "$zns_id_test" | grep -qi "zoc\|ozcs\|mar\|mor"; then
		log_pass "ZNS namespace detected via zns id-ns (${NS_DEV})"
	else
		log_fail "ZNS namespace detection" "CSI != 2 and zns id-ns returned no ZNS fields"
	fi
}

test_zns_id_ctrl() {
	ZNS_ID_CTRL_OUTPUT=$(nvme zns id-ctrl "$CTRL_DEV" 2>&1) || true
	log_cmd "ZNS Identify Controller" "nvme zns id-ctrl ${CTRL_DEV}" "$ZNS_ID_CTRL_OUTPUT"

	if echo "$ZNS_ID_CTRL_OUTPUT" | grep -qi "zasl"; then
		local zasl
		zasl=$(zns_ctrl_get_field "zasl")
		log_pass "zns id-ctrl: zasl field present (${zasl})"
	else
		log_fail "zns id-ctrl: zasl field present" "not found in output"
	fi
}

test_zasl_range() {
	local zasl
	zasl=$(zns_ctrl_get_field "zasl")
	if [ -z "$zasl" ]; then
		log_skip "ZASL range check" "zasl not available"
		return
	fi
	local zasl_int=$((zasl))
	if [ "$zasl_int" -eq 0 ]; then
		log_pass "ZASL=0: Zone Append Size Limit equals MDTS (no separate limit)"
	else
		local mdts
		mdts=$(get_id_ctrl_field "mdts")
		if [ -n "$mdts" ] && [ "$((mdts))" -gt 0 ]; then
			if [ "$zasl_int" -le "$((mdts))" ]; then
				log_pass "ZASL=${zasl_int} is within MDTS range (MDTS=${mdts})"
			else
				log_fail "ZASL must be <= MDTS" "ZASL=${zasl_int}, MDTS=${mdts}"
			fi
		else
			log_pass "ZASL=${zasl_int} (MDTS=0 or unavailable, no upper bound to check)"
		fi
	fi
}

test_zns_id_ns() {
	ZNS_ID_NS_OUTPUT=$(nvme zns id-ns "$NS_DEV" 2>&1) || true
	log_cmd "ZNS Identify Namespace" "nvme zns id-ns ${NS_DEV}" "$ZNS_ID_NS_OUTPUT"

	if echo "$ZNS_ID_NS_OUTPUT" | grep -qi "invalid\|not support\|unknown"; then
		log_fail "zns id-ns command" "command not supported: $(echo "$ZNS_ID_NS_OUTPUT" | head -1)"
		return
	fi

	local missing=""
	local field
	for field in zoc ozcs mar mor; do
		if ! echo "$ZNS_ID_NS_OUTPUT" | grep -qi "^${field}[[:space:]:]"; then
			missing="${missing} ${field}"
		fi
	done

	if [ -z "$missing" ]; then
		log_pass "zns id-ns: key fields present (zoc, ozcs, mar, mor)"
	else
		log_fail "zns id-ns: key fields present" "missing:${missing}"
	fi
}

test_zoc_decode() {
	local zoc
	zoc=$(zns_get_field "zoc")
	if [ -z "$zoc" ]; then
		log_skip "ZOC decode" "zoc field not available"
		return
	fi
	local zoc_int=$((zoc))
	local vzc=$(( zoc_int & 0x1 ))
	local zae=$(( (zoc_int >> 1) & 0x1 ))
	log_pass "ZOC decode (0x$(printf '%02x' "$zoc_int")): VZC=${vzc} (Variable Zone Capacity), ZAE=${zae} (Zone Active Excursions)"
}

test_ozcs_decode() {
	local ozcs
	ozcs=$(zns_get_field "ozcs")
	if [ -z "$ozcs" ]; then
		log_skip "OZCS decode" "ozcs field not available"
		return
	fi
	local ozcs_int=$((ozcs))
	local razb=$(( ozcs_int & 0x1 ))
	local zrwa=$(( (ozcs_int >> 1) & 0x1 ))
	log_pass "OZCS decode (0x$(printf '%02x' "$ozcs_int")): RAZB=${razb} (Read Across Zone Boundaries), ZRWA=${zrwa} (Zone Random Write Area)"
}

test_mar_value() {
	local mar
	mar=$(zns_get_field "mar")
	if [ -z "$mar" ]; then
		log_skip "MAR value" "mar field not available"
		return
	fi
	local mar_int=$((mar))
	if [ "$mar_int" -eq $((0xFFFFFFFF)) ]; then
		log_pass "MAR=0xFFFFFFFF: no limit on active resources"
	elif [ "$mar_int" -ge 0 ]; then
		log_pass "MAR=${mar_int}: maximum active resources limited to $((mar_int + 1))"
	else
		log_fail "MAR value validation" "unexpected value: ${mar}"
	fi
}

test_mor_value() {
	local mor
	mor=$(zns_get_field "mor")
	if [ -z "$mor" ]; then
		log_skip "MOR value" "mor field not available"
		return
	fi
	local mor_int=$((mor))
	if [ "$mor_int" -eq $((0xFFFFFFFF)) ]; then
		log_pass "MOR=0xFFFFFFFF: no limit on open resources"
	elif [ "$mor_int" -ge 0 ]; then
		log_pass "MOR=${mor_int}: maximum open resources limited to $((mor_int + 1))"
	else
		log_fail "MOR value validation" "unexpected value: ${mor}"
	fi
}

test_rrl_frl() {
	local rrl frl
	rrl=$(zns_get_field "rrl")
	frl=$(zns_get_field "frl")
	local found=""
	local notfound=""
	if [ -n "$rrl" ]; then
		found="${found} rrl=${rrl}"
	else
		notfound="${notfound} rrl"
	fi
	if [ -n "$frl" ]; then
		found="${found} frl=${frl}"
	else
		notfound="${notfound} frl"
	fi

	if [ -z "$notfound" ]; then
		log_pass "RRL and FRL present:${found}"
	elif [ -n "$found" ]; then
		log_warn "RRL/FRL partially present" "found:${found}, missing:${notfound}"
	else
		log_skip "RRL/FRL fields" "neither rrl nor frl found"
	fi
}

test_multi_level_limits() {
	local found=""
	local notfound=""
	local field
	for field in rrl1 rrl2 rrl3 frl1 frl2 frl3; do
		local val
		val=$(zns_get_field "$field")
		if [ -n "$val" ]; then
			found="${found} ${field}=${val}"
		else
			notfound="${notfound} ${field}"
		fi
	done

	if [ -z "$notfound" ]; then
		log_pass "ZNS 1.5 multi-level time limits present:${found}"
	elif [ -n "$found" ]; then
		log_pass "ZNS 1.5 multi-level time limits partially present:${found} (missing:${notfound})"
	else
		log_skip "ZNS 1.5 multi-level time limits" "rrl1-3/frl1-3 not found (pre-ZNS 1.5 device)"
	fi
}

test_zrwa_fields() {
	local ozcs
	ozcs=$(zns_get_field "ozcs")
	if [ -z "$ozcs" ]; then
		log_skip "ZRWA fields" "ozcs not available"
		return
	fi
	local ozcs_int=$((ozcs))
	local zrwa_bit=$(( (ozcs_int >> 1) & 0x1 ))
	if [ "$zrwa_bit" -eq 0 ]; then
		log_skip "ZRWA fields" "OZCS bit 1=0 (ZRWA not supported)"
		return
	fi

	local missing=""
	local details=""
	local field
	for field in numzrwa zrwafg zrwasz zrwacap; do
		local val
		val=$(zns_get_field "$field")
		if [ -n "$val" ]; then
			details="${details} ${field}=${val}"
		else
			missing="${missing} ${field}"
		fi
	done

	if [ -z "$missing" ]; then
		log_pass "ZRWA fields present:${details}"
	else
		log_fail "ZRWA fields present (OZCS ZRWA=1)" "missing:${missing}"
	fi
}

test_zrwacap_explicit_flush() {
	local ozcs
	ozcs=$(zns_get_field "ozcs")
	if [ -z "$ozcs" ]; then
		log_skip "ZRWACAP explicit flush" "ozcs not available"
		return
	fi
	local ozcs_int=$((ozcs))
	local zrwa_bit=$(( (ozcs_int >> 1) & 0x1 ))
	if [ "$zrwa_bit" -eq 0 ]; then
		log_skip "ZRWACAP explicit flush" "ZRWA not supported"
		return
	fi

	local zrwacap
	zrwacap=$(zns_get_field "zrwacap")
	if [ -z "$zrwacap" ]; then
		log_skip "ZRWACAP explicit flush" "zrwacap field not available"
		return
	fi
	local cap_int=$((zrwacap))
	local explicit_flush=$(( cap_int & 0x1 ))
	if [ "$explicit_flush" -eq 1 ]; then
		log_pass "ZRWACAP bit 0=1: explicit ZRWA flush supported"
	else
		log_pass "ZRWACAP bit 0=0: explicit ZRWA flush not supported"
	fi
}

test_lbafe() {
	local lbafe_lines
	lbafe_lines=$(echo "$ZNS_ID_NS_OUTPUT" | grep -i "^lbafe" || true)
	if [ -z "$lbafe_lines" ]; then
		log_fail "LBA Format Extension entries present" "no lbafe entries found"
		return
	fi

	local valid_count=0
	local total_count=0
	while IFS= read -r line; do
		total_count=$((total_count + 1))
		local zsze
		zsze=$(echo "$line" | grep -oiP 'zsze\s*:\s*0x[0-9a-fA-F]+' | grep -oiP '0x[0-9a-fA-F]+' || true)
		if [ -n "$zsze" ] && [ "$((zsze))" -gt 0 ]; then
			valid_count=$((valid_count + 1))
		fi
	done <<< "$lbafe_lines"

	if [ "$valid_count" -gt 0 ]; then
		log_pass "LBA Format Extension: ${valid_count}/${total_count} entries with zsze > 0"
	else
		log_fail "At least one LBA Format Extension with zsze > 0" "all ${total_count} entries have zsze=0"
	fi
}

test_report_zones() {
	ZONE_REPORT=$(nvme zns report-zones "$NS_DEV" 2>&1) || true
	log_cmd "Report Zones" "nvme zns report-zones ${NS_DEV}" "$ZONE_REPORT"

	if echo "$ZONE_REPORT" | grep -qi "invalid\|not support\|unknown"; then
		log_fail "report-zones command" "command not supported: $(echo "$ZONE_REPORT" | head -1)"
		return
	fi

	if echo "$ZONE_REPORT" | grep -qi "SLBA\|slba\|zone\|Zone"; then
		log_pass "report-zones returns zone data"
	else
		log_fail "report-zones returns zone data" "no zone entries in output"
	fi
}

test_zone_count() {
	if [ -z "$ZONE_REPORT" ]; then
		log_skip "Zone count" "report-zones output not available"
		return
	fi

	local nr_zones
	nr_zones=$(echo "$ZONE_REPORT" | grep -ci "SLBA\|slba" || true)
	if [ "$nr_zones" -gt 0 ]; then
		log_pass "Zone count: ${nr_zones} zone(s) reported"
	else
		local total_line
		total_line=$(echo "$ZONE_REPORT" | grep -i "nr_zones\|total" | head -1 || true)
		if [ -n "$total_line" ]; then
			log_pass "Zone count: ${total_line}"
		else
			log_fail "Zone count" "could not determine number of zones"
		fi
	fi
}

test_zone_state_types() {
	if [ -z "$ZONE_REPORT" ]; then
		log_skip "Zone state types" "report-zones output not available"
		return
	fi

	local states
	states=$(echo "$ZONE_REPORT" | grep -ioP '(?:State|state)\s*:\s*\K\S+' || true)
	if [ -z "$states" ]; then
		states=$(echo "$ZONE_REPORT" | grep -ioP '(Empty|Imp\. Open|Exp\. Open|Closed|Full|Read Only|Offline|ZSE|ZSIO|ZSEO|ZSC|ZSF|ZSRO|ZSO)' || true)
	fi

	if [ -z "$states" ]; then
		log_skip "Zone state validation" "could not parse zone states from output"
		return
	fi

	local invalid=0
	local valid_pattern="Empty|Imp|Exp|Open|Closed|Full|Read.Only|Offline|ZSE|ZSIO|ZSEO|ZSC|ZSF|ZSRO|ZSO|empty|0x"
	while IFS= read -r state; do
		if ! echo "$state" | grep -qiE "$valid_pattern"; then
			invalid=$((invalid + 1))
		fi
	done <<< "$states"

	local unique_states
	unique_states=$(echo "$states" | sort -u | tr '\n' ',' | sed 's/,$//')
	if [ "$invalid" -eq 0 ]; then
		log_pass "Zone states are valid types: ${unique_states}"
	else
		log_fail "Zone state validation" "${invalid} zone(s) with unrecognized state"
	fi
}

test_changed_zone_list() {
	local output
	output=$(nvme zns changed-zone-list "$NS_DEV" 2>&1) || true
	log_cmd "Changed Zone List" "nvme zns changed-zone-list ${NS_DEV}" "$output"

	if echo "$output" | grep -qi "invalid\|not support\|unknown opcode"; then
		log_skip "Changed zone list" "command not supported"
	else
		log_pass "Changed zone list command completed"
	fi
}

# --------------------------------------------------------------------------
# Destructive Tests
# --------------------------------------------------------------------------

test_zone_lifecycle() {
	safe_device_check "$NS_DEV" "$ALLOW_DESTRUCTIVE"

	local slba
	slba=$(get_first_zone_slba)
	if [ -z "$slba" ]; then
		log_skip "Zone lifecycle (open/close/reset)" "could not determine first zone SLBA"
		return
	fi

	# Open zone
	local output
	output=$(nvme zns open-zone "$NS_DEV" -s "$slba" 2>&1) || true
	log_cmd "Open Zone" "nvme zns open-zone ${NS_DEV} -s ${slba}" "$output"
	if echo "$output" | grep -qi "error\|invalid\|fail"; then
		log_fail "Zone lifecycle: open zone at SLBA=${slba}" "$(echo "$output" | head -1)"
		return
	fi

	local state
	state=$(get_zone_state "$slba")
	if echo "$state" | grep -qi "Open\|ZSIO\|ZSEO"; then
		log_pass "Zone lifecycle: zone at SLBA=${slba} opened (state=${state})"
	else
		log_warn "Zone lifecycle: open zone" "expected Open state, got: ${state}"
	fi

	# Close zone
	output=$(nvme zns close-zone "$NS_DEV" -s "$slba" 2>&1) || true
	log_cmd "Close Zone" "nvme zns close-zone ${NS_DEV} -s ${slba}" "$output"
	if echo "$output" | grep -qi "error\|invalid\|fail"; then
		log_warn "Zone lifecycle: close zone at SLBA=${slba}" "$(echo "$output" | head -1)"
	else
		state=$(get_zone_state "$slba")
		if echo "$state" | grep -qi "Closed\|ZSC\|Empty\|ZSE"; then
			log_pass "Zone lifecycle: zone at SLBA=${slba} closed (state=${state})"
		else
			log_warn "Zone lifecycle: close zone" "expected Closed/Empty, got: ${state}"
		fi
	fi

	# Reset zone
	output=$(nvme zns reset-zone "$NS_DEV" -s "$slba" 2>&1) || true
	log_cmd "Reset Zone" "nvme zns reset-zone ${NS_DEV} -s ${slba}" "$output"
	if echo "$output" | grep -qi "error\|invalid\|fail"; then
		log_warn "Zone lifecycle: reset zone at SLBA=${slba}" "$(echo "$output" | head -1)"
	else
		state=$(get_zone_state "$slba")
		if echo "$state" | grep -qi "Empty\|ZSE"; then
			log_pass "Zone lifecycle: zone at SLBA=${slba} reset to Empty (state=${state})"
		else
			log_warn "Zone lifecycle: reset zone" "expected Empty, got: ${state}"
		fi
	fi
}

test_zrwa_flush() {
	local ozcs
	ozcs=$(zns_get_field "ozcs")
	if [ -z "$ozcs" ]; then
		log_skip "ZRWA flush" "ozcs not available"
		return
	fi
	local ozcs_int=$((ozcs))
	local zrwa_bit=$(( (ozcs_int >> 1) & 0x1 ))
	if [ "$zrwa_bit" -eq 0 ]; then
		log_skip "ZRWA flush" "ZRWA not supported (OZCS bit 1=0)"
		return
	fi

	local zrwacap
	zrwacap=$(zns_get_field "zrwacap")
	if [ -z "$zrwacap" ]; then
		log_skip "ZRWA flush" "zrwacap not available"
		return
	fi
	local cap_int=$((zrwacap))
	local explicit_flush=$(( cap_int & 0x1 ))
	if [ "$explicit_flush" -eq 0 ]; then
		log_skip "ZRWA flush" "explicit flush not supported (zrwacap bit 0=0)"
		return
	fi

	safe_device_check "$NS_DEV" "$ALLOW_DESTRUCTIVE"

	local slba
	slba=$(get_first_zone_slba)
	if [ -z "$slba" ]; then
		log_skip "ZRWA flush" "could not determine first zone SLBA"
		return
	fi

	local output
	output=$(nvme zns zrwa-flush-zone "$NS_DEV" -l "$slba" 2>&1) || true
	log_cmd "ZRWA Flush" "nvme zns zrwa-flush-zone ${NS_DEV} -l ${slba}" "$output"
	if echo "$output" | grep -qi "error\|invalid\|fail"; then
		log_fail "ZRWA flush at LBA=${slba}" "$(echo "$output" | head -1)"
	else
		log_pass "ZRWA flush at LBA=${slba} completed"
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
				echo "Usage: $0 [/dev/nvmeXnY | /dev/nvmeX] [--allow-destructive]"
				echo ""
				echo "ZNS (Zoned Namespace) Command Set verification."
				echo "Read-only tests run by default. Destructive zone lifecycle"
				echo "tests require --allow-destructive."
				exit 0
				;;
			/dev/nvme*)
				if [[ "$arg" =~ ^/dev/nvme[0-9]+n[0-9]+$ ]]; then
					NS_DEV="$arg"
					CTRL_DEV="${arg%n*}"
				elif [[ "$arg" =~ ^/dev/nvme[0-9]+$ ]]; then
					CTRL_DEV="$arg"
				fi
				;;
		esac
	done

	if [ -z "$CTRL_DEV" ]; then
		CTRL_DEV=$(auto_detect_ctrl)
		echo -e "${BOLD}No device specified — auto-detected: ${CTRL_DEV}${RESET}"
	fi

	if [ -z "$NS_DEV" ]; then
		NS_DEV=$(resolve_ns_dev "$CTRL_DEV")
	fi

	if [ ! -e "$NS_DEV" ]; then
		echo "ERROR: Namespace device $NS_DEV does not exist." >&2
		exit 1
	fi

	# Early ZNS detection — skip entire suite if not ZNS
	local csi_check
	csi_check=$(nvme ns-descs "$NS_DEV" 2>&1) || true
	local csi_val=""
	if echo "$csi_check" | grep -qi "csi"; then
		csi_val=$(echo "$csi_check" | grep -i "csi" | head -1 | grep -oP '0x[0-9a-fA-F]+' | head -1 || true)
	fi

	if [ -n "$csi_val" ] && [ "$((csi_val))" -eq 2 ]; then
		: # ZNS confirmed via CSI
	else
		local zns_ctrl_probe
		zns_ctrl_probe=$(nvme zns id-ctrl "$CTRL_DEV" 2>&1) || true
		if ! echo "$zns_ctrl_probe" | grep -qi "zasl"; then
			echo -e "${YELLOW}SKIP: ${NS_DEV} is not a ZNS namespace — skipping entire suite.${RESET}"
			echo -e "  (CSI=${csi_val:-unknown}, zns id-ctrl has no zasl field)"
			exit 0
		fi
	fi

	cache_id_ctrl "$CTRL_DEV"
	init_log "nvme_zns_verify" "$CTRL_DEV"
	log_cmd "Identify Controller (cached)" "nvme id-ctrl ${CTRL_DEV}" "$_ID_CTRL_CACHE"

	print_header \
		"NVMe ZNS Command Set — Verification" \
		"ZNS Command Set Specification, Revision 1.5" \
		"$CTRL_DEV (namespace: ${NS_DEV})"

	echo ""
	echo -e "${BOLD}--- ZNS Detection ---${RESET}"
	test_zns_detect

	echo ""
	echo -e "${BOLD}--- ZNS Identify Controller ---${RESET}"
	test_zns_id_ctrl
	test_zasl_range

	echo ""
	echo -e "${BOLD}--- ZNS Identify Namespace ---${RESET}"
	test_zns_id_ns
	test_zoc_decode
	test_ozcs_decode
	test_mar_value
	test_mor_value

	echo ""
	echo -e "${BOLD}--- Recommended Limits ---${RESET}"
	test_rrl_frl
	test_multi_level_limits

	echo ""
	echo -e "${BOLD}--- ZRWA (Zone Random Write Area) ---${RESET}"
	test_zrwa_fields
	test_zrwacap_explicit_flush

	echo ""
	echo -e "${BOLD}--- LBA Format Extensions ---${RESET}"
	test_lbafe

	echo ""
	echo -e "${BOLD}--- Zone Report ---${RESET}"
	test_report_zones
	test_zone_count
	test_zone_state_types
	test_changed_zone_list

	if [ -n "$ALLOW_DESTRUCTIVE" ]; then
		echo ""
		echo -e "${BOLD}--- Destructive: Zone Lifecycle ---${RESET}"
		test_zone_lifecycle
		test_zrwa_flush
	fi

	print_summary

	if [ "$FAIL_COUNT" -gt 0 ]; then
		exit 1
	fi
	exit 0
}

main "$@"
