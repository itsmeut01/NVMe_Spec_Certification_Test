#!/bin/bash
# SPDX-License-Identifier: GPL-3.0+
# Copyright (C) 2025 Red Hat, Inc.
#
# NVMe I/O — Functional Verification
# Based on NVMe Base Specification — NVM Command Set I/O Commands
# Tests: sequential/offset write+read, compare, write zeroes, trim, flush, MDTS boundary
#
# Usage:
#   ./nvme_io_verify.sh /dev/nvme0 --allow-destructive
#   ./nvme_io_verify.sh /dev/nvme0n1 --allow-destructive

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/nvme_test_lib.sh
source "${SCRIPT_DIR}/../common/nvme_test_lib.sh"

CTRL_DEV=""
NS_DEV=""
ALLOW_DESTRUCTIVE=""
BLOCK_SIZE=512

detect_block_size() {
	BLOCK_SIZE=$(detect_lba_block_size "$NS_DEV")
}

# --------------------------------------------------------------------------
# Test functions
# --------------------------------------------------------------------------

test_sequential_write_read() {
	if write_read_verify "$NS_DEV" 0 1 "$BLOCK_SIZE"; then
		log_pass "Sequential write+read at LBA 0 (${BLOCK_SIZE}B): data matches"
	else
		log_fail "Sequential write+read at LBA 0" "data mismatch"
	fi
}

test_offset_write_read() {
	if write_read_verify "$NS_DEV" 1024 1 "$BLOCK_SIZE"; then
		log_pass "Offset write+read at LBA 1024 (${BLOCK_SIZE}B): data matches"
	else
		log_fail "Offset write+read at LBA 1024" "data mismatch"
	fi
}

test_compare() {
	local oncs
	oncs=$(get_id_ctrl_field "oncs")
	if [ -n "$oncs" ] && [ "$(( oncs & 0x1 ))" -eq 0 ]; then
		log_skip "Compare command" "ONCS bit 0=0 (Compare not supported)"
		return
	fi

	local tmp_dir
	tmp_dir=$(mktemp -d)
	local write_file="${tmp_dir}/cmp_data"
	dd if=/dev/urandom of="$write_file" bs="$BLOCK_SIZE" count=1 2>/dev/null

	nvme write "$NS_DEV" --start-block=2 --block-count=0 \
		--data-size="$BLOCK_SIZE" --data="$write_file" 2>/dev/null || true

	local output
	output=$(nvme compare "$NS_DEV" --start-block=2 --block-count=0 \
		--data-size="$BLOCK_SIZE" --data="$write_file" 2>&1) || true
	log_cmd "Compare" "nvme compare ${NS_DEV} --start-block=2 --block-count=0 --data-size=${BLOCK_SIZE}" "$output"

	rm -rf "$tmp_dir"

	if echo "$output" | grep -qi "error\|mismatch\|fail"; then
		log_fail "Compare command" "comparison failed: $(echo "$output" | head -1)"
	else
		log_pass "Compare command: written data matches on read-back compare"
	fi
}

test_write_zeroes() {
	local oncs
	oncs=$(get_id_ctrl_field "oncs")
	if [ -n "$oncs" ] && [ "$(( (oncs >> 3) & 0x1 ))" -eq 0 ]; then
		log_skip "Write Zeroes" "ONCS bit 3=0 (Write Zeroes not supported)"
		return
	fi

	local output
	output=$(nvme write-zeroes "$NS_DEV" --start-block=4 --block-count=0 2>&1) || true
	log_cmd "Write Zeroes" "nvme write-zeroes ${NS_DEV} --start-block=4 --block-count=0" "$output"
	if echo "$output" | grep -qi "error\|invalid\|fail"; then
		log_fail "Write Zeroes" "command failed: $(echo "$output" | head -1)"
		return
	fi

	local tmp_dir
	tmp_dir=$(mktemp -d)
	local read_file="${tmp_dir}/zero_read"
	nvme read "$NS_DEV" --start-block=4 --block-count=0 \
		--data-size="$BLOCK_SIZE" --data="$read_file" 2>/dev/null || true

	local zero_file="${tmp_dir}/zero_expected"
	dd if=/dev/zero of="$zero_file" bs="$BLOCK_SIZE" count=1 2>/dev/null

	if cmp -s "$zero_file" "$read_file"; then
		log_pass "Write Zeroes: LBA 4 reads back as all zeros"
	else
		log_warn "Write Zeroes" "read-back not all zeros (may be deallocated pattern)"
	fi
	rm -rf "$tmp_dir"
}

test_dsm_trim() {
	local oncs
	oncs=$(get_id_ctrl_field "oncs")
	if [ -n "$oncs" ] && [ "$(( (oncs >> 2) & 0x1 ))" -eq 0 ]; then
		log_skip "Dataset Management (Trim)" "ONCS bit 2=0 (DSM not supported)"
		return
	fi

	local output
	output=$(nvme dsm "$NS_DEV" --ad --slbs=8 --blocks=1 2>&1) || true
	log_cmd "Dataset Management (Trim)" "nvme dsm ${NS_DEV} --ad --slbs=8 --blocks=1" "$output"
	if echo "$output" | grep -qi "error\|invalid\|fail"; then
		log_fail "Dataset Management (Trim)" "command failed: $(echo "$output" | head -1)"
	else
		log_pass "Dataset Management (Trim): deallocate LBA 8 accepted"
	fi
}

test_flush() {
	local output
	output=$(nvme flush "$NS_DEV" 2>&1) || true
	log_cmd "Flush" "nvme flush ${NS_DEV}" "$output"
	if echo "$output" | grep -qi "error\|invalid\|fail"; then
		log_fail "Flush command" "flush returned error: $(echo "$output" | head -1)"
	else
		log_pass "Flush command completed without error"
	fi
}

test_mdts_boundary() {
	local mdts
	mdts=$(get_id_ctrl_field "mdts")
	if [ -z "$mdts" ] || [ "$((mdts))" -eq 0 ]; then
		log_skip "MDTS boundary I/O" "MDTS=0 (no maximum data transfer limit)"
		return
	fi

	local mdts_int=$((mdts))
	local mpsmin
	mpsmin=$(get_id_ctrl_field "mpsmin" || true)
	local page_size=4096
	if [ -n "$mpsmin" ]; then
		page_size=$((1 << (12 + mpsmin)))
	fi
	local mdts_bytes=$((page_size * (1 << mdts_int)))

	local ns_name
	ns_name=$(basename "$NS_DEV")
	local sysfs_max_kb
	sysfs_max_kb=$(cat "/sys/block/${ns_name}/queue/max_hw_sectors_kb" 2>/dev/null || true)
	local max_bytes="$mdts_bytes"
	if [ -n "$sysfs_max_kb" ] && [ "$((sysfs_max_kb))" -gt 0 ]; then
		local sysfs_max_bytes=$((sysfs_max_kb * 1024))
		if [ "$sysfs_max_bytes" -lt "$mdts_bytes" ]; then
			max_bytes="$sysfs_max_bytes"
		fi
	fi

	local blocks=$((max_bytes / BLOCK_SIZE))

	if [ "$blocks" -le 0 ] || [ "$blocks" -gt 65536 ]; then
		log_skip "MDTS boundary I/O" "calculated block count out of range (${blocks})"
		return
	fi

	if write_read_verify "$NS_DEV" 0 "$blocks" "$BLOCK_SIZE"; then
		log_pass "MDTS boundary I/O: write+read at max transfer size (${max_bytes}B, ${blocks} blocks)"
	else
		log_fail "MDTS boundary I/O" "data mismatch at max transfer size"
	fi
}

test_exceed_mdts() {
	local mdts
	mdts=$(get_id_ctrl_field "mdts")
	if [ -z "$mdts" ] || [ "$((mdts))" -eq 0 ]; then
		log_skip "Exceed MDTS" "MDTS=0 (no limit to test)"
		return
	fi

	local mdts_int=$((mdts))
	local page_size=4096
	local max_bytes=$((page_size * (1 << mdts_int)))
	local over_blocks=$(( (max_bytes / BLOCK_SIZE) + 1 ))

	local tmp_dir
	tmp_dir=$(mktemp -d)
	local over_size=$((over_blocks * BLOCK_SIZE))

	if [ "$over_size" -gt $((64 * 1024 * 1024)) ]; then
		rm -rf "$tmp_dir"
		log_skip "Exceed MDTS" "over-sized transfer too large (${over_size}B)"
		return
	fi

	dd if=/dev/urandom of="${tmp_dir}/over_data" bs="$BLOCK_SIZE" count="$over_blocks" 2>/dev/null
	local output
	output=$(nvme write "$NS_DEV" --start-block=0 --block-count=$((over_blocks - 1)) \
		--data-size="$over_size" --data="${tmp_dir}/over_data" 2>&1) || true
	log_cmd "Write (exceed MDTS)" "nvme write ${NS_DEV} --start-block=0 --block-count=$((over_blocks - 1)) --data-size=${over_size}" "$output"
	rm -rf "$tmp_dir"

	if echo "$output" | grep -qi "error\|invalid\|exceed\|max\|status"; then
		log_pass "Exceed MDTS: transfer beyond max correctly rejected"
	else
		log_warn "Exceed MDTS" "over-sized transfer was accepted (driver may split)"
	fi
}

test_multi_ns_io() {
	local nn
	nn=$(get_id_ctrl_field "nn")
	if [ -z "$nn" ] || [ "$((nn))" -le 1 ]; then
		log_skip "Multi-namespace I/O" "only 1 namespace (NN=${nn:-1})"
		return
	fi

	local ns2="${CTRL_DEV}n2"
	if [ ! -e "$ns2" ]; then
		log_skip "Multi-namespace I/O" "namespace 2 device not present"
		return
	fi

	local ns2_csi
	ns2_csi=$(nvme ns-descs "$ns2" 2>/dev/null | grep -i "^csi" | awk -F: '{print $2}' | tr -d ' ' || true)
	if [ -n "$ns2_csi" ] && [ "$((ns2_csi))" -ne 0 ]; then
		log_skip "Multi-namespace I/O" "${ns2} uses non-NVM command set (CSI=$((ns2_csi)))"
		return
	fi

	if write_read_verify "$ns2" 0 1 0; then
		log_pass "Multi-namespace I/O: write+read on ${ns2} succeeded"
	else
		log_fail "Multi-namespace I/O" "data mismatch on ${ns2}"
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
				echo "Functional I/O verification on NVMe namespace."
				echo "DESTRUCTIVE: writes data to the device. Requires --allow-destructive."
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
	detect_block_size

	init_log "nvme_io_verify" "$CTRL_DEV"
	log_cmd "Identify Controller (cached)" "nvme id-ctrl ${CTRL_DEV}" "$_ID_CTRL_CACHE"

	local spec_ref
	spec_ref=$(get_spec_ref "io-test")

	print_header \
		"NVMe I/O — Functional Verification" \
		"$spec_ref" \
		"$CTRL_DEV"

	echo -e "  Block size: ${BLOCK_SIZE}B  Namespace: ${NS_DEV}"
	echo ""

	echo -e "${BOLD}--- Basic Read/Write ---${RESET}"
	test_sequential_write_read
	test_offset_write_read

	echo ""
	echo -e "${BOLD}--- Optional I/O Commands ---${RESET}"
	test_compare
	test_write_zeroes
	test_dsm_trim

	echo ""
	echo -e "${BOLD}--- Flush ---${RESET}"
	test_flush

	echo ""
	echo -e "${BOLD}--- Transfer Size Boundary ---${RESET}"
	test_mdts_boundary
	test_exceed_mdts

	echo ""
	echo -e "${BOLD}--- Multi-namespace ---${RESET}"
	test_multi_ns_io

	print_summary

	if [ "$FAIL_COUNT" -gt 0 ]; then
		exit 1
	fi
	exit 0
}

main "$@"
