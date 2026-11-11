<?php
declare(strict_types=1);

// Only an explicitly configured, owner-only directory outside the source tree
// may hold sessions containing provider credentials. Never fall back silently.
function configurePrivateSession(?string $directory): bool
{
    if (!$directory || !str_starts_with($directory, '/')) { return false; }
    $path = realpath($directory);
    $repository = realpath(dirname(__DIR__, 2));
    if ($path === false || $repository === false || !is_dir($path) ||
        $path === $repository || str_starts_with($path, $repository.'/') ||
        (fileperms($path) & 0777) !== 0700 || !is_writable($path)) {
        return false;
    }
    ini_set('session.save_handler', 'files');
    session_save_path('0;0600;'.$path);
    return true;
}

function saveReplicateToken(string $directory, mixed $value): bool
{
    // Accept printable ASCII without whitespace; never echo submitted input.
    if (!is_string($value) || !preg_match('/\A[\x21-\x7e]{1,512}\z/D', $value)) {
        return false;
    }
    $temporary = tempnam($directory, '.replicate-');
    if ($temporary === false) { throw new RuntimeException('Token storage unavailable.'); }
    try {
        if (!chmod($temporary, 0600) || file_put_contents($temporary, $value, LOCK_EX) !== strlen($value) ||
            !rename($temporary, $directory.'/replicate-token')) {
            throw new RuntimeException('Token storage unavailable.');
        }
    } finally {
        if (is_file($temporary)) { unlink($temporary); }
    }
    return true;
}

// Server-side provider requests use this credential for active paired devices.
// Never include its return value in a device response.
function readReplicateToken(string $directory): ?string
{
    $file = $directory.'/replicate-token';
    if (!is_file($file)) { return null; }
    $token = file_get_contents($file);
    if ($token === false) { throw new RuntimeException('Token storage unavailable.'); }
    return $token;
}

function removeReplicateToken(string $directory): void
{
    $file = $directory.'/replicate-token';
    if (is_file($file) && !unlink($file)) { throw new RuntimeException('Token removal failed.'); }
}
