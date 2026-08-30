package migrator

import (
	"errors"
	"fmt"
	"math"
	"sort"

	"go.sia.tech/core/types"
	"go.sia.tech/renterd/v2/config"
)

// HostRisk describes one distinct usable host and its probability of becoming
// unavailable during a shared protection horizon.
type HostRisk struct {
	HostKey            types.PublicKey
	FailureProbability float64
	FailureDomain      string
}

// DestructionScenario is one mutually-exclusive event that removes a set of
// hosts together.
type DestructionScenario struct {
	Probability float64
	LostHosts   map[types.PublicKey]struct{}
}

// IndependentLossRisk calculates the Poisson-binomial probability that fewer
// than minShards hosts survive.
func IndependentLossRisk(probabilities []float64, minShards int) (float64, error) {
	if minShards <= 0 {
		return 0, errors.New("minShards must be positive")
	} else if minShards > len(probabilities) {
		return 1, nil
	}

	dp := make([]float64, len(probabilities)+1)
	dp[0] = 1
	for i, p := range probabilities {
		if math.IsNaN(p) || math.IsInf(p, 0) || p < 0 || p > 1 {
			return 0, fmt.Errorf("invalid failure probability at index %d: %v", i, p)
		}
		for failures := i + 1; failures >= 1; failures-- {
			dp[failures] = dp[failures]*(1-p) + dp[failures-1]*p
		}
		dp[0] *= 1 - p
	}

	failuresNeeded := len(probabilities) - minShards + 1
	var risk float64
	for failures := failuresNeeded; failures <= len(probabilities); failures++ {
		risk += dp[failures]
	}
	return math.Min(1, math.Max(0, risk)), nil
}

// ScenarioLossRisk blends the no-event case with explicit mutually-exclusive
// correlated destruction scenarios.
func ScenarioLossRisk(hosts []HostRisk, minShards int, scenarios []DestructionScenario) (float64, error) {
	var scenarioProbability float64
	for i, scenario := range scenarios {
		if math.IsNaN(scenario.Probability) || math.IsInf(scenario.Probability, 0) || scenario.Probability < 0 || scenario.Probability > 1 {
			return 0, fmt.Errorf("invalid destruction-scenario probability at index %d", i)
		}
		scenarioProbability += scenario.Probability
	}
	if scenarioProbability > 1+1e-12 {
		return 0, errors.New("destruction scenarios exceed total probability one")
	}
	// Avoid a tiny negative no-event mass caused by accepted floating-point
	// representation drift.
	scenarioProbability = math.Min(1, scenarioProbability)

	allProbabilities := make([]float64, 0, len(hosts))
	for _, host := range hosts {
		allProbabilities = append(allProbabilities, host.FailureProbability)
	}
	baselineRisk, err := IndependentLossRisk(allProbabilities, minShards)
	if err != nil {
		return 0, err
	}
	totalRisk := (1 - scenarioProbability) * baselineRisk

	for _, scenario := range scenarios {
		remaining := make([]float64, 0, len(hosts))
		for _, host := range hosts {
			if _, lost := scenario.LostHosts[host.HostKey]; !lost {
				remaining = append(remaining, host.FailureProbability)
			}
		}
		conditionalRisk := 1.0
		if len(remaining) >= minShards {
			conditionalRisk, err = IndependentLossRisk(remaining, minShards)
			if err != nil {
				return 0, err
			}
		}
		totalRisk += scenario.Probability * conditionalRisk
	}
	return math.Min(1, math.Max(0, totalRisk)), nil
}

// SafeUsableHosts finds the first usable-host count whose loss risk is within
// riskBudget.
func SafeUsableHosts(totalShards, minShards int, riskBudget float64, riskAtUsableCount func(int) (float64, error)) (usable int, found bool, err error) {
	if minShards <= 0 || totalShards < minShards || math.IsNaN(riskBudget) || math.IsInf(riskBudget, 0) || riskBudget < 0 || riskBudget > 1 {
		return 0, false, errors.New("invalid safe-host calculation parameters")
	}
	var previousRisk = math.Inf(1)
	for usable := minShards; usable <= totalShards; usable++ {
		risk, err := riskAtUsableCount(usable)
		if err != nil {
			return 0, false, err
		} else if math.IsNaN(risk) || math.IsInf(risk, 0) || risk < 0 || risk > 1 {
			return 0, false, fmt.Errorf("invalid projected risk at %d usable hosts: %v", usable, risk)
		} else if risk > previousRisk+1e-12 {
			return 0, false, errors.New("projected risk increases with additional usable hosts")
		}
		previousRisk = risk
		if risk <= riskBudget {
			return usable, true, nil
		}
	}
	return totalShards, false, nil
}

// HealthCutoff converts the first safe usable-host count to renterd's existing
// health scale. Migration selects health <= cutoff, so the returned value
// represents the greatest unsafe count.
func HealthCutoff(totalShards, minShards, safeUsableHosts int) float64 {
	if minShards == totalShards {
		return 1
	}
	largestUnsafe := safeUsableHosts - 1
	cutoff := float64(largestUnsafe-minShards) / float64(totalShards-minShards)
	return math.Min(1, math.Max(-1, cutoff))
}

func nextRiskQueuedState(currentlyQueued bool, lossRisk float64, policy config.SlabRiskSettings) bool {
	if currentlyQueued {
		return lossRisk > policy.ExitRisk
	}
	return lossRisk >= policy.EnterRisk
}

// projectRiskForUsableCount makes a conservative projection for the
// explanatory cutoff. When reducing a set, it retains the highest-risk hosts;
// when adding hosts, it assigns the worst observed independent probability.
func projectRiskForUsableCount(hosts []HostRisk, usable int) []HostRisk {
	projected := append([]HostRisk(nil), hosts...)
	sort.Slice(projected, func(i, j int) bool {
		return projected[i].FailureProbability > projected[j].FailureProbability
	})
	if usable <= len(projected) {
		return projected[:usable]
	}

	worst := 1.0
	if len(projected) > 0 {
		worst = projected[0].FailureProbability
	}
	for len(projected) < usable {
		// Synthetic identities are used only to keep explicit scenario maps from
		// accidentally treating projected hosts as an existing host.
		seed := []byte(fmt.Sprintf("renterd-slab-risk-projected-host-%d", len(projected)))
		projected = append(projected, HostRisk{
			HostKey:            types.PublicKey(types.HashBytes(seed)),
			FailureProbability: worst,
		})
	}
	return projected
}

func projectScenariosForUsableCount(scenarios []DestructionScenario, hosts []HostRisk) []DestructionScenario {
	present := make(map[types.PublicKey]struct{}, len(hosts))
	for _, host := range hosts {
		present[host.HostKey] = struct{}{}
	}
	projected := make([]DestructionScenario, 0, len(scenarios))
	for _, scenario := range scenarios {
		lost := make(map[types.PublicKey]struct{})
		for host := range scenario.LostHosts {
			if _, ok := present[host]; ok {
				lost[host] = struct{}{}
			}
		}
		projected = append(projected, DestructionScenario{
			Probability: scenario.Probability,
			LostHosts:   lost,
		})
	}
	return projected
}
