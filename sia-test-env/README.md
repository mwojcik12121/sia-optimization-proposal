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

## Notes

* It is recommended to build the binaries and run the tests on the same machine.
* Nodes do not have access to the Internet after setup.
* Each node uses one CPU and ~3 GB of memory.
* Runtime chain data is temporary and removed with the Compose project.
* Node logs are exported as `logs/nodeXX_scenarioN_YYYYMMDD_HHMMSS.log`.
