NVMe Certification Test Suite — Test Plans
============================================

This documentation describes each test suite's sequential execution steps,
the NVMe commands issued, and the pass/fail criteria for every check.

.. contents:: Table of Contents
   :depth: 2
   :local:

Overview
--------

The NVMe Certification Test Suite contains **27 test suites** with **~399 individual tests**
that validate NVMe devices against the NVMe Base Specification (versions 1.0 through 2.1).

Tests are organized into three categories:

- **Read-Only** (Suites 1-12): Never modify device state. Safe to run on any drive.
- **Non-Destructive Functional** (Suites 13-16): May trigger events but do not erase data.
- **Destructive** (Suites 17-27): Modify device state (format, sanitize, reset, etc.).
  Require ``--allow-destructive`` flag and refuse to run on the OS drive.

Result Codes
------------

All suites use KCIDB-compliant result codes:

- **PASS** — Test succeeded, device conforms to NVMe specification
- **FAIL** — Device non-compliance with NVMe specification
- **SKIP** — Test not applicable (NVMe version gate, missing hardware feature)
- **WARN** — Advisory condition, not a hard failure

Read-Only Suites
----------------

.. toctree::
   :maxdepth: 1

   suite_01_id_ctrl
   suite_02_smart_log
   suite_03_error_log
   suite_04_fw_log
   suite_05_id_ns
   suite_06_power_state
   suite_07_show_regs
   suite_08_supported_logs
   suite_09_effects_log
   suite_10_get_feature
   suite_11_ns_descs
   suite_12_self_test_log

Non-Destructive Functional Suites
----------------------------------

.. toctree::
   :maxdepth: 1

   suite_13_dst_functional
   suite_14_async_event
   suite_15_additional_logs
   suite_16_additional_id

Destructive Suites
------------------

.. toctree::
   :maxdepth: 1

   suite_17_feature_set
   suite_18_io
   suite_19_format
   suite_20_sanitize
   suite_21_ns_mgmt
   suite_22_reservation
   suite_23_reset
   suite_24_fw_mgmt
   suite_25_additional_io
   suite_26_security_directives
   suite_27_advanced_admin

Running the Tests
-----------------

.. code-block:: bash

   # Run read-only + non-destructive suites on a specific device
   sudo ./run_all.sh /dev/nvme0

   # Run ALL suites including destructive tests
   sudo ./run_all.sh /dev/nvme0 --destructive

   # Test all NVMe controllers (auto-skips OS drive)
   sudo ./run_all.sh --all
   sudo ./run_all.sh --all --destructive

   # Run a single suite
   sudo ./nvme_id_ctrl_test/nvme_id_ctrl_verify.sh /dev/nvme0
