Suite 8: Supported Log Pages
=============================

**Script:** ``nvme_supported_logs_test/nvme_supported_logs_verify.sh``
**Category:** Read-Only
**NVMe Command:** ``nvme supported-log-pages``

Overview
--------

Verifies the Supported Log Pages log (an NVMe 2.0+ feature) by running
``nvme supported-log-pages`` and confirming that all mandatory log page
identifiers are reported.  The suite also cross-checks conditional log pages
(Device Self-test, Commands Supported and Effects) against their corresponding
capability bits in Identify Controller (OACS bit 4, LPA bit 1).  The entire
suite is skipped on controllers reporting an NVMe version below 2.0.

Prerequisites
-------------

- Root privileges (``sudo``)
- ``nvme-cli`` installed
- NVMe device (e.g., ``/dev/nvme0``)
- NVMe specification version 2.0 or later (suite skips otherwise)

Test Steps
----------

1. **Preflight & Setup**

   - Verify root privileges and ``nvme-cli`` availability
   - Resolve target controller device (auto-detect or user-specified)
   - Cache Identify Controller data (``nvme id-ctrl``)
   - Check NVMe version is >= 2.0; skip entire suite if not
   - Initialize logging
   - Run ``nvme supported-log-pages /dev/nvmeX`` to capture output

2. **Command Access**

   a. **test_supported_logs_command** -- Confirm that
      ``nvme supported-log-pages`` executes and produces valid output.

      :Command: ``nvme supported-log-pages /dev/nvmeX``
      :Pass: Command returns non-empty output without error indicators
      :Skip: Output is empty, or contains error/unsupported messages

3. **Mandatory Log Pages**

   a. **test_error_info_log_listed** -- Verify LID 0x01 (Error Information
      Log) appears in the supported log pages output.

      :Pass: LID 0x01 is listed
      :Fail: LID 0x01 is not found

   b. **test_smart_health_log_listed** -- Verify LID 0x02 (SMART / Health
      Information Log) appears in the supported log pages output.

      :Pass: LID 0x02 is listed
      :Fail: LID 0x02 is not found

   c. **test_fw_slot_log_listed** -- Verify LID 0x03 (Firmware Slot
      Information Log) appears in the supported log pages output.

      :Pass: LID 0x03 is listed
      :Fail: LID 0x03 is not found

   d. **test_changed_ns_list_log_listed** -- Verify LID 0x04 (Changed
      Namespace List Log) appears in the supported log pages output.

      :Pass: LID 0x04 is listed
      :Fail: LID 0x04 is not found

   e. **test_cmd_effects_log_listed** -- Verify LID 0x05 (Commands Supported
      and Effects Log) appears in the supported log pages output.

      :Pass: LID 0x05 is listed
      :Fail: LID 0x05 is not found

4. **Conditional Log Pages**

   a. **test_dst_log_if_supported** -- If Device Self-test is supported
      (OACS bit 4 = 1), verify LID 0x06 (Device Self-test Log) is listed.

      :Pass: LID 0x06 listed and OACS bit 4 = 1
      :Warn: OACS bit 4 = 1 but LID 0x06 not found in supported-log-pages
      :Skip: DST not supported (OACS bit 4 = 0), or OACS not available

   b. **test_cmd_effects_if_supported** -- If Command Effects Log is
      supported (LPA bit 1 = 1), verify LID 0x05 is listed.

      :Pass: LID 0x05 listed and LPA bit 1 = 1
      :Warn: LPA bit 1 = 1 but LID 0x05 not found in supported-log-pages
      :Skip: LPA bit 1 = 0, or LPA not available

   c. **test_endurance_group_log_if_supported** -- If Endurance Groups are
      supported (CTRATT bit 4 = 1), verify LID 0x09 is listed.

      :Pass: LID 0x09 listed and CTRATT bit 4 = 1
      :Warn: CTRATT bit 4 = 1 but LID 0x09 not found
      :Skip: CTRATT bit 4 = 0, or CTRATT not available

5. **NVM CS 1.3 / PCIe Transport 1.4 Log Pages**

   a. **test_rate_limiting_log_if_nvm_cs** -- Check if LID 0x28 (Rate
      Limiting Log) is listed on NVMe 2.0+ controllers.

      :Pass: LID 0x28 is listed
      :Skip: NVMe < 2.0, or optional log not listed

   b. **test_eom_log_if_pcie_transport** -- Check if LID 0x19 (Eye Opening
      Measurement Log) is listed, from PCIe Transport Specification 1.4.

      :Pass: LID 0x19 is listed
      :Skip: NVMe < 2.0, or optional transport log not listed

6. **NVMe 2.4 Log Pages**

   a. **test_power_measurement_log_if_24** -- Check if LID 0x17 (Power
      Measurement Log) is listed on NVMe 2.4+ controllers.

      :Pass: LID 0x17 is listed
      :Skip: NVMe < 2.4, or optional log not listed

   b. **test_voltage_measurement_log_if_24** -- Check if LID 0x18 (Voltage
      Measurement Log) is listed on NVMe 2.4+ controllers.

      :Pass: LID 0x18 is listed
      :Skip: NVMe < 2.4, or optional log not listed

7. **Summary**

   a. **test_supported_logs_summary** -- Report the total number of
      supported log pages parsed from the output.

      :Pass: Count is reported (always passes)

6. **Summary**

   - Report total PASS / FAIL / SKIP / WARN counts
   - Exit with non-zero status if any FAIL

Result Codes
------------

- **PASS** -- check succeeded, device conforms to spec
- **FAIL** -- device non-compliance with NVMe specification
- **SKIP** -- test not applicable (version gate, missing feature)
- **WARN** -- advisory condition, not a hard failure
