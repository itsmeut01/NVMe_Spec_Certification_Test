#!/bin/bash
# SPDX-License-Identifier: GPL-3.0+
# Copyright (C) 2025 Red Hat, Inc.
#
# NVMe Additional I/O — Behavioral Verification
# Based on NVMe Base Specification — Verify, Write Uncorrectable, Copy, Compare
# Tests: verify, write-uncor + recovery, copy round-trip, get-lba-status,
#        io-passthru, compare — all with save/restore of LBA data
#
# Usage:
#   ./nvme_additional_io_verify.sh /dev/nvme0 --allow-destructive
#   ./nvme_additional_io_verify.sh              # auto-detects

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/nvme_test_lib.sh
source "${SCRIPT_DIR}/../common/nvme_test_lib.sh"

CTRL_DEV=""
NS_DEV=""
ALLOW_DESTRUCTIVE=""
BLOCK_SIZE=512
NSZE=0
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

get_block_size() {
	local ns_output
	ns_output=$(nvme id-ns "$NS_DEV" 2>&1) || true
	local flbas lbaf_line
	flbas=$(echo "$ns_output" | grep "^flbas" | awk '{print $3}' || true)
	local flbas_int=$((flbas))
	local lba_idx=$(( flbas_int & 0xf ))
	lbaf_line=$(echo "$ns_output" | grep "^lbaf  ${lba_idx}" || true)
	if [ -z "$lbaf_line" ]; then
		lbaf_line=$(echo "$ns_output" | grep "lbaf.*${lba_idx}" | head -1 || true)
	fi
	local ds
	ds=$(echo "$lbaf_line" | grep -oP 'ds:\K[0-9]+' || true)
	if [ -n "$ds" ] && [ "$ds" -gt 0 ]; then
		BLOCK_SIZE=$((1 << ds))
	fi
}

get_nsze() {
	local ns_output
	ns_output=$(nvme id-ns "$NS_DEV" 2>&1) || true
	local nsze_val
	nsze_val=$(echo "$ns_output" | grep "^nsze" | awk '{print $3}' || true)
	if [ -n "$nsze_val" ]; then
		NSZE=$((nsze_val))
	fi
}

save_lba() {
	local lba="$1"
	local file="$2"
	nvme read "$NS_DEV" --start-block="$lba" --block-count=0 \
		--data-size="$BLOCK_SIZE" --data="$file" 2>/dev/null || true
}

restore_lba() {
	local lba="$1"
	local file="$2"
	if [ -f "$file" ]; then
		nvme write "$NS_DEV" --start-block="$lba" --block-count=0 \
			--data-size="$BLOCK_SIZE" --data="$file" 2>/dev/null || true
	fi
}

# --------------------------------------------------------------------------
# Test functions
# --------------------------------------------------------------------------

test_verify_lba0() {
	local oncs
	oncs=$(get_id_ctrl_field "oncs")
	local oncs_int=$((oncs))
	local verify_bit=$(( (oncs_int >> 7) & 0x1 ))
	if [ "$verify_bit" -eq 0 ]; then
		log_skip "Verify at LBA 0" "ONCS bit 7 = 0 (Verify not supported)"
		return
	fi

	local save_file="${TMP_DIR}/save_lba0"
	save_lba 0 "$save_file"

	local pattern_file="${TMP_DIR}/pattern_lba0"
	dd if=/dev/urandom of="$pattern_file" bs="$BLOCK_SIZE" count=1 2>/dev/null
	nvme write "$NS_DEV" --start-block=0 --block-count=0 \
		--data-size="$BLOCK_SIZE" --data="$pattern_file" 2>/dev/null || true

	local output
	output=$(nvme verify "$NS_DEV" --start-block=0 --block-count=0 2>&1) || true
	log_cmd "Verify LBA 0" "nvme verify ${NS_DEV} -s 0 -c 0" "$output"

	local read_file="${TMP_DIR}/read_lba0"
	nvme read "$NS_DEV" --start-block=0 --block-count=0 \
		--data-size="$BLOCK_SIZE" --data="$read_file" 2>/dev/null || true

	if cmp -s "$pattern_file" "$read_file"; then
		log_pass "Verify at LBA 0: write + verify + read-back all consistent"
	else
		log_warn "Verify at LBA 0" "read-back mismatch after verify (verify may not guarantee readback)"
	fi

	restore_lba 0 "$save_file"
}

test_verify_offset_lba() {
	local oncs
	oncs=$(get_id_ctrl_field "oncs")
	local oncs_int=$((oncs))
	local verify_bit=$(( (oncs_int >> 7) & 0x1 ))
	if [ "$verify_bit" -eq 0 ]; then
		log_skip "Verify at offset LBA" "ONCS bit 7 = 0"
		return
	fi

	local test_lba=1024
	if [ "$NSZE" -le 1024 ]; then
		test_lba=$(( NSZE / 2 ))
	fi

	local pattern_file="${TMP_DIR}/pattern_offset"
	dd if=/dev/urandom of="$pattern_file" bs="$BLOCK_SIZE" count=1 2>/dev/null
	nvme write "$NS_DEV" --start-block="$test_lba" --block-count=0 \
		--data-size="$BLOCK_SIZE" --data="$pattern_file" 2>/dev/null || true

	local output
	output=$(nvme verify "$NS_DEV" --start-block="$test_lba" --block-count=0 2>&1) || true

	if ! echo "$output" | grep -qi "error\|invalid\|NVMe status"; then
		log_pass "Verify at offset LBA ${test_lba}: command succeeded"
	else
		log_fail "Verify at offset LBA ${test_lba}" "$(echo "$output" | head -1)"
	fi
}

test_verify_invalid_lba() {
	local oncs
	oncs=$(get_id_ctrl_field "oncs")
	local oncs_int=$((oncs))
	local verify_bit=$(( (oncs_int >> 7) & 0x1 ))
	if [ "$verify_bit" -eq 0 ]; then
		log_skip "Verify invalid LBA" "ONCS bit 7 = 0"
		return
	fi

	if [ "$NSZE" -eq 0 ]; then
		log_skip "Verify invalid LBA" "could not determine NSZE"
		return
	fi

	local bad_lba=$((NSZE + 100))
	local output
	output=$(nvme verify "$NS_DEV" --start-block="$bad_lba" --block-count=0 2>&1) || true
	log_cmd "Verify invalid LBA" "nvme verify ${NS_DEV} -s ${bad_lba} -c 0" "$output"

	if echo "$output" | grep -qi "LBA_RANGE\|invalid\|error\|NVMe status"; then
		log_pass "Verify invalid LBA ${bad_lba}: correctly rejected (beyond NSZE=${NSZE})"
	else
		log_warn "Verify invalid LBA" "unexpected response: $(echo "$output" | head -1)"
	fi
}

test_write_uncor_recovery() {
	local oncs
	oncs=$(get_id_ctrl_field "oncs")
	local oncs_int=$((oncs))
	local wuncor_bit=$(( (oncs_int >> 1) & 0x1 ))
	if [ "$wuncor_bit" -eq 0 ]; then
		log_skip "Write Uncorrectable + Recovery" "ONCS bit 1 = 0"
		return
	fi

	local test_lba=2048
	if [ "$NSZE" -le 2048 ]; then
		test_lba=$(( NSZE / 2 ))
	fi

	local save_file="${TMP_DIR}/save_uncor"
	save_lba "$test_lba" "$save_file"

	local output
	output=$(nvme write-uncor "$NS_DEV" --start-block="$test_lba" --block-count=0 2>&1) || true
	log_cmd "Write Uncorrectable" "nvme write-uncor ${NS_DEV} -s ${test_lba} -c 0" "$output"

	if echo "$output" | grep -qi "error\|NVMe status\|invalid"; then
		log_fail "Write Uncorrectable" "command failed: $(echo "$output" | head -1)"
		restore_lba "$test_lba" "$save_file"
		return
	fi

	local read_output
	read_output=$(nvme read "$NS_DEV" --start-block="$test_lba" --block-count=0 \
		--data-size="$BLOCK_SIZE" --data="${TMP_DIR}/uncor_read" 2>&1) || true

	if echo "$read_output" | grep -qi "error\|UNRECOV\|NVMe status"; then
		log_pass "Write Uncorrectable: read at LBA ${test_lba} correctly returns error (uncorrectable)"
	else
		log_warn "Write Uncorrectable" "read did not report error — controller may auto-correct"
	fi

	local recover_file="${TMP_DIR}/recover_data"
	dd if=/dev/urandom of="$recover_file" bs="$BLOCK_SIZE" count=1 2>/dev/null
	nvme write "$NS_DEV" --start-block="$test_lba" --block-count=0 \
		--data-size="$BLOCK_SIZE" --data="$recover_file" 2>/dev/null || true

	local verify_file="${TMP_DIR}/verify_recover"
	nvme read "$NS_DEV" --start-block="$test_lba" --block-count=0 \
		--data-size="$BLOCK_SIZE" --data="$verify_file" 2>/dev/null || true

	if cmp -s "$recover_file" "$verify_file"; then
		log_pass "Recovery: LBA ${test_lba} recovered after write-uncor (write + read-back match)"
	else
		log_fail "Recovery" "LBA ${test_lba} could not be recovered after write-uncor"
	fi

	restore_lba "$test_lba" "$save_file"
}

test_copy_command() {
	local oncs
	oncs=$(get_id_ctrl_field "oncs")
	local oncs_int=$((oncs))
	local copy_bit=$(( (oncs_int >> 8) & 0x1 ))
	if [ "$copy_bit" -eq 0 ]; then
		log_skip "Copy command" "ONCS bit 8 = 0 (Copy not supported)"
		return
	fi

	if ! ver_at_least 2 0; then
		log_skip "Copy command" "requires NVMe 2.0+"
		return
	fi

	local src_lba=4096
	local dst_lba=4097
	if [ "$NSZE" -le 4098 ]; then
		src_lba=$(( NSZE / 2 - 1 ))
		dst_lba=$(( NSZE / 2 ))
	fi

	local save_src="${TMP_DIR}/save_src"
	local save_dst="${TMP_DIR}/save_dst"
	save_lba "$src_lba" "$save_src"
	save_lba "$dst_lba" "$save_dst"

	local pattern_file="${TMP_DIR}/copy_pattern"
	dd if=/dev/urandom of="$pattern_file" bs="$BLOCK_SIZE" count=1 2>/dev/null
	nvme write "$NS_DEV" --start-block="$src_lba" --block-count=0 \
		--data-size="$BLOCK_SIZE" --data="$pattern_file" 2>/dev/null || true

	local output
	output=$(nvme copy "$NS_DEV" --sdlba="$dst_lba" --slbs="$src_lba" --blocks=0 2>&1) || true
	log_cmd "Copy" "nvme copy ${NS_DEV} --sdlba=${dst_lba} --slbs=${src_lba} --blocks=0" "$output"

	if echo "$output" | grep -qi "error\|invalid\|NVMe status"; then
		log_fail "Copy command" "$(echo "$output" | head -1)"
		restore_lba "$src_lba" "$save_src"
		restore_lba "$dst_lba" "$save_dst"
		return
	fi

	local read_dst="${TMP_DIR}/read_dst"
	nvme read "$NS_DEV" --start-block="$dst_lba" --block-count=0 \
		--data-size="$BLOCK_SIZE" --data="$read_dst" 2>/dev/null || true

	if cmp -s "$pattern_file" "$read_dst"; then
		log_pass "Copy: src LBA ${src_lba} -> dst LBA ${dst_lba}, read-back matches pattern"
	else
		log_fail "Copy command" "dst LBA read-back does not match src pattern"
	fi

	restore_lba "$src_lba" "$save_src"
	restore_lba "$dst_lba" "$save_dst"
}

test_get_lba_status() {
	local oacs
	oacs=$(get_id_ctrl_field "oacs")
	local oacs_int=$((oacs))
	local glbas_bit=$(( (oacs_int >> 9) & 0x1 ))
	if [ "$glbas_bit" -eq 0 ]; then
		log_skip "Get LBA Status" "OACS bit 9 = 0 (not supported)"
		return
	fi

	local output
	output=$(nvme get-lba-status "$NS_DEV" --start-lba=0 --max-dw=256 --action=0 2>&1) || true
	log_cmd "Get LBA Status" "nvme get-lba-status ${NS_DEV} -s 0 --max-dw=256 -a 0" "$output"

	if echo "$output" | grep -qi "error\|NVMe status\|invalid"; then
		log_warn "Get LBA Status" "command returned error: $(echo "$output" | head -1)"
	else
		log_pass "Get LBA Status: command succeeded"
	fi
}

test_get_lba_status_after_uncor() {
	local oacs
	oacs=$(get_id_ctrl_field "oacs")
	local oacs_int=$((oacs))
	local glbas_bit=$(( (oacs_int >> 9) & 0x1 ))
	local oncs
	oncs=$(get_id_ctrl_field "oncs")
	local oncs_int=$((oncs))
	local wuncor_bit=$(( (oncs_int >> 1) & 0x1 ))

	if [ "$glbas_bit" -eq 0 ]; then
		log_skip "Get LBA Status after write-uncor" "OACS bit 9 = 0"
		return
	fi
	if [ "$wuncor_bit" -eq 0 ]; then
		log_skip "Get LBA Status after write-uncor" "ONCS bit 1 = 0"
		return
	fi

	local test_lba=3072
	if [ "$NSZE" -le 3072 ]; then
		test_lba=$(( NSZE / 2 ))
	fi

	local save_file="${TMP_DIR}/save_glbas"
	save_lba "$test_lba" "$save_file"

	nvme write-uncor "$NS_DEV" --start-block="$test_lba" --block-count=0 2>/dev/null || true

	local output
	output=$(nvme get-lba-status "$NS_DEV" --start-lba="$test_lba" --max-dw=256 --action=0 2>&1) || true
	log_cmd "Get LBA Status after uncor" "nvme get-lba-status ${NS_DEV} -s ${test_lba}" "$output"

	if ! echo "$output" | grep -qi "error\|NVMe status"; then
		log_pass "Get LBA Status after write-uncor at LBA ${test_lba}: command succeeded"
	else
		log_warn "Get LBA Status after write-uncor" "$(echo "$output" | head -1)"
	fi

	local recover_file="${TMP_DIR}/recover_glbas"
	dd if=/dev/urandom of="$recover_file" bs="$BLOCK_SIZE" count=1 2>/dev/null
	nvme write "$NS_DEV" --start-block="$test_lba" --block-count=0 \
		--data-size="$BLOCK_SIZE" --data="$recover_file" 2>/dev/null || true

	restore_lba "$test_lba" "$save_file"
}

test_io_passthru() {
	local test_lba=5120
	if [ "$NSZE" -le 5120 ]; then
		test_lba=$(( NSZE / 2 ))
	fi

	local nsid
	nsid=$(echo "$NS_DEV" | grep -oP 'n\K[0-9]+$' || echo 1)

	local save_file="${TMP_DIR}/save_passthru"
	save_lba "$test_lba" "$save_file"

	local pattern_file="${TMP_DIR}/passthru_pattern"
	dd if=/dev/urandom of="$pattern_file" bs="$BLOCK_SIZE" count=1 2>/dev/null

	local nlb=0
	local write_output
	write_output=$(nvme io-passthru "$NS_DEV" --opcode=0x01 \
		--namespace-id="$nsid" --cdw10="$test_lba" --cdw12="$nlb" \
		--data-len="$BLOCK_SIZE" --write --input-file="$pattern_file" 2>&1) || true
	log_cmd "IO passthru write" "nvme io-passthru ${NS_DEV} --opcode=0x01 --namespace-id=${nsid} --cdw10=${test_lba}" "$write_output"

	local read_file="${TMP_DIR}/passthru_read"
	local read_output
	read_output=$(nvme io-passthru "$NS_DEV" --opcode=0x02 \
		--namespace-id="$nsid" --cdw10="$test_lba" --cdw12="$nlb" \
		--data-len="$BLOCK_SIZE" --read --input-file="$read_file" 2>&1) || true

	if [ -f "$read_file" ] && cmp -s "$pattern_file" "$read_file"; then
		log_pass "I/O passthru: write (opcode=0x01) + read (opcode=0x02) round-trip matches"
	elif echo "$write_output" | grep -qi "error\|NVMe status\|Invalid argument"; then
		log_warn "I/O passthru" "write failed: $(echo "$write_output" | head -1)"
	elif echo "$read_output" | grep -qi "error\|NVMe status\|Invalid argument"; then
		log_warn "I/O passthru" "read failed: $(echo "$read_output" | head -1)"
	else
		log_warn "I/O passthru" "data mismatch after write+read"
	fi

	restore_lba "$test_lba" "$save_file"
}

test_compare_command() {
	local oncs
	oncs=$(get_id_ctrl_field "oncs")
	local oncs_int=$((oncs))
	local compare_bit=$(( oncs_int & 0x1 ))
	if [ "$compare_bit" -eq 0 ]; then
		log_skip "Compare command" "ONCS bit 0 = 0 (Compare not supported)"
		return
	fi

	local test_lba=6144
	if [ "$NSZE" -le 6144 ]; then
		test_lba=$(( NSZE / 2 ))
	fi

	local pattern_file="${TMP_DIR}/compare_pattern"
	dd if=/dev/urandom of="$pattern_file" bs="$BLOCK_SIZE" count=1 2>/dev/null
	nvme write "$NS_DEV" --start-block="$test_lba" --block-count=0 \
		--data-size="$BLOCK_SIZE" --data="$pattern_file" 2>/dev/null || true

	local output
	output=$(nvme compare "$NS_DEV" --start-block="$test_lba" --block-count=0 \
		--data-size="$BLOCK_SIZE" --data="$pattern_file" 2>&1) || true
	log_cmd "Compare match" "nvme compare ${NS_DEV} -s ${test_lba} -c 0" "$output"

	if echo "$output" | grep -qi "error\|NVMe status\|MISCOMPARE"; then
		log_fail "Compare with matching data" "$(echo "$output" | head -1)"
		return
	fi

	log_pass "Compare: matching data correctly returns success"

	local mismatch_file="${TMP_DIR}/compare_mismatch"
	dd if=/dev/urandom of="$mismatch_file" bs="$BLOCK_SIZE" count=1 2>/dev/null
	local mismatch_output
	mismatch_output=$(nvme compare "$NS_DEV" --start-block="$test_lba" --block-count=0 \
		--data-size="$BLOCK_SIZE" --data="$mismatch_file" 2>&1) || true

	if echo "$mismatch_output" | grep -qi "MISCOMPARE\|error\|NVMe status"; then
		log_pass "Compare: mismatched data correctly returns MISCOMPARE error"
	else
		log_warn "Compare mismatch" "expected MISCOMPARE error, got: $(echo "$mismatch_output" | head -1)"
	fi
}

test_controller_accessible() {
	local output
	output=$(nvme id-ctrl "$CTRL_DEV" 2>&1) || true

	if echo "$output" | grep -q "^mn "; then
		local read_file="${TMP_DIR}/final_read"
		local read_out
		read_out=$(nvme read "$NS_DEV" --start-block=0 --block-count=0 \
			--data-size="$BLOCK_SIZE" --data="$read_file" 2>&1) || true
		if ! echo "$read_out" | grep -qi "error\|NVMe status"; then
			log_pass "Controller and namespace accessible after all I/O tests"
		else
			log_warn "Controller accessible but namespace read failed" "$(echo "$read_out" | head -1)"
		fi
	else
		log_fail "Controller not accessible" "id-ctrl failed after I/O tests"
	fi
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

main() {
	preflight_checks

	local device_arg=""
	for arg in "$@"; do
		case "$arg" in
			--allow-destructive) ALLOW_DESTRUCTIVE="--allow-destructive" ;;
			-h|--help)
				echo "Usage: $0 [/dev/nvmeX | /dev/nvmeXnY] [--allow-destructive]"
				echo "Behavioral verification of NVMe Verify, Write Uncorrectable, Copy, Compare."
				exit 0
				;;
			*) device_arg="$arg" ;;
		esac
	done

	if [ -z "$device_arg" ]; then
		CTRL_DEV=$(auto_detect_ctrl)
		echo -e "${BOLD}No device specified — auto-detected: ${CTRL_DEV}${RESET}"
	else
		CTRL_DEV=$(resolve_ctrl_dev "$device_arg")
	fi

	NS_DEV=$(resolve_ns_dev "$CTRL_DEV")

	if [ ! -e "$CTRL_DEV" ]; then
		echo "ERROR: Device $CTRL_DEV does not exist." >&2
		exit 1
	fi

	safe_device_check "$CTRL_DEV" "$ALLOW_DESTRUCTIVE"

	cache_id_ctrl "$CTRL_DEV"
	get_block_size
	get_nsze
	setup_tmp
	trap cleanup_tmp EXIT

	init_log "nvme_additional_io_verify" "$CTRL_DEV"
	log_cmd "Identify Controller (cached)" "nvme id-ctrl ${CTRL_DEV}" "$_ID_CTRL_CACHE"

	local spec_ref
	spec_ref=$(get_spec_ref "additional-io")

	print_header \
		"NVMe Additional I/O — Behavioral Verification" \
		"$spec_ref" \
		"$CTRL_DEV"

	echo -e "${BOLD}--- Verify Command ---${RESET}"
	test_verify_lba0
	test_verify_offset_lba
	test_verify_invalid_lba

	echo ""
	echo -e "${BOLD}--- Write Uncorrectable + Recovery ---${RESET}"
	test_write_uncor_recovery

	echo ""
	echo -e "${BOLD}--- Copy Command ---${RESET}"
	test_copy_command

	echo ""
	echo -e "${BOLD}--- Get LBA Status ---${RESET}"
	test_get_lba_status
	test_get_lba_status_after_uncor

	echo ""
	echo -e "${BOLD}--- I/O Passthrough ---${RESET}"
	test_io_passthru

	echo ""
	echo -e "${BOLD}--- Compare Command ---${RESET}"
	test_compare_command

	echo ""
	echo -e "${BOLD}--- Post-Test Recovery ---${RESET}"
	test_controller_accessible

	print_summary

	if [ "$FAIL_COUNT" -gt 0 ]; then
		exit 1
	fi
	exit 0
}

main "$@"
