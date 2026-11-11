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

function saveReplicateToken(mixed $value): bool
{
    // Accept printable ASCII without whitespace; never echo submitted input.
    if (!is_string($value) || !preg_match('/\A[\x21-\x7e]{1,512}\z/D', $value)) {
        return false;
    }
    $_SESSION['replicate_token'] = $value;
    return true;
}
