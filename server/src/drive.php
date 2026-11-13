<?php
declare(strict_types=1);

// A dedicated, server-owned read-only Google connection. Never sent to devices.
function driveRoot(): string {
    global $config;
    static $verified=null;
    $root=$config['private_session_directory'] ?? '';
    if ($verified===$root) return $root;
    require_once __DIR__.'/private-session.php';
    if (!configurePrivateSession($root)) throw new RuntimeException('Private server storage is not configured.');
    $verified=$root;return $root;
}
function driveClient(): array {
    global $config;
    $path=driveRoot().'/google-drive-client.json';
    if (is_file($path)) {
        $saved=json_decode(file_get_contents($path),true);
        return ['client_id'=>$saved['client_id'] ?? '', 'client_secret'=>$saved['client_secret'] ?? ''];
    }
    return ['client_id'=>$config['google_drive_client_id'] ?? '', 'client_secret'=>$config['google_drive_client_secret'] ?? ''];
}
function driveConfigured(): bool {
    $client=driveClient();
    return is_string($client['client_id']) && $client['client_id']!=='' && is_string($client['client_secret']) && $client['client_secret']!=='';
}
function driveClientFingerprint(): string { return hash('sha256',json_encode(driveClient(),JSON_THROW_ON_ERROR)); }
function driveSaveClient(array $download,bool $replace): void {
    global $config;
    $web=$download['web'] ?? null;
    if (!is_array($web)) throw new InvalidArgumentException('Choose the JSON downloaded for your Google Web application client. Desktop client files are not supported.');
    $id=$web['client_id'] ?? null;$secret=$web['client_secret'] ?? null;
    if (!is_string($id) || !preg_match('/^[a-zA-Z0-9._-]{1,512}\.apps\.googleusercontent\.com$/D',$id) || !is_string($secret) || !preg_match('/^[\x21-\x7e]{1,512}$/D',$secret)) throw new InvalidArgumentException('The JSON is missing a valid Google client ID or secret. Download the Web application client JSON again.');
    $redirect=rtrim($config['base_url'],'/').'/drive.php';
    if (!is_array($web['redirect_uris'] ?? null) || !in_array($redirect,$web['redirect_uris'],true)) throw new InvalidArgumentException('The Google client is missing this server’s exact redirect URI. Add the URI shown below in Google, then download the JSON again.');
    driveLock(static function() use ($id,$secret,$replace) {
        if ((driveConfigured() || driveRead()!==null) && !$replace) throw new InvalidArgumentException('Confirm replacement before changing existing Google client settings.');
        // Persist only credentials. Never trust downloaded auth/token URLs or return them to a device.
        privateJSON(driveRoot().'/google-drive-client.json',['client_id'=>$id,'client_secret'=>$secret]);
        $tokens=driveRoot().'/google-drive.json';if (is_file($tokens) && !unlink($tokens)) throw new RuntimeException('Could not disconnect the previous Drive account. Retry saving the client.');
    });
}
function driveRead(): ?array {
    $path=driveRoot().'/google-drive.json';
    return is_file($path) ? json_decode(file_get_contents($path),true,32,JSON_THROW_ON_ERROR) : null;
}
function privateJSON(string $path,array $value): void {
    $tmp=tempnam(dirname($path),'.pending-');
    if ($tmp===false) throw new RuntimeException('Private storage unavailable.');
    try {
        chmod($tmp,0600);
        $data=json_encode($value,JSON_THROW_ON_ERROR|JSON_UNESCAPED_UNICODE);
        if (file_put_contents($tmp,$data)!==strlen($data) || !rename($tmp,$path)) throw new RuntimeException('Private storage unavailable.');
    } finally { if (is_file($tmp)) unlink($tmp); }
}
function driveLock(callable $work): mixed {
    $handle=fopen(driveRoot().'/google-drive.lock','c');chmod(driveRoot().'/google-drive.lock',0600);
    if (!$handle || !flock($handle,LOCK_EX)) throw new RuntimeException('Drive connection busy.');
    try { return $work(); } finally { flock($handle,LOCK_UN);fclose($handle); }
}
function driveTokenRequest(array $fields): array {
    global $config;
    if (!driveConfigured()) throw new RuntimeException('Configure Google Drive on the server first.');
    $fields+=driveClient();
    $curl=curl_init('https://oauth2.googleapis.com/token');
    curl_setopt_array($curl,[CURLOPT_POST=>true,CURLOPT_POSTFIELDS=>http_build_query($fields),CURLOPT_RETURNTRANSFER=>true,CURLOPT_FOLLOWLOCATION=>false,CURLOPT_CONNECTTIMEOUT=>15,CURLOPT_TIMEOUT=>30,CURLOPT_PROTOCOLS=>CURLPROTO_HTTPS]);
    $raw=curl_exec($curl);$status=curl_getinfo($curl,CURLINFO_RESPONSE_CODE);curl_close($curl);
    $reply=is_string($raw) ? json_decode($raw,true) : null;
    if ($status!==200 || !is_array($reply) || empty($reply['access_token'])) throw new RuntimeException('Google Drive authorization failed. Reconnect Drive on the server website.');
    return $reply;
}
function driveAccess(?string $connection=null): string {
    return driveLock(function() use ($connection) {
        $saved=driveRead();
        if (!$saved || ($connection!==null && $connection!==$saved['connection'])) throw new RuntimeException('Google Drive connection changed. Import this video again.');
        if (($saved['expires'] ?? 0)>time()+60) return $saved['access_token'];
        $reply=driveTokenRequest(['grant_type'=>'refresh_token','refresh_token'=>$saved['refresh_token']]);
        $saved['access_token']=$reply['access_token'];$saved['expires']=time()+(int)($reply['expires_in'] ?? 3600);
        if (isset($reply['refresh_token'])) $saved['refresh_token']=$reply['refresh_token'];
        privateJSON(driveRoot().'/google-drive.json',$saved);
        return $saved['access_token'];
    });
}
function driveID(mixed $id): string {
    if (!is_string($id) || !preg_match('/^[a-zA-Z0-9_-]{1,200}$/D',$id)) throw new InvalidArgumentException('Invalid Drive file or folder.');
    return $id;
}
function driveJSON(string $path,array $params=[],?string $connection=null): array {
    $curl=curl_init('https://www.googleapis.com/drive/v3/'.$path.'?'.http_build_query($params));
    $raw='';
    curl_setopt_array($curl,[CURLOPT_HTTPHEADER=>['Authorization: Bearer '.driveAccess($connection)],CURLOPT_FOLLOWLOCATION=>false,CURLOPT_CONNECTTIMEOUT=>15,CURLOPT_TIMEOUT=>45,CURLOPT_PROTOCOLS=>CURLPROTO_HTTPS,CURLOPT_WRITEFUNCTION=>static function($curl,$chunk) use (&$raw) { if (strlen($raw)+strlen($chunk)>4*1024*1024) return 0;$raw.=$chunk;return strlen($chunk); }]);
    $ok=curl_exec($curl);$status=curl_getinfo($curl,CURLINFO_RESPONSE_CODE);curl_close($curl);
    if (!$ok || $status!==200) throw new RuntimeException('Could not read Google Drive. Check access or reconnect on the server website.');
    return json_decode($raw,true,32,JSON_THROW_ON_ERROR);
}
function driveFiles(string $folder,string $page=''): array {
    $where=$folder==='shared' ? 'sharedWithMe=true' : "'".driveID($folder)."' in parents";
    $params=['q'=>"trashed=false and ($where) and (mimeType='application/vnd.google-apps.folder' or mimeType contains 'video/')",'pageSize'=>100,'orderBy'=>'folder,name','fields'=>'nextPageToken,files(id,name,mimeType,size)','supportsAllDrives'=>'true','includeItemsFromAllDrives'=>'true'];
    if ($page!=='') $params['pageToken']=$page;
    return driveJSON('files',$params);
}
function driveDownload(string $id,string $path,int $limit,string $connection): void {
    $out=fopen($path,'xb');
    if (!$out) throw new RuntimeException('Import storage unavailable.');
    chmod($path,0600);$bytes=0;
    $curl=curl_init('https://www.googleapis.com/drive/v3/files/'.driveID($id).'?alt=media&supportsAllDrives=true');
    try {
        curl_setopt_array($curl,[CURLOPT_HTTPHEADER=>['Authorization: Bearer '.driveAccess($connection)],CURLOPT_FOLLOWLOCATION=>false,CURLOPT_CONNECTTIMEOUT=>20,CURLOPT_TIMEOUT=>1800,CURLOPT_LOW_SPEED_LIMIT=>1024,CURLOPT_LOW_SPEED_TIME=>90,CURLOPT_PROTOCOLS=>CURLPROTO_HTTPS,CURLOPT_WRITEFUNCTION=>static function($curl,$chunk) use ($out,&$bytes,$limit) { $bytes+=strlen($chunk);if ($bytes>$limit) return 0;return fwrite($out,$chunk); }]);
        $ok=curl_exec($curl);$status=curl_getinfo($curl,CURLINFO_RESPONSE_CODE);
        if (!$ok || $status!==200 || $bytes===0) throw new RuntimeException('Drive download failed or exceeded the configured size limit. Check file download permissions and retry.');
    } catch (Throwable $e) { unlink($path);throw $e; }
    finally { curl_close($curl);fclose($out); }
}
function driveCaption(array $file,string $connection,string $directory): string {
    if (empty($file['parents'][0])) return '';
    $name=pathinfo($file['name'],PATHINFO_FILENAME).'.txt';
    $escape=static fn(string $s): string=>str_replace(["\\","'"],["\\\\","\\'"],$s);
    $reply=driveJSON('files',['q'=>"trashed=false and '".$escape($file['parents'][0])."' in parents and name='".$escape($name)."'",'fields'=>'files(id,size)','pageSize'=>2,'supportsAllDrives'=>'true','includeItemsFromAllDrives'=>'true'],$connection);
    $files=$reply['files'] ?? [];
    if (count($files)>1) throw new RuntimeException('More than one matching caption exists. Give the video a unique matching TXT filename.');
    if (!$files) return '';
    $path=$directory.'/caption.download';
    try {
        driveDownload($files[0]['id'],$path,1024*1024,$connection);$caption=file_get_contents($path);
        if (!mb_check_encoding($caption,'UTF-8')) throw new RuntimeException('Matching caption must be UTF-8 text.');
        return preg_replace('/^\xEF\xBB\xBF/','',$caption);
    } finally { if (is_file($path)) unlink($path); }
}
