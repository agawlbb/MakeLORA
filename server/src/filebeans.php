<?php
declare(strict_types=1);
require_once __DIR__.'/private-session.php';
final class FileBeansFailure extends RuntimeException {
    public function __construct(public readonly string $reason, string $message, public readonly int $status=503) { parent::__construct($message); }
}
function datasetPrivateRoot(): string {
    global $config;static $verified=null;$root=$config['private_session_directory'] ?? '';
    if ($verified===$root) return $root;
    if (!configurePrivateSession($root)) throw new RuntimeException('Private server storage is not configured.');
    $verified=$root;return $root;
}
function privateJSON(string $path,array $value): void {
    $tmp=tempnam(dirname($path),'.pending-');if ($tmp===false) throw new RuntimeException('Private storage unavailable.');
    try { chmod($tmp,0600);$data=json_encode($value,JSON_THROW_ON_ERROR|JSON_UNESCAPED_UNICODE);if (file_put_contents($tmp,$data)!==strlen($data)||!rename($tmp,$path)) throw new RuntimeException('Private storage unavailable.'); }
    finally { if (is_file($tmp)) unlink($tmp); }
}
function filebeansSettings(): array {
    global $config;$path=datasetPrivateRoot().'/filebeans.json';
    return is_file($path) ? json_decode(file_get_contents($path),true,32,JSON_THROW_ON_ERROR) : ['url'=>$config['filebeans_url'] ?? '', 'token'=>$config['filebeans_token'] ?? '', 'sources'=>$config['filebeans_sources'] ?? []];
}
function filebeansConfigured(): bool { $s=filebeansSettings();return !empty($s['url'])&&!empty($s['token'])&&!empty($s['sources']); }
function filebeansLocation(mixed $value): array {
    $s=filebeansSettings();
    if (!is_array($value)||!is_string($value['source'] ?? null)||!in_array($value['source'],$s['sources'],true)||!is_string($value['path'] ?? null)) throw new InvalidArgumentException('Choose a configured FileBeans location.');
    $p=$value['path'];
    if (strlen($p)>4096||!str_starts_with($p,'/')||str_contains($p,"\0")||str_contains($p,'\\')) throw new InvalidArgumentException('Invalid FileBeans path.');
    foreach (explode('/',$p) as $part) if ($part==='..'||$part==='.'||in_array(strtolower($part),['.filebeans-thumbnails','.filebeans-stage','.filebeans-vaults','trash'],true)) throw new InvalidArgumentException('Invalid FileBeans path.');
    return ['source'=>$value['source'],'path'=>$p];
}
function filebeansCurl(string $method,string $route,array $query=[],array $headers=[]): CurlHandle {
    $s=filebeansSettings();if (!filebeansConfigured()) throw new RuntimeException('Configure FileBeans on the server first.');
    $url=rtrim($s['url'],'/').'/v1/'.$route.($query ? '?'.http_build_query($query) : '');
    $curl=curl_init($url);
    curl_setopt_array($curl,[CURLOPT_CUSTOMREQUEST=>$method,CURLOPT_RETURNTRANSFER=>true,CURLOPT_FOLLOWLOCATION=>false,CURLOPT_PROTOCOLS=>CURLPROTO_HTTPS,CURLOPT_CONNECTTIMEOUT=>15,CURLOPT_TIMEOUT=>90,CURLOPT_HTTPHEADER=>array_merge(['Authorization: Bearer '.$s['token']],$headers)]);
    return $curl;
}
function filebeansError(int $status,?array $body): never {
    $reason=$body['code'] ?? '';
    if ($status===423||$reason==='locked'||str_contains(strtolower($body['error'] ?? ''),'locked')) throw new FileBeansFailure('locked','Unlock protected content in a FileBeans mobile app, then retry.',423);
    if ($status===412||$reason==='source_changed') throw new FileBeansFailure('source_changed','Source changed. Relink it and review its edits.',409);
    if ($status===409) throw new FileBeansFailure('conflict','A file with that name already exists, or the operation conflicts. Choose another name or folder.',409);
    if ($status===404) throw new FileBeansFailure('missing','FileBeans content is unavailable. Unlock protected content in a FileBeans mobile app if needed, then retry or relink the source.',404);
    throw new FileBeansFailure('unavailable','FileBeans could not complete the operation. Check its connection and storage, then retry.');
}
function filebeansAPI(string $method,string $route,array $query=[],?array $body=null,?string $key=null): array {
    $headers=['Content-Type: application/json'];if ($key!==null) $headers[]='Idempotency-Key: '.$key;
    $curl=filebeansCurl($method,$route,$query,$headers);
    if ($body!==null) curl_setopt($curl,CURLOPT_POSTFIELDS,json_encode($body,JSON_THROW_ON_ERROR));
    $raw=curl_exec($curl);$status=curl_getinfo($curl,CURLINFO_RESPONSE_CODE);curl_close($curl);
    $reply=is_string($raw) ? json_decode($raw,true) : null;
    if ($status<200||$status>=300||!is_array($reply)) filebeansError($status,$reply);
    return $reply;
}
function filebeansActivity(array $p): void {
    $items=[];foreach ($p['videos'] as $source) $items[]=['source'=>$source['source'],'path'=>$source['path'],'vault'=>$source['vault'] ?? ''];
    if (isset($p['destination'])) { $destination=$p['destination'];if (isset($p['exportJob'])) $destination['job']=$p['exportJob'];$items[]=$destination; }
    if ($items) filebeansAPI('POST','datasets/activity',[],array_values($items));
}
// Proxy authenticated bytes without buffering an original, upload, or preview.
function filebeansProxy(string $method,string $route,array $query=[],bool $upload=false): never {
    $headers=[];
    if ($upload) {
        $key=$_SERVER['HTTP_IDEMPOTENCY_KEY'] ?? ''; $hash=$_SERVER['HTTP_X_CONTENT_SHA256'] ?? '';
        if (!preg_match('/^[a-f0-9]{64}$/D',$key)||!preg_match('/^[a-f0-9]{64}$/D',$hash)) throw new InvalidArgumentException('Upload verification is required.');
        $headers[]='Idempotency-Key: '.$key;$headers[]='X-Content-SHA256: '.$hash;
    }
    if (!$upload && isset($_SERVER['HTTP_RANGE'])) $headers[]='Range: '.$_SERVER['HTTP_RANGE'];
    $curl=filebeansCurl($method,$route,$query,$headers);if ($method==='HEAD') curl_setopt($curl,CURLOPT_NOBODY,true);$status=0;$sent=false;$error='';
    curl_setopt_array($curl,[CURLOPT_TIMEOUT=>3600,CURLOPT_LOW_SPEED_LIMIT=>1,CURLOPT_LOW_SPEED_TIME=>120,CURLOPT_RETURNTRANSFER=>false,
        CURLOPT_HEADERFUNCTION=>static function($c,$line) use (&$status) {
            if (preg_match('/^HTTP\/\S+ (\d+)/',$line,$m)) $status=(int)$m[1];
            if ($status>=200&&$status<300&&preg_match('/^(Content-Type|Content-Length|Content-Range|Accept-Ranges|ETag):/i',$line)) header(trim($line));
            return strlen($line);
        },CURLOPT_WRITEFUNCTION=>static function($c,$bytes) use (&$status,&$sent,&$error) {
            if ($status>=200&&$status<300) { if (!$sent) { http_response_code($status);header('Cache-Control: private, no-store');$sent=true; } echo $bytes; }
            elseif (strlen($error)<8192) $error.=substr($bytes,0,8192-strlen($error));
            return strlen($bytes);
        }]);
    if ($upload) {
        set_time_limit(3600);
        $size=(int)($_SERVER['CONTENT_LENGTH'] ?? 0);
        if ($size<1||$size>2147483647) throw new InvalidArgumentException('Choose a file no larger than 2 GiB.');
        $input=fopen('php://input','rb');curl_setopt_array($curl,[CURLOPT_UPLOAD=>true,CURLOPT_CUSTOMREQUEST=>'POST',CURLOPT_INFILE=>$input,CURLOPT_INFILESIZE=>$size]);
    }
    $ok=curl_exec($curl);curl_close($curl);if (isset($input)) fclose($input);
    if (!$sent && (!$ok||$status<200||$status>=300)) {
        // Upload conflicts concern the destination name, rather than a saved edit reference.
        filebeansError($status,$upload&&$status===409 ? ['code'=>'conflict'] : json_decode($error,true));
    }
    if (!$sent) http_response_code($status);
    exit;
}
