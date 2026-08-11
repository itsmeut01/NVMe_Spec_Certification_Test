Suite 12: Device Self-test Log
==============================

**Script:** ``nvme_self_test_log_test/nvme_self_test_log_verify.sh``
**Category:** Read-Only
**NVMe Command:** ``nvme self-test-log``

Overview
--------

Validates the Device Self-test Log returned by the controller. The suite verifies
that the ``nvme self-test-log`` command succeeds, inspects the current operation
status, counts completed self-test result entries, checks that result codes and
segment numbers fall within valid ranges defined by the NVMe Base Specification,
and cross-validates Power-On Hours (POH) timestamps against the current SMART log.
The entire suite is skipped if Device Self-test is not supported (OACS bit 4 = 0).

Prerequisites
-------------

- Root privileges (``sudo``)
- ``nvme-cli`` installed
- NVMe device (e.g., ``/dev/nvme0``)
- Device Self-test support (OACS bit 4 = 1)

Test Steps
----------

1. **Preflight & Setup**

   - Verify root privileges and ``nvme-cli`` availability
   - Resolve target controller device (auto-detect or user-specified)
   - Cache Identify Controller data (``nvme id-ctrl``)
   - Check OACS bit 4; skip entire suite if DST not supported
   - Initialize logging

2. **Command Access**

   a. **test_dst_log_command** -- verify that ``nvme self-test-log`` executes and returns output.

      :Command: ``nvme self-test-log /dev/nvmeX``
      :Pass: command returns non-empty output without error indicators
      :Fail: command returns empty output
      :Skip: output contains "invalid", "not support", or "unknown"

3. **Current Operation**

   a. **test_current_operation** -- report the current Device Self-test operation status.

      :Command: parses ``nvme self-test-log`` output for current operation field
      :Pass: status indicates no test in progress, a test in progress (Short/Extended/Vendor), or any parseable status value; also passes if field not found (no history)

4. **Completed Results**

   a. **test_completed_results** -- count the number of completed self-test result entries in the log.

      :Command: parses ``nvme self-test-log`` output for result entries
      :Pass: one or more entries found, or no entries (device may have no test history)

   b. **test_result_codes** -- validate that all self-test result codes are within the spec-defined range.

      :Command: parses result/status code fields from ``nvme self-test-log`` output
      :Pass: all codes are in range 0x0--0x7 or 0xF; also passes if no entries exist
      :Fail: one or more entries have a code value greater than 0xF

5. **Entry Validation**

   a. **test_segment_numbers** -- verify all segment numbers are within the valid range 0--255.

      :Command: parses segment fields from ``nvme self-test-log`` output
      :Pass: all segment numbers are 0--255; also passes if no segment data exists
      :Fail: one or more segment numbers exceed 255

   b. **test_poh_timestamps** -- cross-check DST entry Power-On Hours against current SMART POH.

      :Command: ``nvme smart-log /dev/nvmeX`` to obtain current POH, then compares against DST entries
      :Pass: all DST POH values are less than or equal to current SMART POH
      :Warn: one or more DST entries have POH exceeding current SMART POH

6. **Summary**

   - Report total PASS / FAIL / SKIP / WARN counts
   - Exit with non-zero status if any FAIL

Result Codes
------------

- **PASS** -- check succeeded, device conforms to spec
- **FAIL** -- device non-compliance with NVMe specification
- **SKIP** -- test not applicable (DST not supported, no test history)
- **WARN** -- advisory condition, not a hard failure
