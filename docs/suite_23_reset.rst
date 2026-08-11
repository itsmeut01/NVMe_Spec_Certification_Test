Suite 23: Reset
===============

**Script:** ``nvme_reset_test/nvme_reset_verify.sh``
**Category:** Destructive
**NVMe Commands:** ``nvme reset``, ``nvme subsystem-reset``, ``nvme show-regs``, ``nvme get-feature``, ``nvme smart-log``

Overview
--------

Validates NVMe controller reset and subsystem reset behavior. The suite issues
a controller reset, then verifies that the device re-enumerates, that Identify
Controller data is intact, and that I/O resumes. It also inspects post-reset
register state (CSTS.RDY, CSTS.CFS, CC.EN), checks whether features persist,
confirms SMART log availability, and exercises subsystem reset with post-reset
identification.

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
   - Record pre-reset model name (``mn``), serial number (``sn``), and Number of Queues feature (FID 0x07)
   - Initialize logging

2. **Controller Reset**

   a. **Controller Reset** -- issues ``nvme reset`` and waits up to 20 seconds for the device to reappear (with PCI rescan fallback).

      :Command: ``nvme reset /dev/nvmeX``
      :Pass: device node exists after reset
      :Fail: command fails or device not found within timeout

   b. **Post-Reset Identify** -- runs ``nvme id-ctrl`` (with up to 3 retries) and compares model name and serial number against pre-reset values.

      :Command: ``nvme id-ctrl /dev/nvmeX``
      :Pass: model name and serial number match pre-reset values
      :Fail: ``id-ctrl`` command fails after reset
      :Warn: model or serial changed (may be expected on some controllers)

   c. **Post-Reset I/O** -- performs a write+read+compare cycle on the first namespace to confirm data-path recovery after reset.

      :Command: ``write_read_verify /dev/nvmeXnY 0 1``
      :Pass: write+read data matches after controller reset
      :Fail: namespace not present after reset, or data mismatch
      :Skip: no namespace device available

3. **Post-Reset State Verification**

   a. **Post-Reset Register State** -- reads controller registers and validates CSTS.RDY=1, CSTS.CFS=0, and CC.EN=1, confirming the controller is enabled and ready with no fatal status.

      :Command: ``nvme show-regs /dev/nvmeX -H``
      :Pass: CSTS.RDY=1, CSTS.CFS=0, CC.EN=1
      :Fail: any of CSTS.RDY!=1, CSTS.CFS!=0, or CC.EN!=1
      :Skip: registers could not be read

   b. **Post-Reset Feature Persistence (FID 0x07)** -- reads Number of Queues feature after reset and compares with the pre-reset value to observe whether feature state persists across reset.

      :Command: ``nvme get-feature /dev/nvmeX -f 0x07``
      :Pass: feature value readable (reports NSQA/NCQA counts; notes if value changed from pre-reset)
      :Warn: could not read Number of Queues after reset

   c. **Post-Reset SMART Log** -- reads the SMART/Health log after reset and checks that temperature, available_spare, and critical_warning fields are present.

      :Command: ``nvme smart-log /dev/nvmeX``
      :Pass: temperature, available_spare, and critical_warning fields all present
      :Fail: smart-log returned empty output
      :Warn: some expected fields missing

4. **Subsystem Reset**

   a. **Subsystem Reset** -- issues ``nvme subsystem-reset`` and waits up to 30 seconds for the device to recover, then runs ``id-ctrl`` (with up to 4 retries).

      :Command: ``nvme subsystem-reset /dev/nvmeX``
      :Pass: ``id-ctrl`` succeeds after subsystem reset
      :Fail: ``id-ctrl`` fails after subsystem reset
      :Warn: subsystem-reset command itself returned an error

5. **Summary**

   - Report total PASS / FAIL / SKIP / WARN counts
   - Exit with non-zero status if any FAIL

Result Codes
------------

- **PASS** -- check succeeded, device conforms to spec
- **FAIL** -- device non-compliance with NVMe specification
- **SKIP** -- test not applicable (no namespace device)
- **WARN** -- advisory condition, not a hard failure
