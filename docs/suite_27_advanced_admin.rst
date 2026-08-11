Suite 27: Advanced Admin
========================

**Script:** ``nvme_advanced_admin_test/nvme_advanced_admin_verify.sh``
**Category:** Destructive
**NVMe Commands:** ``nvme lockdown``, ``nvme admin-passthru``, ``nvme io-mgmt-recv``, ``nvme io-mgmt-send``, ``nvme virt-mgmt``, ``nvme capacity-mgmt``

Overview
--------

Validates NVMe advanced admin commands: Lockdown (prohibit and restore a command),
I/O Management Receive and Send (FDP/RUH status), Virtualization Management, and
Capacity Management. The Lockdown test performs a full behavioral cycle -- prohibit
Keep Alive via Lockdown, verify the command is rejected, then unlock and confirm
access is restored. A cleanup trap ensures lockdown state is always restored on
exit.

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
   - Register cleanup trap (undoes lockdown on exit if applied)
   - Initialize logging

2. **Lockdown (Behavioral: lock -> verify -> unlock -> verify)**

   a. **Lockdown: Prohibit Keep Alive** -- uses Lockdown to prohibit the Keep Alive command (opcode 0x18), then verifies the command is rejected via admin-passthru, and finally unlocks it.

      :Command: ``nvme lockdown /dev/nvmeX --scp=0 --ofi=0x18 --ifc=0 --prhbt=1``
      :Pass: (lock) command accepted; (verify) Keep Alive correctly returns prohibited error; (unlock) command accepted, lockdown restored
      :Skip: NVMe version < 2.0, or OACS bit 10 = 0 (Lockdown not supported)
      :Warn: lockdown command returns error, or Keep Alive not visibly prohibited

   b. **Lockdown: Verify Unlock Restores Access** -- runs ``id-ctrl`` to confirm the controller is fully accessible after the lockdown unlock cycle.

      :Command: ``nvme id-ctrl /dev/nvmeX``
      :Pass: model name field present (controller accessible)
      :Fail: id-ctrl failed after lockdown unlock
      :Skip: NVMe version < 2.0, or OACS bit 10 = 0

3. **I/O Management**

   a. **I/O Management Receive: RUH Status** -- queries Reclaim Unit Handle status (management operation 1) to probe FDP capability.

      :Command: ``nvme io-mgmt-recv /dev/nvmeXnY -m 1 -l 4096``
      :Pass: RUH Status fields present (FDP capable), or command completed
      :Skip: NVMe version < 2.0, no namespace device, or command not supported
      :Warn: (not used; unsupported responses are SKIPped)

   b. **I/O Management Send: RUH Update** -- issues a Reclaim Unit Handle Update (management operation 1, length 0) to exercise the send path.

      :Command: ``nvme io-mgmt-send /dev/nvmeXnY -m 1 -l 0``
      :Pass: command accepted
      :Skip: NVMe version < 2.0, no namespace device, or command not supported

4. **Virtualization and Capacity Management**

   a. **Virtualization Management** -- queries virtualization management with action=1 (list secondary controllers) to probe SR-IOV capability.

      :Command: ``nvme virt-mgmt /dev/nvmeX -c 0 -r 0 -a 1 -n 0``
      :Pass: query accepted
      :Skip: OACS bit 7 = 0 (not supported), or command returns error

   b. **Capacity Management** -- probes Capacity Management with operation=0 to check whether the controller supports endurance group or NVM set capacity management.

      :Command: ``nvme capacity-mgmt /dev/nvmeX -O 0 -i 0 -l 0 -u 0``
      :Pass: probe accepted
      :Skip: NVMe version < 2.0, or command not supported

5. **Post-Test Recovery**

   a. **Controller Accessible** -- runs ``id-ctrl`` to confirm the controller is operational after all advanced admin tests.

      :Command: ``nvme id-ctrl /dev/nvmeX``
      :Pass: model name field present in id-ctrl output
      :Fail: id-ctrl failed after advanced admin tests

6. **Summary**

   - Report total PASS / FAIL / SKIP / WARN counts
   - Exit with non-zero status if any FAIL

Result Codes
------------

- **PASS** -- check succeeded, device conforms to spec
- **FAIL** -- device non-compliance with NVMe specification
- **SKIP** -- test not applicable (version gate, OACS capability bit not set, no namespace)
- **WARN** -- advisory condition, not a hard failure
