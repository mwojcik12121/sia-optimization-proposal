package migrator

import (
	"context"
	"math"
	"testing"
	"time"

	"go.sia.tech/renterd/v2/config"
)

func TestLocalEvidenceEstimatorScoreBreakdown(t *testing.T) {
	now := time.Now()
	horizon := 4 * time.Hour
	estimate, err := (LocalEvidenceEstimator{
		MaxModelAge: 24 * time.Hour,
		Version:     1,
	}).Estimate(context.Background(), HostRiskInput{
		HostKey:               testHostKey(1),
		RecentScanSuccessRate: 0.75,
		RecentTimeoutRate:     0.50,
		ConsecutiveFailures:   3,
		LastSuccessfulScan:    now.Add(-2 * time.Hour),
		LastObservation:       now.Add(-time.Minute),
		ContractEnd:           now.Add(2 * time.Hour),
	}, horizon)
	if err != nil {
		t.Fatal(err)
	}

	breakdown := estimate.ScoreBreakdown
	assertClose := func(name string, got, want, tolerance float64) {
		t.Helper()
		if math.Abs(got-want) > tolerance {
			t.Fatalf("unexpected %s: got %v, want %v", name, got, want)
		}
	}
	assertClose("timeout score", breakdown.TimeoutScore, 0.30, 1e-12)
	assertClose("scan failure score", breakdown.ScanFailureScore, 0.10, 1e-12)
	assertClose("base rate subtotal", breakdown.BaseRateSubtotal, 0.40, 1e-12)
	assertClose("consecutive failure score", breakdown.ConsecutiveFailureScore, 0.15, 1e-12)
	assertClose("contract expiry score", breakdown.ContractExpiryScore, 0.35, 1e-12)
	assertClose("observation age score", breakdown.ObservationAgeScore, 0.05, 1e-5)
	assertClose("total hazard", breakdown.TotalHazard, 0.95, 1e-5)
	criteriaTotal := breakdown.TimeoutScore + breakdown.ScanFailureScore +
		breakdown.ConsecutiveFailureScore + breakdown.ContractExpiryScore + breakdown.ObservationAgeScore
	assertClose("criterion sum", breakdown.TotalHazard, criteriaTotal, 1e-12)
	assertClose("failure probability", estimate.FailureProbability, 1-math.Exp(-breakdown.TotalHazard), 1e-12)
}

func TestRiskLevels(t *testing.T) {
	for _, test := range []struct {
		probability float64
		level       string
	}{
		{0, "low"},
		{0.099, "low"},
		{0.10, "moderate"},
		{0.249, "moderate"},
		{0.25, "high"},
		{0.499, "high"},
		{0.50, "critical"},
		{1, "critical"},
	} {
		if level := hostRiskLevel(test.probability); level != test.level {
			t.Fatalf("unexpected host risk level for %v: got %q, want %q", test.probability, level, test.level)
		}
	}

	policy := config.SlabRiskSettings{ExitRisk: 0.10, EnterRisk: 0.30}
	for _, test := range []struct {
		probability float64
		level       string
		state       string
	}{
		{0.05, "low", "at_or_below_exit"},
		{0.10, "low", "at_or_below_exit"},
		{0.20, "elevated", "between_thresholds"},
		{0.30, "high", "at_or_above_entry"},
		{0.90, "high", "at_or_above_entry"},
	} {
		if level := slabRiskLevel(test.probability, policy); level != test.level {
			t.Fatalf("unexpected slab risk level for %v: got %q, want %q", test.probability, level, test.level)
		} else if state := slabRiskPolicyState(test.probability, policy); state != test.state {
			t.Fatalf("unexpected slab policy state for %v: got %q, want %q", test.probability, state, test.state)
		}
	}
}

func TestHostNodeName(t *testing.T) {
	for _, test := range []struct {
		address string
		node    string
	}{
		{"node03:9984", "node03"},
		{"10.0.0.3:9982", "10.0.0.3"},
		{"[2001:db8::3]:9982", "2001:db8::3"},
		{"node-without-port", "node-without-port"},
		{"", ""},
	} {
		if node := hostNodeName(test.address); node != test.node {
			t.Fatalf("unexpected host node for %q: got %q, want %q", test.address, node, test.node)
		}
	}
}
