#!/bin/bash
# SPDX-License-Identifier: GPL-3.0+
# Copyright (C) 2025 Red Hat, Inc.
#
# Shared library for NVMe certification test scripts.
# Source this file from each test script.

PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
WARN_COUNT=0
TOTAL=0

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BOLD='\033[1m'
RESET='\033[0m'

_ID_CTRL_CACHE=""
LOG_FILE=""
LOG_DIR=""
_LOG_SCRIPT_NAME=""
_LOG_DEVICE=""

# --------------------------------------------------------------------------
# Logging infrastructure
# --------------------------------------------------------------------------

init_log() {
	local script_name="$1"
	local device="$2"
	_LOG_SCRIPT_NAME="$script_name"
	_LOG_DEVICE="$device"

	local proj_root
	proj_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
	LOG_DIR="${proj_root}/logs"
	mkdir -p "$LOG_DIR"

	local dev_short
	dev_short=$(echo "$device" | sed 's|/dev/||')
	local ts
	ts=$(date '+%Y%m%d_%H%M%S')
	LOG_FILE="${LOG_DIR}/${script_name}_${dev_short}_${ts}.log"

	{
		echo "======================================================================"
		echo "  NVMe Certification Test Log"
		echo "  Script:    ${script_name}"
		echo "  Device:    ${device}"
		echo "  Date:      $(date '+%Y-%m-%d %H:%M:%S %Z')"
		echo "  Hostname:  $(hostname)"
		echo "  Kernel:    $(uname -r)"
		echo "  nvme-cli:  $(nvme version 2>/dev/null || echo 'unknown')"
		echo "======================================================================"
		echo ""
	} > "$LOG_FILE"

	echo -e "  ${BOLD}Log file:${RESET}  ${LOG_FILE}"
}

log_cmd() {
	local cmd_desc="$1"
	local cmd_string="$2"
	local cmd_output="$3"

	[ -z "$LOG_FILE" ] && return

	{
		echo "----------------------------------------------------------------------"
		echo "[COMMAND] ${cmd_desc}"
		echo "[RUN]     ${cmd_string}"
		echo "[OUTPUT]"
		echo "$cmd_output"
		echo "----------------------------------------------------------------------"
		echo ""
	} >> "$LOG_FILE"
}

_log_to_file() {
	local status="$1"
	local test_num="$2"
	local message="$3"
	local detail="${4:-}"

	[ -z "$LOG_FILE" ] && return

	{
		if [ -n "$detail" ]; then
			printf "TEST %3d | %-4s | %s [%s]\n" "$test_num" "$status" "$message" "$detail"
		else
			printf "TEST %3d | %-4s | %s\n" "$test_num" "$status" "$message"
		fi
	} >> "$LOG_FILE"
}

# --------------------------------------------------------------------------
# Result reporting (terminal + log file)
# --------------------------------------------------------------------------

log_pass() {
	TOTAL=$((TOTAL + 1))
	PASS_COUNT=$((PASS_COUNT + 1))
	echo -e "  ${GREEN}PASS${RESET}  TEST ${TOTAL} - $1"
	_log_to_file "PASS" "$TOTAL" "$1"
}

log_fail() {
	TOTAL=$((TOTAL + 1))
	FAIL_COUNT=$((FAIL_COUNT + 1))
	echo -e "  ${RED}FAIL${RESET}  TEST ${TOTAL} - $1 [$2]"
	_log_to_file "FAIL" "$TOTAL" "$1" "$2"
}

log_skip() {
	TOTAL=$((TOTAL + 1))
	SKIP_COUNT=$((SKIP_COUNT + 1))
	echo -e "  ${YELLOW}SKIP${RESET}  TEST ${TOTAL} - $1 [$2]"
	_log_to_file "SKIP" "$TOTAL" "$1" "$2"
}

log_warn() {
	TOTAL=$((TOTAL + 1))
	WARN_COUNT=$((WARN_COUNT + 1))
	echo -e "  ${YELLOW}WARN${RESET}  TEST ${TOTAL} - $1 [$2]"
	_log_to_file "WARN" "$TOTAL" "$1" "$2"
}

# --------------------------------------------------------------------------
# Preflight and device helpers
# --------------------------------------------------------------------------

preflight_checks() {
	if [ "$(id -u)" -ne 0 ]; then
		echo "ERROR: This script must be run as root." >&2
		exit 1
	fi

	if ! command -v nvme &>/dev/null; then
		echo "ERROR: nvme-cli is not installed. Install with: dnf install nvme-cli" >&2
		exit 1
	fi
}

resolve_ctrl_dev() {
	local dev="$1"

	if [[ "$dev" =~ ^/dev/nvme[0-9]+$ ]]; then
		echo "$dev"
		return
	fi

	if [[ "$dev" =~ ^/dev/nvme[0-9]+n[0-9]+$ ]]; then
		echo "${dev%n*}"
		return
	fi

	echo "ERROR: '$dev' does not look like an NVMe device (/dev/nvmeX or /dev/nvmeXnY)" >&2
	exit 1
}

resolve_ns_dev() {
	local dev="$1"

	if [[ "$dev" =~ ^/dev/nvme[0-9]+n[0-9]+$ ]]; then
		echo "$dev"
		return
	fi

	if [[ "$dev" =~ ^/dev/nvme[0-9]+$ ]]; then
		local ns
		ns=$(ls -1 "${dev}n"* 2>/dev/null | grep -E "^${dev}n[0-9]+$" | head -1)
		if [ -n "$ns" ]; then
			echo "$ns"
			return
		fi
		echo "ERROR: No namespace found for controller $dev" >&2
		exit 1
	fi

	echo "ERROR: '$dev' does not look like an NVMe device" >&2
	exit 1
}

auto_detect_ctrl() {
	local first
	first=$(ls -1 /dev/nvme[0-9] 2>/dev/null | head -1)
	if [ -z "$first" ]; then
		echo "ERROR: No NVMe controllers found in /dev/." >&2
		exit 1
	fi
	echo "$first"
}

# --------------------------------------------------------------------------
# id-ctrl cache and field accessors
# --------------------------------------------------------------------------

cache_id_ctrl() {
	local ctrl_dev="$1"
	if [ -z "$_ID_CTRL_CACHE" ]; then
		_ID_CTRL_CACHE=$(nvme id-ctrl "$ctrl_dev" 2>&1)
	fi
}

get_id_ctrl_field() {
	echo "$_ID_CTRL_CACHE" | grep "^$1[[:space:]]" | awk '{ print $3 }' || true
}

get_id_ctrl_string_field() {
	echo "$_ID_CTRL_CACHE" | grep "^$1[[:space:]]" | sed "s/^$1[[:space:]]*:[[:space:]]*//" || true
}

# --------------------------------------------------------------------------
# Generic field accessors (operate on $_CMD_OUTPUT)
# --------------------------------------------------------------------------

get_field() {
	echo "$_CMD_OUTPUT" | grep "^$1[[:space:]]" | awk '{ print $3 }' || true
}

get_string_field() {
	echo "$_CMD_OUTPUT" | grep "^$1[[:space:]]" | sed "s/^$1[[:space:]]*:[[:space:]]*//" || true
}

get_field_by_label() {
	echo "$_CMD_OUTPUT" | grep "^${1}" | sed "s/^${1}[[:space:]]*:[[:space:]]*//" | awk '{ print $1 }' || true
}

# --------------------------------------------------------------------------
# Version check (operates on id-ctrl cache)
# --------------------------------------------------------------------------

ver_at_least() {
	local req_major=$1
	local req_minor=$2
	local ver_val
	ver_val=$(get_id_ctrl_field "ver")
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

get_nvme_version_str() {
	local ver_val
	ver_val=$(get_id_ctrl_field "ver")
	if [ -z "$ver_val" ] || [ "$ver_val" = "0" ] || [ "$ver_val" = "0x0" ]; then
		echo "unknown"
		return
	fi
	local ver_int=$((ver_val))
	local major=$(( (ver_int >> 16) & 0xffff ))
	local minor=$(( (ver_int >> 8) & 0xff ))
	local tertiary=$(( ver_int & 0xff ))
	echo "${major}.${minor}.${tertiary}"
}

# --------------------------------------------------------------------------
# Dynamic spec reference (matches device NVMe version to spec revision)
# --------------------------------------------------------------------------

_get_spec_rev() {
	local ver_val
	ver_val=$(get_id_ctrl_field "ver")
	if [ -z "$ver_val" ] || [ "$ver_val" = "0" ] || [ "$ver_val" = "0x0" ]; then
		echo "1.0"
		return
	fi
	local ver_int=$((ver_val))
	local major=$(( (ver_int >> 16) & 0xffff ))
	local minor=$(( (ver_int >> 8) & 0xff ))

	if [ "$major" -ge 2 ]; then
		if [ "$minor" -ge 1 ]; then echo "2.1"
		else echo "2.0"; fi
	elif [ "$major" -eq 1 ]; then
		if [ "$minor" -ge 4 ]; then echo "1.4"
		elif [ "$minor" -ge 3 ]; then echo "1.3"
		elif [ "$minor" -ge 2 ]; then echo "1.2"
		elif [ "$minor" -ge 1 ]; then echo "1.1"
		else echo "1.0"; fi
	else
		echo "2.1"
	fi
}

get_spec_ref() {
	local topic="$1"
	local spec_rev
	spec_rev=$(_get_spec_rev)

	case "$topic" in
		id-ctrl)
			case "$spec_rev" in
				2.1) echo "NVMe Base Specification, Revision 2.1, Section 5.1.13.2.1, Figure 312" ;;
				2.0) echo "NVMe Base Specification, Revision 2.0, Section 5.17.2.1, Figure 275" ;;
				1.4) echo "NVMe Base Specification, Revision 1.4, Section 5.15.2.1, Figure 247" ;;
				1.3) echo "NVMe Base Specification, Revision 1.3, Section 5.15.2.1" ;;
				1.2) echo "NVMe Base Specification, Revision 1.2, Section 5.15.2.1" ;;
				*)   echo "NVMe Base Specification, Revision ${spec_rev}, Section 5.11" ;;
			esac ;;
		smart-log)
			case "$spec_rev" in
				2.1) echo "NVMe Base Specification, Revision 2.1, Section 5.1.12, Figure 206" ;;
				2.0) echo "NVMe Base Specification, Revision 2.0, Section 5.16.1.2" ;;
				1.4) echo "NVMe Base Specification, Revision 1.4, Section 5.14.1.2" ;;
				1.3) echo "NVMe Base Specification, Revision 1.3, Section 5.14.1.2" ;;
				*)   echo "NVMe Base Specification, Revision ${spec_rev}, Section 5.12.1.2" ;;
			esac ;;
		error-log)
			case "$spec_rev" in
				2.1) echo "NVMe Base Specification, Revision 2.1, Section 5.1.12, Figure 205" ;;
				2.0) echo "NVMe Base Specification, Revision 2.0, Section 5.16.1.1" ;;
				1.4) echo "NVMe Base Specification, Revision 1.4, Section 5.14.1.1" ;;
				1.3) echo "NVMe Base Specification, Revision 1.3, Section 5.14.1.1" ;;
				*)   echo "NVMe Base Specification, Revision ${spec_rev}, Section 5.12.1.1" ;;
			esac ;;
		fw-log)
			case "$spec_rev" in
				2.1) echo "NVMe Base Specification, Revision 2.1, Section 5.1.12, Figure 208" ;;
				2.0) echo "NVMe Base Specification, Revision 2.0, Section 5.16.1.3" ;;
				1.4) echo "NVMe Base Specification, Revision 1.4, Section 5.14.1.3" ;;
				1.3) echo "NVMe Base Specification, Revision 1.3, Section 5.14.1.3" ;;
				*)   echo "NVMe Base Specification, Revision ${spec_rev}, Section 5.12.1.3" ;;
			esac ;;
		id-ns)
			case "$spec_rev" in
				2.1) echo "NVMe Base Specification, Revision 2.1, Section 5.1.13, Figure 319" ;;
				2.0) echo "NVMe Base Specification, Revision 2.0, Section 5.17.2.2" ;;
				1.4) echo "NVMe Base Specification, Revision 1.4, Section 5.15.2.2" ;;
				1.3) echo "NVMe Base Specification, Revision 1.3, Section 5.15.2.2" ;;
				*)   echo "NVMe Base Specification, Revision ${spec_rev}, Section 5.15.2.2" ;;
			esac ;;
		power-state)
			case "$spec_rev" in
				2.1) echo "NVMe Base Specification, Revision 2.1, Section 5.1.13, Figure 313" ;;
				2.0) echo "NVMe Base Specification, Revision 2.0, Section 5.17.2.1" ;;
				1.4) echo "NVMe Base Specification, Revision 1.4, Section 5.15.2.1" ;;
				*)   echo "NVMe Base Specification, Revision ${spec_rev}, Section 5.15.2.1" ;;
			esac ;;
		show-regs)
			case "$spec_rev" in
				2.1) echo "NVMe Base Specification, Revision 2.1, Section 3.1, Figure 36" ;;
				2.0) echo "NVMe Base Specification, Revision 2.0, Section 3.1.3" ;;
				1.4) echo "NVMe Base Specification, Revision 1.4, Section 3.1.5" ;;
				*)   echo "NVMe Base Specification, Revision ${spec_rev}, Section 3.1" ;;
			esac ;;
		supported-logs)
			case "$spec_rev" in
				2.1) echo "NVMe Base Specification, Revision 2.1, Section 5.1.12, Figure 204" ;;
				2.0) echo "NVMe Base Specification, Revision 2.0, Section 5.16.1" ;;
				*)   echo "NVMe Base Specification, Revision ${spec_rev}" ;;
			esac ;;
		effects-log)
			case "$spec_rev" in
				2.1) echo "NVMe Base Specification, Revision 2.1, Section 5.1.12, Figure 210" ;;
				2.0) echo "NVMe Base Specification, Revision 2.0, Section 5.16.1.4" ;;
				1.4) echo "NVMe Base Specification, Revision 1.4, Section 5.14.1.5" ;;
				1.3) echo "NVMe Base Specification, Revision 1.3, Section 5.14.1.5" ;;
				*)   echo "NVMe Base Specification, Revision ${spec_rev}" ;;
			esac ;;
		get-feature)
			case "$spec_rev" in
				2.1) echo "NVMe Base Specification, Revision 2.1, Section 5.1.7" ;;
				2.0) echo "NVMe Base Specification, Revision 2.0, Section 5.12" ;;
				1.4) echo "NVMe Base Specification, Revision 1.4, Section 5.10" ;;
				*)   echo "NVMe Base Specification, Revision ${spec_rev}, Section 5.10" ;;
			esac ;;
		ns-descs)
			case "$spec_rev" in
				2.1) echo "NVMe Base Specification, Revision 2.1, Section 5.1.13.4" ;;
				2.0) echo "NVMe Base Specification, Revision 2.0, Section 5.17.2.4" ;;
				1.4) echo "NVMe Base Specification, Revision 1.4, Section 5.15.2.4" ;;
				1.3) echo "NVMe Base Specification, Revision 1.3, Section 5.15.2.4" ;;
				*)   echo "NVMe Base Specification, Revision ${spec_rev}" ;;
			esac ;;
		self-test-log)
			case "$spec_rev" in
				2.1) echo "NVMe Base Specification, Revision 2.1, Section 5.1.12, Figure 211" ;;
				2.0) echo "NVMe Base Specification, Revision 2.0, Section 5.16.1.6" ;;
				1.4) echo "NVMe Base Specification, Revision 1.4, Section 5.14.1.6" ;;
				*)   echo "NVMe Base Specification, Revision ${spec_rev}" ;;
			esac ;;
		*)
			echo "NVMe Base Specification, Revision ${spec_rev}" ;;
	esac
}

# --------------------------------------------------------------------------
# Header and summary (terminal + log file)
# --------------------------------------------------------------------------

print_header() {
	local title="$1"
	local spec_ref="$2"
	local ctrl_dev="$3"

	local sn mn fr ver_str
	sn=$(get_id_ctrl_string_field "sn" | sed 's/ *$//')
	mn=$(get_id_ctrl_string_field "mn" | sed 's/ *$//')
	fr=$(get_id_ctrl_string_field "fr" | sed 's/ *$//')
	ver_str=$(get_nvme_version_str)

	echo ""
	echo -e "${BOLD}======================================================================${RESET}"
	echo -e "${BOLD}  ${title}${RESET}"
	echo -e "${BOLD}  Spec Reference: ${spec_ref}${RESET}"
	echo -e "${BOLD}======================================================================${RESET}"
	echo -e "  Controller:  ${ctrl_dev}"
	echo -e "  Model:       ${mn}"
	echo -e "  Serial:      ${sn}"
	echo -e "  Firmware:    ${fr}"
	echo -e "  NVMe Ver:    ${ver_str}"
	echo -e "${BOLD}----------------------------------------------------------------------${RESET}"
	echo ""

	if [ -n "$LOG_FILE" ]; then
		{
			echo ""
			echo "  Title:       ${title}"
			echo "  Spec Ref:    ${spec_ref}"
			echo "  Controller:  ${ctrl_dev}"
			echo "  Model:       ${mn}"
			echo "  Serial:      ${sn}"
			echo "  Firmware:    ${fr}"
			echo "  NVMe Ver:    ${ver_str}"
			echo ""
		} >> "$LOG_FILE"
	fi
}

print_summary() {
	echo ""
	echo -e "${BOLD}======================================================================${RESET}"
	echo -e "  ${BOLD}Results:${RESET}  ${GREEN}PASS: ${PASS_COUNT}${RESET}  ${RED}FAIL: ${FAIL_COUNT}${RESET}  ${YELLOW}SKIP: ${SKIP_COUNT}${RESET}  ${YELLOW}WARN: ${WARN_COUNT}${RESET}  Total: ${TOTAL}"
	echo -e "${BOLD}======================================================================${RESET}"

	if [ -n "$LOG_FILE" ]; then
		local _failed_lines="" _skipped_lines="" _warn_lines=""
		if [ "$FAIL_COUNT" -gt 0 ]; then
			_failed_lines=$(grep "| FAIL |" "$LOG_FILE" || true)
		fi
		if [ "$SKIP_COUNT" -gt 0 ]; then
			_skipped_lines=$(grep "| SKIP |" "$LOG_FILE" || true)
		fi
		if [ "$WARN_COUNT" -gt 0 ]; then
			_warn_lines=$(grep "| WARN |" "$LOG_FILE" || true)
		fi
		{
			echo ""
			echo "======================================================================"
			echo "  RESULTS:  PASS: ${PASS_COUNT}  FAIL: ${FAIL_COUNT}  SKIP: ${SKIP_COUNT}  WARN: ${WARN_COUNT}  Total: ${TOTAL}"
			echo "======================================================================"
			echo ""
			if [ -n "$_failed_lines" ]; then
				echo "FAILED TESTS:"
				echo "$_failed_lines"
				echo ""
			fi
			if [ -n "$_warn_lines" ]; then
				echo "WARNING TESTS:"
				echo "$_warn_lines"
				echo ""
			fi
			if [ -n "$_skipped_lines" ]; then
				echo "SKIPPED TESTS:"
				echo "$_skipped_lines"
				echo ""
			fi
		} >> "$LOG_FILE"
		echo -e "  ${BOLD}Log file:${RESET}  ${LOG_FILE}"
	fi
}

handle_args() {
	local script_name="$1"
	local description="$2"
	shift 2

	if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
		echo "Usage: ${script_name} [/dev/nvmeX | /dev/nvmeXnY]"
		echo ""
		echo "${description}"
		echo "Requires root privileges and the nvme-cli package."
		echo ""
		echo "If no device is given, the first NVMe controller found is used."
		exit 0
	fi

	local ctrl_dev
	if [ $# -eq 0 ]; then
		ctrl_dev=$(auto_detect_ctrl)
		echo -e "${BOLD}No device specified — auto-detected: ${ctrl_dev}${RESET}"
	else
		ctrl_dev=$(resolve_ctrl_dev "$1")
	fi

	echo "$ctrl_dev"
}

