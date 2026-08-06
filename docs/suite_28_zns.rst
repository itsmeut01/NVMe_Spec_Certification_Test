Suite 28: ZNS (Zoned Namespace)
================================

**Script:** ``nvme_zns_test/nvme_zns_verify.sh``
**Category:** Mixed (Read-Only + Destructive)
**NVMe Commands:** ``nvme zns id-ctrl``, ``nvme zns id-ns``, ``nvme zns report-zones``, ``nvme zns changed-zone-list``, ``nvme zns open-zone``, ``nvme zns close-zone``, ``nvme zns reset-zone``, ``nvme zns zrwa-flush-zone``, ``nvme ns-descs``

Overview
--------

Validates the NVMe ZNS (Zoned Namespace) Command Set per ZNS Command Set
Specification, Revision 1.5. The suite detects whether the target namespace
is ZNS (CSI=2) and, if not, skips the entire suite. Read-only tests verify
ZNS Identify Controller, ZNS Identify Namespace fields (ZOC, OZCS, MAR, MOR,
RRL, FRL, multi-level time limits, ZRWA, LBA Format Extensions), zone
report parsing, and changed zone list. Destructive tests exercise the full
zone lifecycle (open, close, reset) and ZRWA explicit flush when supported.

Prerequisites
-------------

- Root privileges (``sudo``)
- ``nvme-cli`` installed (with ZNS plugin support)
- NVMe namespace device that implements the ZNS Command Set (CSI=2)
- ``--allow-destructive`` flag required for zone lifecycle and ZRWA flush tests
- Non-OS NVMe device (OS drive is always refused for destructive tests)

Test Steps
----------

1. **Preflight & Setup**

   - Verify root privileges and ``nvme-cli`` availability
   - Resolve target controller and namespace devices
   - Detect ZNS support via ``nvme zns id-ns`` or ``nvme ns-descs`` CSI field
   - If not ZNS, skip entire suite with exit 0
   - Cache Identify Controller data (``nvme id-ctrl``)
   - Initialize logging

2. **ZNS Detection**

   a. **test_zns_detect** -- Verify the namespace is ZNS by checking CSI=2 from ``nvme ns-descs`` or confirming ``nvme zns id-ns`` returns ZNS fields.

      :Command: ``nvme ns-descs /dev/nvmeXnY``, ``nvme zns id-ns /dev/nvmeXnY``
      :Pass: CSI=2 detected, or zns id-ns returns ZNS fields (zoc, ozcs, mar, mor)
      :Fail: CSI is not 2 and zns id-ns returns no ZNS fields

3. **ZNS Identify Controller**

   a. **test_zns_id_ctrl** -- Run ``nvme zns id-ctrl`` and verify the zasl (Zone Append Size Limit) field is present.

      :Command: ``nvme zns id-ctrl /dev/nvmeX``
      :Pass: zasl field found in output
      :Fail: zasl field not found

   b. **test_zasl_range** -- Validate ZASL value: 0 means no separate limit (equals MDTS), otherwise ZASL must be <= MDTS.

      :Pass: ZASL=0, or ZASL <= MDTS
      :Fail: ZASL > MDTS
      :Skip: zasl not available

4. **ZNS Identify Namespace**

   a. **test_zns_id_ns** -- Run ``nvme zns id-ns`` and verify key fields (zoc, ozcs, mar, mor) are present.

      :Command: ``nvme zns id-ns /dev/nvmeXnY``
      :Pass: all four fields present
      :Fail: one or more fields missing, or command not supported

   b. **test_zoc_decode** -- Decode Zone Operation Characteristics bits: VZC (bit 0, Variable Zone Capacity), ZAE (bit 1, Zone Active Excursions).

      :Pass: bits decoded and reported
      :Skip: zoc field not available

   c. **test_ozcs_decode** -- Decode Optional Zoned Command Support bits: RAZB (bit 0, Read Across Zone Boundaries), ZRWA (bit 1, Zone Random Write Area).

      :Pass: bits decoded and reported
      :Skip: ozcs field not available

   d. **test_mar_value** -- Validate Max Active Resources: 0xFFFFFFFF means unlimited, otherwise report the limit.

      :Pass: MAR is 0xFFFFFFFF (unlimited) or a valid resource count
      :Fail: unexpected negative value
      :Skip: mar field not available

   e. **test_mor_value** -- Validate Max Open Resources: 0xFFFFFFFF means unlimited, otherwise report the limit.

      :Pass: MOR is 0xFFFFFFFF (unlimited) or a valid resource count
      :Fail: unexpected negative value
      :Skip: mor field not available

5. **Recommended Limits**

   a. **test_rrl_frl** -- Check Reset Recommended Limit (RRL) and Finish Recommended Limit (FRL) fields are present.

      :Pass: both rrl and frl found
      :Warn: only one of rrl/frl found
      :Skip: neither rrl nor frl found

   b. **test_multi_level_limits** -- Check ZNS 1.5 multi-level time limit fields (rrl1, rrl2, rrl3, frl1, frl2, frl3).

      :Pass: all six fields present, or partially present (pre-1.5 device)
      :Skip: none of the multi-level fields found (pre-ZNS 1.5 device)

6. **ZRWA (Zone Random Write Area)**

   a. **test_zrwa_fields** -- If OZCS bit 1 indicates ZRWA support, verify numzrwa, zrwafg, zrwasz, and zrwacap fields are present.

      :Pass: all ZRWA fields present
      :Fail: OZCS ZRWA=1 but one or more ZRWA fields missing
      :Skip: OZCS bit 1=0 (ZRWA not supported) or ozcs not available

   b. **test_zrwacap_explicit_flush** -- If ZRWA supported, decode zrwacap bit 0 (explicit ZRWA flush support).

      :Pass: bit 0 decoded and reported (1=supported, 0=not supported)
      :Skip: ZRWA not supported, or zrwacap not available

7. **LBA Format Extensions**

   a. **test_lbafe** -- Verify at least one LBA Format Extension entry exists with zsze (Zone Size) > 0.

      :Pass: at least one lbafe entry with zsze > 0
      :Fail: no lbafe entries found, or all entries have zsze=0

8. **Zone Report**

   a. **test_report_zones** -- Run ``nvme zns report-zones`` and verify it returns zone data.

      :Command: ``nvme zns report-zones /dev/nvmeXnY``
      :Pass: output contains zone entries (SLBA/zone references)
      :Fail: command not supported, or no zone entries in output

   b. **test_zone_count** -- Parse the total number of zones from the report-zones output.

      :Pass: zone count determined and reported
      :Fail: could not determine zone count
      :Skip: report-zones output not available

   c. **test_zone_state_types** -- Verify all reported zone states are valid (Empty, Open, Closed, Full, Read Only, Offline).

      :Pass: all zone states are recognized types
      :Fail: one or more zones with unrecognized state
      :Skip: could not parse zone states, or report-zones output not available

   d. **test_changed_zone_list** -- Run ``nvme zns changed-zone-list`` and verify it completes.

      :Command: ``nvme zns changed-zone-list /dev/nvmeXnY``
      :Pass: command completed
      :Skip: command not supported

9. **Destructive: Zone Lifecycle** (requires ``--allow-destructive``)

   a. **test_zone_lifecycle** -- Open zone 0, verify state is Open, close zone, verify state is Closed, reset zone, verify state is Empty.

      :Command: ``nvme zns open-zone``, ``nvme zns close-zone``, ``nvme zns reset-zone``
      :Pass: each state transition verified (Open -> Closed -> Empty)
      :Fail: open-zone command fails
      :Warn: state after transition does not match expected value
      :Skip: could not determine first zone SLBA

   b. **test_zrwa_flush** -- If ZRWA and explicit flush are supported, test ``nvme zns zrwa-flush-zone`` on the first zone.

      :Command: ``nvme zns zrwa-flush-zone /dev/nvmeXnY -l <slba>``
      :Pass: flush command completed
      :Fail: flush command returned error
      :Skip: ZRWA not supported, explicit flush not supported, or SLBA not available

10. **Summary**

    - Report total PASS / FAIL / SKIP / WARN counts
    - Exit with non-zero status if any FAIL

Result Codes
------------

- **PASS** -- check succeeded, device conforms to ZNS specification
- **FAIL** -- device non-compliance with ZNS Command Set Specification
- **SKIP** -- test not applicable (not a ZNS device, feature not supported, missing capability)
- **WARN** -- advisory condition, not a hard failure (e.g., zone state after transition differs from expected)
