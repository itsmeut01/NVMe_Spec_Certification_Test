Suite 7: Controller Registers
==============================

**Script:** ``nvme_show_regs_test/nvme_show_regs_verify.sh``
**Category:** Read-Only
**NVMe Command:** ``nvme show-regs``

Overview
--------

Verifies the NVMe controller's memory-mapped registers as exposed by
``nvme show-regs``.  The suite checks the Controller Status register (CSTS) for
readiness and absence of fatal errors, the Controller Configuration register (CC)
for the enable bit, the Capabilities register (CAP) for queue depth, command set
support, and timeout values, and the Version register (VS) for consistency with
the Identify Controller data.  NVMe 2.0+ fields such as Controller Ready Modes
(CRMS) and Controller Ready Timeouts (CRTO) are tested when the spec version
warrants it.

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
   - Run ``nvme show-regs /dev/nvmeX -H`` to capture register output (falls
     back to non-human-readable mode if ``-H`` fails)

2. **Register Access**

   a. **test_show_regs_command** -- Confirm that ``nvme show-regs`` executes
      and produces output.

      :Command: ``nvme show-regs /dev/nvmeX -H``
      :Pass: Command returns non-empty output without error indicators
      :Fail: Output is empty
      :Skip: Controller reports the command as unsupported

   .. note:: If register access is not supported, all remaining tests are
      skipped and the suite exits with the current summary.

3. **Controller Status (CSTS)**

   a. **test_csts_rdy** -- Check that the Controller Ready bit (CSTS.RDY) is
      set to 1.

      :Pass: CSTS.RDY = 1 (controller ready)
      :Fail: CSTS.RDY = 0 (controller not ready)
      :Skip: CSTS register could not be read

   b. **test_csts_cfs** -- Check that the Controller Fatal Status bit
      (CSTS.CFS) is cleared.

      :Pass: CSTS.CFS = 0 (no fatal status)
      :Fail: CSTS.CFS = 1 (fatal controller status)
      :Skip: CSTS register could not be read

   c. **test_csts_shst** -- Check the Shutdown Status field (CSTS.SHST) for
      normal operation (00b).

      :Pass: CSTS.SHST = 00b (normal operation)
      :Warn: CSTS.SHST indicates a non-normal shutdown state
      :Skip: CSTS register could not be read

4. **Controller Configuration (CC)**

   a. **test_cc_en** -- Check that the Enable bit (CC.EN) is set to 1.

      :Pass: CC.EN = 1 (controller enabled)
      :Fail: CC.EN = 0 (controller disabled)
      :Skip: CC register could not be read

5. **Controller Capabilities (CAP)**

   a. **test_cap_mqes** -- Read the Maximum Queue Entries Supported field
      (CAP.MQES) and verify it is greater than zero.

      :Pass: CAP.MQES + 1 > 0 (max queue entries reported)
      :Fail: CAP.MQES + 1 = 0
      :Skip: CAP register could not be read

   b. **test_cap_css** -- Read the Command Sets Supported field (CAP.CSS) and
      report whether the NVM command set is supported (bit 0).

      :Pass: CAP.CSS value is reported (always passes)
      :Skip: CAP register could not be read

   c. **test_cap_to** -- Read the Timeout field (CAP.TO) and verify it is
      non-zero; the spec requires controllers to set this field.

      :Pass: CAP.TO > 0 (worst-case ready timeout reported in 500 ms units)
      :Fail: CAP.TO = 0 (spec violation)
      :Skip: CAP register could not be read

   d. **test_cap_crms** -- Read the Controller Ready Modes Supported field
      (CAP.CRMS) and check that CRWMS (Controller Ready With Media Supported)
      is set.

      :Pass: CAP.CRWMS = 1
      :Warn: CAP.CRWMS = 0 (NVMe 2.0+ spec says it shall be 1)
      :Skip: NVMe version below 2.0, or CAP register could not be read

6. **Controller Ready Timeouts (NVMe 2.0+)**

   a. **test_crto** -- Read the CRTO register and extract CRWMT (Controller
      Ready With Media Timeout) and CRIMT (Controller Ready Independent of
      Media Timeout), both in 500 ms units.

      :Pass: CRWMT > 0 (timeouts reported)
      :Warn: CRWMT = 0 (expected non-zero)
      :Skip: NVMe version below 2.0, or CRTO register not found

7. **Version Register**

   a. **test_vs_matches_id_ctrl** -- Compare the Version register (VS) from
      ``show-regs`` with the VER field from Identify Controller.

      :Pass: VS register value matches id-ctrl VER
      :Warn: VS and VER values do not match
      :Skip: VS register or id-ctrl VER could not be read

8. **Summary**

   - Report total PASS / FAIL / SKIP / WARN counts
   - Exit with non-zero status if any FAIL

Result Codes
------------

- **PASS** -- check succeeded, device conforms to spec
- **FAIL** -- device non-compliance with NVMe specification
- **SKIP** -- test not applicable (version gate, missing feature)
- **WARN** -- advisory condition, not a hard failure
