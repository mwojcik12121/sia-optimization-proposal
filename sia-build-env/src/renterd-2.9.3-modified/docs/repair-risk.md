# Risk-aware Sia slab repair

This fork implements the local scheduling proposal in section 7 of the theory
document. It does not change Sia consensus, contracts, sector proofs, erasure
coding, or the requirement for at least `MinShards` downloadable source shards.
The numerical defaults are illustrative policy values, not fitted guarantees.

## Scheduling

1. Count distinct hosts with good contracts, retaining the released structural
   health `(u-k)/(n-k)` and its no-redundancy special case.
2. Give slabs with `u <= k` emergency priority independently of model validity.
3. Estimate independent, heterogeneous host failure probabilities and compute
   the Poisson-binomial loss tail using a descending in-place dynamic program.
4. Mix that tail with explicitly configured mutually exclusive destructive
   scenarios. A scenario removes its listed host identities before recomputing
   the independent tail. Scenario probabilities must sum to at most one.
5. Admit fresh risks at or above the entry threshold; retain already admitted
   slabs only while risk is above the lower exit threshold. Order emergencies
   first, then fresh risks by descending loss probability, then fallback slabs
   by ascending structural health. Encryption-key serialization breaks ties.
6. Missing, stale, invalid, unsupported, or out-of-bounds estimates use the fixed
   health cutoff instead. The default fallback remains `0.75`.

The existing health-only migration API remains unchanged when no risk options
are supplied. Structural health is not overwritten with a probability or cutoff.

## Evidence and protection horizon

All host evidence comes from the renter database. Hosts cannot assert their own
probabilities. Available evidence maps to the proposal as follows:

| Proposed input | Available local evidence |
| --- | --- |
| Timeout rate | Failed / total recorded interactions; includes more than timeouts |
| Scan success rate | Uptime / (uptime + downtime), or the last scan outcome when no duration history exists |
| Consecutive failures | Persisted recent scan-failure count |
| Evidence age | Time since last scan, plus recent downtime after failed scans as a lower bound on time since successful observation |
| Contract expiry | Earliest of the latest good expiries for each shard on a host, compared with current height and the actual network block interval |

The estimator uses the proposal's `0.60/0.40` base weights, `0.05` consecutive
failure step capped at `0.50`, `0.35` expiry penalty, and observation-age penalty
`min(0.25, 0.10*age/horizon)`.

**Explicit analytical extension:** the dimensionless cumulative score is scaled
by `horizon / 1h` before applying `-expm1(-hazard)`. This chooses a one-hour
reference period so increased waiting time cannot reduce risk through the
proposal's age/horizon term. The coefficients and reference period still need
empirical calibration. This is not an exact reproduction of an unscaled example
probability from the report.

The horizon is oldest scan age + estimated queue delay + repair duration +
safety margin. Queue delay uses admitted queue length, successful repair p90, and
configured parallelism. The repair estimate is never below `defaultRepairTime`.
Duration samples do not decay toward zero. One extra admission pass incorporates
newly queued work; no unbounded feedback/fixed-point loop is run.

Risk validity ends at the earliest host scan deadline. The worker checks that
deadline before executing risk-only work. Model version and a policy fingerprint
scope persisted hysteresis; incompatible policy changes discard old queue state.
The bounded state lives in the existing settings table, so no schema migration
is required. Probabilities themselves are recomputed, not persisted or reused.

## Configuration

Default executable configuration:

```yaml
autopilot:
  migratorHealthCutoff: 0.75
  migratorRisk:
    enabled: true
    entryThreshold: 0.000001
    exitThreshold: 0.00000025
    safetyMargin: 1h
    modelTTL: 6h
    defaultRepairTime: 5m
    maxQueueDelay: 24h
    maxHorizon: 168h
    scenarios: []
```

Each scenario accepts `name`, `probability`, and `hosts` (full Sia public-key
strings). Names must be unique; duplicate/zero host keys and invalid probability
mass are rejected. There are at most 64 scenarios with 255 hosts each.

Probabilities refer to the protection horizon. Events must be mutually exclusive
even if their host sets intersect. Independent overlapping outage causes must
be expressed as disjoint joint-event branches, not entered as if exclusive. No
operator, ASN, subnet, or provider relationships are automatically inferred.

The CLI boolean `--autopilot.migratorRisk.enabled=false` disables the policy.
Other parameters and scenario definitions are configured through YAML. Existing
library callers of the migrator constructor retain health-only behavior unless
they explicitly pass a risk policy.

## API and diagnostics

`POST /api/bus/slabs/migration` accepts the existing `healthCutoff` and `limit`
plus optional `risk` options: `policy`, `queueDepth`, `parallelism`, `repairTime`,
and `blockInterval`. API durations are integer milliseconds, unlike YAML durations.

Risk-aware results add `repairRisk` alongside unchanged `health`. It includes
model version, validity/deadline, loss probability, protection horizon, usable
host count, emergency flag, explanatory cutoff, under-provisioning indicator,
decision reason, and host-avoidance hints. Invalid estimates must never be read
as zero risk; inspect `valid` and `reason`.

The explanatory cutoff inverts a **conservative risk class**: hypothetical hosts
use the worst currently observed failure probability, and scenarios retain their
current affected-host counts. Replacement hosts are assumed outside the explicit
scenarios, never to have zero independent risk. The first safe count maps to
`(u*-1-k)/(n-k)`; an unsatisfied budget reports under-provisioning and cutoff one.
The actual heterogeneous loss probability, not this explanatory bound, controls
admission. The cutoff is not a prediction about unobserved replacement hosts.

## Worker behavior and limits

Risk-only admission is actionable even when structural health is one: the worker
can replace shards on explicitly affected scenario hosts and the highest-risk
observed host. Avoided hosts remain available for downloads but are excluded
from destinations. A risk-driven move requires enough distinct allowed
destinations for the full existing erasure profile. Without that spare capacity,
structurally unhealthy slabs still receive their ordinary missing-shard repair;
fully healthy slabs report a migration failure instead of claiming risk reduction.

Destination eligibility still follows existing usability, contract, and capacity
checks. This policy does not prove that replacement hosts are independent or
safer, does not automatically expand contract capacity, and cannot fix an
under-provisioned erasure profile. The model selects a conservative subset with
at most one host per shard and one shard per host. Replacement copies remain
downloadable but do not inflate modeled redundancy. Stale optional copies can
be ignored only when fresh copies cover an equally large independent placement.
This is not a full multiplicity-aware survival model.

SQL evidence is fetched in 256-slab keyset pages on both SQLite and MySQL. At
most 10,000 candidates remain admitted per pass; the scan continues so later
emergencies can displace lower-priority entries. All uploaded slabs must be
considered because high-risk slabs can have full structural health. Work is
therefore bounded per page, not constant-time for the whole renter. Queue delay
or total horizon beyond configured model bounds invalidates the estimate and
uses the fixed fallback rather than silently clipping to a safe-looking value.

The estimator uses cumulative interaction evidence rather than a new rolling
telemetry store. Common-cause events require trustworthy local operator input.
These limitations and the illustrative hazard calibration should be evaluated
before treating the policy as a production durability control.

## Verification scope

The existing Go suite has passed against SQLite, including local end-to-end
tests. The migration test enables risk-aware admission with a high entry
threshold to preserve its structural-repair purpose. No new test cases were
added. Passing the suite does not establish comprehensive risk-policy coverage
or empirical calibration. The separate Docker scenarios require compatible
built binaries and a running Docker daemon; MySQL, live-network, benchmark, and
race verification are separate checks.