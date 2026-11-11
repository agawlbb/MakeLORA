<?php
declare(strict_types=1);
require_once __DIR__.'/private-session.php';
function supportedGenerationModel(?string $model): bool {
    return in_array(strtolower($model ?? ''), ['qwen/qwen-image-edit-2509','qwen-image-edit-2509'], true);
}
function generationSettings(array $input): array {
    $prompt=$input['prompt'] ?? ''; $image=$input['image'] ?? ''; $ratio=$input['aspect_ratio'] ?? 'match_input_image'; $scale=$input['lora_scale'] ?? 1;
    if (!is_string($prompt) || trim($prompt)==='' || strlen($prompt)>10000 || !is_string($image) || !preg_match('#^data:image/jpeg;base64,[A-Za-z0-9+/=]+$#D',$image) || !in_array($ratio,['match_input_image','1:1','16:9','9:16','4:3','3:4'],true) || !is_numeric($scale) || $scale<0 || $scale>4) fail('Invalid generation settings.');
    $args=['image'=>[$image],'prompt'=>$prompt,'aspect_ratio'=>$ratio,'lora_scale'=>(float)$scale,'output_format'=>'jpg','disable_safety_checker'=>true];
    if (isset($input['seed'])) {
        if (!is_int($input['seed']) || $input['seed']<0 || $input['seed']>2147483647) fail('Invalid seed.');
        $args['seed']=$input['seed'];
    }
    return $args;
}
function provider(string $path, ?array $body = null): array {
    global $config;
    $token = readReplicateToken($config['private_session_directory']);
    if (!$token) fail('Configure the Replicate token on the server first.',503);
    $curl = curl_init('https://api.replicate.com/v1/'.$path);
    curl_setopt_array($curl, [CURLOPT_RETURNTRANSFER=>true, CURLOPT_TIMEOUT=>60,
        CURLOPT_HTTPHEADER=>['Authorization: Bearer '.$token,'Content-Type: application/json']]);
    if ($body !== null) curl_setopt_array($curl,[CURLOPT_POST=>true,CURLOPT_POSTFIELDS=>json_encode($body,JSON_THROW_ON_ERROR)]);
    $raw=curl_exec($curl); $code=curl_getinfo($curl,CURLINFO_RESPONSE_CODE); curl_close($curl);
    if ($raw===false || $code<200 || $code>=300) fail('Generation provider request failed. Check server configuration or try again.',502);
    return json_decode($raw,true,512,JSON_THROW_ON_ERROR);
}
function serveWeights(): never {
    global $config;
    $sha=$_GET['sha'] ?? ''; $expires=$_GET['expires'] ?? ''; $signature=$_GET['signature'] ?? '';
    $token=readReplicateToken($config['private_session_directory']) ?? '';
    if (!preg_match('/^[a-f0-9]{64}$/D',$sha) || !preg_match('/^[0-9]{1,12}$/D',$expires) || (int)$expires<time() || (int)$expires>time()+3600 || $token==='' ||
        !hash_equals(hash_hmac('sha256',$sha.':'.$expires,$token),$signature)) fail('Download expired.',403);
    $file=query('SELECT storage_key FROM makelora_files WHERE sha256=?',[$sha])->fetch();
    if (!$file) fail('Weight unavailable.',404);
    $path=($config['file_storage_directory'] ?? dirname(__DIR__).'/storage/files').'/'.basename($file['storage_key']);
    if (!is_file($path)) fail('Weight unavailable.',404);
    header('Content-Disposition: attachment; filename="weights.safetensors"');
    header('Content-Type: application/octet-stream'); header('Content-Length: '.filesize($path)); readfile($path); exit;
}
// Originals remain private; only authenticated device requests serve images.
function outputDirectory(): string {
    global $config;
    $root=$config['private_session_directory'].'/outputs';
    if (!is_dir($root) && !mkdir($root,0700,true) && !is_dir($root)) throw new RuntimeException('Output storage unavailable.');
    return $root;
}
function downloadOutput(string $url, string $path): void {
    $parts=parse_url($url);
    $host=strtolower($parts['host'] ?? '');
    if (($parts['scheme'] ?? '')!=='https' || !($host==='replicate.delivery' || str_ends_with($host,'.replicate.delivery')) ||
        isset($parts['user']) || isset($parts['pass']) || isset($parts['port'])) throw new RuntimeException('Unexpected output URL.');
    $file=fopen($path,'wb');
    if (!$file) throw new RuntimeException('Output storage unavailable.');
    chmod($path,0600);
    $curl=curl_init($url); $size=0;
    try {
        curl_setopt_array($curl,[CURLOPT_TIMEOUT=>60,CURLOPT_FOLLOWLOCATION=>false,
            CURLOPT_WRITEFUNCTION=>static function($handle,string $data) use ($file,&$size): int {
                $size+=strlen($data);
                if ($size>50_000_000) return 0;
                return fwrite($file,$data);
            }]);
        $ok=curl_exec($curl); $code=curl_getinfo($curl,CURLINFO_RESPONSE_CODE);
        if ($ok===false || $code!==200) throw new RuntimeException('Could not archive output.');
    } finally { curl_close($curl); fclose($file); }
    $info=@getimagesize($path);
    if (!$info || ($info['mime'] ?? '')!=='image/jpeg') throw new RuntimeException('Invalid output image.');
}
function storedPrediction(array $job): array {
    return ['id'=>$job['id'],'status'=>$job['status'],'logs'=>$job['logs'] ?? '',
        'error'=>in_array($job['status'],['failed','canceled'],true) ? 'Generation '.$job['status'].'.' : null];
}
function syncGeneration(array $job): array {
    global $db;
    if (in_array($job['status'],['succeeded','failed','canceled'],true)) return storedPrediction($job);
    if (!$job['provider_id']) fail('Generation submission is still being recorded. Try again shortly.',503);
    // Always re-fetch the provider response; never trust webhook output URLs.
    $prediction=provider('predictions/'.rawurlencode($job['provider_id']));
    $written=[];
    $db->beginTransaction();
    try {
        $job=query('SELECT * FROM makelora_generations WHERE id=? FOR UPDATE',[$job['id']])->fetch();
        if (in_array($job['status'],['succeeded','failed','canceled'],true)) { $db->commit(); return storedPrediction($job); }
        if ($prediction['status']==='succeeded') {
            $urls=$prediction['output'] ?? [];
            if (!is_array($urls) || !$urls) throw new RuntimeException('Missing provider outputs.');
            foreach ($urls as $index=>$url) {
                // Tombstones prevent retries from recreating removed gallery images.
                if (query('SELECT id FROM makelora_outputs WHERE generation_id=? AND output_index=?',[$job['id'],$index])->fetch()) continue;
                $id=sprintf('%016x',(int)(microtime(true)*1000000)).bin2hex(random_bytes(24));
                $filename=$id.'.jpg'; $destination=outputDirectory().'/'.$filename;
                $temporary=tempnam(outputDirectory(),'.output-');
                if ($temporary===false) throw new RuntimeException('Output storage unavailable.');
                try {
                    downloadOutput($url,$temporary);
                    if (!rename($temporary,$destination)) throw new RuntimeException('Output storage unavailable.');
                    $written[]=$destination;
                } finally { if (is_file($temporary)) unlink($temporary); }
                query('INSERT INTO makelora_outputs (id,generation_id,output_index,storage_key,created_at) VALUES (?,?,?,?,UTC_TIMESTAMP())',[$id,$job['id'],$index,$filename]);
            }
        }
        $job['status']=$prediction['status'];
        $job['logs']=substr($prediction['logs'] ?? '',0,20000);
        query('UPDATE makelora_generations SET status=?,logs=? WHERE id=?',[$job['status'],$job['logs'],$job['id']]);
        $db->commit();
        return storedPrediction($job);
    } catch (Throwable $error) {
        if ($db->inTransaction()) $db->rollBack();
        foreach ($written as $path) if (is_file($path)) unlink($path);
        throw $error;
    }
}
function generationWebhook(?array $payload=null): never {
    $id=$_GET['id'] ?? ''; $secret=$_GET['secret'] ?? '';
    if (!is_string($id) || !is_string($secret) || !preg_match('/^[a-f0-9]{64}$/D',$secret)) fail('Invalid callback.',403);
    $job=query('SELECT * FROM makelora_generations WHERE id=?',[$id])->fetch();
    if (!$job || !$job['callback_hash'] || !hash_equals($job['callback_hash'],hash('sha256',$secret))) fail('Invalid callback.',403);
    if (!$job['provider_id']) {
        // Recover a callback that races submission, including a lost create response.
        if ($payload===null) {
            $raw=file_get_contents('php://input',false,null,0,20000001);
            if (strlen($raw)>20000000) fail('Callback too large.',413);
            $payload=json_decode($raw,true,64,JSON_THROW_ON_ERROR);
        }
        $candidate=$payload['id'] ?? '';
        if (!is_string($candidate) || !preg_match('/^[a-zA-Z0-9_-]{1,100}$/D',$candidate)) fail('Invalid callback.',403);
        $actual=provider('predictions/'.rawurlencode($candidate));
        $callbackQuery=[];
        parse_str(parse_url($actual['webhook'] ?? '',PHP_URL_QUERY) ?: '',$callbackQuery);
        $actualSecret=$callbackQuery['secret'] ?? '';
        if (($callbackQuery['id'] ?? '')!==$job['id'] || !is_string($actualSecret) ||
            !hash_equals($job['callback_hash'],hash('sha256',$actualSecret))) fail('Callback prediction mismatch.',403);
        query('UPDATE makelora_generations SET provider_id=? WHERE id=? AND provider_id IS NULL',[$candidate,$job['id']]);
        $job=query('SELECT * FROM makelora_generations WHERE id=?',[$job['id']])->fetch();
    }
    syncGeneration($job);
    jsonResponse(['status'=>'received']);
}
function startGeneration(array $input, array $device): array {
    global $config;
    $file=query('SELECT * FROM makelora_files WHERE sha256=?',[$input['model'] ?? ''])->fetch();
    if (!$file || !supportedGenerationModel($file['target_model'])) fail('Choose a Qwen-edit weight.');
    $args=generationSettings($input);
    $token=readReplicateToken($config['private_session_directory']) ?? '';
    if ($token==='') fail('Configure the Replicate token on the server first.',503);
    // Check storage before starting a paid job.
    outputDirectory();
    $expires=(string)(time()+3600); $sha=$file['sha256'];
    $base=rtrim($config['base_url'],'/').'/api.php?';
    $args['lora_weights']=$base.http_build_query(['action'=>'weights','sha'=>$sha,'expires'=>$expires,'signature'=>hash_hmac('sha256',$sha.':'.$expires,$token)]);
    $id=bin2hex(random_bytes(32)); $callback=bin2hex(random_bytes(32));
    query('INSERT INTO makelora_generations (id,device_id,model_name,prompt,callback_hash,created_at) VALUES (?,?,?,?,?,UTC_TIMESTAMP())',[$id,$device['id'],$file['display_name'],$input['prompt'],hash('sha256',$callback)]);
    $prediction=provider('models/qwen/qwen-image-edit-plus-lora/predictions',[
        'input'=>$args,'webhook'=>$base.http_build_query(['action'=>'generation_webhook','id'=>$id,'secret'=>$callback]),
        'webhook_events_filter'=>['completed']]);
    query('UPDATE makelora_generations SET provider_id=? WHERE id=?',[$prediction['id'],$id]);
    return ['id'=>$id,'status'=>$prediction['status'],'logs'=>'','error'=>null];
}
function galleryPage(string $before=''): array {
    if ($before!=='' && !preg_match('/^[a-f0-9]{64}$/D',$before)) fail('Invalid gallery cursor.');
    $rows=query("SELECT o.id,g.model_name AS model,COALESCE(g.prompt,'') AS prompt,DATE_FORMAT(o.created_at,'%Y-%m-%dT%H:%i:%sZ') AS date FROM makelora_outputs o JOIN makelora_generations g ON g.id=o.generation_id WHERE o.deleted_at IS NULL AND o.id<? ORDER BY o.id DESC LIMIT 101",[$before==='' ? str_repeat('f',64) : $before])->fetchAll();
    $more=count($rows)>100;
    $rows=array_slice($rows,0,100);
    return ['outputs'=>$rows,'next'=>$more ? $rows[count($rows)-1]['id'] : null];
}
function outputRecord(string $id): array {
    $row=query('SELECT * FROM makelora_outputs WHERE id=? AND deleted_at IS NULL',[$id])->fetch();
    if (!$row) fail('Image not found.',404);
    return $row;
}
function serveOutput(string $id): never {
    $row=outputRecord($id);
    $path=outputDirectory().'/'.basename($row['storage_key']);
    if (!is_file($path)) fail('Image unavailable.',404);
    header('Content-Type: image/jpeg'); header('Content-Length: '.filesize($path));
    header('Content-Disposition: inline; filename="MakeLORA-'.$row['id'].'.jpg"');
    readfile($path); exit;
}
function removeOutput(string $id): void {
    $row=outputRecord($id);
    query('UPDATE makelora_outputs SET deleted_at=UTC_TIMESTAMP() WHERE id=? AND deleted_at IS NULL',[$id]);
    $path=outputDirectory().'/'.basename($row['storage_key']);
    if (is_file($path) && !unlink($path)) throw new RuntimeException('Could not remove output file.');
}
function generationAPI(string $action, array $device): void {
    if ($device['status']!=='active') fail('Approve pairing on the server first.',403);
    $method=$_SERVER['REQUEST_METHOD'];
    if ($action==='models' && $method==='GET') {
        $files=query('SELECT sha256 AS id,display_name AS displayName,target_model AS baseModel,size_bytes AS sizeBytes,inspection_json FROM makelora_files ORDER BY display_name,sha256')->fetchAll();
        foreach ($files as &$file) {
            $file['sizeBytes']=(int)$file['sizeBytes'];
            $file['details']=json_encode(json_decode($file['inspection_json'],true)['metadata'] ?? [],JSON_UNESCAPED_SLASHES);
            unset($file['inspection_json']);
            $file['supported']=supportedGenerationModel($file['baseModel']);
        }
        jsonResponse(['models'=>$files]);
    }
    if ($action==='gallery' && $method==='GET') jsonResponse(galleryPage($_GET['before'] ?? ''));
    if ($action==='output' && $method==='GET') serveOutput($_GET['id'] ?? '');
    if ($action==='remove_output' && $method==='POST') {
        removeOutput($_GET['id'] ?? ''); jsonResponse(['status'=>'removed']);
    }
    if ($action==='prediction' && $method==='GET') {
        $job=query('SELECT * FROM makelora_generations WHERE id=?',[$_GET['id'] ?? ''])->fetch();
        if (!$job) fail('Generation not found.',404);
        jsonResponse(syncGeneration($job));
    }
    if ($action==='generate' && $method==='POST') {
        $raw=file_get_contents('php://input',false,null,0,16000001);
        if (strlen($raw)>16000000) fail('Input image too large.',413);
        jsonResponse(startGeneration(json_decode($raw,true,16,JSON_THROW_ON_ERROR),$device),201);
    }
}
