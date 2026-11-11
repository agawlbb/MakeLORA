ALTER TABLE makelora_generations
 ADD COLUMN provider_id VARCHAR(100) NULL,
 ADD COLUMN model_name VARCHAR(255) NOT NULL DEFAULT '',
 ADD COLUMN prompt TEXT NULL,
 ADD COLUMN callback_hash CHAR(64) NULL,
 ADD COLUMN status VARCHAR(24) NOT NULL DEFAULT 'starting',
 ADD COLUMN logs TEXT NULL;
UPDATE makelora_generations SET provider_id=id;
CREATE TABLE IF NOT EXISTS makelora_outputs (
 id CHAR(64) CHARACTER SET ascii COLLATE ascii_bin PRIMARY KEY,
 generation_id VARCHAR(100) CHARACTER SET ascii COLLATE ascii_bin NOT NULL,
 output_index INT UNSIGNED NOT NULL,
 storage_key VARCHAR(80) NOT NULL,
 created_at DATETIME NOT NULL,
 deleted_at DATETIME NULL,
 UNIQUE KEY generation_output (generation_id, output_index)
);
