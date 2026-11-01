package stores

import (
	"math"
	"testing"
)

func TestStructuralHealth(t *testing.T) {
	if got := StructuralHealth(2, 1, 3); math.Abs(got-0.5) > 1e-9 {
		t.Fatalf("unexpected structural health for 2/3: got %v want 0.5", got)
	}
	if got := StructuralHealth(1, 1, 3); math.Abs(got-0) > 1e-9 {
		t.Fatalf("unexpected structural health for 1/3: got %v want 0", got)
	}
	if got := StructuralHealth(0, 1, 3); got != -0.5 {
		t.Fatalf("unexpected structural health for 0/3: got %v want -0.5", got)
	}
}

func TestIndependentSlabLossProbability(t *testing.T) {
	got := IndependentSlabLossProbability(3, 1, []float64{0.1, 0.1, 0.1})
	want := 0.001
	if math.Abs(got-want) > 1e-9 {
		t.Fatalf("unexpected independent loss probability: got %v want %v", got, want)
	}
}

func TestRiskAwareHealth(t *testing.T) {
	healthy := RiskAwareHealth(3, 1, 3, []float64{0.01, 0.01, 0.01}, 1e-6)
	fragile := RiskAwareHealth(1, 1, 3, []float64{0.99, 0.99, 0.99}, 1e-6)
	if !(healthy > fragile) {
		t.Fatalf("risk-aware health should decrease as the slab becomes less resilient: healthy=%v fragile=%v", healthy, fragile)
	}
	if got := RiskAwareHealth(2, 1, 3, []float64{0.1, 0.1}, 1e-6); got != 0.5 {
		t.Fatalf("unexpected risk-aware health for 2/3: got %v want 0.5", got)
	}
}
