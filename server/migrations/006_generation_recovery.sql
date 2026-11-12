ALTER TABLE makelora_generations
 ADD COLUMN dismissed_at DATETIME NULL,
 ADD COLUMN next_check_at DATETIME NULL;
