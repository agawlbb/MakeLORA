<?php
declare(strict_types=1);
require_once __DIR__.'/private-session.php';
require_once __DIR__.'/retry-queue.php';
require_once __DIR__.'/generation-recipes.php';
require_once __DIR__.'/generation-models.php';
require_once __DIR__.'/video-output.php';
function qwenGenerationSettings(array $input): array {
    $prompt=$input['prompt'] ?? ''; $image=$input['image'] ?? ''; $ratio=$input['aspect_ratio'] ?? 'match_input_image'; $scale=$input['lora_scale'] ?? 1;
    if (!is_string($prompt) || trim($prompt)==='' || strlen($prompt)>10000 || !is_string($image) || !preg_match('#^data:image/jpeg;base64,[A-Za-z0-9+/=]+$#D',$image) || !in_array($ratio,['match_input_image','1:1','16:9','9:16','4:3','3:4'],true) || !is_numeric($scale) || $scale<0 || $scale>4) fail('Invalid generation settings.');
    $args=['image'=>[$image],'prompt'=>$prompt,'aspect_ratio'=>$ratio,'lora_scale'=>(float)$scale,'output_format'=>'jpg','disable_safety_checker'=>true];
    if (isset($input['seed'])) {
        if (!is_int($input['seed']) || $input['seed']<0 || $input['seed']>2147483647) fail('Invalid seed.');
        $args['seed']=$input['seed'];
    }
    return $args;
}
final class ProviderFailure extends RuntimeException {
    public readonly string $reference;
    public function __construct(public readonly int $httpStatus, public readonly int $retryAfter = 30, int $transportError = 0) {
        $this->reference=bin2hex(random_bytes(6));
        $reason=match ($httpStatus) {
            401,403 => "Replicate rejected the server API token or model access (HTTP $httpStatus). Update the saved server token or its permissions before retrying.",
            402 => 'Replicate requires billing credit (HTTP 402). Add credit in Replicate before submitting again.',
            404 => 'Replicate could not find this model or generation (HTTP 404). Remove an unavailable generation tile, or check model availability before submitting again.',
            400,422 => "Replicate rejected the generation settings (HTTP $httpStatus). Check the image, prompt and model settings before retrying.",
            429 => "Replicate rate limit reached (HTTP 429). Wait $retryAfter seconds before retrying.",
            0 => 'The server could not reach Replicate. Check server network access and retry later.',
            default => "Replicate is temporarily unavailable (HTTP $httpStatus). Retry later."
        };
        parent::__construct($reason.' Reference: '.$this->reference);
        // Never log provider response bodies, input images, URLs or credentials.
        error_log("MakeLORA provider failure ref={$this->reference} http=$httpStatus transport=$transportError");
    }
    public function definiteRejection(): bool { return $this->httpStatus>=400 && $this->httpStatus<500 && $this->httpStatus!==408; }
    public function respond(?string $jobID=null, ?string $jobStatus=null): never {
        $reply=['error'=>$this->getMessage(),'reference'=>$this->reference,'retryAfter'=>$this->retryAfter];
        if ($jobID!==null) $reply['jobID']=$jobID;
        if ($jobStatus!==null) $reply['jobStatus']=$jobStatus;
        jsonResponse($reply,$this->httpStatus===429 ? 429 : 502);
    }
}
function provider(string $path, ?array $body = null): array {
    global $config;
    $token = readReplicateToken($config['private_session_directory']);
    if (!$token) fail('Configure the Replicate token on the server first.',503);
    $curl = curl_init('https://api.replicate.com/v1/'.$path);
    $retryAfter=30;
    curl_setopt_array($curl, [CURLOPT_RETURNTRANSFER=>true, CURLOPT_TIMEOUT=>60,
        CURLOPT_HEADERFUNCTION=>static function($handle,string $header) use (&$retryAfter): int {
            if (preg_match('/^Retry-After:\s*([0-9]+)/i',$header,$match)) $retryAfter=max(5,min(300,(int)$match[1]));
            return strlen($header);
        },
        CURLOPT_HTTPHEADER=>['Authorization: Bearer '.$token,'Content-Type: application/json']]);
    if ($body !== null) curl_setopt_array($curl,[CURLOPT_POST=>true,CURLOPT_POSTFIELDS=>json_encode($body,JSON_THROW_ON_ERROR)]);
    $raw=curl_exec($curl); $code=curl_getinfo($curl,CURLINFO_RESPONSE_CODE); $transportError=curl_errno($curl); curl_close($curl);
    if ($raw===false || $code<200 || $code>=300) throw new ProviderFailure($raw===false ? 0 : $code,$retryAfter,$transportError);
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
    header('Content-Type: application/octet-stream'); header('Content-Length: '.filesize($path));
    if ($_SERVER['REQUEST_METHOD']!=='HEAD') readfile($path);
    exit;
}
// Originals remain private; only authenticated device requests serve images.
function outputDirectory(): string {
    global $config;
    $root=$config['private_session_directory'].'/outputs';
    if (!is_dir($root) && !mkdir($root,0700,true) && !is_dir($root)) throw new RuntimeException('Output storage unavailable.');
    return $root;
}
function downloadOutput(string $url, string $path,bool $video=false): void {
    $parts=parse_url($url);
    $host=strtolower($parts['host'] ?? '');
    if (($parts['scheme'] ?? '')!=='https' || !($host==='replicate.delivery' || str_ends_with($host,'.replicate.delivery')) ||
        isset($parts['user']) || isset($parts['pass']) || isset($parts['port'])) throw new RuntimeException('Unexpected output URL.');
    $file=fopen($path,'wb');
    if (!$file) throw new RuntimeException('Output storage unavailable.');
    chmod($path,0600);
    $curl=curl_init($url); $size=0;
    try {
        curl_setopt_array($curl,[CURLOPT_TIMEOUT=>180,CURLOPT_FOLLOWLOCATION=>false,
            CURLOPT_WRITEFUNCTION=>static function($handle,string $data) use ($file,&$size,$video): int {
                $size+=strlen($data);
                if ($size>($video ? 250_000_000:50_000_000)) return 0;
                return fwrite($file,$data);
            }]);
        $ok=curl_exec($curl); $code=curl_getinfo($curl,CURLINFO_RESPONSE_CODE);
        if ($ok===false || $code!==200) throw new RuntimeException('Could not archive output.');
    } finally { curl_close($curl); fclose($file); }
    if ($video) { validateVideoOutput($path); return; }
    $info=@getimagesize($path);
    if (!$info || ($info['mime'] ?? '')!=='image/jpeg') throw new RuntimeException('Invalid output image.');
}
function latestGenerationStatus(array $job): string {
    $status=$job['status'];
    if (!in_array($status,['starting','processing'],true)) {
        $message=$job['logs'] ?? '';
        if ($status==='failed' && str_starts_with($message,'Replicate ') && !str_contains($message,"\n") && !str_contains($message,"\r")) return $message;
        return ucfirst($status);
    }
    $lines=preg_split('/[\r\n]+/',preg_replace('/\x1b\[[0-9;]*[a-zA-Z]/','',$job['logs'] ?? ''));
    foreach (array_reverse($lines) as $line) {
        $line=trim($line);
        if ($line!=='' && preg_match('/^.{1,240}/us',$line,$match)) return $match[0];
    }
    return $status==='starting' ? 'Starting…' : 'Processing…';
}
function storedPrediction(array $job): array {
    return retryPublicFields($job) + ['id'=>$job['id'],'status'=>$job['status'],'logs'=>$job['logs'] ?? '', 'latestStatus'=>latestGenerationStatus($job),
        'error'=>in_array($job['status'],['failed','canceled'],true) ? latestGenerationStatus($job) : null,
        'retryAfter'=>isset($job['next_check_at']) ? max(0,strtotime($job['next_check_at'].' UTC')-time()) : 0];
}
function syncGeneration(array $job, bool $force=false, bool $direct=false): array {
    global $db;
    if (!$direct && !empty($job['retry_enabled'])) return syncRetryGeneration($job,$force);
    if (in_array($job['status'],['succeeded','failed','canceled'],true)) return storedPrediction($job);
    if (!$job['provider_id']) return storedPrediction(array_merge($job,['status'=>'unconfirmed']));
    if (!$force) {
        $claim=query('UPDATE makelora_generations SET next_check_at=DATE_ADD(UTC_TIMESTAMP(),INTERVAL 10 SECOND) WHERE id=? AND (next_check_at IS NULL OR next_check_at<=UTC_TIMESTAMP())',[$job['id']]);
        if ($claim->rowCount()===0) return storedPrediction(query('SELECT * FROM makelora_generations WHERE id=?',[$job['id']])->fetch());
    }
    // Always re-fetch the provider response; never trust webhook output URLs.
    try { $prediction=provider('predictions/'.rawurlencode($job['provider_id'])); }
    catch (ProviderFailure $error) {
        $next=gmdate('Y-m-d H:i:s',time()+$error->retryAfter);
        if ($error->httpStatus===404) {
            query('UPDATE makelora_generations SET status=?,logs=? WHERE id=?',['failed',$error->getMessage(),$job['id']]);
            return storedPrediction(array_merge($job,['status'=>'failed','logs'=>$error->getMessage()]));
        }
        query('UPDATE makelora_generations SET next_check_at=? WHERE id=?',[$next,$job['id']]);
        throw $error;
    }
    return archiveGenerationPrediction($job,$prediction);
}
function archiveGenerationPrediction(array $job,array $prediction,int $outputOffset=0,bool $preserveState=false): array {
    global $db;
    $written=[];
    $db->beginTransaction();
    try {
        $job=query('SELECT * FROM makelora_generations WHERE id=? FOR UPDATE',[$job['id']])->fetch();
        if (empty($job['retry_enabled']) && in_array($job['status'],['succeeded','failed','canceled'],true)) { $db->commit(); return storedPrediction($job); }
        if ($preserveState && $prediction['status']!=='succeeded') { $db->commit(); return storedPrediction($job); }
        if ($prediction['status']==='succeeded') {
            $urls=$prediction['output'] ?? [];
            if (is_string($urls)) $urls=[$urls];
            $video=($job['model_family'] ?? 'qwen')==='wan';
            if (!is_array($urls) || !$urls) throw new RuntimeException('Missing provider outputs.');
            foreach ($urls as $index=>$url) {
                if (!is_int($index) || $index<0 || $index>=10000) throw new RuntimeException('Invalid output index.');
                $index+=$outputOffset;
                // Tombstones prevent retries from recreating removed gallery images.
                if (query('SELECT id FROM makelora_outputs WHERE generation_id=? AND output_index=?',[$job['id'],$index])->fetch()) continue;
                $id=sprintf('%016x',(int)(microtime(true)*1000000)).bin2hex(random_bytes(24));
                $filename=$id.($video ? '.mp4':'.jpg'); $destination=outputDirectory().'/'.$filename;
                $temporary=tempnam(outputDirectory(),'.output-');
                if ($temporary===false) throw new RuntimeException('Output storage unavailable.');
                try {
                    downloadOutput($url,$temporary,$video);
                    if (!rename($temporary,$destination)) throw new RuntimeException('Output storage unavailable.');
                    $written[]=$destination;
                } finally { if (is_file($temporary)) unlink($temporary); }
                query('INSERT INTO makelora_outputs (id,generation_id,output_index,storage_key,media_type,mime_type,created_at) VALUES (?,?,?,?,?,?,UTC_TIMESTAMP())',[$id,$job['id'],$index,$filename,$video ? 'video':'image',$video ? 'video/mp4':'image/jpeg']);
            }
        }
        if ($job['status']!=='succeeded') $job['status']=$prediction['status'];
        $job['logs']=preg_replace('/^[\x80-\xBF]+/','',substr($prediction['logs'] ?? '',-20000));
        if ($job['status']==='failed') {
            $code=is_string($prediction['error'] ?? null) && preg_match('/\bE[0-9]{4}\b/',$prediction['error'],$match) ? ' ('.$match[0].')' : '';
            $job['logs']="Replicate generation failed$code. Check the image, prompt and LoRA compatibility before submitting again.";
        } elseif ($job['status']==='canceled') { $job['logs']='Generation canceled.'; }
        query('UPDATE makelora_generations SET status=?,logs=? WHERE id=?',[$job['status'],$job['logs'],$job['id']]);
        $seed=$prediction['input']['seed'] ?? null;
        if (is_int($seed)) query('UPDATE makelora_generation_recipes SET resolved_seed=? WHERE generation_id=?',[$seed,$job['id']]);
        $db->commit();
        return storedPrediction($job);
    } catch (Throwable $error) {
        if ($db->inTransaction()) $db->rollBack();
        foreach ($written as $path) if (is_file($path)) unlink($path);
        throw $error;
    }
}
function generationWebhook(?array $payload=null): never {
    if (isset($_GET['attempt'])) retryGenerationWebhook($payload);
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
    syncGeneration($job,true);
    jsonResponse(['status'=>'received']);
}
function startGeneration(array $input, array $device): array {
    global $config,$db;
    $input=resolveGenerationSource($input);
    if (isset($input['retry_offline']) && !is_bool($input['retry_offline'])) fail('Invalid retry option.');
    if ($input['retry_offline'] ?? false) return startRetryGeneration($input,$device);
    $file=generationFile($input['model'] ?? '');
    $args=generationArguments($input,$file);
    $token=readReplicateToken($config['private_session_directory']) ?? '';
    if ($token==='') fail('Configure the Replicate token on the server first.',503);
    // Check storage and video inspection before starting a paid job.
    if (generationFamily($file['target_model'])==='wan') requireVideoTools();
    outputDirectory();
    $base=rtrim($config['base_url'],'/').'/api.php?';
    $id=bin2hex(random_bytes(32)); $callback=bin2hex(random_bytes(32));
    $db->beginTransaction();
    try {
        query('INSERT INTO makelora_generations (id,device_id,model_name,prompt,callback_hash,created_at) VALUES (?,?,?,?,?,UTC_TIMESTAMP())',[$id,$device['id'],$file['display_name'],$input['prompt'],hash('sha256',$callback)]);
        saveGenerationIdentity($id,$file);
        saveGenerationRecipe($id,$input,$file);
        $db->commit();
    } catch (Throwable $error) { if ($db->inTransaction()) $db->rollBack(); throw $error; }
    try {
        $prediction=submitModelPrediction($file,$args,[
            'webhook'=>$base.http_build_query(['action'=>'generation_webhook','id'=>$id,'secret'=>$callback]),
            'webhook_events_filter'=>['completed']]);
    } catch (ProviderFailure $error) {
        // A timeout may occur after acceptance; a later authenticated callback can recover it.
        $status=$error->definiteRejection() ? 'failed' : 'unconfirmed';
        query('UPDATE makelora_generations SET status=?,logs=? WHERE id=?',[$status,$error->getMessage(),$id]);
        $error->respond($id,$status);
    }
    query('UPDATE makelora_generations SET provider_id=? WHERE id=?',[$prediction['id'],$id]);
    return ['id'=>$id,'status'=>$prediction['status'],'logs'=>'','latestStatus'=>latestGenerationStatus(['status'=>$prediction['status'],'logs'=>'']),'error'=>null];
}
function galleryPage(string $before=''): array {
    if ($before!=='' && !preg_match('/^[a-f0-9]{64}$/D',$before)) fail('Invalid gallery cursor.');
    $rows=query("SELECT o.id,o.media_type AS mediaType,o.mime_type AS mimeType,g.model_name AS model,COALESCE(g.prompt,'') AS prompt,DATE_FORMAT(o.created_at,'%Y-%m-%dT%H:%i:%sZ') AS date FROM makelora_outputs o JOIN makelora_generations g ON g.id=o.generation_id WHERE o.deleted_at IS NULL AND o.id<? ORDER BY o.id DESC LIMIT 101",[$before==='' ? str_repeat('f',64) : $before])->fetchAll();
    $more=count($rows)>100;
    $rows=array_slice($rows,0,100);
    $jobs=[];
    if ($before==='') {
        $jobs=query("SELECT id,model_name AS model,COALESCE(prompt,'') AS prompt,status,logs,provider_id,retry_enabled,retry_until,next_retry_at,retry_count,retry_cancelled_at FROM makelora_generations WHERE dismissed_at IS NULL AND status<>'succeeded' ORDER BY created_at DESC,id DESC LIMIT 100")->fetchAll();
        foreach ($jobs as &$job) {
            if (!$job['provider_id'] && $job['status']==='starting') $job['status']='unconfirmed';
            $job['latestStatus']=$job['status']==='unconfirmed' ? 'Submission not confirmed. Remove this tile to dismiss it; the request may still complete.' : latestGenerationStatus($job);
            $job=retryPublicFields($job)+$job;
            unset($job['logs'],$job['provider_id'],$job['retry_enabled'],$job['retry_until'],$job['next_retry_at'],$job['retry_count'],$job['retry_cancelled_at']);
        }
    }
    return ['outputs'=>$rows,'jobs'=>$jobs,'next'=>$more ? $rows[count($rows)-1]['id'] : null];
}
function dismissGeneration(string $id): void {
    if (!preg_match('/^[a-zA-Z0-9_-]{1,100}$/D',$id)) fail('Invalid generation.');
    if (!query('SELECT * FROM makelora_generations WHERE id=?',[$id])->fetch()) fail('Generation not found.',404);
    cancelGenerationRetries($id);
    // Keep the callback/job record: dismissal never deletes completed originals or cancels a paid run.
    query('UPDATE makelora_generations SET dismissed_at=UTC_TIMESTAMP() WHERE id=?',[$id]);
}
function outputRecord(string $id): array {
    $row=query('SELECT * FROM makelora_outputs WHERE id=? AND deleted_at IS NULL',[$id])->fetch();
    if (!$row) fail('Image not found.',404);
    return $row;
}
function serveOutput(string $id): never {
    $row=outputRecord($id);
    $path=outputDirectory().'/'.basename($row['storage_key']);
    if (!is_file($path)) fail('Media unavailable.',404);
    $size=filesize($path); $range=outputByteRange($_SERVER['HTTP_RANGE'] ?? null,$size);
    header('Accept-Ranges: bytes'); header('Content-Type: '.($row['mime_type'] ?? 'image/jpeg'));
    header('Content-Disposition: inline; filename="MakeLORA-'.$row['id'].'.'.(($row['media_type'] ?? 'image')==='video' ? 'mp4':'jpg').'"');
    if ($range===false) { http_response_code(416);header('Content-Range: bytes */'.$size);header('Content-Length: 0');exit; }
    [$start,$end]=$range; $remaining=$end-$start+1;
    if (isset($_SERVER['HTTP_RANGE'])) { http_response_code(206);header("Content-Range: bytes $start-$end/$size"); }
    header('Content-Length: '.$remaining);
    if ($_SERVER['REQUEST_METHOD']==='HEAD') exit;
    $stream=fopen($path,'rb');
    try { fseek($stream,$start); while ($remaining>0 && !feof($stream)) { $chunk=fread($stream,min(1048576,$remaining)); if ($chunk===false || $chunk==='') break;echo $chunk;$remaining-=strlen($chunk); } }
    finally { fclose($stream); }
    exit;
}
function removeOutput(string $id): void {
    global $db;
    $row=outputRecord($id);
    $db->beginTransaction();
    try {
        $job=query('SELECT * FROM makelora_generations WHERE id=? FOR UPDATE',[$row['generation_id']])->fetch();
        query('UPDATE makelora_outputs SET deleted_at=UTC_TIMESTAMP() WHERE id=? AND deleted_at IS NULL',[$id]);
        $inputPath=cleanRecipeInputLocked($job,true);
        $db->commit();
    } catch (Throwable $error) { if ($db->inTransaction()) $db->rollBack();throw $error; }
    if ($inputPath && is_file($inputPath) && !unlink($inputPath)) throw new RuntimeException('Could not remove original image.');
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
            $file['family']=generationFamily($file['baseModel']);
            $file['mediaType']=$file['family']==='wan' ? 'video':'image';
            $file['isBase']=false;
        }
        unset($file);
        $files[]=['id'=>WAN_BASE_ID,'displayName'=>baseWanModel()['display_name'],'baseModel'=>baseWanModel()['target_model'],'sizeBytes'=>0,'details'=>'Base Wan model, without custom LoRA weights.','supported'=>true,'family'=>'wan','mediaType'=>'video','isBase'=>true];
        jsonResponse(['models'=>$files]);
    }
    if ($action==='cancel_retries' && $method==='POST') {
        cancelGenerationRetries($_GET['id'] ?? ''); jsonResponse(['status'=>'retry_canceled']);
    }
    if ($action==='dismiss_generation' && $method==='POST') {
        dismissGeneration($_GET['id'] ?? ''); jsonResponse(['status'=>'dismissed']);
    }
    if ($action==='generation_details' && $method==='GET') jsonResponse(generationDetails($_GET['id'] ?? ''));
    if ($action==='generation_input' && $method==='GET') {
        $bytes=originalImageForOutput($_GET['id'] ?? '');
        header('Content-Type: image/jpeg');header('Content-Length: '.strlen($bytes));echo $bytes;exit;
    }
    if ($action==='gallery' && $method==='GET') jsonResponse(galleryPage($_GET['before'] ?? ''));
    if ($action==='output' && in_array($method,['GET','HEAD'],true)) serveOutput($_GET['id'] ?? '');
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
