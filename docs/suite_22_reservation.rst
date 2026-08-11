Suite 22: Reservation
=====================

**Script:** ``nvme_reservation_test/nvme_reservation_verify.sh``
**Category:** Destructive
**NVMe Commands:** ``nvme resv-register``, ``nvme resv-acquire``, ``nvme resv-report``, ``nvme resv-release``

Overview
--------

Validates the NVMe Reservation command set by exercising the full reservation
lifecycle: registering a reservation key, acquiring an exclusive reservation,
reporting registration state, releasing the reservation, and confirming that
normal I/O resumes after release. The suite skips entirely if the namespace does
not advertise reservation capability (``rescap=0``) or is a private namespace
(``NMIC`` bit 0 = 0, meaning reservations require a shared namespace).

Prerequisites
-------------

- Root privileges (``sudo``)
- ``nvme-cli`` installed
- NVMe device (e.g., ``/dev/nvme0``)
- ``--allow-destructive`` flag required
- Non-OS NVMe device (OS drive is always refused)
- Namespace must support reservations (``rescap != 0``)
- Namespace must be shared (``NMIC`` bit 0 = 1)

Test Steps
----------

1. **Preflight & Setup**

   - Verify root privileges and ``nvme-cli`` availability
   - Resolve target controller and namespace devices
   - Perform OS drive safety check (``safe_device_check``)
   - Cache Identify Controller data (``nvme id-ctrl``)
   - Read Identify Namespace to check ``rescap`` and ``NMIC`` fields
   - Skip entire suite if reservations are not supported or namespace is private
   - Initialize logging

2. **Reservation Lifecycle**

   a. **Register Reservation Key** -- registers a new reservation key on the namespace using ``resv-register`` with action RREGA=0 (register).

      :Command: ``nvme resv-register /dev/nvmeXnY --rrega=0 --nrkey=0x1234567890abcdef``
      :Pass: command completes without error
      :Fail: command returns an error (other than "not supported")
      :Skip: controller reports reservations not supported

   b. **Acquire Exclusive Reservation** -- acquires an exclusive reservation (rtype=1) using the previously registered key.

      :Command: ``nvme resv-acquire /dev/nvmeXnY --racqa=0 --crkey=0x1234567890abcdef --rtype=1``
      :Pass: command completes without error
      :Warn: command returns an error or status message

   c. **Report Reservations** -- queries the current reservation state and registered controllers on the namespace.

      :Command: ``nvme resv-report /dev/nvmeXnY -s 1``
      :Pass: command completes and registration data (regctl, key, rtype) is visible, or command completes without error
      :Warn: command returns an error or status message

   d. **Release Reservation** -- releases the held reservation and unregisters the key (RRELA=0, then RREGA=1 to unregister).

      :Command: ``nvme resv-release /dev/nvmeXnY --rrela=0 --crkey=0x1234567890abcdef --rtype=1``
      :Pass: command completes without error
      :Warn: command returns an error or status message

   e. **I/O After Reservation Release** -- performs a write+read+compare cycle at LBA 0 to confirm that I/O is functional after all reservation state has been cleared.

      :Command: ``write_read_verify /dev/nvmeXnY 0 1`` (internal helper using ``nvme write`` / ``nvme read``)
      :Pass: write+read data matches
      :Fail: write+read data mismatch

3. **Summary**

   - Report total PASS / FAIL / SKIP / WARN counts
   - Exit with non-zero status if any FAIL

Result Codes
------------

- **PASS** -- check succeeded, device conforms to spec
- **FAIL** -- device non-compliance with NVMe specification
- **SKIP** -- test not applicable (reservations not supported, namespace is private)
- **WARN** -- advisory condition, not a hard failure
