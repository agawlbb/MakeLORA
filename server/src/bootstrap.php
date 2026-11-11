<?php
declare(strict_types=1);
require dirname(__DIR__).'/vendor/autoload.php';
$configPath = getenv('MAKELORA_CONFIG') ?: '/run/makelora/settings.php';
if (!is_file($configPath)) { http_response_code(503); exit('Pairing service is not configured.'); }
$config = require $configPath;
// This prototype must never accidentally become a production authentication bypass.
if (($config['environment'] ?? '') !== 'prototype' || ($config['open_management'] ?? false) !== true) {
    http_response_code(503); exit('Shared sign-in integration is required before production use.');
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
