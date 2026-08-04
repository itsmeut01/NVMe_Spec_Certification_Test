Suite 14: Async Event
=====================

**Script:** ``nvme_async_event_test/nvme_async_event_verify.sh``
**Category:** Non-Destructive Functional
**NVMe Command:** ``nvme get-feature``, ``nvme set-feature``, ``nvme smart-log``, ``nvme admin-passthru``

Overview
--------

Validates Asynchronous Event Request (AER) capabilities and related controller
behavior. The suite checks that the controller advertises a non-zero AER limit
(AERL), attempts to trigger a temperature threshold event by temporarily lowering
TMPTH, verifies error log counter increments after an invalid admin opcode
injection, confirms SMART log consistency post-injection, exercises the Abort
command with valid and invalid SQID values, and reads the Async Event Configuration
(AEC) feature (FID 0x0B). Temperature thresholds are saved and restored
automatically.

Prerequisites
-------------

- Root privileges (``sudo``)
- ``nvme-cli`` installed
- NVMe device (e.g., ``/dev/nvme0``)

Test Steps
----------

1. **Preflight & Setup**

   - Verify root privileges and ``nvme-cli`` availability
   - Resolve target controller device (auto-detect or user-specified)
   - Cache Identify Controller data (``nvme id-ctrl``)
   - Initialize logging

2. **AER Capability**

   a. **test_aerl_nonzero** -- verify the Async Event Request Limit (AERL) supports at least one outstanding AER.

      :Command: parses ``aerl`` field from cached ``nvme id-ctrl``
      :Pass: AERL + 1 >= 1 (at least one outstanding AER supported)
      :Fail: AERL indicates zero outstanding AERs supported
      :Skip: AERL field not found in id-ctrl output

3. **Temperature Event**

   a. **test_temp_event_trigger** -- attempt to trigger a temperature AER by setting TMPTH below the current temperature.

      :Command: ``nvme get-feature /dev/nvmeX -f 0x04`` (save), ``nvme smart-log /dev/nvmeX`` (read temp), ``nvme set-feature /dev/nvmeX -f 0x04 -v <low_thresh>`` (trigger), ``nvme smart-log`` (check critical_warning bit 1), then restore original TMPTH
      :Pass: critical_warning bit 1 set (temperature exceeded threshold)
      :Warn: bit 1 not set (controller may batch events)
      :Skip: cannot save TMPTH, cannot read temperature, or cannot read critical_warning

4. **Error Injection**

   a. **test_error_log_increment** -- inject an invalid admin opcode and verify the error log entry count increments.

      :Command: ``nvme smart-log /dev/nvmeX`` (before), ``nvme admin-passthru /dev/nvmeX --opcode=0x7f --cdw10=0`` (inject), ``nvme smart-log /dev/nvmeX`` (after)
      :Pass: ``num_err_log_entries`` increased after injection
      :Warn: count unchanged (controller may not log all errors)
      :Skip: cannot read ``num_err_log_entries`` before or after injection

   b. **test_smart_after_error** -- confirm the SMART log is still readable and consistent after error injection.

      :Command: ``nvme smart-log /dev/nvmeX``
      :Pass: SMART log contains temperature and available spare fields
      :Fail: smart-log command fails
      :Warn: some expected fields missing from output

5. **Abort Command (Spec 5.1.1)**

   a. **test_abort_command** -- issue an Abort command for CID=0, SQID=0 and verify the controller remains operational.

      :Command: ``nvme admin-passthru /dev/nvmeX --opcode=0x08 --cdw10=0x00000000`` then ``nvme id-ctrl /dev/nvmeX``
      :Pass: controller responds to id-ctrl after abort (remains operational)
      :Fail: controller not responding after abort

   b. **test_abort_invalid_sqid** -- issue an Abort command with an invalid SQID (0xFFFF) and verify graceful handling.

      :Command: ``nvme admin-passthru /dev/nvmeX --opcode=0x08 --cdw10=0xFFFF0000`` then ``nvme id-ctrl /dev/nvmeX``
      :Pass: controller responds to id-ctrl after invalid SQID abort (no crash)
      :Fail: controller not responding after abort with invalid SQID

6. **AER Configuration Check**

   a. **test_aec_readable** -- read the Async Event Configuration feature (FID 0x0B) and decode its fields.

      :Command: ``nvme get-feature /dev/nvmeX -f 0x0b``
      :Pass: feature returns a parseable result value; reports SMART/CW mask, NS_Attr, and FW_Act bits
      :Fail: mandatory feature returns no result

7. **Summary**

   - Report total PASS / FAIL / SKIP / WARN counts
   - Exit with non-zero status if any FAIL

Result Codes
------------

- **PASS** -- check succeeded, device conforms to spec
- **FAIL** -- device non-compliance with NVMe specification
- **SKIP** -- test not applicable (feature unreadable, field not found)
- **WARN** -- advisory condition, not a hard failure
