CREATE TABLE projects (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    name          TEXT NOT NULL,
    root_path     TEXT NOT NULL,
    php_version   TEXT NOT NULL,
    https_enabled INTEGER NOT NULL DEFAULT 0 CHECK (https_enabled IN (0, 1)),
    status        TEXT NOT NULL DEFAULT 'active'
                  CHECK (status IN ('active', 'disabled', 'error')),
    created_at    TEXT NOT NULL,
    updated_at    TEXT NOT NULL
);

CREATE TABLE project_domains (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    project_id INTEGER NOT NULL,
    domain     TEXT NOT NULL COLLATE NOCASE UNIQUE,
    is_primary INTEGER NOT NULL DEFAULT 0 CHECK (is_primary IN (0, 1)),
    created_at TEXT NOT NULL,

    FOREIGN KEY (project_id)
        REFERENCES projects(id)
        ON DELETE CASCADE
);

CREATE INDEX idx_project_domains_project
    ON project_domains(project_id);

CREATE UNIQUE INDEX idx_project_domains_one_primary
    ON project_domains(project_id)
    WHERE is_primary = 1;

CREATE TABLE operation_history (
    id             TEXT PRIMARY KEY,
    project_id     INTEGER,
    operation_type TEXT NOT NULL,
    status         TEXT NOT NULL CHECK (
        status IN ('preparing', 'applying', 'verifying', 'completed', 'rolling_back', 'rolled_back', 'failed')
    ),
    started_at     TEXT NOT NULL,
    finished_at    TEXT,
    error_code     TEXT,
    error_message  TEXT,

    FOREIGN KEY (project_id)
        REFERENCES projects(id)
        ON DELETE SET NULL
);

CREATE INDEX idx_operation_history_project
    ON operation_history(project_id);

CREATE INDEX idx_operation_history_status
    ON operation_history(status);

