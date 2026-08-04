Suite 20: Sanitize
==================

**Script:** ``nvme_sanitize_test/nvme_sanitize_verify.sh``
**Category:** Destructive
**NVMe Command:** ``nvme sanitize``, ``nvme sanitize-log``

Overview
--------

This suite validates the NVMe Sanitize command, which cryptographically or physically erases all user data across all namespaces on the controller. It tests Block Erase sanitize (sanact=2), polls the sanitize log for progress and completion, verifies the final sanitize status, tests Overwrite sanitize (sanact=3) when supported, and confirms that I/O operations succeed after sanitize completes. The suite is skipped if the controller does not support sanitize (SANICAP = 0) or the NVMe version is below 1.3. The drive is dirtied with random data before each sanitize operation.

Prerequisites
-------------

- Root privileges (``sudo``)
- ``nvme-cli`` installed
- NVMe device (e.g., ``/dev/nvme0``)
- ``--allow-destructive`` flag required
- Non-OS NVMe device (OS drive is always refused)
- NVMe 1.3 or later
- Controller must support Sanitize (SANICAP != 0)

Test Steps
----------

1. **Preflight & Setup**

   - Verify root privileges and ``nvme-cli`` availability
   - Resolve target controller and namespace devices
   - Perform OS drive safety check (``safe_device_check``)
   - Cache Identify Controller data (``nvme id-ctrl``)
   - Verify NVMe version >= 1.3; skip entire suite if not
   - Read SANICAP field; skip entire suite if SANICAP = 0
   - Parse SANICAP bits: BES (Block Erase Support), OWS (Overwrite Support), CES (Crypto Erase Support)
   - Initialize logging

2. **Block Erase Sanitize**

   a. **test_block_erase** -- Write random data to dirty the drive, then issue Block Erase sanitize (sanact=2).

      :Command: ``nvme sanitize /dev/nvmeX --sanact=2``
      :Pass: sanitize command accepted
      :Fail: command returns error
      :Skip: SANICAP BES bit not set

   b. **test_poll_sanitize** -- Wait for sanitize to start (SSTAT in-progress), then poll sanitize-log until completion or timeout using the controller-reported estimated time.

      :Command: ``nvme sanitize-log /dev/nvmeX`` (polled)
      :Pass: sanitize completed successfully (SSTAT status bits = 001b or 100b)
      :Fail: sanitize reported failure (SSTAT status bits = 011b)
      :Warn: SSTAT never reached in-progress, or timeout exceeded
      :Skip: Block Erase not initiated

   c. **test_sanitize_result** -- Read the sanitize log and verify the final SSTAT indicates success.

      :Command: ``nvme sanitize-log /dev/nvmeX``
      :Pass: SSTAT indicates completed successfully
      :Fail: SSTAT indicates failure
      :Warn: still in progress or unexpected status bits
      :Skip: Block Erase not initiated or could not parse sanitize-log

3. **Overwrite Sanitize**

   a. **test_overwrite_sanitize** -- Issue Overwrite sanitize (sanact=3) with pattern 0x12345678, wait for start, then poll to completion.

      :Command: ``nvme sanitize /dev/nvmeX --sanact=3 --ovrpat=0x12345678``
      :Pass: overwrite sanitize command accepted and completed successfully
      :Fail: overwrite sanitize reported failure
      :Warn: command returned error, SSTAT never reached in-progress, or timeout exceeded
      :Skip: SANICAP OWS bit not set

4. **Post-Sanitize I/O**

   a. **test_io_post_sanitize** -- Verify namespace is accessible via id-ns, detect block size, then perform write+read I/O at LBA 0.

      :Command: ``nvme id-ns`` + ``nvme write`` / ``nvme read`` on namespace
      :Pass: write+read data matches after sanitize
      :Fail: namespace not accessible or data mismatch
      :Skip: no namespace device

5. **Summary**

   - Report total PASS / FAIL / SKIP / WARN counts
   - Exit with non-zero status if any FAIL

Result Codes
------------

- **PASS** -- check succeeded, device conforms to spec
- **FAIL** -- device non-compliance with NVMe specification
- **SKIP** -- test not applicable (Sanitize not supported, NVMe < 1.3, specific sanitize type not supported)
- **WARN** -- advisory condition, not a hard failure (e.g., timeout waiting for sanitize completion)
