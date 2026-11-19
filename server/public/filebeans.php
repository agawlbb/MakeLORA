<?php
declare(strict_types=1);
require dirname(__DIR__).'/src/bootstrap.php';
require dirname(__DIR__).'/src/filebeans.php';
$notice='';$saved=[];
try {
    datasetPrivateRoot();ini_set('session.use_strict_mode','1');session_name('makelora_filebeans');
    session_set_cookie_params(['secure'=>true,'httponly'=>true,'samesite'=>'Strict','path'=>parse_url($config['browser_base_url'] ?? $config['base_url'],PHP_URL_PATH) ?: '/']);session_start();
    $_SESSION['csrf'] ??= bin2hex(random_bytes(32));
    if ($_SERVER['REQUEST_METHOD']==='POST') {
        if (!is_string($_POST['csrf'] ?? null)||!hash_equals($_SESSION['csrf'],$_POST['csrf'])) { http_response_code(403);exit('Reload the page and try again.'); }
        $url=rtrim(trim($_POST['url'] ?? ''),'/');$parts=parse_url($url);$token=trim($_POST['token'] ?? '');$sources=array_values(array_filter(array_map('trim',explode(',',$_POST['sources'] ?? ''))));
        if (($parts['scheme'] ?? '')!=='https'||empty($parts['host'])||isset($parts['user'])||isset($parts['pass'])||isset($parts['query'])||isset($parts['fragment'])) throw new InvalidArgumentException('Enter an HTTPS FileBeans API base URL.');
        $old=filebeansSettings();if ($token==='') { if ($url!==$old['url']) throw new InvalidArgumentException('Enter the token for the new server.');$token=$old['token']; }
        if (!preg_match('/^[\x21-\x7e]{16,1024}$/D',$token)||!$sources||count($sources)>32) throw new InvalidArgumentException('Enter a token and allowed source names.');
        foreach ($sources as $source) if (strlen($source)>100||preg_match('/[\x00-\x1f]/',$source)) throw new InvalidArgumentException('Invalid source name.');
        privateJSON(datasetPrivateRoot().'/filebeans.json',['url'=>$url,'token'=>$token,'sources'=>$sources]);$notice='FileBeans connection saved.';
    }
    $saved=filebeansSettings();
} catch (Throwable $e) { $notice=$e instanceof InvalidArgumentException ? $e->getMessage() : 'FileBeans configuration unavailable.'; }
?><!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>FileBeans · MakeLORA</title><link rel="stylesheet" href="style.css"><main>
<h1>FileBeans</h1><p><a href="./">Server settings</a></p>
<?php if ($notice): ?><p role="status"><?=escape($notice)?></p><?php endif ?>
<form method="post" autocomplete="off">
<input type="hidden" name="csrf" value="<?=escape($_SESSION['csrf'] ?? '')?>">
<label>API base URL <input name="url" type="url" required value="<?=escape($saved['url'] ?? '')?>"></label>
<label>API token <input name="token" type="password" autocomplete="off"></label>
<label>Allowed sources, comma separated <input name="sources" required value="<?=escape(implode(',',$saved['sources'] ?? []))?>"></label>
<button>Save connection</button></form></main></html>
