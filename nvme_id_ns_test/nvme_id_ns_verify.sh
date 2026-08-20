#!/bin/bash
# SPDX-License-Identifier: GPL-3.0+
# Copyright (C) 2025 Red Hat, Inc.
#
# NVMe Identify Namespace Data Structure verification
# Based on NVMe Base Specification, Revision 2.1
# Section 5.1.13, Figure 319 — I/O Cmd Set Independent Identify Namespace
# Field names from nvme-cli upstream nvme-print-stdout.c
#
# Usage:
#   ./nvme_id_ns_verify.sh /dev/nvme0n1
#   ./nvme_id_ns_verify.sh /dev/nvme0
#   ./nvme_id_ns_verify.sh              # auto-detects first NVMe namespace

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/nvme_test_lib.sh
source "${SCRIPT_DIR}/../common/nvme_test_lib.sh"

NS_DATA=""

ns_get_field() {
	echo "$NS_DATA" | grep "^$1[[:space:]:]" | awk -F': ' '{ print $2 }' | awk '{ print $1 }' || true
}

ns_field_present() {
	echo "$NS_DATA" | grep -q "^$1[[:space:]:]"
}

ns_get_hex_field() {
	local raw
	raw=$(ns_get_field "$1")
	if [ -n "$raw" ]; then
		echo $((raw))
	fi
}

# --------------------------------------------------------------------------
# Test functions
# --------------------------------------------------------------------------

test_nsze() {
	local val
	val=$(ns_get_field "nsze")
	if [ -z "$val" ]; then
		log_fail "nsze (Namespace Size) is present" "not found"
		return
	fi
	local nsze_int=$((val))
	if [ "$nsze_int" -gt 0 ]; then
		log_pass "nsze (Namespace Size) is present and non-zero (${val})"
	else
		log_fail "nsze (Namespace Size) must be > 0" "got ${val}"
	fi
}

test_ncap() {
	local ncap nsze
	ncap=$(ns_get_field "ncap")
	nsze=$(ns_get_field "nsze")
	if [ -z "$ncap" ]; then
		log_fail "ncap (Namespace Capacity) is present" "not found"
		return
	fi
	local ncap_int=$((ncap))
	local nsze_int=$((nsze))
	if [ "$ncap_int" -gt 0 ] && [ "$ncap_int" -le "$nsze_int" ]; then
		log_pass "ncap (Namespace Capacity) is valid (${ncap}, <= nsze)"
	elif [ "$ncap_int" -gt 0 ]; then
		log_fail "ncap <= nsze" "ncap=${ncap} > nsze=${nsze}"
	else
		log_fail "ncap (Namespace Capacity) must be > 0" "got ${ncap}"
	fi
}

test_nuse() {
	local nuse ncap
	nuse=$(ns_get_field "nuse")
	ncap=$(ns_get_field "ncap")
	if [ -z "$nuse" ]; then
		log_fail "nuse (Namespace Utilization) is present" "not found"
		return
	fi
	local nuse_int=$((nuse))
	local ncap_int=$((ncap))
	if [ "$nuse_int" -le "$ncap_int" ]; then
		log_pass "nuse (Namespace Utilization) is valid (${nuse}, <= ncap)"
	else
		log_fail "nuse <= ncap" "nuse=${nuse} > ncap=${ncap}"
	fi
}

test_nsfeat() {
	if ns_field_present "nsfeat"; then
		local val
		val=$(ns_get_field "nsfeat")
		log_pass "nsfeat (Namespace Features) is present (${val})"
	else
		log_fail "nsfeat (Namespace Features) is present" "not found"
	fi
}

test_nlbaf() {
	local val
	val=$(ns_get_field "nlbaf")
	if [ -z "$val" ]; then
		log_fail "nlbaf (Number of LBA Formats) is present" "not found"
		return
	fi
	local nlbaf_int=$((val))
	if [ "$nlbaf_int" -ge 0 ]; then
		log_pass "nlbaf (Number of LBA Formats) is present (${nlbaf_int}, means $((nlbaf_int + 1)) format(s))"
	else
		log_fail "nlbaf >= 0" "got ${val}"
	fi
}

test_flbas() {
	local flbas nlbaf
	flbas=$(ns_get_field "flbas")
	nlbaf=$(ns_get_field "nlbaf")
	if [ -z "$flbas" ]; then
		log_fail "flbas (Formatted LBA Size) is present" "not found"
		return
	fi
	local flbas_int=$((flbas))
	local active_fmt=$(( flbas_int & 0xf ))
	local nlbaf_int=$((nlbaf))
	if [ "$active_fmt" -le "$nlbaf_int" ]; then
		log_pass "flbas (Formatted LBA Size) is valid (${flbas}, active format index=${active_fmt}, max=${nlbaf_int})"
	else
		log_fail "flbas active format index <= nlbaf" "active=${active_fmt} > nlbaf=${nlbaf_int}"
	fi
}

test_mc() {
	if ns_field_present "mc"; then
		local val
		val=$(ns_get_field "mc")
		log_pass "mc (Metadata Capabilities) is present (${val})"
	else
		log_fail "mc (Metadata Capabilities) is present" "not found"
	fi
}

test_dpc() {
	if ns_field_present "dpc"; then
		local val
		val=$(ns_get_field "dpc")
		log_pass "dpc (Data Protection Capabilities) is present (${val})"
	else
		log_fail "dpc (Data Protection Capabilities) is present" "not found"
	fi
}

test_dps() {
	if ns_field_present "dps"; then
		local val
		val=$(ns_get_field "dps")
		log_pass "dps (Data Protection Settings) is present (${val})"
	else
		log_fail "dps (Data Protection Settings) is present" "not found"
	fi
}

test_nmic() {
	if ns_field_present "nmic"; then
		local val
		val=$(ns_get_field "nmic")
		log_pass "nmic (Namespace Multi-path/Sharing) is present (${val})"
	else
		log_fail "nmic (Namespace Multi-path/Sharing) is present" "not found"
	fi
}

test_rescap() {
	if ns_field_present "rescap"; then
		local val
		val=$(ns_get_field "rescap")
		log_pass "rescap (Reservation Capabilities) is present (${val})"
	else
		log_fail "rescap (Reservation Capabilities) is present" "not found"
	fi
}

test_fpi() {
	if ns_field_present "fpi"; then
		local val
		val=$(ns_get_field "fpi")
		log_pass "fpi (Format Progress Indicator) is present (${val})"
	else
		log_fail "fpi (Format Progress Indicator) is present" "not found"
	fi
}

test_dlfeat() {
	if ! ver_at_least 1 3; then
		log_skip "dlfeat (Deallocate LB Features) is present" "requires NVMe 1.3+"
		return
	fi
	if ns_field_present "dlfeat"; then
		local val
		val=$(ns_get_field "dlfeat")
		log_pass "dlfeat (Deallocate LB Features) is present (${val})"
	else
		log_fail "dlfeat (Deallocate LB Features) is present" "not found"
	fi
}

test_nawun() {
	if ! ver_at_least 1 2; then
		log_skip "nawun (Namespace Atomic Write Unit Normal) is present" "requires NVMe 1.2+"
		return
	fi
	if ns_field_present "nawun"; then
		local val
		val=$(ns_get_field "nawun")
		log_pass "nawun (Namespace Atomic Write Unit Normal) is present (${val})"
	else
		log_fail "nawun is present" "not found"
	fi
}

test_nawupf() {
	if ! ver_at_least 1 2; then
		log_skip "nawupf (Namespace Atomic Write Unit Power Fail) is present" "requires NVMe 1.2+"
		return
	fi
	if ns_field_present "nawupf"; then
		local val
		val=$(ns_get_field "nawupf")
		log_pass "nawupf (Namespace Atomic Write Unit Power Fail) is present (${val})"
	else
		log_fail "nawupf is present" "not found"
	fi
}

test_nacwu() {
	if ! ver_at_least 1 2; then
		log_skip "nacwu (Namespace Atomic Compare & Write Unit) is present" "requires NVMe 1.2+"
		return
	fi
	if ns_field_present "nacwu"; then
		local val
		val=$(ns_get_field "nacwu")
		log_pass "nacwu (Namespace Atomic Compare & Write Unit) is present (${val})"
	else
		log_fail "nacwu is present" "not found"
	fi
}

test_nabsn() {
	if ! ver_at_least 1 2; then
		log_skip "nabsn (Namespace Atomic Boundary Size Normal) is present" "requires NVMe 1.2+"
		return
	fi
	if ns_field_present "nabsn"; then
		local val
		val=$(ns_get_field "nabsn")
		log_pass "nabsn (Namespace Atomic Boundary Size Normal) is present (${val})"
	else
		log_fail "nabsn is present" "not found"
	fi
}

test_nabo() {
	if ! ver_at_least 1 2; then
		log_skip "nabo (Namespace Atomic Boundary Offset) is present" "requires NVMe 1.2+"
		return
	fi
	if ns_field_present "nabo"; then
		local val
		val=$(ns_get_field "nabo")
		log_pass "nabo (Namespace Atomic Boundary Offset) is present (${val})"
	else
		log_fail "nabo is present" "not found"
	fi
}

test_nabspf() {
	if ! ver_at_least 1 2; then
		log_skip "nabspf (Namespace Atomic Boundary Size Power Fail) is present" "requires NVMe 1.2+"
		return
	fi
	if ns_field_present "nabspf"; then
		local val
		val=$(ns_get_field "nabspf")
		log_pass "nabspf (Namespace Atomic Boundary Size Power Fail) is present (${val})"
	else
		log_fail "nabspf is present" "not found"
	fi
}

test_noiob() {
	if ! ver_at_least 1 2; then
		log_skip "noiob (Namespace Optimal I/O Boundary) is present" "requires NVMe 1.2+"
		return
	fi
	if ns_field_present "noiob"; then
		local val
		val=$(ns_get_field "noiob")
		log_pass "noiob (Namespace Optimal I/O Boundary) is present (${val})"
	else
		log_fail "noiob is present" "not found"
	fi
}

test_nvmcap() {
	if ! ver_at_least 1 3; then
		log_skip "nvmcap (NVM Capacity) is present" "requires NVMe 1.3+"
		return
	fi
	if ns_field_present "nvmcap"; then
		local val
		val=$(echo "$NS_DATA" | grep "^nvmcap " | sed 's/^nvmcap *: *//')
		log_pass "nvmcap (NVM Capacity) is present (${val})"
	else
		log_fail "nvmcap (NVM Capacity) is present" "not found"
	fi
}

test_anagrpid() {
	if ! ver_at_least 1 4; then
		log_skip "anagrpid (ANA Group Identifier) is present" "requires NVMe 1.4+"
		return
	fi
	if ns_field_present "anagrpid"; then
		local val
		val=$(ns_get_field "anagrpid")
		log_pass "anagrpid (ANA Group Identifier) is present (${val})"
	else
		log_fail "anagrpid is present" "not found"
	fi
}

test_nvmsetid() {
	if ! ver_at_least 1 4; then
		log_skip "nvmsetid (NVM Set Identifier) is present" "requires NVMe 1.4+"
		return
	fi
	if ns_field_present "nvmsetid"; then
		local val
		val=$(ns_get_field "nvmsetid")
		log_pass "nvmsetid (NVM Set Identifier) is present (${val})"
	else
		log_fail "nvmsetid is present" "not found"
	fi
}

test_endgid() {
	if ! ver_at_least 1 4; then
		log_skip "endgid (Endurance Group Identifier) is present" "requires NVMe 1.4+"
		return
	fi
	if ns_field_present "endgid"; then
		local val
		val=$(ns_get_field "endgid")
		log_pass "endgid (Endurance Group Identifier) is present (${val})"
	else
		log_fail "endgid is present" "not found"
	fi
}

test_nguid() {
	if ns_field_present "nguid"; then
		local val
		val=$(echo "$NS_DATA" | grep "^nguid " | sed 's/^nguid *: *//')
		if echo "$val" | grep -qP '[^0 ]'; then
			log_pass "nguid (Namespace GUID) is present and non-zero (${val})"
		else
			log_pass "nguid (Namespace GUID) is present (all zeros — valid if eui64 is non-zero)"
		fi
	else
		log_fail "nguid (Namespace GUID) is present" "not found"
	fi
}

test_eui64() {
	if ns_field_present "eui64"; then
		local val
		val=$(echo "$NS_DATA" | grep "^eui64 " | sed 's/^eui64 *: *//')
		if echo "$val" | grep -qP '[^0 ]'; then
			log_pass "eui64 (IEEE Extended Unique Identifier) is present and non-zero (${val})"
		else
			log_pass "eui64 (IEEE Extended Unique Identifier) is present (all zeros — valid if nguid is non-zero)"
		fi
	else
		log_fail "eui64 (IEEE Extended Unique Identifier) is present" "not found"
	fi
}

test_lbaf0() {
	local lbaf0_line
	lbaf0_line=$(echo "$NS_DATA" | grep "^lbaf  *0 " | head -1)
	if [ -z "$lbaf0_line" ]; then
		log_fail "lbaf 0 (LBA Format 0) is present" "not found"
		return
	fi
	local lbads
	lbads=$(echo "$lbaf0_line" | grep -oP 'lbads:(\d+)' | cut -d: -f2)
	if [ -z "$lbads" ]; then
		log_fail "lbaf 0 lbads is parseable" "could not extract lbads"
		return
	fi
	if [ "$lbads" -ge 9 ]; then
		local block_size=$((1 << lbads))
		log_pass "lbaf 0 (LBA Format 0) is valid (lbads=${lbads}, block_size=${block_size} bytes)"
	else
		log_fail "lbaf 0 lbads >= 9 (512 bytes minimum)" "got lbads=${lbads}"
	fi
}

test_active_lbaf_valid() {
	local flbas nlbaf
	flbas=$(ns_get_field "flbas")
	nlbaf=$(ns_get_field "nlbaf")
	if [ -z "$flbas" ] || [ -z "$nlbaf" ]; then
		log_skip "Active LBA format has valid lbads" "flbas or nlbaf not available"
		return
	fi
	local flbas_int=$((flbas))
	local active_fmt=$(( flbas_int & 0xf ))
	local active_line
	active_line=$(echo "$NS_DATA" | grep "^lbaf *${active_fmt} " | head -1)
	if [ -z "$active_line" ]; then
		log_fail "Active LBA format ${active_fmt} entry exists" "not found in output"
		return
	fi
	local lbads
	lbads=$(echo "$active_line" | grep -oP 'lbads:(\d+)' | cut -d: -f2)
	if [ -n "$lbads" ] && [ "$lbads" -ge 9 ] && [ "$lbads" -le 16 ]; then
		local block_size=$((1 << lbads))
		log_pass "Active LBA format ${active_fmt} has valid lbads=${lbads} (${block_size} bytes)"
	elif [ -n "$lbads" ]; then
		log_fail "Active LBA format lbads in range 9-16" "got lbads=${lbads}"
	else
		log_fail "Active LBA format lbads parseable" "could not extract lbads"
	fi
}

# --------------------------------------------------------------------------
# Deep Validation Tests
# --------------------------------------------------------------------------

test_nsfeat_decode() {
	local val
	val=$(ns_get_field "nsfeat")
	if [ -z "$val" ]; then
		log_skip "nsfeat bit decode" "not present"
		return
	fi
	local nsfeat_int=$((val))
	local thin=$(( nsfeat_int & 0x1 ))
	local na=$(( (nsfeat_int >> 1) & 0x1 ))
	local dulbe=$(( (nsfeat_int >> 2) & 0x1 ))
	local uidreuse=$(( (nsfeat_int >> 3) & 0x1 ))
	local optperf=$(( (nsfeat_int >> 4) & 0x3 ))
	log_pass "nsfeat decode (0x$(printf '%02x' "$nsfeat_int")): thin=${thin} ns_atomic=${na} dulbe=${dulbe} uid_reuse=${uidreuse} optperf=${optperf}"
}

test_mc_decode() {
	local val
	val=$(ns_get_field "mc")
	if [ -z "$val" ]; then
		log_skip "mc bit decode" "not present"
		return
	fi
	local mc_int=$((val))
	local extdlba=$(( mc_int & 0x1 ))
	local mdp=$(( (mc_int >> 1) & 0x1 ))
	log_pass "mc decode (0x$(printf '%02x' "$mc_int")): extended_lba=${extdlba} metadata_pointer=${mdp}"
}

test_dpc_decode() {
	local val
	val=$(ns_get_field "dpc")
	if [ -z "$val" ]; then
		log_skip "dpc bit decode" "not present"
		return
	fi
	local dpc_int=$((val))
	local pit1=$(( dpc_int & 0x1 ))
	local pit2=$(( (dpc_int >> 1) & 0x1 ))
	local pit3=$(( (dpc_int >> 2) & 0x1 ))
	local pif8=$(( (dpc_int >> 3) & 0x1 ))
	local pil8=$(( (dpc_int >> 4) & 0x1 ))
	log_pass "dpc decode (0x$(printf '%02x' "$dpc_int")): PI_T1=${pit1} PI_T2=${pit2} PI_T3=${pit3} first_bytes=${pif8} last_bytes=${pil8}"
}

test_dps_vs_dpc() {
	local dps dpc
	dps=$(ns_get_field "dps")
	dpc=$(ns_get_field "dpc")
	if [ -z "$dps" ] || [ -z "$dpc" ]; then
		log_skip "dps vs dpc cross-check" "fields not present"
		return
	fi
	local dps_int=$((dps))
	local dpc_int=$((dpc))
	local pit=$(( dps_int & 0x7 ))
	if [ "$pit" -eq 0 ]; then
		log_pass "dps: PI disabled (pit=0)"
		return
	fi
	if [ "$pit" -ge 1 ] && [ "$pit" -le 3 ]; then
		local dpc_bit=$(( (dpc_int >> (pit - 1)) & 0x1 ))
		if [ "$dpc_bit" -eq 1 ]; then
			log_pass "dps: PI type ${pit} enabled and supported by dpc (bit $((pit - 1))=1)"
		else
			log_fail "dps PI type must be supported by dpc" "dps selects type ${pit} but dpc bit $((pit - 1))=0"
		fi
	else
		log_fail "dps PI type must be 0-3" "got pit=${pit}"
	fi
}

test_rescap_decode() {
	local val
	val=$(ns_get_field "rescap")
	if [ -z "$val" ]; then
		log_skip "rescap bit decode" "not present"
		return
	fi
	local rc_int=$((val))
	local ptpl=$(( rc_int & 0x1 ))
	local we=$(( (rc_int >> 1) & 0x1 ))
	local ea=$(( (rc_int >> 2) & 0x1 ))
	local wero=$(( (rc_int >> 3) & 0x1 ))
	local earo=$(( (rc_int >> 4) & 0x1 ))
	local wear=$(( (rc_int >> 5) & 0x1 ))
	local eaar=$(( (rc_int >> 6) & 0x1 ))
	local iekr=$(( (rc_int >> 7) & 0x1 ))
	log_pass "rescap decode (0x$(printf '%02x' "$rc_int")): ptpl=${ptpl} we=${we} ea=${ea} wero=${wero} earo=${earo} wear=${wear} eaar=${eaar} iekr=${iekr}"
}

test_fpi_decode() {
	local val
	val=$(ns_get_field "fpi")
	if [ -z "$val" ]; then
		log_skip "fpi decode" "not present"
		return
	fi
	local fpi_int=$((val))
	local fpis=$(( (fpi_int >> 7) & 0x1 ))
	local fpii=$(( fpi_int & 0x7F ))
	if [ "$fpis" -eq 1 ]; then
		log_pass "fpi: Format Progress Indicator supported, remaining=${fpii}%"
	else
		log_pass "fpi: Format Progress Indicator not supported (fpis=0)"
	fi
}

test_dlfeat_decode() {
	if ! ver_at_least 1 3; then
		log_skip "dlfeat decode" "requires NVMe 1.3+"
		return
	fi
	local val
	val=$(ns_get_field "dlfeat")
	if [ -z "$val" ]; then
		log_skip "dlfeat decode" "not present"
		return
	fi
	local dl_int=$((val))
	local read_behavior=$(( dl_int & 0x7 ))
	local dwz=$(( (dl_int >> 3) & 0x1 ))
	local guard=$(( (dl_int >> 4) & 0x1 ))
	local rb_name=""
	case "$read_behavior" in
		0) rb_name="not reported" ;;
		1) rb_name="all zeros" ;;
		2) rb_name="all ones" ;;
		*) rb_name="reserved(${read_behavior})" ;;
	esac
	log_pass "dlfeat decode (0x$(printf '%02x' "$dl_int")): read_behavior=${rb_name} dealloc_write_zeroes=${dwz} guard_crc=${guard}"
}

test_nvmcap_vs_nsze() {
	if ! ver_at_least 1 3; then
		log_skip "nvmcap vs nsze cross-check" "requires NVMe 1.3+"
		return
	fi
	local nvmcap_raw nsze flbas
	nvmcap_raw=$(echo "$NS_DATA" | grep "^nvmcap[[:space:]:]" | sed 's/^nvmcap[[:space:]]*:[[:space:]]*//' || true)
	nsze=$(ns_get_field "nsze")
	flbas=$(ns_get_field "flbas")
	if [ -z "$nvmcap_raw" ] || [ -z "$nsze" ] || [ -z "$flbas" ]; then
		log_skip "nvmcap vs nsze cross-check" "fields not available"
		return
	fi
	local nvmcap_int
	nvmcap_int=$(echo "$nvmcap_raw" | awk '{ print $1 }')
	nvmcap_int=$((nvmcap_int))
	if [ "$nvmcap_int" -eq 0 ]; then
		log_pass "nvmcap=0 (not reported) — cross-check skipped"
		return
	fi
	local flbas_int=$((flbas))
	local active_fmt=$(( flbas_int & 0xf ))
	local lbaf_line
	lbaf_line=$(echo "$NS_DATA" | grep "^lbaf *${active_fmt} " | head -1)
	if [ -z "$lbaf_line" ]; then
		log_skip "nvmcap vs nsze cross-check" "could not find lbaf ${active_fmt}"
		return
	fi
	local lbads
	lbads=$(echo "$lbaf_line" | grep -oP 'lbads:(\d+)' | cut -d: -f2)
	if [ -z "$lbads" ]; then
		log_skip "nvmcap vs nsze cross-check" "could not parse lbads"
		return
	fi
	local nsze_int=$((nsze))
	local block_size=$((1 << lbads))
	local expected_bytes=$((nsze_int * block_size))
	if [ "$nvmcap_int" -ge "$expected_bytes" ]; then
		log_pass "nvmcap (${nvmcap_int}) >= nsze*block_size (${expected_bytes})"
	else
		log_warn "nvmcap < nsze*block_size" "nvmcap=${nvmcap_int}, expected=${expected_bytes}"
	fi
}

test_nguid_eui64_unique_id() {
	local has_nguid=0
	local has_eui64=0
	if ns_field_present "nguid"; then
		local nguid_val
		nguid_val=$(echo "$NS_DATA" | grep "^nguid " | sed 's/^nguid *: *//')
		if echo "$nguid_val" | grep -qP '[^0 ]'; then
			has_nguid=1
		fi
	fi
	if ns_field_present "eui64"; then
		local eui64_val
		eui64_val=$(echo "$NS_DATA" | grep "^eui64 " | sed 's/^eui64 *: *//')
		if echo "$eui64_val" | grep -qP '[^0 ]'; then
			has_eui64=1
		fi
	fi
	if [ "$has_nguid" -eq 1 ] || [ "$has_eui64" -eq 1 ]; then
		log_pass "Namespace has unique identifier (nguid=${has_nguid}, eui64=${has_eui64})"
	else
		log_warn "No unique namespace identifier" "both nguid and eui64 are all zeros"
	fi
}

test_all_lbaf_validation() {
	local nlbaf
	nlbaf=$(ns_get_field "nlbaf")
	if [ -z "$nlbaf" ]; then
		log_skip "All LBA format validation" "nlbaf not present"
		return
	fi
	local nlbaf_int=$((nlbaf))
	local valid=0
	local invalid=0
	local i
	for i in $(seq 0 "$nlbaf_int"); do
		local lbaf_line
		lbaf_line=$(echo "$NS_DATA" | grep "^lbaf *${i} " | head -1)
		if [ -z "$lbaf_line" ]; then
			continue
		fi
		local lbads
		lbads=$(echo "$lbaf_line" | grep -oP 'lbads:(\d+)' | cut -d: -f2)
		if [ -z "$lbads" ] || [ "$lbads" -eq 0 ]; then
			continue
		elif [ "$lbads" -ge 9 ]; then
			valid=$((valid + 1))
		else
			invalid=$((invalid + 1))
		fi
	done
	if [ "$invalid" -eq 0 ]; then
		log_pass "All $((nlbaf_int + 1)) LBA formats have valid lbads >= 9 (${valid} checked)"
	else
		log_fail "All LBA formats must have lbads >= 9" "${invalid} format(s) with lbads < 9"
	fi
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

main() {
	preflight_checks

	local ns_dev ctrl_dev

	if [ $# -eq 0 ]; then
		ctrl_dev=$(auto_detect_ctrl)
		ns_dev=$(resolve_ns_dev "$ctrl_dev")
		echo -e "${BOLD}No device specified — auto-detected: ${ns_dev}${RESET}"
	elif [ "$1" = "-h" ] || [ "$1" = "--help" ]; then
		echo "Usage: $0 [/dev/nvmeXnY | /dev/nvmeX]"
		echo "Verifies NVMe Identify Namespace Data per NVMe Base Spec 2.1."
		exit 0
	else
		if [[ "$1" =~ ^/dev/nvme[0-9]+n[0-9]+$ ]]; then
			ns_dev="$1"
			ctrl_dev="${1%n*}"
		else
			ctrl_dev=$(resolve_ctrl_dev "$1")
			ns_dev=$(resolve_ns_dev "$ctrl_dev")
		fi
	fi

	if [ ! -e "$ns_dev" ]; then
		echo "ERROR: Namespace device $ns_dev does not exist." >&2
		exit 1
	fi

	cache_id_ctrl "$ctrl_dev"
	init_log "nvme_id_ns_verify" "$ns_dev"
	log_cmd "Identify Controller (cached)" "nvme id-ctrl ${ctrl_dev}" "$_ID_CTRL_CACHE"

	local spec_ref
	spec_ref=$(get_spec_ref "id-ns")

	print_header \
		"NVMe Identify Namespace — Verification" \
		"$spec_ref" \
		"$ctrl_dev (namespace: ${ns_dev})"

	NS_DATA=$(nvme id-ns "$ns_dev" 2>&1)
	if [ $? -ne 0 ]; then
		echo "ERROR: Failed to run 'nvme id-ns ${ns_dev}':" >&2
		echo "$NS_DATA" >&2
		exit 1
	fi
	log_cmd "Identify Namespace" "nvme id-ns ${ns_dev}" "$NS_DATA"

	echo -e "${BOLD}--- Namespace Size & Capacity ---${RESET}"
	test_nsze
	test_ncap
	test_nuse

	echo ""
	echo -e "${BOLD}--- Namespace Features & Format ---${RESET}"
	test_nsfeat
	test_nlbaf
	test_flbas
	test_mc
	test_dpc
	test_dps

	echo ""
	echo -e "${BOLD}--- Multi-path, Reservations & Format ---${RESET}"
	test_nmic
	test_rescap
	test_fpi
	test_dlfeat

	echo ""
	echo -e "${BOLD}--- Atomic Write Parameters ---${RESET}"
	test_nawun
	test_nawupf
	test_nacwu
	test_nabsn
	test_nabo
	test_nabspf
	test_noiob

	echo ""
	echo -e "${BOLD}--- Capacity & Identifiers ---${RESET}"
	test_nvmcap
	test_anagrpid
	test_nvmsetid
	test_endgid
	test_nguid
	test_eui64

	echo ""
	echo -e "${BOLD}--- LBA Format Validation ---${RESET}"
	test_lbaf0
	test_active_lbaf_valid

	echo ""
	echo -e "${BOLD}--- Deep Field Validation ---${RESET}"
	test_nsfeat_decode
	test_mc_decode
	test_dpc_decode
	test_dps_vs_dpc
	test_rescap_decode
	test_fpi_decode
	test_dlfeat_decode
	test_nvmcap_vs_nsze
	test_nguid_eui64_unique_id
	test_all_lbaf_validation

	print_summary

	if [ "$FAIL_COUNT" -gt 0 ]; then
		exit 1
	fi
	exit 0
}

main "$@"
