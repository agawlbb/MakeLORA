<?php
declare(strict_types=1);
define('MAKELORA_DEVICE_API',true);
require dirname(__DIR__).'/src/bootstrap.php';
require dirname(__DIR__).'/src/generation.php';
if (in_array('--check', $argv, true)) {
    query('SELECT retry_enabled,retry_until,next_retry_at,retry_payload_key FROM makelora_generations LIMIT 0');
    query('SELECT id FROM makelora_generation_attempts LIMIT 0');
    query('SELECT generation_id FROM makelora_generation_recipes LIMIT 0');
    retryPayloadDirectory();recipeDirectory();
    echo "Generation retry schema and private storage available.\n";
    exit;
}
echo 'Generation retry worker processed '.runGenerationRetryWorker()." due jobs.\n";
