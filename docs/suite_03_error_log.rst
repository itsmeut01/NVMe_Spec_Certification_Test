Suite 3: Error Information Log
==============================

**Script:** ``nvme_error_log_test/nvme_error_log_verify.sh``
**Category:** Read-Only
**NVMe Command:** ``nvme error-log``

Overview
--------

Validates the NVMe Error Information Log structure and per-entry fields
(NVMe Base Specification, Revision 2.1, Section 5.1.12, Figure 205). The
suite checks that the error-log command succeeds, entries conform to the
expected structure, per-entry fields are present, error counts are
monotonically ordered, and SMART error counters are consistent with the
log contents.

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
   - Retrieve Error Information Log (``nvme error-log /dev/nvmeX``)
   - Initialize logging

2. **Log Structure**

   a. **test_error_log_command** -- Verify the ``nvme error-log`` command executes and produces output.

      :Command: ``nvme error-log /dev/nvmeX``
      :Pass: command produces non-empty output
      :Fail: output is empty

   b. **test_entry_structure** -- Verify the log contains parseable entry structures.

      :Pass: one or more ``Entry[N]`` headers found, or log is empty (no errors recorded -- valid state)
      :Fail: (always passes; empty log is acceptable)

   c. **test_entry_count_within_elpe** -- Verify entry count does not exceed ELPE+1 from Identify Controller.

      :Pass: entry count <= ELPE + 1
      :Fail: more entries than ELPE allows
      :Skip: could not read ELPE from id-ctrl

3. **Per-Entry Fields (checked on first entry)**

   a. **test_error_count** -- Verify error_count field is present in the first entry.

      :Pass: error_count field found
      :Fail: error_count not found
      :Skip: no error entries to validate

   b. **test_sqid** -- Verify Submission Queue ID field is present.

      :Pass: sqid field found
      :Fail: sqid not found
      :Skip: no error entries to validate

   c. **test_cmdid** -- Verify Command ID field is present.

      :Pass: cmdid field found
      :Fail: cmdid not found
      :Skip: no error entries to validate

   d. **test_status_field** -- Verify status_field is present.

      :Pass: status_field found
      :Fail: status_field not found
      :Skip: no error entries to validate

   e. **test_phase_tag** -- Verify phase_tag field is present.

      :Pass: phase_tag found
      :Fail: phase_tag not found
      :Skip: no error entries to validate

   f. **test_parm_err_loc** -- Verify Parameter Error Location field is present.

      :Pass: parm_err_loc found
      :Fail: parm_err_loc not found
      :Skip: no error entries to validate

   g. **test_lba** -- Verify Logical Block Address field is present.

      :Pass: lba field found
      :Fail: lba not found
      :Skip: no error entries to validate

   h. **test_nsid** -- Verify Namespace ID field is present.

      :Pass: nsid field found
      :Fail: nsid not found
      :Skip: no error entries to validate

   i. **test_vs** -- Verify Vendor Specific field is present.

      :Pass: vs field found
      :Fail: vs not found
      :Skip: no error entries to validate

   j. **test_trtype** -- Verify Transport Type field is present.

      :Pass: trtype field found
      :Fail: trtype not found
      :Skip: controller is pre-NVMe 1.4, or no error entries

   k. **test_csi** -- Verify Command Set Identifier field is present.

      :Pass: csi field found
      :Fail: csi not found
      :Skip: controller is pre-NVMe 2.0, or no error entries

   l. **test_opcode** -- Verify opcode field is present.

      :Pass: opcode field found
      :Fail: opcode not found
      :Skip: controller is pre-NVMe 2.0, or no error entries

   m. **test_cs** -- Verify Command Specific field is present.

      :Pass: cs field found
      :Fail: cs not found
      :Skip: controller is pre-NVMe 2.0, or no error entries

   n. **test_trtype_spec_info** -- Verify Transport Specific Info field is present.

      :Pass: trtype_spec_info field found
      :Fail: trtype_spec_info not found
      :Skip: controller is pre-NVMe 2.0, or no error entries

   o. **test_log_page_version** -- Verify log_page_version field is present.

      :Pass: log_page_version field found
      :Fail: log_page_version not found
      :Skip: controller is pre-NVMe 2.0, or no error entries

4. **Ordering Checks**

   a. **test_error_count_ordering** -- Verify error_count values across entries are monotonically descending.

      :Pass: error_count values decrease from Entry[0] onward
      :Fail: values not in expected descending order
      :Skip: fewer than 2 entries

5. **Deep Validation**

   a. **test_status_field_decode** -- Decode status_field into Status Code Type (SCT) and Status Code (SC).

      :Pass: SCT and SC successfully decoded
      :Skip: no error entries, or status_field not extractable

   b. **test_all_errors_zero_note** -- Summarize whether all entries have error_count = 0 or report non-zero counts.

      :Pass: clean state (no entries), all error_count = 0, or non-zero counts reported

   c. **test_error_count_nonzero_entries** -- Cross-check SMART num_err_log_entries against error-log entry count.

      :Command: ``nvme smart-log /dev/nvmeX``
      :Pass: SMART and error-log counts are consistent
      :Warn: SMART reports 0 errors but error-log has entries
      :Skip: could not read SMART log

6. **Summary**

   - Report total PASS / FAIL / SKIP / WARN counts
   - Exit with non-zero status if any FAIL

Result Codes
------------

- **PASS** -- check succeeded, device conforms to spec
- **FAIL** -- device non-compliance with NVMe specification
- **SKIP** -- test not applicable (version gate, missing feature)
- **WARN** -- advisory condition, not a hard failure
