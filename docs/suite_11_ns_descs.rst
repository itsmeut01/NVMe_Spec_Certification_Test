Suite 11: Namespace Identification Descriptors
===============================================

**Script:** ``nvme_ns_descs_test/nvme_ns_descs_verify.sh``
**Category:** Read-Only
**NVMe Command:** ``nvme ns-descs``

Overview
--------

Validates the Namespace Identification Descriptor list returned by the controller
for a given namespace. The suite checks that the ``nvme ns-descs`` command succeeds,
verifies the presence and format of EUI-64, NGUID, and UUID descriptors, confirms
at least one non-zero identifier exists, validates the Command Set Identifier (CSI)
descriptor on NVMe 2.0+ devices, and checks that descriptor lengths conform to the
NVMe Base Specification.

Prerequisites
-------------

- Root privileges (``sudo``)
- ``nvme-cli`` installed
- NVMe namespace device (e.g., ``/dev/nvme0n1``)

Test Steps
----------

1. **Preflight & Setup**

   - Verify root privileges and ``nvme-cli`` availability
   - Resolve target controller device (auto-detect or user-specified)
   - Derive namespace device (append ``n1`` if controller-only path given)
   - Cache Identify Controller data (``nvme id-ctrl``)
   - Initialize logging

2. **Command Access**

   a. **test_ns_descs_command** -- verify that ``nvme ns-descs`` executes and returns output.

      :Command: ``nvme ns-descs /dev/nvmeXnY``
      :Pass: command returns non-empty output without error indicators
      :Fail: command returns empty output
      :Skip: output contains "invalid", "not support", or "unknown opcode"

3. **Descriptor Presence**

   a. **test_eui64_present** -- check whether the EUI-64 descriptor is present and extract its value.

      :Command: parses ``nvme ns-descs`` output for ``eui64``
      :Pass: EUI-64 present with a parseable 16-hex-digit value, or not present (optional per spec)

   b. **test_nguid_present** -- check whether the NGUID descriptor is present and extract its value.

      :Command: parses ``nvme ns-descs`` output for ``nguid``
      :Pass: NGUID present with a parseable 32-hex-digit value, or not present (optional per spec)

   c. **test_uuid_present** -- check whether the UUID descriptor is present and extract its value.

      :Command: parses ``nvme ns-descs`` output for ``uuid``
      :Pass: UUID present with a parseable 36-character UUID, or not present (optional per spec)

4. **Cross-Validation**

   a. **test_at_least_one_id** -- confirm at least one non-zero namespace identifier (EUI-64, NGUID, or UUID) exists.

      :Command: parses all three descriptor values from ``nvme ns-descs`` output
      :Pass: at least one descriptor has a non-zero value
      :Warn: all descriptors are zero or absent

   b. **test_csi_nvm** -- validate the Command Set Identifier descriptor value.

      :Command: parses ``nvme ns-descs`` output for ``csi``
      :Pass: CSI value is 0 (NVM), 2 (ZNS), 3 (KV), or another recognized index; or CSI not present (optional)
      :Skip: NVMe version below 2.0

5. **Descriptor Integrity**

   a. **test_descriptor_lengths** -- verify that descriptor lengths match spec requirements (EUI-64=8, NGUID=16, UUID=16).

      :Command: parses length fields from ``nvme ns-descs`` output
      :Pass: all present descriptors have correct lengths
      :Fail: one or more descriptors have incorrect lengths

6. **Summary**

   - Report total PASS / FAIL / SKIP / WARN counts
   - Exit with non-zero status if any FAIL

Result Codes
------------

- **PASS** -- check succeeded, device conforms to spec
- **FAIL** -- device non-compliance with NVMe specification
- **SKIP** -- test not applicable (version gate, missing feature)
- **WARN** -- advisory condition, not a hard failure
