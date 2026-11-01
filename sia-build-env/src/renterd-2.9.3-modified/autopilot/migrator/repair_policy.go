package migrator

import (
	"context"
	"math"
	"time"

	"go.sia.tech/core/consensus"
	"go.sia.tech/renterd/v2/api"
)

func (m *Migrator) slabsForMigration(ctx context.Context, queueDepth int) ([]api.UnhealthySlab, error) {
	legacy := func() ([]api.UnhealthySlab, error) {
		return m.ss.SlabsForMigration(ctx, m.healthCutoff, migratorBatchSize)
	}
	if !m.riskPolicy.Enabled {
		return legacy()
	}
	store, ok := m.ss.(interface {
		SlabsForMigrationWithRisk(context.Context, float64, int, api.SlabRiskOptions) ([]api.UnhealthySlab, error)
	})
	if !ok {
		m.logger.Warn("risk scheduling unavailable; using structural health cutoff")
		return legacy()
	}
	networkSource, ok := m.bus.(interface {
		ConsensusNetwork(context.Context) (consensus.Network, error)
	})
	if !ok {
		return legacy()
	}
	network, err := networkSource.ConsensusNetwork(ctx)
	if err != nil || network.BlockInterval <= 0 {
		m.logger.Warnw("risk scheduling cannot determine block interval; using structural health cutoff", "error", err)
		return legacy()
	}
	m.statsSlabMigrationSpeedMS.Recompute()
	repairMS := m.statsSlabMigrationSpeedMS.P90()
	repairTime := time.Duration(m.riskPolicy.DefaultRepairTime)
	if repairMS > 0 && !math.IsNaN(repairMS) && !math.IsInf(repairMS, 0) && repairMS < float64(math.MaxInt64)/float64(time.Millisecond) {
		repairTime = max(repairTime, time.Duration(repairMS*float64(time.Millisecond)))
	}
	opts := api.SlabRiskOptions{
		Policy: m.riskPolicy, QueueDepth: uint64(max(0, queueDepth)), Parallelism: m.numThreads,
		RepairTime: api.DurationMS(repairTime), BlockInterval: api.DurationMS(network.BlockInterval),
	}
	const admissionLimit = 10000
	slabs, err := store.SlabsForMigrationWithRisk(ctx, m.healthCutoff, admissionLimit, opts)
	if err == nil && uint64(len(slabs)) > opts.QueueDepth {
		// One bounded feedback pass includes newly admitted work without an
		// unbounded queue/risk fixed-point loop.
		opts.QueueDepth = uint64(len(slabs))
		slabs, err = store.SlabsForMigrationWithRisk(ctx, m.healthCutoff, admissionLimit, opts)
	}
	if err != nil {
		m.logger.Warnw("risk scheduling failed; using structural health cutoff", "error", err)
		return legacy()
	}
	return slabs, nil
}