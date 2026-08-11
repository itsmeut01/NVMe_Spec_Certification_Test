Suite 15: Additional Log Pages
==============================

**Script:** ``nvme_additional_logs_test/nvme_additional_logs_verify.sh``
**Category:** Non-Destructive Functional / Read-Only
**NVMe Command:** ``nvme telemetry-log``, ``nvme persistent-event-log``, ``nvme endurance-log``, ``nvme changed-ns-list-log``, ``nvme resv-notif-log``, ``nvme fid-support-effects-log``, ``nvme lba-status-log``, ``nvme predictable-lat-log``, ``nvme boot-part-log``, ``nvme endurance-event-agg-log``

Overview
--------

Validates additional NVMe log pages through both behavioral and read-only
verification. The behavioral portion exercises the Telemetry Host-Initiated log
lifecycle (generate, verify header, re-read existing, and read controller-initiated)
and the Persistent Event Log lifecycle (establish context, read, release, and verify
release). The read-only portion probes accessibility of Endurance Group Info,
Changed Namespace List, Reservation Notification, FID Support and Effects, LBA
Status Information, Predictable Latency, Boot Partition, and Endurance Group Event
Aggregate log pages. Temporary files are created for telemetry data and cleaned up
on exit.

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
   - Create temporary directory for telemetry binary files
   - Initialize logging

2. **Telemetry (Behavioral: generate -> verify -> read)**

   a. **test_telemetry_generate** -- generate a host-initiated telemetry snapshot to a binary file.

      :Command: ``nvme telemetry-log /dev/nvmeX -O <tmpfile> -g 1 -d 1``
      :Pass: telemetry binary file created and non-empty
      :Fail: file not created or empty
      :Skip: requires NVMe 1.3+, or controller returns not-supported/error

   b. **test_telemetry_verify_header** -- verify the telemetry header Log Page Identifier (LPI) byte.

      :Command: ``od`` on first byte of generated telemetry binary file
      :Pass: LPI is 0x08 (Host-Initiated Telemetry)
      :Warn: LPI is not 0x08, or file is smaller than 512 bytes
      :Skip: requires NVMe 1.3+, or no telemetry data was generated

   c. **test_telemetry_read_existing** -- re-read existing telemetry context without generating a new snapshot.

      :Command: ``nvme telemetry-log /dev/nvmeX -O <tmpfile> -g 0 -d 1``
      :Pass: telemetry binary file created and non-empty
      :Warn: no data returned
      :Skip: requires NVMe 1.3+, no prior data, or controller returns not-supported

   d. **test_telemetry_controller_initiated** -- read the controller-initiated telemetry log.

      :Command: ``nvme telemetry-log /dev/nvmeX -O <tmpfile> -c -d 1``
      :Pass: telemetry binary file created and non-empty, or command completed
      :Skip: requires NVMe 1.3+, or controller returns not-supported/error

3. **Persistent Event Log (Behavioral: establish -> read -> release)**

   a. **test_persistent_event_establish** -- establish a Persistent Event Log context.

      :Command: ``nvme persistent-event-log /dev/nvmeX -a 1``
      :Pass: command completes without error
      :Warn: command returns non-INVALID error
      :Skip: requires NVMe 1.4+, or controller returns invalid-field/not-supported

   b. **test_persistent_event_read** -- read the Persistent Event Log header.

      :Command: ``nvme persistent-event-log /dev/nvmeX -a 0 -l 512``
      :Pass: output contains header fields (log_revision, tnel, timestamp, num_events) or command completes without error
      :Skip: requires NVMe 1.4+, or controller returns not-supported

   c. **test_persistent_event_release** -- release the Persistent Event Log context.

      :Command: ``nvme persistent-event-log /dev/nvmeX -a 2``
      :Pass: command completes without error
      :Warn: command returns non-INVALID error
      :Skip: requires NVMe 1.4+, or controller returns invalid/not-supported

   d. **test_persistent_event_verify_release** -- verify the context is no longer readable after release.

      :Command: ``nvme persistent-event-log /dev/nvmeX -a 0 -l 512``
      :Pass: read fails (context correctly released) or post-release state verified
      :Warn: data still readable after release (controller may retain context)
      :Skip: requires NVMe 1.4+

4. **Read-Only Log Pages**

   a. **test_endurance_group_log** -- read the Endurance Group Information log page.

      :Command: ``nvme endurance-log /dev/nvmeX -g 0``
      :Pass: output contains key fields (critical_warning, avail_spare, percent_used) or command completes
      :Skip: requires NVMe 1.3+, or controller returns not-supported/invalid

   b. **test_changed_ns_list_log** -- read the Changed Namespace List log page.

      :Command: ``nvme changed-ns-list-log /dev/nvmeX``
      :Pass: command completes without error
      :Skip: requires NVMe 1.2+, or controller returns error/invalid

   c. **test_resv_notif_log** -- read the Reservation Notification log page.

      :Command: ``nvme resv-notif-log /dev/nvmeX``
      :Pass: output contains key fields (count, type, nsid) or command completes
      :Skip: controller returns not-supported/invalid

   d. **test_fid_support_effects_log** -- read the FID Support and Effects log and verify mandatory FIDs are listed.

      :Command: ``nvme fid-support-effects-log /dev/nvmeX``
      :Pass: all 5 mandatory FIDs present (0x01 Arbitration, 0x02 Power Management, 0x04 Temperature Threshold, 0x07 Number of Queues, 0x0B Async Event Config)
      :Fail: empty output
      :Warn: some mandatory FIDs missing or output format does not match expected patterns
      :Skip: requires NVMe 2.0+, or controller returns not-supported/invalid

   e. **test_lba_status_log** -- read the LBA Status Information log page.

      :Command: ``nvme lba-status-log /dev/nvmeX``
      :Pass: command completes and log is accessible
      :Skip: requires NVMe 1.4+, or controller returns not-supported/invalid

   f. **test_predictable_lat_log** -- read the Predictable Latency Per NVM Set log page.

      :Command: ``nvme predictable-lat-log /dev/nvmeX -n 1``
      :Pass: command completes and log is accessible
      :Skip: requires NVMe 1.4+, or controller returns not-supported/invalid

   g. **test_boot_partition_log** -- read the Boot Partition log page.

      :Command: ``nvme boot-part-log /dev/nvmeX``
      :Pass: command completes and log is accessible
      :Skip: requires NVMe 1.4+, or controller returns not-supported/invalid

   h. **test_endurance_event_agg_log** -- read the Endurance Group Event Aggregate log page.

      :Command: ``nvme endurance-event-agg-log /dev/nvmeX``
      :Pass: command completes and log is accessible
      :Skip: requires NVMe 1.4+, or controller returns not-supported/invalid

5. **NVM CS 1.3 / PCIe Transport 1.4 Log Pages**

   a. **test_rate_limiting_log** -- read the Rate Limiting log page (LID 0x28), from NVM CS 1.3.

      :Command: ``nvme get-log /dev/nvmeX -i 0x28 -l 4096``
      :Pass: log data is accessible
      :Skip: NVMe < 2.0, or controller returns not-supported/invalid

   b. **test_eom_log** -- read the Eye Opening Measurement log page (LID 0x19), from PCIe Transport 1.4.

      :Command: ``nvme get-log /dev/nvmeX -i 0x19 -l 4096``
      :Pass: log data is accessible
      :Skip: NVMe < 2.0, or controller returns not-supported/invalid

6. **NVMe 2.4 Log Pages**

   a. **test_power_measurement_log** -- read the Power Measurement log page (LID 0x17), new in NVMe 2.4.

      :Command: ``nvme get-log /dev/nvmeX -i 0x17 -l 512``
      :Pass: log data is accessible
      :Skip: NVMe < 2.4, or controller returns not-supported/invalid

   b. **test_voltage_measurement_log** -- read the Voltage Measurement log page (LID 0x18), new in NVMe 2.4.

      :Command: ``nvme get-log /dev/nvmeX -i 0x18 -l 512``
      :Pass: log data is accessible
      :Skip: NVMe < 2.4, or controller returns not-supported/invalid

   c. **test_cross_controller_reset_log** -- read the Cross-Controller Reset log page (LID 0x1E), new in NVMe 2.4.

      :Command: ``nvme get-log /dev/nvmeX -i 0x1E -l 512``
      :Pass: log data is accessible
      :Skip: NVMe < 2.4, or controller returns not-supported/invalid

   d. **test_lost_host_comm_log** -- read the Lost Host Communication log page (LID 0x1F), new in NVMe 2.4.

      :Command: ``nvme get-log /dev/nvmeX -i 0x1F -l 512``
      :Pass: log data is accessible
      :Skip: NVMe < 2.4, or controller returns not-supported/invalid

7. **Summary**

   - Report total PASS / FAIL / SKIP / WARN counts
   - Exit with non-zero status if any FAIL

Result Codes
------------

- **PASS** -- check succeeded, device conforms to spec
- **FAIL** -- device non-compliance with NVMe specification
- **SKIP** -- test not applicable (version gate, missing feature)
- **WARN** -- advisory condition, not a hard failure
