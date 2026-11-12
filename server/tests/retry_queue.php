<?php
declare(strict_types=1);
require __DIR__.'/recipe_fake.php';
// php -n: all provider/SQL behavior is simulated; no paid jobs or credentials.
foreach (['CURLOPT_RETURNTRANSFER','CURLOPT_TIMEOUT','CURLOPT_HTTPHEADER','CURLOPT_POST','CURLOPT_POSTFIELDS','CURLINFO_RESPONSE_CODE','CURLOPT_FOLLOWLOCATION','CURLOPT_WRITEFUNCTION','CURLOPT_HEADERFUNCTION'] as $i=>$name) define($name,$i+1);
final class Reply extends RuntimeException { public function __construct(public array $data,public int $status=200) {} }
function fail(string $message,int $code=400): never { throw new Reply(['error'=>$message],$code); }
function jsonResponse(array $data,int $code=200): never { throw new Reply($data,$code); }
function check(bool $value,string $message): void { if (!$value) throw new RuntimeException($message); }
$GLOBALS['recipes']=[];$jobs=[];$attempts=[];$images=[];$creates=[];$predictions=[];$history=['results'=>[],'next'=>null];$deviceActive=true;$locked=false;$createCode=503;$createState='starting';$historyCode=200;$badDownload=false;$createHook=null;
$db=new class {
    private ?array $snapshot=null;
    public function beginTransaction(): void { $this->snapshot=[$GLOBALS['jobs'],$GLOBALS['images'],$GLOBALS['attempts']]; }
    public function inTransaction(): bool { return $this->snapshot!==null; }
    public function commit(): void { $this->snapshot=null; }
    public function rollBack(): void { [$GLOBALS['jobs'],$GLOBALS['images'],$GLOBALS['attempts']]=$this->snapshot;$this->snapshot=null; }
};
function query(string $sql,array $params=[]): object {
    global $jobs,$attempts,$images,$deviceActive,$locked;
    $rows=[];$affected=0;
    if (str_contains($sql,'makelora_generation_recipes')) $rows=fakeRecipeQuery($sql,$params);
    elseif (str_starts_with($sql,'SELECT GET_LOCK')) $rows=[[0=>$locked ? 0:1]];
    elseif (str_starts_with($sql,'SELECT RELEASE_LOCK')) $rows=[[0=>1]];
    elseif (str_starts_with($sql,'INSERT INTO makelora_generations')) {
        [$id,$device,$model,$prompt,$until,$next,$key,$created]=$params;
        $jobs[$id]=['id'=>$id,'device_id'=>$device,'model_name'=>$model,'prompt'=>$prompt,'provider_id'=>null,'callback_hash'=>null,'status'=>'retry_scheduled','logs'=>null,'retry_enabled'=>1,'retry_until'=>$until,'next_retry_at'=>$next,'retry_count'=>0,'retry_cancelled_at'=>null,'retry_payload_key'=>$key,'dismissed_at'=>null,'next_check_at'=>null,'created_at'=>$created];
    } elseif (str_starts_with($sql,'INSERT INTO makelora_generation_attempts')) {
        [$id,$job,$number,$hash,$started]=$params;
        $attempts[$id]=['id'=>$id,'generation_id'=>$job,'attempt_no'=>$number,'callback_hash'=>$hash,'state'=>'submitting','started_at'=>$started,'provider_id'=>null];
    } elseif (str_starts_with($sql,'UPDATE makelora_generations SET next_check_at=DATE_ADD')) {
        $id=$params[0];
        if (!$jobs[$id]['next_check_at'] || retryTimestamp($jobs[$id]['next_check_at'])<=time()) {
            $jobs[$id]['next_check_at']=retryDate(time()+10);$affected=1;
        }
    } elseif (preg_match('/^UPDATE (makelora_generations|makelora_generation_attempts) SET (.+) WHERE id=\?$/',$sql,$match)) {
        $id=array_pop($params);$target=&$jobs;
        if ($match[1]==='makelora_generation_attempts') $target=&$attempts;
        $fields=explode(',',$match[2]);
        foreach ($fields as $index=>$field) {
            if (!preg_match('/^([a-z_]+)=\?$/',$field,$name)) throw new RuntimeException('Unexpected update expression');
            $target[$id][$name[1]]=$params[$index];
        }
        $affected=1;unset($target);
    } elseif (str_starts_with($sql,'UPDATE makelora_generations SET dismissed_at=UTC_TIMESTAMP()')) {
        $jobs[$params[0]]['dismissed_at']='now';
    } elseif (str_starts_with($sql,'SELECT * FROM makelora_generations WHERE id=')) {
        if (isset($jobs[$params[0]])) $rows=[$jobs[$params[0]]];
    } elseif (str_starts_with($sql,'SELECT * FROM makelora_generations WHERE retry_payload_key=')) {
        $rows=array_values(array_filter($jobs,static fn($row)=>$row['retry_payload_key']===$params[0]));
    } elseif (str_starts_with($sql,'SELECT id FROM makelora_generations WHERE retry_enabled')) {
        foreach ($jobs as $job) if ($job['retry_enabled'] && $job['next_retry_at'] && retryTimestamp($job['next_retry_at'])<=time()) $rows[]=['id'=>$job['id']];
        $rows=array_slice($rows,0,5);
    } elseif (str_starts_with($sql,'SELECT * FROM makelora_generation_attempts WHERE id=')) {
        if (isset($attempts[$params[0]])) $rows=[$attempts[$params[0]]];
    } elseif (str_starts_with($sql,'SELECT * FROM makelora_generation_attempts WHERE generation_id=')) {
        foreach ($attempts as $attempt) if ($attempt['generation_id']===$params[0] && (count($params)===1 || $attempt['provider_id']===$params[1])) $rows[]=$attempt;
        usort($rows,static fn($a,$b)=>$b['attempt_no']<=>$a['attempt_no']);
    } elseif (str_starts_with($sql,'SELECT status FROM makelora_devices')) $rows=[['status'=>$deviceActive ? 'active':'revoked']];
    elseif (str_starts_with($sql,'SELECT * FROM makelora_files')) $rows=[['sha256'=>str_repeat('a',64),'display_name'=>'Fixture','target_model'=>$GLOBALS['fixtureBaseModel'] ?? 'Qwen/Qwen-Image-Edit-2509']];
    elseif (str_starts_with($sql,'SELECT id FROM makelora_outputs')) {
        $rows=array_values(array_filter($images,static fn($image)=>$image['generation_id']===$params[0] && (str_contains($sql,'deleted_at IS NULL') ? ($image['deleted_at'] ?? null)===null:$image['output_index']===$params[1])));
    } elseif (str_starts_with($sql,'INSERT INTO makelora_outputs')) {
        [$id,$job,$index,$key,$media,$mime]=$params;$images[$id]=['id'=>$id,'generation_id'=>$job,'output_index'=>$index,'storage_key'=>$key,'media_type'=>$media,'mime_type'=>$mime];
    } else throw new RuntimeException('Unexpected SQL: '.$sql);
    return new class($rows,$affected) {
        public function __construct(private array $rows,private int $affected) {}
        public function fetch(): array|false { return $this->rows[0] ?? false; }
        public function fetchAll(): array { return $this->rows; }
        public function fetchColumn(): mixed { return $this->rows[0][0] ?? false; }
        public function rowCount(): int { return $this->affected; }
    };
}
function curl_init(string $url): object { return (object)['url'=>$url,'options'=>[],'code'=>200]; }
function curl_setopt_array(object $curl,array $options): bool { $curl->options+=$options;return true; }
function curl_errno(object $curl): int { return 0; }
function curl_getinfo(object $curl,int $key): int { return $curl->code; }
function curl_close(object $curl): void {}
function curl_exec(object $curl): string|bool {
    global $creates,$createCode,$createState,$predictions,$history,$historyCode,$badDownload,$createHook;
    if (isset($curl->options[CURLOPT_WRITEFUNCTION])) {
        $bytes=$badDownload ? 'broken':($GLOBALS['downloadBytes'] ?? hex2bin('ffd8ffc00011080001000103011100021100031100ffd9'));
        $curl->options[CURLOPT_WRITEFUNCTION]($curl,$bytes);return true;
    }
    if (isset($curl->options[CURLOPT_POST])) {
        $body=json_decode($curl->options[CURLOPT_POSTFIELDS],true);
        $creates[]=$body;$GLOBALS['createURLs'][]=$curl->url;$curl->code=$createCode;
        if ($createHook) { $hook=$createHook;$createHook=null;$hook($body); }
        if ($createCode>=300) return '{"detail":"simulated outage"}';
        $id='provider-'.count($creates);
        $wan=str_contains($curl->url,'/models/wavespeedai/');
        return json_encode($predictions[$id]=['id'=>$id,'model'=>$wan ? wanContract()['model']:QWEN_PROVIDER,'version'=>$wan ? 'hidden':null,'source'=>'api','webhook'=>$body['webhook'],'created_at'=>gmdate('c'),'status'=>$createState,'logs'=>'Working','output'=>$createState==='succeeded' ? ['https://replicate.delivery/result.jpg']:null]);
    }
    $path=parse_url($curl->url,PHP_URL_PATH);
    if ($path==='/v1/predictions') {
        $curl->code=$historyCode;
        return json_encode($history);
    }
    $id=basename($path);$curl->code=isset($predictions[$id]) ? 200:404;
    return json_encode($predictions[$id] ?? ['detail'=>'not found']);
}
require dirname(__DIR__).'/src/generation.php';
$root=sys_get_temp_dir().'/makelora-queue-'.bin2hex(random_bytes(8));mkdir($root,0700);
$config=['private_session_directory'=>$root,'base_url'=>'https://fixture.invalid/MakeLORA'];
file_put_contents($root.'/replicate-token','fixture-token');
$input=['model'=>str_repeat('a',64),'image'=>'data:image/jpeg;base64,AAAA','prompt'=>'Exact prompt','aspect_ratio'=>'4:3','lora_scale'=>1,'seed'=>42,'retry_offline'=>true];
$device=['id'=>'fixture-device','status'=>'active'];
function resetQueueFixture(): void {
    global $jobs,$attempts,$images,$creates,$predictions,$history,$deviceActive,$locked,$createCode,$createState,$historyCode,$badDownload,$createHook,$root;
    $GLOBALS['createURLs']=[];$GLOBALS['recipes']=[];$jobs=[];$attempts=[];$images=[];$creates=[];$predictions=[];$history=['results'=>[],'next'=>null];$deviceActive=true;$locked=false;$createCode=503;$createState='starting';$historyCode=200;$badDownload=false;$createHook=null;
    foreach (['retry-inputs','outputs','generation-inputs'] as $folder) foreach (glob($root.'/'.$folder.'/*') ?: [] as $path) unlink($path);
}
function forceDue(string $id): void {
    $GLOBALS['jobs'][$id]['next_retry_at']=retryDate(time()-1);
    $GLOBALS['jobs'][$id]['next_check_at']=null;
}
function newQueuedJob(): string {
    $reply=startGeneration($GLOBALS['input'],$GLOBALS['device']);
    check($reply['status']==='retry_scheduled','Temporary provider failure queues without a modal error');
    return $reply['id'];
}
try {
    $now=1700000000;
    $policy=['provider_id'=>null,'status'=>'retry_scheduled','retry_cancelled_at'=>null,'retry_until'=>retryDate($now+43200),'retry_count'=>0];
    check(retryMaySubmit($policy,$now),'New retry allowed');
    check(!retryMaySubmit($policy,$now+43201),'No POST after 12 hours');
    check(!retryMaySubmit(array_merge($policy,['retry_count'=>24]),$now),'At most 24 retries');
    foreach ([0,408,429,500,503] as $code) check(retryableSubmissionFailure(new ProviderFailure($code)),'Transient submission failure retryable');
    foreach ([400,401,402,403,404,422] as $code) check(!retryableSubmissionFailure(new ProviderFailure($code)),'Permanent failures stop');
    $id=newQueuedJob();$job=retryJob($id);$path=retryPayloadPath($job['retry_payload_key']);
    check(isset($GLOBALS['recipes'][$id]) && is_file(recipeInputPath($id.'.jpg')),'Retry submission saves independent replay original');
    check(is_file($path) && (fileperms($path)&0777)===0600,'Input privately retained');
    check((fileperms(dirname($path))&0777)===0700,'Input directory private');
    $saved=json_decode(file_get_contents($path),true);
    check($saved['seed']===42 && $saved['prompt']==='Exact prompt','Original seed/prompt persisted');
    check(!str_contains(file_get_contents($path),'fixture-token') && !isset($saved['lora_weights']),'No provider credential or expiring URL persisted');
    check(retryTimestamp($job['next_retry_at'])>=time()+1798,'Retry scheduled at 30 minutes');
    runGenerationRetryWorker();check(count($creates)===1,'Worker does not retry early');
    $createCode=201;forceDue($id);runGenerationRetryWorker();
    check(count($creates)===2 && retryJob($id)['retry_count']===1,'Headless worker resubmits once when due');
    check($creates[1]['input']['prompt']==='Exact prompt' && $creates[1]['input']['seed']===42 && $creates[1]['input']['aspect_ratio']==='4:3','All original settings retained');
    parse_str(parse_url($creates[1]['input']['lora_weights'],PHP_URL_QUERY),$signed);
    check((int)$signed['expires']>=time()+3500 && hash_equals(hash_hmac('sha256',$signed['sha'].':'.$signed['expires'],'fixture-token'),$signed['signature']),'Download signature regenerated for retry');
    check($creates[0]['webhook']!==$creates[1]['webhook'],'Each attempt has a distinct callback');
    check(!is_file($path),'Input removed once submission is confirmed');
    $accepted=retryJob($id)['provider_id'];$predictions[$accepted]['status']='succeeded';$predictions[$accepted]['output']=['https://replicate.delivery/result.jpg'];
    forceDue($id);runGenerationRetryWorker();
    check(retryJob($id)['status']==='succeeded' && count($images)===1,'Worker archives results with app closed');
    check(count($creates)===2 && retryJob($id)['next_retry_at']===null,'Success stops further submission retries');

    resetQueueFixture();$createCode=402;
    $reply=startGeneration($input,$device);$job=retryJob($reply['id']);
    check($job['status']==='failed' && $job['next_retry_at']===null && $job['retry_payload_key']===null,'Billing failure stops and cleans input');

    resetQueueFixture();$id=newQueuedJob();$first=$creates[0];
    cancelGenerationRetries($id);
    check(retryJob($id)['status']==='retry_canceled' && retryJob($id)['retry_payload_key']===null,'Cancellation survives restarts and deletes input');
    runGenerationRetryWorker();check(count($creates)===1,'Canceled retry never submits');
    parse_str(parse_url($first['webhook'],PHP_URL_QUERY),$callback);$_GET=$callback;
    $predictions['late-accepted']=['id'=>'late-accepted','model'=>isset($body['version']) ? wanContract()['model']:QWEN_PROVIDER,'version'=>$body['version'] ?? null,'source'=>'api','status'=>'succeeded','webhook'=>$first['webhook'],'created_at'=>gmdate('c'),'output'=>['https://replicate.delivery/late.jpg']];
    try { retryGenerationWebhook(['id'=>'late-accepted']); } catch (Reply $reply) { check($reply->status===200,'Late callback acknowledged'); }
    check(count($images)===1 && retryJob($id)['status']==='succeeded','Stopping retries preserves an already accepted output');

    resetQueueFixture();$id=newQueuedJob();$jobs[$id]['retry_until']=retryDate(time()-1);forceDue($id);runGenerationRetryWorker();
    check(count($creates)===1 && retryJob($id)['status']==='retry_expired' && retryJob($id)['retry_payload_key']===null,'Expired window stops and purges input');

    resetQueueFixture();$id=newQueuedJob();$jobs[$id]['retry_count']=24;forceDue($id);runGenerationRetryWorker();
    check(count($creates)===1 && retryJob($id)['status']==='retry_expired','Retry budget cannot be exceeded');

    resetQueueFixture();$id=newQueuedJob();$historyCode=503;forceDue($id);runGenerationRetryWorker();
    check(count($creates)===1 && retryJob($id)['status']==='retry_paused','History outage never blindly creates another paid prediction');

    resetQueueFixture();$id=newQueuedJob();
    $unknown=['id'=>'unknown','model'=>isset($body['version']) ? wanContract()['model']:QWEN_PROVIDER,'version'=>$body['version'] ?? null,'source'=>'api','status'=>'starting','created_at'=>gmdate('c'),'webhook'=>null];
    $history=['results'=>[$unknown],'next'=>null];$predictions['unknown']=$unknown;
    forceDue($id);runGenerationRetryWorker();
    check(count($creates)===1 && retryJob($id)['status']==='retry_paused','Unidentifiable recent run pauses retries');

    resetQueueFixture();$id=newQueuedJob();
    $recovered=['id'=>'recovered','model'=>isset($body['version']) ? wanContract()['model']:QWEN_PROVIDER,'version'=>$body['version'] ?? null,'source'=>'api','status'=>'starting','created_at'=>gmdate('c'),'webhook'=>$creates[0]['webhook'],'logs'=>'Recovered'];
    $history=['results'=>[$recovered],'next'=>null];$predictions['recovered']=$recovered;
    forceDue($id);runGenerationRetryWorker();
    check(count($creates)===1 && retryJob($id)['provider_id']==='recovered','Lost create response reconciled without a duplicate POST');

    resetQueueFixture();$id=newQueuedJob();$locked=true;forceDue($id);runGenerationRetryWorker();
    check(count($creates)===1,'Concurrent worker cannot claim a locked job');

    resetQueueFixture();$id=newQueuedJob();$deviceActive=false;forceDue($id);runGenerationRetryWorker();
    check(count($creates)===1 && retryJob($id)['status']==='retry_canceled','Revoked device cannot trigger future paid retries');

    resetQueueFixture();$createCode=201;$createState='succeeded';$badDownload=true;
    $reply=startGeneration($input,$device);$id=$reply['id'];
    check(count($creates)===1 && retryJob($id)['status']==='processing' && retryJob($id)['provider_id']!==null,'Archive failure retains known accepted run');
    $badDownload=false;forceDue($id);runGenerationRetryWorker();
    check(count($creates)===1 && count($images)===1 && retryJob($id)['status']==='succeeded','Archive recovery only downloads, never resubmits');

    resetQueueFixture();$createCode=503;
    $createHook=static function(array $body): void {
        global $predictions;
        parse_str(parse_url($body['webhook'],PHP_URL_QUERY),$query);$_GET=$query;
        $predictions['callback-won']=['id'=>'callback-won','model'=>isset($body['version']) ? wanContract()['model']:QWEN_PROVIDER,'version'=>$body['version'] ?? null,'source'=>'api','status'=>'succeeded','webhook'=>$body['webhook'],'created_at'=>gmdate('c'),'output'=>['https://replicate.delivery/race.jpg']];
        try { retryGenerationWebhook(['id'=>'callback-won']); } catch (Reply $reply) { check($reply->status===200,'Race callback accepted'); }
    };
    $reply=startGeneration($input,$device);
    check($reply['status']==='succeeded' && count($images)===1 && retryJob($reply['id'])['next_retry_at']===null,'Create HTTP 500 cannot overwrite a successful callback');

    resetQueueFixture();
    $orphan=retryPayloadPath(str_repeat('f',64).'.json');file_put_contents($orphan,'private orphan');touch($orphan,time()-43201);
    $partial=retryPayloadDirectory().'/.request-crash';file_put_contents($partial,'private partial');touch($partial,time()-43201);
    purgeExpiredRetryInputs();
    check(!is_file($orphan) && !is_file($partial),'Worker purges crash-orphaned inputs after 12 hours');
    try { retryNextPage('https://untrusted.invalid/v1/predictions'); throw new RuntimeException('Untrusted page accepted'); }
    catch (RuntimeException $error) { check($error->getMessage()==='Untrusted prediction history page.','History never leaks credentials to another host'); }
    echo "Offline retry scheduling, headless recovery, reconciliation, cancellation, retention, budgets, locking and race checks passed.\n";
} finally {
    foreach (['retry-inputs','outputs','generation-inputs'] as $folder) {
        foreach (glob($root.'/'.$folder.'/*') ?: [] as $path) unlink($path);
        if (is_dir($root.'/'.$folder)) rmdir($root.'/'.$folder);
    }
    unlink($root.'/replicate-token');rmdir($root);
}
