package migrator

import (
	"context"
	"errors"
	"fmt"
	"math"
	"time"

	"go.sia.tech/core/types"
)

var ErrStaleHostRiskEvidence = errors.New("host-risk evidence is stale")

// HostRiskInput contains only evidence observed or derived by the renter.
type HostRiskInput struct {
	HostKey types.PublicKey

	RecentScanSuccessRate float64
	RecentTimeoutRate     float64
	ConsecutiveFailures   uint64

	LastSuccessfulScan time.Time
	LastObservation    time.Time
	ContractEnd        time.Time

	FailureDomain string
}

type HostRiskEstimate struct {
	HostKey            types.PublicKey
	FailureProbability float64
	FailureDomain      string
	ValidUntil         time.Time
	ModelVersion       uint32
}

type HostRiskEstimator interface {
	Estimate(context.Context, HostRiskInput, time.Duration) (HostRiskEstimate, error)
	ModelVersion() uint32
}

// LocalEvidenceEstimator is the initial, explicitly versioned local policy.
// Its coefficients are intentionally rollout inputs rather than network
// guarantees; enforcement is disabled by default.
type LocalEvidenceEstimator struct {
	MaxModelAge time.Duration
	Version     uint32
}

func (e LocalEvidenceEstimator) ModelVersion() uint32 { return e.Version }

func (e LocalEvidenceEstimator) Estimate(ctx context.Context, input HostRiskInput, horizon time.Duration) (HostRiskEstimate, error) {
	if err := ctx.Err(); err != nil {
		return HostRiskEstimate{}, err
	} else if horizon <= 0 {
		return HostRiskEstimate{}, errors.New("risk horizon must be positive")
	} else if e.MaxModelAge <= 0 {
		return HostRiskEstimate{}, errors.New("maximum model age must be positive")
	} else if input.LastObservation.IsZero() || time.Since(input.LastObservation) > e.MaxModelAge {
		return HostRiskEstimate{}, ErrStaleHostRiskEvidence
	}
	for name, value := range map[string]float64{
		"recent scan success rate": input.RecentScanSuccessRate,
		"recent timeout rate":      input.RecentTimeoutRate,
	} {
		if math.IsNaN(value) || math.IsInf(value, 0) || value < 0 || value > 1 {
			return HostRiskEstimate{}, fmt.Errorf("invalid %s: %v", name, value)
		}
	}

	baseRate := 0.60*input.RecentTimeoutRate + 0.40*(1-input.RecentScanSuccessRate)
	consecutivePenalty := math.Min(0.50, float64(input.ConsecutiveFailures)*0.05)
	expiryPenalty := 0.0
	if !input.ContractEnd.IsZero() && input.ContractEnd.Before(time.Now().Add(horizon)) {
		expiryPenalty = 0.35
	}
	observationPenalty := 0.25
	if !input.LastSuccessfulScan.IsZero() {
		successfulScanAge := time.Since(input.LastSuccessfulScan)
		observationPenalty = math.Min(0.25, math.Max(0, successfulScanAge.Seconds()/horizon.Seconds()*0.10))
	}
	hazard := math.Max(0, baseRate+consecutivePenalty+expiryPenalty+observationPenalty)
	probability := 1 - math.Exp(-hazard)

	validUntil := input.LastObservation.Add(e.MaxModelAge)
	return HostRiskEstimate{
		HostKey:            input.HostKey,
		FailureProbability: math.Min(1, math.Max(0, probability)),
		FailureDomain:      input.FailureDomain,
		ValidUntil:         validUntil,
		ModelVersion:       e.Version,
	}, nil
}
