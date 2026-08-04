Suite 16: Additional Identify
=============================

**Script:** ``nvme_additional_id_test/nvme_additional_id_verify.sh``
**Category:** Read-Only
**NVMe Command:** ``nvme list-ctrl``, ``nvme list-subsys``, ``nvme primary-ctrl-caps``, ``nvme list-secondary``, ``nvme id-uuid``, ``nvme nvm-id-ctrl``, ``nvme nvm-id-ns``, ``nvme cmdset-ind-id-ns``, ``nvme id-domain``, ``nvme id-iocs``, ``nvme id-nvmset``, ``nvme id-ns-granularity``, ``nvme id-ns-lba-format``, ``nvme list-endgrp``, ``nvme nvm-id-ns-lba-format``

Overview
--------

Performs read-only verification of all NVMe Identify command variants and list
commands beyond the core ``id-ctrl`` and ``id-ns``. The suite probes controller
and subsystem list commands, multi-controller and virtualization structures
(Primary Controller Capabilities, Secondary Controller List), extended identify
structures introduced in NVMe 1.4 and 2.0 (UUID List, NVM Command Set Identify,
Command Set Independent ID, Domain List, I/O Command Set), NVM Set and Namespace
Granularity structures, and LBA Format and Endurance Group lists. Each test
validates command accessibility and, where possible, cross-checks key fields
against cached Identify Controller data.

Prerequisites
-------------

- Root privileges (``sudo``)
- ``nvme-cli`` installed
- NVMe device (e.g., ``/dev/nvme0`` or ``/dev/nvme0n1``)

Test Steps
----------

1. **Preflight & Setup**

   - Verify root privileges and ``nvme-cli`` availability
   - Resolve target controller device and namespace device (auto-detect or user-specified)
   - Cache Identify Controller data (``nvme id-ctrl``)
   - Initialize logging

2. **Controller & Subsystem Lists**

   a. **test_list_ctrl_attached** -- list controllers attached to the namespace and verify own CNTLID appears.

      :Command: ``nvme list-ctrl /dev/nvmeX``
      :Pass: controller list returned; own CNTLID found in output if parseable
      :Skip: controller returns not-supported/invalid

   b. **test_list_ctrl_subsystem** -- list all controllers in the subsystem (controller ID 0 scope).

      :Command: ``nvme list-ctrl /dev/nvmeX -c 0``
      :Pass: controller list returned
      :Skip: controller returns not-supported/invalid

   c. **test_list_subsys** -- list NVMe subsystem topology and cross-check SUBNQN with id-ctrl.

      :Command: ``nvme list-subsys /dev/nvmeX``
      :Pass: SUBNQN from id-ctrl matches output, or subsystem topology returned
      :Skip: controller returns not-supported

3. **Multi-Controller / Virtualization**

   a. **test_primary_ctrl_caps** -- read Primary Controller Capabilities and cross-check CNTLID.

      :Command: ``nvme primary-ctrl-caps /dev/nvmeX``
      :Pass: key fields (cntlid, portid, crt) present; CNTLID matches id-ctrl if parseable
      :Skip: controller returns not-supported/invalid

   b. **test_list_secondary** -- list Secondary Controller entries.

      :Command: ``nvme list-secondary /dev/nvmeX``
      :Pass: secondary entries present, or zero entries returned (valid for single-controller subsystem)
      :Skip: controller returns not-supported/invalid

4. **Extended Identify Structures**

   a. **test_id_uuid** -- read the Identify UUID List.

      :Command: ``nvme id-uuid /dev/nvmeX``
      :Pass: UUID entries with valid format found, or command completed
      :Skip: requires NVMe 1.4+, or controller returns not-supported/invalid

   b. **test_nvm_id_ctrl** -- read the NVM Command Set specific Identify Controller data.

      :Command: ``nvme nvm-id-ctrl /dev/nvmeX``
      :Pass: key fields (VSL, WZSL, WUSL, DMRL, DMRSL) present, or command completed
      :Skip: requires NVMe 2.0+, or controller returns not-supported/invalid

   c. **test_nvm_id_ns** -- read the NVM Command Set specific Identify Namespace data.

      :Command: ``nvme nvm-id-ns /dev/nvmeXnY``
      :Pass: key fields (LBSTM, ELBAF, PID) present, or command completed
      :Skip: requires NVMe 2.0+, no namespace device, or controller returns not-supported/invalid

   d. **test_cmdset_ind_id_ns** -- read the Command Set Independent Identify Namespace data.

      :Command: ``nvme cmdset-ind-id-ns /dev/nvmeXnY``
      :Pass: command completed
      :Skip: requires NVMe 2.0+, no namespace device, or controller returns not-supported/invalid

5. **Domain / Command Set / NVM Set**

   a. **test_id_domain** -- read the Identify Domain List.

      :Command: ``nvme id-domain /dev/nvmeX``
      :Pass: domain capacity fields (dom_cap, unalloc_cap, max_egrp) present, or command completed
      :Skip: requires NVMe 2.0+, or controller returns not-supported/invalid

   b. **test_id_iocs** -- read the Identify I/O Command Set data structure.

      :Command: ``nvme id-iocs /dev/nvmeX -c 0``
      :Pass: command completed
      :Skip: requires NVMe 2.0+, or controller returns not-supported/invalid

   c. **test_id_nvmset** -- read the Identify NVM Set List.

      :Command: ``nvme id-nvmset /dev/nvmeX``
      :Pass: NVM set entries present, or command completed
      :Skip: requires NVMe 1.4+, or controller returns not-supported/invalid

   d. **test_id_ns_granularity** -- read the Identify Namespace Granularity List.

      :Command: ``nvme id-ns-granularity /dev/nvmeX``
      :Pass: NUMD/NSG/NCG fields present, or command completed
      :Skip: requires NVMe 1.4+, or controller returns not-supported/invalid

6. **LBA Format / Endurance Group**

   a. **test_id_ns_lba_format** -- read the Identify Namespace LBA Format data.

      :Command: ``nvme id-ns-lba-format /dev/nvmeXnY``
      :Pass: format entries accessible
      :Skip: requires NVMe 2.0+, no namespace device, or controller returns not-supported/invalid

   b. **test_list_endgrp** -- list Endurance Group identifiers.

      :Command: ``nvme list-endgrp /dev/nvmeX``
      :Pass: endurance group IDs found, or command completed
      :Skip: requires NVMe 2.0+, or controller returns not-supported/invalid

   c. **test_nvm_id_ns_lba_format** -- read the NVM Command Set specific Namespace LBA Format data.

      :Command: ``nvme nvm-id-ns-lba-format /dev/nvmeXnY``
      :Pass: extended format data accessible
      :Skip: requires NVMe 2.0+, no namespace device, or controller returns not-supported/invalid

7. **Summary**

   - Report total PASS / FAIL / SKIP / WARN counts
   - Exit with non-zero status if any FAIL

Result Codes
------------

- **PASS** -- check succeeded, device conforms to spec
- **FAIL** -- device non-compliance with NVMe specification
- **SKIP** -- test not applicable (version gate, missing feature, no namespace device)
- **WARN** -- advisory condition, not a hard failure
