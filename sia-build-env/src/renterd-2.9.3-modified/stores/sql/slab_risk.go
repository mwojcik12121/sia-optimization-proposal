package sql

import (
	"context"
	"fmt"
	"strings"
	"time"

	"go.sia.tech/core/types"
	"go.sia.tech/renterd/v2/internal/sql"
	"go.sia.tech/renterd/v2/object"
)

type SlabRiskHost struct {
	Key                 types.PublicKey
	Shards              []int
	LastScan            time.Time
	RecentDowntime      time.Duration
	LastScanSuccess     bool
	TotalScans          uint64
	ConsecutiveFailures uint64
	Successful          float64
	Failed              float64
	Uptime              time.Duration
	Downtime            time.Duration
	ContractEnd         uint64
}

type SlabRiskCandidate struct {
	ID          int64
	Key         object.EncryptionKey
	Health      float64
	MinShards   int
	TotalShards int
	Hosts       []SlabRiskHost
}

// SlabRiskBatch traverses all uploaded slabs, not just those below the legacy
// cutoff: correlation can make a structurally healthy slab urgent. Keyset pages
// bound SQL work and memory. Keep shard indices so replacement copies can be
// modeled without counting the same erasure shard as independent redundancy.
func SlabRiskBatch(ctx context.Context, tx sql.Tx, after int64, limit int) ([]SlabRiskCandidate, error) {
	rows, err := tx.Query(ctx, `SELECT id, `+"`key`"+`, health, min_shards, total_shards
		FROM slabs WHERE id > ? AND db_buffered_slab_id IS NULL
		AND health_valid_until > ? ORDER BY id LIMIT ?`, after, time.Now().Unix(), limit)
	if err != nil {
		return nil, err
	}
	var slabs []SlabRiskCandidate
	for rows.Next() {
		var s SlabRiskCandidate
		if err := rows.Scan(&s.ID, (*EncryptionKey)(&s.Key), &s.Health, &s.MinShards, &s.TotalShards); err != nil {
			rows.Close()
			return nil, err
		}
		slabs = append(slabs, s)
	}
	err = rows.Err()
	rows.Close()
	if err != nil || len(slabs) == 0 {
		return slabs, err
	}
	args := []any{contractUsabilityGood}
	byID := make(map[int64]int)
	for i, s := range slabs {
		args = append(args, s.ID)
		byID[s.ID] = i
	}
	rows, err = tx.Query(ctx, `SELECT DISTINCT sec.db_slab_id, sec.slab_index, c.host_key,
		h.last_scan, h.last_scan_success, h.total_scans,
		COALESCE(h.recent_scan_failures, 0), COALESCE(h.recent_downtime, 0),
		h.successful_interactions, h.failed_interactions, h.uptime, h.downtime, c.window_end
		FROM sectors sec INNER JOIN contract_sectors cs ON cs.db_sector_id = sec.id
		INNER JOIN contracts c ON c.id = cs.db_contract_id AND c.usability = ?
		INNER JOIN hosts h ON h.public_key = c.host_key
		WHERE sec.db_slab_id IN (`+strings.TrimSuffix(strings.Repeat("?,", len(slabs)), ",")+`)
		ORDER BY sec.db_slab_id, c.host_key, c.window_end DESC, sec.slab_index`, args...)
	if err != nil {
		return nil, fmt.Errorf("fetch slab host evidence: %w", err)
	}
	defer rows.Close()
	seen := make(map[int64]map[types.PublicKey]int)
	for rows.Next() {
		var id int64
		var shard int
		var h SlabRiskHost
		if err := rows.Scan(&id, &shard, (*PublicKey)(&h.Key), (*UnixTimeMS)(&h.LastScan), &h.LastScanSuccess,
			&h.TotalScans, &h.ConsecutiveFailures, (*DurationMS)(&h.RecentDowntime), &h.Successful, &h.Failed,
			(*DurationMS)(&h.Uptime), (*DurationMS)(&h.Downtime), &h.ContractEnd); err != nil {
			return nil, err
		}
		if seen[id] == nil {
			seen[id] = make(map[types.PublicKey]int)
		}
		i := byID[id]
		hi, exists := seen[id][h.Key]
		if !exists {
			hi = len(slabs[i].Hosts)
			slabs[i].Hosts = append(slabs[i].Hosts, h)
			seen[id][h.Key] = hi
		}
		// Renewed contracts can repeat a host/shard pair.
		host := &slabs[i].Hosts[hi]
		found := false
		for _, index := range host.Shards {
			found = found || index == shard
		}
		if !found {
			host.Shards = append(host.Shards, shard)
			// Keep the earliest latest-good expiry across distinct shards.
			host.ContractEnd = min(host.ContractEnd, h.ContractEnd)
		}
	}
	return slabs, rows.Err()
}
