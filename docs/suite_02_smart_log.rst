Suite 2: SMART / Health Information Log
=======================================

**Script:** ``nvme_smart_log_test/nvme_smart_log_verify.sh``
**Category:** Read-Only
**NVMe Command:** ``nvme smart-log``

Overview
--------

Validates all mandatory and optional fields in the NVMe SMART / Health
Information Log (NVMe Base Specification, Revision 2.1+, Section 5.2.13 (2.4)
/ 5.1.12 (2.1), Figure 214 (2.4) / 206 (2.1)). Each field is checked for
presence and plausible values.  Cross-validation tests compare SMART counters
against Identify Controller thresholds and Error Information Log entries to
detect inconsistencies.  On NVMe 2.4+ controllers, new extended fields (OLEC,
IPM, INFW) are tested when nvme-cli exposes them.

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
   - Retrieve SMART log (``nvme smart-log /dev/nvmeX``)
   - Initialize logging

2. **Critical Warning & Temperature**

   a. **test_critical_warning** -- Verify critical_warning field is present and decode all 5 warning bits (spare, temp, reliability, read-only, volatile backup).

      :Command: ``nvme smart-log /dev/nvmeX``
      :Pass: critical_warning field is present
      :Fail: critical_warning not present

   b. **test_temperature** -- Verify composite temperature is reported and non-zero; cross-check against WCTEMP.

      :Pass: temperature is present and non-zero (Kelvin value parsed)
      :Fail: temperature not present or zero

   c. **test_available_spare** -- Verify available spare percentage is reported.

      :Pass: available_spare field is present
      :Fail: available_spare not present

   d. **test_available_spare_threshold** -- Verify available spare threshold percentage is reported.

      :Pass: available_spare_threshold field is present
      :Fail: available_spare_threshold not present

   e. **test_percentage_used** -- Verify percentage used is reported.

      :Pass: percentage_used field is present
      :Fail: percentage_used not present

3. **Data Units & Host Commands**

   a. **test_data_units_read** -- Verify Data Units Read counter is reported.

      :Pass: Data Units Read field is present
      :Fail: Data Units Read not present

   b. **test_data_units_written** -- Verify Data Units Written counter is reported.

      :Pass: Data Units Written field is present
      :Fail: Data Units Written not present

   c. **test_host_read_commands** -- Verify host read command counter is reported.

      :Pass: host_read_commands field is present
      :Fail: host_read_commands not present

   d. **test_host_write_commands** -- Verify host write command counter is reported.

      :Pass: host_write_commands field is present
      :Fail: host_write_commands not present

4. **Controller Lifecycle**

   a. **test_controller_busy_time** -- Verify controller busy time counter is reported.

      :Pass: controller_busy_time field is present
      :Fail: controller_busy_time not present

   b. **test_power_cycles** -- Verify power cycle count is reported.

      :Pass: power_cycles field is present
      :Fail: power_cycles not present

   c. **test_power_on_hours** -- Verify power-on hours counter is reported.

      :Pass: power_on_hours field is present
      :Fail: power_on_hours not present

   d. **test_unsafe_shutdowns** -- Verify unsafe shutdown count is reported.

      :Pass: unsafe_shutdowns field is present
      :Fail: unsafe_shutdowns not present

   e. **test_media_errors** -- Verify media and data integrity error count is reported.

      :Pass: media_errors field is present
      :Fail: media_errors not present

   f. **test_num_err_log_entries** -- Verify number of error log entries counter is reported.

      :Pass: num_err_log_entries field is present
      :Fail: num_err_log_entries not present

5. **Temperature History & Thermal Management**

   a. **test_warning_temp_time** -- Verify Warning Temperature Time is reported.

      :Pass: Warning Temperature Time field is present
      :Fail: Warning Temperature Time not present

   b. **test_critical_comp_temp_time** -- Verify Critical Composite Temperature Time is reported.

      :Pass: Critical Composite Temperature Time field is present
      :Fail: Critical Composite Temperature Time not present

   c. **test_temp_sensors** -- Check how many optional temperature sensors (1-8) are present.

      :Pass: at least one temperature sensor is present
      :Skip: no optional temperature sensors found

   d. **test_thm_t1_trans_count** -- Verify Thermal Management T1 Transition Count is reported.

      :Pass: Thermal Management T1 Trans Count field is present
      :Fail: field not present
      :Skip: controller is pre-NVMe 1.3

   e. **test_thm_t2_trans_count** -- Verify Thermal Management T2 Transition Count is reported.

      :Pass: Thermal Management T2 Trans Count field is present
      :Fail: field not present
      :Skip: controller is pre-NVMe 1.3

   f. **test_thm_t1_total_time** -- Verify Thermal Management T1 Total Time is reported.

      :Pass: Thermal Management T1 Total Time field is present
      :Fail: field not present
      :Skip: controller is pre-NVMe 1.3

   g. **test_thm_t2_total_time** -- Verify Thermal Management T2 Total Time is reported.

      :Pass: Thermal Management T2 Total Time field is present
      :Fail: field not present
      :Skip: controller is pre-NVMe 1.3

6. **NVMe 2.4 Extended SMART Fields**

   a. **test_olec** -- Check for Outstanding LBA Error Count (OLEC) field,
      new in NVMe 2.4 (bytes 544+).

      :Pass: OLEC value is reported
      :Skip: NVMe < 2.4, or field not in nvme-cli output (needs newer nvme-cli)

   b. **test_ipm** -- Check for Idle Power Mode (IPM) field, new in NVMe 2.4.

      :Pass: IPM value is reported
      :Skip: NVMe < 2.4, or field not in nvme-cli output

   c. **test_infw** -- Check for Informational NVM Firmware Warnings (INFW)
      field, new in NVMe 2.4.

      :Pass: INFW value is reported
      :Skip: NVMe < 2.4, or field not in nvme-cli output

7. **Cross-Validation Checks**

   a. **test_spare_vs_threshold** -- Cross-check available_spare against available_spare_threshold and critical_warning bit 0.

      :Pass: spare >= threshold with bit 0 clear, or spare < threshold with bit 0 set
      :Fail: spare < threshold but critical_warning bit 0 not set
      :Skip: fields not available

   b. **test_temp_vs_wctemp** -- Cross-check composite temperature against WCTEMP and critical_warning bit 1.

      :Pass: temp < WCTEMP with bit 1 clear, or temp >= WCTEMP with bit 1 set
      :Warn: temp >= WCTEMP but critical_warning bit 1 not set
      :Skip: temperature or WCTEMP not available

   c. **test_temperature_range** -- Verify composite temperature falls within typical 250K-400K range.

      :Pass: temperature is within 250K-400K
      :Warn: temperature outside typical range
      :Skip: temperature not parseable

   d. **test_percentage_used_warning** -- Check if percentage_used exceeds 100% (past rated endurance).

      :Pass: percentage_used <= 100%
      :Warn: percentage_used > 100%
      :Skip: percentage_used not available

   e. **test_num_err_cross_validate** -- Cross-check num_err_log_entries against actual error-log entry count.

      :Command: ``nvme error-log /dev/nvmeX``
      :Pass: SMART error count and error-log entry count are consistent
      :Warn: SMART reports 0 errors but error-log has entries
      :Skip: could not read error-log

8. **Summary**

   - Report total PASS / FAIL / SKIP / WARN counts
   - Exit with non-zero status if any FAIL

Result Codes
------------

- **PASS** -- check succeeded, device conforms to spec
- **FAIL** -- device non-compliance with NVMe specification
- **SKIP** -- test not applicable (version gate, missing feature)
- **WARN** -- advisory condition, not a hard failure
