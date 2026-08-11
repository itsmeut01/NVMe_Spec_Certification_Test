Suite 13: Device Self-test Functional
=====================================

**Script:** ``nvme_dst_functional_test/nvme_dst_functional_verify.sh``
**Category:** Non-Destructive Functional
**NVMe Command:** ``nvme device-self-test``

Overview
--------

Performs functional verification of the NVMe Device Self-test command by exercising
the full lifecycle: starting a short self-test, polling until completion, inspecting
the result, testing the abort mechanism, and starting then immediately aborting an
extended self-test. This confirms that the controller correctly accepts, executes,
reports, and aborts self-test operations as required by the NVMe Base Specification.
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

2. **Short Self-test**

   a. **test_start_short_dst** -- issue the start-short-self-test command (STC=1).

      :Command: ``nvme device-self-test /dev/nvmeX -s 1``
      :Pass: command accepted without error
      :Fail: command returns error, invalid, or not-supported indication

   b. **test_poll_short_completion** -- poll ``nvme self-test-log`` until the short test completes or times out at 120 seconds.

      :Command: ``nvme self-test-log /dev/nvmeX`` (polled every 5 seconds)
      :Pass: current operation indicates no self-test in progress within timeout
      :Warn: test did not complete within 120-second timeout
      :Skip: self-test-log not available

   c. **test_short_result** -- inspect the Operation Result of the most recent self-test log entry.

      :Command: ``nvme self-test-log /dev/nvmeX``
      :Pass: result is 0x0 (completed without error) or 0x1 (aborted by command)
      :Fail: result is 0x5 (fatal or unknown test error)
      :Warn: result is 0x2, 0x3, 0x4, 0x6, 0x7, or unrecognized
      :Skip: Operation Result field not parseable, or 0xF (no entry)

3. **Self-test Abort**

   a. **test_abort_dst** -- start a short self-test, wait briefly, then issue an abort (STC=0xF).

      :Command: ``nvme device-self-test /dev/nvmeX -s 1`` then ``nvme device-self-test /dev/nvmeX -s 0xf``
      :Pass: abort command accepted without error
      :Warn: abort command returns error or not-supported indication

4. **Extended Self-test (start + immediate abort)**

   a. **test_start_extended_dst** -- issue the start-extended-self-test command (STC=2).

      :Command: ``nvme device-self-test /dev/nvmeX -s 2``
      :Pass: command accepted without error
      :Fail: command returns error, invalid, or not-supported indication

   b. **test_abort_extended_immediately** -- abort the extended self-test shortly after start and verify the result entry.

      :Command: ``nvme device-self-test /dev/nvmeX -s 0xf`` then ``nvme self-test-log /dev/nvmeX``
      :Pass: abort accepted and result entry shows aborted (0x1) or completed (0x0)
      :Warn: abort command returns error

5. **Summary**

   - Report total PASS / FAIL / SKIP / WARN counts
   - Exit with non-zero status if any FAIL

Result Codes
------------

- **PASS** -- check succeeded, device conforms to spec
- **FAIL** -- device non-compliance with NVMe specification
- **SKIP** -- test not applicable (DST not supported, unparseable output)
- **WARN** -- advisory condition, not a hard failure
