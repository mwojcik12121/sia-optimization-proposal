package migrator

import (
	"math"
	"testing"

	"go.sia.tech/core/types"
	"go.sia.tech/renterd/v2/config"
)

func testHostKey(b byte) (key types.PublicKey) {
	key[0] = b
	return
}

func TestIndependentLossRisk(t *testing.T) {
	risk, err := IndependentLossRisk([]float64{0.1, 0.1, 0.1}, 2)
	if err != nil {
		t.Fatal(err)
	} else if math.Abs(risk-0.028) > 1e-12 {
		t.Fatalf("unexpected risk %v", risk)
	}

	for _, probabilities := range [][]float64{{-0.1}, {1.1}, {math.NaN()}, {math.Inf(1)}} {
		if _, err := IndependentLossRisk(probabilities, 1); err == nil {
			t.Fatalf("expected invalid probability %v to fail", probabilities)
		}
	}
}

func TestCorrelatedScenarioRaisesRisk(t *testing.T) {
	hosts := []HostRisk{
		{HostKey: testHostKey(1), FailureProbability: 0.01},
		{HostKey: testHostKey(2), FailureProbability: 0.01},
		{HostKey: testHostKey(3), FailureProbability: 0.01},
		{HostKey: testHostKey(4), FailureProbability: 0.01},
	}
	independent, err := ScenarioLossRisk(hosts, 3, nil)
	if err != nil {
		t.Fatal(err)
	}
	correlated, err := ScenarioLossRisk(hosts, 3, []DestructionScenario{{
		Probability: 0.02,
		LostHosts: map[types.PublicKey]struct{}{
			testHostKey(1): {},
			testHostKey(2): {},
		},
	}})
	if err != nil {
		t.Fatal(err)
	} else if correlated <= independent {
		t.Fatal("correlated scenario did not raise risk")
	}
}

func TestHysteresis(t *testing.T) {
	policy := config.SlabRiskSettings{EnterRisk: 1e-6, ExitRisk: 2.5e-7}
	if !nextRiskQueuedState(false, 1.1e-6, policy) {
		t.Fatal("slab should enter risk queue")
	} else if !nextRiskQueuedState(true, 5e-7, policy) {
		t.Fatal("slab should remain queued")
	} else if nextRiskQueuedState(true, 1e-7, policy) {
		t.Fatal("slab should leave risk queue")
	}
}

func TestHealthCutoff(t *testing.T) {
	if cutoff := HealthCutoff(30, 10, 28); math.Abs(cutoff-0.85) > 1e-12 {
		t.Fatalf("unexpected cutoff %v", cutoff)
	}
}
