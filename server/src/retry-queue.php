<?php
declare(strict_types=1);

const GENERATION_RETRY_INTERVAL = 1800;
const GENERATION_RETRY_WINDOW = 43200;
const GENERATION_MAX_RETRIES = 24;

function retryDate(int $time): string { return gmdate('Y-m-d H:i:s',$time); }
function retryTimestamp(?string $date): int { return $date ? strtotime($date.' UTC') : 0; }
function retryISO(?string $date): ?string { return $date ? gmdate('Y-m-d\TH:i:s\Z',retryTimestamp($date)) : null; }
function retryableSubmissionFailure(ProviderFailure $failure): bool {
    return in_array($failure->httpStatus,[0,408,429],true) || $failure->httpStatus>=500;
}
function retryPublicFields(array $job): array {
    if (empty($job['retry_enabled'])) return [];
    $queued=in_array($job['status'],['retry_scheduled','retry_submitting','retry_paused'],true);
    $message=$job['logs'] ?? '';
    if ($job['status']==='retry_submitting') $message='Submitting generation · retry '.(int)$job['retry_count'].' of '.GENERATION_MAX_RETRIES;
    if ($job['status']==='retry_scheduled' && !empty($job['next_retry_at'])) $message='Retry scheduled for '.gmdate('H:i \U\T\C',retryTimestamp($job['next_retry_at'])).' · '.(int)$job['retry_count'].' of '.GENERATION_MAX_RETRIES.' retries used';
    if ($job['status']==='retry_paused' && !empty($job['next_retry_at'])) $message='Retry paused while confirming the previous request · recheck '.gmdate('H:i \U\T\C',retryTimestamp($job['next_retry_at']));
    return [
        'retryEnabled'=>true,'nextRetryAt'=>retryISO($job['next_retry_at'] ?? null),
        'retryUntil'=>retryISO($job['retry_until'] ?? null),'retryCount'=>(int)($job['retry_count'] ?? 0),
        'canCancelRetries'=>!$job['provider_id'] && empty($job['retry_cancelled_at']) && $queued,
    ] + ($queued || in_array($job['status'],['retry_expired','retry_canceled'],true) ? ['latestStatus'=>$message] : []);
}
function retryJob(string $id): array {
    $job=query('SELECT * FROM makelora_generations WHERE id=?',[$id])->fetch();
    if (!$job) throw new RuntimeException('Generation not found.');
    return $job;
}
function retryUpdate(string $id,array $values): void {
    $allowed=['status','logs','provider_id','next_retry_at','retry_count','retry_cancelled_at','retry_payload_key','next_check_at'];
    foreach (array_keys($values) as $key) if (!in_array($key,$allowed,true)) throw new LogicException('Invalid retry update.');
    query('UPDATE makelora_generations SET '.implode(',',array_map(static fn($key)=>$key.'=?',array_keys($values))).' WHERE id=?',[...array_values($values),$id]);
}
function retryAttemptUpdate(string $id,array $values): void {
    foreach (array_keys($values) as $key) if (!in_array($key,['state','provider_id'],true)) throw new LogicException('Invalid attempt update.');
    query('UPDATE makelora_generation_attempts SET '.implode(',',array_map(static fn($key)=>$key.'=?',array_keys($values))).' WHERE id=?',[...array_values($values),$id]);
}
function retryPayloadDirectory(): string {
    global $config;
    $path=$config['private_session_directory'].'/retry-inputs';
    if (!is_dir($path) && !mkdir($path,0700,true) && !is_dir($path)) throw new RuntimeException('Retry storage unavailable.');
    return $path;
}
function retryPayloadPath(string $key): string {
    if (!preg_match('/^[a-f0-9]{64}\.json$/D',$key)) throw new RuntimeException('Invalid retry payload key.');
    return retryPayloadDirectory().'/'.$key;
}
function retrySavePayload(string $id,array $input): string {
    $args=generationSettings($input);
    // Persist only validated original inputs, never provider credentials or expiring URLs.
    $payload=$args;
    $payload['model']=$input['model'];$payload['_family']=$input['_family'] ?? 'qwen';
    if (is_array($payload['image'])) $payload['image']=$payload['image'][0];
    unset($payload['lora_weights']);
    if (isset($args['seed'])) $payload['seed']=$args['seed'];
    $temporary=tempnam(retryPayloadDirectory(),'.request-');
    if ($temporary===false) throw new RuntimeException('Retry storage unavailable.');
    try {
        chmod($temporary,0600);
        $data=json_encode($payload,JSON_THROW_ON_ERROR);
        if (file_put_contents($temporary,$data,LOCK_EX)!==strlen($data) || !rename($temporary,retryPayloadPath($id.'.json'))) throw new RuntimeException('Could not retain retry inputs.');
    } finally { if (is_file($temporary)) unlink($temporary); }
    return $id.'.json';
}
function retryCleanPayload(array $job): void {
    if (empty($job['retry_payload_key'])) return;
    $path=retryPayloadPath($job['retry_payload_key']);
    if (is_file($path) && !unlink($path)) throw new RuntimeException('Could not remove retry input.');
    retryUpdate($job['id'],['retry_payload_key'=>null]);
}
function retryFinish(array $job,string $status,string $message): void {
    retryUpdate($job['id'],['status'=>$status,'logs'=>$message,'next_retry_at'=>null]);
    retryCleanPayload($job);
}
function retryMaySubmit(array $job,int $now): bool {
    return empty($job['retry_cancelled_at']) && !$job['provider_id'] &&
        !in_array($job['status'],['succeeded','failed','canceled','retry_expired','retry_canceled'],true) &&
        $now<=retryTimestamp($job['retry_until']) && (int)$job['retry_count']<GENERATION_MAX_RETRIES;
}
function retrySchedule(array $job,string $message,?int $now=null,bool $paused=false): void {
    $now ??= time();
    if ($job['provider_id'] || in_array($job['status'],['succeeded','failed','canceled'],true)) return;
    if (!retryMaySubmit($job,$now)) {
        retryFinish($job,empty($job['retry_cancelled_at']) ? 'retry_expired':'retry_canceled',
            empty($job['retry_cancelled_at']) ? 'Retry window ended. Submit again to start a new request.':'Automatic retries stopped.');
        return;
    }
    retryUpdate($job['id'],['status'=>$paused ? 'retry_paused':'retry_scheduled','logs'=>$message,
        'next_retry_at'=>retryDate(min($now+GENERATION_RETRY_INTERVAL,retryTimestamp($job['retry_until'])))]);
}
function withRetryLock(string $id,callable $operation): mixed {
    $name='makelora.retry.'.substr(hash('sha256',$id),0,48);
    if ((int)query('SELECT GET_LOCK(?,0)',[$name])->fetchColumn()!==1) return null;
    try { return $operation(); }
    finally { query('SELECT RELEASE_LOCK(?)',[$name]); }
}
function latestRetryAttempt(string $id): array|false {
    return query('SELECT * FROM makelora_generation_attempts WHERE generation_id=? ORDER BY attempt_no DESC LIMIT 1',[$id])->fetch();
}
function startRetryGeneration(array $input,array $device): array {
    global $config,$db;
    $file=generationFile($input['model'] ?? '');
    $input['_family']=generationFamily($file['target_model']);
    generationSettings($input);
    if ($input['_family']==='wan') requireVideoTools();
    if (!readReplicateToken($config['private_session_directory'])) fail('Configure the Replicate token on the server first.',503);
    outputDirectory();
    $id=bin2hex(random_bytes(32)); $now=time();
    $key=retrySavePayload($id,$input);
    $db->beginTransaction();
    try {
        query("INSERT INTO makelora_generations (id,device_id,model_name,prompt,status,retry_enabled,retry_until,next_retry_at,retry_payload_key,created_at) VALUES (?,?,?,?,'retry_scheduled',1,?,?,?,?)",
            [$id,$device['id'],$file['display_name'],$input['prompt'],retryDate($now+GENERATION_RETRY_WINDOW),retryDate($now),$key,retryDate($now)]);
        saveGenerationIdentity($id,$file);
        saveGenerationRecipe($id,$input,$file);
        $db->commit();
    } catch (Throwable $error) { if ($db->inTransaction()) $db->rollBack(); unlink(retryPayloadPath($key)); throw $error; }
    withRetryLock($id,static function() use ($id): void {
        // A worker may already have claimed the new job.
        if (!latestRetryAttempt($id)) submitRetryAttempt(retryJob($id));
    });
    return storedPrediction(retryJob($id));
}
function submitRetryAttempt(array $job): void {
    global $config;
    $now=time();
    if (!retryMaySubmit($job,$now)) { retrySchedule($job,'Retry window ended.',$now); return; }
    $device=query('SELECT status FROM makelora_devices WHERE id=?',[$job['device_id']])->fetch();
    if (!$device || $device['status']!=='active') { retryFinish($job,'retry_canceled','Retries stopped because the submitting device no longer has access.'); return; }
    $token=readReplicateToken($config['private_session_directory']);
    if (!$token) { retryFinish($job,'failed','Replicate token is missing. Save a server token before submitting again.'); return; }
    $input=json_decode(file_get_contents(retryPayloadPath($job['retry_payload_key'])),true,16,JSON_THROW_ON_ERROR);
    if (($input['model'] ?? '')===WAN_BASE_ID) $file=baseWanModel();
    else $file=query('SELECT * FROM makelora_files WHERE sha256=?',[$input['model']])->fetch();
    if (!$file || generationFamily($file['target_model'])!==($job['model_family'] ?? 'qwen')) { retryFinish($job,'failed','The selected weight is unavailable or its base model changed. Choose a weight and submit again.'); return; }
    $args=generationArguments($input,$file,$job);
    $base=rtrim($config['base_url'],'/').'/api.php?';
    $previous=latestRetryAttempt($job['id']);
    $number=$previous ? (int)$previous['attempt_no']+1 : 0;
    if ($number>GENERATION_MAX_RETRIES) { retryFinish($job,'retry_expired','The retry limit was reached. Submit again to start a new request.'); return; }
    $attemptID=bin2hex(random_bytes(32));$secret=bin2hex(random_bytes(32));
    query("INSERT INTO makelora_generation_attempts (id,generation_id,attempt_no,callback_hash,state,started_at) VALUES (?,?,?,?,'submitting',?)",
        [$attemptID,$job['id'],$number,hash('sha256',$secret),retryDate($now)]);
    retryUpdate($job['id'],['status'=>'retry_submitting','retry_count'=>$number,'next_retry_at'=>retryDate(min($now+GENERATION_RETRY_INTERVAL,retryTimestamp($job['retry_until'])))]);
    $fresh=retryJob($job['id']);
    if (!empty($fresh['retry_cancelled_at'])) { retryAttemptUpdate($attemptID,['state'=>'canceled']); retryFinish($fresh,'retry_canceled','Automatic retries stopped.'); return; }
    try {
        $prediction=submitModelPrediction($file,$args,[
            'webhook'=>$base.http_build_query(['action'=>'generation_webhook','id'=>$job['id'],'attempt'=>$attemptID,'secret'=>$secret]),
            'webhook_events_filter'=>['completed']],$job);
        acceptRetryPrediction($job['id'],$attemptID,$prediction);
    } catch (ProviderFailure $failure) {
        $fresh=retryJob($job['id']);
        // A completion callback may have won the race with the create response.
        if ($fresh['provider_id'] || $fresh['status']==='succeeded') return;
        retryAttemptUpdate($attemptID,['state'=>$failure->definiteRejection() ? 'rejected':'uncertain']);
        if (retryableSubmissionFailure($failure)) retrySchedule($fresh,$failure->getMessage());
        else retryFinish($fresh,'failed',$failure->getMessage());
    } catch (Throwable $error) {
        // A process or response failure after POST is ambiguous; reconcile before any new POST.
        $fresh=retryJob($job['id']);
        if ($fresh['provider_id']) {
            if ($fresh['status']!=='succeeded') retryUpdate($job['id'],['next_retry_at'=>retryDate(time()+60)]);
        } else {
            retryAttemptUpdate($attemptID,['state'=>'uncertain']);
            retrySchedule($fresh,'Submission response could not be confirmed. Checking the previous attempt before retrying.');
        }
        error_log('MakeLORA retry response failure: '.get_class($error));
    }
}
function acceptRetryPrediction(string $jobID,string $attemptID,array $prediction): void {
    if (!is_string($prediction['id'] ?? null) || !preg_match('/^[a-zA-Z0-9_-]{1,100}$/D',$prediction['id'])) throw new RuntimeException('Invalid provider prediction.');
    retryAttemptUpdate($attemptID,['provider_id'=>$prediction['id'],'state'=>$prediction['status']]);
    $job=retryJob($jobID);
    if ($job['status']!=='succeeded' && (!$job['provider_id'] || $job['provider_id']===$prediction['id'])) retryUpdate($jobID,['provider_id'=>$prediction['id'],'status'=>in_array($prediction['status'],['starting','processing'],true) ? $prediction['status']:'processing','next_retry_at'=>retryDate(time()+60)]);
    retryCleanPayload($job); // Confirmed acceptance means the input is no longer needed for resubmission.
    handleRetryPrediction($jobID,$attemptID,$prediction);
}
function handleRetryPrediction(string $jobID,string $attemptID,array $prediction): array {
    $attempt=query('SELECT * FROM makelora_generation_attempts WHERE id=?',[$attemptID])->fetch();
    if (!$attempt || $attempt['generation_id']!==$jobID) throw new RuntimeException('Attempt not found.');
    retryAttemptUpdate($attemptID,['provider_id'=>$prediction['id'],'state'=>$prediction['status']]);
    $before=retryJob($jobID);
    archiveGenerationPrediction($before,$prediction,(int)$attempt['attempt_no']*10000,$before['provider_id']!==$prediction['id']);
    $job=retryJob($jobID);
    if (in_array($job['status'],['succeeded','failed','canceled'],true)) {
        retryUpdate($jobID,['next_retry_at'=>null]);retryCleanPayload($job);
    } else { retryUpdate($jobID,['next_retry_at'=>retryDate(time()+60)]); }
    return storedPrediction(retryJob($jobID));
}
function syncRetryGeneration(array $job,bool $force=false): array {
    if (!$job['provider_id'] || in_array($job['status'],['succeeded','failed','canceled','retry_expired','retry_canceled'],true)) return storedPrediction($job);
    if (!$force) {
        $claim=query('UPDATE makelora_generations SET next_check_at=DATE_ADD(UTC_TIMESTAMP(),INTERVAL 10 SECOND) WHERE id=? AND (next_check_at IS NULL OR next_check_at<=UTC_TIMESTAMP())',[$job['id']]);
        if ($claim->rowCount()===0) return storedPrediction(retryJob($job['id']));
    }
    $attempt=query('SELECT * FROM makelora_generation_attempts WHERE generation_id=? AND provider_id=?',[$job['id'],$job['provider_id']])->fetch();
    if (!$attempt) throw new RuntimeException('Provider attempt missing.');
    try {
        return handleRetryPrediction($job['id'],$attempt['id'],provider('predictions/'.rawurlencode($job['provider_id'])));
    } catch (ProviderFailure $failure) {
        if ($failure->httpStatus===404) {
            retryFinish($job,'failed',$failure->getMessage());
            return storedPrediction(retryJob($job['id']));
        }
        // A known accepted prediction is only polled, never resubmitted.
        retryUpdate($job['id'],['next_check_at'=>retryDate(time()+$failure->retryAfter),'next_retry_at'=>retryDate(time()+GENERATION_RETRY_INTERVAL)]);
        throw $failure;
    }
}
function retryWebhookMatches(array $prediction,array $job,array $attempt): bool {
    $query=[];
    parse_str(parse_url($prediction['webhook'] ?? '',PHP_URL_QUERY) ?: '',$query);
    return ($query['id'] ?? '')===$job['id'] && ($query['attempt'] ?? '')===$attempt['id'] &&
        is_string($query['secret'] ?? null) && hash_equals($attempt['callback_hash'],hash('sha256',$query['secret']));
}
function retryNextPage(?string $url): ?string {
    if (!$url) return null;
    $parts=parse_url($url);
    if (($parts['scheme'] ?? '')!=='https' || ($parts['host'] ?? '')!=='api.replicate.com' ||
        ($parts['path'] ?? '')!=='/v1/predictions' || isset($parts['user']) || isset($parts['pass']) || isset($parts['port'])) throw new RuntimeException('Untrusted prediction history page.');
    return 'predictions'.(isset($parts['query']) ? '?'.$parts['query'] : '');
}
function reconcileRetryAttempt(array $job,array $attempt): ?array {
    $path='predictions'; $since=retryTimestamp($attempt['started_at'])-60;
    $ambiguous=false; $covered=false; $inspected=0;
    for ($page=0;$path!==null && $page<20;$page++) {
        $history=provider($path);
        if (!is_array($history['results'] ?? null)) throw new RuntimeException('Prediction history is unavailable.');
        foreach ($history['results'] as $candidate) {
            $created=strtotime($candidate['created_at'] ?? '');
            if (!$created) throw new RuntimeException('Prediction history timestamp missing.');
            if ($created<$since) { $covered=true; continue; }
            if (($candidate['model'] ?? '')!==($job['provider_model'] ?? QWEN_PROVIDER) || ($candidate['source'] ?? '')==='web') continue;
            if (!empty($job['provider_version']) && ($candidate['version'] ?? '')!==$job['provider_version']) continue;
            if (retryWebhookMatches($candidate,$job,$attempt)) return provider('predictions/'.rawurlencode($candidate['id']));
            if (empty($candidate['webhook'])) {
                if (++$inspected>25) throw new RuntimeException('Too many unidentified recent predictions.');
                $candidate=provider('predictions/'.rawurlencode($candidate['id']));
                if (retryWebhookMatches($candidate,$job,$attempt)) return $candidate;
                if (empty($candidate['webhook'])) $ambiguous=true;
            }
        }
        $path=retryNextPage($history['next'] ?? null);
        if ($path===null) $covered=true;
        if ($covered) break;
    }
    if (!$covered || $ambiguous || time()-retryTimestamp($attempt['started_at'])>3300) {
        throw new RuntimeException('Cannot safely confirm whether the prior submission was accepted.');
    }
    return null;
}
function retryGenerationWebhook(?array $payload=null): never {
    $id=$_GET['id'] ?? ''; $attemptID=$_GET['attempt'] ?? ''; $secret=$_GET['secret'] ?? '';
    if (!is_string($id) || !is_string($attemptID) || !is_string($secret) || !preg_match('/^[a-f0-9]{64}$/D',$attemptID)) fail('Invalid callback.',403);
    $attempt=query('SELECT * FROM makelora_generation_attempts WHERE id=?',[$attemptID])->fetch();
    if (!$attempt || $attempt['generation_id']!==$id || !hash_equals($attempt['callback_hash'],hash('sha256',$secret))) fail('Invalid callback.',403);
    $job=retryJob($id);
    if (!$attempt['provider_id']) {
        if ($payload===null) {
            $raw=file_get_contents('php://input',false,null,0,20000001);
            if (strlen($raw)>20000000) fail('Callback too large.',413);
            $payload=json_decode($raw,true,64,JSON_THROW_ON_ERROR);
        }
        $providerID=$payload['id'] ?? '';
        if (!is_string($providerID) || !preg_match('/^[a-zA-Z0-9_-]{1,100}$/D',$providerID)) fail('Invalid callback.',403);
        $prediction=provider('predictions/'.rawurlencode($providerID));
        if (!retryWebhookMatches($prediction,$job,$attempt)) fail('Callback prediction mismatch.',403);
    } else { $prediction=provider('predictions/'.rawurlencode($attempt['provider_id'])); }
    acceptRetryPrediction($id,$attemptID,$prediction);
    jsonResponse(['status'=>'received']);
}
function cancelGenerationRetries(string $id): void {
    if (!preg_match('/^[a-zA-Z0-9_-]{1,100}$/D',$id)) fail('Invalid generation.');
    $job=query('SELECT * FROM makelora_generations WHERE id=?',[$id])->fetch();
    if (!$job) fail('Generation not found.',404);
    if (empty($job['retry_enabled'])) return;
    $values=['retry_cancelled_at'=>retryDate(time())];
    if (!$job['provider_id']) $values+=['status'=>'retry_canceled','next_retry_at'=>null,'logs'=>'Automatic retries stopped.'];
    retryUpdate($id,$values);retryCleanPayload($job);
}
function processRetryJob(string $id): void {
    withRetryLock($id,static function() use ($id): void {
        $job=retryJob($id);
        if (empty($job['next_retry_at']) || retryTimestamp($job['next_retry_at'])>time()) return;
        if ($job['provider_id']) { syncRetryGeneration($job,true); return; }
        if (!retryMaySubmit($job,time())) { retrySchedule($job,'Retry window ended.'); return; }
        $attempt=latestRetryAttempt($id);
        if ($attempt && !in_array($attempt['state'],['rejected'],true)) {
            try { $prediction=reconcileRetryAttempt($job,$attempt); }
            catch (Throwable $error) {
                if ($error instanceof ProviderFailure && !retryableSubmissionFailure($error)) {
                    retryFinish($job,'failed',$error->getMessage()); return;
                }
                retrySchedule($job,'Waiting to confirm the previous submission. No new prediction will be submitted until it can be verified.',null,true);
                error_log('MakeLORA retry reconciliation deferred: '.get_class($error));
                return;
            }
            if ($prediction!==null) { acceptRetryPrediction($id,$attempt['id'],$prediction); return; }
            retryAttemptUpdate($attempt['id'],['state'=>'rejected']);
        }
        submitRetryAttempt(retryJob($id));
    });
}
function purgeExpiredRetryInputs(?int $now=null): void {
    $now ??= time();
    foreach (new DirectoryIterator(retryPayloadDirectory()) as $file) {
        if (!$file->isFile() || $file->isLink() || $file->getMTime()>$now-GENERATION_RETRY_WINDOW) continue;
        $key=$file->getFilename();
        if (str_starts_with($key,'.request-')) { unlink($file->getPathname()); continue; }
        if (!preg_match('/^[a-f0-9]{64}\.json$/D',$key)) continue;
        $job=query('SELECT * FROM makelora_generations WHERE retry_payload_key=?',[$key])->fetch();
        if (!$job) { unlink($file->getPathname()); continue; }
        if (retryTimestamp($job['retry_until'])>$now) continue;
        if (!$job['provider_id'] && !in_array($job['status'],['succeeded','failed','canceled','retry_canceled'],true)) {
            retryFinish($job,'retry_expired','The 12-hour retry window ended. Submit again to start a new request.');
        } else { retryCleanPayload($job); }
    }
}
function runGenerationRetryWorker(): int {
    try { purgeExpiredRetryInputs(); purgeUnusedRecipeInputs(); }
    catch (Throwable $error) { error_log('MakeLORA retry input cleanup deferred: '.get_class($error)); }
    $jobs=query('SELECT id FROM makelora_generations WHERE retry_enabled=1 AND next_retry_at IS NOT NULL AND next_retry_at<=UTC_TIMESTAMP() ORDER BY next_retry_at,id LIMIT 5')->fetchAll();
    foreach ($jobs as $row) {
        try { processRetryJob($row['id']); }
        catch (Throwable $error) {
            // Keep the job durable after storage/network faults; do not start another paid run.
            error_log('MakeLORA retry worker deferred job: '.get_class($error));
            retryUpdate($row['id'],['next_retry_at'=>retryDate(time()+GENERATION_RETRY_INTERVAL)]);
        }
    }
    return count($jobs);
}
