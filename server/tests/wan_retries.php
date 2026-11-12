<?php
declare(strict_types=1);
require __DIR__.'/retry_queue.php';
$root=sys_get_temp_dir().'/makelora-wan-queue-'.bin2hex(random_bytes(8));mkdir($root,0700);
$config=['private_session_directory'=>$root,'base_url'=>'https://fixture.invalid/MakeLORA','ffprobe_binary'=>getenv('MAKELORA_TEST_FFPROBE') ?: '/usr/bin/ffprobe'];
file_put_contents($root.'/replicate-token','fixture-token');
$input=['model'=>WAN_BASE_ID,'image'=>'data:image/jpeg;base64,AAAA','prompt'=>'Move forward','aspect_ratio'=>'9:16','negative_prompt'=>'blur','sample_steps'=>20,'sample_shift'=>4,'sample_guide_scale'=>7.0,'fast_mode'=>'Fast','disable_safety_checker'=>false,'retry_offline'=>true];
try {
    resetQueueFixture();
    $reply=startGeneration($input,$device);$id=$reply['id'];
    check($reply['status']==='retry_scheduled','Wan temporary rejection queues retries');
    $payload=json_decode(file_get_contents(retryPayloadPath($jobs[$id]['retry_payload_key'])),true);
    check($payload['negative_prompt']==='blur' && $payload['sample_steps']===20 && $payload['sample_shift']===4 && $payload['fast_mode']==='Fast' && $payload['_family']==='wan','Retry retains every video setting');
    $version=$jobs[$id]['provider_version'];
    $createCode=201;forceDue($id);processRetryJob($id);
    check(count($creates)===2 && $creates[1]['version']===$version,'Headless retry uses the original pinned Wan version');
    check($creates[1]['input']['aspect_ratio']==='9:16' && !isset($creates[1]['input']['lora_weights']),'Base retry maps settings without LoRA');
    check($jobs[$id]['provider_id']!==null && $jobs[$id]['retry_payload_key']===null,'Accepted video is polled, retained resubmission input removed');
    $accepted=count($creates);forceDue($id);processRetryJob($id);
    check(count($creates)===$accepted,'Polling accepted video cannot submit another prediction');
    resetQueueFixture();
    $createCode=201;
    $custom=$input;$custom['model']=str_repeat('a',64);$custom['lora_scale']=0.6;
    $fixtureBaseModel='Wan-AI/Wan2.1-I2V-14B-480P';
    $reply=startGeneration($custom,$device);$customID=$reply['id'];
    check($creates[0]['input']['lora_scale']===0.6 && isset($creates[0]['input']['lora_weights']),'Wan LoRA submission uses weight transport');
    $attempt=latestRetryAttempt($customID);
    $candidate=$predictions[$jobs[$customID]['provider_id']];
    $history=['results'=>[$candidate],'next'=>null];
    check(reconcileRetryAttempt($jobs[$customID],$attempt)['id']===$candidate['id'],'Reconciliation recognizes Wan provider and version');
    echo "Wan headless retry settings, pinned versions, base/LoRA transport, polling and reconciliation passed.\n";
} finally {
    unset($fixtureBaseModel,$downloadBytes);
    foreach (['retry-inputs','outputs','generation-inputs'] as $folder) {
        foreach (glob($root.'/'.$folder.'/*') ?: [] as $path) unlink($path);
        if (is_dir($root.'/'.$folder)) rmdir($root.'/'.$folder);
    }
    unlink($root.'/replicate-token');rmdir($root);
}
