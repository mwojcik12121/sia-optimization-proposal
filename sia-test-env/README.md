# Sia scenario test environment

This environment is used to test optimization proposed for Sia.

The build environment uses following defaults:

```dotenv
RUNTIME_TOOLS_IMAGE=sia-lab-runtime-tools:bookworm
SKIP_IMAGE_BUILD=0
SIA_API_PASSWORD=lab-api-password
BOOTSTRAP_TIMEOUT_SECONDS=7200
SCENARIO_TIMEOUT_SECONDS=2400
SCENARIO_RELEASE_TIMEOUT_SECONDS=900
RUNNER_READY_TIMEOUT_SECONDS=7200
SCENARIO_SETUP_BLOCKS=40
SCENARIO_BLOCKS=240
SCENARIO_DRAIN_BLOCKS=80
SCENARIO_MINE_INTERVAL_SECONDS=4
SCENARIO_TRANSFER_TIMEOUT_SECONDS=45
```

## Required resources

The setup presented below was based on physical capabilities of the machine used by the author of the optimization proposal.

| CPU | RAM | Free disk |
|:---:|:---:|:---:|
| 8 threads | 24 GB | 750 GB |

## Run the scenario

Copy the product of `sia-build-env` into `bin/`, extract it, then run a scenario:

```bash
tar -C bin -xzf bin/sia-binaries.tar.gz
./run.sh 1
```

The runner verifies the archive checksums and feature markers before building any node images. `node01` always receives `renterd-modified`; `node02` always receives `renterd-unmodified`. The container entrypoint checks this assignment again before writing configuration or starting renterd.

## Scenario description

Scenario 1 starts all eight nodes and synchronizes them at height 200. It then:

- funds both renter wallets and all four host wallets;
- gives every host a writable volume, enables contracts, and announces
  `node03` through `node06` on the private chain;
- configures each renter for four contracts and 2-of-4 slabs, then uploads and
  verifies a 12 MiB object before host faults are allowed to start;
- lets only `node07` mine the bounded setup allowance, and opens the workload
  window only after both objects exist and every host reports two active,
  data-bearing contracts;
- has `node01`, `node02`, `node04`, and `node06` continuously create storage or
  wallet traffic while `node07` and `node08` alternate mining blocks;
- repeatedly applies delay, complete network interruption, and a temporary
  `hostd` pause to the odd-numbered hosts, `node03` and `node05`; and
- repeatedly triggers renter maintenance on both variants. Both use a 10-second
  heartbeat and scanner interval. On `node01`, modified renterd additionally
  enables risk enforcement with a 30-second risk-model TTL; `node02` remains
  the unmodified fixed-health control.

After setup, all nodes synchronize at the fixed workload start height. They
remain active for another `SCENARIO_BLOCKS`, recover to the target height, and
then enter an `SCENARIO_DRAIN_BLOCKS` grace window. The two miners keep
alternating during the drain while every other node resets faults and finishes
any in-flight transfer or API call. Setup must complete within
`SCENARIO_SETUP_BLOCKS`, so it cannot consume the fault-observation window; the
default 80-block drain lasts about 320 seconds.
The drain length and mining interval are validated together with the transfer
timeout so an override cannot shorten the grace period below one full in-flight
workload iteration. After the drain, `node07` mines one settlement block and
all non-renter nodes must report the same final tip ID.

## Notes

* It is recommended to build the binaries and run the tests on the same machine.
* Nodes do not have access to the Internet after setup.
* Each node uses one CPU and ~3 GB of memory.
* Runtime chain data is temporary and removed with the Compose project.
* Node logs are exported as `logs/nodeXX_scenarioN_YYYYMMDD_HHMMSS.log`.
* Log timestamps use the current Docker host's local time zone. The host's `/etc/localtime` is mounted read-only into each node so native and test-harness messages use the same clock.
