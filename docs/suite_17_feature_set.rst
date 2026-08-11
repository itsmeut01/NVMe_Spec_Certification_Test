Suite 17: Set Features
======================

**Script:** ``nvme_feature_set_test/nvme_feature_set_verify.sh``
**Category:** Destructive
**NVMe Command:** ``nvme set-feature``, ``nvme get-feature``

Overview
--------

This suite validates the NVMe Set Features command across 11 Feature Identifiers (FIDs), ensuring that each feature can be saved, modified, behaviorally verified (via I/O or admin commands), and restored. Each FID group follows a save-set-verify-I/O-restore pattern to confirm that feature changes take effect and do not break controller operation. The suite covers mandatory features (Arbitration, Power Management, Temperature Threshold, Error Recovery, Volatile Write Cache, Interrupt Coalescing, Number of Queues, Async Event Configuration) and optional features gated by NVMe version or capability bits (APST, HCTM, Keep Alive Timer).

Prerequisites
-------------

- Root privileges (``sudo``)
- ``nvme-cli`` installed
- NVMe device (e.g., ``/dev/nvme0``)
- ``--allow-destructive`` flag required
- Non-OS NVMe device (OS drive is always refused)

Test Steps
----------

1. **Preflight & Setup**

   - Verify root privileges and ``nvme-cli`` availability
   - Resolve target controller and namespace devices
   - Perform OS drive safety check (``safe_device_check``)
   - Cache Identify Controller data (``nvme id-ctrl``)
   - Check VWC capability bit (``vwc & 0x1``) to gate VWC group
   - Initialize logging

2. **Volatile Write Cache (FID 0x06)**

   Entire group is skipped if Volatile Write Cache is not present (``vwc`` bit 0 = 0).

   a. **test_vwc_save** -- Save the original WCE value from FID 0x06.

      :Command: ``nvme get-feature /dev/nvmeX -f 0x06``
      :Pass: saved value is non-empty
      :Skip: could not read FID 0x06

   b. **test_vwc_disable** -- Set WCE=0 to disable write cache and verify via readback.

      :Command: ``nvme set-feature /dev/nvmeX -f 0x06 -V 0``
      :Pass: readback confirms WCE=0
      :Fail: readback does not confirm WCE=0
      :Skip: no saved value

   c. **test_vwc_io_disabled** -- Perform write+read I/O with cache disabled to confirm data integrity.

      :Command: ``nvme write`` / ``nvme read`` on namespace
      :Pass: write+read data matches
      :Fail: data mismatch
      :Skip: no saved value or no namespace device

   d. **test_vwc_enable** -- Set WCE=1 to enable write cache and verify via readback.

      :Command: ``nvme set-feature /dev/nvmeX -f 0x06 -V 1``
      :Pass: readback confirms WCE=1
      :Fail: readback does not confirm WCE=1
      :Skip: no saved value

   e. **test_vwc_flush_with_cache** -- Perform write+read I/O with cache enabled to confirm data integrity.

      :Command: ``nvme write`` / ``nvme read`` on namespace
      :Pass: write+read data matches
      :Fail: data mismatch
      :Skip: no saved value or no namespace device

   f. **test_vwc_flush_succeeds** -- Issue a flush command and verify it completes without error.

      :Command: ``nvme flush /dev/nvmeXnY``
      :Pass: flush completes without error
      :Fail: flush returns error
      :Skip: no namespace device

   g. **test_vwc_restore** -- Restore the original WCE value and verify via readback.

      :Command: ``nvme set-feature /dev/nvmeX -f 0x06 -V <saved>``
      :Pass: readback matches original value
      :Warn: readback mismatch after restore
      :Skip: no saved value

3. **Temperature Threshold (FID 0x04)**

   a. **test_tmpth_save** -- Save the original temperature threshold from FID 0x04.

      :Command: ``nvme get-feature /dev/nvmeX -f 0x04``
      :Pass: saved value is non-empty
      :Skip: could not read FID 0x04

   b. **test_tmpth_set_below_temp** -- Set threshold below current SMART temperature to trigger a warning condition.

      :Command: ``nvme set-feature /dev/nvmeX -f 0x04 -V <temp-5K>``
      :Pass: readback confirms new threshold
      :Fail: readback mismatch
      :Skip: no saved value or could not read SMART temperature

   c. **test_tmpth_critical_warning** -- Check SMART critical_warning bit 1 (temperature) after lowering threshold.

      :Command: ``nvme smart-log /dev/nvmeX``
      :Pass: critical_warning temperature bit is set
      :Warn: bit not set (controller may batch AER)
      :Skip: no saved value or could not read SMART

   d. **test_tmpth_set_zero** -- Attempt to set threshold to 0 and observe controller behavior.

      :Command: ``nvme set-feature /dev/nvmeX -f 0x04 -V 0``
      :Pass: controller either rejects or accepts threshold=0
      :Skip: no saved value

   e. **test_tmpth_critical_clears** -- Restore a safe threshold and verify critical_warning bit 1 clears.

      :Command: ``nvme set-feature`` + ``nvme smart-log``
      :Pass: critical_warning temperature bit cleared
      :Warn: bit still set (may take time to clear)
      :Skip: no saved value or could not read SMART

   f. **test_tmpth_restore** -- Restore the original temperature threshold and verify via readback.

      :Command: ``nvme set-feature /dev/nvmeX -f 0x04 -V <saved>``
      :Pass: readback matches original value
      :Warn: readback mismatch
      :Skip: no saved value

4. **Power Management (FID 0x02)**

   a. **test_pm_save** -- Save the current power state from FID 0x02.

      :Command: ``nvme get-feature /dev/nvmeX -f 0x02``
      :Pass: saved value is non-empty
      :Skip: could not read FID 0x02

   b. **test_pm_set_ps0** -- Set power state to PS 0 and verify via readback.

      :Command: ``nvme set-feature /dev/nvmeX -f 0x02 -V 0``
      :Pass: readback confirms PS 0
      :Fail: readback mismatch
      :Skip: no saved value

   c. **test_pm_io_ps0** -- Perform write+read I/O in power state 0 to confirm data integrity.

      :Command: ``nvme write`` / ``nvme read`` on namespace
      :Pass: write+read data matches
      :Fail: data mismatch
      :Skip: no saved value or no namespace device

   d. **test_pm_cycle_all** -- Cycle through all operational power states (PS 0 to NPSS), issuing id-ctrl at each.

      :Command: ``nvme set-feature -f 0x02`` + ``nvme id-ctrl`` per state
      :Pass: id-ctrl succeeds in every power state
      :Fail: id-ctrl fails in some power state
      :Skip: no saved value or could not read NPSS

   e. **test_pm_responsive_deepest** -- Set deepest power state (NPSS), wait 1s, then verify controller responds to id-ctrl.

      :Command: ``nvme set-feature -f 0x02 -V <NPSS>`` + ``nvme id-ctrl``
      :Pass: id-ctrl succeeds after deepest PS
      :Fail: id-ctrl fails after deepest PS
      :Skip: no saved value or could not read NPSS

   f. **test_pm_invalid_ps** -- Attempt to set PS beyond NPSS and verify the controller rejects it.

      :Command: ``nvme set-feature /dev/nvmeX -f 0x02 -V <NPSS+1>``
      :Pass: invalid PS correctly rejected
      :Warn: PS accepted (controller may clamp)
      :Skip: no saved value or could not read NPSS

   g. **test_pm_restore** -- Restore the original power state and verify via readback.

      :Command: ``nvme set-feature /dev/nvmeX -f 0x02 -V <saved>``
      :Pass: readback matches original value
      :Warn: readback mismatch
      :Skip: no saved value

5. **Error Recovery (FID 0x05)**

   a. **test_err_save** -- Save the current TLER (Time Limited Error Recovery) value from FID 0x05.

      :Command: ``nvme get-feature /dev/nvmeX -f 0x05``
      :Pass: saved value is non-empty
      :Skip: could not read FID 0x05

   b. **test_err_set_value** -- Set TLER to 50 (5000 ms) and verify via readback.

      :Command: ``nvme set-feature /dev/nvmeX -f 0x05 -V 50``
      :Pass: readback confirms TLER=50
      :Warn: readback mismatch (controller may not support)
      :Skip: no saved value

   c. **test_err_set_zero** -- Set TLER to 0 (unlimited) and verify via readback.

      :Command: ``nvme set-feature /dev/nvmeX -f 0x05 -V 0``
      :Pass: readback confirms TLER=0
      :Warn: readback mismatch
      :Skip: no saved value

   d. **test_err_restore** -- Restore the original TLER value and verify via readback.

      :Command: ``nvme set-feature /dev/nvmeX -f 0x05 -V <saved>``
      :Pass: readback matches original value
      :Warn: readback mismatch
      :Skip: no saved value

6. **Arbitration (FID 0x01)**

   a. **test_arb_save** -- Save the current arbitration value from FID 0x01.

      :Command: ``nvme get-feature /dev/nvmeX -f 0x01``
      :Pass: saved value is non-empty
      :Skip: could not read FID 0x01

   b. **test_arb_set_value** -- Set arbitration to HPW=7, LPW=3 and verify readback.

      :Command: ``nvme set-feature /dev/nvmeX -f 0x01 -V <value>``
      :Pass: readback is non-empty
      :Warn: could not read back
      :Skip: no saved value

   c. **test_arb_io_after** -- Perform write+read I/O under the new arbitration settings.

      :Command: ``nvme write`` / ``nvme read`` on namespace
      :Pass: write+read data matches
      :Fail: data mismatch
      :Skip: no saved value or no namespace device

   d. **test_arb_restore** -- Restore the original arbitration value and verify via readback.

      :Command: ``nvme set-feature /dev/nvmeX -f 0x01 -V <saved>``
      :Pass: readback matches original value
      :Warn: readback mismatch
      :Skip: no saved value

7. **APST (FID 0x0C, NVMe 1.3+)**

   Entire group is skipped if NVMe version < 1.3 or APSTA bit is not set.

   a. **test_apst_save** -- Save the current APSTE value from FID 0x0C.

      :Command: ``nvme get-feature /dev/nvmeX -f 0x0c``
      :Pass: saved value is non-empty
      :Skip: APSTA not supported, NVMe < 1.3, or could not read FID 0x0C

   b. **test_apst_enable** -- Enable Autonomous Power State Transitions (APSTE=1) and verify readback.

      :Command: ``nvme set-feature /dev/nvmeX -f 0x0c -V 1``
      :Pass: readback confirms APSTE=1
      :Warn: readback mismatch
      :Skip: not supported or no saved value

   c. **test_apst_responsive** -- Verify controller responds to id-ctrl and I/O succeeds with APST enabled.

      :Command: ``nvme id-ctrl`` + ``nvme write`` / ``nvme read``
      :Pass: id-ctrl and I/O succeed with APST enabled
      :Fail: id-ctrl or I/O fails
      :Skip: not supported or no saved value

   d. **test_apst_disable** -- Disable APST (APSTE=0) and verify readback.

      :Command: ``nvme set-feature /dev/nvmeX -f 0x0c -V 0``
      :Pass: readback confirms APSTE=0
      :Warn: readback mismatch
      :Skip: not supported or no saved value

   e. **test_apst_restore** -- Restore the original APSTE value and verify via readback.

      :Command: ``nvme set-feature /dev/nvmeX -f 0x0c -V <saved>``
      :Pass: readback matches original value
      :Warn: readback mismatch
      :Skip: not supported or no saved value

8. **HCTM (FID 0x10, NVMe 1.3+)**

   Entire group is skipped if NVMe version < 1.3 or HCTMA bit is not set.

   a. **test_hctm_save** -- Save the current Thermal Management Temperature (TMT) from FID 0x10.

      :Command: ``nvme get-feature /dev/nvmeX -f 0x10``
      :Pass: saved value is non-empty
      :Skip: HCTMA not supported, NVMe < 1.3, or could not read FID 0x10

   b. **test_hctm_set_range** -- Set TMT1 and TMT2 within valid range using controller-reported MNTMT/MXTMT values and verify readback.

      :Command: ``nvme set-feature /dev/nvmeX -f 0x10 -V <(TMT1<<16)|TMT2>``
      :Pass: readback confirms set values
      :Warn: readback mismatch
      :Skip: not supported or no saved value

   c. **test_hctm_smart_temp** -- Read SMART temperature while HCTM is active.

      :Command: ``nvme smart-log /dev/nvmeX``
      :Pass: temperature value read successfully
      :Skip: not supported, no saved value, or could not read temperature

   d. **test_hctm_invalid_order** -- Attempt to set TMT2 > TMT1 (invalid order) and verify the controller rejects it.

      :Command: ``nvme set-feature /dev/nvmeX -f 0x10 -V <(300<<16)|350>``
      :Pass: invalid TMT order rejected
      :Warn: controller accepted invalid order (may clamp)
      :Skip: not supported or no saved value

   e. **test_hctm_set_zero** -- Set both TMT1 and TMT2 to 0 (disable HCTM) and verify readback.

      :Command: ``nvme set-feature /dev/nvmeX -f 0x10 -V 0``
      :Pass: readback confirms TMT=0
      :Warn: readback mismatch
      :Skip: not supported or no saved value

   f. **test_hctm_restore** -- Restore the original TMT value and verify via readback.

      :Command: ``nvme set-feature /dev/nvmeX -f 0x10 -V <saved>``
      :Pass: readback matches original value
      :Warn: readback mismatch
      :Skip: not supported or no saved value

9. **Interrupt Coalescing (FID 0x08)**

   a. **test_intc_save** -- Save the current interrupt coalescing value from FID 0x08.

      :Command: ``nvme get-feature /dev/nvmeX -f 0x08``
      :Pass: saved value is non-empty
      :Skip: could not read FID 0x08

   b. **test_intc_set_value** -- Set interrupt coalescing to TIME=10, THR=4 and verify readback.

      :Command: ``nvme set-feature /dev/nvmeX -f 0x08 -V <(10<<8)|4>``
      :Pass: readback is non-empty
      :Warn: could not read back
      :Skip: no saved value

   c. **test_intc_io_after** -- Perform write+read I/O under new coalescing settings.

      :Command: ``nvme write`` / ``nvme read`` on namespace
      :Pass: write+read data matches
      :Fail: data mismatch
      :Skip: no saved value or no namespace device

   d. **test_intc_restore** -- Restore the original coalescing value and verify via readback.

      :Command: ``nvme set-feature /dev/nvmeX -f 0x08 -V <saved>``
      :Pass: readback matches original value
      :Warn: readback mismatch
      :Skip: no saved value

10. **Number of Queues (FID 0x07)**

    a. **test_nq_save** -- Save the current NSQA/NCQA value from FID 0x07.

       :Command: ``nvme get-feature /dev/nvmeX -f 0x07``
       :Pass: saved value is non-empty
       :Skip: could not read FID 0x07

    b. **test_nq_set_value** -- Set NSQA=4, NCQA=4 and verify readback reports allocated queues.

       :Command: ``nvme set-feature /dev/nvmeX -f 0x07 -V <(3<<16)|3>``
       :Pass: readback shows allocated queue counts
       :Warn: could not read back
       :Skip: no saved value

    c. **test_nq_io_after** -- Perform write+read I/O with the new queue allocation.

       :Command: ``nvme write`` / ``nvme read`` on namespace
       :Pass: write+read data matches
       :Fail: data mismatch
       :Skip: no saved value or no namespace device

    d. **test_nq_restore** -- Restore the original queue settings and verify readback.

       :Command: ``nvme set-feature /dev/nvmeX -f 0x07 -V <saved>``
       :Pass: readback is non-empty
       :Warn: could not read back
       :Skip: no saved value

11. **Async Event Configuration (FID 0x0B)**

    a. **test_aec_save** -- Save the current async event configuration from FID 0x0B.

       :Command: ``nvme get-feature /dev/nvmeX -f 0x0b``
       :Pass: saved value is non-empty
       :Skip: could not read FID 0x0B

    b. **test_aec_set_smart_events** -- Enable all SMART critical warning events (bits 4:0 = 0x1F) and verify readback.

       :Command: ``nvme set-feature /dev/nvmeX -f 0x0b -V 0x1F``
       :Pass: readback shows all SMART events enabled or controller-masked subset
       :Warn: could not read back
       :Skip: no saved value

    c. **test_aec_set_minimal** -- Set AEC to 0 (disable optional events) and verify readback.

       :Command: ``nvme set-feature /dev/nvmeX -f 0x0b -V 0``
       :Pass: readback is non-empty
       :Warn: could not read back
       :Skip: no saved value

    d. **test_aec_restore** -- Restore the original AEC value and verify via readback.

       :Command: ``nvme set-feature /dev/nvmeX -f 0x0b -V <saved>``
       :Pass: readback matches original value
       :Warn: readback mismatch
       :Skip: no saved value

12. **Keep Alive Timer (FID 0x0F)**

    Entire group is skipped if Keep Alive is not supported (KAS = 0 in Identify Controller).

    a. **test_kat_save** -- Save the current KATO value from FID 0x0F.

       :Command: ``nvme get-feature /dev/nvmeX -f 0x0f``
       :Pass: saved value is non-empty
       :Skip: KAS=0 (not supported) or could not read FID 0x0F

    b. **test_kat_set_value** -- Set KATO to 30000 ms and verify readback.

       :Command: ``nvme set-feature /dev/nvmeX -f 0x0f -V 30000``
       :Pass: readback shows value in ms
       :Warn: could not read back
       :Skip: no saved value

    c. **test_kat_set_zero** -- Set KATO to 0 (disabled) and verify readback.

       :Command: ``nvme set-feature /dev/nvmeX -f 0x0f -V 0``
       :Pass: readback shows 0
       :Warn: could not read back
       :Skip: no saved value

    d. **test_kat_restore** -- Restore the original KATO value and verify via readback.

       :Command: ``nvme set-feature /dev/nvmeX -f 0x0f -V <saved>``
       :Pass: readback matches original value
       :Warn: readback mismatch
       :Skip: no saved value

13. **Summary**

    - Report total PASS / FAIL / SKIP / WARN counts
    - Exit with non-zero status if any FAIL

Result Codes
------------

- **PASS** -- check succeeded, device conforms to spec
- **FAIL** -- device non-compliance with NVMe specification
- **SKIP** -- test not applicable (feature not supported, version gate, missing capability)
- **WARN** -- advisory condition, not a hard failure (e.g., readback mismatch on restore, controller may clamp values)
