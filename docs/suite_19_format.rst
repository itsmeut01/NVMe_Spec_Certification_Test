Suite 19: Format NVM
====================

**Script:** ``nvme_format_test/nvme_format_verify.sh``
**Category:** Destructive
**NVMe Command:** ``nvme format``

Overview
--------

This suite validates the NVMe Format NVM command, which performs a low-level format of a namespace. It tests formatting with the current LBA format, user data erase (Secure Erase Setting = 1), switching to an alternate LBA format and back, and verifying that I/O operations succeed after formatting. The entire suite is skipped if the controller does not support Format NVM (OACS bit 1 = 0).

Prerequisites
-------------

- Root privileges (``sudo``)
- ``nvme-cli`` installed
- NVMe device (e.g., ``/dev/nvme0``)
- ``--allow-destructive`` flag required
- Non-OS NVMe device (OS drive is always refused)
- At least one namespace must be present
- Controller must support Format NVM (OACS bit 1 = 1)

Test Steps
----------

1. **Preflight & Setup**

   - Verify root privileges and ``nvme-cli`` availability
   - Resolve target controller and namespace devices
   - Perform OS drive safety check (``safe_device_check``)
   - Cache Identify Controller data (``nvme id-ctrl``)
   - Check Format NVM support (OACS bit 1); skip entire suite if not supported
   - Detect current LBAF index and block size from Identify Namespace (``flbas`` / ``lbads``)
   - Initialize logging

2. **Format Operations**

   a. **test_format_current_lbaf** -- Format the namespace with the current LBA format and verify the namespace remains accessible.

      :Command: ``nvme format /dev/nvmeXnY -l <current_lbaf> --force``
      :Pass: namespace accessible after format (id-ns returns flbas)
      :Fail: format returns error, or namespace not accessible after format

   b. **test_format_user_data_erase** -- Format with Secure Erase Setting = 1 (user data erase) and verify LBA 0 reads back as zeros.

      :Command: ``nvme format /dev/nvmeXnY --ses=1 -l <current_lbaf> --force``
      :Pass: LBA 0 reads back as all zeros after SES=1 format
      :Warn: format returns error, or LBA 0 not all zeros (controller may use different erase pattern)

   c. **test_format_alternate_lbaf** -- Format with an alternate LBAF, verify id-ns confirms the new format, then restore original LBAF.

      :Command: ``nvme format /dev/nvmeXnY -l <alt_lbaf> --force``
      :Pass: id-ns confirms new LBAF after format
      :Warn: flbas does not match expected LBAF
      :Skip: only 1 LBA format supported (NLBAF = 0)

3. **Post-Format I/O**

   a. **test_io_after_format** -- Perform write+read I/O at LBA 0 after all format operations to confirm the data path works.

      :Command: ``nvme write`` / ``nvme read`` on namespace
      :Pass: write+read data matches
      :Fail: data mismatch

4. **Summary**

   - Report total PASS / FAIL / SKIP / WARN counts
   - Exit with non-zero status if any FAIL

Result Codes
------------

- **PASS** -- check succeeded, device conforms to spec
- **FAIL** -- device non-compliance with NVMe specification
- **SKIP** -- test not applicable (Format NVM not supported, only one LBAF available)
- **WARN** -- advisory condition, not a hard failure (e.g., controller uses non-zero erase pattern)
