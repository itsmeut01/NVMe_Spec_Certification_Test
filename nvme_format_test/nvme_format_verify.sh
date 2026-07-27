#!/bin/bash
# SPDX-License-Identifier: GPL-3.0+
# Copyright (C) 2025 Red Hat, Inc.
#
# NVMe Format NVM — Functional Verification
# Based on NVMe Base Specification — Format NVM command
# Tests: format with current LBAF, user data erase, alternate LBAF, I/O after format
#
# Usage:
#   ./nvme_format_verify.sh /dev/nvme0 --allow-destructive
#   ./nvme_format_verify.sh /dev/nvme0n1 --allow-destructive

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/nvme_test_lib.sh
source "${SCRIPT_DIR}/../common/nvme_test_lib.sh"

CTRL_DEV=""
NS_DEV=""
ALLOW_DESTRUCTIVE=""
ORIGINAL_LBAF=0
BLOCK_SIZE=512

detect_lbaf_info() {
	local ns_output
	ns_output=$(nvme id-ns "$NS_DEV" 2>&1) || true
	local flbas
	flbas=$(echo "$ns_output" | grep "^flbas" | awk '{print $3}' || true)
	if [ -n "$flbas" ]; then
		ORIGINAL_LBAF=$(( flbas & 0xF ))
	fi
	local lbads
	lbads=$(echo "$ns_output" | grep "lbads.*:.*[0-9]" | sed -n "$((ORIGINAL_LBAF + 1))p" | grep -oP 'lbads\s*:\s*\K[0-9]+' || true)
	if [ -n "$lbads" ] && [ "$((lbads))" -gt 0 ]; then
		BLOCK_SIZE=$((1 << lbads))
	fi
}

# --------------------------------------------------------------------------
# Test functions
# --------------------------------------------------------------------------

test_format_current_lbaf() {
	local output
	output=$(nvme format "$NS_DEV" -l "$ORIGINAL_LBAF" 2>&1) || true
	if echo "$output" | grep -qi "error\|invalid\|fail"; then
		log_fail "Format with current LBAF ${ORIGINAL_LBAF}" "error: $(echo "$output" | head -1)"
		return
	fi

	sleep 2

	local ns_check
	ns_check=$(nvme id-ns "$NS_DEV" 2>&1) || true
	if echo "$ns_check" | grep -q "^flbas"; then
		log_pass "Format with current LBAF ${ORIGINAL_LBAF}: namespace accessible after format"
	else
		log_fail "Format with current LBAF ${ORIGINAL_LBAF}" "namespace not accessible after format"
	fi
}

test_format_user_data_erase() {
	local output
	output=$(nvme format "$NS_DEV" --ses=1 -l "$ORIGINAL_LBAF" 2>&1) || true
	if echo "$output" | grep -qi "error\|invalid\|fail"; then
		log_warn "Format with user data erase (SES=1)" "error: $(echo "$output" | head -1)"
		return
	fi

	sleep 2

	local tmp_dir
	tmp_dir=$(mktemp -d)
	local read_file="${tmp_dir}/erase_read"
	nvme read "$NS_DEV" --start-block=0 --block-count=0 \
		--data-size="$BLOCK_SIZE" --data="$read_file" 2>/dev/null || true

	local zero_file="${tmp_dir}/zero_expected"
	dd if=/dev/zero of="$zero_file" bs="$BLOCK_SIZE" count=1 2>/dev/null

	if cmp -s "$zero_file" "$read_file"; then
		log_pass "User data erase: LBA 0 reads back as all zeros after SES=1 format"
	else
		log_warn "User data erase" "LBA 0 not all zeros (controller may use different erase pattern)"
	fi
	rm -rf "$tmp_dir"
}

test_format_alternate_lbaf() {
	local ns_output
	ns_output=$(nvme id-ns "$NS_DEV" 2>&1) || true
	local nlbaf
	nlbaf=$(echo "$ns_output" | grep "^nlbaf" | awk '{print $3}' || true)

	if [ -z "$nlbaf" ] || [ "$((nlbaf))" -le 0 ]; then
		log_skip "Format with alternate LBAF" "only 1 LBA format supported (NLBAF=${nlbaf:-0})"
		return
	fi

	local alt_lbaf=1
	if [ "$ORIGINAL_LBAF" -eq 1 ]; then
		alt_lbaf=0
	fi

	local output
	output=$(nvme format "$NS_DEV" -l "$alt_lbaf" 2>&1) || true
	if echo "$output" | grep -qi "error\|invalid\|fail"; then
		log_warn "Format with alternate LBAF ${alt_lbaf}" "$(echo "$output" | head -1)"
		return
	fi

	sleep 2

	ns_output=$(nvme id-ns "$NS_DEV" 2>&1) || true
	local flbas
	flbas=$(echo "$ns_output" | grep "^flbas" | awk '{print $3}' || true)
	local cur_lbaf=0
	if [ -n "$flbas" ]; then
		cur_lbaf=$(( flbas & 0xF ))
	fi

	if [ "$cur_lbaf" -eq "$alt_lbaf" ]; then
		log_pass "Format with alternate LBAF ${alt_lbaf}: id-ns confirms new format"
	else
		log_warn "Format with alternate LBAF" "flbas shows LBAF=${cur_lbaf} (expected ${alt_lbaf})"
	fi

	output=$(nvme format "$NS_DEV" -l "$ORIGINAL_LBAF" 2>&1) || true
	sleep 2
}

test_io_after_format() {
	if write_read_verify "$NS_DEV" 0 1 "$BLOCK_SIZE"; then
		log_pass "I/O after format: write+read at LBA 0 succeeded"
	else
		log_fail "I/O after format" "write+read data mismatch"
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
				echo "Functional verification of NVMe Format NVM command."
				echo "DESTRUCTIVE: erases all data on the namespace. Requires --allow-destructive."
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

	if [ -z "$NS_DEV" ]; then
		echo "ERROR: No namespace device found for ${CTRL_DEV}." >&2
		exit 1
	fi

	safe_device_check "$CTRL_DEV" "$ALLOW_DESTRUCTIVE"

	cache_id_ctrl "$CTRL_DEV"

	local oacs
	oacs=$(get_id_ctrl_field "oacs")
	if [ -n "$oacs" ] && [ "$(( (oacs >> 1) & 0x1 ))" -eq 0 ]; then
		echo -e "${YELLOW}SKIP${RESET}  Format NVM not supported (OACS bit 1=0)"
		exit 0
	fi

	detect_lbaf_info

	init_log "nvme_format_verify" "$CTRL_DEV"
	log_cmd "Identify Controller (cached)" "nvme id-ctrl ${CTRL_DEV}" "$_ID_CTRL_CACHE"

	local spec_ref
	spec_ref=$(get_spec_ref "format")

	print_header \
		"NVMe Format NVM — Functional Verification" \
		"$spec_ref" \
		"$CTRL_DEV"

	echo -e "  Namespace: ${NS_DEV}  Current LBAF: ${ORIGINAL_LBAF}  Block size: ${BLOCK_SIZE}B"
	echo ""

	echo -e "${BOLD}--- Format Operations ---${RESET}"
	test_format_current_lbaf
	test_format_user_data_erase
	test_format_alternate_lbaf

	echo ""
	echo -e "${BOLD}--- Post-Format I/O ---${RESET}"
	test_io_after_format

	print_summary

	if [ "$FAIL_COUNT" -gt 0 ]; then
		exit 1
	fi
	exit 0
}

main "$@"
