CREATE TABLE IF NOT EXISTS makelora_generations (
 id VARCHAR(100) CHARACTER SET ascii COLLATE ascii_bin PRIMARY KEY,
 device_id CHAR(32) NOT NULL,
 created_at DATETIME NOT NULL
);
