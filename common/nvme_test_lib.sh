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
declare -A _SAVED_FEATURES

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
# Safe device checks (for destructive / mutating tests)
# --------------------------------------------------------------------------

_DESTRUCTIVE_ALLOWED=0

is_os_drive() {
	local dev="$1"
	local ctrl_dev
	if [[ "$dev" =~ ^/dev/nvme[0-9]+n[0-9]+$ ]]; then
		ctrl_dev="${dev%n*}"
	elif [[ "$dev" =~ ^/dev/nvme[0-9]+$ ]]; then
		ctrl_dev="$dev"
	else
		return 1
	fi

	local ctrl_base
	ctrl_base=$(basename "$ctrl_dev")

	local root_src
	root_src=$(findmnt -n -o SOURCE / 2>/dev/null || true)
	if [ -n "$root_src" ]; then
		local root_real
		root_real=$(readlink -f "$root_src" 2>/dev/null || echo "$root_src")
		if echo "$root_real" | grep -q "$ctrl_base"; then
			return 0
		fi
	fi

	local boot_src
	boot_src=$(findmnt -n -o SOURCE /boot 2>/dev/null || true)
	if [ -n "$boot_src" ] && echo "$boot_src" | grep -q "$ctrl_base"; then
		return 0
	fi

	local efi_src
	efi_src=$(findmnt -n -o SOURCE /boot/efi 2>/dev/null || true)
	if [ -n "$efi_src" ] && echo "$efi_src" | grep -q "$ctrl_base"; then
		return 0
	fi

	if lsblk -n -o MOUNTPOINTS "/dev/${ctrl_base}"* 2>/dev/null | grep -q "/"; then
		return 0
	fi

	return 1
}

has_mounted_partitions() {
	local dev="$1"
	local ctrl_dev
	if [[ "$dev" =~ ^/dev/nvme[0-9]+n[0-9]+$ ]]; then
		ctrl_dev="${dev%n*}"
	elif [[ "$dev" =~ ^/dev/nvme[0-9]+$ ]]; then
		ctrl_dev="$dev"
	else
		return 1
	fi

	local mounts
	mounts=$(lsblk -n -o MOUNTPOINTS "${ctrl_dev}"* 2>/dev/null | grep -v "^$" || true)
	if [ -n "$mounts" ]; then
		return 0
	fi
	return 1
}

safe_device_check() {
	local dev="$1"
	local allow_flag="${2:-}"

	if [ "$allow_flag" = "--allow-destructive" ]; then
		_DESTRUCTIVE_ALLOWED=1
	fi

	if is_os_drive "$dev"; then
		echo -e "${RED}ERROR: ${dev} is the OS drive — destructive tests REFUSED.${RESET}" >&2
		echo -e "  Root filesystem or /boot is on this controller." >&2
		echo -e "  Use a different NVMe device that does not host the OS." >&2
		exit 1
	fi

	if has_mounted_partitions "$dev"; then
		echo -e "${YELLOW}WARNING: ${dev} has mounted partitions:${RESET}" >&2
		local ctrl_dev
		if [[ "$dev" =~ ^/dev/nvme[0-9]+n[0-9]+$ ]]; then
			ctrl_dev="${dev%n*}"
		else
			ctrl_dev="$dev"
		fi
		lsblk -o NAME,SIZE,MOUNTPOINTS "${ctrl_dev}"* 2>/dev/null | head -20 >&2
		echo "" >&2
		if [ "$_DESTRUCTIVE_ALLOWED" -ne 1 ]; then
			echo -e "${RED}REFUSED: Pass --allow-destructive to run on a device with mounted partitions.${RESET}" >&2
			exit 1
		fi
		echo -e "${YELLOW}Proceeding anyway (--allow-destructive was passed).${RESET}" >&2
	fi

	if [ "$_DESTRUCTIVE_ALLOWED" -ne 1 ]; then
		echo -e "${RED}ERROR: Destructive tests require --allow-destructive flag.${RESET}" >&2
		echo -e "  This test suite will write to / modify ${dev}." >&2
		echo -e "  Usage: $0 ${dev} --allow-destructive" >&2
		exit 1
	fi

	echo -e "${GREEN}Safe device check passed:${RESET} ${dev} is not the OS drive."
}

auto_detect_safe_ctrl() {
	local all_ctrls
	all_ctrls=$(ls -1 /dev/nvme[0-9] 2>/dev/null)
	if [ -z "$all_ctrls" ]; then
		echo "ERROR: No NVMe controllers found in /dev/." >&2
		exit 1
	fi

	local safe_dev=""
	while IFS= read -r ctrl; do
		if ! is_os_drive "$ctrl"; then
			safe_dev="$ctrl"
			break
		fi
	done <<< "$all_ctrls"

	if [ -z "$safe_dev" ]; then
		echo "ERROR: All NVMe controllers host the OS — no safe device for destructive tests." >&2
		echo "  Controllers found:" >&2
		while IFS= read -r ctrl; do
			echo "    ${ctrl} (OS drive)" >&2
		done <<< "$all_ctrls"
		exit 1
	fi

	echo "$safe_dev"
}

list_nvme_devices() {
	echo -e "${BOLD}NVMe devices:${RESET}"
	local all_ctrls
	all_ctrls=$(ls -1 /dev/nvme[0-9] 2>/dev/null || true)
	if [ -z "$all_ctrls" ]; then
		echo "  No NVMe controllers found."
		return
	fi
	while IFS= read -r ctrl; do
		local model serial
		model=$(nvme id-ctrl "$ctrl" 2>/dev/null | grep "^mn " | sed 's/^mn.*: //' || echo "unknown")
		serial=$(nvme id-ctrl "$ctrl" 2>/dev/null | grep "^sn " | sed 's/^sn.*: //' || echo "unknown")
		if is_os_drive "$ctrl"; then
			echo -e "  ${RED}[OS]${RESET}  ${ctrl}  ${model}  (${serial})"
		elif has_mounted_partitions "$ctrl"; then
			echo -e "  ${YELLOW}[MNT]${RESET} ${ctrl}  ${model}  (${serial})"
		else
			echo -e "  ${GREEN}[OK]${RESET}  ${ctrl}  ${model}  (${serial})"
		fi
	done <<< "$all_ctrls"
}

# --------------------------------------------------------------------------
# Feature save / restore / set helpers (for set-feature tests)
# --------------------------------------------------------------------------

extract_feature_result() {
	local output="$1"
	local hex
	hex=$(echo "$output" | grep -oiP '(?:result|value)[[:space:]:]*0x[0-9a-fA-F]+' | head -1 | grep -oiP '0x[0-9a-fA-F]+' || true)
	if [ -n "$hex" ]; then echo "$hex"; return; fi
	hex=$(echo "$output" | grep -oiP '(?:result|value)[[:space:]:]*[0-9a-fA-F]+' | head -1 | grep -oiP '[0-9a-fA-F]+$' || true)
	if [ -n "$hex" ]; then echo "0x${hex}"; return; fi
}

save_feature() {
	local fid="$1"
	local ctrl_dev="$2"
	local output
	output=$(nvme get-feature "$ctrl_dev" -f "$fid" 2>&1) || true
	local result
	result=$(extract_feature_result "$output")
	if [ -n "$result" ]; then
		_SAVED_FEATURES["$fid"]="$result"
		echo "$result"
	else
		echo ""
	fi
}

restore_feature() {
	local fid="$1"
	local ctrl_dev="$2"
	local saved="${_SAVED_FEATURES[$fid]:-}"
	if [ -z "$saved" ]; then
		return 0
	fi
	local val=$((saved))
	nvme set-feature "$ctrl_dev" -f "$fid" -v "$val" 2>&1 || true
	unset '_SAVED_FEATURES[$fid]'
}

set_feature() {
	local fid="$1"
	local value="$2"
	local ctrl_dev="$3"
	local output
	output=$(nvme set-feature "$ctrl_dev" -f "$fid" -v "$value" 2>&1) || true
	echo "$output"
}

verify_feature() {
	local fid="$1"
	local expected="$2"
	local ctrl_dev="$3"
	local output
	output=$(nvme get-feature "$ctrl_dev" -f "$fid" 2>&1) || true
	local result
	result=$(extract_feature_result "$output")
	if [ -z "$result" ]; then
		return 1
	fi
	local got=$((result))
	local want=$((expected))
	[ "$got" -eq "$want" ]
}

# --------------------------------------------------------------------------
# Write / read / verify pattern (for behavioral validation)
# --------------------------------------------------------------------------

write_read_verify() {
	local ns_dev="$1"
	local start_lba="${2:-0}"
	local block_count="${3:-1}"
	local block_size="${4:-512}"

	local total_bytes=$((block_count * block_size))
	local tmp_dir
	tmp_dir=$(mktemp -d)
	local write_file="${tmp_dir}/write_data"
	local read_file="${tmp_dir}/read_data"
	local rc=0

	dd if=/dev/urandom of="$write_file" bs="$block_size" count="$block_count" 2>/dev/null

	if ! nvme write "$ns_dev" --start-block="$start_lba" \
		--block-count=$((block_count - 1)) --data-size="$total_bytes" \
		--data="$write_file" 2>/dev/null; then
		rc=1
	fi

	if [ "$rc" -eq 0 ]; then
		if ! nvme read "$ns_dev" --start-block="$start_lba" \
			--block-count=$((block_count - 1)) --data-size="$total_bytes" \
			--data="$read_file" 2>/dev/null; then
			rc=1
		fi
	fi

	if [ "$rc" -eq 0 ]; then
		if ! cmp -s "$write_file" "$read_file"; then
			rc=1
		fi
	fi

	rm -rf "$tmp_dir"
	return $rc
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
		feature-set)
			case "$spec_rev" in
				2.1) echo "NVMe Base Specification, Revision 2.1, Section 5.1.25 (Set Features)" ;;
				2.0) echo "NVMe Base Specification, Revision 2.0, Section 5.27 (Set Features)" ;;
				1.4) echo "NVMe Base Specification, Revision 1.4, Section 5.21 (Set Features)" ;;
				1.3) echo "NVMe Base Specification, Revision 1.3, Section 5.21" ;;
				*)   echo "NVMe Base Specification, Revision ${spec_rev}" ;;
			esac ;;
		io-test)
			case "$spec_rev" in
				2.1) echo "NVMe Base Specification, Revision 2.1, Section 7 (I/O Commands)" ;;
				2.0) echo "NVMe Base Specification, Revision 2.0, Section 7 (I/O Commands)" ;;
				1.4) echo "NVMe Base Specification, Revision 1.4, Section 6 (NVM Command Set)" ;;
				1.3) echo "NVMe Base Specification, Revision 1.3, Section 6 (NVM Command Set)" ;;
				*)   echo "NVMe Base Specification, Revision ${spec_rev}, Section 6" ;;
			esac ;;
		dst-functional)
			case "$spec_rev" in
				2.1) echo "NVMe Base Specification, Revision 2.1, Section 5.1.5 (Device Self-test)" ;;
				2.0) echo "NVMe Base Specification, Revision 2.0, Section 5.9 (Device Self-test)" ;;
				1.4) echo "NVMe Base Specification, Revision 1.4, Section 5.8 (Device Self-test)" ;;
				*)   echo "NVMe Base Specification, Revision ${spec_rev}" ;;
			esac ;;
		format)
			case "$spec_rev" in
				2.1) echo "NVMe Base Specification, Revision 2.1, Section 5.1.10 (Format NVM)" ;;
				2.0) echo "NVMe Base Specification, Revision 2.0, Section 5.14 (Format NVM)" ;;
				1.4) echo "NVMe Base Specification, Revision 1.4, Section 5.23 (Format NVM)" ;;
				*)   echo "NVMe Base Specification, Revision ${spec_rev}" ;;
			esac ;;
		sanitize)
			case "$spec_rev" in
				2.1) echo "NVMe Base Specification, Revision 2.1, Section 5.1.22 (Sanitize)" ;;
				2.0) echo "NVMe Base Specification, Revision 2.0, Section 5.24 (Sanitize)" ;;
				1.4) echo "NVMe Base Specification, Revision 1.4, Section 5.24 (Sanitize)" ;;
				*)   echo "NVMe Base Specification, Revision ${spec_rev}" ;;
			esac ;;
		ns-mgmt)
			case "$spec_rev" in
				2.1) echo "NVMe Base Specification, Revision 2.1, Section 5.1.21 (Namespace Management)" ;;
				2.0) echo "NVMe Base Specification, Revision 2.0, Section 5.23 (Namespace Management)" ;;
				1.4) echo "NVMe Base Specification, Revision 1.4, Section 5.20 (Namespace Management)" ;;
				*)   echo "NVMe Base Specification, Revision ${spec_rev}" ;;
			esac ;;
		reservation)
			case "$spec_rev" in
				2.1) echo "NVMe Base Specification, Revision 2.1, Section 7.5-7.8 (Reservations)" ;;
				2.0) echo "NVMe Base Specification, Revision 2.0, Section 7.2-7.5 (Reservations)" ;;
				1.4) echo "NVMe Base Specification, Revision 1.4, Section 6.10-6.13 (Reservations)" ;;
				*)   echo "NVMe Base Specification, Revision ${spec_rev}" ;;
			esac ;;
		reset)
			case "$spec_rev" in
				2.1) echo "NVMe Base Specification, Revision 2.1, Section 3.7 (Resets)" ;;
				2.0) echo "NVMe Base Specification, Revision 2.0, Section 3.7 (Resets)" ;;
				1.4) echo "NVMe Base Specification, Revision 1.4, Section 7.3 (Resets)" ;;
				*)   echo "NVMe Base Specification, Revision ${spec_rev}" ;;
			esac ;;
		async-event)
			case "$spec_rev" in
				2.1) echo "NVMe Base Specification, Revision 2.1, Section 5.1.2 (Async Event Request)" ;;
				2.0) echo "NVMe Base Specification, Revision 2.0, Section 5.2 (Async Event Request)" ;;
				1.4) echo "NVMe Base Specification, Revision 1.4, Section 5.2 (Async Event Request)" ;;
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

