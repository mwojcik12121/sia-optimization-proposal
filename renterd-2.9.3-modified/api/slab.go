package api

import (
	"time"

	"go.sia.tech/core/types"
	"go.sia.tech/renterd/v2/object"
)

type (
	PackedSlab struct {
		BufferID      uint                 `json:"bufferID"`
		Data          []byte               `json:"data"`
		EncryptionKey object.EncryptionKey `json:"encryptionKey"`
	}

	SlabBuffer struct {
		Complete bool   `json:"complete"` // whether the slab buffer is complete and ready to upload
		Filename string `json:"filename"` // name of the buffer on disk
		Size     int64  `json:"size"`     // size of the buffer
		MaxSize  int64  `json:"maxSize"`  // maximum size of the buffer
		Locked   bool   `json:"locked"`   // whether the slab buffer is locked for uploading
	}

	UnhealthySlab struct {
		EncryptionKey object.EncryptionKey `json:"encryptionKey"`
		Health        float64              `json:"health"`

		LossRisk               float64     `json:"lossRisk"`
		RecommendedCutoff      float64     `json:"recommendedCutoff"`
		RiskValidUntil         TimeRFC3339 `json:"riskValidUntil"`
		EstimatedRepairDuration DurationMS  `json:"estimatedRepairDuration"`
		Reason                  string      `json:"reason"`
	}

	// SlabRiskHost contains renter-observed evidence for one distinct host
	// currently contributing a usable shard to a slab.
	SlabRiskHost struct {
		HostKey               types.PublicKey `json:"hostKey"`
		HostAddress           string          `json:"hostAddress,omitempty"`
		RecentScanSuccessRate float64         `json:"recentScanSuccessRate"`
		RecentTimeoutRate     float64         `json:"recentTimeoutRate"`
		ConsecutiveFailures   uint64          `json:"consecutiveFailures"`
		LastSuccessfulScan    TimeRFC3339     `json:"lastSuccessfulScan"`
		LastObservation       TimeRFC3339     `json:"lastObservation"`
		ContractEndHeight     uint64          `json:"contractEndHeight"`
		FailureDomain         string          `json:"failureDomain,omitempty"`
	}

	// SlabRiskInput is a consistent database snapshot used to refresh one
	// slab's cached loss-risk estimate.
	SlabRiskInput struct {
		EncryptionKey      object.EncryptionKey `json:"encryptionKey"`
		MinShards          int                  `json:"minShards"`
		TotalShards        int                  `json:"totalShards"`
		UsableShards       int                  `json:"usableShards"`
		Hosts              []SlabRiskHost       `json:"hosts"`
		CurrentlyRiskQueued bool                 `json:"currentlyRiskQueued"`
	}

	// SlabRiskUpdate is the durable result of one slab-risk calculation.
	SlabRiskUpdate struct {
		EncryptionKey          object.EncryptionKey `json:"encryptionKey"`
		UsableShards           int                  `json:"usableShards"`
		LossRisk               float64              `json:"lossRisk"`
		RecommendedCutoff      float64              `json:"recommendedCutoff"`
		RiskValidUntilUnix     int64                `json:"riskValidUntilUnix"`
		EstimatedRepairSeconds int64                `json:"estimatedRepairSeconds"`
		ModelVersion           uint32               `json:"modelVersion"`
		RiskQueued             bool                 `json:"riskQueued"`
	}

	UploadedPackedSlab struct {
		BufferID uint
		Shards   []UploadedSector
	}

	UploadedSector struct {
		ContractID types.FileContractID `json:"contractID"`
		Root       types.Hash256        `json:"root"`
	}
)

type (
	AddPartialSlabResponse struct {
		SlabBufferMaxSizeSoftReached bool               `json:"slabBufferMaxSizeSoftReached"`
		Slabs                        []object.SlabSlice `json:"slabs"`
	}

	// MigrationSlabsRequest is the request type for the /slabs/migration endpoint.
	MigrationSlabsRequest struct {
		// HealthCutoff is retained for compatibility with pre-risk clients.
		HealthCutoff         float64 `json:"healthCutoff,omitempty"`
		FallbackHealthCutoff float64 `json:"fallbackHealthCutoff,omitempty"`
		EnterRisk            float64 `json:"enterRisk,omitempty"`
		Limit                int     `json:"limit"`
		NowUnix              int64   `json:"nowUnix,omitempty"`
		UseRisk              bool    `json:"useRisk,omitempty"`
	}

	SlabRiskInputsRequest struct {
		Limit        int    `json:"limit"`
		NowUnix      int64  `json:"nowUnix"`
		ModelVersion uint32 `json:"modelVersion"`
	}

	PackedSlabsRequestGET struct {
		LockingDuration DurationMS `json:"lockingDuration"`
		MinShards       uint8      `json:"minShards"`
		TotalShards     uint8      `json:"totalShards"`
		Limit           int        `json:"limit"`
	}

	PackedSlabsRequestPOST struct {
		Slabs []UploadedPackedSlab `json:"slabs"`
	}

	SlabsForMigrationResponse struct {
		Slabs []UnhealthySlab `json:"slabs"`
	}

	// UpdateSlabRequest is the request type for the PUT /slab/:key endpoint.
	UpdateSlabRequest []UploadedSector
)

// RiskValidUntilTime converts a persisted Unix timestamp to the API time type.
func RiskValidUntilTime(unix int64) TimeRFC3339 {
	return TimeRFC3339(time.Unix(unix, 0).UTC())
}

func (s UploadedPackedSlab) Contracts() (fcids []types.FileContractID) {
	seen := make(map[types.FileContractID]struct{})
	for _, sector := range s.Shards {
		_, ok := seen[sector.ContractID]
		if !ok {
			seen[sector.ContractID] = struct{}{}
			fcids = append(fcids, sector.ContractID)
		}
	}
	return
}
