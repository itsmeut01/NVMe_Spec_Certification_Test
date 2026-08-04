Suite 9: Commands Supported and Effects Log
============================================

**Script:** ``nvme_effects_log_test/nvme_effects_log_verify.sh``
**Category:** Read-Only
**NVMe Command:** ``nvme effects-log``

Overview
--------

Verifies the Commands Supported and Effects Log by running
``nvme effects-log`` and confirming that all mandatory Admin and I/O command
opcodes are reported as supported (CSUPP=1).  The suite checks for the six
mandatory Admin commands (Identify, Get Log Page, Get Features, Set Features,
Abort, Async Event Request) and the three mandatory NVM I/O commands (Read,
Write, Flush).  The entire suite is skipped if the controller does not support
the Commands Supported and Effects Log (LPA bit 1 = 0).

Prerequisites
-------------

- Root privileges (``sudo``)
- ``nvme-cli`` installed
- NVMe device (e.g., ``/dev/nvme0``)
- Commands Supported and Effects Log support (LPA bit 1 = 1; suite skips
  otherwise)

Test Steps
----------

1. **Preflight & Setup**

   - Verify root privileges and ``nvme-cli`` availability
   - Resolve target controller device (auto-detect or user-specified)
   - Cache Identify Controller data (``nvme id-ctrl``)
   - Check LPA bit 1; skip entire suite if Command Effects Log is not
     supported
   - Initialize logging
   - Run ``nvme effects-log /dev/nvmeX`` to capture output

2. **Command Access**

   a. **test_effects_log_command** -- Confirm that ``nvme effects-log``
      executes and produces valid output.

      :Command: ``nvme effects-log /dev/nvmeX``
      :Pass: Command returns non-empty output without error indicators
      :Skip: Output is empty, or contains error/unsupported messages

   .. note:: If the effects-log data is not available (empty or error output),
      all remaining tests are skipped and the suite exits with the current
      summary.

3. **Mandatory Admin Commands**

   a. **test_admin_identify** -- Verify Admin Identify (opcode 06h) is
      reported as supported (ACS6 with CSUPP=1).

      :Pass: Opcode 06h entry found with CSUPP indicated
      :Fail: Opcode 06h not found in effects-log output

   b. **test_admin_get_log_page** -- Verify Admin Get Log Page (opcode 02h)
      is reported as supported (ACS2 with CSUPP=1).

      :Pass: Opcode 02h entry found with CSUPP indicated
      :Fail: Opcode 02h not found in effects-log output

   c. **test_admin_get_features** -- Verify Admin Get Features (opcode 0Ah)
      is reported as supported (ACS10 with CSUPP=1).

      :Pass: Opcode 0Ah entry found with CSUPP indicated
      :Fail: Opcode 0Ah not found in effects-log output

   d. **test_admin_set_features** -- Verify Admin Set Features (opcode 09h)
      is reported as supported (ACS9 with CSUPP=1).

      :Pass: Opcode 09h entry found with CSUPP indicated
      :Fail: Opcode 09h not found in effects-log output

   e. **test_admin_abort** -- Verify Admin Abort (opcode 08h) is reported
      as supported (ACS8 with CSUPP=1).

      :Pass: Opcode 08h entry found with CSUPP indicated
      :Fail: Opcode 08h not found in effects-log output

   f. **test_admin_async_event** -- Verify Admin Async Event Request
      (opcode 0Ch) is reported as supported (ACS12 with CSUPP=1).

      :Pass: Opcode 0Ch entry found with CSUPP indicated
      :Fail: Opcode 0Ch not found in effects-log output

4. **Mandatory I/O Commands**

   a. **test_io_read** -- Verify I/O Read (opcode 02h) is reported as
      supported (IOCS2 with CSUPP=1).

      :Pass: I/O opcode 02h entry found with CSUPP indicated
      :Warn: I/O opcode 02h not found (may be due to output format)

   b. **test_io_write** -- Verify I/O Write (opcode 01h) is reported as
      supported (IOCS1 with CSUPP=1).

      :Pass: I/O opcode 01h entry found with CSUPP indicated
      :Warn: I/O opcode 01h not found (may be due to output format)

   c. **test_io_flush** -- Verify I/O Flush (opcode 00h) is reported as
      supported (IOCS0 with CSUPP=1).

      :Pass: I/O opcode 00h entry found with CSUPP indicated
      :Warn: I/O opcode 00h not found (may be due to output format)

5. **Summary**

   - Report total PASS / FAIL / SKIP / WARN counts
   - Exit with non-zero status if any FAIL

Result Codes
------------

- **PASS** -- check succeeded, device conforms to spec
- **FAIL** -- device non-compliance with NVMe specification
- **SKIP** -- test not applicable (version gate, missing feature)
- **WARN** -- advisory condition, not a hard failure
