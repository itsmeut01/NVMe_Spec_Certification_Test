Suite 5: Identify Namespace
===========================

**Script:** ``nvme_id_ns_test/nvme_id_ns_verify.sh``
**Category:** Read-Only
**NVMe Command:** ``nvme id-ns``

Overview
--------

Validates all mandatory and version-conditional fields in the NVMe Identify
Namespace data structure (NVMe Base Specification, Revision 2.1,
Section 5.1.13, Figure 319). The suite checks namespace size and capacity
relationships, LBA format validity, atomic write parameters, namespace
identifiers, and performs deep bitfield decoding with cross-validation of
related fields such as dps vs. dpc and nvmcap vs. nsze.

Prerequisites
-------------

- Root privileges (``sudo``)
- ``nvme-cli`` installed
- NVMe namespace device (e.g., ``/dev/nvme0n1``)

Test Steps
----------

1. **Preflight & Setup**

   - Verify root privileges and ``nvme-cli`` availability
   - Resolve target namespace device (auto-detect or user-specified)
   - Cache Identify Controller data (``nvme id-ctrl /dev/nvmeX``)
   - Retrieve Identify Namespace data (``nvme id-ns /dev/nvmeXnY``)
   - Initialize logging

2. **Namespace Size & Capacity**

   a. **test_nsze** -- Verify Namespace Size is present and non-zero.

      :Command: ``nvme id-ns /dev/nvmeXnY``
      :Pass: nsze > 0
      :Fail: nsze is zero or not found

   b. **test_ncap** -- Verify Namespace Capacity is present, non-zero, and <= nsze.

      :Pass: 0 < ncap <= nsze
      :Fail: ncap is zero, not found, or ncap > nsze

   c. **test_nuse** -- Verify Namespace Utilization is present and <= ncap.

      :Pass: nuse <= ncap
      :Fail: nuse > ncap or not found

3. **Namespace Features & Format**

   a. **test_nsfeat** -- Verify Namespace Features field is present.

      :Pass: nsfeat field found
      :Fail: nsfeat not found

   b. **test_nlbaf** -- Verify Number of LBA Formats is present (0-based, so 0 means 1 format).

      :Pass: nlbaf field found and >= 0
      :Fail: nlbaf not found

   c. **test_flbas** -- Verify Formatted LBA Size is present and the active format index does not exceed nlbaf.

      :Pass: flbas active format index <= nlbaf
      :Fail: active format index > nlbaf, or flbas not found

   d. **test_mc** -- Verify Metadata Capabilities field is present.

      :Pass: mc field found
      :Fail: mc not found

   e. **test_dpc** -- Verify Data Protection Capabilities field is present.

      :Pass: dpc field found
      :Fail: dpc not found

   f. **test_dps** -- Verify Data Protection Settings field is present.

      :Pass: dps field found
      :Fail: dps not found

4. **Multi-path, Reservations & Format**

   a. **test_nmic** -- Verify Namespace Multi-path/Sharing Capabilities field is present.

      :Pass: nmic field found
      :Fail: nmic not found

   b. **test_rescap** -- Verify Reservation Capabilities field is present.

      :Pass: rescap field found
      :Fail: rescap not found

   c. **test_fpi** -- Verify Format Progress Indicator field is present.

      :Pass: fpi field found
      :Fail: fpi not found

   d. **test_dlfeat** -- Verify Deallocate Logical Block Features field is present.

      :Pass: dlfeat field found
      :Fail: dlfeat not found
      :Skip: controller is pre-NVMe 1.3

5. **Atomic Write Parameters**

   a. **test_nawun** -- Verify Namespace Atomic Write Unit Normal is present.

      :Pass: nawun field found
      :Fail: nawun not found
      :Skip: controller is pre-NVMe 1.2

   b. **test_nawupf** -- Verify Namespace Atomic Write Unit Power Fail is present.

      :Pass: nawupf field found
      :Fail: nawupf not found
      :Skip: controller is pre-NVMe 1.2

   c. **test_nacwu** -- Verify Namespace Atomic Compare & Write Unit is present.

      :Pass: nacwu field found
      :Fail: nacwu not found
      :Skip: controller is pre-NVMe 1.2

   d. **test_nabsn** -- Verify Namespace Atomic Boundary Size Normal is present.

      :Pass: nabsn field found
      :Fail: nabsn not found
      :Skip: controller is pre-NVMe 1.2

   e. **test_nabo** -- Verify Namespace Atomic Boundary Offset is present.

      :Pass: nabo field found
      :Fail: nabo not found
      :Skip: controller is pre-NVMe 1.2

   f. **test_nabspf** -- Verify Namespace Atomic Boundary Size Power Fail is present.

      :Pass: nabspf field found
      :Fail: nabspf not found
      :Skip: controller is pre-NVMe 1.2

   g. **test_noiob** -- Verify Namespace Optimal I/O Boundary is present.

      :Pass: noiob field found
      :Fail: noiob not found
      :Skip: controller is pre-NVMe 1.2

6. **Capacity & Identifiers**

   a. **test_nvmcap** -- Verify NVM Capacity field is present.

      :Pass: nvmcap field found
      :Fail: nvmcap not found
      :Skip: controller is pre-NVMe 1.3

   b. **test_anagrpid** -- Verify ANA Group Identifier is present.

      :Pass: anagrpid field found
      :Fail: anagrpid not found
      :Skip: controller is pre-NVMe 1.4

   c. **test_nvmsetid** -- Verify NVM Set Identifier is present.

      :Pass: nvmsetid field found
      :Fail: nvmsetid not found
      :Skip: controller is pre-NVMe 1.4

   d. **test_endgid** -- Verify Endurance Group Identifier is present.

      :Pass: endgid field found
      :Fail: endgid not found
      :Skip: controller is pre-NVMe 1.4

   e. **test_nguid** -- Verify Namespace GUID is present; note if all-zeros.

      :Pass: nguid field found (non-zero or all-zeros with note)
      :Fail: nguid not found

   f. **test_eui64** -- Verify IEEE Extended Unique Identifier is present; note if all-zeros.

      :Pass: eui64 field found (non-zero or all-zeros with note)
      :Fail: eui64 not found

7. **LBA Format Validation**

   a. **test_lbaf0** -- Verify LBA Format 0 is present and lbads >= 9 (minimum 512-byte sector).

      :Pass: lbaf 0 present with lbads >= 9
      :Fail: lbaf 0 not found or lbads < 9

   b. **test_active_lbaf_valid** -- Verify the active LBA format has lbads in range 9-16.

      :Pass: active format lbads is 9-16
      :Fail: lbads outside 9-16 range or not parseable

8. **Deep Field Validation**

   a. **test_nsfeat_decode** -- Bitwise decode of Namespace Features (thin provisioning, ns-atomic, DULBE, UID reuse, optimal performance).

      :Pass: all bits decoded
      :Skip: nsfeat not present

   b. **test_mc_decode** -- Bitwise decode of Metadata Capabilities (extended LBA, metadata pointer).

      :Pass: all bits decoded
      :Skip: mc not present

   c. **test_dpc_decode** -- Bitwise decode of Data Protection Capabilities (PI Type 1/2/3, first/last 8 bytes).

      :Pass: all bits decoded
      :Skip: dpc not present

   d. **test_dps_vs_dpc** -- Cross-check Data Protection Settings against Data Protection Capabilities.

      :Pass: PI disabled (pit=0), or selected PI type is supported by dpc
      :Fail: dps selects a PI type not supported by dpc
      :Skip: dps or dpc not present

   e. **test_rescap_decode** -- Bitwise decode of Reservation Capabilities (ptpl, WE, EA, WERO, EARO, WEAR, EAAR, IEKR).

      :Pass: all bits decoded
      :Skip: rescap not present

   f. **test_fpi_decode** -- Decode Format Progress Indicator (supported flag and remaining percentage).

      :Pass: fpis and percentage decoded
      :Skip: fpi not present

   g. **test_dlfeat_decode** -- Decode Deallocate Logical Block Features (read behavior, write-zeroes, guard CRC).

      :Pass: all bits decoded
      :Skip: controller is pre-NVMe 1.3 or dlfeat not present

   h. **test_nvmcap_vs_nsze** -- Cross-check nvmcap against nsze * block_size.

      :Pass: nvmcap >= nsze * block_size, or nvmcap = 0 (not reported)
      :Warn: nvmcap < nsze * block_size
      :Skip: controller is pre-NVMe 1.3 or fields not available

   i. **test_nguid_eui64_unique_id** -- Verify namespace has at least one non-zero unique identifier (nguid or eui64).

      :Pass: at least one of nguid or eui64 is non-zero
      :Warn: both nguid and eui64 are all zeros

   j. **test_all_lbaf_validation** -- Verify all LBA formats (0 through nlbaf) have lbads >= 9.

      :Pass: all formats have valid lbads
      :Fail: one or more formats have lbads < 9
      :Skip: nlbaf not present

9. **Summary**

   - Report total PASS / FAIL / SKIP / WARN counts
   - Exit with non-zero status if any FAIL

Result Codes
------------

- **PASS** -- check succeeded, device conforms to spec
- **FAIL** -- device non-compliance with NVMe specification
- **SKIP** -- test not applicable (version gate, missing feature)
- **WARN** -- advisory condition, not a hard failure
