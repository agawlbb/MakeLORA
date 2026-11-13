<?php
declare(strict_types=1);
require dirname(__DIR__).'/src/bootstrap.php';
require dirname(__DIR__).'/src/private-session.php';
$privateSession = configurePrivateSession($config['private_session_directory'] ?? null);
ini_set('session.use_strict_mode','1');
session_name('makelora_management');
session_set_cookie_params(['secure'=>true,'httponly'=>true,'samesite'=>'Strict','path'=>parse_url($config['base_url'],PHP_URL_PATH) ?: '/']);
session_start();
$_SESSION['csrf'] ??= bin2hex(random_bytes(32));
if ($_SERVER['REQUEST_METHOD']==='POST') {
    if (!hash_equals($_SESSION['csrf'],(string)($_POST['csrf'] ?? ''))) { http_response_code(403); exit('Reload the page and try again.'); }
    $action=$_POST['action'] ?? '';
    if ($action==='save_replicate' || $action==='remove_replicate') {
        if (!$privateSession) { http_response_code(503); exit('Private token storage is not configured.'); }
        if ($action==='remove_replicate') {
            removeReplicateToken($config['private_session_directory']);
            $_SESSION['token_notice']='Replicate token removed.';
        } elseif (saveReplicateToken($config['private_session_directory'], $_POST['replicate_token'] ?? null)) {
            $_SESSION['token_notice']='Replicate token saved.';
        } else {
            $_SESSION['token_notice']='Enter a token of 1–512 characters without spaces.';
        }
    } elseif ($action==='invite') {
        $secret=bin2hex(random_bytes(32));
        query('INSERT INTO makelora_invites (id,expires_at) VALUES (?,DATE_ADD(UTC_TIMESTAMP(), INTERVAL 5 MINUTE))',[hash('sha256',$secret)]);
        $_SESSION['invite']=['secret'=>$secret,'expires'=>time()+300];
    } elseif ($action==='approve') {
        query("UPDATE makelora_devices SET status='active' WHERE id=? AND status='pending' AND expires_at>UTC_TIMESTAMP()",[(string)($_POST['id'] ?? '')]);
    } elseif ($action==='revoke') {
        query("UPDATE makelora_devices SET status='revoked' WHERE id=?",[(string)($_POST['id'] ?? '')]);
    }
    header('Location: ./',true,303); exit;
}
$invite=$_SESSION['invite'] ?? null;
$payload=null; $svg=null;
if ($invite && $invite['expires']>time()) {
    $used=query('SELECT used_at FROM makelora_invites WHERE id=?',[hash('sha256',$invite['secret'])])->fetch();
    if ($used && !$used['used_at']) {
        $payload=json_encode(['version'=>1,'server'=>rtrim($config['base_url'],'/'),'invitation'=>$invite['secret']],JSON_UNESCAPED_SLASHES|JSON_THROW_ON_ERROR);
        $writer=new BaconQrCode\Writer(new BaconQrCode\Renderer\ImageRenderer(new BaconQrCode\Renderer\RendererStyle\RendererStyle(320),new BaconQrCode\Renderer\Image\SvgImageBackEnd()));
        $svg=$writer->writeString($payload);
    }
}
$devices=query('SELECT * FROM makelora_devices ORDER BY created_at DESC')->fetchAll();
$files=query('SELECT sha256, original_name, display_name, size_bytes, target_model, inspection_json, imported_at FROM makelora_files ORDER BY imported_at DESC, sha256')->fetchAll();
$tokenNotice=$_SESSION['token_notice'] ?? null;
unset($_SESSION['token_notice']);
?><!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>MakeLORA server</title><link rel="stylesheet" href="style.css"><main>
<h1>MakeLORA</h1>
<p><a href="drive.php">Google Drive connection</a></p>
<section aria-labelledby="replicate-heading">
<h2 id="replicate-heading">Replicate API token</h2>
<?php if ($tokenNotice): ?><p role="status"><?=escape($tokenNotice)?></p><?php endif ?>
<?php if (!$privateSession): ?><p>Private token storage is not configured on this server.</p>
<?php elseif (is_file($config['private_session_directory'].'/replicate-token')): ?>
<form method="post"><input type="hidden" name="csrf" value="<?=escape($_SESSION['csrf'])?>"><button name="action" value="remove_replicate">Remove token</button></form>
<?php else: ?>
<form method="post" autocomplete="off"><input type="hidden" name="csrf" value="<?=escape($_SESSION['csrf'])?>">
<input id="replicate-token" aria-label="Replicate API token" name="replicate_token" type="password" required maxlength="512" autocomplete="off" spellcheck="false" autocapitalize="none">
<button name="action" value="save_replicate">Save token</button></form>
<?php endif ?>
</section>
<div class="catalog">
<?php if (!$files): ?><p>No files yet.</p><?php endif ?>
<?php foreach ($files as $file): $scan=json_decode($file['inspection_json'],true,512,JSON_THROW_ON_ERROR); ?>
<details class="file">
<summary class="file-row"><span class="file-name" title="<?=escape($file['display_name'])?>"><?=escape($file['display_name'])?></span><time datetime="<?=escape(str_replace(' ','T',$file['imported_at']).'Z')?>"><?=escape(substr($file['imported_at'],0,16))?> UTC</time><span class="file-model" title="<?=escape($file['target_model'] ?? '')?>"><?=escape($file['target_model'] ? basename($file['target_model']) : '—')?></span></summary>
<div class="file-details"><dl>
<dt>Filename</dt><dd><?=escape($file['original_name'])?></dd>
<dt>Uploaded</dt><dd><?=escape($file['imported_at'])?> UTC</dd>
<dt>Target model</dt><dd><?=escape($file['target_model'] ?? '—')?></dd>
<dt>Type</dt><dd><?=escape($scan['file_type'])?></dd>
<dt>Model family</dt><dd><?=escape($scan['model_family'] ?? '—')?></dd>
<dt>Base checkpoint</dt><dd><?=escape($scan['exact_base_model'] ?? '—')?></dd>
<dt>Size</dt><dd><?=number_format($file['size_bytes']/1048576,2)?> MiB</dd>
<dt>SHA-256</dt><dd><code><?=escape($file['sha256'])?></code></dd>
<dt>Tensors</dt><dd><?=number_format($scan['tensor_count'])?></dd>
<dt>Parameters</dt><dd><?=number_format($scan['parameter_count'])?></dd>
<dt>Data types</dt><dd><?=escape(implode(', ',array_keys($scan['dtypes'])))?></dd>
<dt>LoRA rank</dt><dd><?=escape(implode(', ',$scan['lora_ranks']) ?: '—')?></dd>
</dl>
<details class="metadata"><summary>Metadata</summary><dl><?php foreach ($scan['metadata'] as $key=>$value): ?><dt><?=escape($key)?></dt><dd><code><?=escape($value)?></code></dd><?php endforeach ?></dl></details>
</div></details>
<?php endforeach ?>
</div>
<details class="devices"<?=$payload ? ' open' : ''?>><summary>Devices</summary>

<form method="post"><input type="hidden" name="csrf" value="<?=escape($_SESSION['csrf'])?>"><button name="action" value="invite">Pair device</button></form>
<?php if ($payload): ?><section><h2>Pair your iPad</h2><p>In MakeLORA, open Server → Scan QR. This invitation expires in five minutes and works once.</p><img width="320" height="320" alt="Pairing invitation" src="data:image/svg+xml;base64,<?=base64_encode($svg)?>"><p>Alternatively, copy this invitation into the app:</p><textarea readonly aria-label="Pairing invitation"><?=escape($payload)?></textarea></section><?php endif ?>
<p><a href="./">Refresh</a></p>
<?php foreach ($devices as $device): $expired=$device['status']==='pending' && strtotime($device['expires_at'].' UTC')<=time(); ?>
<section><h2><?=escape($device['name'])?></h2><p><?=escape($expired?'expired':$device['status'])?> · Paired/requested <?=escape($device['created_at'])?> UTC<br>Last contact: <?=escape($device['last_seen_at'] ?? 'Never')?> UTC</p>
<form method="post"><input type="hidden" name="csrf" value="<?=escape($_SESSION['csrf'])?>"><input type="hidden" name="id" value="<?=escape($device['id'])?>">
<?php if ($device['status']==='pending' && !$expired): ?><p>Confirm that the iPad shows <strong><?=escape($device['confirmation'])?></strong> before approving.</p><button name="action" value="approve">Approve matching device</button><?php endif ?>
<?php if ($device['status']!=='revoked'): ?><button name="action" value="revoke"><?=$device['status']==='pending'?'Cancel pairing':'Revoke device'?></button><?php endif ?></form></section><?php endforeach ?>
</details>
</main></html>
