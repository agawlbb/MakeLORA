<?php
declare(strict_types=1);
require dirname(__DIR__).'/src/private-session.php';
function check(bool $ok): void { if (!$ok) { throw new RuntimeException('Private session check failed.'); } }
$directory = sys_get_temp_dir().'/makelora-session-test-'.bin2hex(random_bytes(8));
mkdir($directory, 0700);
try {
    check(!configurePrivateSession(dirname(__DIR__)));
    check(!configurePrivateSession(null));
    chmod($directory, 0755);
    check(!configurePrivateSession($directory));
    chmod($directory, 0700);
    clearstatcache();
    check(configurePrivateSession($directory));
    session_id(bin2hex(random_bytes(16)));
    session_start();
    $first = session_id();
    check(saveReplicateToken($directory, 'synthetic-test-secret'));
    check(!saveReplicateToken($directory, ['invalid']));
    check(!saveReplicateToken($directory, "invalid\nvalue"));
    check(!saveReplicateToken($directory, str_repeat('a', 513)));
    session_write_close();
    $file = $directory.'/sess_'.$first;
    check((fileperms($file) & 0777) === 0600);
    session_id(bin2hex(random_bytes(16)));
    session_start();
    check(!isset($_SESSION['replicate_token']));
    check(readReplicateToken($directory) === 'synthetic-test-secret');
    session_write_close();
    session_id($first);
    session_start();
    check(!isset($_SESSION['replicate_token']));
    check(readReplicateToken($directory) === 'synthetic-test-secret');
    check((fileperms($directory.'/replicate-token') & 0777) === 0600);
    removeReplicateToken($directory);
    session_write_close();
    check(!str_contains(file_get_contents($file), 'synthetic-test-secret'));
    session_id($first);
    session_start();
    check(!isset($_SESSION['replicate_token']));
    check(readReplicateToken($directory) === null);
    session_write_close();
} finally {
    foreach (glob($directory.'/*') as $file) { unlink($file); }
    rmdir($directory);
}
echo "Persistent token storage, cross-session availability, permissions and removal passed.\n";
