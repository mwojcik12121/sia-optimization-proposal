package stores

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"sort"
	"time"

	"go.sia.tech/core/types"
	"go.sia.tech/renterd/v2/api"
	"go.sia.tech/renterd/v2/stores/sql"
)

const (
	repairRiskSetting   = "internal.repairRiskQueue.v1"
	repairRiskBatchSize = 256
	maxRepairQueue      = 10000
)

type repairQueueState struct {
	Version int             `json:"version"`
	Policy  string          `json:"policy"`
	Queued  map[string]bool `json:"queued"`
}

// hostFailureProbability implements the illustrative estimator in section 7.3.
// Local interaction failure fraction and uptime fraction are proxies for timeout
// and scan success rates, not fitted failure probabilities.
func hostFailureProbability(h sql.SlabRiskHost, now time.Time, horizon, blockInterval time.Duration, height uint64) float64 {
	if h.TotalScans == 0 || h.LastScan.IsZero() || h.LastScan.After(now) || horizon <= 0 || blockInterval <= 0 ||
		h.Successful < 0 || h.Failed < 0 || math.IsNaN(h.Successful+h.Failed) || math.IsInf(h.Successful+h.Failed, 0) ||
		h.Successful+h.Failed <= 0 || h.Uptime < 0 || h.Downtime < 0 || h.RecentDowntime < 0 {
		return math.NaN()
	}
	timeoutRate := h.Failed / (h.Successful + h.Failed)
	scanSuccess := 0.0
	if h.LastScanSuccess {
		scanSuccess = 1
	}
	if h.Uptime > 0 || h.Downtime > 0 {
		scanSuccess = float64(h.Uptime) / (float64(h.Uptime) + float64(h.Downtime))
	}
	lambda := 0.60*timeoutRate + 0.40*(1-scanSuccess) + math.Min(0.50, 0.05*float64(h.ConsecutiveFailures))
	if h.ContractEnd <= height || float64(h.ContractEnd-height) <= float64(horizon)/float64(blockInterval) {
		lambda += 0.35
	}
	age := now.Sub(h.LastScan)
	if !h.LastScanSuccess {
		// A lower bound on the last successful observation, not an invented timestamp.
		age = cappedDurationSum(time.Duration(math.MaxInt64), age, h.RecentDowntime)
	}
	lambda += math.Min(0.25, 0.10*float64(age)/float64(horizon))
	// Analytical extension (§7.11.3): integrate the illustrative score against
	// a one-hour reference so increasing the horizon cannot decrease risk.
	return -math.Expm1(-lambda * float64(horizon) / float64(time.Hour))
}

func cappedDurationSum(cap time.Duration, values ...time.Duration) time.Duration {
	var sum time.Duration
	for _, v := range values {
		if v < 0 || v > cap-sum {
			return cap
		}
		sum += v
	}
	return sum
}

// correlatedSlabLoss implements the mutually exclusive scenario mixture. Host
// sets may intersect, but the events themselves MUST be mutually exclusive.
func correlatedSlabLoss(hosts []types.PublicKey, probabilities []float64, k int, scenarios []api.SlabFailureScenario) float64 {
	base := IndependentSlabLossProbability(len(hosts), k, probabilities)
	if math.IsNaN(base) {
		return base
	}
	var mass, weighted float64
	for _, scenario := range scenarios {
		removed := make(map[types.PublicKey]bool, len(scenario.Hosts))
		for _, hk := range scenario.Hosts {
			removed[hk] = true
		}
		var remaining []float64
		for i, hk := range hosts {
			if !removed[hk] {
				remaining = append(remaining, probabilities[i])
			}
		}
		mass += scenario.Probability
		weighted += scenario.Probability * IndependentSlabLossProbability(len(remaining), k, remaining)
	}
	return math.Min(1, math.Max(0, (1-mass)*base+weighted))
}

// independentPlacement selects at most one host per shard and one shard per
// host. Other copies remain available to the downloader but do not inflate the
// probability model. Prefer lower-risk copies, including configured domains.
func independentPlacement(s sql.SlabRiskCandidate, ps []float64, scenarios []api.SlabFailureScenario) (sql.SlabRiskCandidate, []float64, bool) {
	if len(ps) != len(s.Hosts) {
		return s, nil, false
	}
	order := make([]int, len(s.Hosts))
	scores := append([]float64(nil), ps...)
	for i, h := range s.Hosts {
		order[i] = i
		if len(h.Shards) == 0 {
			return s, nil, false
		}
		for _, shard := range h.Shards {
			if shard < 1 || shard > s.TotalShards {
				return s, nil, false
			}
		}
		for _, scenario := range scenarios {
			for _, hk := range scenario.Hosts {
				if hk == h.Key {
					scores[i] += scenario.Probability
					break
				}
			}
		}
	}
	sort.Slice(order, func(i, j int) bool {
		a, b := order[i], order[j]
		if scores[a] != scores[b] {
			return scores[a] < scores[b]
		}
		return s.Hosts[a].Key.String() < s.Hosts[b].Key.String()
	})
	assigned := make([]int, s.TotalShards)
	for i := range assigned {
		assigned[i] = -1
	}
	var assign func(int, []bool) bool
	assign = func(host int, visited []bool) bool {
		for _, shard := range s.Hosts[host].Shards {
			i := shard - 1
			if visited[i] {
				continue
			}
			visited[i] = true
			if assigned[i] == -1 || assign(assigned[i], visited) {
				assigned[i] = host
				return true
			}
		}
		return false
	}
	for _, host := range order {
		assign(host, make([]bool, s.TotalShards))
	}
	hosts := s.Hosts
	s.Hosts = nil
	var probabilities []float64
	for _, host := range assigned {
		if host >= 0 {
			s.Hosts = append(s.Hosts, hosts[host])
			probabilities = append(probabilities, ps[host])
		}
	}
	return s, probabilities, true
}

// explanatoryCutoff inverts a conservative risk class: each hypothetical host
// has the worst observed probability and scenarios retain their affected-host
// counts. Replacements are outside explicit scenarios, never zero-risk hosts.
// Admission uses actual heterogeneous risk, not this explanatory bound.
func explanatoryCutoff(s sql.SlabRiskCandidate, ps []float64, policy api.SlabRiskPolicy) (float64, bool) {
	worst := 0.0
	for _, p := range ps {
		worst = math.Max(worst, p)
	}
	// Compute every homogeneous tail in one O(n²) pass, instead of rerunning
	// the full DP for every hypothetical host count and every scenario.
	tails := make([]float64, s.TotalShards+1)
	dp := make([]float64, s.TotalShards+1)
	dp[0] = 1
	for u := 0; u <= s.TotalShards; u++ {
		if u > 0 {
			for f := u; f >= 0; f-- {
				dp[f] *= 1 - worst
				if f > 0 {
					dp[f] += dp[f-1] * worst
				}
			}
		}
		if u < s.MinShards {
			tails[u] = 1
		} else {
			for _, probability := range dp[u-s.MinShards+1 : u+1] {
				tails[u] += probability
			}
		}
	}
	counts := make([]int, len(policy.Scenarios))
	for j, scenario := range policy.Scenarios {
		keys := make(map[types.PublicKey]bool)
		for _, hk := range scenario.Hosts {
			keys[hk] = true
		}
		for _, h := range s.Hosts {
			if keys[h.Key] {
				counts[j]++
			}
		}
	}
	for u := s.MinShards; u <= s.TotalShards; u++ {
		base := tails[u]
		mass, weighted := 0.0, 0.0
		for j, scenario := range policy.Scenarios {
			remaining := u - min(u, counts[j])
			mass += scenario.Probability
			weighted += scenario.Probability * tails[remaining]
		}
		if (1-mass)*base+weighted <= policy.EntryThreshold {
			if s.MinShards == s.TotalShards {
				return 1, false
			}
			return math.Max(-1, float64(u-1-s.MinShards)/float64(s.TotalShards-s.MinShards)), false
		}
	}
	return 1, true
}

func evaluateSlabRisk(s sql.SlabRiskCandidate, opts api.SlabRiskOptions, height uint64, now time.Time) *api.SlabRepairRisk {
	p := opts.Policy
	r := &api.SlabRepairRisk{ModelVersion: api.SlabRiskModelVersion, UsableHosts: len(s.Hosts), Emergency: len(s.Hosts) <= s.MinShards, Reason: "missing-or-stale-evidence"}
	if s.MinShards <= 0 || s.TotalShards < s.MinShards || s.TotalShards > 255 {
		r.Reason = "unsupported-shard-placement"
		return r
	}
	placement, _, supported := independentPlacement(s, make([]float64, len(s.Hosts)), nil)
	if !supported {
		r.Reason = "unsupported-shard-placement"
		return r
	}
	r.UsableHosts = len(placement.Hosts)
	r.Emergency = r.UsableHosts <= s.MinShards
	if r.UsableHosts < s.MinShards {
		r.Reason = "below-reconstruction-boundary"
		return r
	}
	// Optional old copies must not invalidate an otherwise fresh placement.
	// Ignoring unobserved copies is conservative; they remain downloadable.
	hosts := make([]sql.SlabRiskHost, 0, len(s.Hosts))
	for _, h := range s.Hosts {
		if h.LastScan.IsZero() || h.LastScan.After(now) || now.Sub(h.LastScan) >= time.Duration(p.ModelTTL) ||
			math.IsNaN(hostFailureProbability(h, now, time.Hour, time.Duration(opts.BlockInterval), height)) {
			continue
		}
		hosts = append(hosts, h)
	}
	if len(hosts) < s.MinShards {
		return r
	}
	s.Hosts = hosts
	freshPlacement, _, _ := independentPlacement(s, make([]float64, len(hosts)), nil)
	if len(freshPlacement.Hosts) < r.UsableHosts {
		return r
	}
	oldest := time.Duration(0)
	r.ValidUntil = now.Add(time.Duration(p.ModelTTL))
	for _, h := range s.Hosts {
		if h.LastScan.IsZero() || h.LastScan.After(now) || now.Sub(h.LastScan) >= time.Duration(p.ModelTTL) {
			return r
		}
		oldest = max(oldest, now.Sub(h.LastScan))
		if deadline := h.LastScan.Add(time.Duration(p.ModelTTL)); deadline.Before(r.ValidUntil) {
			r.ValidUntil = deadline
		}
	}
	repairTime := time.Duration(opts.RepairTime)
	if repairTime <= 0 {
		repairTime = time.Duration(p.DefaultRepairTime)
	}
	queue := float64(opts.QueueDepth) * float64(repairTime) / float64(max(uint64(1), opts.Parallelism))
	if queue > float64(p.MaxQueueDelay) || repairTime > time.Duration(p.MaxHorizon) {
		r.Reason = "queue-or-repair-horizon-exceeds-bound"
		return r
	}
	horizon := cappedDurationSum(time.Duration(p.MaxHorizon), oldest, time.Duration(queue), repairTime, time.Duration(p.SafetyMargin))
	r.ProtectionHorizon = api.DurationMS(horizon)
	if horizon >= time.Duration(p.MaxHorizon) {
		r.Reason = "protection-horizon-exceeds-bound"
		return r
	}
	keys := make([]types.PublicKey, len(s.Hosts))
	ps := make([]float64, len(s.Hosts))
	for i, h := range s.Hosts {
		keys[i] = h.Key
		ps[i] = hostFailureProbability(h, now, horizon, time.Duration(opts.BlockInterval), height)
		if math.IsNaN(ps[i]) {
			return r
		}
	}
	s, ps, supported = independentPlacement(s, ps, p.Scenarios)
	if !supported {
		r.Reason = "unsupported-shard-placement"
		return r
	}
	r.UsableHosts = len(s.Hosts)
	r.Emergency = r.Emergency || r.UsableHosts <= s.MinShards
	keys = keys[:0]
	for _, h := range s.Hosts {
		keys = append(keys, h.Key)
	}
	r.LossProbability = correlatedSlabLoss(keys, ps, s.MinShards, p.Scenarios)
	if math.IsNaN(r.LossProbability) {
		r.LossProbability = 0
		return r
	}
	r.Valid = true
	r.Reason = "risk-budget"
	r.HealthCutoff, r.UnderProvisioned = explanatoryCutoff(s, ps, p)
	avoid := make(map[types.PublicKey]bool)
	for _, scenario := range p.Scenarios {
		if scenario.Probability == 0 {
			continue
		}
		affectsSlab := false
		for _, hk := range scenario.Hosts {
			for _, key := range keys {
				if hk == key {
					affectsSlab = true
					break
				}
			}
		}
		if affectsSlab {
			// Exclude the whole affected domain, not just current slab holders:
			// moving to another host in that scenario would not reduce exposure.
			for _, hk := range scenario.Hosts {
				avoid[hk] = true
			}
		}
	}
	if len(keys) > 0 {
		worst := 0
		for i := range ps {
			if ps[i] > ps[worst] {
				worst = i
			}
		}
		avoid[keys[worst]] = true
	}
	for hk := range avoid {
		r.AvoidHosts = append(r.AvoidHosts, hk)
	}
	sort.Slice(r.AvoidHosts, func(i, j int) bool { return r.AvoidHosts[i].String() < r.AvoidHosts[j].String() })
	return r
}

func repairPriorityLess(a, b api.UnhealthySlab) bool {
	ar, br := a.RepairRisk, b.RepairRisk
	if ar.Emergency != br.Emergency {
		return ar.Emergency
	}
	if ar.Valid != br.Valid {
		return ar.Valid
	}
	if ar.Valid && ar.LossProbability != br.LossProbability {
		return ar.LossProbability > br.LossProbability
	}
	if a.Health != b.Health {
		return a.Health < b.Health
	}
	return a.EncryptionKey.String() < b.EncryptionKey.String()
}

// SlabsForMigrationWithRisk is an opt-in companion to the unchanged legacy
// query. Only hysteresis is persisted; probabilities are freshly recomputed.
func (s *SQLStore) SlabsForMigrationWithRisk(ctx context.Context, healthCutoff float64, limit int, opts api.SlabRiskOptions) ([]api.UnhealthySlab, error) {
	if !opts.Policy.Enabled {
		return s.SlabsForMigration(ctx, healthCutoff, limit)
	} else if err := opts.Policy.Validate(); err != nil {
		return nil, err
	}
	s.repairRiskMu.Lock()
	defer s.repairRiskMu.Unlock()
	if limit == 0 {
		return nil, nil
	} else if limit < 0 || limit > maxRepairQueue {
		limit = maxRepairQueue
	}
	encodedPolicy, _ := json.Marshal(opts.Policy)
	hash := sha256.Sum256(encodedPolicy)
	state := repairQueueState{Version: api.SlabRiskModelVersion, Policy: hex.EncodeToString(hash[:]), Queued: make(map[string]bool)}
	err := s.db.Transaction(ctx, func(tx sql.DatabaseTx) error {
		// A transaction may be retried by the database wrapper.
		state.Queued = make(map[string]bool)
		encoded, err := tx.Setting(ctx, repairRiskSetting)
		if errors.Is(err, sql.ErrSettingNotFound) {
			return nil
		} else if err != nil {
			return err
		}
		var previous repairQueueState
		if json.Unmarshal([]byte(encoded), &previous) == nil && previous.Version == state.Version && previous.Policy == state.Policy {
			state.Queued = previous.Queued
		}
		return nil
	})
	if err != nil {
		return nil, fmt.Errorf("read repair hysteresis: %w", err)
	}
	var selected []api.UnhealthySlab
	var after int64
	for {
		if err := ctx.Err(); err != nil {
			return nil, err
		}
		var batch []sql.SlabRiskCandidate
		var height uint64
		err = s.db.Transaction(ctx, func(tx sql.DatabaseTx) error {
			tip, err := tx.Tip(ctx)
			if err != nil {
				return err
			}
			height = tip.Height
			batch, err = tx.SlabRiskBatch(ctx, after, repairRiskBatchSize)
			return err
		})
		if err != nil {
			return nil, err
		}
		now := time.Now()
		for _, candidate := range batch {
			after = candidate.ID
			r := evaluateSlabRisk(candidate, opts, height, now)
			queued := r.Emergency
			if r.Valid {
				if state.Queued[candidate.Key.String()] {
					queued = queued || r.LossProbability > opts.Policy.ExitThreshold
				} else {
					queued = queued || r.LossProbability >= opts.Policy.EntryThreshold
				}
			} else {
				queued = queued || candidate.Health <= healthCutoff
			}
			if queued {
				selected = append(selected, api.UnhealthySlab{EncryptionKey: candidate.Key, Health: candidate.Health, RepairRisk: r})
			}
		}
		// Bound resident admission, but continue scanning for later emergencies.
		sort.Slice(selected, func(i, j int) bool { return repairPriorityLess(selected[i], selected[j]) })
		if len(selected) > limit {
			selected = selected[:limit]
		}
		if len(batch) < repairRiskBatchSize {
			break
		}
	}
	// Earlier pages may have expired while scanning a large renter. Never
	// return an expired risk-only admission as fresh.
	now := time.Now()
	fresh := selected[:0]
	for _, slab := range selected {
		if r := slab.RepairRisk; r.Valid && !now.Before(r.ValidUntil) {
			r.Valid = false
			r.Reason = "expired-during-scan"
			if !r.Emergency && slab.Health > healthCutoff {
				continue
			}
		}
		fresh = append(fresh, slab)
	}
	selected = fresh
	sort.Slice(selected, func(i, j int) bool { return repairPriorityLess(selected[i], selected[j]) })
	state.Queued = make(map[string]bool)
	for _, slab := range selected {
		if slab.RepairRisk.Valid {
			state.Queued[slab.EncryptionKey.String()] = true
		}
	}
	encodedState, err := json.Marshal(state)
	if err != nil {
		return nil, err
	}
	err = s.db.Transaction(ctx, func(tx sql.DatabaseTx) error {
		return tx.UpdateSetting(ctx, repairRiskSetting, string(encodedState))
	})
	return selected, err
}
