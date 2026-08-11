Suite 29: KV Command Set
========================

**Script:** ``nvme_kv_test/nvme_kv_verify.sh``
**Category:** Read-Only (with optional Destructive section)
**NVMe Command:** ``nvme ns-descs``, ``nvme id-ns``, ``nvme get-feature``, ``nvme io-passthru``

Overview
--------

Validates the NVMe KV (Key Value) Command Set as defined in the KV Command Set
Specification, Revision 1.4. The KV Command Set (CSI=3) enables key-value
operations on NVMe namespaces as an alternative to the traditional block-based
NVM Command Set. This suite detects KV namespaces via the CSI descriptor in
``nvme ns-descs``, verifies KV Identify Namespace fields, probes the KV
Configuration feature (FID 0x20), and sends read-only KV I/O commands (List,
Exist) via ``nvme io-passthru``.

**Note:** KV-capable NVMe hardware is uncommon. On non-KV namespaces (CSI != 3),
the entire suite exits with SKIP after the initial detection check. This is
expected behavior for most NVMe devices.

An optional destructive section performs a full Store/Retrieve/Delete lifecycle
test when ``--allow-destructive`` is passed.

Prerequisites
-------------

- Root privileges (``sudo``)
- ``nvme-cli`` installed
- NVMe device (e.g., ``/dev/nvme0``)
- KV Command Set namespace (CSI=3) for tests to execute (non-KV namespaces skip the entire suite)
- ``--allow-destructive`` flag for Store/Retrieve/Delete lifecycle test
- Non-OS NVMe device for destructive tests (OS drive is always refused)

Test Steps
----------

1. **Preflight & Setup**

   - Verify root privileges and ``nvme-cli`` availability
   - Resolve target controller and namespace devices
   - Cache Identify Controller data (``nvme id-ctrl``)
   - Detect KV namespace via ``nvme ns-descs`` (CSI=3 check)
   - If namespace is not KV, SKIP entire suite and exit
   - Initialize logging

2. **KV Detection**

   a. **test_kv_detect** -- confirm the namespace reports CSI=3 (KV Command Set) via the Namespace Identification Descriptors.

      :Command: ``nvme ns-descs /dev/nvmeXnY``
      :Pass: CSI=3 detected in ns-descs output
      :Fail: CSI != 3 (should not reach this point due to early skip)

3. **KV Identify Namespace**

   a. **test_kv_id_ns** -- run ``nvme id-ns`` on the KV namespace and verify the command succeeds.

      :Command: ``nvme id-ns /dev/nvmeXnY``
      :Pass: command returns non-empty output without error indicators
      :Fail: command returns empty output or error

   b. **test_kv_nsze** -- check that the NSZE (Namespace Size) field is present and non-zero.

      :Command: parses ``nvme id-ns`` output for ``nsze``
      :Pass: NSZE is present and greater than zero
      :Fail: NSZE field missing or zero
      :Skip: id-ns output not available

   c. **test_kv_ncap** -- check that the NCAP (Namespace Capacity) field is present.

      :Command: parses ``nvme id-ns`` output for ``ncap``
      :Pass: NCAP field is present (zero allowed for thin provisioning)
      :Fail: NCAP field missing
      :Skip: id-ns output not available

4. **KV Configuration (FID 0x20)**

   a. **test_kv_config_fid** -- read the KV Configuration feature (FID 0x20) via ``nvme get-feature`` and verify the command completes.

      :Command: ``nvme get-feature /dev/nvmeXnY -f 0x20``
      :Pass: feature is readable and returns a result value
      :Skip: controller does not support FID 0x20

   b. **test_ednek_decode** -- if FID 0x20 is readable, decode the EDNEK (Enable Distinct Namespace Encryption Keys) bit (bit 0 of the result).

      :Command: parses FID 0x20 result value
      :Pass: EDNEK bit decoded (enabled or disabled)
      :Skip: FID 0x20 not supported or result value not parseable

5. **KV I/O Probe (Read-Only)**

   a. **test_kv_list_keys** -- send the KV List command (opcode 0x06) via ``nvme io-passthru`` to enumerate keys. Verifies the controller responds with either success or a valid error code.

      :Command: ``nvme io-passthru /dev/nvmeXnY --opcode=0x06 --data-len=4096 -r``
      :Pass: controller responds (success or valid status code)
      :Skip: controller does not recognize KV List opcode

   b. **test_kv_exist_probe** -- send the KV Exist command (opcode 0x14) with a zero-length key via ``nvme io-passthru``. Verifies the controller responds appropriately.

      :Command: ``nvme io-passthru /dev/nvmeXnY --opcode=0x14 --cdw11=0``
      :Pass: controller responds with valid status (key not found is expected)
      :Skip: controller does not recognize KV Exist opcode

6. **Destructive: KV Store/Retrieve/Delete** *(optional, requires --allow-destructive)*

   a. **test_kv_store_retrieve_delete** -- full KV lifecycle: Store a small test value with a 4-byte key, Retrieve it and verify data matches, Delete the key, then verify deletion via Exist.

      :Command: ``nvme io-passthru`` with opcodes 0x01 (Store), 0x02 (Retrieve), 0x10 (Delete), 0x14 (Exist)
      :Pass: Store succeeds, Retrieve returns matching data, Delete succeeds, Exist confirms key absent
      :Fail: any step returns an unexpected error or data mismatch
      :Skip: KV Store opcode not supported; or ``--allow-destructive`` not passed
      :Warn: key still appears to exist after deletion

7. **Summary**

   - Report total PASS / FAIL / SKIP / WARN counts
   - Exit with non-zero status if any FAIL

Result Codes
------------

- **PASS** -- check succeeded, device conforms to KV Command Set specification
- **FAIL** -- device non-compliance with KV Command Set specification
- **SKIP** -- test not applicable (non-KV namespace, feature not supported, destructive flag not passed)
- **WARN** -- advisory condition, not a hard failure
