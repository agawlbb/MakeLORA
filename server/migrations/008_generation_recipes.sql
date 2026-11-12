CREATE TABLE IF NOT EXISTS makelora_generation_recipes (
 generation_id VARCHAR(100) CHARACTER SET ascii COLLATE ascii_bin PRIMARY KEY,
 settings_json TEXT NOT NULL CHECK (JSON_VALID(settings_json)),
 input_key VARCHAR(80) NULL,
 resolved_seed BIGINT NULL,
 created_at DATETIME NOT NULL
);
