Suite 24: Firmware Management
=============================

**Script:** ``nvme_fw_mgmt_test/nvme_fw_mgmt_verify.sh``
**Category:** Destructive
**NVMe Commands:** ``nvme fw-log``, ``nvme fw-commit``, ``nvme fw-download``

Overview
--------

Validates NVMe firmware management commands by reading firmware slot information,
exercising safe behavioral tests (re-committing the already-active slot, verifying
slot stability), probing error cases (invalid slot zero, activate without download,
download from ``/dev/zero``), and confirming the controller remains accessible
afterward. The suite skips entirely if OACS bit 2 is 0, indicating the controller
does not support firmware commands.

Prerequisites
-------------

- Root privileges (``sudo``)
- ``nvme-cli`` installed
- NVMe device (e.g., ``/dev/nvme0``)
- ``--allow-destructive`` flag required (``--controller-reset`` in ``run_all.sh``)
- Non-OS NVMe device (OS drive is always refused)
- Controller must support firmware commands (OACS bit 2 = 1)
- **Warning**: Firmware commit can trigger a controller reset and PCI bus re-enumeration

Test Steps
----------

1. **Preflight & Setup**

   - Verify root privileges and ``nvme-cli`` availability
   - Resolve target controller device
   - Perform OS drive safety check (``safe_device_check``)
   - Cache Identify Controller data (``nvme id-ctrl``)
   - Check OACS bit 2; skip entire suite if firmware commands are not supported
   - Initialize logging

2. **Read Firmware State**

   a. **Read Firmware Slot Info** -- reads the firmware log page and extracts the Active Firmware Info (AFI) field to determine the currently active firmware slot.

      :Command: ``nvme fw-log /dev/nvmeX``
      :Pass: AFI field found and active slot identified
      :Fail: AFI field not found in fw-log output

3. **Behavioral: Re-commit Active Slot**

   a. **Re-commit Active Firmware Slot** -- performs a fw-commit with action=2 (set active) targeting the already-active slot, which should be a safe no-op.

      :Command: ``nvme fw-commit /dev/nvmeX -s <active_slot> -a 2``
      :Pass: command succeeds or indicates needs-reset
      :Skip: active slot unknown
      :Warn: command returns an error

   b. **Verify Active Slot Unchanged** -- re-reads the firmware log to confirm the active slot did not change after the re-commit operation.

      :Command: ``nvme fw-log /dev/nvmeX`` (via ``get_active_slot`` helper)
      :Pass: active slot matches saved value
      :Fail: active slot changed after fw-commit
      :Skip: no saved active slot state
      :Warn: could not read current active slot

4. **Firmware Slot Revisions**

   a. **Firmware Slot Revision Strings** -- scans slots 1 through 7 in the firmware log for non-empty firmware revision strings (frs1..frs7).

      :Command: ``nvme fw-log /dev/nvmeX``
      :Pass: at least one slot has a non-empty revision string, or revision fields are present
      :Fail: no firmware revision strings found in any slot

5. **Error Case Validation**

   a. **fw-commit Invalid Slot Zero** -- attempts fw-commit with slot=0 and action=2, which is invalid for set-active; expects rejection.

      :Command: ``nvme fw-commit /dev/nvmeX -s 0 -a 2``
      :Pass: command rejected with invalid/error status
      :Warn: slot 0 accepted (spec says slot 0 means controller-chosen)

   b. **fw-commit Activate Without Download** -- attempts to activate a non-active slot (action=1) without first downloading a firmware image; expects rejection.

      :Command: ``nvme fw-commit /dev/nvmeX -s <alt_slot> -a 1``
      :Pass: command correctly rejected (no image, invalid firmware)
      :Skip: active slot unknown
      :Warn: unexpected response

   c. **fw-download /dev/zero Payload** -- downloads a 4096-byte zeroed payload from ``/dev/zero`` to exercise the firmware download command path.

      :Command: ``nvme fw-download /dev/nvmeX -f /dev/zero --xfer=4096``
      :Pass: command accepted (path exercised) or rejected (invalid firmware image -- both are valid)

6. **Post-Test Recovery**

   a. **Controller Accessible** -- runs ``id-ctrl`` to confirm the controller is still operational after firmware management tests.

      :Command: ``nvme id-ctrl /dev/nvmeX``
      :Pass: model name field present in id-ctrl output
      :Fail: id-ctrl failed after firmware management tests

7. **Summary**

   - Report total PASS / FAIL / SKIP / WARN counts
   - Exit with non-zero status if any FAIL

Result Codes
------------

- **PASS** -- check succeeded, device conforms to spec
- **FAIL** -- device non-compliance with NVMe specification
- **SKIP** -- test not applicable (OACS bit 2 = 0, active slot unknown)
- **WARN** -- advisory condition, not a hard failure
