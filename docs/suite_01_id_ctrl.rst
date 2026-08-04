Suite 1: Identify Controller
=============================

**Script:** ``nvme_id_ctrl_test/nvme_id_ctrl_verify.sh``
**Category:** Read-Only
**NVMe Command:** ``nvme id-ctrl``

Overview
--------

Validates all mandatory fields in the NVMe Identify Controller data structure
(NVMe Base Specification, Revision 2.1, Section 5.1.13.2.1, Figure 312). Each
field is checked for presence, legal value, and version-conditional requirements.
Fields introduced in NVMe 1.2, 1.3, 1.4, 2.0, and 2.1 are automatically
skipped on older controllers. Deep validation tests cross-check related fields
for logical consistency.

Prerequisites
-------------

- Root privileges (``sudo``)
- ``nvme-cli`` installed
- NVMe device (e.g., ``/dev/nvme0``)

Test Steps
----------

1. **Preflight & Setup**

   - Verify root privileges and ``nvme-cli`` availability
   - Resolve target controller device (auto-detect or user-specified)
   - Cache Identify Controller data (``nvme id-ctrl /dev/nvmeX``)
   - Initialize logging

2. **Controller Capabilities and Features (Bytes 0-255)**

   a. **test_vid** -- Verify PCI Vendor ID is non-zero.

      :Command: ``nvme id-ctrl /dev/nvmeX``
      :Pass: vid field is present and non-zero
      :Fail: vid is empty or zero

   b. **test_ssvid** -- Verify PCI Subsystem Vendor ID is non-zero.

      :Pass: ssvid field is present and non-zero
      :Fail: ssvid is empty or zero

   c. **test_sn** -- Verify Serial Number is non-empty.

      :Pass: sn field contains a non-empty string
      :Fail: sn is empty

   d. **test_mn** -- Verify Model Number is non-empty.

      :Pass: mn field contains a non-empty string
      :Fail: mn is empty

   e. **test_fr** -- Verify Firmware Revision is non-empty.

      :Pass: fr field contains a non-empty string
      :Fail: fr is empty

   f. **test_rab** -- Verify Recommended Arbitration Burst is reported.

      :Pass: rab field is present
      :Fail: rab not present

   g. **test_ieee** -- Verify IEEE OUI Identifier is non-zero.

      :Pass: ieee field is present and not ``000000``
      :Fail: ieee is empty or all zeros

   h. **test_mdts** -- Verify Maximum Data Transfer Size is reported.

      :Pass: mdts field is present
      :Fail: mdts not present

   i. **test_cntlid** -- Verify Controller ID is reported.

      :Pass: cntlid field is present
      :Fail: cntlid not present

   j. **test_ver** -- Verify NVMe Version is non-zero.

      :Pass: ver field is present and non-zero; version string decoded
      :Fail: ver is zero or empty (required since NVMe 1.2)

   k. **test_rtd3r** -- Verify D3 Resume Latency is reported.

      :Pass: rtd3r field is present
      :Fail: rtd3r not present
      :Skip: controller is pre-NVMe 1.2

   l. **test_rtd3e** -- Verify D3 Entry Latency is reported.

      :Pass: rtd3e field is present
      :Fail: rtd3e not present
      :Skip: controller is pre-NVMe 1.2

   m. **test_oaes** -- Verify Optional Async Event Support is reported.

      :Pass: oaes field is present
      :Fail: oaes not present
      :Skip: controller is pre-NVMe 1.2

   n. **test_ctratt** -- Verify Controller Attributes is reported.

      :Pass: ctratt field is present
      :Fail: ctratt not present
      :Skip: controller is pre-NVMe 1.3

   o. **test_bpcap** -- Verify Boot Partition Capabilities is reported.

      :Pass: bpcap field is present
      :Fail: bpcap not present
      :Skip: controller is pre-NVMe 1.4

   p. **test_cntrltype** -- Verify Controller Type is valid (1=I/O, 2=Discovery, 3=Admin).

      :Pass: cntrltype is 1, 2, or 3
      :Fail: cntrltype is 0 or unknown value (NVMe 1.4+)
      :Skip: controller is pre-NVMe 1.4

   q. **test_nvmsr** -- Verify NVM Subsystem Report is reported.

      :Pass: nvmsr field is present
      :Fail: nvmsr not present
      :Skip: controller is pre-NVMe 1.4

   r. **test_vwci** -- Verify VPD Write Cycle Info is reported.

      :Pass: vwci field is present
      :Fail: vwci not present
      :Skip: controller is pre-NVMe 1.4

   s. **test_mec** -- Verify Management Endpoint Capabilities is reported.

      :Pass: mec field is present
      :Fail: mec not present
      :Skip: controller is pre-NVMe 1.4

3. **Admin Command Set Attributes (Bytes 256-511)**

   a. **test_oacs** -- Verify Optional Admin Command Support is reported.

      :Pass: oacs field is present; decoded bits logged
      :Fail: oacs not present

   b. **test_acl** -- Verify Abort Command Limit is reported.

      :Pass: acl field is present
      :Fail: acl not present

   c. **test_aerl** -- Verify Async Event Request Limit is reported.

      :Pass: aerl field is present
      :Fail: aerl not present

   d. **test_frmw** -- Verify firmware slot count is between 1 and 7.

      :Pass: FRMW.NOFS is 1-7
      :Fail: FRMW not present or NOFS out of range

   e. **test_lpa** -- Verify Log Page Attributes is reported.

      :Pass: lpa field is present
      :Fail: lpa not present

   f. **test_elpe** -- Verify Error Log Page Entries count is reported.

      :Pass: elpe field is present
      :Fail: elpe not present

   g. **test_npss** -- Verify Number of Power States Support is reported.

      :Pass: npss field is present
      :Fail: npss not present

   h. **test_avscc** -- Verify Admin Vendor Specific Command Config is reported.

      :Pass: avscc field is present
      :Fail: avscc not present

   i. **test_wctemp** -- Verify Warning Composite Temperature Threshold is non-zero.

      :Pass: wctemp is non-zero (or zero on pre-1.2 controllers)
      :Fail: wctemp is zero on NVMe 1.2+ controllers

   j. **test_cctemp** -- Verify Critical Composite Temperature Threshold is non-zero.

      :Pass: cctemp is non-zero (or zero on pre-1.2 controllers)
      :Fail: cctemp is zero on NVMe 1.2+ controllers

   k. **test_fwug** -- Verify Firmware Update Granularity is reported.

      :Pass: fwug field is present
      :Fail: fwug not present
      :Skip: controller is pre-NVMe 1.3

   l. **test_kas** -- Verify Keep Alive Support is reported.

      :Pass: kas field is present
      :Skip: controller is pre-NVMe 1.2, or field not present

   m. **test_cqt** -- Verify Command Quiesce Time is reported.

      :Pass: cqt field is present
      :Fail: cqt not present
      :Skip: controller is pre-NVMe 2.1

4. **NVM Command Set Attributes (Bytes 512-575)**

   a. **test_sqes** -- Verify minimum Submission Queue entry size is 64 bytes (2^6).

      :Pass: SQES lower nibble equals 6
      :Fail: SQES lower nibble is not 6

   b. **test_cqes** -- Verify minimum Completion Queue entry size is 16 bytes (2^4).

      :Pass: CQES lower nibble equals 4
      :Fail: CQES lower nibble is not 4

   c. **test_maxcmd** -- Verify Maximum Outstanding Commands is reported.

      :Pass: maxcmd is non-zero
      :Skip: maxcmd is 0 (optional for PCIe) or not present

   d. **test_nn** -- Verify Number of Namespaces is non-zero.

      :Pass: nn > 0
      :Fail: nn is zero or empty

   e. **test_oncs** -- Verify Optional NVM Command Support is reported.

      :Pass: oncs field is present
      :Fail: oncs not present

   f. **test_fuses** -- Verify Fused Operation Support is reported.

      :Pass: fuses field is present
      :Fail: fuses not present

   g. **test_fna** -- Verify Format NVM Attributes is reported.

      :Pass: fna field is present
      :Fail: fna not present

   h. **test_vwc** -- Verify Volatile Write Cache is reported.

      :Pass: vwc field is present
      :Fail: vwc not present

   i. **test_awun** -- Verify Atomic Write Unit Normal is reported.

      :Pass: awun field is present
      :Fail: awun not present

   j. **test_awupf** -- Verify Atomic Write Unit Power Fail is reported.

      :Pass: awupf field is present
      :Fail: awupf not present

   k. **test_icsvscc** -- Verify I/O Cmd Set Vendor Specific Config is reported.

      :Pass: icsvscc field is present
      :Fail: icsvscc not present

   l. **test_nwpc** -- Verify Namespace Write Protection Capabilities is reported.

      :Pass: nwpc field is present
      :Fail: nwpc not present
      :Skip: controller is pre-NVMe 1.4

   m. **test_ocfs** -- Verify Copy Descriptor Formats Supported is reported.

      :Pass: ocfs field is present
      :Fail: ocfs not present
      :Skip: controller is pre-NVMe 2.0

5. **NVM Subsystem Attributes (Bytes 256-1023)**

   a. **test_subnqn** -- Verify NVMe Qualified Name is reported and starts with ``nqn.``.

      :Pass: subnqn is present and begins with ``nqn.``
      :Fail: subnqn is empty, missing, or does not start with ``nqn.``
      :Skip: controller is pre-NVMe 1.4

6. **Deep Field Validation**

   a. **test_oacs_bit_decode** -- Full bitwise decode of OACS; cross-check FW Commit bit against FRMW slot count.

      :Pass: all bits decoded successfully; FW Commit + FRMW consistent
      :Fail: OACS not present, or FW Commit supported but FRMW slots = 0

   b. **test_oncs_bit_decode** -- Full bitwise decode of ONCS (Compare, Write Uncorrectable, DSM, Write Zeroes, etc.).

      :Pass: all bits decoded
      :Fail: oncs not present

   c. **test_ctratt_bit_decode** -- Full bitwise decode of Controller Attributes.

      :Pass: all bits decoded
      :Fail: ctratt not present
      :Skip: controller is pre-NVMe 1.3

   d. **test_mdts_reasonable** -- Verify MDTS implies a maximum transfer size of at least 128 KiB.

      :Pass: MDTS = 0 (no limit) or computed size >= 128 KiB
      :Fail: computed max transfer < 128 KiB

   e. **test_wctemp_cctemp_cross** -- Verify CCTEMP > WCTEMP and both are within 273K-500K.

      :Pass: CCTEMP > WCTEMP
      :Fail: CCTEMP <= WCTEMP
      :Skip: one or both thresholds are zero or unavailable
      :Warn: temperature outside 273K-500K typical range

   f. **test_hctma_thermal** -- If HCTMA is supported, verify MNTMT < MXTMT.

      :Pass: HCTMA not supported, or MNTMT < MXTMT
      :Fail: HCTMA supported but MNTMT >= MXTMT or fields missing
      :Skip: controller is pre-NVMe 1.3

   g. **test_tnvmcap_unvmcap** -- Verify UNVMCAP <= TNVMCAP.

      :Pass: UNVMCAP <= TNVMCAP, or TNVMCAP = 0 (not reported)
      :Fail: UNVMCAP > TNVMCAP
      :Skip: controller is pre-NVMe 1.3 or fields not present

   h. **test_awun_awupf_cross** -- Verify AWUPF <= AWUN.

      :Pass: AWUPF <= AWUN
      :Fail: AWUPF > AWUN
      :Skip: fields not present

   i. **test_lpa_bit_decode** -- Full bitwise decode of Log Page Attributes.

      :Pass: all bits decoded
      :Fail: lpa not present

   j. **test_sgls_decode** -- Decode Scatter Gather List Support field.

      :Pass: all bits decoded
      :Skip: controller is pre-NVMe 1.3 or sgls not present

   k. **test_sanicap_decode** -- Decode Sanitize Capabilities field.

      :Pass: all bits decoded
      :Skip: controller is pre-NVMe 1.3 or sanicap not present

   l. **test_nn_cross_validate** -- Verify active namespace count from ``nvme list-ns`` does not exceed NN.

      :Command: ``nvme list-ns /dev/nvmeX --all``
      :Pass: active namespace count <= NN
      :Fail: more active namespaces than NN
      :Skip: NN not present or controller device unresolvable

   m. **test_reserved_bits** -- Verify reserved bits in OACS[15:12] and ONCS[15:13] are zero.

      :Pass: all reserved bits are zero
      :Fail: any reserved bit is non-zero

7. **Summary**

   - Report total PASS / FAIL / SKIP / WARN counts
   - Exit with non-zero status if any FAIL

Result Codes
------------

- **PASS** -- check succeeded, device conforms to spec
- **FAIL** -- device non-compliance with NVMe specification
- **SKIP** -- test not applicable (version gate, missing feature)
- **WARN** -- advisory condition, not a hard failure
