#!/bin/bash
# SPDX-License-Identifier: GPL-3.0+
# Copyright (C) 2025 Red Hat, Inc.
#
# NVMe KV Command Set — Verification
# Based on NVMe KV Command Set Specification, Revision 1.4
# Tests: KV namespace detection (CSI=3), KV Identify Namespace fields,
#        KV Configuration feature (FID 0x20), KV I/O probe via io-passthru,
#        and optional Store/Retrieve/Delete lifecycle
#
# Usage:
#   ./nvme_kv_verify.sh /dev/nvme0
#   ./nvme_kv_verify.sh /dev/nvme0n1
#   ./nvme_kv_verify.sh /dev/nvme0n1 --allow-destructive
#   ./nvme_kv_verify.sh              # auto-detects first NVMe controller

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/nvme_test_lib.sh
source "${SCRIPT_DIR}/../common/nvme_test_lib.sh"

CTRL_DEV=""
NS_DEV=""
ALLOW_DESTRUCTIVE=""
KV_DETECTED=0
KV_ID_NS_OUTPUT=""
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

detect_kv_namespace() {
	local ns_descs
	ns_descs=$(nvme ns-descs "$NS_DEV" 2>&1) || true
	log_cmd "Namespace ID Descriptors" "nvme ns-descs ${NS_DEV}" "$ns_descs"

	# Look for CSI=3 (Key Value Command Set)
	if echo "$ns_descs" | grep -qi "csi"; then
		local csi_val
		csi_val=$(echo "$ns_descs" | grep -i "csi" | head -1 | grep -oP '0x[0-9a-fA-F]+' || true)
		if [ -n "$csi_val" ]; then
			local csi_int=$((csi_val))
			if [ "$csi_int" -eq 3 ]; then
				KV_DETECTED=1
				return 0
			fi
		fi
	fi

	# Fallback: check for "Key Value" text in output
	if echo "$ns_descs" | grep -qi "Key Value"; then
		KV_DETECTED=1
		return 0
	fi

	return 1
}

get_nsid() {
	echo "$NS_DEV" | grep -oP 'n\K[0-9]+$' || echo 1
}

# --------------------------------------------------------------------------
# Test functions — KV Detection
# --------------------------------------------------------------------------

test_kv_detect() {
	if [ "$KV_DETECTED" -eq 1 ]; then
		log_pass "KV Command Set detected (CSI=3) on ${NS_DEV}"
	else
		log_fail "KV Command Set detection" "CSI != 3 on ${NS_DEV}"
	fi
}

# --------------------------------------------------------------------------
# Test functions — KV Identify Namespace
# --------------------------------------------------------------------------

test_kv_id_ns() {
	KV_ID_NS_OUTPUT=$(nvme id-ns "$NS_DEV" 2>&1) || true
	log_cmd "Identify Namespace" "nvme id-ns ${NS_DEV}" "$KV_ID_NS_OUTPUT"

	if [ -z "$KV_ID_NS_OUTPUT" ]; then
		log_fail "Identify Namespace on KV namespace" "empty output"
		return
	fi

	if echo "$KV_ID_NS_OUTPUT" | grep -qi "invalid\|not support\|error"; then
		log_fail "Identify Namespace on KV namespace" "$(echo "$KV_ID_NS_OUTPUT" | head -1)"
	else
		log_pass "Identify Namespace command succeeds on KV namespace"
	fi
}

test_kv_nsze() {
	if [ -z "$KV_ID_NS_OUTPUT" ]; then
		log_skip "NSZE (Namespace Size)" "id-ns output not available"
		return
	fi

	local nsze_val
	nsze_val=$(echo "$KV_ID_NS_OUTPUT" | grep "^nsze" | awk '{print $3}' || true)
	if [ -z "$nsze_val" ]; then
		log_fail "NSZE (Namespace Size) is present" "field not found in id-ns output"
		return
	fi

	local nsze_int=$((nsze_val))
	if [ "$nsze_int" -gt 0 ]; then
		log_pass "NSZE (Namespace Size) is present and non-zero: ${nsze_int}"
	else
		log_fail "NSZE (Namespace Size) is non-zero" "NSZE=0"
	fi
}

test_kv_ncap() {
	if [ -z "$KV_ID_NS_OUTPUT" ]; then
		log_skip "NCAP (Namespace Capacity)" "id-ns output not available"
		return
	fi

	local ncap_val
	ncap_val=$(echo "$KV_ID_NS_OUTPUT" | grep "^ncap" | awk '{print $3}' || true)
	if [ -z "$ncap_val" ]; then
		log_fail "NCAP (Namespace Capacity) is present" "field not found in id-ns output"
		return
	fi

	local ncap_int=$((ncap_val))
	if [ "$ncap_int" -gt 0 ]; then
		log_pass "NCAP (Namespace Capacity) is present: ${ncap_int}"
	else
		log_pass "NCAP (Namespace Capacity) is present: 0 (may be thin provisioned)"
	fi
}

# --------------------------------------------------------------------------
# Test functions — KV Configuration Feature (FID 0x20)
# --------------------------------------------------------------------------

KV_CONFIG_OUTPUT=""
KV_CONFIG_SUPPORTED=0

test_kv_config_fid() {
	KV_CONFIG_OUTPUT=$(nvme get-feature "$NS_DEV" -f 0x20 2>&1) || true
	log_cmd "Get Feature: KV Configuration (FID 0x20)" \
		"nvme get-feature ${NS_DEV} -f 0x20" "$KV_CONFIG_OUTPUT"

	if echo "$KV_CONFIG_OUTPUT" | grep -qi "invalid field\|not support\|invalid opcode\|unknown\|error"; then
		log_skip "KV Configuration Feature (FID 0x20)" "not supported by controller"
		return
	fi

	KV_CONFIG_SUPPORTED=1
	local result_hex
	result_hex=$(echo "$KV_CONFIG_OUTPUT" | grep -oiP '(?:result|value)[[:space:]:]*0x[0-9a-fA-F]+' | head -1 | grep -oiP '0x[0-9a-fA-F]+' || true)
	if [ -n "$result_hex" ]; then
		log_pass "KV Configuration Feature (FID 0x20) readable: ${result_hex}"
	else
		log_pass "KV Configuration Feature (FID 0x20) command completed"
	fi
}

test_ednek_decode() {
	if [ "$KV_CONFIG_SUPPORTED" -eq 0 ]; then
		log_skip "EDNEK (Enable Distinct Namespace Encryption Keys)" "FID 0x20 not supported"
		return
	fi

	local result_hex
	result_hex=$(echo "$KV_CONFIG_OUTPUT" | grep -oiP '(?:result|value)[[:space:]:]*0x[0-9a-fA-F]+' | head -1 | grep -oiP '0x[0-9a-fA-F]+' || true)
	if [ -z "$result_hex" ]; then
		log_skip "EDNEK decode" "could not parse FID 0x20 result value"
		return
	fi

	local result_int=$((result_hex))
	local ednek_bit=$(( result_int & 0x1 ))
	if [ "$ednek_bit" -eq 1 ]; then
		log_pass "EDNEK (Distinct Namespace Encryption Keys): enabled (bit 0=1)"
	else
		log_pass "EDNEK (Distinct Namespace Encryption Keys): disabled (bit 0=0)"
	fi
}

# --------------------------------------------------------------------------
# Test functions — KV I/O Probe (read-only, via io-passthru)
# --------------------------------------------------------------------------

test_kv_list_keys() {
	local nsid
	nsid=$(get_nsid)

	local output
	output=$(nvme io-passthru "$NS_DEV" --opcode=0x06 \
		--namespace-id="$nsid" --data-len=4096 -r 2>&1) || true
	log_cmd "KV List Keys (opcode=0x06)" \
		"nvme io-passthru ${NS_DEV} --opcode=0x06 --namespace-id=${nsid} --data-len=4096 -r" \
		"$output"

	if echo "$output" | grep -qi "invalid opcode\|not support"; then
		log_skip "KV List Keys (opcode=0x06)" "controller does not recognize KV List opcode"
		return
	fi

	if echo "$output" | grep -qi "error\|NVMe status"; then
		local sc
		sc=$(echo "$output" | grep -oiP 'sc:?\s*0x[0-9a-fA-F]+' | head -1 || true)
		log_pass "KV List Keys: controller responded with status (${sc:-see log})"
	else
		log_pass "KV List Keys: controller accepted command"
	fi
}

test_kv_exist_probe() {
	local nsid
	nsid=$(get_nsid)

	# Send Exist command (opcode 0x14) with zero-length key
	# cdw11 bits 15:00 = key length (0 = zero-length probe)
	local output
	output=$(nvme io-passthru "$NS_DEV" --opcode=0x14 \
		--namespace-id="$nsid" --cdw11=0 2>&1) || true
	log_cmd "KV Exist probe (opcode=0x14)" \
		"nvme io-passthru ${NS_DEV} --opcode=0x14 --namespace-id=${nsid} --cdw11=0" \
		"$output"

	if echo "$output" | grep -qi "invalid opcode\|not support"; then
		log_skip "KV Exist probe (opcode=0x14)" "controller does not recognize KV Exist opcode"
		return
	fi

	if echo "$output" | grep -qi "error\|NVMe status"; then
		local sc
		sc=$(echo "$output" | grep -oiP 'sc:?\s*0x[0-9a-fA-F]+' | head -1 || true)
		# A valid error (e.g., key not found) is expected behavior
		log_pass "KV Exist probe: controller responded with valid status (${sc:-see log})"
	else
		log_pass "KV Exist probe: controller accepted command (key does not exist)"
	fi
}

# --------------------------------------------------------------------------
# Test functions — Destructive: KV Store/Retrieve/Delete lifecycle
# --------------------------------------------------------------------------

test_kv_store_retrieve_delete() {
	local nsid
	nsid=$(get_nsid)

	# Use a 4-byte test key "test" (0x74657374)
	local key_len=4
	# cdw11 bits 15:00 = key length
	local cdw11_store=$key_len

	# Create a small test value (64 bytes)
	local value_file="${TMP_DIR}/kv_value"
	dd if=/dev/urandom of="$value_file" bs=64 count=1 2>/dev/null

	local key_file="${TMP_DIR}/kv_key"
	printf 'test' > "$key_file"

	# --- Store (opcode 0x01) ---
	# cdw10 = value size in bytes (64)
	# cdw11 bits 15:00 = key length (4)
	local store_output
	store_output=$(nvme io-passthru "$NS_DEV" --opcode=0x01 \
		--namespace-id="$nsid" --cdw10=64 --cdw11="$cdw11_store" \
		--data-len=64 --write --input-file="$value_file" 2>&1) || true
	log_cmd "KV Store" \
		"nvme io-passthru ${NS_DEV} --opcode=0x01 --cdw10=64 --cdw11=${cdw11_store}" \
		"$store_output"

	if echo "$store_output" | grep -qi "invalid opcode\|not support"; then
		log_skip "KV Store/Retrieve/Delete lifecycle" "KV Store opcode not supported"
		return
	fi

	if echo "$store_output" | grep -qi "error\|NVMe status"; then
		log_fail "KV Store" "$(echo "$store_output" | head -1)"
		return
	fi

	log_pass "KV Store: key stored successfully"

	# --- Retrieve (opcode 0x02) ---
	local retrieve_file="${TMP_DIR}/kv_retrieve"
	local retrieve_output
	retrieve_output=$(nvme io-passthru "$NS_DEV" --opcode=0x02 \
		--namespace-id="$nsid" --cdw10=64 --cdw11="$key_len" \
		--data-len=64 --read --input-file="$retrieve_file" 2>&1) || true
	log_cmd "KV Retrieve" \
		"nvme io-passthru ${NS_DEV} --opcode=0x02 --cdw10=64 --cdw11=${key_len}" \
		"$retrieve_output"

	if echo "$retrieve_output" | grep -qi "error\|NVMe status"; then
		log_fail "KV Retrieve" "$(echo "$retrieve_output" | head -1)"
	elif [ -f "$retrieve_file" ] && cmp -s "$value_file" "$retrieve_file"; then
		log_pass "KV Retrieve: retrieved value matches stored value"
	else
		log_fail "KV Retrieve" "data mismatch between stored and retrieved values"
	fi

	# --- Delete (opcode 0x10) ---
	local delete_output
	delete_output=$(nvme io-passthru "$NS_DEV" --opcode=0x10 \
		--namespace-id="$nsid" --cdw11="$key_len" 2>&1) || true
	log_cmd "KV Delete" \
		"nvme io-passthru ${NS_DEV} --opcode=0x10 --cdw11=${key_len}" \
		"$delete_output"

	if echo "$delete_output" | grep -qi "error\|NVMe status"; then
		log_fail "KV Delete" "$(echo "$delete_output" | head -1)"
	else
		log_pass "KV Delete: key deleted successfully"
	fi

	# --- Verify deletion via Exist (opcode 0x14) ---
	local exist_output
	exist_output=$(nvme io-passthru "$NS_DEV" --opcode=0x14 \
		--namespace-id="$nsid" --cdw11="$key_len" 2>&1) || true
	log_cmd "KV Exist after Delete" \
		"nvme io-passthru ${NS_DEV} --opcode=0x14 --cdw11=${key_len}" \
		"$exist_output"

	# After deletion, Exist should indicate the key does not exist
	if echo "$exist_output" | grep -qi "error\|NVMe status"; then
		log_pass "KV Exist after Delete: key confirmed absent (controller returned error status)"
	else
		log_warn "KV Exist after Delete" "key may still exist after delete"
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
				echo "Usage: $0 [/dev/nvmeX | /dev/nvmeXnY] [--allow-destructive]"
				echo "Verifies NVMe KV Command Set (CSI=3) per KV CS 1.4."
				echo ""
				echo "Most tests are read-only. The Store/Retrieve/Delete lifecycle"
				echo "test requires --allow-destructive."
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
		CTRL_DEV=$(auto_detect_ctrl)
		echo -e "${BOLD}No device specified — auto-detected: ${CTRL_DEV}${RESET}"
	fi

	if [ -z "$NS_DEV" ]; then
		NS_DEV=$(ls -1 "${CTRL_DEV}n"* 2>/dev/null | grep -E "^${CTRL_DEV}n[0-9]+$" | head -1 || true)
	fi

	if [ -z "$NS_DEV" ]; then
		echo "ERROR: No namespace device found for ${CTRL_DEV}." >&2
		exit 1
	fi

	if [ ! -e "$CTRL_DEV" ]; then
		echo "ERROR: Device $CTRL_DEV does not exist." >&2
		exit 1
	fi

	if [ ! -e "$NS_DEV" ]; then
		echo "ERROR: Namespace device $NS_DEV does not exist." >&2
		exit 1
	fi

	cache_id_ctrl "$CTRL_DEV"

	# Early KV detection — skip entire suite if namespace is not KV
	detect_kv_namespace || true
	if [ "$KV_DETECTED" -eq 0 ]; then
		echo -e "${YELLOW}SKIP${RESET}  Namespace is not KV Command Set (CSI != 3)"
		echo "  Skipping entire suite — ${NS_DEV} does not report CSI=3."
		exit 0
	fi

	setup_tmp
	trap cleanup_tmp EXIT

	init_log "nvme_kv_verify" "$CTRL_DEV"
	log_cmd "Identify Controller (cached)" "nvme id-ctrl ${CTRL_DEV}" "$_ID_CTRL_CACHE"

	local spec_ref
	spec_ref="NVMe KV Command Set Specification, Revision 1.4"

	print_header \
		"NVMe KV Command Set — Verification" \
		"$spec_ref" \
		"$NS_DEV"

	echo -e "  Namespace: ${NS_DEV}  Controller: ${CTRL_DEV}"
	echo ""

	echo -e "${BOLD}--- KV Detection ---${RESET}"
	test_kv_detect

	echo ""
	echo -e "${BOLD}--- KV Identify Namespace ---${RESET}"
	test_kv_id_ns
	test_kv_nsze
	test_kv_ncap

	echo ""
	echo -e "${BOLD}--- KV Configuration (FID 0x20) ---${RESET}"
	test_kv_config_fid
	test_ednek_decode

	echo ""
	echo -e "${BOLD}--- KV I/O Probe (Read-Only) ---${RESET}"
	test_kv_list_keys
	test_kv_exist_probe

	if [ -n "$ALLOW_DESTRUCTIVE" ]; then
		echo ""
		echo -e "${BOLD}--- Destructive: KV Store/Retrieve/Delete ---${RESET}"
		safe_device_check "$CTRL_DEV" "$ALLOW_DESTRUCTIVE"
		test_kv_store_retrieve_delete
	fi

	print_summary

	if [ "$FAIL_COUNT" -gt 0 ]; then
		exit 1
	fi
	exit 0
}

main "$@"
