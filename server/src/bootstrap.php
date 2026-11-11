<?php
declare(strict_types=1);
require dirname(__DIR__).'/vendor/autoload.php';
$configPath = getenv('MAKELORA_CONFIG') ?: '/run/makelora/settings.php';
if (!is_file($configPath)) { http_response_code(503); exit('Pairing service is not configured.'); }
$config = require $configPath;
if (($config['maintenance'] ?? false) === true) {
    http_response_code(503); header('Cache-Control: no-store'); header('Retry-After: 60');
    exit('MakeLORA is moving to its new server. Try again shortly.');
}
// Device requests authenticate independently with the stored bearer credential.
// Browser management must use the shared VPS sign-in in production.
if (($config['environment'] ?? '') === 'production' && ($config['open_management'] ?? true) === false) {
    if (!defined('MAKELORA_DEVICE_API')) {
        require_once '/opt/vps-auth/bootstrap.php';
        vpsRequireUser();
    }
} elseif (($config['environment'] ?? '') !== 'prototype' || ($config['open_management'] ?? false) !== true) {
    http_response_code(503); exit('MakeLORA authentication is not configured.');
}
try {
    $db = new PDO($config['dsn'], $config['user'], $config['password'], [PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION, PDO::ATTR_DEFAULT_FETCH_MODE=>PDO::FETCH_ASSOC, PDO::ATTR_EMULATE_PREPARES=>false]);
    $db->exec("SET time_zone = '+00:00'");
} catch (Throwable $e) {
    error_log('MakeLORA database unavailable: '.get_class($e));
    http_response_code(503); header('Cache-Control: no-store'); exit('Pairing database unavailable.');
}
header('Cache-Control: no-store');
header('Referrer-Policy: no-referrer');
header('X-Content-Type-Options: nosniff');
header("Content-Security-Policy: default-src 'none'; style-src 'self'; img-src 'self' data:; form-action 'self'; frame-ancestors 'none'; base-uri 'none'");
function query(string $sql, array $params = []): PDOStatement { global $db; $s=$db->prepare($sql); $s->execute($params); return $s; }
function jsonResponse(array $data, int $code=200): never { http_response_code($code); header('Content-Type: application/json'); echo json_encode($data, JSON_THROW_ON_ERROR); exit; }
function fail(string $message, int $code=400): never { jsonResponse(['error'=>$message], $code); }
function escape(string $s): string { return htmlspecialchars($s, ENT_QUOTES, 'UTF-8'); }
