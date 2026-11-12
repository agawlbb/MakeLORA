ALTER TABLE makelora_generations
 ADD COLUMN retry_enabled TINYINT(1) NOT NULL DEFAULT 0,
 ADD COLUMN retry_until DATETIME NULL,
 ADD COLUMN next_retry_at DATETIME NULL,
 ADD COLUMN retry_count INT UNSIGNED NOT NULL DEFAULT 0,
 ADD COLUMN retry_cancelled_at DATETIME NULL,
 ADD COLUMN retry_payload_key VARCHAR(80) NULL,
 ADD INDEX retry_due (retry_enabled,next_retry_at);
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
