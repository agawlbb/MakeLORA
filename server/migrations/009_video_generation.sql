ALTER TABLE makelora_generations
 ADD COLUMN IF NOT EXISTS model_family VARCHAR(16) NOT NULL DEFAULT 'qwen',
 ADD COLUMN IF NOT EXISTS provider_model VARCHAR(120) NOT NULL DEFAULT 'qwen/qwen-image-edit-plus-lora',
 ADD COLUMN IF NOT EXISTS provider_version CHAR(64) NULL;
ALTER TABLE makelora_outputs
 ADD COLUMN IF NOT EXISTS media_type VARCHAR(16) NOT NULL DEFAULT 'image',
 ADD COLUMN IF NOT EXISTS mime_type VARCHAR(40) NOT NULL DEFAULT 'image/jpeg';
