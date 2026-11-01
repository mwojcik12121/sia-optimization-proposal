package api

import (
	"fmt"
	"math"
	"time"

	"go.sia.tech/core/types"
)

// SlabRiskModelVersion changes whenever persisted risk-policy semantics change.
const SlabRiskModelVersion = 2

// SlabFailureScenario describes one branch of a mutually exclusive, locally
// configured failure model. Probabilities refer to the protection horizon, not
// to independent per-host events. Hosts cannot supply these values.
type SlabFailureScenario struct {
	Name        string            `json:"name" yaml:"name"`
	Probability float64           `json:"probability" yaml:"probability"`
	Hosts       []types.PublicKey `json:"hosts" yaml:"hosts"`
}

// SlabRiskPolicy configures local repair admission; it never changes slab health
// or the erasure-coding reconstruction boundary. HTTP durations are milliseconds.
type SlabRiskPolicy struct {
	Enabled           bool                  `json:"enabled"`
	EntryThreshold    float64               `json:"entryThreshold"`
	ExitThreshold     float64               `json:"exitThreshold"`
	SafetyMargin      DurationMS            `json:"safetyMargin"`
	ModelTTL          DurationMS            `json:"modelTTL"`
	MaxHorizon        DurationMS            `json:"maxHorizon"`
	MaxQueueDelay     DurationMS            `json:"maxQueueDelay"`
	DefaultRepairTime DurationMS            `json:"defaultRepairTime"`
	Scenarios         []SlabFailureScenario `json:"scenarios,omitempty"`
}

func DefaultSlabRiskPolicy() SlabRiskPolicy {
	return SlabRiskPolicy{
		Enabled: true, EntryThreshold: 1e-6, ExitThreshold: 2.5e-7,
		SafetyMargin: DurationMS(time.Hour), ModelTTL: DurationMS(6 * time.Hour),
		MaxHorizon: DurationMS(7 * 24 * time.Hour), MaxQueueDelay: DurationMS(24 * time.Hour),
		DefaultRepairTime: DurationMS(5 * time.Minute),
	}
}

func (p SlabRiskPolicy) Validate() error {
	if !p.Enabled {
		return nil
	}
	validProbability := func(v float64) bool { return !math.IsNaN(v) && v >= 0 && v <= 1 }
	if !validProbability(p.EntryThreshold) || !validProbability(p.ExitThreshold) || p.ExitThreshold <= 0 || p.ExitThreshold >= p.EntryThreshold {
		return fmt.Errorf("risk thresholds must satisfy 0 < exit < entry <= 1")
	}
	if p.SafetyMargin < 0 || p.ModelTTL <= 0 || p.DefaultRepairTime <= 0 || p.MaxQueueDelay < 0 ||
		p.MaxHorizon <= p.SafetyMargin || p.ModelTTL > p.MaxHorizon || p.DefaultRepairTime > p.MaxHorizon {
		return fmt.Errorf("invalid repair risk duration bounds")
	}
	if len(p.Scenarios) > 64 {
		return fmt.Errorf("at most 64 mutually exclusive failure scenarios are supported")
	}
	var total float64
	names := make(map[string]bool)
	for _, s := range p.Scenarios {
		if s.Name == "" || names[s.Name] || !validProbability(s.Probability) || len(s.Hosts) == 0 || len(s.Hosts) > 255 {
			return fmt.Errorf("invalid or duplicate failure scenario %q", s.Name)
		}
		names[s.Name] = true
		total += s.Probability
		seen := make(map[types.PublicKey]bool)
		for _, hk := range s.Hosts {
			if hk == (types.PublicKey{}) || seen[hk] {
				return fmt.Errorf("invalid or duplicate host in scenario %q", s.Name)
			}
			seen[hk] = true
		}
	}
	if total > 1 {
		return fmt.Errorf("mutually exclusive scenario probabilities must sum to at most one")
	}
	return nil
}

// SlabRiskOptions supplies scheduler measurements rather than host assertions.
type SlabRiskOptions struct {
	Policy        SlabRiskPolicy `json:"policy"`
	QueueDepth    uint64         `json:"queueDepth"`
	Parallelism   uint64         `json:"parallelism"`
	RepairTime    DurationMS     `json:"repairTime"`
	BlockInterval DurationMS     `json:"blockInterval"`
}

// SlabRepairRisk is explanatory metadata. Health remains structural health.
type SlabRepairRisk struct {
	ModelVersion      int               `json:"modelVersion"`
	Valid             bool              `json:"valid"`
	ValidUntil        time.Time         `json:"validUntil"`
	LossProbability   float64           `json:"lossProbability"`
	ProtectionHorizon DurationMS        `json:"protectionHorizon"`
	HealthCutoff      float64           `json:"healthCutoff"`
	UsableHosts       int               `json:"usableHosts"`
	Emergency         bool              `json:"emergency"`
	UnderProvisioned  bool              `json:"underProvisioned"`
	Reason            string            `json:"reason"`
	AvoidHosts        []types.PublicKey `json:"avoidHosts,omitempty"`
}
