Suite 4: Firmware Slot Information Log
======================================

**Script:** ``nvme_fw_log_test/nvme_fw_log_verify.sh``
**Category:** Read-Only
**NVMe Command:** ``nvme fw-log``

Overview
--------

Validates the NVMe Firmware Slot Information Log (NVMe Base Specification,
Revision 2.1, Section 5.1.12, Figure 208). The suite verifies that the Active
Firmware Info (AFI) field is present with a valid active slot, firmware revision
strings are populated, and cross-checks slot data against Identify Controller
FRMW fields for consistency.

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
   - Cache Identify Controller data (``nvme id-ctrl /dev/nvmeX``)
   - Retrieve Firmware Slot Information Log (``nvme fw-log /dev/nvmeX``)
   - Initialize logging

2. **Firmware Log Fields**

   a. **test_fw_log_command** -- Verify the ``nvme fw-log`` command executes and produces output.

      :Command: ``nvme fw-log /dev/nvmeX``
      :Pass: command produces non-empty output
      :Fail: output is empty

   b. **test_afi_present** -- Verify the AFI (Active Firmware Info) field is present.

      :Pass: afi field found in output
      :Fail: afi field not found

   c. **test_afi_active_slot_valid** -- Verify the active firmware slot number (AFI bits [2:0]) is between 1 and 7.

      :Pass: active slot is 1-7
      :Fail: active slot is outside 1-7 range

   d. **test_afi_next_slot_valid** -- Verify the next active slot (AFI bits [6:4]) is valid (0 = not specified, 1-7 = valid slot).

      :Pass: next slot is 0 (use current) or 1-7
      :Fail: next slot is outside 0-7 range

   e. **test_frs1_present** -- Verify FW Revision Slot 1 (frs1) is present, since at least slot 1 must exist.

      :Pass: frs1 field found
      :Fail: frs1 not found

3. **Cross-Checks with Identify Controller**

   a. **test_fw_slots_vs_frmw** -- Verify populated firmware slot count does not exceed FRMW.NOFS from Identify Controller.

      :Pass: populated slots <= FRMW.NOFS
      :Fail: more slots populated than the controller reports supporting
      :Skip: could not read frmw from id-ctrl

   b. **test_active_slot_has_fw** -- Verify the active firmware slot contains a firmware revision string.

      :Pass: active slot has a non-empty firmware revision
      :Fail: active slot is empty or invalid

   c. **test_active_fw_matches_id_ctrl** -- Cross-check the firmware revision in the active slot against the FR field from Identify Controller.

      :Pass: firmware revision from fw-log matches id-ctrl FR
      :Fail: firmware revisions do not match
      :Skip: could not extract firmware strings for comparison

   d. **test_frmw_slot1_readonly** -- Report whether slot 1 is read-only (FRMW.FFSRO bit).

      :Pass: FFSRO bit decoded and reported (informational -- always passes)
      :Skip: could not read frmw from id-ctrl

4. **Summary**

   - Report total PASS / FAIL / SKIP / WARN counts
   - Exit with non-zero status if any FAIL

Result Codes
------------

- **PASS** -- check succeeded, device conforms to spec
- **FAIL** -- device non-compliance with NVMe specification
- **SKIP** -- test not applicable (version gate, missing feature)
- **WARN** -- advisory condition, not a hard failure
