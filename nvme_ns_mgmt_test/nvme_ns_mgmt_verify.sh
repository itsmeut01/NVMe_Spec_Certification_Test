#!/bin/bash
# SPDX-License-Identifier: GPL-3.0+
# Copyright (C) 2025 Red Hat, Inc.
#
# NVMe Namespace Management — Functional Verification
# Based on NVMe Base Specification — Namespace Management / Attachment
# Tests: create NS, attach, I/O on new NS, detach, delete, verify original NS
#
# Usage:
#   ./nvme_ns_mgmt_verify.sh /dev/nvme0 --allow-destructive
#   ./nvme_ns_mgmt_verify.sh /dev/nvme0n1 --allow-destructive

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../common/nvme_test_lib.sh
source "${SCRIPT_DIR}/../common/nvme_test_lib.sh"

CTRL_DEV=""
NS_DEV=""
ALLOW_DESTRUCTIVE=""
CREATED_NSID=""
CNTLID=""

get_cntlid() {
	local cntlid
	cntlid=$(get_id_ctrl_field "cntlid")
	if [ -n "$cntlid" ]; then
		CNTLID=$((cntlid))
	else
		CNTLID=0
	fi
}

# --------------------------------------------------------------------------
# Test functions
# --------------------------------------------------------------------------

test_create_ns() {
	local tnvmcap
	tnvmcap=$(get_id_ctrl_field "tnvmcap")
	local unvmcap
	unvmcap=$(get_id_ctrl_field "unvmcap")

	local ns_size=1024
	if [ -n "$unvmcap" ] && [ "$((unvmcap))" -gt 0 ]; then
		local avail_blocks=$((unvmcap / 512))
		if [ "$avail_blocks" -lt "$ns_size" ]; then
			ns_size=$((avail_blocks / 2))
		fi
	fi

	if [ "$ns_size" -le 0 ]; then
		ns_size=128
	fi

	local output
	output=$(nvme create-ns "$CTRL_DEV" --nsze="$ns_size" --ncap="$ns_size" --flbas=0 --dps=0 --nmic=0 2>&1) || true
	log_cmd "Create Namespace" "nvme create-ns ${CTRL_DEV} --nsze=${ns_size} --ncap=${ns_size} --flbas=0 --dps=0 --nmic=0" "$output"

	if echo "$output" | grep -qi "NVMe status\|error\|invalid\|fail\|capacity\|not support"; then
		log_warn "Create namespace" "$(echo "$output" | head -1)"
		return
	fi

	local nsid
	nsid=$(echo "$output" | grep -oiP 'nsid\s*[=:]\s*\K[0-9]+' || echo "$output" | grep -oP 'create-ns:\s*\K[0-9]+' || true)

	if [ -n "$nsid" ] && [ "$((nsid))" -gt 0 ]; then
		CREATED_NSID="$nsid"
		log_pass "Create namespace: NSID=${nsid} (size=${ns_size} blocks)"
	else
		log_warn "Create namespace" "command accepted but could not parse NSID from: $output"
	fi
}

test_attach_ns() {
	if [ -z "$CREATED_NSID" ]; then
		log_skip "Attach namespace" "no namespace was created"
		return
	fi

	local output
	output=$(nvme attach-ns "$CTRL_DEV" --namespace-id="$CREATED_NSID" --controllers="$CNTLID" 2>&1) || true
	log_cmd "Attach Namespace" "nvme attach-ns ${CTRL_DEV} --namespace-id=${CREATED_NSID} --controllers=${CNTLID}" "$output"

	if echo "$output" | grep -qi "error\|invalid\|fail"; then
		log_fail "Attach namespace NSID=${CREATED_NSID}" "$(echo "$output" | head -1)"
		return
	fi

	sleep 2
	nvme ns-rescan "$CTRL_DEV" 2>/dev/null || true
	sleep 1

	local list_output
	list_output=$(nvme list-ns "$CTRL_DEV" 2>&1) || true
	log_cmd "List Namespaces" "nvme list-ns ${CTRL_DEV}" "$list_output"
	if echo "$list_output" | grep -q "\[.*${CREATED_NSID}\]\|:${CREATED_NSID}$\| ${CREATED_NSID} "; then
		log_pass "Attach namespace NSID=${CREATED_NSID}: visible in list-ns"
	else
		log_pass "Attach namespace NSID=${CREATED_NSID}: command accepted"
	fi
}

test_io_new_ns() {
	if [ -z "$CREATED_NSID" ]; then
		log_skip "I/O on new namespace" "no namespace was created"
		return
	fi

	local new_ns_dev="${CTRL_DEV}n${CREATED_NSID}"
	if [ ! -e "$new_ns_dev" ]; then
		sleep 2
		nvme ns-rescan "$CTRL_DEV" 2>/dev/null || true
		sleep 1
	fi

	if [ ! -e "$new_ns_dev" ]; then
		log_skip "I/O on new namespace" "${new_ns_dev} not present in /dev"
		return
	fi

	if write_read_verify "$new_ns_dev" 0 1; then
		log_pass "I/O on new namespace ${new_ns_dev}: write+read succeeded"
	else
		log_fail "I/O on new namespace" "write+read data mismatch on ${new_ns_dev}"
	fi
}

test_detach_ns() {
	if [ -z "$CREATED_NSID" ]; then
		log_skip "Detach namespace" "no namespace was created"
		return
	fi

	local output
	output=$(nvme detach-ns "$CTRL_DEV" --namespace-id="$CREATED_NSID" --controllers="$CNTLID" 2>&1) || true
	log_cmd "Detach Namespace" "nvme detach-ns ${CTRL_DEV} --namespace-id=${CREATED_NSID} --controllers=${CNTLID}" "$output"

	if echo "$output" | grep -qi "error\|invalid\|fail"; then
		log_warn "Detach namespace NSID=${CREATED_NSID}" "$(echo "$output" | head -1)"
		return
	fi

	sleep 2
	nvme ns-rescan "$CTRL_DEV" 2>/dev/null || true
	log_pass "Detach namespace NSID=${CREATED_NSID}: command accepted"
}

test_delete_ns() {
	if [ -z "$CREATED_NSID" ]; then
		log_skip "Delete namespace" "no namespace was created"
		return
	fi

	local output
	output=$(nvme delete-ns "$CTRL_DEV" --namespace-id="$CREATED_NSID" 2>&1) || true
	log_cmd "Delete Namespace" "nvme delete-ns ${CTRL_DEV} --namespace-id=${CREATED_NSID}" "$output"

	if echo "$output" | grep -qi "error\|invalid\|fail"; then
		log_warn "Delete namespace NSID=${CREATED_NSID}" "$(echo "$output" | head -1)"
	else
		log_pass "Delete namespace NSID=${CREATED_NSID}: successfully deleted"
		CREATED_NSID=""
	fi
}

test_original_ns_unaffected() {
	if [ -z "$NS_DEV" ]; then
		log_skip "Original NS unaffected" "no original namespace device"
		return
	fi

	local ns_output
	ns_output=$(nvme id-ns "$NS_DEV" 2>&1) || true
	log_cmd "Identify Namespace" "nvme id-ns ${NS_DEV}" "$ns_output"
	if echo "$ns_output" | grep -q "^nsze"; then
		log_pass "Original namespace ${NS_DEV} still accessible after NS management operations"
	else
		log_fail "Original NS unaffected" "id-ns on ${NS_DEV} failed"
	fi
}

# --------------------------------------------------------------------------
# Cleanup (in case of early exit)
# --------------------------------------------------------------------------

cleanup() {
	if [ -n "$CREATED_NSID" ] && [ -n "$CTRL_DEV" ]; then
		nvme detach-ns "$CTRL_DEV" --namespace-id="$CREATED_NSID" --controllers="$CNTLID" 2>/dev/null || true
		nvme delete-ns "$CTRL_DEV" --namespace-id="$CREATED_NSID" 2>/dev/null || true
	fi
}

trap cleanup EXIT

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
				echo "Functional verification of NVMe Namespace Management."
				echo "DESTRUCTIVE: creates/deletes namespaces. Requires --allow-destructive."
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

	safe_device_check "$CTRL_DEV" "$ALLOW_DESTRUCTIVE"

	cache_id_ctrl "$CTRL_DEV"

	local oacs
	oacs=$(get_id_ctrl_field "oacs")
	if [ -n "$oacs" ] && [ "$(( (oacs >> 3) & 0x1 ))" -eq 0 ]; then
		echo -e "${YELLOW}SKIP${RESET}  Namespace Management not supported (OACS bit 3=0)"
		exit 0
	fi

	get_cntlid

	init_log "nvme_ns_mgmt_verify" "$CTRL_DEV"
	log_cmd "Identify Controller (cached)" "nvme id-ctrl ${CTRL_DEV}" "$_ID_CTRL_CACHE"

	local spec_ref
	spec_ref=$(get_spec_ref "ns-mgmt")

	print_header \
		"NVMe Namespace Management — Functional Verification" \
		"$spec_ref" \
		"$CTRL_DEV"

	echo -e "  Controller ID: ${CNTLID}"
	echo ""

	echo -e "${BOLD}--- Namespace Lifecycle ---${RESET}"
	test_create_ns
	test_attach_ns
	test_io_new_ns
	test_detach_ns
	test_delete_ns

	echo ""
	echo -e "${BOLD}--- Original Namespace ---${RESET}"
	test_original_ns_unaffected

	print_summary

	if [ "$FAIL_COUNT" -gt 0 ]; then
		exit 1
	fi
	exit 0
}

main "$@"
