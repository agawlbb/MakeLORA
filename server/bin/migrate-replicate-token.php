<?php
declare(strict_types=1);
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
require dirname(__DIR__).'/src/private-session.php';
$config = require (getenv('MAKELORA_CONFIG') ?: '/run/makelora/settings.php');
$directory = $config['private_session_directory'] ?? null;
if (!configurePrivateSession($directory)) { throw new RuntimeException('Private storage unavailable.'); }
$files = glob($directory.'/sess_*');
usort($files, fn($a, $b) => filemtime($b) <=> filemtime($a));
foreach ($files as $file) {
    session_id(substr(basename($file), 5));
    session_start();
    try {
        if (isset($_SESSION['replicate_token'])) {
            if (readReplicateToken($directory) === null &&
                !saveReplicateToken($directory, $_SESSION['replicate_token'])) {
                throw new RuntimeException('Legacy token is invalid.');
            }
            unset($_SESSION['replicate_token']);
        }
    } finally {
        session_write_close();
    }
}
echo "Persistent token migration complete.\n";
