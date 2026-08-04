Suite 18: I/O
=============

**Script:** ``nvme_io_test/nvme_io_verify.sh``
**Category:** Destructive
**NVMe Command:** ``nvme write``, ``nvme read``, ``nvme compare``, ``nvme write-zeroes``, ``nvme dsm``, ``nvme flush``

Overview
--------

This suite validates NVMe NVM Command Set I/O operations including sequential and offset write+read, the Compare command, Write Zeroes, Dataset Management (Trim/Deallocate), Flush, and Maximum Data Transfer Size (MDTS) boundary behavior. It verifies that basic data path operations produce correct results, optional I/O commands work when supported, and the controller correctly handles transfers at and beyond the MDTS limit. Multi-namespace I/O is also tested when more than one namespace exists.

Prerequisites
-------------

- Root privileges (``sudo``)
- ``nvme-cli`` installed
- NVMe device (e.g., ``/dev/nvme0``)
- ``--allow-destructive`` flag required
- Non-OS NVMe device (OS drive is always refused)
- At least one namespace must be present

Test Steps
----------

1. **Preflight & Setup**

   - Verify root privileges and ``nvme-cli`` availability
   - Resolve target controller and namespace devices
   - Perform OS drive safety check (``safe_device_check``)
   - Cache Identify Controller data (``nvme id-ctrl``)
   - Detect namespace block size from Identify Namespace (``flbas`` / ``lbads``)
   - Initialize logging

2. **Basic Read/Write**

   a. **test_sequential_write_read** -- Write random data at LBA 0 and read it back to verify data integrity.

      :Command: ``nvme write /dev/nvmeXnY --start-block=0 --block-count=0`` / ``nvme read``
      :Pass: read-back data matches written data
      :Fail: data mismatch

   b. **test_offset_write_read** -- Write random data at LBA 1024 and read it back to verify offset I/O.

      :Command: ``nvme write /dev/nvmeXnY --start-block=1024 --block-count=0`` / ``nvme read``
      :Pass: read-back data matches written data
      :Fail: data mismatch

3. **Optional I/O Commands**

   a. **test_compare** -- Write data to LBA 2, then use the Compare command to verify on-media data matches.

      :Command: ``nvme compare /dev/nvmeXnY --start-block=2 --block-count=0``
      :Pass: compare reports data matches
      :Fail: comparison failed
      :Skip: ONCS bit 0 = 0 (Compare not supported)

   b. **test_write_zeroes** -- Issue Write Zeroes at LBA 4 and verify the block reads back as all zeros.

      :Command: ``nvme write-zeroes /dev/nvmeXnY --start-block=4 --block-count=0``
      :Pass: LBA 4 reads back as all zeros
      :Fail: command failed
      :Warn: read-back not all zeros (may be deallocated pattern)
      :Skip: ONCS bit 3 = 0 (Write Zeroes not supported)

   c. **test_dsm_trim** -- Issue Dataset Management deallocate (Trim) on LBA 8 and verify the command is accepted.

      :Command: ``nvme dsm /dev/nvmeXnY --ad --slbs=8 --blocks=1``
      :Pass: deallocate command accepted
      :Fail: command failed
      :Skip: ONCS bit 2 = 0 (DSM not supported)

4. **Flush**

   a. **test_flush** -- Issue a Flush command to the namespace and verify it completes without error.

      :Command: ``nvme flush /dev/nvmeXnY``
      :Pass: flush completed without error
      :Fail: flush returned error

5. **Transfer Size Boundary**

   a. **test_mdts_boundary** -- Write+read at the maximum data transfer size (MDTS) boundary, capped by sysfs max_hw_sectors_kb.

      :Command: ``nvme write`` / ``nvme read`` with block count = MDTS / block_size
      :Pass: write+read at max transfer size succeeds with data match
      :Fail: data mismatch at max transfer size
      :Skip: MDTS = 0 (no limit) or calculated block count out of range

   b. **test_exceed_mdts** -- Attempt a write exceeding MDTS and verify the controller or driver rejects it.

      :Command: ``nvme write /dev/nvmeXnY --block-count=<MDTS+1 blocks>``
      :Pass: over-sized transfer correctly rejected
      :Warn: transfer accepted (driver may split)
      :Skip: MDTS = 0 (no limit) or over-sized transfer too large

6. **Multi-namespace**

   a. **test_multi_ns_io** -- Write+read on namespace 2 to verify I/O works across multiple namespaces.

      :Command: ``nvme write`` / ``nvme read`` on ``/dev/nvmeXn2``
      :Pass: write+read on second namespace succeeds
      :Fail: data mismatch on second namespace
      :Skip: only 1 namespace (NN <= 1) or namespace 2 device not present

7. **Summary**

   - Report total PASS / FAIL / SKIP / WARN counts
   - Exit with non-zero status if any FAIL

Result Codes
------------

- **PASS** -- check succeeded, device conforms to spec
- **FAIL** -- device non-compliance with NVMe specification
- **SKIP** -- test not applicable (optional command not supported, MDTS not set, single namespace)
- **WARN** -- advisory condition, not a hard failure (e.g., driver splitting over-sized transfers)
