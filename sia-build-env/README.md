# Sia binary build environment

This environment compiles Sia executables and exports them as a portable archive for the test environment. It builds unmodified and modified renterd from separate Go workspaces so their identical module paths cannot shadow each other.

The build environment uses following defaults:

```dotenv
GO_BUILDER_IMAGE=golang:1.26-bookworm
AUTO_PULL_BUILDER_IMAGE=1
GO_DEPENDENCY_PROXY=https://proxy.golang.org,direct
GO_DEPENDENCY_SUMDB=sum.golang.org
RUN_GO_GENERATE=1
APPLY_LAB_NETWORK_PATCH=1
SIA_BUILD_STATIC=1
```

## Recommended resources

| CPU | RAM | Swap | Free disk |
|:---:|:---:|:---:|:---:|
| 2 threads | 4 GB | 2-4 GB optional | 15-20 GB |

Practical verification:
Build was done on a machine with 32 GB RAM, 12 CPU cores and around 800 GB of free disk space - it was done with 4 parallel jobs and took around 2 minutes.

## Build

1. Place repositories in `src/` folder

2. Run

```bash
./build.sh \
  --core NAME \
  --coreutils NAME \
  --hostd NAME \
  --renterd-unmodified NAME \
  --renterd-modified NAME \
  --walletd NAME \
  --build-jobs N
```

`--renterd` remains available as an alias for `--renterd-unmodified`. The build rejects swapped renterd inputs by checking for the proposal's `slabRisk` configuration extension before and after compilation.

3. After a successful build, the `bin/` directory shall contain:

```text
bin/sia-binaries.tar.gz
```

which contains:

```text
BUILD_TAG
BUILD_MANIFEST
SHA256SUMS
hostd
renterd-unmodified
renterd-modified
walletd
```

`BUILD_MANIFEST` records the source directory assigned to every artifact, and `SHA256SUMS` is checked during packaging and again by the test runner.
