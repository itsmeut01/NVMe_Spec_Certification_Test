Suite 21: Namespace Management
===============================

**Script:** ``nvme_ns_mgmt_test/nvme_ns_mgmt_verify.sh``
**Category:** Destructive
**NVMe Command:** ``nvme create-ns``, ``nvme attach-ns``, ``nvme detach-ns``, ``nvme delete-ns``, ``nvme ns-rescan``, ``nvme list-ns``

Overview
--------

This suite validates the NVMe Namespace Management and Attachment commands by exercising the full namespace lifecycle: create a new namespace, attach it to the controller, perform I/O on it, detach it, and delete it. After the lifecycle test, the suite verifies that the original namespace remains accessible and unaffected. The entire suite is skipped if the controller does not support Namespace Management (OACS bit 3 = 0). A cleanup trap ensures the created namespace is detached and deleted even if the script exits early.

Prerequisites
-------------

- Root privileges (``sudo``)
- ``nvme-cli`` installed
- NVMe device (e.g., ``/dev/nvme0``)
- ``--allow-destructive`` flag required
- Non-OS NVMe device (OS drive is always refused)
- Controller must support Namespace Management (OACS bit 3 = 1)
- Sufficient unallocated NVM capacity (``unvmcap``) for creating a test namespace

Test Steps
----------

1. **Preflight & Setup**

   - Verify root privileges and ``nvme-cli`` availability
   - Resolve target controller and namespace devices
   - Perform OS drive safety check (``safe_device_check``)
   - Cache Identify Controller data (``nvme id-ctrl``)
   - Check Namespace Management support (OACS bit 3); skip entire suite if not supported
   - Read controller ID (``cntlid``) for attach/detach operations
   - Register cleanup trap to detach and delete any created namespace on exit
   - Initialize logging

2. **Namespace Lifecycle**

   a. **test_create_ns** -- Create a new namespace using available unallocated capacity (sized from ``unvmcap``, default 1024 blocks).

      :Command: ``nvme create-ns /dev/nvmeX --nsze=<size> --ncap=<size> --flbas=0 --dps=0 --nmic=0``
      :Pass: namespace created successfully, NSID parsed from output
      :Warn: command returned NVMe status error or could not parse NSID

   b. **test_attach_ns** -- Attach the newly created namespace to the controller and rescan.

      :Command: ``nvme attach-ns /dev/nvmeX --namespace-id=<nsid> --controllers=<cntlid>``
      :Pass: attach command accepted (optionally confirmed via ``nvme list-ns``)
      :Fail: attach command returns error
      :Skip: no namespace was created

   c. **test_io_new_ns** -- Perform write+read I/O on the newly created and attached namespace.

      :Command: ``nvme write`` / ``nvme read`` on ``/dev/nvmeXn<nsid>``
      :Pass: write+read data matches
      :Fail: data mismatch
      :Skip: no namespace was created or device not present in /dev

   d. **test_detach_ns** -- Detach the created namespace from the controller and rescan.

      :Command: ``nvme detach-ns /dev/nvmeX --namespace-id=<nsid> --controllers=<cntlid>``
      :Pass: detach command accepted
      :Warn: command returns error
      :Skip: no namespace was created

   e. **test_delete_ns** -- Delete the created namespace.

      :Command: ``nvme delete-ns /dev/nvmeX --namespace-id=<nsid>``
      :Pass: namespace successfully deleted
      :Warn: command returns error
      :Skip: no namespace was created

3. **Original Namespace**

   a. **test_original_ns_unaffected** -- Verify the original namespace is still accessible after the create/attach/detach/delete lifecycle.

      :Command: ``nvme id-ns /dev/nvmeXnY``
      :Pass: id-ns succeeds and shows ``nsze`` field
      :Fail: id-ns fails on original namespace
      :Skip: no original namespace device

4. **Summary**

   - Report total PASS / FAIL / SKIP / WARN counts
   - Exit with non-zero status if any FAIL

Result Codes
------------

- **PASS** -- check succeeded, device conforms to spec
- **FAIL** -- device non-compliance with NVMe specification
- **SKIP** -- test not applicable (Namespace Management not supported, no unallocated capacity)
- **WARN** -- advisory condition, not a hard failure (e.g., create accepted but NSID not parseable)
