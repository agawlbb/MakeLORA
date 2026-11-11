<?php
// php -n: no network, paid jobs, database credentials or persistent files.
declare(strict_types=1);
foreach (['CURLOPT_RETURNTRANSFER','CURLOPT_TIMEOUT','CURLOPT_HTTPHEADER','CURLOPT_POST','CURLOPT_POSTFIELDS','CURLINFO_RESPONSE_CODE','CURLOPT_FOLLOWLOCATION','CURLOPT_WRITEFUNCTION'] as $i=>$name) define($name,$i+1);
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
    return json_encode($GLOBALS['prediction']);
}
function curl_getinfo(object $curl,int $key): int { return isset($curl->options[CURLOPT_WRITEFUNCTION]) ? 200 : 201; }
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
    $rows=[];
    if (str_starts_with($sql,'INSERT INTO makelora_generations')) {
        [$id,$device,$model,$prompt,$hash]=$params;
        $jobs[$id]=['id'=>$id,'device_id'=>$device,'model_name'=>$model,'prompt'=>$prompt,'callback_hash'=>$hash,'status'=>'starting','provider_id'=>null,'logs'=>null];
    } elseif (str_starts_with($sql,'UPDATE makelora_generations SET provider_id')) {
        $jobs[$params[1]]['provider_id']=$params[0];
    } elseif (str_starts_with($sql,'UPDATE makelora_generations SET status')) {
        $jobs[$params[2]]['status']=$params[0]; $jobs[$params[2]]['logs']=$params[1];
    } elseif (str_starts_with($sql,'SELECT * FROM makelora_generations')) {
        if (isset($jobs[$params[0]])) $rows=[$jobs[$params[0]]];
    } elseif (str_starts_with($sql,'INSERT INTO makelora_outputs')) {
        [$id,$job,$index,$key]=$params;
        $images[$id]=['id'=>$id,'generation_id'=>$job,'output_index'=>$index,'storage_key'=>$key,'deleted_at'=>null];
    } elseif (str_starts_with($sql,'SELECT id FROM makelora_outputs')) {
        $rows=array_values(array_filter($images,fn($row)=>$row['generation_id']===$params[0] && $row['output_index']===$params[1]));
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
    return new class($rows) {
        public function __construct(private array $rows) {}
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
foreach (['models','generate','prediction','gallery','output','remove_output'] as $action) {
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
    check(callAPI('gallery',$other)->data['outputs']===[],'Empty shared gallery');
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
    check($images===[] && $jobs[$id]['status']==='starting','Failed archive rolls back database state');
    check($jobs[$id]['provider_id']==='provider-job','Callback recovers missing create response');
    check((glob(outputDirectory().'/*') ?: [])===[],'Failed archive removes temporary files');
    $badDownloadAt=0; $downloads=0;
    try { generationWebhook(); } catch (Reply $reply) { check($reply->status===200,'Completion callback archives outputs'); }
    check(count($images)===2 && $downloads===2,'All outputs archived without client download');
    $page=callAPI('gallery',$other)->data;
    check(count($page['outputs'])===2 && $page['outputs'][0]['prompt']==='Add glasses','Shared metadata');
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
    try { downloadOutput('https://internal.example/image.jpg',$directory.'/blocked'); throw new RuntimeException('Untrusted output allowed'); }
    catch (RuntimeException $error) { check($error->getMessage()==='Unexpected output URL.','Output download origin restricted'); }
    $_GET=['sha'=>str_repeat('a',64),'expires'=>(string)(time()-1),'signature'=>'bad'];
    try { serveWeights(); } catch (Reply $reply) { check($reply->status===403,'Expired weights blocked'); }
} finally {
    foreach (glob($directory.'/outputs/*') ?: [] as $path) unlink($path);
    if (is_dir($directory.'/outputs')) rmdir($directory.'/outputs');
    if (is_file($directory.'/replicate-token')) unlink($directory.'/replicate-token');
    rmdir($directory);
}
echo "Shared server gallery, authentication, callback archival, pagination, deletion and retry tests passed.\n";
