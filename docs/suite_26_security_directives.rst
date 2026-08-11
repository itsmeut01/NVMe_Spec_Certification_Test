Suite 26: Security and Directives
==================================

**Script:** ``nvme_security_directives_test/nvme_security_directives_verify.sh``
**Category:** Destructive
**NVMe Commands:** ``nvme security-recv``, ``nvme dir-receive``, ``nvme dir-send``, ``nvme admin-passthru``

Overview
--------

Validates NVMe Security Receive (read-only probe) and Directives (Streams
enable/disable lifecycle) commands. The Security Receive tests safely query
supported protocol lists without issuing Security Send. The Directives tests
perform a full behavioral cycle: read current state, enable Streams, verify
enabled, query Streams parameters and status, disable Streams, and verify
disabled. An Admin Passthru test round-trips an Identify Controller via raw
opcode. On exit, a cleanup handler restores Streams to the disabled state if
it was enabled during testing.

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
   - Create temporary directory for binary data
   - Register cleanup trap (restores Streams directive on exit)
   - Initialize logging

2. **Security Receive (read-only probe)**

   a. **Security Receive: Supported Protocols** -- issues Security Receive with security protocol 0x00 to query the list of supported security protocols without modifying device state.

      :Command: ``nvme security-recv /dev/nvmeX --secp=0x00 --spsp=0 --size=4096 --al=4096 -b``
      :Pass: returns protocol list data, or command completes with empty response (valid)
      :Skip: OACS bit 0 = 0 (Security not supported)
      :Warn: command returns an error

   b. **Security Receive Response Parseable** -- confirms that the Security Receive response does not crash nvme-cli and produces clean output.

      :Command: ``nvme security-recv /dev/nvmeX --secp=0x00 --spsp=0 --size=4096 --al=4096``
      :Pass: response is parseable with no crash
      :Fail: nvme-cli crashed (segfault or core dump)
      :Skip: OACS bit 0 = 0

3. **Directives: Save Current State**

   a. **Directive Receive: Read Current State** -- reads the current directive state using Directive Receive with Identify directive type (D=0, O=1).

      :Command: ``nvme dir-receive /dev/nvmeXnY -D 0 -O 1 -l 4096``
      :Pass: directive parameters readable
      :Skip: OACS bit 5 = 0 (Directives not supported), or no namespace device
      :Warn: command returns an error

4. **Directives: Enable Streams**

   a. **Directive Send: Enable Streams** -- sends a Directive Send to enable the Streams directive type (D=0, O=1, T=1, e=1).

      :Command: ``nvme dir-send /dev/nvmeXnY -D 0 -O 1 -T 1 -e 1``
      :Pass: command completed without error
      :Skip: OACS bit 5 = 0, or no namespace device
      :Warn: command returns an error (controller may not support Streams)

   b. **Directive Receive: Verify Streams Enabled** -- re-reads directive state to confirm the Streams directive was enabled.

      :Command: ``nvme dir-receive /dev/nvmeXnY -D 0 -O 1 -l 4096``
      :Pass: Streams enabled confirmed, or directive params readable after enable
      :Skip: Streams not enabled, OACS bit 5 = 0, or no namespace device
      :Warn: command returns an error

5. **Directives: Query Streams While Enabled**

   a. **Streams Directive Parameters** -- queries Streams-specific parameters (MSL, NSSA, NSSO) while Streams is enabled.

      :Command: ``nvme dir-receive /dev/nvmeXnY -D 1 -O 1``
      :Pass: MSL/NSSA/NSSO fields present, or command succeeds
      :Skip: Streams not enabled or not supported, or no namespace device
      :Warn: command returns an error

   b. **Streams Directive Status** -- queries Streams status while Streams is enabled.

      :Command: ``nvme dir-receive /dev/nvmeXnY -D 1 -O 2``
      :Pass: status readable while Streams enabled
      :Skip: Streams not enabled or not supported, or no namespace device
      :Warn: command returns an error

6. **Directives: Disable Streams (Restore)**

   a. **Directive Send: Disable Streams** -- sends a Directive Send to disable the Streams directive (D=0, O=1, T=1, e=0), restoring the original state.

      :Command: ``nvme dir-send /dev/nvmeXnY -D 0 -O 1 -T 1 -e 0``
      :Pass: Streams directive disabled (restored)
      :Skip: OACS bit 5 = 0, or no namespace device
      :Warn: command returns an error

   b. **Directive Receive: Verify Streams Disabled** -- re-reads directive state to confirm the Streams directive was successfully disabled.

      :Command: ``nvme dir-receive /dev/nvmeXnY -D 0 -O 1 -l 4096``
      :Pass: state readable after disabling Streams (restore verified)
      :Skip: OACS bit 5 = 0, or no namespace device
      :Warn: command returns an error

7. **Admin Passthru**

   a. **Admin Passthru: Identify Controller** -- issues an Identify Controller command via raw admin passthrough (opcode=0x06) and cross-checks the returned model name against cached id-ctrl data.

      :Command: ``nvme admin-passthru /dev/nvmeX --opcode=0x06 --cdw10=1 --data-len=4096 --read``
      :Pass: returned data contains matching model name, or returned printable data
      :Warn: command returned error, or could not cross-check with id-ctrl

8. **Summary**

   - Report total PASS / FAIL / SKIP / WARN counts
   - Exit with non-zero status if any FAIL

Result Codes
------------

- **PASS** -- check succeeded, device conforms to spec
- **FAIL** -- device non-compliance with NVMe specification
- **SKIP** -- test not applicable (OACS capability bit not set, no namespace device)
- **WARN** -- advisory condition, not a hard failure
