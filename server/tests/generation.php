<?php
// php -n: no network, paid jobs, database credentials or persistent files.
declare(strict_types=1);
require __DIR__.'/recipe_fake.php';
foreach (['CURLOPT_RETURNTRANSFER','CURLOPT_TIMEOUT','CURLOPT_HTTPHEADER','CURLOPT_POST','CURLOPT_POSTFIELDS','CURLINFO_RESPONSE_CODE','CURLOPT_FOLLOWLOCATION','CURLOPT_WRITEFUNCTION','CURLOPT_HEADERFUNCTION'] as $i=>$name) define($name,$i+1);
final class Reply extends RuntimeException { public function __construct(public array $data, public int $status=200) {} }
function jsonResponse(array $data,int $code=200): never { throw new Reply($data,$code); }
function fail(string $message,int $code=400): never { throw new Reply(['error'=>$message],$code); }
function check(bool $condition,string $message): void { if (!$condition) throw new RuntimeException($message); }
function curl_init(string $url): object { return (object)['url'=>$url,'options'=>[]]; }
function curl_setopt_array(object $curl,array $options): bool { $curl->options += $options; $GLOBALS['transport']=$curl; return true; }
function curl_exec(object $curl): string|bool {
    if (isset($curl->options[CURLOPT_WRITEFUNCTION])) {
        $GLOBALS['downloads']++;
        // JPEG SOF fixture: a 1x1 RGB image header.
        $bytes=hex2bin('ffd8ffc00011080001000103011100021100031100ffd9');
        if (($GLOBALS['badDownloadAt'] ?? 0)===$GLOBALS['downloads']) $bytes='broken';
        return $curl->options[CURLOPT_WRITEFUNCTION]($curl,$bytes)===strlen($bytes);
    }
    $GLOBALS['providerCalls']=($GLOBALS['providerCalls'] ?? 0)+1;
    if (isset($curl->options[CURLOPT_HEADERFUNCTION]) && isset($GLOBALS['retryAfter'])) $curl->options[CURLOPT_HEADERFUNCTION]($curl,'Retry-After: '.$GLOBALS['retryAfter']);
    return ($GLOBALS['transportFailure'] ?? false) ? false : json_encode($GLOBALS['prediction']);
}
function curl_getinfo(object $curl,int $key): int { return isset($curl->options[CURLOPT_WRITEFUNCTION]) ? 200 : ($GLOBALS['providerHTTP'] ?? 201); }
function curl_errno(object $curl): int { return ($GLOBALS['transportFailure'] ?? false) ? 28 : 0; }
function curl_close(object $curl): void {}
$jobs=[]; $images=[]; $downloads=0;
$db=new class {
    private ?array $snapshot=null;
    public function beginTransaction(): void { $this->snapshot=[$GLOBALS['jobs'],$GLOBALS['images']]; }
    public function inTransaction(): bool { return $this->snapshot!==null; }
    public function commit(): void { $this->snapshot=null; }
    public function rollBack(): void { [$GLOBALS['jobs'],$GLOBALS['images']]=$this->snapshot; $this->snapshot=null; }
};
function query(string $sql,array $params=[]): object {
    global $jobs,$images,$file;
    $rows=[]; $affected=0;
    if (str_contains($sql,'makelora_generation_recipes')) $rows=fakeRecipeQuery($sql,$params);
    elseif (str_starts_with($sql,'INSERT INTO makelora_generations')) {
        [$id,$device,$model,$prompt,$hash]=$params;
        $jobs[$id]=['id'=>$id,'device_id'=>$device,'model_name'=>$model,'prompt'=>$prompt,'callback_hash'=>$hash,'status'=>'starting','provider_id'=>null,'logs'=>null,'dismissed_at'=>null,'next_check_at'=>null];
    } elseif (str_starts_with($sql,'UPDATE makelora_generations SET provider_id')) {
        $jobs[$params[1]]['provider_id']=$params[0];
    } elseif (str_starts_with($sql,'UPDATE makelora_generations SET next_check_at=DATE_ADD')) {
        $next=$jobs[$params[0]]['next_check_at'] ?? null;
        if ($next===null || strtotime($next.' UTC')<=time()) {
            $jobs[$params[0]]['next_check_at']=gmdate('Y-m-d H:i:s',time()+10); $affected=1;
        }
    } elseif (str_starts_with($sql,'UPDATE makelora_generations SET next_check_at=?')) {
        $jobs[$params[1]]['next_check_at']=$params[0];
    } elseif (str_starts_with($sql,'UPDATE makelora_generations SET dismissed_at')) {
        $jobs[$params[0]]['dismissed_at']='now';
    } elseif (str_starts_with($sql,'UPDATE makelora_generations SET status')) {
        $jobs[$params[2]]['status']=$params[0]; $jobs[$params[2]]['logs']=$params[1];
    } elseif (str_starts_with($sql,'SELECT id,model_name AS model')) {
        foreach ($jobs as $job) if (($job['dismissed_at'] ?? null)===null && $job['status']!=='succeeded') {
            $rows[]=['id'=>$job['id'],'model'=>$job['model_name'],'prompt'=>$job['prompt'],'status'=>$job['status'],'logs'=>$job['logs'],'provider_id'=>$job['provider_id']];
        }
        $rows=array_slice(array_reverse($rows),0,100);
    } elseif (str_starts_with($sql,'SELECT * FROM makelora_generations')) {
        if (isset($jobs[$params[0]])) $rows=[$jobs[$params[0]]];
    } elseif (str_starts_with($sql,'INSERT INTO makelora_outputs')) {
        [$id,$job,$index,$key]=$params;
        $images[$id]=['id'=>$id,'generation_id'=>$job,'output_index'=>$index,'storage_key'=>$key,'deleted_at'=>null];
    } elseif (str_starts_with($sql,'SELECT id FROM makelora_outputs')) {
        $rows=array_values(array_filter($images,fn($row)=>$row['generation_id']===$params[0] && (str_contains($sql,'deleted_at IS NULL') ? ($row['deleted_at'] ?? null)===null:$row['output_index']===$params[1])));
    } elseif (str_starts_with($sql,'SELECT * FROM makelora_outputs')) {
        $row=$images[$params[0]] ?? null;
        if ($row && $row['deleted_at']===null) $rows=[$row];
    } elseif (str_starts_with($sql,'UPDATE makelora_outputs SET deleted_at')) {
        $images[$params[0]]['deleted_at']='now';
    } elseif (str_starts_with($sql,'SELECT o.id')) {
        foreach ($images as $image) if ($image['deleted_at']===null && strcmp($image['id'],$params[0])<0) {
            $job=$jobs[$image['generation_id']];
            $rows[]=['id'=>$image['id'],'model'=>$job['model_name'],'prompt'=>$job['prompt'],'date'=>'2026-11-11T12:00:00Z'];
        }
        usort($rows,fn($a,$b)=>strcmp($b['id'],$a['id'])); $rows=array_slice($rows,0,101);
    } elseif (str_starts_with($sql,'SELECT * FROM makelora_devices')) {
        foreach (['a'=>'active','b'=>'pending','c'=>'revoked'] as $token=>$status) {
            if ($params[0]===hash('sha256',str_repeat($token,64))) $rows=[['id'=>'device-'.$token,'status'=>$status,'expires_at'=>'2099-01-01 00:00:00']];
        }
    } elseif (str_starts_with($sql,'SELECT sha256 AS id')) {
        $rows=[['id'=>str_repeat('a',64),'displayName'=>'Glasses','baseModel'=>'Qwen/Qwen-Image-Edit-2509','sizeBytes'=>'42','inspection_json'=>'{"metadata":{"description":"Custom edit"}}']];
    } elseif (str_starts_with($sql,'SELECT * FROM makelora_files')) {
        $rows=[$file];
    } else { throw new RuntimeException('Unexpected SQL: '.$sql); }
    return new class($rows,$affected) {
        public function __construct(private array $rows,private int $affected) {}
        public function rowCount(): int { return $this->affected; }
        public function fetch(): array|false { return $this->rows[0] ?? false; }
        public function fetchAll(): array { return $this->rows; }
    };
}
require dirname(__DIR__).'/src/generation.php';
require dirname(__DIR__).'/src/device-auth.php';
function callAPI(string $action,array $device): Reply {
    try { generationAPI($action,$device); } catch (Reply $reply) { return $reply; }
    throw new RuntimeException('Missing response');
}
check(latestGenerationStatus(['status'=>'starting','logs'=>''])==='Starting…','Starting fallback');
check(latestGenerationStatus(['status'=>'processing','logs'=>"Old status\rProgress 50%\n\n"])==='Progress 50%','Only newest nonempty status');
check(latestGenerationStatus(['status'=>'processing','logs'=>"Old status\n\x1b[32mRendering 75%\x1b[0m"])==='Rendering 75%','Terminal formatting stripped');
check(latestGenerationStatus(['status'=>'failed','logs'=>'Rendering 75%'])==='Failed','Failure replaces stale progress');
check(supportedGenerationModel('Qwen/Qwen-Image-Edit-2509'),'Known model');
check(!supportedGenerationModel('Qwen/Qwen-Image-Edit-2511'),'Incompatible base disabled');
check(!supportedGenerationModel(null),'Unknown base disabled');
$settings=generationSettings(['prompt'=>'Add glasses','image'=>'data:image/jpeg;base64,AAAA']);
check($settings['aspect_ratio']==='match_input_image' && $settings['lora_scale']===1.0,'Defaults');
check($settings['output_format']==='jpg' && $settings['disable_safety_checker']===true && !isset($settings['seed']),'JPG, safety and random seed');
foreach ([['prompt'=>''],['image'=>'https://untrusted.example/image.jpg'],['lora_scale'=>5],['aspect_ratio'=>'bad'],['seed'=>-1],['seed'=>'42']] as $override) {
    try { generationSettings(array_merge(['prompt'=>'Edit','image'=>'data:image/jpeg;base64,AAAA'],$override)); throw new RuntimeException('Invalid input accepted'); }
    catch (Reply $reply) { check($reply->status===400,'Invalid settings rejected'); }
}
foreach (['','Basic bad','Bearer bad','Bearer '.str_repeat('d',64),'Bearer '.str_repeat('c',64)] as $auth) {
    try { authenticatedDevice($auth); throw new RuntimeException('Invalid auth accepted'); }
    catch (Reply $reply) { check($reply->status===401,'Missing, malformed, unknown or revoked token denied'); }
}
check(authenticatedDevice('Bearer '.str_repeat('a',64))['status']==='active','Valid token accepted');
check(authenticatedDevice('Bearer '.str_repeat('b',64))['status']==='pending','Pending status available, feature access still blocked');
$_SERVER['REQUEST_METHOD']='GET';
$active=['id'=>'device-a','status'=>'active']; $other=['id'=>'device-b','status'=>'active'];
foreach (['models','generate','prediction','gallery','output','remove_output','dismiss_generation'] as $action) {
    check(callAPI($action,['id'=>'pending','status'=>'pending'])->status===403,'Pending devices blocked for '.$action);
    check(callAPI($action,['id'=>'revoked','status'=>'revoked'])->status===403,'Inactive devices blocked for '.$action);
}
check(callAPI('models',$active)->data['models'][0]['supported']===true,'Supported catalog');
$directory=sys_get_temp_dir().'/makelora-generation-'.bin2hex(random_bytes(8)); mkdir($directory,0700);
$config=['private_session_directory'=>$directory,'base_url'=>'https://server.example/MakeLORA'];
$file=['sha256'=>str_repeat('a',64),'display_name'=>'Glasses','target_model'=>'Qwen/Qwen-Image-Edit-2509'];
$prediction=['id'=>'provider-job','status'=>'starting','output'=>null];
try {
    try { startGeneration(['prompt'=>'Edit','image'=>'data:image/jpeg;base64,AAAA'],$active); throw new RuntimeException('Token required'); }
    catch (Reply $reply) { check($reply->status===503,'Missing server token'); }
    file_put_contents($directory.'/replicate-token','test-token');
    $created=startGeneration(['model'=>str_repeat('a',64),'prompt'=>'Add glasses','image'=>'data:image/jpeg;base64,AAAA'],$active);
    $id=$created['id']; $transport=$GLOBALS['transport'];
    check($transport->url==='https://api.replicate.com/v1/models/qwen/qwen-image-edit-plus-lora/predictions','Qwen endpoint');
    check(in_array('Authorization: Bearer test-token',$transport->options[CURLOPT_HTTPHEADER],true),'Server token used');
    $body=json_decode($transport->options[CURLOPT_POSTFIELDS],true);
    check($body['webhook_events_filter']===['completed'],'Archive when app is closed');
    parse_str(parse_url($body['webhook'],PHP_URL_QUERY),$callback);
    check(hash_equals(hash('sha256',$callback['secret']),$jobs[$id]['callback_hash']),'Callback scoped to job');
    parse_str(parse_url($body['input']['lora_weights'],PHP_URL_QUERY),$signed);
    check(hash_equals(hash_hmac('sha256',$signed['sha'].':'.$signed['expires'],'test-token'),$signed['signature']),'Scoped weight signature');
    check(!str_contains(json_encode($created),'test-token') && !isset($created['output']),'Provider token and URLs not exposed');
    $_GET=['id'=>$id];
    check(callAPI('prediction',$other)->data['status']==='starting','Any approved device can poll');
    $upcoming=callAPI('gallery',$other)->data;
    check($upcoming['outputs']===[] && count($upcoming['jobs'])===1,'Pending tile shared before output exists');
    check($upcoming['jobs'][0]['id']===$id && $upcoming['jobs'][0]['latestStatus']==='Starting…','Pending tile identity and status');
    check(!isset($upcoming['jobs'][0]['logs']),'Gallery excludes log history');
    $prediction=['id'=>'provider-job','status'=>'processing','logs'=>"Loading\nRendering 75%\n",'output'=>null];
    $jobs[$id]['next_check_at']=null;
    $reply=callAPI('prediction',$other)->data;
    check($reply['latestStatus']==='Rendering 75%','Status polling returns only latest display message');
    check(callAPI('gallery',$other)->data['jobs'][0]['latestStatus']==='Rendering 75%','Shared tile advances to latest status');
    $calls=$providerCalls;
    check(callAPI('prediction',$other)->data['status']==='processing','Cached provider state returned');
    check($providerCalls===$calls,'Shared cache prevents duplicate provider polling');
    $jobs[$id]['next_check_at']=null; $providerHTTP=429; $retryAfter=60;
    try { syncGeneration($jobs[$id]); throw new RuntimeException('Throttling accepted'); }
    catch (ProviderFailure $failure) {
        check($failure->httpStatus===429 && $failure->retryAfter===60,'Rate limit and retry delay retained');
    }
    $calls=$providerCalls;
    check(callAPI('prediction',$other)->data['status']==='processing','Throttled prediction retains recoverable state');
    check($providerCalls===$calls,'Retry-After suppresses repeated provider requests');
    $providerHTTP=201; unset($retryAfter);
    $prediction=['id'=>'provider-job','status'=>'succeeded','logs'=>'Done','output'=>['https://replicate.delivery/result.jpg','https://replicate.delivery/second.jpg']];
    $_GET=['id'=>$id,'secret'=>str_repeat('0',64)];
    try { generationWebhook(); throw new RuntimeException('Invalid callback accepted'); }
    catch (Reply $reply) { check($reply->status===403,'Bad callback denied'); }
    $_GET=$callback;
    $jobs[$id]['provider_id']=null;
    $prediction['webhook']='https://server.example/api.php?action=generation_webhook&id=wrong&secret=wrong';
    try { generationWebhook(['id'=>'unrelated-job']); throw new RuntimeException('Mismatched prediction accepted'); }
    catch (Reply $reply) { check($reply->status===403,'Recovery verifies provider callback binding'); }
    $prediction['webhook']=$body['webhook'];
    $badDownloadAt=2;
    try { generationWebhook(['id'=>'provider-job']); throw new RuntimeException('Corrupt image archived'); }
    catch (RuntimeException $error) { check($error->getMessage()==='Invalid output image.','Corrupt output rejected'); }
    check($images===[] && $jobs[$id]['status']==='processing','Failed archive rolls back database state');
    check($jobs[$id]['provider_id']==='provider-job','Callback recovers missing create response');
    check((glob(outputDirectory().'/*') ?: [])===[],'Failed archive removes temporary files');
    $badDownloadAt=0; $downloads=0;
    try { generationWebhook(); } catch (Reply $reply) { check($reply->status===200,'Completion callback archives outputs'); }
    check(count($images)===2 && $downloads===2,'All outputs archived without client download');
    $page=callAPI('gallery',$other)->data;
    check(count($page['outputs'])===2 && $page['outputs'][0]['prompt']==='Add glasses','Shared metadata');
    check($page['jobs']===[],'Completed images replace pending tile');
    foreach ($images as $image) {
        $path=outputDirectory().'/'.$image['storage_key'];
        check(is_file($path) && (fileperms($path)&0777)===0600,'Private server files');
        check(outputRecord($image['id'])['id']===$image['id'],'Authenticated image lookup');
    }
    $first=$page['outputs'][0]['id'];
    check(count(galleryPage($first)['outputs'])===1,'Cursor pagination');
    $_GET=['id'=>$id];
    check(callAPI('prediction',$other)->data['status']==='succeeded','Archived completion status');
    check($downloads===2,'Retry does not duplicate downloads');
    $_SERVER['REQUEST_METHOD']='POST'; $_GET=['id'=>$first];
    check(callAPI('remove_output',$other)->data['status']==='removed','Other approved device can remove');
    check(!is_file(outputDirectory().'/'.$first.'.jpg'),'Removed bytes deleted');
    $_SERVER['REQUEST_METHOD']='GET'; $_GET=[];
    check(count(callAPI('gallery',$active)->data['outputs'])===1,'Removal shared across devices');
    try { outputRecord($first); throw new RuntimeException('Deleted output served'); }
    catch (Reply $reply) { check($reply->status===404,'Removed output inaccessible'); }
    $_GET=$callback;
    try { generationWebhook(); } catch (Reply $reply) { check($reply->status===200,'Callback retry succeeds'); }
    check($downloads===2 && count(galleryPage()['outputs'])===1,'Retry cannot resurrect deleted output');
    // Definite API rejection becomes a visible, dismissible failed tile with actionable details.
    $providerHTTP=402;
    try { startGeneration(['model'=>str_repeat('a',64),'prompt'=>'Edit','image'=>'data:image/jpeg;base64,AAAA'],$active); throw new RuntimeException('Billing rejection accepted'); }
    catch (Reply $reply) {
        check($reply->status===502 && $reply->data['jobStatus']==='failed','Rejected submission recorded as failed');
        check(str_contains($reply->data['error'],'HTTP 402') && str_contains($reply->data['error'],'credit'),'Billing recovery action is specific');
        $failedID=$reply->data['jobID'];
    }
    $failedTiles=galleryPage()['jobs'];
    check(count(array_filter($failedTiles,fn($row)=>$row['id']===$failedID))===1,'Rejected submission visible without provider ID');
    $_SERVER['REQUEST_METHOD']='POST'; $_GET=['id'=>$failedID];
    check(callAPI('dismiss_generation',$other)->data['status']==='dismissed','Any approved device can dismiss a failed generation');
    check(!array_filter(galleryPage()['jobs'],fn($row)=>$row['id']===$failedID),'Dismissed tile disappears from all devices');
    // A timeout is unconfirmed, not failed: callback recovery remains possible.
    $providerHTTP=201; $transportFailure=true;
    try { startGeneration(['model'=>str_repeat('a',64),'prompt'=>'Edit','image'=>'data:image/jpeg;base64,AAAA'],$active); throw new RuntimeException('Timeout accepted'); }
    catch (Reply $reply) { check($reply->data['jobStatus']==='unconfirmed','Timeout leaves an honest unconfirmed state'); $uncertainID=$reply->data['jobID']; }
    $transportFailure=false;
    $request=json_decode($transport->options[CURLOPT_POSTFIELDS],true);
    parse_str(parse_url($request['webhook'],PHP_URL_QUERY),$uncertainCallback);
    dismissGeneration($uncertainID);
    $prediction=['id'=>'recovered-provider-job','status'=>'succeeded','webhook'=>$request['webhook'],'output'=>['https://replicate.delivery/recovered.jpg']];
    $_GET=$uncertainCallback;
    try { generationWebhook(['id'=>'recovered-provider-job']); } catch (Reply $reply) { check($reply->status===200,'Dismissed uncertain run can still complete'); }
    check($jobs[$uncertainID]['status']==='succeeded','Dismissal preserves callback archival');
    check(!array_filter(galleryPage()['jobs'],fn($row)=>$row['id']===$uncertainID),'Callback cannot restore dismissed tile');
    // A missing provider prediction terminates polling and remains dismissible.
    $missingID=str_repeat('e',64);
    $jobs[$missingID]=array_merge($jobs[$id],['id'=>$missingID,'status'=>'processing','next_check_at'=>null,'dismissed_at'=>null]);
    $providerHTTP=404;
    check(syncGeneration($jobs[$missingID])['status']==='failed','Missing provider prediction is terminal');
    $providerHTTP=201;
    $fresh=startGeneration(['model'=>str_repeat('a',64),'prompt'=>'Edit again','image'=>'data:image/jpeg;base64,AAAA'],$active);
    check(isset($fresh['id']),'A failed or unconfirmed job never prevents a new request');
    foreach ([401,403,422,429,503] as $code) {
        $failure=new ProviderFailure($code);
        check(str_contains($failure->getMessage(),'HTTP '.$code),'Provider status is actionable');
        check(!str_contains($failure->getMessage(),'test-token'),'Credential never exposed in errors');
    }
    try { downloadOutput('https://internal.example/image.jpg',$directory.'/blocked'); throw new RuntimeException('Untrusted output allowed'); }
    catch (RuntimeException $error) { check($error->getMessage()==='Unexpected output URL.','Output download origin restricted'); }
    $_GET=['sha'=>str_repeat('a',64),'expires'=>(string)(time()-1),'signature'=>'bad'];
    try { serveWeights(); } catch (Reply $reply) { check($reply->status===403,'Expired weights blocked'); }
} finally {
    foreach (glob($directory.'/generation-inputs/*') ?: [] as $path) unlink($path);
    if (is_dir($directory.'/generation-inputs')) rmdir($directory.'/generation-inputs');
    foreach (glob($directory.'/outputs/*') ?: [] as $path) unlink($path);
    if (is_dir($directory.'/outputs')) rmdir($directory.'/outputs');
    if (is_file($directory.'/replicate-token')) unlink($directory.'/replicate-token');
    rmdir($directory);
}
echo "Shared server gallery, authentication, callback archival, pagination, deletion and retry tests passed.\n";
