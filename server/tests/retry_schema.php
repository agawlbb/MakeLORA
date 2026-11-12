<?php
declare(strict_types=1);
// Real SQL and named locks, but only connection-local temporary tables in VM test DB.
require __DIR__.'/test_database.php';
$db=vmTestDatabase();
foreach (['004_generations.sql','005_server_gallery.sql','006_generation_recovery.sql','007_generation_retries.sql'] as $migration) {
    $db->exec(str_replace('CREATE TABLE IF NOT EXISTS','CREATE TEMPORARY TABLE',file_get_contents(dirname(__DIR__).'/migrations/'.$migration)));
}
function query(string $sql,array $params=[]): PDOStatement {
    global $db;$statement=$db->prepare($sql);$statement->execute($params);return $statement;
}
function fail(string $message,int $code=400): never { throw new RuntimeException($message); }
function check(bool $condition,string $message): void { if (!$condition) throw new RuntimeException($message); }
require dirname(__DIR__).'/src/generation.php';
$root=sys_get_temp_dir().'/makelora-retry-sql-'.bin2hex(random_bytes(8));mkdir($root,0700);
$config=['private_session_directory'=>$root,'base_url'=>'https://fixture.invalid'];
$id=bin2hex(random_bytes(32));$attempt=bin2hex(random_bytes(32));$now=time();
try {
    $key=retrySavePayload($id,['model'=>str_repeat('a',64),'image'=>'data:image/jpeg;base64,AAAA','prompt'=>'SQL fixture']);
    query("INSERT INTO makelora_generations (id,device_id,model_name,prompt,status,retry_enabled,retry_until,next_retry_at,retry_payload_key,created_at) VALUES (?,?,?,?,'retry_scheduled',1,?,?,?,?)",
        [$id,'fixture-device','SQL fixture','Prompt',retryDate($now+43200),retryDate($now),$key,retryDate($now)]);
    $job=retryJob($id);retrySchedule($job,'Temporary outage.',$now);
    check(retryTimestamp(retryJob($id)['next_retry_at'])===$now+1800,'Real SQL retry schedule');
    $entries=array_values(array_filter(galleryPage()['jobs'],static fn($row)=>$row['id']===$id));
    check(count($entries)===1 && $entries[0]['canCancelRetries']===true,'Queued job visible in real gallery SQL');
    check($entries[0]['retryCount']===0 && !isset($entries[0]['retry_payload_key']),'Public retry metadata');

    $called=0;
    withRetryLock($id,static function() use (&$called): void { $called++; });
    check($called===1,'Real advisory lock released');
    $other=vmTestDatabase();$name='makelora.retry.'.substr(hash('sha256',$id),0,48);
    $hold=$other->prepare('SELECT GET_LOCK(?,0)');$hold->execute([$name]);
    check((int)$hold->fetchColumn()===1,'Second connection holds worker lock');
    withRetryLock($id,static function() use (&$called): void { $called++; });
    check($called===1,'Concurrent SQL connection cannot enter retry critical section');
    $release=$other->prepare('SELECT RELEASE_LOCK(?)');$release->execute([$name]);
    query("INSERT INTO makelora_generation_attempts (id,generation_id,attempt_no,callback_hash,state,started_at) VALUES (?,?,?,?,'submitting',?)",
        [$attempt,$id,0,str_repeat('b',64),retryDate($now)]);
    check(latestRetryAttempt($id)['id']===$attempt,'Attempt lookup');
    retryAttemptUpdate($attempt,['provider_id'=>'fixture-provider','state'=>'processing']);
    retryUpdate($id,['provider_id'=>'fixture-provider','status'=>'processing']);
    handleRetryPrediction($id,$attempt,['id'=>'fixture-provider','status'=>'processing','logs'=>'SQL progress']);
    check(retryJob($id)['logs']==='SQL progress','Transactional state archival uses real SQL');
    cancelGenerationRetries($id);
    check(retryJob($id)['retry_payload_key']===null && !is_file(retryPayloadPath($key)),'Cancellation removes retained input');
    check(retryJob($id)['provider_id']==='fixture-provider','Cancellation preserves an accepted run');
    dismissGeneration($id);
    check(!array_filter(galleryPage()['jobs'],static fn($row)=>$row['id']===$id),'Dismissal shared across gallery reads');
    echo "VM temporary-table retry migrations, queue SQL, attempt lookup, locking and cleanup checks passed.\n";
} finally {
    foreach (glob($root.'/retry-inputs/*') ?: [] as $path) unlink($path);
    if (is_dir($root.'/retry-inputs')) rmdir($root.'/retry-inputs');
    rmdir($root);
}
