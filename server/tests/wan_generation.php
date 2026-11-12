<?php
// Real MP4 validation, simulated provider traffic and in-memory SQL. No paid requests.
declare(strict_types=1);
require __DIR__.'/generation.php';
$directory=sys_get_temp_dir().'/makelora-wan-'.bin2hex(random_bytes(8));mkdir($directory,0700);
$config=['private_session_directory'=>$directory,'base_url'=>'https://fixture.invalid/MakeLORA','ffprobe_binary'=>getenv('MAKELORA_TEST_FFPROBE') ?: '/usr/bin/ffprobe'];
file_put_contents($directory.'/replicate-token','fixture-token');
$jobs=[];$images=[];$recipes=[];$downloads=0;$providerHTTP=201;$transportFailure=false;
$input=['model'=>WAN_BASE_ID,'image'=>'data:image/jpeg;base64,AAAA','prompt'=>'A bird takes flight','negative_prompt'=>'blur','aspect_ratio'=>'9:16','sample_steps'=>12,'sample_shift'=>4,'sample_guide_scale'=>6.5,'fast_mode'=>'Off','seed'=>123];
try {
    check(generationFamily('Wan-AI/Wan2.1-I2V-14B-480P')==='wan','Wan weights recognized');
    check(!supportedGenerationModel('Wan-AI/Wan2.1-I2V-14B-720P'),'720p weights cannot run in the 480p endpoint');
    foreach ([['aspect_ratio'=>'1:1'],['fast_mode'=>'Quality'],['sample_steps'=>0],['sample_steps'=>41],['sample_steps'=>2.5],['sample_shift'=>-1],['sample_guide_scale'=>11],['disable_safety_checker'=>'true'],['negative_prompt'=>[]]] as $override) {
        try { generationSettings(array_replace($input,$override));throw new RuntimeException('Invalid Wan setting accepted'); }
        catch (Reply $reply) { check($reply->status===400,'Wan validation fails before paid requests'); }
    }
    $args=generationArguments($input,baseWanModel());
    check(is_string($args['image']) && !isset($args['lora_weights'],$args['output_format']),'Wan uses one image and omits Qwen output settings');
    check(!isset($args['lora_scale']) && !$args['disable_safety_checker'],'Base model omits LoRA and preserves provider safety default');
    $wanFile=['sha256'=>str_repeat('b',64),'display_name'=>'Custom motion','target_model'=>'Wan-AI/Wan2.1-I2V-14B-480P'];
    $args=generationArguments($input+['lora_scale'=>0.7],$wanFile);
    parse_str(parse_url($args['lora_weights'],PHP_URL_QUERY),$signature);
    check($signature['sha']===$wanFile['sha256'] && $args['lora_scale']===0.7,'Wan LoRA gets signed weight URL and selected strength');
    $prediction=['id'=>'wan-provider','status'=>'starting'];
    $created=startGeneration($input,['id'=>'device-a','status'=>'active']);$id=$created['id'];
    $body=json_decode($transport->options[CURLOPT_POSTFIELDS],true);
    check($transport->url==='https://api.replicate.com/v1/predictions' && $body['version']===wanContract()['version'],'Wan requests pin the verified version');
    check($jobs[$id]['model_family']==='wan' && $jobs[$id]['provider_version']===$body['version'],'Job stores family and provider version');
    $settings=json_decode($recipes[$id]['settings_json'],true);
    check($settings['negativePrompt']==='blur' && $settings['fastMode']==='Off' && $settings['inferenceSteps']===12 && $settings['flowShift']===4 && $settings['guidanceScale']===6.5,'Replay retains all Wan settings');
    check($settings['outputFormat']==='mp4' && $settings['disableSafetyChecker']===false,'Replay retains video and safety settings');
    $downloadBytes=file_get_contents(__DIR__.'/fixtures/wan-output.mp4');
    $prediction=['id'=>'wan-provider','status'=>'succeeded','input'=>['seed'=>123],'output'=>'https://replicate.delivery/video.mp4'];
    archiveGenerationPrediction($jobs[$id],$prediction);
    $output=array_values($images)[0];
    check($output['media_type']==='video' && $output['mime_type']==='video/mp4' && str_ends_with($output['storage_key'],'.mp4'),'Single provider URL archived as MP4');
    $path=outputDirectory().'/'.$output['storage_key'];
    check(file_get_contents($path)===$downloadBytes,'Streamed bytes archived unchanged');
    check(galleryPage()['outputs'][0]['mediaType']==='video','Gallery identifies video media');
    $before=$downloads;archiveGenerationPrediction($jobs[$id],$prediction);
    check($downloads===$before,'Duplicate callback does not download again');
    removeOutput($output['id']);
    check(!is_file($path),'Deleting video removes MP4');
    archiveGenerationPrediction($jobs[$id],$prediction);
    check($downloads===$before && galleryPage()['outputs']===[],'Deletion tombstone survives callback replay');
    unset($downloadBytes);
    $bad=$directory.'/bad.mp4';file_put_contents($bad,'not a video');
    try { validateVideoOutput($bad);throw new RuntimeException('Corrupt video accepted'); }
    catch (RuntimeException $e) { check($e->getMessage()==='Invalid output video.','Real ffprobe rejects corrupt media'); }
    unlink($bad);
    foreach ([[null,100,[0,99]],['bytes=0-9',100,[0,9]],['bytes=90-',100,[90,99]],['bytes=-5',100,[95,99]],['bytes=0-1000',100,[0,99]],['bytes=100-',100,false],['bytes=4-2',100,false],['bytes=-0',100,false],['bytes=0-1,4-5',100,false]] as [$header,$size,$expected]) check(outputByteRange($header,$size)===$expected,'Byte range '.$header);
    echo "Wan version pinning, settings, base/LoRA mapping, replay, actual MP4 validation, archival, deletion and byte ranges passed.\n";
} finally {
    unset($downloadBytes);
    foreach (['generation-inputs','outputs'] as $folder) {
        foreach (glob($directory.'/'.$folder.'/*') ?: [] as $path) unlink($path);
        if (is_dir($directory.'/'.$folder)) rmdir($directory.'/'.$folder);
    }
    unlink($directory.'/replicate-token');rmdir($directory);
}
