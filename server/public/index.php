<?php
declare(strict_types=1);
require dirname(__DIR__).'/src/bootstrap.php';
ini_set('session.use_strict_mode','1');
session_name('makelora_management');
session_set_cookie_params(['secure'=>true,'httponly'=>true,'samesite'=>'Strict','path'=>parse_url($config['base_url'],PHP_URL_PATH) ?: '/']);
session_start();
$_SESSION['csrf'] ??= bin2hex(random_bytes(32));
if ($_SERVER['REQUEST_METHOD']==='POST') {
    if (!hash_equals($_SESSION['csrf'],(string)($_POST['csrf'] ?? ''))) { http_response_code(403); exit('Reload the page and try again.'); }
    $action=$_POST['action'] ?? '';
    if ($action==='invite') {
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
$files=query('SELECT sha256, original_name, size_bytes, target_model, inspection_json, imported_at FROM makelora_files ORDER BY imported_at DESC, sha256')->fetchAll();
?><!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>MakeLORA server</title><link rel="stylesheet" href="style.css"><main>
<h1>MakeLORA server</h1><p>VM prototype · Management is open. Pairing grants no file or model-run access.</p>
<h2>File catalog</h2><p>Files are stored privately on this VM. Downloads are not enabled. Embedded model declarations and user-specified targets are labeled separately.</p>
<?php if (!$files): ?><p>No files imported yet.</p><?php endif ?>
<?php foreach ($files as $file): $scan=json_decode($file['inspection_json'],true,512,JSON_THROW_ON_ERROR); ?>
<section class="file"><h3><?=escape($file['original_name'])?></h3><dl>
<?php if ($file['target_model']): ?><dt>Target model (user specified)</dt><dd><?=escape($file['target_model'])?></dd><?php endif ?>
<dt>Type</dt><dd><?=escape($scan['file_type'])?></dd>
<dt>Model family (declared)</dt><dd><?=escape($scan['model_family'] ?? 'Unknown')?></dd>
<dt>Identification</dt><dd><?=escape($scan['identification'])?></dd>
<dt>Exact base checkpoint (declared)</dt><dd><?=escape($scan['exact_base_model'] ?? 'Unknown — not recorded in the file')?></dd>
<dt>Size</dt><dd><?=number_format((int)$file['size_bytes'])?> bytes (<?=number_format($file['size_bytes']/1048576,2)?> MiB)</dd>
<dt>SHA-256</dt><dd><code><?=escape($file['sha256'])?></code></dd>
<dt>Tensors</dt><dd><?=number_format($scan['tensor_count'])?></dd>
<dt>Stored parameters</dt><dd><?=number_format($scan['parameter_count'])?></dd>
<dt>Data types (tensor counts)</dt><dd><?=escape(json_encode($scan['dtypes'],JSON_THROW_ON_ERROR))?></dd>
<dt>LoRA ranks</dt><dd><?=escape(implode(', ',$scan['lora_ranks']) ?: 'Unknown')?></dd>
<dt>Imported</dt><dd><?=escape($file['imported_at'])?> UTC</dd>
</dl>
<?php foreach ($scan['evidence'] as $evidence): ?><p><?=escape($evidence)?></p><?php endforeach ?>
<details><summary>Embedded metadata</summary><dl><?php foreach ($scan['metadata'] as $key=>$value): ?><dt><?=escape($key)?></dt><dd><code><?=escape($value)?></code></dd><?php endforeach ?></dl></details>
</section>
<?php endforeach ?>
<h2>Devices</h2>
<form method="post"><input type="hidden" name="csrf" value="<?=escape($_SESSION['csrf'])?>"><button name="action" value="invite">Generate pairing QR</button></form>
<?php if ($payload): ?><section><h2>Pair your iPad</h2><p>In MakeLORA, open Server → Scan QR. This invitation expires in five minutes and works once.</p><img width="320" height="320" alt="Pairing invitation" src="data:image/svg+xml;base64,<?=base64_encode($svg)?>"><p>Alternatively, copy this invitation into the app:</p><textarea readonly aria-label="Pairing invitation"><?=escape($payload)?></textarea></section><?php endif ?>
<p><a href="./">Refresh device status</a></p>
<?php foreach ($devices as $device): $expired=$device['status']==='pending' && strtotime($device['expires_at'].' UTC')<=time(); ?>
<section><h2><?=escape($device['name'])?></h2><p><?=escape($expired?'expired':$device['status'])?> · Paired/requested <?=escape($device['created_at'])?> UTC<br>Last contact: <?=escape($device['last_seen_at'] ?? 'Never')?> UTC</p>
<form method="post"><input type="hidden" name="csrf" value="<?=escape($_SESSION['csrf'])?>"><input type="hidden" name="id" value="<?=escape($device['id'])?>">
<?php if ($device['status']==='pending' && !$expired): ?><p>Confirm that the iPad shows <strong><?=escape($device['confirmation'])?></strong> before approving.</p><button name="action" value="approve">Approve matching device</button><?php endif ?>
<?php if ($device['status']!=='revoked'): ?><button name="action" value="revoke"><?=$device['status']==='pending'?'Cancel pairing':'Revoke device'?></button><?php endif ?></form></section><?php endforeach ?>
</main></html>
