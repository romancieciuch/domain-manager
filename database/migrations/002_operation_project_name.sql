ALTER TABLE operation_history ADD COLUMN project_name TEXT;

CREATE INDEX idx_operation_history_started_at
    ON operation_history(started_at DESC);
