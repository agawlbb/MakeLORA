<?php
declare(strict_types=1);
require_once __DIR__.'/drive.php';
require_once __DIR__.'/video-output.php';
require_once __DIR__.'/dataset-folders.php';

function datasetRoot(): string {
    $root=driveRoot().'/datasets';
    if (!is_dir($root) && !mkdir($root,0700) && !is_dir($root)) throw new RuntimeException('Dataset storage unavailable.');
    return $root;
}
function datasetID(mixed $id): string {
    if (!is_string($id) || !preg_match('/^[a-f0-9]{32}$/D',$id)) throw new InvalidArgumentException('Invalid dataset item.');
    return $id;
}
function datasetPath(string $id): string { return datasetRoot().'/'.datasetID($id); }
function datasetRead(string $id): array {
    $path=datasetPath($id).'/project.json';
    if (!is_file($path)) throw new InvalidArgumentException('Dataset no longer exists.');
    $project=json_decode(file_get_contents($path),true,32,JSON_THROW_ON_ERROR);
    if ($project['deleted'] ?? false) throw new InvalidArgumentException('Dataset no longer exists.');
    return $project;
}
function datasetUpdate(string $id,callable $work): array {
    $directory=datasetPath($id);
    if (!is_dir($directory)) throw new InvalidArgumentException('Dataset no longer exists.');
    $handle=fopen($directory.'/lock','c');chmod($directory.'/lock',0600);
    if (!$handle || !flock($handle,LOCK_EX)) throw new RuntimeException('Dataset is busy.');
    try { $project=datasetRead($id);$work($project);privateJSON($directory.'/project.json',$project);return $project; }
    finally { flock($handle,LOCK_UN);fclose($handle); }
}
function datasetBody(): array {
    if ((int)($_SERVER['CONTENT_LENGTH'] ?? 0)>2*1024*1024) fail('Request too large.',413);
    $raw=file_get_contents('php://input',false,null,0,2*1024*1024+1);
    if (strlen($raw)>2*1024*1024) fail('Request too large.',413);
    $body=json_decode($raw,true,32,JSON_THROW_ON_ERROR);
    if (!is_array($body)) throw new InvalidArgumentException('Invalid request.');
    return $body;
}
function datasetName(mixed $name): string {
    if (!is_string($name) || trim($name)==='' || mb_strlen($name)>100) throw new InvalidArgumentException('Enter a dataset name of 1–100 characters.');
    return trim($name);
}
function datasetClip(array $clip,array $project): array {
    $id=datasetID($clip['id'] ?? null);$video=datasetID($clip['videoID'] ?? null);
    $source=$project['videos'][$video] ?? null;
    if (!$source || $source['status']!=='ready') throw new InvalidArgumentException('Wait for the video preview to finish.');
    $start=$clip['start'] ?? null;$end=$clip['end'] ?? null;
    if ((!is_int($start) && !is_float($start)) || (!is_int($end) && !is_float($end)) || !is_finite((float)$start) || !is_finite((float)$end) || $start<0 || $end-$start<0.1 || $end>$source['duration']+0.001) throw new InvalidArgumentException('Choose a valid trim of at least 0.1 seconds.');
    $caption=$clip['caption'] ?? '';
    if (!is_string($caption) || strlen($caption)>1024*1024 || !mb_check_encoding($caption,'UTF-8')) throw new InvalidArgumentException('Caption must be UTF-8 text under 1 MB.');
    $crop=$clip['crop'] ?? null;
    if ($crop!==null) {
        if (!is_array($crop)) throw new InvalidArgumentException('Invalid crop.');
        foreach (['x','y','width','height'] as $key) if (!isset($crop[$key]) || !is_numeric($crop[$key]) || !is_finite((float)$crop[$key])) throw new InvalidArgumentException('Invalid crop.');
        $crop=array_map('floatval',array_intersect_key($crop,array_flip(['x','y','width','height'])));
        if ($crop['x']<0 || $crop['y']<0 || $crop['width']<0.05 || $crop['height']<0.05 || $crop['x']+$crop['width']>1.000001 || $crop['y']+$crop['height']>1.000001) throw new InvalidArgumentException('Crop must fit inside the video.');
        $ratio=($source['width']*$crop['width'])/($source['height']*$crop['height']);
        if ($ratio<1/16 || $ratio>16) throw new InvalidArgumentException('Crop is too narrow.');
    }
    return ['id'=>$id,'videoID'=>$video,'start'=>(float)$start,'end'=>(float)$end,'caption'=>$caption,'crop'=>$crop];
}
function datasetSigningKey(): string {
    $path=driveRoot().'/dataset-signing-key';
    // The key is immutable: playback must not wait for Google's token-refresh lock.
    if (is_file($path)) return file_get_contents($path);
    return driveLock(static function() {
        $path=driveRoot().'/dataset-signing-key';
        if (!is_file($path)) {
            $temporary=tempnam(driveRoot(),'.signing-');
            try { chmod($temporary,0600);file_put_contents($temporary,bin2hex(random_bytes(32)));if (!rename($temporary,$path)) throw new RuntimeException('Preview signing unavailable.'); }
            finally { if (is_file($temporary)) unlink($temporary); }
        }
        return file_get_contents($path);
    });
}
function datasetMediaURL(string $project,string $video,string $kind,string $device,int $version=0): string {
    global $config;
    $params=['action'=>'dataset_media','project'=>$project,'video'=>$video,'kind'=>$kind,'device'=>$device,'version'=>$version,'expires'=>time()+3600];
    $params['signature']=hash_hmac('sha256',implode('|',array_values($params)),datasetSigningKey());
    return rtrim($config['base_url'],'/').'/api.php?'.http_build_query($params);
}
function datasetPublic(array $p,string $device): array {
    $videos=[];
    foreach ($p['videos'] as $video) {
        unset($video['connection'],$video['device']);
        if ($video['status']==='ready') {
            $video['previewURL']=datasetMediaURL($p['id'],$video['id'],'preview',$device);
            $video['thumbnails']=[];
            for ($i=0;$i<8;$i++) $video['thumbnails'][]=datasetMediaURL($p['id'],$video['id'],'thumb'.$i,$device);
        }
        $videos[]=$video;
    }
    unset($p['exportDevice']);$p['videos']=$videos;$p['clips']=array_values($p['clips']);
    $p['exportDestination']=datasetFolderConfigured() ? 'filebrowser' : 'zip';
    $p['exportFolder']=($p['exportStatus']==='ready' && ($p['exportRevision'] ?? -1)===$p['revision'] && ($p['exportFormat'] ?? 'zip')==='folder' && isset($p['exportFolderName'])) ? datasetFolderLabel().' / '.$p['exportFolderName'] : null;
    unset($p['exportFolderName']);
    $p['exportURL']=(($p['exportFormat'] ?? 'zip')==='zip' && $p['exportStatus']==='ready' && ($p['exportRevision'] ?? -1)===$p['revision']) ? datasetMediaURL($p['id'],'','export',$device,$p['revision']) : null;
    return $p;
}
function datasetWorkerReady(): bool {
    $root=datasetRoot();
    if (is_file($root.'/heartbeat') && filemtime($root.'/heartbeat')>time()-120) return true;
    $lock=fopen($root.'/worker.lock','c');chmod($root.'/worker.lock',0600);
    if (!$lock) return false;
    $idle=flock($lock,LOCK_EX|LOCK_NB);
    if ($idle) flock($lock,LOCK_UN);
    fclose($lock);return !$idle;
}
function datasetsAPI(string $action,array $device): never {
    if ($device['status']!=='active') fail('Approve pairing on the server first.',403);
    try {
        $method=$_SERVER['REQUEST_METHOD'];
        if ($action==='drive_status' && $method==='GET') jsonResponse(['configured'=>driveConfigured(),'connected'=>driveRead()!==null,'workerReady'=>datasetWorkerReady()]);
        if ($action==='drive_files' && $method==='GET') {
            $page=$_GET['page'] ?? '';if (!is_string($page) || strlen($page)>4096) throw new InvalidArgumentException('Invalid page.');
            jsonResponse(driveFiles((string)($_GET['folder'] ?? 'root'),$page));
        }
        if ($action==='datasets' && $method==='GET') {
            $items=[];foreach (glob(datasetRoot().'/*/project.json') ?: [] as $path) {
                $raw=@file_get_contents($path);if ($raw===false) continue;
                $p=json_decode($raw,true,32,JSON_THROW_ON_ERROR);if ($p['deleted'] ?? false) continue;
                $items[]=['id'=>$p['id'],'name'=>$p['name'],'count'=>count($p['clips'])];
            }
            usort($items,static fn($a,$b)=>strcmp($a['name'],$b['name']));jsonResponse(['projects'=>$items]);
        }
        if ($action==='dataset_create' && $method==='POST') {
            $body=datasetBody();$id=bin2hex(random_bytes(16));
            $p=['id'=>$id,'name'=>datasetName($body['name'] ?? null),'revision'=>0,'videos'=>[],'clips'=>[],'exportStatus'=>'none','exportError'=>null];
            mkdir(datasetPath($id),0700);privateJSON(datasetPath($id).'/project.json',$p);jsonResponse(datasetPublic($p,$device['id']),201);
        }
        $id=datasetID($_GET['id'] ?? null);
        if ($action==='dataset' && $method==='GET') jsonResponse(datasetPublic(datasetRead($id),$device['id']));
        if ($action==='dataset_import' && $method==='POST') {
            $body=datasetBody();$ids=$body['files'] ?? null;
            if (!is_array($ids) || count($ids)<1 || count($ids)>100) throw new InvalidArgumentException('Choose 1–100 videos.');
            foreach ($ids as $file) driveID($file);
            $connection=driveRead()['connection'] ?? null;
            if (!$connection) throw new InvalidArgumentException('Connect Google Drive on the server website first.');
            $p=datasetUpdate($id,static function(&$p) use ($ids,$connection,$device) {
                foreach (array_unique($ids) as $file) {
                    $existing=array_filter($p['videos'],static fn($v)=>$v['driveID']===$file && $v['status']!=='failed' && $v['connection']===$connection);
                    if ($existing) continue;
                    $failed=array_filter($p['videos'],static fn($v)=>$v['driveID']===$file && $v['status']==='failed');
                    if (!$failed && count($p['videos'])>=500) throw new InvalidArgumentException('A dataset supports up to 500 source videos.');
                    $video=$failed ? array_key_first($failed) : bin2hex(random_bytes(16));
                    $p['videos'][$video]=['id'=>$video,'driveID'=>$file,'connection'=>$connection,'device'=>$device['id'],'name'=>'Drive video','status'=>'queued','error'=>null];
                }
            });jsonResponse(datasetPublic($p,$device['id']),202);
        }
        if ($action==='dataset_save' && $method==='POST') {
            $body=datasetBody();
            $p=datasetUpdate($id,static function(&$p) use ($body) {
                if (($body['revision'] ?? -1)!==$p['revision']) throw new InvalidArgumentException('Dataset changed on another device. Reload before saving.');
                $clips=$body['clips'] ?? null;
                if (!is_array($clips) || count($clips)>500) throw new InvalidArgumentException('A dataset supports up to 500 clips.');
                $validated=[];
                foreach ($clips as $clip) { if (!is_array($clip)) throw new InvalidArgumentException('Invalid clip.');$c=datasetClip($clip,$p);if (isset($validated[$c['id']])) throw new InvalidArgumentException('Duplicate clip.');$validated[$c['id']]=$c; }
                $p['name']=datasetName($body['name'] ?? null);$p['clips']=$validated;$p['revision']++;
                if ($p['exportStatus']==='ready') $p['exportStatus']='none';
            });jsonResponse(datasetPublic($p,$device['id']));
        }
        if ($action==='dataset_remove_video' && $method==='POST') {
            $video=datasetID($_GET['video'] ?? null);
            $p=datasetUpdate($id,static function(&$p) use ($video) {
                if (!isset($p['videos'][$video])) throw new InvalidArgumentException('Source video no longer exists.');
                if ($p['videos'][$video]['status']==='processing' || $p['exportStatus']==='processing') throw new InvalidArgumentException('Wait for processing to finish before removing a source video.');
                unset($p['videos'][$video]);
                $p['clips']=array_filter($p['clips'],static fn($clip)=>$clip['videoID']!==$video);
                $p['revision']++;$p['exportStatus']='none';$p['exportError']=null;
            });
            $directory=datasetPath($id).'/'.$video;if (is_dir($directory)) datasetRemoveTree($directory);
            jsonResponse(datasetPublic($p,$device['id']));
        }
        if ($action==='dataset_export' && $method==='POST') {
            $body=datasetBody();$format=$body['format'] ?? datasetExportFormat();
            if (!in_array($format,['folder','zip'],true)) throw new InvalidArgumentException('Choose a folder or ZIP export.');
            if ($format==='folder') datasetFolderRoot();
            $p=datasetUpdate($id,static function(&$p) use ($device,$format) {
                if (!$p['clips']) throw new InvalidArgumentException('Add at least one clip.');
                if (in_array($p['exportStatus'],['queued','processing'],true)) return;
                $p['exportStatus']='queued';$p['exportDevice']=$device['id'];$p['exportError']=null;$p['exportFormat']=$format;
            });jsonResponse(datasetPublic($p,$device['id']),202);
        }
        if ($action==='dataset_delete' && $method==='POST') {
            // Keep directory and lock inode stable during deletion; worker checks the tombstone.
            datasetUpdate($id,static function(&$p) {
                if ($p['exportStatus']==='processing' || array_filter($p['videos'],static fn($v)=>$v['status']==='processing')) throw new InvalidArgumentException('Wait for processing to finish before deleting.');
                $p['deleted']=true;
            });
            datasetRemoveTree(datasetPath($id));jsonResponse(['deleted'=>true]);
        }
        fail('Unknown dataset operation or method.',405);
    } catch (InvalidArgumentException $e) { fail($e->getMessage()); }
    catch (RuntimeException $e) { fail($e->getMessage(),503); }
}
function datasetRemoveTree(string $path): void {
    foreach (scandir($path) ?: [] as $item) if ($item!=='.' && $item!=='..') { $child=$path.'/'.$item;if (is_dir($child) && !is_link($child)) datasetRemoveTree($child);else unlink($child); }
    rmdir($path);
}
function serveDatasetMedia(): never {
    try {
        $id=datasetID($_GET['project'] ?? null);$video=(string)($_GET['video'] ?? '');$kind=(string)($_GET['kind'] ?? '');$device=datasetID($_GET['device'] ?? null);
        $version=(string)($_GET['version'] ?? '');$expiry=(string)($_GET['expires'] ?? '');$signature=(string)($_GET['signature'] ?? '');
        $expected=hash_hmac('sha256',implode('|',['dataset_media',$id,$video,$kind,$device,$version,$expiry]),datasetSigningKey());
        if (!ctype_digit($version) || !ctype_digit($expiry) || (int)$expiry<time() || (int)$expiry>time()+3600 || !hash_equals($expected,$signature)) fail('Preview link expired. Reload the dataset.',401);
        $active=query("SELECT id FROM makelora_devices WHERE id=? AND status='active'",[$device])->fetch();
        if (!$active) fail('Device access revoked.',401);
        $p=datasetRead($id);
        if ($kind==='export') {
            if (($p['exportFormat'] ?? 'zip')!=='zip' || $video!=='' || (int)$version!==$p['revision'] || $p['exportStatus']!=='ready' || ($p['exportRevision'] ?? -1)!==$p['revision']) fail('Export is no longer current.',404);
            $path=datasetPath($id).'/dataset-'.$p['exportRevision'].'.zip';$mime='application/zip';header('Content-Disposition: attachment; filename="dataset.zip"');
        } else {
            datasetID($video);
            if (($p['videos'][$video]['status'] ?? '')!=='ready') fail('Preview unavailable.',404);
            if ($kind==='preview') { $path=datasetPath($id).'/'.$video.'/preview.mp4';$mime='video/mp4'; }
            elseif (preg_match('/^thumb[0-7]$/D',$kind)) { $path=datasetPath($id).'/'.$video.'/'.$kind.'.jpg';$mime='image/jpeg'; }
            else fail('Unknown media.',404);
        }
        $handle=@fopen($path,'rb');if (!$handle) fail('Media unavailable.',404);
        $size=fstat($handle)['size'];$range=outputByteRange($_SERVER['HTTP_RANGE'] ?? null,$size);
        header('Accept-Ranges: bytes');header('Content-Type: '.$mime);header('Cache-Control: private, no-store');
        if ($range===false) { fclose($handle);header('Content-Range: bytes */'.$size);http_response_code(416);exit; }
        [$start,$end]=$range;
        if (isset($_SERVER['HTTP_RANGE'])) { http_response_code(206);header("Content-Range: bytes $start-$end/$size"); }
        header('Content-Length: '.($end-$start+1));
        if ($_SERVER['REQUEST_METHOD']==='HEAD') { fclose($handle);exit; }
        fseek($handle,$start);$left=$end-$start+1;
        while ($left>0 && !feof($handle) && !connection_aborted()) { $chunk=fread($handle,min($left,1024*1024));if ($chunk===false || $chunk==='') break;echo $chunk;$left-=strlen($chunk); }
        fclose($handle);exit;
    } catch (InvalidArgumentException $e) { fail('Media unavailable.',404); }
    catch (Throwable $e) { fail('Media unavailable.',503); }
}
