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
 model_family VARCHAR(16) NOT NULL DEFAULT 'qwen',
 provider_model VARCHAR(120) NOT NULL DEFAULT 'qwen/qwen-image-edit-plus-lora',
 provider_version CHAR(64) NULL,
 provider_id VARCHAR(100) NULL,
 model_name VARCHAR(255) NOT NULL DEFAULT '',
 prompt TEXT NULL,
 callback_hash CHAR(64) NULL,
 status VARCHAR(24) NOT NULL DEFAULT 'starting',
 logs TEXT NULL,
 dismissed_at DATETIME NULL,
 next_check_at DATETIME NULL,
 retry_enabled TINYINT(1) NOT NULL DEFAULT 0,
 retry_until DATETIME NULL,
 next_retry_at DATETIME NULL,
 retry_count INT UNSIGNED NOT NULL DEFAULT 0,
 retry_cancelled_at DATETIME NULL,
 retry_payload_key VARCHAR(80) NULL,
 INDEX retry_due (retry_enabled,next_retry_at),
 created_at DATETIME NOT NULL
);

CREATE TABLE IF NOT EXISTS makelora_outputs (
 id CHAR(64) CHARACTER SET ascii COLLATE ascii_bin PRIMARY KEY,
 generation_id VARCHAR(100) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
 output_index INT UNSIGNED NOT NULL,
 media_type VARCHAR(16) NOT NULL DEFAULT 'image',
 mime_type VARCHAR(40) NOT NULL DEFAULT 'image/jpeg',
 storage_key VARCHAR(80) NOT NULL,
 created_at DATETIME NOT NULL,
 deleted_at DATETIME NULL,
 UNIQUE KEY generation_output (generation_id, output_index)
);

CREATE TABLE IF NOT EXISTS makelora_generation_attempts (
 id CHAR(64) CHARACTER SET ascii COLLATE ascii_bin PRIMARY KEY,
 generation_id VARCHAR(100) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
 attempt_no INT UNSIGNED NOT NULL,
 callback_hash CHAR(64) NOT NULL,
 provider_id VARCHAR(100) NULL,
 state VARCHAR(24) NOT NULL,
 started_at DATETIME NOT NULL,
 UNIQUE KEY generation_attempt (generation_id,attempt_no),
 INDEX generation_lookup (generation_id)
);
CREATE TABLE IF NOT EXISTS makelora_generation_recipes (
 generation_id VARCHAR(100) CHARACTER SET ascii COLLATE ascii_bin PRIMARY KEY,
 settings_json TEXT NOT NULL CHECK (JSON_VALID(settings_json)),
 input_key VARCHAR(80) NULL,
 resolved_seed BIGINT NULL,
 created_at DATETIME NOT NULL
);
