# Sia scenario test environment

This environment is used to test optimization proposed for Sia.

The build environment uses following defaults:

```dotenv
RUNTIME_TOOLS_IMAGE=sia-lab-runtime-tools:bookworm
SKIP_IMAGE_BUILD=0
SIA_API_PASSWORD=lab-api-password
BOOTSTRAP_TIMEOUT_SECONDS=7200
SCENARIO_TIMEOUT_SECONDS=1800
SCENARIO_RELEASE_TIMEOUT_SECONDS=900
RUNNER_READY_TIMEOUT_SECONDS=7200
```

## Required resources

The setup presented below was based on physical capabilities of the machine used by the author of the optimization proposal.

| CPU | RAM | Free disk |
|:---:|:---:|:---:|
| 8 threads | 24 GB | 750 GB |

## Run the scenario

Copy product of sia-build-env into `bin/` folder and extract its contents, then run a scenario:

```bash
./run.sh 1
```

## Scenario description

Scenario 1 behavior (example):

All eight nodes are started and reach height 200 before injecting:

- `node03` host: 650 ms delay with jitter for 18 seconds;
- `node04` host: complete network interruption for 20 seconds;
- `node05` host: primary hostd process paused for 14 seconds;
- `node06` host: 18% packet loss for 18 seconds;
- `node07`: mines block 201 while those host faults are active.

Every node must recover and reach height 201 before the scenario succeeds.

## Notes

* It is recommended to build the binaries and run the tests on the same machine.
* Nodes do not have access to the Internet after setup.
* Each node uses one CPU and ~3 GB of memory.
* Runtime chain data is temporary and stored on bounded tmpfs mounts.
