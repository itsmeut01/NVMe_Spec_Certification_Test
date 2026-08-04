Suite 25: Additional I/O
========================

**Script:** ``nvme_additional_io_test/nvme_additional_io_verify.sh``
**Category:** Destructive
**NVMe Commands:** ``nvme verify``, ``nvme write-uncor``, ``nvme copy``, ``nvme get-lba-status``, ``nvme io-passthru``, ``nvme compare``

Overview
--------

Validates NVMe optional I/O commands: Verify, Write Uncorrectable with recovery,
Copy, Get LBA Status, I/O passthrough (raw opcode write/read), and Compare. Each
test saves and restores LBA data to minimize side effects. Feature-gated tests
check ONCS/OACS capability bits and NVMe version before executing.

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
   - Determine logical block size from Identify Namespace (``flbas`` / ``lbaf``)
   - Determine namespace size (``nsze``)
   - Create temporary directory for data files
   - Initialize logging

2. **Verify Command**

   a. **Verify at LBA 0** -- writes a random pattern to LBA 0, issues a Verify command, then reads back and compares to confirm data consistency.

      :Command: ``nvme verify /dev/nvmeXnY --start-block=0 --block-count=0``
      :Pass: write + verify + read-back are all consistent
      :Skip: ONCS bit 7 = 0 (Verify not supported)
      :Warn: read-back mismatch after verify (verify may not guarantee readback)

   b. **Verify at Offset LBA** -- issues a Verify command at an offset LBA (default 1024 or half of NSZE for small namespaces).

      :Command: ``nvme verify /dev/nvmeXnY --start-block=<offset> --block-count=0``
      :Pass: command succeeds without error
      :Fail: command returns an error
      :Skip: ONCS bit 7 = 0

   c. **Verify Invalid LBA** -- issues a Verify at an LBA beyond the namespace size to confirm proper out-of-range rejection.

      :Command: ``nvme verify /dev/nvmeXnY --start-block=<NSZE+100> --block-count=0``
      :Pass: command correctly rejected with LBA_RANGE or invalid error
      :Skip: ONCS bit 7 = 0, or NSZE unknown
      :Warn: unexpected response (no error returned)

3. **Write Uncorrectable + Recovery**

   a. **Write Uncorrectable and Recovery** -- marks an LBA as uncorrectable, verifies that a read returns an unrecoverable error, then writes new data to recover the LBA and confirms the recovery via read-back.

      :Command: ``nvme write-uncor /dev/nvmeXnY --start-block=<lba> --block-count=0``
      :Pass: (uncorrectable) read at marked LBA returns error; (recovery) write + read-back match after overwrite
      :Fail: write-uncor command fails, or LBA cannot be recovered
      :Skip: ONCS bit 1 = 0 (Write Uncorrectable not supported)
      :Warn: read did not report error after write-uncor (controller may auto-correct)

4. **Copy Command**

   a. **Copy Round-Trip** -- writes a random pattern to a source LBA, copies it to a destination LBA, then reads back the destination and compares to the original pattern.

      :Command: ``nvme copy /dev/nvmeXnY --sdlba=<dst> --slbs=<src> --blocks=0``
      :Pass: destination read-back matches source pattern
      :Fail: copy command fails or destination data does not match
      :Skip: ONCS bit 8 = 0 (Copy not supported), or NVMe version < 2.0

5. **Get LBA Status**

   a. **Get LBA Status** -- queries LBA status starting at LBA 0 with action=0.

      :Command: ``nvme get-lba-status /dev/nvmeXnY --start-lba=0 --max-dw=256 --action=0``
      :Pass: command succeeds
      :Skip: OACS bit 9 = 0 (not supported)
      :Warn: command returns an error

   b. **Get LBA Status After Write-Uncor** -- marks an LBA as uncorrectable and then queries its LBA status to observe the reported state, followed by recovery of the marked LBA.

      :Command: ``nvme get-lba-status /dev/nvmeXnY --start-lba=<lba> --max-dw=256 --action=0``
      :Pass: command succeeds after write-uncor
      :Skip: OACS bit 9 = 0, or ONCS bit 1 = 0
      :Warn: command returns an error

6. **I/O Passthrough**

   a. **I/O Passthru Write+Read** -- uses raw I/O passthrough to write (opcode=0x01) a random pattern and read it back (opcode=0x02), then compares the data.

      :Command: ``nvme io-passthru /dev/nvmeXnY --opcode=0x01 ...`` / ``nvme io-passthru /dev/nvmeXnY --opcode=0x02 ...``
      :Pass: write + read round-trip data matches
      :Warn: write or read failed, or data mismatch

7. **Compare Command**

   a. **Compare with Matching Data** -- writes a random pattern and issues a Compare with the same data, expecting success.

      :Command: ``nvme compare /dev/nvmeXnY --start-block=<lba> --block-count=0 --data-size=<bs> --data=<file>``
      :Pass: compare returns success for matching data
      :Fail: compare returns error or MISCOMPARE for matching data
      :Skip: ONCS bit 0 = 0 (Compare not supported)

   b. **Compare with Mismatched Data** -- issues a Compare with different random data, expecting a MISCOMPARE error.

      :Command: ``nvme compare /dev/nvmeXnY --start-block=<lba> --block-count=0 --data-size=<bs> --data=<mismatch_file>``
      :Pass: compare returns MISCOMPARE error for mismatched data
      :Warn: expected MISCOMPARE error not returned

8. **Post-Test Recovery**

   a. **Controller and Namespace Accessible** -- runs ``id-ctrl`` and a read at LBA 0 to confirm both controller and namespace are operational after all I/O tests.

      :Command: ``nvme id-ctrl /dev/nvmeX`` and ``nvme read /dev/nvmeXnY --start-block=0``
      :Pass: controller and namespace both accessible
      :Fail: id-ctrl failed after I/O tests
      :Warn: controller accessible but namespace read failed

9. **Summary**

   - Report total PASS / FAIL / SKIP / WARN counts
   - Exit with non-zero status if any FAIL

Result Codes
------------

- **PASS** -- check succeeded, device conforms to spec
- **FAIL** -- device non-compliance with NVMe specification
- **SKIP** -- test not applicable (ONCS/OACS capability bit not set, version gate)
- **WARN** -- advisory condition, not a hard failure
