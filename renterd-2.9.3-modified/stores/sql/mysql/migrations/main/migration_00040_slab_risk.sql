ALTER TABLE slabs
    ADD COLUMN usable_shards INT NOT NULL DEFAULT 0,
    ADD COLUMN loss_risk DOUBLE NULL,
    ADD COLUMN recommended_cutoff DOUBLE NULL,
    ADD COLUMN risk_valid_until BIGINT NOT NULL DEFAULT 0,
    ADD COLUMN estimated_repair_seconds BIGINT NOT NULL DEFAULT 0,
    ADD COLUMN risk_model_version INT UNSIGNED NOT NULL DEFAULT 0,
    ADD COLUMN risk_queued BOOLEAN NOT NULL DEFAULT FALSE;

UPDATE slabs SET health_valid_until = 0;

CREATE INDEX slabs_risk_priority_idx
ON slabs(risk_valid_until, loss_risk DESC, health ASC);
