<?php
// Run with php -n: a fake HTTP transport exercises requests without paid jobs.
declare(strict_types=1);
foreach (['CURLOPT_RETURNTRANSFER','CURLOPT_TIMEOUT','CURLOPT_HTTPHEADER','CURLOPT_POST','CURLOPT_POSTFIELDS','CURLINFO_RESPONSE_CODE'] as $i=>$name) define($name,$i+1);
final class Reply extends RuntimeException { public function __construct(public array $data, public int $status=200) {} }
function jsonResponse(array $data,int $code=200): never { throw new Reply($data,$code); }
function fail(string $message,int $code=400): never { throw new Reply(['error'=>$message],$code); }
function curl_init(string $url): object { return (object)['url'=>$url,'options'=>[]]; }
function curl_setopt_array(object $curl,array $options): bool { $curl->options += $options; $GLOBALS['transport']=$curl; return true; }
function curl_exec(object $curl): string { return json_encode(['id'=>'test-job','status'=>'starting','output'=>null]); }
function curl_getinfo(object $curl,int $key): int { return 201; }
function curl_close(object $curl): void {}
function query(string $sql,array $params=[]): object {
    if (str_contains($sql,'INSERT')) $GLOBALS['insert']=$params;
    return new class($sql,$params) {
        public function __construct(private string $sql,private array $params) {}
        public function fetch(): array|false {
            if (str_contains($this->sql,'makelora_generations')) return $this->params===['test-job','active-device'] ? ['id'=>'test-job'] : false;
            return $GLOBALS['file'];
        }
        public function fetchAll(): array { return [['id'=>str_repeat('a',64),'displayName'=>'Glasses','baseModel'=>'Qwen/Qwen-Image-Edit-2509','sizeBytes'=>'42','inspection_json'=>'{"metadata":{"description":"Custom edit"}}']]; }
    };
}
require dirname(__DIR__).'/src/generation.php';
function check(bool $condition,string $message): void { if (!$condition) throw new RuntimeException($message); }
function callAPI(string $action,array $device): Reply {
    try { generationAPI($action,$device); } catch (Reply $reply) { return $reply; }
    throw new RuntimeException('Missing response');
}
check(supportedGenerationModel('Qwen/Qwen-Image-Edit-2509'),'Known model');
check(!supportedGenerationModel('Qwen/Qwen-Image-Edit-2511'),'Do not use incompatible base versions');
check(!supportedGenerationModel(null),'Unknown base disabled');
$settings=generationSettings(['prompt'=>'Add glasses','image'=>'data:image/jpeg;base64,AAAA']);
check($settings['aspect_ratio']==='match_input_image' && $settings['lora_scale']===1.0,'Requested defaults');
check($settings['output_format']==='jpg' && $settings['disable_safety_checker']===true && !isset($settings['seed']),'Output, safety and random seed defaults');
check($settings['image']===['data:image/jpeg;base64,AAAA'],'Provider image array');
$settings=generationSettings(['prompt'=>'Edit','image'=>'data:image/jpeg;base64,AAAA','seed'=>42,'lora_scale'=>0.5,'aspect_ratio'=>'3:4']);
check($settings['seed']===42 && $settings['lora_scale']===0.5 && $settings['aspect_ratio']==='3:4','Overrides');
foreach ([['prompt'=>''],['image'=>'https://untrusted.example/image.jpg'],['lora_scale'=>5],['aspect_ratio'=>'bad'],['seed'=>-1],['seed'=>'42']] as $override) {
    try { generationSettings(array_merge(['prompt'=>'Edit','image'=>'data:image/jpeg;base64,AAAA'],$override)); throw new RuntimeException('Invalid input accepted'); }
    catch (Reply $reply) { check($reply->status===400,'Invalid settings rejected'); }
}
$_SERVER['REQUEST_METHOD']='GET';
$active=['id'=>'active-device','status'=>'active'];
check(callAPI('models',['id'=>'pending','status'=>'pending'])->status===403,'Pending devices blocked');
$catalog=callAPI('models',$active);
check($catalog->data['models'][0]['supported']===true,'Supported catalog');
check($catalog->data['models'][0]['sizeBytes']===42,'Numeric sizes');
check(!isset($catalog->data['models'][0]['inspection_json']),'Raw scan omitted');
$_GET['id']='test-job';
check(callAPI('prediction',['id'=>'other-device','status'=>'active'])->status===404,'Other device cannot poll');
$directory=sys_get_temp_dir().'/makelora-generation-'.bin2hex(random_bytes(8)); mkdir($directory,0700);
$config=['private_session_directory'=>$directory,'base_url'=>'https://server.example/MakeLORA'];
$file=['sha256'=>str_repeat('a',64),'target_model'=>'Qwen/Qwen-Image-Edit-2509'];
try {
    check(callAPI('prediction',$active)->status===503,'Missing token handled');
    file_put_contents($directory.'/replicate-token','test-token');
    $reply=callAPI('prediction',$active);
    check($reply->data['output']===[],'Null output normalized');
    check($GLOBALS['transport']->url==='https://api.replicate.com/v1/predictions/test-job','Fixed provider origin');
    check(in_array('Authorization: Bearer test-token',$GLOBALS['transport']->options[CURLOPT_HTTPHEADER],true),'Uses server token');
    check(!str_contains(json_encode($reply->data),'test-token'),'Token excluded from reply');
    $created=startGeneration(['model'=>str_repeat('a',64),'prompt'=>'Add glasses','image'=>'data:image/jpeg;base64,AAAA'],$active);
    check($created['id']==='test-job' && $GLOBALS['insert']===['test-job','active-device'],'Submission ownership saved');
    $transport=$GLOBALS['transport'];
    check($transport->url==='https://api.replicate.com/v1/models/qwen/qwen-image-edit-plus-lora/predictions','Qwen endpoint');
    $body=json_decode($transport->options[CURLOPT_POSTFIELDS],true)['input'];
    check($body['output_format']==='jpg' && $body['disable_safety_checker']===true,'Provider settings');
    parse_str(parse_url($body['lora_weights'],PHP_URL_QUERY),$signed);
    check(hash_equals(hash_hmac('sha256',$signed['sha'].':'.$signed['expires'],'test-token'),$signed['signature']),'Scoped weight signature');
    check(!str_contains($body['lora_weights'],'test-token'),'Signed URL contains no provider token');
    $file['target_model']='Qwen/Qwen-Image-Edit-2511';
    try { startGeneration(['model'=>str_repeat('a',64)],$active); throw new RuntimeException('Incompatible weight accepted'); }
    catch (Reply $reply) { check($reply->status===400,'Incompatible weights blocked'); }
    $_GET=['sha'=>str_repeat('a',64),'expires'=>(string)(time()-1),'signature'=>'bad'];
    try { serveWeights(); } catch (Reply $reply) { check($reply->status===403,'Expired weight URLs blocked'); }
} finally { unlink($directory.'/replicate-token'); rmdir($directory); }
echo "Generation catalog, device isolation, provider authentication and expired download tests passed.\n";
