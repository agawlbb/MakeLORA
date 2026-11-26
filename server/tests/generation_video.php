<?php
declare(strict_types=1);
// Fake provider traffic; real bounded FFmpeg preparation, no original copies.
ob_start();require __DIR__."/generation.php";ob_end_clean();
if (!defined("CURLOPT_CONNECTTIMEOUT")) define("CURLOPT_CONNECTTIMEOUT",1000);
if (!class_exists("CURLFile")) {
    final class CURLFile { public function __construct(public string $name,public string $mime,public string $postname) {} }
}
$root=sys_get_temp_dir()."/makelora-video-edits-".bin2hex(random_bytes(8));mkdir($root,0700);
$config=["private_session_directory"=>$root,"base_url"=>"https://fixture.invalid/MakeLORA"];
file_put_contents($root."/filebeans.json",json_encode(["url"=>"https://fixture.invalid","token"=>"fixture","sources"=>["fixture"]]));
file_put_contents($root."/replicate-token","fixture-token");
$fixture=__DIR__."/fixtures/wan-output.mp4";$originalHash=hash_file("sha256",$fixture);
$edit=["source"=>"fixture","path"=>"/original.mp4","revision"=>str_repeat("a",64),"vault"=>"","start"=>0.05,"end"=>0.20,"crop"=>["x"=>0.25,"y"=>0,"width"=>0.5,"height"=>1]];
try {
    $normalized=generationVideoEdit($edit);
    check($normalized["start"]===0.05 && $normalized["crop"]["width"]===0.5,"Edit preserves trim and crop");
    foreach ([["source"=>"unconfigured"],["path"=>"/../secret"],["revision"=>""],["start"=>-1],["end"=>61],["end"=>0.06],["crop"=>["x"=>0.9,"y"=>0,"width"=>0.5,"height"=>1]]] as $override) {
        try { generationVideoEdit(array_replace($edit,$override));throw new RuntimeException("Invalid edit accepted"); }
        catch (InvalidArgumentException $expected) {}
    }
    $input=["model"=>WAN_REPLACE_ID,"image"=>"data:image/jpeg;base64,AAAA","video_edit"=>$edit];
    $settings=generationSettings($input);
    check(isset($settings["video_edit"])&&!isset($settings["video"]),"Saved payload contains only video edit, never encoded media or a signed URL");
    $id=str_repeat("c",64);saveGenerationRecipe($id,$input,baseWanReplaceModel());
    $recipe=json_decode($recipes[$id]["settings_json"],true);
    check($recipe["videoEdit"]["revision"]===$edit["revision"]&&$recipe["videoEdit"]["start"]===0.05,"Run again retains original revision and edit");
    $key=retrySavePayload(str_repeat("e",64),$input+["_family"=>"wan_replace"]);
    $retry=json_decode(file_get_contents(retryPayloadPath($key)),true);
    check($retry["video_edit"]["crop"]["width"]===0.5&&!isset($retry["video"]),"Retries retain edit commands without video bytes");
    $prediction=["urls"=>["get"=>"https://api.replicate.com/v1/files/fixture/download?signed=fixture"]];$providerHTTP=201;
    $url=withGenerationVideoClip($normalized,$fixture,static function(string $path): string {
        check(is_file($path)&&filesize($path)>0,"Complete MP4 exists before upload");
        $probe=proc_open(["/usr/bin/ffprobe","-v","error","-show_entries","stream=width,height:format=duration","-of","json",$path],[0=>["file","/dev/null","r"],1=>["pipe","w"],2=>["file","/dev/null","w"]],$pipes);
        $info=json_decode(stream_get_contents($pipes[1],4096),true);fclose($pipes[1]);check(proc_close($probe)===0,"Edited MP4 is readable");
        check(abs($info["streams"][0]["width"]/$info["streams"][0]["height"]-0.5)<0.01,"Rendered crop matches selected half-width region");
        check((float)$info["format"]["duration"]<=0.21,"Rendered trim excludes unselected source duration");
        return uploadGenerationVideoFile($path);
    });
    check($url===$prediction["urls"]["get"] && $transport->url==="https://api.replicate.com/v1/files","Upload uses Replicate Files and returns the hosted input URL");
    check($transport->options[CURLOPT_POSTFIELDS]["content"] instanceof CURLFile,"Upload sends multipart file content");
    check(glob($root."/generation-video-scratch/.clip-*")===[],"Successful upload removes edited temporary MP4");
    try {
        withGenerationVideoClip($normalized,$fixture,static function(string $path): never { throw new RuntimeException("simulated upload failure"); });
        throw new RuntimeException("Upload failure swallowed");
    } catch (RuntimeException $error) { check($error->getMessage()==="simulated upload failure","Upload failure propagated"); }
    check(glob($root."/generation-video-scratch/.clip-*")===[],"Failed upload removes edited temporary MP4");
    try { withGenerationVideoClip($normalized,$root."/missing.mp4",static fn()=>null);throw new RuntimeException("Invalid source rendered"); }
    catch (RuntimeException $error) { check(str_contains($error->getMessage(),"could not be prepared"),"Render failure occurs before provider submission"); }
    check(glob($root."/generation-video-scratch/.clip-*")===[],"Failed render removes edited temporary MP4");
    check(hash_file("sha256",$fixture)===$originalHash,"Source remains untouched");
    echo "FileBeans edit validation, recipe/retry references, actual trim/crop, Files upload contract and success/failure cleanup passed.\n";
} finally {
    foreach (["generation-inputs","retry-inputs","generation-video-scratch"] as $folder) {
        foreach (glob($root."/".$folder."/*") ?: [] as $path) unlink($path);
        foreach (glob($root."/".$folder."/.clip-*") ?: [] as $path) unlink($path);
        if (is_dir($root."/".$folder)) rmdir($root."/".$folder);
    }
    unlink($root."/filebeans.json");unlink($root."/replicate-token");rmdir($root);
}
