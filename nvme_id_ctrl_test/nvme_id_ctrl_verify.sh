#!/bin/bash
# SPDX-License-Identifier: GPL-3.0+
# Copyright (C) 2025 Red Hat, Inc.
#
# Standalone NVMe Identify Controller mandatory field verification
# Based on NVMe Base Specification, Revision 2.4
# Section 5.2.14.2.1, Figure 338 — Identify Controller Data Structure
# Covers ALL mandatory (M) fields for I/O controllers with version-conditional checks
# Version gates: fields introduced in 1.2, 1.4, 2.0, 2.1, 2.4 are skipped on older controllers
#
# Usage:
#   ./nvme_id_ctrl_verify.sh /dev/nvme0
#   ./nvme_id_ctrl_verify.sh /dev/nvme0n1
#   ./nvme_id_ctrl_verify.sh              # auto-detects first NVMe controller

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/nvme_test_lib.sh
source "${SCRIPT_DIR}/../common/nvme_test_lib.sh"

NVME_VER=""

get_field() {
	echo "$ID_CTRL" | grep "^$1 " | awk '{ print $3 }'
}

get_string_field() {
	echo "$ID_CTRL" | grep "^$1 " | sed "s/^$1 *: *//"
}

ver_at_least() {
	local req_major=$1
	local req_minor=$2
	local ver_val
	ver_val=$(get_field "ver")
	if [ -z "$ver_val" ] || [ "$ver_val" = "0" ] || [ "$ver_val" = "0x0" ]; then
		return 1
	fi
	local ver_int=$((ver_val))
	local major=$(( (ver_int >> 16) & 0xffff ))
	local minor=$(( (ver_int >> 8) & 0xff ))
	if [ "$major" -gt "$req_major" ]; then
		return 0
	elif [ "$major" -eq "$req_major" ] && [ "$minor" -ge "$req_minor" ]; then
		return 0
	fi
	return 1
}

# --------------------------------------------------------------------------
# Test functions — one per mandatory field or group
# --------------------------------------------------------------------------

test_vid() {
	local val
	val=$(get_field "vid")
	if [ -n "$val" ] && [ "$val" != "0" ] && [ "$val" != "0x0" ]; then
		log_pass "VID (PCI Vendor ID) is non-zero (${val})"
	else
		log_fail "VID (PCI Vendor ID) is non-zero" "vid=${val:-<empty>}"
	fi
}

test_ssvid() {
	local val
	val=$(get_field "ssvid")
	if [ -n "$val" ] && [ "$val" != "0" ] && [ "$val" != "0x0" ]; then
		log_pass "SSVID (PCI Subsystem Vendor ID) is non-zero (${val})"
	else
		log_fail "SSVID (PCI Subsystem Vendor ID) is non-zero" "ssvid=${val:-<empty>}"
	fi
}

test_sn() {
	local val
	val=$(get_string_field "sn")
	val=$(echo "$val" | sed 's/ *$//')
	if [ -n "$val" ]; then
		log_pass "SN (Serial Number) is non-empty (${val})"
	else
		log_fail "SN (Serial Number) is non-empty" "sn is empty"
	fi
}

test_mn() {
	local val
	val=$(get_string_field "mn")
	val=$(echo "$val" | sed 's/ *$//')
	if [ -n "$val" ]; then
		log_pass "MN (Model Number) is non-empty (${val})"
	else
		log_fail "MN (Model Number) is non-empty" "mn is empty"
	fi
}

test_fr() {
	local val
	val=$(get_string_field "fr")
	val=$(echo "$val" | sed 's/ *$//')
	if [ -n "$val" ]; then
		log_pass "FR (Firmware Revision) is non-empty (${val})"
	else
		log_fail "FR (Firmware Revision) is non-empty" "fr is empty"
	fi
}

test_mdts() {
	local val
	val=$(get_field "mdts")
	if [ -n "$val" ]; then
		log_pass "MDTS (Maximum Data Transfer Size) is reported (${val})"
	else
		log_fail "MDTS (Maximum Data Transfer Size) is reported" "not present"
	fi
}

test_cntlid() {
	local val
	val=$(get_field "cntlid")
	if [ -n "$val" ]; then
		log_pass "CNTLID (Controller ID) is reported (${val})"
	else
		log_fail "CNTLID (Controller ID) is reported" "not present"
	fi
}

test_ver() {
	local val
	val=$(get_field "ver")
	if [ -n "$val" ] && [ "$val" != "0" ] && [ "$val" != "0x0" ]; then
		local ver_int major minor tertiary
		ver_int=$((val))
		major=$(( (ver_int >> 16) & 0xffff ))
		minor=$(( (ver_int >> 8) & 0xff ))
		tertiary=$(( ver_int & 0xff ))
		NVME_VER="${major}.${minor}.${tertiary}"
		log_pass "VER (NVMe Version) is non-zero (${NVME_VER})"
	else
		NVME_VER="0.0.0"
		log_fail "VER (NVMe Version) is non-zero — required since NVMe 1.2" "ver=${val:-<empty>}"
	fi
}

test_cntrltype() {
	if ! ver_at_least 1 4; then
		local val
		val=$(get_field "cntrltype")
		if [ -n "$val" ] && [ "$val" != "0" ]; then
			log_pass "CNTRLTYPE (Controller Type) is valid (${val}, pre-1.4 but reported)"
		else
			log_skip "CNTRLTYPE (Controller Type) is valid" "requires NVMe 1.4+ (ver reports pre-1.4)"
		fi
		return
	fi
	local val
	val=$(get_field "cntrltype")
	if [ -z "$val" ]; then
		log_fail "CNTRLTYPE (Controller Type) is valid" "not present"
		return
	fi
	local type_name=""
	case "$val" in
		1) type_name="I/O controller" ;;
		2) type_name="Discovery controller" ;;
		3) type_name="Administrative controller" ;;
		0) log_fail "CNTRLTYPE (Controller Type) is valid" "value 0 (not reported) — required since NVMe 1.4"; return ;;
		*) log_fail "CNTRLTYPE (Controller Type) is valid" "unknown value ${val}"; return ;;
	esac
	log_pass "CNTRLTYPE (Controller Type) is valid (${val} = ${type_name})"
}

test_sqes() {
	local val
	val=$(get_field "sqes")
	if [ -z "$val" ]; then
		log_fail "SQES minimum SQ entry size is 64 bytes" "not present"
		return
	fi
	local sqes_min=$(( val & 0xf ))
	local sqes_max=$(( (val >> 4) & 0xf ))
	if [ "$sqes_min" -eq 6 ]; then
		log_pass "SQES minimum SQ entry size is 64 bytes (min=2^${sqes_min}, max=2^${sqes_max})"
	else
		log_fail "SQES minimum SQ entry size is 64 bytes" "sqes_min=${sqes_min}, expected 6"
	fi
}

test_cqes() {
	local val
	val=$(get_field "cqes")
	if [ -z "$val" ]; then
		log_fail "CQES minimum CQ entry size is 16 bytes" "not present"
		return
	fi
	local cqes_min=$(( val & 0xf ))
	local cqes_max=$(( (val >> 4) & 0xf ))
	if [ "$cqes_min" -eq 4 ]; then
		log_pass "CQES minimum CQ entry size is 16 bytes (min=2^${cqes_min}, max=2^${cqes_max})"
	else
		log_fail "CQES minimum CQ entry size is 16 bytes" "cqes_min=${cqes_min}, expected 4"
	fi
}

test_nn() {
	local val
	val=$(get_field "nn")
	if [ -n "$val" ] && [ "$val" -gt 0 ] 2>/dev/null; then
		log_pass "NN (Number of Namespaces) is non-zero (${val})"
	else
		log_fail "NN (Number of Namespaces) is non-zero" "nn=${val:-<empty>}"
	fi
}

test_frmw() {
	local val
	val=$(get_field "frmw")
	if [ -z "$val" ]; then
		log_fail "FRMW reports at least one firmware slot" "not present"
		return
	fi
	local nofs=$(( (val >> 1) & 0x7 ))
	local ffsro=$(( val & 0x1 ))
	local fawr=$(( (val >> 4) & 0x1 ))
	local smud=$(( (val >> 5) & 0x1 ))
	if [ "$nofs" -ge 1 ] && [ "$nofs" -le 7 ]; then
		log_pass "FRMW reports at least one firmware slot (slots=${nofs}, ffsro=${ffsro}, fawr=${fawr}, smud=${smud})"
	else
		log_fail "FRMW reports at least one firmware slot" "nofs=${nofs}"
	fi
}

test_lpa() {
	local val
	val=$(get_field "lpa")
	if [ -n "$val" ]; then
		local smarts=$(( val & 0x1 ))
		local cses=$(( (val >> 1) & 0x1 ))
		log_pass "LPA (Log Page Attributes) is reported (0x$(printf '%02x' "$val"), smarts=${smarts}, cses=${cses})"
	else
		log_fail "LPA (Log Page Attributes) is reported" "not present"
	fi
}

test_elpe() {
	local val
	val=$(get_field "elpe")
	if [ -n "$val" ]; then
		log_pass "ELPE (Error Log Page Entries) is reported ($((val + 1)) entries)"
	else
		log_fail "ELPE (Error Log Page Entries) is reported" "not present"
	fi
}

test_npss() {
	local val
	val=$(get_field "npss")
	if [ -n "$val" ]; then
		log_pass "NPSS (Number of Power States Support) is reported ($((val + 1)) states)"
	else
		log_fail "NPSS (Number of Power States Support) is reported" "not present"
	fi
}

test_oacs() {
	local val
	val=$(get_field "oacs")
	if [ -z "$val" ]; then
		log_fail "OACS (Optional Admin Command Support) is reported" "not present"
		return
	fi
	local ssrs=$(( val & 0x1 ))
	local fnvms=$(( (val >> 1) & 0x1 ))
	local fwds=$(( (val >> 2) & 0x1 ))
	local nms=$(( (val >> 3) & 0x1 ))
	local dsts=$(( (val >> 4) & 0x1 ))
	log_pass "OACS (Optional Admin Command Support) is reported (0x$(printf '%04x' "$val"), sec=${ssrs} fmt=${fnvms} fw=${fwds} ns=${nms} dst=${dsts})"
}

test_acl() {
	local val
	val=$(get_field "acl")
	if [ -n "$val" ]; then
		log_pass "ACL (Abort Command Limit) is reported ($((val + 1)) commands)"
	else
		log_fail "ACL (Abort Command Limit) is reported" "not present"
	fi
}

test_aerl() {
	local val
	val=$(get_field "aerl")
	if [ -n "$val" ]; then
		log_pass "AERL (Async Event Request Limit) is reported ($((val + 1)) events)"
	else
		log_fail "AERL (Async Event Request Limit) is reported" "not present"
	fi
}

test_oncs() {
	local val
	val=$(get_field "oncs")
	if [ -z "$val" ]; then
		log_fail "ONCS (Optional NVM Command Support) is reported" "not present"
		return
	fi
	local cmp=$(( val & 0x1 ))
	local wus=$(( (val >> 1) & 0x1 ))
	local dsm=$(( (val >> 2) & 0x1 ))
	local wzs=$(( (val >> 3) & 0x1 ))
	log_pass "ONCS (Optional NVM Command Support) is reported (0x$(printf '%04x' "$val"), cmp=${cmp} wu=${wus} dsm=${dsm} wz=${wzs})"
}

test_wctemp() {
	local val
	val=$(get_field "wctemp")
	if [ -z "$val" ]; then
		log_fail "WCTEMP (Warning Composite Temp Threshold) is reported" "not present"
		return
	fi
	if [ "$val" -gt 0 ] 2>/dev/null; then
		local celsius=$(( val - 273 ))
		log_pass "WCTEMP (Warning Composite Temp Threshold) is non-zero (${val}K / ${celsius}C)"
	else
		if ver_at_least 1 2; then
			log_fail "WCTEMP (Warning Composite Temp Threshold) is non-zero" "wctemp=0, required non-zero since NVMe 1.2"
		else
			log_pass "WCTEMP (Warning Composite Temp Threshold) is reported (0 — pre-1.2 controller)"
		fi
	fi
}

test_cctemp() {
	local val
	val=$(get_field "cctemp")
	if [ -z "$val" ]; then
		log_fail "CCTEMP (Critical Composite Temp Threshold) is reported" "not present"
		return
	fi
	if [ "$val" -gt 0 ] 2>/dev/null; then
		local celsius=$(( val - 273 ))
		log_pass "CCTEMP (Critical Composite Temp Threshold) is non-zero (${val}K / ${celsius}C)"
	else
		if ver_at_least 1 2; then
			log_fail "CCTEMP (Critical Composite Temp Threshold) is non-zero" "cctemp=0, required non-zero since NVMe 1.2"
		else
			log_pass "CCTEMP (Critical Composite Temp Threshold) is reported (0 — pre-1.2 controller)"
		fi
	fi
}

test_maxcmd() {
	local val
	val=$(get_field "maxcmd")
	if [ -n "$val" ]; then
		if [ "$val" -gt 0 ] 2>/dev/null; then
			log_pass "MAXCMD (Maximum Outstanding Commands) is reported (${val})"
		else
			log_skip "MAXCMD (Maximum Outstanding Commands) is reported" "value 0 — optional for NVMe over PCIe"
		fi
	else
		log_skip "MAXCMD (Maximum Outstanding Commands) is reported" "field not present in output"
	fi
}

test_fwug() {
	if ! ver_at_least 1 3; then
		log_skip "FWUG (Firmware Update Granularity) is reported" "requires NVMe 1.3+"
		return
	fi
	local val
	val=$(get_field "fwug")
	if [ -n "$val" ]; then
		if [ "$val" = "255" ] || [ "$val" = "0xff" ]; then
			log_pass "FWUG (Firmware Update Granularity) is reported (no restriction)"
		elif [ "$val" = "0" ]; then
			log_pass "FWUG (Firmware Update Granularity) is reported (no info provided)"
		else
			local kb=$(( val * 4 ))
			log_pass "FWUG (Firmware Update Granularity) is reported (${kb} KiB)"
		fi
	else
		log_fail "FWUG (Firmware Update Granularity) is reported" "not present"
	fi
}

test_kas() {
	if ! ver_at_least 1 2; then
		log_skip "KAS (Keep Alive Support) is reported" "requires NVMe 1.2+"
		return
	fi
	local val
	val=$(get_field "kas")
	if [ -n "$val" ]; then
		if [ "$val" -gt 0 ] 2>/dev/null; then
			local ms=$(( val * 100 ))
			log_pass "KAS (Keep Alive Support) is reported (${ms} ms)"
		else
			log_pass "KAS (Keep Alive Support) is reported (not supported)"
		fi
	else
		log_skip "KAS (Keep Alive Support) is reported" "field not present"
	fi
}

test_ieee() {
	local val
	val=$(echo "$ID_CTRL" | grep "^ieee " | awk '{ print $3 }')
	if [ -n "$val" ] && [ "$val" != "000000" ]; then
		log_pass "IEEE OUI Identifier is non-zero (${val})"
	else
		log_fail "IEEE OUI Identifier is non-zero" "ieee=${val:-<empty>}"
	fi
}

test_rab() {
	local val
	val=$(get_field "rab")
	if [ -n "$val" ]; then
		log_pass "RAB (Recommended Arbitration Burst) is reported (${val})"
	else
		log_fail "RAB (Recommended Arbitration Burst) is reported" "not present"
	fi
}

test_rtd3r() {
	if ! ver_at_least 1 2; then
		log_skip "RTD3R (D3 Resume Latency) is reported" "requires NVMe 1.2+"
		return
	fi
	local val
	val=$(get_field "rtd3r")
	if [ -n "$val" ]; then
		if [ "$val" = "0" ] || [ "$val" = "0x0" ]; then
			log_pass "RTD3R (D3 Resume Latency) is reported (not reported by controller)"
		else
			local us=$((val))
			log_pass "RTD3R (D3 Resume Latency) is reported (${us} us)"
		fi
	else
		log_fail "RTD3R (D3 Resume Latency) is reported" "not present"
	fi
}

test_rtd3e() {
	if ! ver_at_least 1 2; then
		log_skip "RTD3E (D3 Entry Latency) is reported" "requires NVMe 1.2+"
		return
	fi
	local val
	val=$(get_field "rtd3e")
	if [ -n "$val" ]; then
		if [ "$val" = "0" ] || [ "$val" = "0x0" ]; then
			log_pass "RTD3E (D3 Entry Latency) is reported (not reported by controller)"
		else
			local us=$((val))
			log_pass "RTD3E (D3 Entry Latency) is reported (${us} us)"
		fi
	else
		log_fail "RTD3E (D3 Entry Latency) is reported" "not present"
	fi
}

test_oaes() {
	if ! ver_at_least 1 2; then
		log_skip "OAES (Optional Async Event Support) is reported" "requires NVMe 1.2+"
		return
	fi
	local val
	val=$(get_field "oaes")
	if [ -n "$val" ]; then
		log_pass "OAES (Optional Async Event Support) is reported (0x$(printf '%08x' "$((val))"))"
	else
		log_fail "OAES (Optional Async Event Support) is reported" "not present"
	fi
}

test_ctratt() {
	if ! ver_at_least 1 3; then
		log_skip "CTRATT (Controller Attributes) is reported" "requires NVMe 1.3+"
		return
	fi
	local val
	val=$(get_field "ctratt")
	if [ -n "$val" ]; then
		log_pass "CTRATT (Controller Attributes) is reported (0x$(printf '%08x' "$((val))"))"
	else
		log_fail "CTRATT (Controller Attributes) is reported" "not present"
	fi
}

test_bpcap() {
	if ! ver_at_least 1 4; then
		log_skip "BPCAP (Boot Partition Capabilities) is reported" "requires NVMe 1.4+"
		return
	fi
	local val
	val=$(get_field "bpcap")
	if [ -n "$val" ]; then
		log_pass "BPCAP (Boot Partition Capabilities) is reported (0x$(printf '%04x' "$((val))"))"
	else
		log_fail "BPCAP (Boot Partition Capabilities) is reported" "not present"
	fi
}

test_nvmsr() {
	if ! ver_at_least 1 4; then
		log_skip "NVMSR (NVM Subsystem Report) is reported" "requires NVMe 1.4+"
		return
	fi
	local val
	val=$(get_field "nvmsr")
	if [ -n "$val" ]; then
		local nvmesd=$(( val & 0x1 ))
		local nvmee=$(( (val >> 1) & 0x1 ))
		log_pass "NVMSR (NVM Subsystem Report) is reported (nvmesd=${nvmesd}, nvmee=${nvmee})"
	else
		log_fail "NVMSR (NVM Subsystem Report) is reported" "not present"
	fi
}

test_vwci() {
	if ! ver_at_least 1 4; then
		log_skip "VWCI (VPD Write Cycle Info) is reported" "requires NVMe 1.4+"
		return
	fi
	local val
	val=$(get_field "vwci")
	if [ -n "$val" ]; then
		local vwcrv=$(( (val >> 7) & 0x1 ))
		local vwcr=$(( val & 0x7f ))
		if [ "$vwcrv" -eq 1 ]; then
			log_pass "VWCI (VPD Write Cycle Info) is reported (remaining=${vwcr} x256B, valid)"
		else
			log_pass "VWCI (VPD Write Cycle Info) is reported (remaining count not valid)"
		fi
	else
		log_fail "VWCI (VPD Write Cycle Info) is reported" "not present"
	fi
}

test_mec() {
	if ! ver_at_least 1 4; then
		log_skip "MEC (Management Endpoint Capabilities) is reported" "requires NVMe 1.4+"
		return
	fi
	local val
	val=$(get_field "mec")
	if [ -n "$val" ]; then
		local twpme=$(( val & 0x1 ))
		local pcieme=$(( (val >> 1) & 0x1 ))
		log_pass "MEC (Management Endpoint Capabilities) is reported (twpme=${twpme}, pcieme=${pcieme})"
	else
		log_fail "MEC (Management Endpoint Capabilities) is reported" "not present"
	fi
}

test_avscc() {
	local val
	val=$(get_field "avscc")
	if [ -n "$val" ]; then
		local vscf=$(( val & 0x1 ))
		log_pass "AVSCC (Admin Vendor Specific Cmd Config) is reported (vscf=${vscf})"
	else
		log_fail "AVSCC (Admin Vendor Specific Cmd Config) is reported" "not present"
	fi
}

test_cqt() {
	if ! ver_at_least 2 1; then
		log_skip "CQT (Command Quiesce Time) is reported" "requires NVMe 2.1+"
		return
	fi
	local val
	val=$(get_field "cqt")
	if [ -n "$val" ]; then
		log_pass "CQT (Command Quiesce Time) is reported (${val} ms)"
	else
		log_fail "CQT (Command Quiesce Time) is reported" "not present"
	fi
}

test_nssl() {
	if ! ver_at_least 2 4; then
		log_skip "NSSL (NVM Subsystem Shutdown Latency) is reported" "requires NVMe 2.4+"
		return
	fi
	local val
	val=$(get_field "nssl")
	if [ -n "$val" ]; then
		log_pass "NSSL (NVM Subsystem Shutdown Latency) is reported (${val})"
	else
		log_fail "NSSL (NVM Subsystem Shutdown Latency) is reported" "not present"
	fi
}

test_plsi() {
	if ! ver_at_least 2 4; then
		log_skip "PLSI (Power Loss Signaling Information) is reported" "requires NVMe 2.4+"
		return
	fi
	local val
	val=$(get_field "plsi")
	if [ -n "$val" ]; then
		local plsi_int=$((val))
		local plsepf=$(( plsi_int & 0x1 ))
		local plsfq=$(( (plsi_int >> 1) & 0x1 ))
		log_pass "PLSI (Power Loss Signaling Information) is reported (0x$(printf '%02x' "$plsi_int"), plsepf=${plsepf}, plsfq=${plsfq})"
	else
		log_fail "PLSI (Power Loss Signaling Information) is reported" "not present"
	fi
}

test_crcap() {
	if ! ver_at_least 2 4; then
		log_skip "CRCAP (Controller Reachability Capabilities) is reported" "requires NVMe 2.4+"
		return
	fi
	local val
	val=$(get_field "crcap")
	if [ -n "$val" ]; then
		local crcap_int=$((val))
		local rrsup=$(( crcap_int & 0x1 ))
		local rgidc=$(( (crcap_int >> 1) & 0x1 ))
		log_pass "CRCAP (Controller Reachability Capabilities) is reported (0x$(printf '%02x' "$crcap_int"), rrsup=${rrsup}, rgidc=${rgidc})"
	else
		log_fail "CRCAP (Controller Reachability Capabilities) is reported" "not present"
	fi
}

test_mptfawr() {
	if ! ver_at_least 2 4; then
		log_skip "MPTFAWR (Max Processing Time for FW Activation Without Reset) is reported" "requires NVMe 2.4+"
		return
	fi
	local val
	val=$(get_field "mptfawr")
	if [ -n "$val" ]; then
		local mptfawr_int=$((val))
		if [ "$mptfawr_int" -eq 0 ]; then
			log_pass "MPTFAWR (Max Processing Time for FW Activation Without Reset) is reported (no limit)"
		else
			local ms=$(( mptfawr_int * 100 ))
			log_pass "MPTFAWR (Max Processing Time for FW Activation Without Reset) is reported (${ms} ms)"
		fi
	else
		log_fail "MPTFAWR (Max Processing Time for FW Activation Without Reset) is reported" "not present"
	fi
}

test_megcap() {
	if ! ver_at_least 2 4; then
		log_skip "MEGCAP (Max Endurance Group Capacity) is reported" "requires NVMe 2.4+"
		return
	fi
	local val
	val=$(echo "$ID_CTRL" | grep "^megcap " | sed 's/^megcap *: *//' | awk '{ print $1 }')
	if [ -n "$val" ]; then
		log_pass "MEGCAP (Max Endurance Group Capacity) is reported (${val})"
	else
		log_fail "MEGCAP (Max Endurance Group Capacity) is reported" "not present"
	fi
}

test_tmpthha() {
	if ! ver_at_least 2 4; then
		log_skip "TMPTHHA (Temperature Threshold Hysteresis Attributes) is reported" "requires NVMe 2.4+"
		return
	fi
	local val
	val=$(get_field "tmpthha")
	if [ -n "$val" ]; then
		local tmpthha_int=$((val))
		local tmpthmh=$(( tmpthha_int & 0x7 ))
		log_pass "TMPTHHA (Temperature Threshold Hysteresis Attributes) is reported (0x$(printf '%02x' "$tmpthha_int"), hysteresis=${tmpthmh})"
	else
		log_fail "TMPTHHA (Temperature Threshold Hysteresis Attributes) is reported" "not present"
	fi
}

test_fuses() {
	local val
	val=$(get_field "fuses")
	if [ -n "$val" ]; then
		local fcws=$(( val & 0x1 ))
		log_pass "FUSES (Fused Operation Support) is reported (fcws=${fcws})"
	else
		log_fail "FUSES (Fused Operation Support) is reported" "not present"
	fi
}

test_fna() {
	local val
	val=$(get_field "fna")
	if [ -n "$val" ]; then
		local fns=$(( val & 0x1 ))
		local sens=$(( (val >> 1) & 0x1 ))
		local cryes=$(( (val >> 2) & 0x1 ))
		local bcnsid=$(( (val >> 3) & 0x1 ))
		log_pass "FNA (Format NVM Attributes) is reported (0x$(printf '%02x' "$val"), fns=${fns} sens=${sens} cryes=${cryes} bcnsid=${bcnsid})"
	else
		log_fail "FNA (Format NVM Attributes) is reported" "not present"
	fi
}

test_vwc() {
	local val
	val=$(get_field "vwc")
	if [ -n "$val" ]; then
		local vwcp=$(( val & 0x1 ))
		local fb=$(( (val >> 1) & 0x3 ))
		if [ "$vwcp" -eq 1 ]; then
			log_pass "VWC (Volatile Write Cache) is reported (present, flush_behavior=${fb})"
		else
			log_pass "VWC (Volatile Write Cache) is reported (not present)"
		fi
	else
		log_fail "VWC (Volatile Write Cache) is reported" "not present"
	fi
}

test_awun() {
	local val
	val=$(get_field "awun")
	if [ -n "$val" ]; then
		log_pass "AWUN (Atomic Write Unit Normal) is reported (${val})"
	else
		log_fail "AWUN (Atomic Write Unit Normal) is reported" "not present"
	fi
}

test_awupf() {
	local val
	val=$(get_field "awupf")
	if [ -n "$val" ]; then
		log_pass "AWUPF (Atomic Write Unit Power Fail) is reported (${val})"
	else
		log_fail "AWUPF (Atomic Write Unit Power Fail) is reported" "not present"
	fi
}

test_icsvscc() {
	local val
	val=$(get_field "icsvscc")
	if [ -n "$val" ]; then
		local snvscf=$(( val & 0x1 ))
		log_pass "ICSVSCC (I/O Cmd Set Vendor Specific Config) is reported (snvscf=${snvscf})"
	else
		log_fail "ICSVSCC (I/O Cmd Set Vendor Specific Config) is reported" "not present"
	fi
}

test_nwpc() {
	if ! ver_at_least 1 4; then
		log_skip "NWPC (Namespace Write Protection Capabilities) is reported" "requires NVMe 1.4+"
		return
	fi
	local val
	val=$(get_field "nwpc")
	if [ -n "$val" ]; then
		local nwpwps=$(( val & 0x1 ))
		local wpupcs=$(( (val >> 1) & 0x1 ))
		local pwps=$(( (val >> 2) & 0x1 ))
		log_pass "NWPC (Namespace Write Protection) is reported (nwpwps=${nwpwps} wpupcs=${wpupcs} pwps=${pwps})"
	else
		log_fail "NWPC (Namespace Write Protection) is reported" "not present"
	fi
}

test_ocfs() {
	if ! ver_at_least 2 0; then
		log_skip "OCFS (Copy Descriptor Formats Supported) is reported" "requires NVMe 2.0+"
		return
	fi
	local val
	val=$(get_field "ocfs")
	if [ -n "$val" ]; then
		log_pass "OCFS (Copy Descriptor Formats Supported) is reported (0x$(printf '%04x' "$((val))"))"
	else
		log_fail "OCFS (Copy Descriptor Formats Supported) is reported" "not present"
	fi
}

test_subnqn() {
	if ! ver_at_least 1 4; then
		log_skip "SUBNQN (NVMe Qualified Name) is reported" "requires NVMe 1.4+"
		return
	fi
	local val
	val=$(get_string_field "subnqn")
	val=$(echo "$val" | sed 's/ *$//')
	if [ -n "$val" ]; then
		if echo "$val" | grep -q "^nqn\."; then
			log_pass "SUBNQN (NVMe Qualified Name) is valid NQN format (${val})"
		else
			log_fail "SUBNQN (NVMe Qualified Name) must start with 'nqn.'" "got '${val}'"
		fi
	else
		log_fail "SUBNQN (NVMe Qualified Name) is reported" "empty or not present"
	fi
}

# --------------------------------------------------------------------------
# Deep Validation Tests (--full mode only)
# --------------------------------------------------------------------------

test_oacs_bit_decode() {
	local val
	val=$(get_field "oacs")
	if [ -z "$val" ]; then
		log_fail "OACS full bit decode" "oacs not present"
		return
	fi
	local oacs_int=$((val))
	local sec=$(( oacs_int & 0x1 ))
	local fmt=$(( (oacs_int >> 1) & 0x1 ))
	local fwc=$(( (oacs_int >> 2) & 0x1 ))
	local nsm=$(( (oacs_int >> 3) & 0x1 ))
	local dst=$(( (oacs_int >> 4) & 0x1 ))
	local dir=$(( (oacs_int >> 5) & 0x1 ))
	local nmi=$(( (oacs_int >> 6) & 0x1 ))
	local vir=$(( (oacs_int >> 7) & 0x1 ))
	local dbc=$(( (oacs_int >> 8) & 0x1 ))
	local glbas=$(( (oacs_int >> 9) & 0x1 ))
	local lock=$(( (oacs_int >> 10) & 0x1 ))
	local hmlms=$(( (oacs_int >> 11) & 0x1 ))
	local enss=$(( (oacs_int >> 12) & 0x1 ))
	local ccfls=$(( (oacs_int >> 13) & 0x1 ))

	local bits_summary="sec=${sec} fmt=${fmt} fw=${fwc} ns=${nsm} dst=${dst} dir=${dir} nmi=${nmi} vir=${vir} dbc=${dbc} lba=${glbas} lock=${lock} hmlms=${hmlms}"
	if ver_at_least 2 4; then
		bits_summary="${bits_summary} enss=${enss} ccfls=${ccfls}"
	fi

	if [ "$fwc" -eq 1 ]; then
		local frmw
		frmw=$(get_field "frmw")
		if [ -n "$frmw" ]; then
			local nofs=$(( (frmw >> 1) & 0x7 ))
			if [ "$nofs" -ge 1 ]; then
				log_pass "OACS bit decode: FW Commit supported (bit 2=1), FRMW slots=${nofs} (${bits_summary})"
			else
				log_fail "OACS cross-check: FW Commit supported but FRMW slots=0" "frmw=0x$(printf '%02x' "$frmw")"
			fi
		else
			log_pass "OACS bit decode: FW Commit supported (bit 2=1) (${bits_summary})"
		fi
	else
		log_pass "OACS bit decode (0x$(printf '%04x' "$oacs_int")): ${bits_summary}"
	fi
}

test_oncs_bit_decode() {
	local val
	val=$(get_field "oncs")
	if [ -z "$val" ]; then
		log_fail "ONCS full bit decode" "oncs not present"
		return
	fi
	local oncs_int=$((val))
	local cmp=$(( oncs_int & 0x1 ))
	local wu=$(( (oncs_int >> 1) & 0x1 ))
	local dsm=$(( (oncs_int >> 2) & 0x1 ))
	local wz=$(( (oncs_int >> 3) & 0x1 ))
	local saf=$(( (oncs_int >> 4) & 0x1 ))
	local rsv=$(( (oncs_int >> 5) & 0x1 ))
	local ts=$(( (oncs_int >> 6) & 0x1 ))
	local vrfy=$(( (oncs_int >> 7) & 0x1 ))
	local copy=$(( (oncs_int >> 8) & 0x1 ))
	local csa=$(( (oncs_int >> 9) & 0x1 ))
	local afc=$(( (oncs_int >> 10) & 0x1 ))
	local maxwzd=$(( (oncs_int >> 11) & 0x1 ))
	local nszs=$(( (oncs_int >> 12) & 0x1 ))
	if ver_at_least 2 4; then
		log_pass "ONCS bit decode (0x$(printf '%04x' "$oncs_int")): cmp=${cmp} wu=${wu} dsm=${dsm} wz=${wz} saf=${saf} rsv=${rsv} ts=${ts} vrfy=${vrfy} copy=${copy} csa=${csa} afc=${afc} maxwzd=${maxwzd} nszs=${nszs}"
	else
		log_pass "ONCS bit decode (0x$(printf '%04x' "$oncs_int")): cmp=${cmp} wu=${wu} dsm=${dsm} wz=${wz} saf=${saf} rsv=${rsv} ts=${ts} vrfy=${vrfy} copy=${copy}"
	fi
}

test_ctratt_bit_decode() {
	if ! ver_at_least 1 3; then
		log_skip "CTRATT full bit decode" "requires NVMe 1.3+"
		return
	fi
	local val
	val=$(get_field "ctratt")
	if [ -z "$val" ]; then
		log_fail "CTRATT full bit decode" "ctratt not present"
		return
	fi
	local ctratt_int=$((val))
	local hids=$(( ctratt_int & 0x1 ))
	local nopspm=$(( (ctratt_int >> 1) & 0x1 ))
	local nsets=$(( (ctratt_int >> 2) & 0x1 ))
	local rrlvls=$(( (ctratt_int >> 3) & 0x1 ))
	local egs=$(( (ctratt_int >> 4) & 0x1 ))
	local plm=$(( (ctratt_int >> 5) & 0x1 ))
	local tbkas=$(( (ctratt_int >> 6) & 0x1 ))
	local ng=$(( (ctratt_int >> 7) & 0x1 ))
	local sqa=$(( (ctratt_int >> 8) & 0x1 ))
	local ulist=$(( (ctratt_int >> 9) & 0x1 ))
	local mds=$(( (ctratt_int >> 10) & 0x1 ))
	local fcm=$(( (ctratt_int >> 11) & 0x1 ))
	local vcm=$(( (ctratt_int >> 12) & 0x1 ))
	local deg=$(( (ctratt_int >> 13) & 0x1 ))
	local dnvms=$(( (ctratt_int >> 14) & 0x1 ))
	local elbas=$(( (ctratt_int >> 15) & 0x1 ))
	local mem=$(( (ctratt_int >> 16) & 0x1 ))
	local hmbr=$(( (ctratt_int >> 17) & 0x1 ))
	local rhii=$(( (ctratt_int >> 18) & 0x1 ))
	local fdps=$(( (ctratt_int >> 19) & 0x1 ))
	if ver_at_least 2 4; then
		local pls=$(( (ctratt_int >> 20) & 0x1 ))
		local pms=$(( (ctratt_int >> 21) & 0x1 ))
		local vms=$(( (ctratt_int >> 22) & 0x1 ))
		local iiellss=$(( (ctratt_int >> 23) & 0x1 ))
		log_pass "CTRATT bit decode (0x$(printf '%08x' "$ctratt_int")): 128id=${hids} nopspm=${nopspm} nsets=${nsets} rrlvls=${rrlvls} egs=${egs} plm=${plm} tbkas=${tbkas} ng=${ng} sqa=${sqa} uuid=${ulist} mds=${mds} fcm=${fcm} vcm=${vcm} deg=${deg} dnvms=${dnvms} elbas=${elbas} mem=${mem} hmbr=${hmbr} rhii=${rhii} fdps=${fdps} pls=${pls} pms=${pms} vms=${vms} iiellss=${iiellss}"
	else
		log_pass "CTRATT bit decode (0x$(printf '%08x' "$ctratt_int")): 128id=${hids} nopspm=${nopspm} nsets=${nsets} rrlvls=${rrlvls} egs=${egs} plm=${plm} tbkas=${tbkas} ng=${ng} sqa=${sqa} uuid=${ulist} mds=${mds} fcm=${fcm} vcm=${vcm} deg=${deg} dnvms=${dnvms} elbas=${elbas} mem=${mem} hmbr=${hmbr} rhii=${rhii} fdps=${fdps}"
	fi
}

test_mdts_reasonable() {
	local val
	val=$(get_field "mdts")
	if [ -z "$val" ]; then
		log_fail "MDTS reasonable transfer size" "not present"
		return
	fi
	local mdts_int=$((val))
	if [ "$mdts_int" -eq 0 ]; then
		log_pass "MDTS=0 (no limit imposed by controller, host-determined)"
		return
	fi
	local max_bytes=$(( (1 << mdts_int) * 4096 ))
	if [ "$max_bytes" -ge 131072 ]; then
		local max_kb=$((max_bytes / 1024))
		log_pass "MDTS=${mdts_int} (max transfer = ${max_kb} KiB >= 128 KiB)"
	else
		local max_kb=$((max_bytes / 1024))
		log_fail "MDTS reasonable transfer size (>= 128 KiB)" "MDTS=${mdts_int} = ${max_kb} KiB"
	fi
}

test_wctemp_cctemp_cross() {
	local wctemp cctemp
	wctemp=$(get_field "wctemp")
	cctemp=$(get_field "cctemp")
	if [ -z "$wctemp" ] || [ -z "$cctemp" ]; then
		log_skip "CCTEMP > WCTEMP cross-validation" "wctemp or cctemp not available"
		return
	fi
	local wc_int=$((wctemp))
	local cc_int=$((cctemp))
	if [ "$wc_int" -eq 0 ] || [ "$cc_int" -eq 0 ]; then
		log_skip "CCTEMP > WCTEMP cross-validation" "one or both thresholds are 0"
		return
	fi
	if [ "$cc_int" -gt "$wc_int" ]; then
		log_pass "CCTEMP (${cc_int}K) > WCTEMP (${wc_int}K)"
	else
		log_fail "CCTEMP must be > WCTEMP" "CCTEMP=${cc_int}K, WCTEMP=${wc_int}K"
	fi
	if [ "$wc_int" -lt 273 ] || [ "$wc_int" -gt 500 ]; then
		log_warn "WCTEMP outside typical range" "WCTEMP=${wc_int}K not in 273K-500K"
	fi
	if [ "$cc_int" -lt 273 ] || [ "$cc_int" -gt 500 ]; then
		log_warn "CCTEMP outside typical range" "CCTEMP=${cc_int}K not in 273K-500K"
	fi
}

test_hctma_thermal() {
	if ! ver_at_least 1 3; then
		log_skip "HCTMA thermal management cross-check" "requires NVMe 1.3+"
		return
	fi
	local hctma
	hctma=$(get_field "hctma")
	if [ -z "$hctma" ]; then
		log_skip "HCTMA thermal management cross-check" "hctma not present"
		return
	fi
	local hctma_int=$((hctma))
	if [ "$((hctma_int & 0x1))" -eq 0 ]; then
		log_pass "HCTMA not supported — thermal management check skipped"
		return
	fi
	local mntmt mxtmt
	mntmt=$(get_field "mntmt")
	mxtmt=$(get_field "mxtmt")
	if [ -z "$mntmt" ] || [ -z "$mxtmt" ]; then
		log_fail "HCTMA supported but MNTMT/MXTMT not present" "missing fields"
		return
	fi
	local mn_int=$((mntmt))
	local mx_int=$((mxtmt))
	if [ "$mn_int" -lt "$mx_int" ]; then
		log_pass "HCTMA: MNTMT (${mn_int}K) < MXTMT (${mx_int}K)"
	else
		log_fail "HCTMA: MNTMT must be < MXTMT" "MNTMT=${mn_int}K, MXTMT=${mx_int}K"
	fi
}

test_tnvmcap_unvmcap() {
	if ! ver_at_least 1 3; then
		log_skip "TNVMCAP/UNVMCAP cross-validation" "requires NVMe 1.3+"
		return
	fi
	local tnvmcap unvmcap
	tnvmcap=$(echo "$ID_CTRL" | grep "^tnvmcap " | sed 's/^tnvmcap *: *//' | awk '{ print $1 }')
	unvmcap=$(echo "$ID_CTRL" | grep "^unvmcap " | sed 's/^unvmcap *: *//' | awk '{ print $1 }')
	if [ -z "$tnvmcap" ] || [ -z "$unvmcap" ]; then
		log_skip "TNVMCAP/UNVMCAP cross-validation" "fields not present"
		return
	fi
	local tn_int=$((tnvmcap))
	local un_int=$((unvmcap))
	if [ "$tn_int" -eq 0 ]; then
		log_pass "TNVMCAP=0 (not reported) — UNVMCAP check skipped"
		return
	fi
	if [ "$un_int" -le "$tn_int" ]; then
		log_pass "UNVMCAP (${un_int}) <= TNVMCAP (${tn_int})"
	else
		log_fail "UNVMCAP must be <= TNVMCAP" "UNVMCAP=${un_int}, TNVMCAP=${tn_int}"
	fi
}

test_awun_awupf_cross() {
	local awun awupf
	awun=$(get_field "awun")
	awupf=$(get_field "awupf")
	if [ -z "$awun" ] || [ -z "$awupf" ]; then
		log_skip "AWUPF <= AWUN cross-validation" "fields not present"
		return
	fi
	local awun_int=$((awun))
	local awupf_int=$((awupf))
	if [ "$awun_int" -eq 0 ] && [ "$awupf_int" -eq 0 ]; then
		log_pass "AWUN=0, AWUPF=0 (default atomic write unit)"
		return
	fi
	if [ "$awupf_int" -le "$awun_int" ]; then
		log_pass "AWUPF (${awupf_int}) <= AWUN (${awun_int})"
	else
		log_fail "AWUPF must be <= AWUN" "AWUPF=${awupf_int}, AWUN=${awun_int}"
	fi
}

test_lpa_bit_decode() {
	local val
	val=$(get_field "lpa")
	if [ -z "$val" ]; then
		log_fail "LPA full bit decode" "not present"
		return
	fi
	local lpa_int=$((val))
	local smlp=$(( lpa_int & 0x1 ))
	local celp=$(( (lpa_int >> 1) & 0x1 ))
	local ed=$(( (lpa_int >> 2) & 0x1 ))
	local telem=$(( (lpa_int >> 3) & 0x1 ))
	local persevnt=$(( (lpa_int >> 4) & 0x1 ))
	local lid_sup=$(( (lpa_int >> 5) & 0x1 ))
	local tel=$(( (lpa_int >> 6) & 0x1 ))
	log_pass "LPA bit decode (0x$(printf '%02x' "$lpa_int")): smlp=${smlp} celp=${celp} ed=${ed} telem=${telem} persevnt=${persevnt} lid_sup=${lid_sup} tel=${tel}"
}

test_sgls_decode() {
	if ! ver_at_least 1 3; then
		log_skip "SGLS decode" "requires NVMe 1.3+"
		return
	fi
	local val
	val=$(get_field "sgls")
	if [ -z "$val" ]; then
		log_skip "SGLS decode" "sgls not present"
		return
	fi
	local sgls_int=$((val))
	local sglsp=$(( sgls_int & 0x3 ))
	local key=$(( (sgls_int >> 2) & 0x1 ))
	local bbs=$(( (sgls_int >> 16) & 0x1 ))
	local bacmdb=$(( (sgls_int >> 17) & 0x1 ))
	local sglltb=$(( (sgls_int >> 18) & 0x1 ))
	local mpcsd=$(( (sgls_int >> 19) & 0x1 ))
	local aofdsl=$(( (sgls_int >> 20) & 0x1 ))
	local trsdbd=$(( (sgls_int >> 21) & 0x1 ))
	log_pass "SGLS decode (0x$(printf '%08x' "$sgls_int")): sglsp=${sglsp} key=${key} bbs=${bbs} bacmdb=${bacmdb} sglltb=${sglltb} mpcsd=${mpcsd} aofdsl=${aofdsl} trsdbd=${trsdbd}"
}

test_sanicap_decode() {
	if ! ver_at_least 1 3; then
		log_skip "SANICAP decode" "requires NVMe 1.3+"
		return
	fi
	local val
	val=$(get_field "sanicap")
	if [ -z "$val" ]; then
		log_skip "SANICAP decode" "sanicap not present"
		return
	fi
	local sanicap_int=$((val))
	local ces=$(( sanicap_int & 0x1 ))
	local bes=$(( (sanicap_int >> 1) & 0x1 ))
	local ows=$(( (sanicap_int >> 2) & 0x1 ))
	local ndi=$(( (sanicap_int >> 29) & 0x1 ))
	local nodmmas=$(( (sanicap_int >> 30) & 0x3 ))
	log_pass "SANICAP decode (0x$(printf '%08x' "$sanicap_int")): ces=${ces} bes=${bes} ows=${ows} ndi=${ndi} nodmmas=${nodmmas}"
}

test_nn_cross_validate() {
	local nn
	nn=$(get_field "nn")
	if [ -z "$nn" ]; then
		log_skip "NN cross-validate with list-ns" "nn not present"
		return
	fi
	local nn_int=$((nn))
	local ctrl_dev
	ctrl_dev=$(echo "$_LOG_DEVICE" | sed 's|n[0-9]*$||')
	if [ -z "$ctrl_dev" ]; then
		log_skip "NN cross-validate with list-ns" "could not determine controller device"
		return
	fi
	local ns_count
	ns_count=$(nvme list-ns "$ctrl_dev" --all 2>/dev/null | grep -c "^\[" || true)
	if [ -z "$ns_count" ] || [ "$ns_count" -eq 0 ]; then
		ns_count=$(nvme list-ns "$ctrl_dev" 2>/dev/null | grep -c "^\[" || true)
	fi
	if [ "$ns_count" -le "$nn_int" ]; then
		log_pass "Active namespaces (${ns_count}) <= NN (${nn_int})"
	else
		log_fail "Active namespaces must be <= NN" "count=${ns_count}, NN=${nn_int}"
	fi
}

test_reserved_bits() {
	local oacs oncs
	oacs=$(get_field "oacs")
	oncs=$(get_field "oncs")
	local fail=0
	if [ -n "$oacs" ]; then
		local oacs_int=$((oacs))
		if ver_at_least 2 4; then
			local oacs_rsvd=$(( (oacs_int >> 14) & 0x3 ))
			if [ "$oacs_rsvd" -ne 0 ]; then
				log_fail "OACS reserved bits [15:14] must be 0 (NVMe 2.4)" "got 0x$(printf '%x' "$oacs_rsvd")"
				fail=1
			fi
		else
			local oacs_rsvd=$(( (oacs_int >> 12) & 0xF ))
			if [ "$oacs_rsvd" -ne 0 ]; then
				log_fail "OACS reserved bits [15:12] must be 0" "got 0x$(printf '%x' "$oacs_rsvd")"
				fail=1
			fi
		fi
	fi
	if [ -n "$oncs" ]; then
		local oncs_int=$((oncs))
		local oncs_rsvd=$(( (oncs_int >> 13) & 0x7 ))
		if [ "$oncs_rsvd" -ne 0 ]; then
			log_fail "ONCS reserved bits [15:13] must be 0" "got 0x$(printf '%x' "$oncs_rsvd")"
			fail=1
		fi
	fi
	if [ "$fail" -eq 0 ]; then
		log_pass "Reserved bits in OACS/ONCS are zero"
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
		echo "Verifies NVMe Identify Controller mandatory fields per NVMe Base Spec 2.4."
		exit 0
	else
		ctrl_dev=$(resolve_ctrl_dev "$1")
	fi

	if [ ! -e "$ctrl_dev" ]; then
		echo "ERROR: Device $ctrl_dev does not exist." >&2
		exit 1
	fi

	ID_CTRL=$(nvme id-ctrl "$ctrl_dev" 2>&1)
	if [ $? -ne 0 ]; then
		echo "ERROR: Failed to run 'nvme id-ctrl ${ctrl_dev}':" >&2
		echo "$ID_CTRL" >&2
		exit 1
	fi

	# Also populate the common lib cache so ver_at_least/get_id_ctrl_field work
	_ID_CTRL_CACHE="$ID_CTRL"

	init_log "nvme_id_ctrl_verify" "$ctrl_dev"
	log_cmd "Identify Controller" "nvme id-ctrl ${ctrl_dev}" "$ID_CTRL"

	local spec_ref
	spec_ref=$(get_spec_ref "id-ctrl")

	print_header \
		"NVMe Identify Controller — Mandatory Field Verification" \
		"$spec_ref" \
		"$ctrl_dev"

	echo -e "${BOLD}--- Controller Capabilities and Features (Bytes 0-255) ---${RESET}"
	test_vid
	test_ssvid
	test_sn
	test_mn
	test_fr
	test_rab
	test_ieee
	test_mdts
	test_cntlid
	test_ver
	test_rtd3r
	test_rtd3e
	test_oaes
	test_ctratt
	test_bpcap
	test_nssl
	test_plsi
	test_cntrltype
	test_crcap
	test_nvmsr
	test_vwci
	test_mec

	echo ""
	echo -e "${BOLD}--- Admin Command Set Attributes (Bytes 256-511) ---${RESET}"
	test_oacs
	test_acl
	test_aerl
	test_frmw
	test_lpa
	test_elpe
	test_npss
	test_avscc
	test_wctemp
	test_cctemp
	test_fwug
	test_kas
	test_mptfawr
	test_megcap
	test_tmpthha
	test_cqt

	echo ""
	echo -e "${BOLD}--- NVM Command Set Attributes (Bytes 512-575) ---${RESET}"
	test_sqes
	test_cqes
	test_maxcmd
	test_nn
	test_oncs
	test_fuses
	test_fna
	test_vwc
	test_awun
	test_awupf
	test_icsvscc
	test_nwpc
	test_ocfs

	echo ""
	echo -e "${BOLD}--- NVM Subsystem Attributes (Bytes 256-1023) ---${RESET}"
	test_subnqn

	echo ""
	echo -e "${BOLD}--- Deep Field Validation ---${RESET}"
	test_oacs_bit_decode
	test_oncs_bit_decode
	test_ctratt_bit_decode
	test_mdts_reasonable
	test_wctemp_cctemp_cross
	test_hctma_thermal
	test_tnvmcap_unvmcap
	test_awun_awupf_cross
	test_lpa_bit_decode
	test_sgls_decode
	test_sanicap_decode
	test_nn_cross_validate
	test_reserved_bits

	print_summary

	if [ "$FAIL_COUNT" -gt 0 ]; then
		exit 1
	fi
	exit 0
}

main "$@"
