package stores

import "math"

// StructuralHealth is the released distinct-usable-host metric. Below-threshold
// health remains negative rather than being rounded to -1.
func StructuralHealth(usableHosts, minShards, totalShards int) float64 {
	if minShards <= 0 || totalShards < minShards || usableHosts < 0 {
		return -1
	}
	if totalShards == minShards {
		if usableHosts < minShards {
			return -1
		}
		return 1
	}
	return math.Min(1, float64(usableHosts-minShards)/float64(totalShards-minShards))
}

// IndependentSlabLossProbability computes the Poisson-binomial loss tail using
// O(u) memory. Missing or invalid evidence is NaN, never an implicit zero risk.
func IndependentSlabLossProbability(usableHosts, minShards int, probabilities []float64) float64 {
	if minShards <= 0 || usableHosts < 0 || usableHosts > 255 {
		return math.NaN()
	} else if usableHosts < minShards {
		return 1
	} else if len(probabilities) != usableHosts {
		return math.NaN()
	}
	dp := make([]float64, usableHosts+1)
	dp[0] = 1
	for i, p := range probabilities {
		if math.IsNaN(p) || math.IsInf(p, 0) || p < 0 || p > 1 {
			return math.NaN()
		}
		for f := i + 1; f >= 0; f-- {
			dp[f] *= 1 - p
			if f > 0 {
				dp[f] += dp[f-1] * p
			}
		}
	}
	var risk float64
	for _, p := range dp[usableHosts-minShards+1:] {
		risk += p
	}
	return math.Min(1, math.Max(0, risk))
}

// RiskBudgetHealthCutoff requires a full, ordered hypothetical n-host profile.
// It must not invent zero-failure hosts to fill missing observations. A profile
// that never meets the budget has cutoff 1 (under-provisioned).
func RiskBudgetHealthCutoff(_ int, minShards, totalShards int, probabilities []float64, budget float64) float64 {
	if minShards <= 0 || totalShards < minShards || totalShards > 255 || len(probabilities) != totalShards || math.IsNaN(budget) || budget <= 0 || budget > 1 {
		return math.NaN()
	}
	if minShards == totalShards {
		return 1
	}
	for u := minShards; u <= totalShards; u++ {
		risk := IndependentSlabLossProbability(u, minShards, probabilities[:u])
		if math.IsNaN(risk) {
			return math.NaN()
		} else if risk <= budget {
			return math.Max(-1, float64(u-1-minShards)/float64(totalShards-minShards))
		}
	}
	return 1
}

// RiskAwareHealth is retained for callers of the original helper. Structural
// health is never replaced by a risk cutoff; scheduling compares risk separately.
func RiskAwareHealth(usableHosts, minShards, totalShards int, _ []float64, _ float64) float64 {
	return StructuralHealth(usableHosts, minShards, totalShards)
}
