package migrator

import (
	"context"
	"errors"
	"fmt"
	"math"
	"net"
	"sync"
	"time"

	rhpv4 "go.sia.tech/core/rhp/v4"
	"go.sia.tech/core/types"
	"go.sia.tech/renterd/v2/alerts"
	"go.sia.tech/renterd/v2/api"
	"go.sia.tech/renterd/v2/config"
	"go.sia.tech/renterd/v2/internal/accounts"
	"go.sia.tech/renterd/v2/internal/contracts"
	"go.sia.tech/renterd/v2/internal/download"
	"go.sia.tech/renterd/v2/internal/hosts"
	"go.sia.tech/renterd/v2/internal/memory"
	"go.sia.tech/renterd/v2/internal/rhp"
	rhp4 "go.sia.tech/renterd/v2/internal/rhp/v4"
	"go.sia.tech/renterd/v2/internal/upload"
	"go.sia.tech/renterd/v2/internal/utils"
	"go.sia.tech/renterd/v2/object"
	"go.uber.org/zap"
)

const (
	// migrationAlertRegisterInterval is the interval at which we update the
	// ongoing migrations alert to indicate progress
	migrationAlertRegisterInterval = 30 * time.Second

	// migratorBatchSize is the amount of slabs we fetch for migration from the
	// slab store at once
	migratorBatchSize = math.MaxInt // TODO: change once we have a fix for the infinite loop

	// riskRefreshBatchSize bounds database reads, calculations, and writes
	// influenced by one maintenance pass.
	riskRefreshBatchSize = 1000

	// slabRiskModelVersion identifies the semantics of LocalEvidenceEstimator.
	slabRiskModelVersion = 1

	// Sia targets one block every ten minutes. Contract expiry heights are
	// converted to local scheduling time only; this does not affect consensus.
	targetBlockTime = 10 * time.Minute
)

type (
	Bus interface {
		Accounts(context.Context, string) ([]api.Account, error)
		AddMultipartPart(ctx context.Context, bucket, key, ETag, uploadID string, partNumber int, slices []object.SlabSlice) (err error)
		AddObject(ctx context.Context, bucket, key string, o object.Object, opts api.AddObjectOptions) error
		AddPartialSlab(ctx context.Context, data []byte, minShards, totalShards uint8) (slabs []object.SlabSlice, slabBufferMaxSizeSoftReached bool, err error)
		AddUploadingSectors(ctx context.Context, uID api.UploadID, root []types.Hash256) error
		AcquireContract(ctx context.Context, fcid types.FileContractID, priority int, d time.Duration) (lockID uint64, err error)
		ConsensusState(ctx context.Context) (api.ConsensusState, error)
		Contracts(ctx context.Context, opts api.ContractsOpts) ([]api.ContractMetadata, error)
		DeleteHostSector(ctx context.Context, hk types.PublicKey, root types.Hash256) error
		FetchPartialSlab(ctx context.Context, key object.EncryptionKey, offset, length uint32) ([]byte, error)
		FinishUpload(ctx context.Context, uID api.UploadID) error
		FundAccount(ctx context.Context, account rhpv4.Account, fcid types.FileContractID, amount types.Currency) (types.Currency, error)
		GougingParams(ctx context.Context) (api.GougingParams, error)
		Host(ctx context.Context, hostKey types.PublicKey) (api.Host, error)
		KeepaliveContract(ctx context.Context, fcid types.FileContractID, lockID uint64, d time.Duration) (err error)
		MarkPackedSlabsUploaded(ctx context.Context, slabs []api.UploadedPackedSlab) error
		Objects(ctx context.Context, prefix string, opts api.ListObjectOptions) (resp api.ObjectsResponse, err error)
		RecordContractSpending(ctx context.Context, records []api.ContractSpendingRecord) error
		ReleaseContract(ctx context.Context, fcid types.FileContractID, lockID uint64) (err error)
		RenewedContract(ctx context.Context, renewedFrom types.FileContractID) (api.ContractMetadata, error)
		Slab(ctx context.Context, key object.EncryptionKey) (object.Slab, error)
		TrackUpload(ctx context.Context, uID api.UploadID) error
		UpdateAccounts(context.Context, []api.Account) error
		UpdateSlab(ctx context.Context, key object.EncryptionKey, sectors []api.UploadedSector) error
		UploadParams(ctx context.Context) (api.UploadParams, error)
		UsableHosts(ctx context.Context) (hosts []api.HostInfo, err error)
	}

	SlabStore interface {
		RefreshHealth(ctx context.Context) error
		Slab(ctx context.Context, key object.EncryptionKey) (object.Slab, error)
		SlabsForMigration(ctx context.Context, healthCutoff float64, limit int) ([]api.UnhealthySlab, error)
		RiskAwareSlabsForMigration(ctx context.Context, req api.MigrationSlabsRequest) ([]api.UnhealthySlab, error)
		SlabRiskInputs(ctx context.Context, req api.SlabRiskInputsRequest) ([]api.SlabRiskInput, error)
		UpdateSlabRisks(ctx context.Context, updates []api.SlabRiskUpdate) error
	}
)

type (
	Migrator struct {
		alerts alerts.Alerter
		bus    Bus
		ss     SlabStore

		healthCutoff float64
		numThreads   uint64
		riskPolicy   config.SlabRiskSettings

		hostRiskEstimator HostRiskEstimator

		accounts        *accounts.Manager
		downloadManager *download.Manager
		uploadManager   *upload.Manager
		hostManager     hosts.Manager

		rhp4Client *rhp4.Client

		signalConsensusNotSynced  chan struct{}
		signalMaintenanceFinished chan struct{}

		statsSlabMigrationSpeedMS *utils.DataPoints

		shutdownCtx context.Context
		wg          sync.WaitGroup

		logger *zap.SugaredLogger

		mu                 sync.Mutex
		migrating          bool
		migratingLastStart time.Time
	}
)

func New(ctx context.Context, masterKey [32]byte, alerts alerts.Alerter, ss SlabStore, b Bus, healthCutoff float64, riskPolicy config.SlabRiskSettings, numThreads, downloadMaxOverdrive, uploadMaxOverdrive uint64, downloadOverdriveTimeout, uploadOverdriveTimeout, uploadSectorTimeout, accountsRefillInterval time.Duration, logger *zap.Logger) (*Migrator, error) {
	logger = logger.Named("migrator")
	m := &Migrator{
		alerts: alerts,
		bus:    b,
		ss:     ss,

		healthCutoff: healthCutoff,
		numThreads:   numThreads,
		riskPolicy:   riskPolicy,
		hostRiskEstimator: LocalEvidenceEstimator{
			MaxModelAge: riskPolicy.ModelTTL,
			Version:     slabRiskModelVersion,
		},

		signalConsensusNotSynced:  make(chan struct{}, 1),
		signalMaintenanceFinished: make(chan struct{}, 1),

		statsSlabMigrationSpeedMS: utils.NewDataPoints(time.Hour),

		shutdownCtx: ctx,

		logger: logger.Sugar(),
	}

	if uploadSectorTimeout == 0 {
		return nil, errors.New("migrator upload sector timeout must be positive")
	} else if err := validateRiskPolicy(riskPolicy); err != nil {
		return nil, fmt.Errorf("invalid slab risk policy: %w", err)
	}

	// derive keys
	mk := utils.MasterKey(masterKey)
	ak := mk.DeriveAccountsKey("migrator")
	uk := mk.DeriveUploadKey()

	// create account manager
	am, err := accounts.NewManager(ak, "migrator", alerts, m, m, b, b, b, b, accountsRefillInterval, logger)
	if err != nil {
		return nil, err
	}
	m.accounts = am

	// create host manager
	dialer := rhp.NewFallbackDialer(b, net.Dialer{}, logger)
	csr := contracts.NewSpendingRecorder(ctx, b, 5*time.Second, logger)
	m.hostManager = hosts.NewManager(masterKey, am, csr, b, dialer, logger)
	m.rhp4Client = rhp4.New(dialer)

	// create upload & download manager
	mm := memory.NewManager(math.MaxInt64, logger)
	m.downloadManager = download.NewManager(ctx, &uk, m.hostManager, mm, b, downloadMaxOverdrive, downloadOverdriveTimeout, logger)
	m.uploadManager = upload.NewManager(ctx, &uk, m.hostManager, mm, b, b, b, uploadMaxOverdrive, uploadOverdriveTimeout, uploadSectorTimeout, logger)

	return m, nil
}

func validateRiskPolicy(policy config.SlabRiskSettings) error {
	if !policy.Enabled {
		return nil
	}
	if math.IsNaN(policy.ExitRisk) || math.IsNaN(policy.EnterRisk) || math.IsInf(policy.ExitRisk, 0) || math.IsInf(policy.EnterRisk, 0) || policy.ExitRisk < 0 || policy.ExitRisk >= policy.EnterRisk || policy.EnterRisk > 1 {
		return errors.New("require 0 <= exitRisk < enterRisk <= 1")
	} else if policy.SafetyMargin <= 0 {
		return errors.New("safetyMargin must be positive")
	} else if policy.ModelTTL <= 0 {
		return errors.New("modelTTL must be positive")
	} else if math.IsNaN(policy.FallbackHealthCutoff) || math.IsInf(policy.FallbackHealthCutoff, 0) || policy.FallbackHealthCutoff < -1 || policy.FallbackHealthCutoff > 1 {
		return errors.New("fallbackHealthCutoff must be between negative one and one")
	}
	return nil
}

func (m *Migrator) Migrate(ctx context.Context) {
	m.mu.Lock()
	if m.migrating {
		m.mu.Unlock()
		return
	}
	m.migrating = true
	m.migratingLastStart = time.Now()
	m.mu.Unlock()

	m.wg.Add(1)
	go func() {
		defer m.wg.Done()
		m.performMigrations(ctx)
		m.mu.Lock()
		m.migrating = false
		m.mu.Unlock()
	}()
}

func (m *Migrator) Shutdown(ctx context.Context) error {
	m.wg.Wait()

	// stop uploads and downloads
	m.downloadManager.Stop()
	m.uploadManager.Stop()

	// stop account manager
	return m.accounts.Shutdown(ctx)
}

func (m *Migrator) SignalMaintenanceFinished() {
	select {
	case m.signalMaintenanceFinished <- struct{}{}:
	default:
	}
}

func (m *Migrator) Status() (bool, time.Time) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.migrating, m.migratingLastStart
}

func (m *Migrator) slabMigrationEstimate(remaining int) time.Duration {
	// recompute p90
	m.statsSlabMigrationSpeedMS.Recompute()

	// return 0 if p90 is 0 (can happen if we haven't collected enough data points)
	p90 := m.statsSlabMigrationSpeedMS.P90()
	if p90 == 0 {
		return 0
	}

	totalNumMS := float64(remaining) * p90 / float64(m.numThreads)
	return time.Duration(totalNumMS) * time.Millisecond
}

// protectionHorizon is the time during which more failures can occur before a
// queued repair is expected to finish.
func (m *Migrator) protectionHorizon(oldestObservationAge time.Duration, queuedSlabsAhead int) time.Duration {
	queueDelay := m.slabMigrationEstimate(queuedSlabsAhead)
	repairP90 := m.slabMigrationEstimate(max(1, int(m.numThreads)))
	return oldestObservationAge + queueDelay + repairP90 + m.riskPolicy.SafetyMargin
}

func (m *Migrator) refreshSlabRisk(ctx context.Context, input api.SlabRiskInput, queuedSlabsAhead int, currentHeight uint64) (api.SlabRiskUpdate, error) {
	if len(input.Hosts) != input.UsableShards {
		return api.SlabRiskUpdate{}, fmt.Errorf("usable-host snapshot changed: health has %d hosts, evidence has %d", input.UsableShards, len(input.Hosts))
	}

	now := time.Now()
	var oldestObservationAge time.Duration
	for _, host := range input.Hosts {
		if observation := host.LastObservation.Std(); !observation.IsZero() {
			age := now.Sub(observation)
			if age > oldestObservationAge {
				oldestObservationAge = age
			}
		}
	}
	horizon := m.protectionHorizon(oldestObservationAge, queuedSlabsAhead)
	validUntil := now.Add(m.riskPolicy.ModelTTL)
	hostRisks := make([]HostRisk, 0, len(input.Hosts))
	for _, host := range input.Hosts {
		contractEnd := now
		if host.ContractEndHeight > currentHeight {
			blocks := host.ContractEndHeight - currentHeight
			if blocks > uint64(math.MaxInt64/int64(targetBlockTime)) {
				contractEnd = time.Unix(1<<62, 0)
			} else {
				contractEnd = now.Add(time.Duration(blocks) * targetBlockTime)
			}
		}
		estimate, err := m.hostRiskEstimator.Estimate(ctx, HostRiskInput{
			HostKey:               host.HostKey,
			RecentScanSuccessRate: host.RecentScanSuccessRate,
			RecentTimeoutRate:     host.RecentTimeoutRate,
			ConsecutiveFailures:   host.ConsecutiveFailures,
			LastSuccessfulScan:    host.LastSuccessfulScan.Std(),
			LastObservation:       host.LastObservation.Std(),
			ContractEnd:           contractEnd,
			FailureDomain:         host.FailureDomain,
		}, horizon)
		if err != nil {
			return api.SlabRiskUpdate{}, err
		} else if estimate.ValidUntil.Before(validUntil) {
			validUntil = estimate.ValidUntil
		}
		hostRisks = append(hostRisks, HostRisk{
			HostKey:            estimate.HostKey,
			FailureProbability: estimate.FailureProbability,
			FailureDomain:      estimate.FailureDomain,
		})
	}

	// Correlated scenarios are supported by the calculator, but are empty
	// until a renter-controlled failure-domain classifier supplies auditable
	// mutually-exclusive events.
	var scenarios []DestructionScenario
	lossRisk, err := ScenarioLossRisk(hostRisks, input.MinShards, scenarios)
	if err != nil {
		return api.SlabRiskUpdate{}, err
	}
	safeHosts, found, err := SafeUsableHosts(input.TotalShards, input.MinShards, m.riskPolicy.EnterRisk, func(usable int) (float64, error) {
		projectedHosts := projectRiskForUsableCount(hostRisks, usable)
		projectedScenarios := projectScenariosForUsableCount(scenarios, projectedHosts)
		return ScenarioLossRisk(projectedHosts, input.MinShards, projectedScenarios)
	})
	if err != nil {
		return api.SlabRiskUpdate{}, err
	}
	recommendedCutoff := 1.0
	if found {
		recommendedCutoff = HealthCutoff(input.TotalShards, input.MinShards, safeHosts)
	}

	return api.SlabRiskUpdate{
		EncryptionKey:          input.EncryptionKey,
		UsableShards:           len(hostRisks),
		LossRisk:               lossRisk,
		RecommendedCutoff:      recommendedCutoff,
		RiskValidUntilUnix:     validUntil.Unix(),
		EstimatedRepairSeconds: max(1, int64(math.Ceil(horizon.Seconds()))),
		ModelVersion:           m.hostRiskEstimator.ModelVersion(),
		RiskQueued:             nextRiskQueuedState(input.CurrentlyRiskQueued, lossRisk, m.riskPolicy),
	}, nil
}

func (m *Migrator) refreshSlabRisks(ctx context.Context) {
	if !m.riskPolicy.Enabled {
		return
	}
	state, err := m.bus.ConsensusState(ctx)
	if err != nil {
		m.logger.Warnw("slab risk refresh failed; fixed health cutoff will be used", zap.Error(err))
		return
	}
	inputs, err := m.ss.SlabRiskInputs(ctx, api.SlabRiskInputsRequest{
		Limit:        riskRefreshBatchSize,
		NowUnix:      time.Now().Unix(),
		ModelVersion: m.hostRiskEstimator.ModelVersion(),
	})
	if err != nil {
		m.logger.Warnw("slab risk input refresh failed; fixed health cutoff will be used", zap.Error(err))
		return
	}

	updates := make([]api.SlabRiskUpdate, 0, len(inputs))
	for i, input := range inputs {
		if err := ctx.Err(); err != nil {
			return
		}
		update, err := m.refreshSlabRisk(ctx, input, i, state.BlockHeight)
		if err != nil {
			m.logger.Warnw("slab risk calculation failed; fixed health cutoff will be used",
				zap.Stringer("slab", input.EncryptionKey),
				zap.Error(err))
			continue
		}
		m.logger.Debugw("calculated slab loss risk",
			zap.Stringer("slab", input.EncryptionKey),
			zap.Float64("lossRisk", update.LossRisk),
			zap.Float64("recommendedCutoff", update.RecommendedCutoff),
			zap.Int64("riskValidUntil", update.RiskValidUntilUnix),
			zap.Int64("protectionHorizonSeconds", update.EstimatedRepairSeconds),
			zap.Bool("riskQueued", update.RiskQueued),
			zap.Bool("shadow", m.riskPolicy.Shadow))
		updates = append(updates, update)
	}
	if len(updates) > 0 {
		if err := m.ss.UpdateSlabRisks(ctx, updates); err != nil {
			m.logger.Warnw("failed to persist slab risks; fixed health cutoff will be used", zap.Error(err))
		}
	}
}

func migrationCandidateOverlap(fixed, risk []api.UnhealthySlab) (overlap int) {
	fixedKeys := make(map[object.EncryptionKey]struct{}, len(fixed))
	for _, slab := range fixed {
		fixedKeys[slab.EncryptionKey] = struct{}{}
	}
	for _, slab := range risk {
		if _, ok := fixedKeys[slab.EncryptionKey]; ok {
			overlap++
		}
	}
	return
}

func (m *Migrator) performMigrations(ctx context.Context) {
	m.logger.Info("performing migrations")

	// prepare jobs channel
	jobs := make(chan api.UnhealthySlab)
	var wg sync.WaitGroup
	defer func() {
		close(jobs)
		wg.Wait()
	}()

	// launch workers
	for i := uint64(0); i < m.numThreads; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()

			// process jobs
			for j := range jobs {
				start := time.Now()
				err := m.migrateSlab(ctx, j.EncryptionKey)
				m.statsSlabMigrationSpeedMS.Track(float64(time.Since(start).Milliseconds()))
				if utils.IsErr(err, api.ErrConsensusNotSynced) {
					// interrupt migrations if consensus is not synced
					select {
					case m.signalConsensusNotSynced <- struct{}{}:
					default:
					}
					return
				} else if err != nil {
					m.logger.Errorw("migration failed",
						zap.Float64("health", j.Health),
						zap.Stringer("slab", j.EncryptionKey))
				}
			}
		}()
	}
	var toMigrate []api.UnhealthySlab

	// ignore a potential signal before the first iteration of the 'OUTER' loop
	select {
	case <-m.signalMaintenanceFinished:
	default:
	}

	// helper to update 'toMigrate'
	updateToMigrate := func() {
		fixedCutoff := m.healthCutoff
		if m.riskPolicy.Enabled {
			fixedCutoff = m.riskPolicy.FallbackHealthCutoff
		}
		fixedCandidates, err := m.ss.SlabsForMigration(ctx, fixedCutoff, migratorBatchSize)
		if err != nil {
			m.logger.Errorf("failed to fetch slabs for migration, err: %v", err)
			return
		}
		toMigrateNew := fixedCandidates
		if m.riskPolicy.Enabled {
			riskCandidates, riskErr := m.ss.RiskAwareSlabsForMigration(ctx, api.MigrationSlabsRequest{
				FallbackHealthCutoff: m.riskPolicy.FallbackHealthCutoff,
				EnterRisk:            m.riskPolicy.EnterRisk,
				Limit:                migratorBatchSize,
				NowUnix:              time.Now().Unix(),
				UseRisk:              true,
			})
			if riskErr != nil {
				m.logger.Warnf("failed to fetch risk-aware slabs; using fixed health cutoff: %v", riskErr)
			} else if m.riskPolicy.Shadow {
				m.logger.Infow("slab risk shadow candidate comparison",
					zap.Int("fixedCandidates", len(fixedCandidates)),
					zap.Int("riskCandidates", len(riskCandidates)),
					zap.Int("overlap", migrationCandidateOverlap(fixedCandidates, riskCandidates)))
			} else {
				toMigrateNew = riskCandidates
			}
		}
		m.logger.Infof("%d potential slabs fetched for migration", len(toMigrateNew))

		// merge toMigrateNew with toMigrate
		// NOTE: when merging, we remove all slabs from toMigrate that don't
		// require migration anymore. However, slabs that have been in toMigrate
		// before will be repaired before any new slabs. This is to prevent
		// starvation.
		migrateNewMap := make(map[object.EncryptionKey]api.UnhealthySlab)
		for _, slab := range toMigrateNew {
			migrateNewMap[slab.EncryptionKey] = slab
		}
		retained := toMigrate[:0]
		for _, slab := range toMigrate {
			if current, exists := migrateNewMap[slab.EncryptionKey]; exists {
				retained = append(retained, current)
				delete(migrateNewMap, slab.EncryptionKey)
			}
		}
		toMigrate = retained
		for _, slab := range toMigrateNew {
			if _, isNew := migrateNewMap[slab.EncryptionKey]; isNew {
				toMigrate = append(toMigrate, slab)
			}
		}
	}

	// unregister the ongoing migrations alert when we're done
	defer func() {
		if err := m.alerts.DismissAlerts(ctx, alertOngoingMigrationsID); err != nil {
			m.logger.Errorf("failed to dismiss alert: %v", err)
		}
	}()

OUTER:
	for {
		// recompute health.
		start := time.Now()
		if err := m.ss.RefreshHealth(ctx); err != nil {
			if err := m.alerts.RegisterAlert(ctx, newRefreshHealthFailedAlert(err)); err != nil {
				m.logger.Errorf("failed to register alert: %v", err)
			}
			m.logger.Errorf("failed to recompute cached health before migration: %v", err)
		} else {
			if err := m.alerts.DismissAlerts(ctx, alertHealthRefreshID); err != nil {
				m.logger.Errorf("failed to dismiss alert: %v", err)
			}
			m.logger.Infof("recomputed slab health in %v", time.Since(start))
			m.refreshSlabRisks(ctx)
			updateToMigrate()
		}

		// log the updated list of slabs to migrate
		m.logger.Infof("%d slabs to migrate", len(toMigrate))

		// return if there are no slabs to migrate
		if len(toMigrate) == 0 {
			res, err := m.alerts.Alerts(ctx, alerts.AlertsOpts{Offset: 0, Limit: -1})
			if err != nil {
				m.logger.Errorf("failed to get alerts: %v", err)
				return
			}
			for _, id := range filterMigrationFailedAlertIDs(res.Alerts) {
				if err := m.alerts.DismissAlerts(ctx, id); err != nil {
					m.logger.Errorf("failed to dismiss alert: %v", err)
				}
			}
			return
		}

		var lastRegister time.Time
		for i, slab := range toMigrate {
			if time.Since(lastRegister) > migrationAlertRegisterInterval {
				// register an alert to notify users about ongoing migrations
				remaining := len(toMigrate) - i
				if err := m.alerts.RegisterAlert(ctx, newOngoingMigrationsAlert(remaining, m.slabMigrationEstimate(remaining))); err != nil {
					m.logger.Errorf("failed to register alert: %v", err)
				}
				lastRegister = time.Now()
			}
			select {
			case <-ctx.Done():
				return
			case <-m.signalConsensusNotSynced:
				m.logger.Info("migrations interrupted - consensus is not synced")
				return
			case <-m.signalMaintenanceFinished:
				m.logger.Info("migrations interrupted - updating slabs for migration")
				continue OUTER
			case jobs <- slab:
			}
		}

		// all slabs migrated
		return
	}
}
