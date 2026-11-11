CREATE TABLE IF NOT EXISTS makelora_invites (
 id CHAR(64) PRIMARY KEY,
 expires_at DATETIME NOT NULL,
 used_at DATETIME NULL
);
CREATE TABLE IF NOT EXISTS makelora_devices (
 id CHAR(32) PRIMARY KEY,
 name VARCHAR(100) NOT NULL,
 token_hash CHAR(64) NOT NULL UNIQUE,
 confirmation CHAR(6) NOT NULL,
 status VARCHAR(16) NOT NULL,
 created_at DATETIME NOT NULL,
 expires_at DATETIME NOT NULL,
 last_seen_at DATETIME NULL
);
CREATE TABLE IF NOT EXISTS makelora_files (
 sha256 CHAR(64) CHARACTER SET ascii COLLATE ascii_bin PRIMARY KEY,
 original_name VARCHAR(255) NOT NULL,
 display_name VARCHAR(255) NOT NULL,
 storage_key VARCHAR(80) NOT NULL UNIQUE,
 target_model VARCHAR(255) NULL,
 size_bytes BIGINT UNSIGNED NOT NULL,
 inspection_json LONGTEXT NOT NULL CHECK (JSON_VALID(inspection_json)),
 tensors_json LONGTEXT NOT NULL CHECK (JSON_VALID(tensors_json)),
 imported_at DATETIME NOT NULL,
 inspected_at DATETIME NOT NULL
);

CREATE TABLE IF NOT EXISTS makelora_generations (
 id VARCHAR(100) CHARACTER SET ascii COLLATE ascii_bin PRIMARY KEY,
 device_id CHAR(32) NOT NULL,
 provider_id VARCHAR(100) NULL,
 model_name VARCHAR(255) NOT NULL DEFAULT '',
 prompt TEXT NULL,
 callback_hash CHAR(64) NULL,
 status VARCHAR(24) NOT NULL DEFAULT 'starting',
 logs TEXT NULL,
 created_at DATETIME NOT NULL
);

CREATE TABLE IF NOT EXISTS makelora_outputs (
 id CHAR(64) CHARACTER SET ascii COLLATE ascii_bin PRIMARY KEY,
 generation_id VARCHAR(100) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
 output_index INT UNSIGNED NOT NULL,
 storage_key VARCHAR(80) NOT NULL,
 created_at DATETIME NOT NULL,
 deleted_at DATETIME NULL,
 UNIQUE KEY generation_output (generation_id, output_index)
);
