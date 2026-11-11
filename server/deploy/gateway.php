<?php
declare(strict_types=1);
header('Cache-Control: no-store');
header('X-Robots-Tag: noindex, nofollow, noarchive, nosnippet');
$path = parse_url($_SERVER['REQUEST_URI'] ?? '', PHP_URL_PATH);
$routes = ['/MakeLORA/'=>'index.php', '/MakeLORA/index.php'=>'index.php',
    '/MakeLORA/api.php'=>'api.php', '/MakeLORA/style.css'=>'style.css'];
if ($path === '/MakeLORA') { header('Location: /MakeLORA/', true, 308); exit; }
if (!isset($routes[$path])) { http_response_code(404); exit; }
$file = $routes[$path];
if ($file !== 'api.php') {
    require_once '/opt/vps-auth/bootstrap.php';
    vpsRequireUser();
}
putenv('MAKELORA_CONFIG=/run/site-private/makelora/settings.php');
$public = '/run/site-private/makelora/app/public/';
if ($file === 'style.css') {
    header('Content-Type: text/css; charset=utf-8');
    readfile($public.$file);
    exit;
}
require $public.$file;
