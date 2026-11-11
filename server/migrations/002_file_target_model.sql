-- VM catalog annotation; reinspection must preserve user-specified targets.
ALTER TABLE makelora_files ADD COLUMN IF NOT EXISTS target_model VARCHAR(255) NULL;
