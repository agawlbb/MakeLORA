<?php
declare(strict_types=1);
const WAN_BASE_ID='wan-2.1-i2v-14b-480p';
const WAN_REPLACE_ID="wan-2.2-animate-replace";
const WAN_REPLACE_PROVIDER="wan-video/wan-2.2-animate-replace";
const QWEN_PROVIDER='qwen/qwen-image-edit-plus-lora';
function wanContract(): array {
    static $value;
    return $value ??= json_decode(file_get_contents(__DIR__.'/contracts/wan-2.1-i2v-480p.json'),true,32,JSON_THROW_ON_ERROR);
}
function generationFamily(?string $model): ?string {
    return match(strtolower($model ?? '')) {
        'qwen/qwen-image-edit-2509','qwen-image-edit-2509'=>'qwen',
        'wan-ai/wan2.1-i2v-14b-480p','wan2.1-i2v-14b-480p','wan-2.1-i2v-14b-480p'=>'wan',
        WAN_REPLACE_ID,WAN_REPLACE_PROVIDER=>"wan_replace",
        default=>null
    };
}
function supportedGenerationModel(?string $model): bool { return generationFamily($model)!==null; }
function baseWanModel(): array { return ['sha256'=>WAN_BASE_ID,'display_name'=>'Wan 2.1 Image-to-Video 14B · Base','target_model'=>'Wan-AI/Wan2.1-I2V-14B-480P','is_base'=>true]; }
function baseWanReplaceModel(): array { return ["sha256"=>WAN_REPLACE_ID,"display_name"=>"Wan 2.2 Animate Replace","target_model"=>WAN_REPLACE_PROVIDER,"is_base"=>true]; }
function generationFile(mixed $id): array {
    if (!is_string($id)) fail('Choose an available model.');
    if ($id===WAN_REPLACE_ID) return baseWanReplaceModel();
    if ($id===WAN_BASE_ID) return baseWanModel();
    $file=query('SELECT * FROM makelora_files WHERE sha256=?',[$id])->fetch();
    if (!$file || !supportedGenerationModel($file['target_model'])) fail('Choose compatible Qwen Image Edit 2509 or Wan 2.1 I2V 14B 480p weights.');
    return $file;
}
function generationSettings(array $input,?string $family=null): array {
    $family ??= $input['_family'] ?? match($input['model'] ?? '') { WAN_BASE_ID=>'wan',WAN_REPLACE_ID=>'wan_replace',default=>'qwen' };
    if ($family==="wan_replace") return wanReplaceSettings($input);
    if ($family==='qwen') return qwenGenerationSettings($input);
    if ($family!=='wan') fail('Unsupported model family.');
    $properties=wanContract()['input']['properties']; $args=[];
    foreach ($properties as $key=>$schema) {
        if ($key==='lora_weights') continue; // Only the server may construct weight URLs.
        if (!array_key_exists($key,$input) && !array_key_exists('default',$schema)) {
            if ($key==='seed') continue;
            fail('Missing '.$key.'.');
        }
        $value=$input[$key] ?? $schema['default'] ?? null;
        $valid=match($schema['type']) {
            'string'=>is_string($value), 'integer'=>is_int($value), 'number'=>(is_int($value)||is_float($value)) && is_finite((float)$value), 'boolean'=>is_bool($value), default=>false
        };
        if (!$valid || (isset($schema['enum']) && !in_array($value,$schema['enum'],true)) ||
            (isset($schema['minimum']) && $value<$schema['minimum']) || (isset($schema['maximum']) && $value>$schema['maximum'])) fail('Invalid '.$key.'.');
        $args[$key]=$value;
    }
    if (trim($args['prompt'])==='' || strlen($args['prompt'])>10000 || strlen($args['negative_prompt'])>10000 ||
        !preg_match('#^data:image/jpeg;base64,[A-Za-z0-9+/=]+$#D',$args['image']) || strlen($args['image'])>14666700) fail('Invalid image or prompt.');
    if (isset($args['seed']) && ($args['seed']<0 || $args['seed']>2147483647)) fail('Invalid seed.');
    return $args;
}
// Only local file data is accepted; never let a client make the provider fetch arbitrary URLs.
function wanReplaceSettings(array $input): array {
    $image=$input['character_image'] ?? $input['image'] ?? null;
    $video=$input['video'] ?? null;
    if (!is_string($image) || strlen($image)>14666700 || !preg_match('#^data:image/jpeg;base64,[A-Za-z0-9+/=]+$#D',$image)) fail('Choose a character image.');
    if (!is_string($video) || strlen($video)>10666700 || !preg_match('#^data:video/(mp4|quicktime);base64,[A-Za-z0-9+/=]+$#D',$video)) fail('Choose an MP4 or MOV video up to 8 MB.');
    foreach ([$image,$video] as $data) if (base64_decode(substr($data,strpos($data,',')+1),true)===false) fail('Invalid file encoding.');
    $args=['character_image'=>$image,'video'=>$video,'resolution'=>$input['resolution'] ?? '720','merge_audio'=>$input['merge_audio'] ?? true,'go_fast'=>$input['go_fast'] ?? true];
    if (!in_array($args['resolution'],['480','720'],true) || !is_bool($args['merge_audio']) || !is_bool($args['go_fast'])) fail('Invalid replacement settings.');
    if (array_key_exists('seed',$input)) {
        if (!is_int($input['seed']) || $input['seed']<0 || $input['seed']>2147483647) fail('Invalid seed.');
        $args['seed']=$input['seed'];
    }
    return $args;
}
function generationIdentity(array $file): array {
    $family=generationFamily($file['target_model']);
    return ['model_family'=>$family,'provider_model'=>$family==='wan_replace' ? WAN_REPLACE_PROVIDER:($family==='wan' ? wanContract()['model']:QWEN_PROVIDER),'provider_version'=>$family==='wan' ? wanContract()['version']:null];
}
function saveGenerationIdentity(string $id,array $file): void {
    $identity=generationIdentity($file);
    query('UPDATE makelora_generations SET model_family=?,provider_model=?,provider_version=? WHERE id=?',[$identity['model_family'],$identity['provider_model'],$identity['provider_version'],$id]);
}
function generationArguments(array $input,array $file,?array $job=null): array {
    global $config;
    $family=generationFamily($file['target_model']);
    if ($job && $family!==($job['model_family'] ?? 'qwen')) throw new RuntimeException('The model family has changed. Submit a new request.');
    $args=generationSettings($input,$family);
    if ($family==='wan_replace') {
        if (empty($file['is_base'])) fail('Animate Replace does not accept custom LoRA weights.');
        return $args;
    }
    if (empty($file['is_base'])) {
        $token=readReplicateToken($config['private_session_directory']) ?? '';
        $expires=(string)(time()+3600);$sha=$file['sha256'];
        $args['lora_weights']=rtrim($config['base_url'],'/').'/api.php?'.http_build_query(['action'=>'weights','sha'=>$sha,'expires'=>$expires,'signature'=>hash_hmac('sha256',$sha.':'.$expires,$token)]);
    } else { unset($args['lora_scale']); }
    return $args;
}
function submitModelPrediction(array $file,array $args,array $callback,?array $job=null): array {
    $identity=$job ?? generationIdentity($file);
    if (($identity['model_family'] ?? 'qwen')==='wan_replace') return provider('models/'.WAN_REPLACE_PROVIDER.'/predictions',['input'=>$args]+$callback);
    if (($identity['model_family'] ?? 'qwen')==='wan') {
        // Official models expose stable input schemas but hide/alias execution versions.
        // Use the documented model endpoint and retain the observed schema ID for replay.
        return provider('models/'.($identity['provider_model'] ?? wanContract()['model']).'/predictions',['input'=>$args]+$callback);
    }
    return provider('models/'.QWEN_PROVIDER.'/predictions',['input'=>$args]+$callback);
}
