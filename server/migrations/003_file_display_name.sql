ALTER TABLE makelora_files ADD COLUMN IF NOT EXISTS display_name VARCHAR(255) NOT NULL DEFAULT '';
UPDATE makelora_files SET display_name=original_name WHERE display_name='';
