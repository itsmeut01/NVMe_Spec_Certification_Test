Suite 10: Get Features
======================

**Script:** ``nvme_get_feature_test/nvme_get_feature_verify.sh``
**Category:** Read-Only
**NVMe Command:** ``nvme get-feature``

Overview
--------

Validates the NVMe Get Features command by querying a range of mandatory and
optional Feature Identifiers (FIDs) and verifying that the returned values are
well-formed, within spec-defined ranges, and consistent with Identify Controller
capability bits.  Tested features include Number of Queues, Volatile Write Cache,
Power Management, Temperature Threshold, Error Recovery, Arbitration, Autonomous
Power State Transition, Host Controlled Thermal Management, Interrupt Vector
Configuration, Async Event Configuration, and Keep Alive Timer.  The suite also
confirms graceful error handling when an unsupported FID is requested.

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
   - Cache Identify Controller data (``nvme id-ctrl``)
   - Initialize logging

2. **Queue Configuration**

   a. **test_num_queues** -- Query FID 0x07 (Number of Queues) and extract
      NSQA (number of submission queues allocated) and NCQA (number of
      completion queues allocated).

      :Command: ``nvme get-feature /dev/nvmeX -f 0x07``
      :Pass: Both NSQA and NCQA are > 0
      :Fail: Either queue count is zero, or result cannot be parsed
      :Skip: Feature not accessible (error response)

   b. **test_num_queues_reasonable** -- Verify that NSQA and NCQA from
      FID 0x07 are within the valid range (0--65534).

      :Pass: Both values are <= 65534
      :Fail: Either value exceeds 65534
      :Skip: Feature could not be read

3. **Write Cache & Power**

   a. **test_volatile_wc** -- Query FID 0x06 (Volatile Write Cache) and
      cross-check the WCE (Write Cache Enable) bit against the VWC field in
      Identify Controller.

      :Command: ``nvme get-feature /dev/nvmeX -f 0x06``
      :Pass: WCE bit is consistent with id-ctrl VWC present bit
      :Warn: id-ctrl reports VWC not present but WCE=1
      :Skip: VWC not present per id-ctrl, or feature could not be read

   b. **test_power_mgmt** -- Query FID 0x02 (Power Management) and verify
      the current power state (PS) is within 0..NPSS.

      :Command: ``nvme get-feature /dev/nvmeX -f 0x02``
      :Pass: Current PS is <= NPSS (or PS reported when NPSS unavailable)
      :Fail: Current PS exceeds NPSS
      :Skip: Feature could not be read

4. **Temperature & Error Recovery**

   a. **test_temp_thresh** -- Query FID 0x04 (Temperature Threshold) and
      report the configured threshold in Kelvin and Celsius.

      :Command: ``nvme get-feature /dev/nvmeX -f 0x04``
      :Pass: Threshold value is returned (non-zero or zero/not-configured)
      :Skip: Feature could not be read

   b. **test_err_recovery** -- Query FID 0x05 (Error Recovery) and report
      the TLER (Time Limited Error Recovery) value.

      :Command: ``nvme get-feature /dev/nvmeX -f 0x05``
      :Pass: TLER value is returned (non-zero timeout or zero/unlimited)
      :Skip: Feature could not be read

5. **Arbitration & Advanced Features**

   a. **test_arbitration** -- Query FID 0x01 (Arbitration) and extract the
      Arbitration Burst (AB), Low/Medium/High Priority Weight fields.

      :Command: ``nvme get-feature /dev/nvmeX -f 0x01``
      :Pass: All arbitration fields are parsed and reported
      :Skip: Feature could not be read

   b. **test_auto_pst** -- Query FID 0x0C (Autonomous Power State
      Transition) and report the APSTE (enable) bit.

      :Command: ``nvme get-feature /dev/nvmeX -f 0x0c``
      :Pass: APSTE bit is read and reported (enabled or disabled)
      :Skip: NVMe version below 1.3, APSTA not supported per id-ctrl, or
             feature could not be read

   c. **test_hctm** -- Query FID 0x10 (Host Controlled Thermal Management)
      and report TMT1 and TMT2 threshold values in Kelvin.

      :Command: ``nvme get-feature /dev/nvmeX -f 0x10``
      :Pass: TMT1/TMT2 values are returned (non-zero or not configured)
      :Skip: NVMe version below 1.3, HCTMA not supported per id-ctrl, or
             feature could not be read

6. **Interrupt, AER Config & Keep Alive**

   a. **test_interrupt_vector_config** -- Query FID 0x09 (Interrupt Vector
      Configuration) and report the Coalescing Disable (CD) bit for vector 0.

      :Command: ``nvme get-feature /dev/nvmeX -f 0x09``
      :Pass: CD bit value is reported
      :Skip: Feature not supported, or result could not be parsed

   b. **test_async_event_config** -- Query FID 0x0B (Async Event
      Configuration) and extract the SMART/Critical Warning mask, Namespace
      Attribute, and Firmware Activation notice bits.

      :Command: ``nvme get-feature /dev/nvmeX -f 0x0b``
      :Pass: Configuration bits are parsed and reported
      :Fail: Feature could not be read (mandatory feature)

   c. **test_keep_alive_timer** -- Query FID 0x0F (Keep Alive Timer) and
      report the KATO value in milliseconds, gated on KAS support from
      Identify Controller.

      :Command: ``nvme get-feature /dev/nvmeX -f 0x0f``
      :Pass: KATO value is reported
      :Skip: KAS = 0 (Keep Alive not supported), or feature could not be read

7. **NVM CS 1.3 Features (NVMe 2.0+)**

   a. **test_perf_characteristics** -- Query FID 0x1C (Performance
      Characteristics) from NVM Command Set Specification 1.3.

      :Command: ``nvme get-feature /dev/nvmeX -f 0x1c``
      :Pass: Feature result is readable
      :Skip: NVMe < 2.0, or not supported by controller

   b. **test_rate_limiting** -- Query FID 0x28 (Rate Limiting) from NVM
      Command Set Specification 1.3.

      :Command: ``nvme get-feature /dev/nvmeX -f 0x28``
      :Pass: Feature result is readable
      :Skip: NVMe < 2.0, or not supported by controller

8. **NVMe 2.4 Power & Voltage Features**

   a. **test_cdp** -- Query FID 0x22 (Configurable Device Personality).

      :Command: ``nvme get-feature /dev/nvmeX -f 0x22``
      :Pass: Feature result is readable
      :Skip: NVMe < 2.4, or not supported by controller

   b. **test_power_limit** -- Query FID 0x23 (Power Limit).

      :Command: ``nvme get-feature /dev/nvmeX -f 0x23``
      :Pass: Feature result is readable
      :Skip: NVMe < 2.4, or not supported by controller

   c. **test_power_threshold** -- Query FID 0x24 (Power Threshold).

      :Command: ``nvme get-feature /dev/nvmeX -f 0x24``
      :Pass: Feature result is readable
      :Skip: NVMe < 2.4, or not supported by controller

   d. **test_power_measurement** -- Query FID 0x25 (Power Measurement).

      :Command: ``nvme get-feature /dev/nvmeX -f 0x25``
      :Pass: Feature result is readable
      :Skip: NVMe < 2.4, or not supported by controller

   e. **test_voltage_threshold** -- Query FID 0x26 (Voltage Threshold).

      :Command: ``nvme get-feature /dev/nvmeX -f 0x26``
      :Pass: Feature result is readable
      :Skip: NVMe < 2.4, or not supported by controller

   f. **test_voltage_measurement** -- Query FID 0x27 (Voltage Measurement).

      :Command: ``nvme get-feature /dev/nvmeX -f 0x27``
      :Pass: Feature result is readable
      :Skip: NVMe < 2.4, or not supported by controller

9. **Error Handling**

   a. **test_feature_error_handling** -- Issue a Get Feature request with an
      unsupported FID (0xFF) and verify the controller handles it gracefully
      without crashing.

      :Command: ``nvme get-feature /dev/nvmeX -f 0xFF``
      :Pass: Controller returns an error or empty output without crashing

10. **Summary**

   - Report total PASS / FAIL / SKIP / WARN counts
   - Exit with non-zero status if any FAIL

Result Codes
------------

- **PASS** -- check succeeded, device conforms to spec
- **FAIL** -- device non-compliance with NVMe specification
- **SKIP** -- test not applicable (version gate, missing feature)
- **WARN** -- advisory condition, not a hard failure
