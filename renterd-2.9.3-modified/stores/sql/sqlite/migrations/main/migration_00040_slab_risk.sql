ALTER TABLE slabs ADD COLUMN usable_shards INTEGER NOT NULL DEFAULT 0;
ALTER TABLE slabs ADD COLUMN loss_risk REAL;
ALTER TABLE slabs ADD COLUMN recommended_cutoff REAL;
ALTER TABLE slabs ADD COLUMN risk_valid_until INTEGER NOT NULL DEFAULT 0;
ALTER TABLE slabs ADD COLUMN estimated_repair_seconds INTEGER NOT NULL DEFAULT 0;
ALTER TABLE slabs ADD COLUMN risk_model_version INTEGER NOT NULL DEFAULT 0;
ALTER TABLE slabs ADD COLUMN risk_queued INTEGER NOT NULL DEFAULT 0;

-- usable_shards must be refreshed together with health before it can be used
-- as an emergency migration signal.
UPDATE slabs SET health_valid_until = 0;

CREATE INDEX slabs_risk_priority_idx
ON slabs(risk_valid_until, loss_risk DESC, health ASC);
