<?php
declare(strict_types=1);
require dirname(__DIR__).'/src/bootstrap.php';
// Permit the consent redirect after our CSRF-protected POST, without widening other pages.
header("Content-Security-Policy: default-src 'none'; style-src 'self'; form-action 'self' https://accounts.google.com; frame-ancestors 'none'; base-uri 'none'");
require dirname(__DIR__).'/src/drive.php';
try {
    driveRoot();
    ini_set('session.use_strict_mode','1');session_name('makelora_drive');
    // Lax allows the top-level OAuth callback from Google to retain its state cookie.
    session_set_cookie_params(['secure'=>true,'httponly'=>true,'samesite'=>'Lax','path'=>parse_url($config['base_url'],PHP_URL_PATH) ?: '/']);session_start();
    $_SESSION['csrf'] ??= bin2hex(random_bytes(32));
    $redirect=rtrim($config['base_url'],'/').'/drive.php';
    $notice='';
    if (isset($_GET['state']) || isset($_GET['code']) || isset($_GET['error'])) {
        $state=$_SESSION['oauth'] ?? [];unset($_SESSION['oauth']);
        if (!is_string($_GET['state'] ?? null) || !hash_equals($state['state'] ?? '',$_GET['state']) || ($state['expires'] ?? 0)<time()) throw new RuntimeException('Authorization expired. Connect again.');
        if (!is_string($_GET['code'] ?? null) || isset($_GET['error'])) throw new RuntimeException('Drive authorization was not completed.');
        $reply=driveTokenRequest(['grant_type'=>'authorization_code','code'=>$_GET['code'],'redirect_uri'=>$redirect,'code_verifier'=>$state['verifier']]);
        if (empty($reply['refresh_token']) || !in_array('https://www.googleapis.com/auth/drive.readonly',explode(' ',$reply['scope'] ?? ''),true)) throw new RuntimeException('Read-only offline Drive access is required. Connect again and grant access.');
        driveLock(static function() use ($reply) { privateJSON(driveRoot().'/google-drive.json',['connection'=>bin2hex(random_bytes(16)),'refresh_token'=>$reply['refresh_token'],'access_token'=>$reply['access_token'],'expires'=>time()+(int)($reply['expires_in'] ?? 3600)]); });
        header('Location: drive.php',true,303);exit;
    }
    if ($_SERVER['REQUEST_METHOD']==='POST') {
        if (!is_string($_POST['csrf'] ?? null) || !hash_equals($_SESSION['csrf'],$_POST['csrf'])) { http_response_code(403);exit('Reload the page and try again.'); }
        if (($_POST['action'] ?? '')==='disconnect') {
            driveLock(static function() { $path=driveRoot().'/google-drive.json';if (is_file($path)) unlink($path); });
            $notice='Drive disconnected from this server. Existing server copies are retained. You can also revoke access in your Google account.';
        } elseif (driveConfigured()) {
            $verifier=bin2hex(random_bytes(32));$state=bin2hex(random_bytes(32));
            $_SESSION['oauth']=['state'=>$state,'verifier'=>$verifier,'expires'=>time()+600];
            $params=['client_id'=>$config['google_drive_client_id'],'redirect_uri'=>$redirect,'response_type'=>'code','scope'=>'https://www.googleapis.com/auth/drive.readonly','access_type'=>'offline','prompt'=>'consent','state'=>$state,'code_challenge'=>rtrim(strtr(base64_encode(hash('sha256',$verifier,true)),'+/','-_'),'='),'code_challenge_method'=>'S256'];
            header('Location: https://accounts.google.com/o/oauth2/v2/auth?'.http_build_query($params),true,303);exit;
        }
    }
    $connected=driveRead()!==null;
} catch (Throwable $e) { $notice=$e instanceof RuntimeException ? $e->getMessage() : 'Drive setup unavailable.';$connected=false; }
?><!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Google Drive · MakeLORA</title><link rel="stylesheet" href="style.css"><main>
<h1>Google Drive</h1><p><a href="./">Server settings</a></p>
<?php if ($notice): ?><p role="status"><?=escape($notice)?></p><?php endif ?>
<?php if (!driveConfigured()): ?><p>Configure the server’s Google OAuth web client and enable the Drive API first. Register this redirect URI:</p><code><?=escape(rtrim($config['base_url'],'/').'/drive.php')?></code>
<?php elseif (isset($_SESSION['csrf'])): ?>
<p><?=$connected ? 'Drive is connected.' : 'Connect the Google account containing your training videos.'?> All approved devices on this server share this connection and imported datasets.</p>
<p>Read-only permission lets this server browse and download files from this account. MakeLORA copies only videos you select and their matching captions. It does not modify Drive files.</p>
<form method="post"><input type="hidden" name="csrf" value="<?=escape($_SESSION['csrf'])?>"><button name="action" value="<?=$connected ? 'disconnect' : 'connect'?>"><?=$connected ? 'Disconnect Drive' : 'Connect Google Drive'?></button></form>
<?php endif ?></main></html>
