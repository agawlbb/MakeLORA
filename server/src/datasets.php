<?php
declare(strict_types=1);
require_once __DIR__.'/filebeans.php';
function datasetRoot(): string { $root=datasetPrivateRoot().'/datasets';if (!is_dir($root)&&!mkdir($root,0700)&&!is_dir($root)) throw new RuntimeException('Dataset storage unavailable.');return $root; }
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
function datasetMediaURL(string $project,string $video,string $kind,string $device,int $version=0): string {
    global $config;$key=datasetPrivateRoot().'/dataset-signing-key';
    if (!is_file($key)) { $h=fopen($key,'x');if ($h) { chmod($key,0600);fwrite($h,bin2hex(random_bytes(32)));fclose($h); } }
    $params=['action'=>'dataset_media','project'=>$project,'video'=>$video,'kind'=>$kind,'device'=>$device,'version'=>$version,'expires'=>time()+3600];
    $params['signature']=hash_hmac('sha256',implode('|',array_values($params)),file_get_contents($key));
    return rtrim($config['base_url'],'/').'/api.php?'.http_build_query($params);
}
function datasetPublic(array $p,string $device): array {
    $videos=[];
    foreach ($p['videos'] as $v) {
        if ($v['status']==='ready') {
            $v['previewURL']=datasetMediaURL($p['id'],$v['id'],'preview',$device);
            $v['thumbnails']=[];if ($p['model']==='wan') for ($i=0;$i<8;$i++) $v['thumbnails'][]=datasetMediaURL($p['id'],$v['id'],'thumb'.$i,$device);
        }
        $videos[]=$v;
    }
    $p['videos']=$videos;$p['clips']=array_values($p['clips']);$p['exportDestination']='filebeans';$p['exportURL']=null;
    $p['exportFolder']=($p['exportStatus']==='ready'&&($p['exportRevision'] ?? -1)===$p['revision']) ? ($p['exportResult']['source'].' / '.$p['exportResult']['path']) : null;
    return $p;
}
function datasetSync(array &$p): void {
    foreach ($p['videos'] as &$v) {
        if (!in_array($v['status'],['queued','processing'],true)) continue;
        try { $j=filebeansAPI('GET','datasets/jobs/'.$v['job']); }
        catch (FileBeansFailure $e) { if ($e->reason==='locked') { $v['status']='blocked';$v['error']=$e->getMessage();continue; }throw $e; }
        $v['status']=$j['state'];$v['error']=$j['error'] ?? null;
        if ($j['state']==='ready'&&!isset($v['duration'])) {
            $v=array_merge($v,$j['info']);
            if ($p['model']==='wan'&&!array_filter($p['clips'],static fn($c)=>($c['videoID'] ?? '')===$v['id'])) { $id=bin2hex(random_bytes(16));$p['clips'][$id]=['id'=>$id,'videoID'=>$v['id'],'start'=>0.0,'end'=>$v['duration'],'crop'=>null,'caption'=>$v['caption'] ?? ''];$p['revision']++; }
        }
    }unset($v);
    if (isset($p['exportJob'])&&in_array($p['exportStatus'],['queued','processing'],true)) {
        try { $j=filebeansAPI('GET','datasets/jobs/'.$p['exportJob']); }
        catch (FileBeansFailure $e) { if ($e->reason==='locked') { $p['exportStatus']='blocked';$p['exportError']=$e->getMessage();return; }throw $e; }
        $p['exportStatus']=$j['state'];$p['exportError']=$j['error'] ?? null;
        if ($j['state']==='ready') { $p['exportResult']=$j['result'];if ($p['exportRevision']!==$p['revision']) { $p['exportStatus']='stale';$p['exportError']='Dataset changed during rendering. Render again to include the changes.'; } }
    }
}
function datasetCrop(mixed $crop): ?array {
    if ($crop===null) return null;
    if (!is_array($crop)) throw new InvalidArgumentException('Invalid crop.');
    foreach (['x','y','width','height'] as $key) if (!isset($crop[$key])||!is_numeric($crop[$key])||!is_finite((float)$crop[$key])) throw new InvalidArgumentException('Invalid crop.');
    $c=array_map('floatval',array_intersect_key($crop,array_flip(['x','y','width','height'])));
    if ($c['x']<0||$c['y']<0||$c['width']<0.05||$c['height']<0.05||$c['x']+$c['width']>1.000001||$c['y']+$c['height']>1.000001) throw new InvalidArgumentException('Crop must fit inside the source.');return $c;
}
function datasetClip(array $clip,array $p): array {
    $result=['id'=>datasetID($clip['id'] ?? null)];$caption=$clip['caption'] ?? '';
    if (!is_string($caption)||strlen($caption)>1024*1024||!mb_check_encoding($caption,'UTF-8')) throw new InvalidArgumentException('Caption must be UTF-8 text under 1 MB.');$result['caption']=$caption;
    $fields=$p['model']==='wan' ? ['videoID'] : ['control','target'];
    foreach ($fields as $field) { $id=datasetID($clip[$field] ?? null);if (($p['videos'][$id]['status'] ?? '')!=='ready') throw new InvalidArgumentException('Prepare the source before editing.');$result[$field]=$id; }
    if ($p['model']==='wan') {
        $start=$clip['start'] ?? null;$end=$clip['end'] ?? null;
        if (!is_numeric($start)||!is_numeric($end)||!is_finite((float)$start)||!is_finite((float)$end)||$start<0||$end-$start<0.1||$end>$p['videos'][$result['videoID']]['duration']+0.001) throw new InvalidArgumentException('Choose a valid trim of at least 0.1 seconds.');
        $result+=['start'=>(float)$start,'end'=>(float)$end,'crop'=>datasetCrop($clip['crop'] ?? null)];
    } else { $result+=['start'=>0.0,'end'=>0.0,'controlCrop'=>datasetCrop($clip['controlCrop'] ?? null),'targetCrop'=>datasetCrop($clip['targetCrop'] ?? null)]; }
    return $result;
}
function datasetInput(array $v): array { return array_intersect_key($v,array_flip(['id','source','path','revision'])); }
function datasetsAPI(string $action,array $device): never {
    if ($device['status']!=='active') fail('Approve pairing on the server first.',403);
    try {
        $method=$_SERVER['REQUEST_METHOD'];
        if ($action==='dataset_connection'&&$method==='GET') {
            if (!filebeansConfigured()) jsonResponse(['configured'=>false,'connected'=>false]);
            $cap=filebeansAPI('GET','capabilities');$ready=in_array('datasetMediaV1',$cap['features'] ?? [],true);
            jsonResponse(['configured'=>true,'connected'=>$ready,'workerReady'=>$ready]);
        }
        if ($action==='dataset_sources'&&$method==='GET') {
            $reply=filebeansAPI('GET','fs/sources');$allowed=filebeansSettings()['sources'];
            $reply['scopes']=array_values(array_filter($reply['scopes'],static fn($s)=>in_array($s['name'],$allowed,true)));jsonResponse($reply);
        }
        if ($action==='dataset_files'&&$method==='GET') jsonResponse(filebeansAPI('GET','fs/resources',filebeansLocation($_GET)));
        if ($action==='dataset_upload'&&$method==='POST') filebeansProxy('POST','datasets/uploads',filebeansLocation($_GET),true);
        if ($action==='datasets'&&$method==='GET') {
            $items=[];foreach (glob(datasetRoot().'/*/project.json') ?: [] as $path) { $p=json_decode(file_get_contents($path),true,32,JSON_THROW_ON_ERROR);if (!($p['deleted'] ?? false)) $items[]=['id'=>$p['id'],'name'=>$p['name'],'model'=>$p['model'] ?? 'wan','count'=>count($p['clips'])]; }
            usort($items,static fn($a,$b)=>strcmp($a['name'],$b['name']));jsonResponse(['projects'=>$items]);
        }
        if ($action==='dataset_create'&&$method==='POST') {
            $body=datasetBody();$model=$body['model'] ?? 'wan';if (!in_array($model,['wan','qwen'],true)) throw new InvalidArgumentException('Choose a dataset model.');
            $id=bin2hex(random_bytes(16));$p=['id'=>$id,'name'=>datasetName($body['name'] ?? null),'model'=>$model,'revision'=>0,'videos'=>[],'clips'=>[],'exportStatus'=>'none','exportError'=>null];
            mkdir(datasetPath($id),0700);privateJSON(datasetPath($id).'/project.json',$p);jsonResponse(datasetPublic($p,$device['id']),201);
        }
        $id=datasetID($_GET['id'] ?? null);
        if ($action==='dataset'&&$method==='GET') { $p=datasetUpdate($id,static function(&$p){datasetSync($p);});jsonResponse(datasetPublic($p,$device['id'])); }
        if ($action==='dataset_activity'&&$method==='POST') { filebeansActivity(datasetRead($id));jsonResponse(['active'=>true]); }
        if ($action==='dataset_import'&&$method==='POST') {
            $body=datasetBody();$files=$body['files'] ?? null;if (!is_array($files)||count($files)<1||count($files)>100) throw new InvalidArgumentException('Choose 1–100 sources.');
            $p=datasetUpdate($id,static function(&$p) use ($files) {
                foreach ($files as $file) {
                    $loc=filebeansLocation($file);$meta=filebeansAPI('GET','fs/resources',$loc);
                    $prefix=$p['model']==='wan' ? 'video/' : 'image/';if (!str_starts_with($meta['type'],$prefix)) throw new InvalidArgumentException('Choose media matching this dataset model.');
                    if (array_filter($p['videos'],static fn($v)=>$v['source']===$loc['source']&&$v['path']===$loc['path'])) continue;
                    if (count($p['videos'])>=500) throw new InvalidArgumentException('A dataset supports up to 500 sources.');
                    $vid=datasetID($file['id'] ?? null);$v=['id'=>$vid]+$loc+['revision'=>$meta['revision'],'name'=>$meta['name'],'status'=>'queued','error'=>null];
                    $job=filebeansAPI('POST','datasets/jobs',[],['operation'=>'prepare','model'=>$p['model'],'inputs'=>[datasetInput($v)],'destination'=>['source'=>'','path'=>'']],hash('sha256',$p['id'].$vid.$meta['revision']));
                    $v['job']=$job['id'];$p['videos'][$vid]=$v;$p['revision']++;
                }
            });jsonResponse(datasetPublic($p,$device['id']),202);
        }
        if ($action==='dataset_retry_source'&&$method==='POST') {
            $vid=datasetID($_GET['video'] ?? null);
            $p=datasetUpdate($id,static function(&$p) use ($vid) { if (!isset($p['videos'][$vid])) throw new InvalidArgumentException('Source missing.');filebeansAPI('POST','datasets/jobs/'.$p['videos'][$vid]['job'].'/retry',[],[]);$p['videos'][$vid]['status']='queued';$p['videos'][$vid]['error']=null; });jsonResponse(datasetPublic($p,$device['id']));
        }
        if ($action==='dataset_relink'&&$method==='POST') {
            $body=datasetBody();$vid=datasetID($body['video'] ?? null);$loc=filebeansLocation($body['location'] ?? null);
            $p=datasetUpdate($id,static function(&$p) use ($vid,$loc) {
                if (!isset($p['videos'][$vid])) throw new InvalidArgumentException('Source missing.');
                $meta=filebeansAPI('GET','fs/resources',$loc);if (!str_starts_with($meta['type'],$p['model']==='wan'?'video/':'image/')) throw new InvalidArgumentException('Choose matching media.');
                $v=['id'=>$vid]+$loc+['revision'=>$meta['revision'],'name'=>$meta['name'],'status'=>'queued','error'=>null,'reviewRequired'=>true];
                $job=filebeansAPI('POST','datasets/jobs',[],['operation'=>'prepare','model'=>$p['model'],'inputs'=>[datasetInput($v)],'destination'=>['source'=>'','path'=>'']],bin2hex(random_bytes(16)));
                $v['job']=$job['id'];$p['videos'][$vid]=$v;$p['revision']++;$p['exportStatus']='none';
            });jsonResponse(datasetPublic($p,$device['id']));
        }
        if ($action==='dataset_save'&&$method==='POST') {
            $body=datasetBody();$p=datasetUpdate($id,static function(&$p) use ($body) {
                if (($body['revision'] ?? -1)!==$p['revision']) throw new InvalidArgumentException('Dataset changed on another device. Reload before saving.');
                $clips=$body['clips'] ?? null;if (!is_array($clips)||count($clips)>500) throw new InvalidArgumentException('A dataset supports up to 500 clips or pairs.');
                $validated=[];foreach ($clips as $clip) { $c=datasetClip($clip,$p);if (isset($validated[$c['id']])) throw new InvalidArgumentException('Duplicate item.');$validated[$c['id']]=$c; }
                filebeansActivity($p);$p['clips']=$validated;$p['name']=datasetName($body['name'] ?? null);$p['revision']++;
                foreach (($body['reviewedSources'] ?? []) as $vid) { datasetID($vid);if (isset($p['videos'][$vid])) unset($p['videos'][$vid]['reviewRequired']); }
                if ($p['exportStatus']==='ready') $p['exportStatus']='none';
            });jsonResponse(datasetPublic($p,$device['id']));
        }
        if ($action==='dataset_remove_video'&&$method==='POST') {
            $vid=datasetID($_GET['video'] ?? null);$p=datasetUpdate($id,static function(&$p) use ($vid) {
                filebeansActivity($p);unset($p['videos'][$vid]);$p['clips']=array_filter($p['clips'],static fn($c)=>!in_array($vid,[$c['videoID'] ?? '',$c['control'] ?? '',$c['target'] ?? ''],true));$p['revision']++;$p['exportStatus']='none';
            });jsonResponse(datasetPublic($p,$device['id']));
        }
        if ($action==='dataset_destination'&&$method==='POST') {
            $body=datasetBody();$dest=filebeansLocation($body['destination'] ?? null);
            $meta=filebeansAPI('GET','fs/resources',$dest);if ($meta['type']!=='directory') throw new InvalidArgumentException('Choose an output folder.');
            $p=datasetUpdate($id,static function(&$p) use ($dest){filebeansActivity($p);$p['destination']=$dest;});jsonResponse(datasetPublic($p,$device['id']));
        }
        if ($action==='dataset_export'&&$method==='POST') {
            $body=datasetBody();$p=datasetUpdate($id,static function(&$p) use ($body) {
                if (!$p['clips']) throw new InvalidArgumentException('Add clips or pairs first.');
                if (in_array($p['exportStatus'],['queued','processing'],true)) return;
                if (array_filter($p['videos'],static fn($v)=>$v['reviewRequired'] ?? false)) throw new InvalidArgumentException('Review relinked source edits and save before rendering.');
                $dest=filebeansLocation($body['destination'] ?? $p['destination'] ?? null);
                $meta=filebeansAPI('GET','fs/resources',$dest);if ($meta['type']!=='directory') throw new InvalidArgumentException('Choose an output folder.');
                foreach ($p['videos'] as $v) { $meta=filebeansAPI('GET','fs/resources',['source'=>$v['source'],'path'=>$v['path']]);if ($meta['revision']!==$v['revision']) throw new FileBeansFailure('source_changed','Source changed. Relink it and review its edits.',409); }
                filebeansActivity($p);$p['destination']=$dest;
                $req=['operation'=>'render','model'=>$p['model'],'inputs'=>array_values(array_map('datasetInput',$p['videos'])),'clips'=>array_values($p['clips']),'destination'=>$dest];
                $j=filebeansAPI('POST','datasets/jobs',[],$req,hash('sha256',$p['id'].':'.$p['revision'].':'.json_encode($dest)));
                if (in_array($j['state'],['failed','blocked','cancelled'],true)) $j=filebeansAPI('POST','datasets/jobs/'.$j['id'].'/retry',[],[]);
                if ($j['state']==='ready') $p['exportResult']=$j['result'];
                $p['exportJob']=$j['id'];$p['exportRevision']=$p['revision'];$p['exportStatus']=$j['state'];$p['exportError']=$j['error'] ?? null;
            });jsonResponse(datasetPublic($p,$device['id']),202);
        }
        if ($action==='dataset_cancel_export'&&$method==='POST') { $p=datasetUpdate($id,static function(&$p){if (isset($p['exportJob'])) filebeansAPI('POST','datasets/jobs/'.$p['exportJob'].'/cancel',[],[]);$p['exportStatus']='cancelled';});jsonResponse(datasetPublic($p,$device['id'])); }
        if ($action==='dataset_delete'&&$method==='POST') { datasetUpdate($id,static function(&$p){$p['deleted']=true;});jsonResponse(['deleted'=>true]); }
        fail('Unknown dataset operation or method.',405);
    } catch (FileBeansFailure $e) { http_response_code($e->status);jsonResponse(['error'=>$e->getMessage(),'code'=>$e->reason],$e->status); }
    catch (InvalidArgumentException $e) { fail($e->getMessage()); }
    catch (RuntimeException $e) { fail($e->getMessage(),503); }
}
function serveDatasetMedia(): never {
    try {
        $id=datasetID($_GET['project'] ?? null);$vid=datasetID($_GET['video'] ?? null);$kind=(string)($_GET['kind'] ?? '');$device=datasetID($_GET['device'] ?? null);
        $version=(string)($_GET['version'] ?? '');$expiry=(string)($_GET['expires'] ?? '');$signature=(string)($_GET['signature'] ?? '');$key=datasetPrivateRoot().'/dataset-signing-key';
        if (!is_file($key)) fail('Preview link expired.',401);
        $expected=hash_hmac('sha256',implode('|',['dataset_media',$id,$vid,$kind,$device,$version,$expiry]),file_get_contents($key));
        if (!ctype_digit($version)||!ctype_digit($expiry)||(int)$expiry<time()||(int)$expiry>time()+3600||!hash_equals($expected,$signature)) fail('Preview link expired. Reload the dataset.',401);
        if (!query("SELECT id FROM makelora_devices WHERE id=? AND status='active'",[$device])->fetch()) fail('Device access revoked.',401);
        if ($kind!=='preview'&&!preg_match('/^thumb[0-7]$/D',$kind)) fail('Unknown media.',404);
        $p=datasetRead($id);$v=$p['videos'][$vid] ?? null;if (!$v||$v['status']!=='ready') fail('Preview unavailable.',404);
        filebeansProxy('GET','datasets/jobs/'.$v['job'].'/media/'.$kind);
    } catch (FileBeansFailure $e) { jsonResponse(['error'=>$e->getMessage(),'code'=>$e->reason],$e->status); }
    catch (Throwable $e) { fail('Preview unavailable. Reopen the dataset and retry.',503); }
}
