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
function generationReply(array $prediction): array {
    return ['id'=>$prediction['id'],'status'=>$prediction['status'], 'logs'=>$prediction['logs'] ?? '',
        'output'=>$prediction['output'] ?? [], 'error'=>isset($prediction['error']) ? 'The provider could not generate this image.' : null];
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
function startGeneration(array $input, array $device): array {
    global $config;
    $file=query('SELECT * FROM makelora_files WHERE sha256=?',[$input['model'] ?? ''])->fetch();
    if (!$file || !supportedGenerationModel($file['target_model'])) fail('Choose a Qwen-edit weight.');
    $args=generationSettings($input);
    $token=readReplicateToken($config['private_session_directory']) ?? '';
    $expires=(string)(time()+3600); $sha=$file['sha256'];
    $url=rtrim($config['base_url'],'/').'/api.php?'.http_build_query(['action'=>'weights','sha'=>$sha,'expires'=>$expires,'signature'=>hash_hmac('sha256',$sha.':'.$expires,$token)]);
    $args['lora_weights']=$url;
    $prediction=provider('models/qwen/qwen-image-edit-plus-lora/predictions',['input'=>$args]);
    query('INSERT INTO makelora_generations (id,device_id,created_at) VALUES (?,?,UTC_TIMESTAMP())',[$prediction['id'],$device['id']]);
    return generationReply($prediction);
}
function generationAPI(string $action, array $device): void {
    global $config;
    if ($device['status']!=='active') fail('Approve pairing on the server first.',403);
    if ($action==='models' && $_SERVER['REQUEST_METHOD']==='GET') {
        $files=query('SELECT sha256 AS id,display_name AS displayName,target_model AS baseModel,size_bytes AS sizeBytes,inspection_json FROM makelora_files ORDER BY display_name,sha256')->fetchAll();
        foreach ($files as &$file) {
            $file['sizeBytes']=(int)$file['sizeBytes'];
            $file['details']=json_encode(json_decode($file['inspection_json'],true)['metadata'] ?? [],JSON_UNESCAPED_SLASHES);
            unset($file['inspection_json']);
            $file['supported']=supportedGenerationModel($file['baseModel']);
        }
        jsonResponse(['models'=>$files]);
    }
    if ($action==='prediction' && $_SERVER['REQUEST_METHOD']==='GET') {
        $id=$_GET['id'] ?? '';
        if (!query('SELECT id FROM makelora_generations WHERE id=? AND device_id=?',[$id,$device['id']])->fetch()) fail('Generation not found.',404);
        jsonResponse(generationReply(provider('predictions/'.rawurlencode($id))));
    }
    if ($action==='generate' && $_SERVER['REQUEST_METHOD']==='POST') {
        $raw=file_get_contents('php://input',false,null,0,16000001);
        if (strlen($raw)>16000000) fail('Input image too large.',413);
        $input=json_decode($raw,true,16,JSON_THROW_ON_ERROR);
        jsonResponse(startGeneration($input,$device),201);
    }
}
