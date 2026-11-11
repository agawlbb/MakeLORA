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
