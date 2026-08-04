Suite 6: Power State Descriptors
=================================

**Script:** ``nvme_power_state_test/nvme_power_state_verify.sh``
**Category:** Read-Only
**NVMe Command:** ``nvme id-ctrl``

Overview
--------

Validates the Power State Descriptor data structures embedded in the Identify
Controller response (bytes 2048--3071) per NVMe Base Specification, Revision 2.1,
Section 5.1.13, Figure 313.  Each descriptor reports maximum power, entry/exit
latencies, read/write throughput hints, idle/active power, and the
operational/non-operational flag.  The suite verifies field presence, value
constraints, and cross-field consistency across all declared power states.

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
   - Extract all ``ps N :`` lines from id-ctrl output

2. **Power State Count**

   a. **test_npss_from_id_ctrl** -- Read the NPSS (Number of Power States
      Support) field from Identify Controller.

      :Command: ``nvme id-ctrl /dev/nvmeX``
      :Pass: NPSS field is present and parsed successfully
      :Fail: NPSS field is not found in id-ctrl output

   b. **test_all_ps_descriptors_present** -- Confirm that a ``ps N :`` line
      exists for every power state 0 through NPSS.

      :Pass: All PS 0..NPSS descriptors are present in id-ctrl output
      :Fail: One or more descriptors are missing
      :Skip: NPSS was not available

3. **PS 0 (Default) Validation**

   a. **test_ps0_max_power** -- Verify that Power State 0 reports a non-zero
      maximum power (mp) value.

      :Pass: PS 0 ``mp`` field is non-zero
      :Fail: PS 0 ``mp`` is zero or missing

   b. **test_ps0_operational** -- Verify that Power State 0 is marked as
      operational (NOPS=0, no ``non-operational`` flag).

      :Pass: PS 0 does not contain the ``non-operational`` marker
      :Fail: PS 0 is marked as non-operational

4. **Per-State Fields**

   a. **test_ps_enlat_exlat** -- Check that every power state has both
      ``enlat`` (entry latency) and ``exlat`` (exit latency) fields.

      :Pass: All power states have both enlat and exlat
      :Fail: One or more states are missing enlat or exlat
      :Skip: NPSS not available

   b. **test_ps_rrt_rrl** -- Check that every power state has both ``rrt``
      (relative read throughput) and ``rrl`` (relative read latency) fields.

      :Pass: All power states have both rrt and rrl
      :Fail: One or more states are missing rrt or rrl
      :Skip: NPSS not available

   c. **test_ps_rwt_rwl** -- Check that every power state has both ``rwt``
      (relative write throughput) and ``rwl`` (relative write latency) fields,
      including the continuation line.

      :Pass: All power states have both rwt and rwl
      :Fail: One or more states are missing rwt or rwl
      :Skip: NPSS not available

   d. **test_ps_idle_power** -- Verify that the ``idle_power`` field is present
      in each power state's continuation line.

      :Pass: All (or some) power states have the idle_power field
      :Fail: No power states have the idle_power field
      :Skip: NVMe version is below 1.2, or NPSS not available

   e. **test_ps_active_power** -- Verify that the ``active_power`` field is
      present in each power state's continuation line.

      :Pass: All (or some) power states have the active_power field
      :Fail: No power states have the active_power field
      :Skip: NVMe version is below 1.2, or NPSS not available

5. **Power State Characteristics**

   a. **test_nops_states** -- Count the number of operational vs.
      non-operational power states and report the distribution.

      :Pass: Distribution is reported (always passes with count)
      :Skip: NPSS not available, or only one power state (PS 0)

   b. **test_ps_max_power_decreasing** -- Check whether max power (mp) is
      non-increasing across power states PS 0 through PS NPSS.

      :Pass: Max power is non-increasing, or any increases are noted as
             non-monotonic but potentially valid
      :Skip: NPSS not available, or only one power state

6. **Deep Validation**

   a. **test_ps_idle_le_max** -- Verify that idle_power does not exceed
      max_power (mp) within each power state.

      :Pass: idle_power <= max_power in all states checked
      :Fail: One or more states have idle_power > max_power
      :Skip: NVMe version below 1.2, NPSS not available, or no states had
             both fields

   b. **test_ps_active_le_max** -- Verify that active_power does not exceed
      max_power (mp) within each power state.

      :Pass: active_power <= max_power in all states checked
      :Fail: One or more states have active_power > max_power
      :Skip: NVMe version below 1.2, NPSS not available, or no states had
             both fields

   c. **test_ps_latency_trend** -- Check that entry and exit latencies are
      generally non-decreasing as power state numbers increase (deeper sleep
      states should have higher latency).

      :Pass: Latencies are non-decreasing across all power states
      :Warn: One or more latency decreases detected between consecutive states
      :Skip: NPSS not available, or fewer than 3 power states

   d. **test_apste_consistency** -- Read the APSTA field from Identify
      Controller to determine whether Autonomous Power State Transitions are
      supported.

      :Pass: APSTA field is read and its bit 0 value is reported
      :Skip: NVMe version below 1.3, or APSTA not present in id-ctrl

7. **Summary**

   - Report total PASS / FAIL / SKIP / WARN counts
   - Exit with non-zero status if any FAIL

Result Codes
------------

- **PASS** -- check succeeded, device conforms to spec
- **FAIL** -- device non-compliance with NVMe specification
- **SKIP** -- test not applicable (version gate, missing feature)
- **WARN** -- advisory condition, not a hard failure
