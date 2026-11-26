<?php
declare(strict_types=1);
require_once __DIR__."/datasets.php";

// Durable state is a revision-pinned FileBeans reference and a normalized edit.
function generationVideoEdit(mixed $value): array {
    if (!is_array($value)) throw new InvalidArgumentException("Choose a FileBeans video and save its trim and crop.");
    $location=filebeansLocation($value);
    $revision=$value["revision"] ?? null;$vault=$value["vault"] ?? "";
    if (!is_string($revision)||$revision===""||strlen($revision)>256||!is_string($vault)||strlen($vault)>256) throw new InvalidArgumentException("Invalid video reference.");
    $start=$value["start"] ?? null;$end=$value["end"] ?? null;
    if ((!is_int($start)&&!is_float($start))||(!is_int($end)&&!is_float($end))||!is_finite((float)$start)||!is_finite((float)$end)||$start<0||$end-$start<0.1||$end-$start>60.001) throw new InvalidArgumentException("Choose a video trim between 0.1 and 60 seconds.");
    return $location+["revision"=>$revision,"vault"=>$vault,"start"=>(float)$start,"end"=>(float)$end,"crop"=>datasetCrop($value["crop"] ?? null)];
}
function generationVideoReference(array $edit): array { return array_intersect_key($edit,array_flip(["source","path","revision","vault"])); }
function generationVideoCheck(array $reference): array {
    $meta=datasetCheckSource($reference);
    if (!str_starts_with($meta["type"] ?? "","video/")) throw new InvalidArgumentException("Choose a video from FileBeans.");
    return $meta;
}
function generationVideoKey(): string {
    $path=datasetPrivateRoot()."/generation-video-signing-key";
    if (!is_file($path)) {
        $handle=@fopen($path,"x");
        if ($handle) { chmod($path,0600);fwrite($handle,bin2hex(random_bytes(32)));fclose($handle); }
    }
    $key=file_get_contents($path);
    if (!is_string($key)||strlen($key)!==64) throw new RuntimeException("Video signing unavailable.");
    return $key;
}
function generationVideoURL(array $reference,string $device): string {
    global $config;
    $payload=base64_encode(json_encode(["reference"=>$reference,"device"=>$device,"expires"=>time()+3600],JSON_THROW_ON_ERROR));
    return rtrim($config["base_url"],"/")."/api.php?".http_build_query(["action"=>"generation_video_media","payload"=>$payload,"signature"=>hash_hmac("sha256","generation-video|".$payload,generationVideoKey())]);
}
function generationVideoSource(array $input,array $device): array {
    $location=filebeansLocation($input);$meta=filebeansAPI("GET","fs/resources",$location);
    $reference=$location+["revision"=>$meta["revision"],"vault"=>$meta["vault"] ?? ""];
    if (isset($input["revision"]) && $reference["revision"]!==$input["revision"]) throw new FileBeansFailure("source_changed","Source changed. Select the video again and review its edits.",409);
    generationVideoCheck($reference);
    filebeansAPI("POST","datasets/activity",[],[array_intersect_key($reference,array_flip(["source","path","vault"]))]);
    $info=filebeansAPI("GET","datasets/source/info",$reference+["model"=>"wan"]);
    if (($info["duration"] ?? 0)<=0||($info["width"] ?? 0)<=0||($info["height"] ?? 0)<=0) throw new InvalidArgumentException("Video details unavailable.");
    return $reference+["name"=>$meta["name"],"duration"=>$info["duration"],"width"=>$info["width"],"height"=>$info["height"],"previewURL"=>generationVideoURL($reference,$device["id"])];
}
function requireGenerationVideoRenderer(): void {
    global $config;
    if (!is_executable($config["ffmpeg_binary"] ?? "/usr/bin/ffmpeg")||!is_executable("/usr/bin/timeout")||!is_executable("/usr/bin/prlimit")) throw new RuntimeException("Video generation requires ffmpeg, timeout and prlimit on the server.");
}
function generationVideoArgument(array $edit,string $device): string {
    global $config;
    requireGenerationVideoRenderer();
    if (!readReplicateToken($config["private_session_directory"])) fail("Configure the Replicate token first.",503);
    $reference=generationVideoReference($edit);generationVideoCheck($reference);
    $info=filebeansAPI("GET","datasets/source/info",$reference+["model"=>"wan"]);
    if ($edit["end"]>($info["duration"] ?? 0)+0.001) throw new InvalidArgumentException("The trim extends beyond the source video.");
    filebeansAPI("POST","datasets/activity",[],[array_intersect_key($reference,array_flip(["source","path","vault"]))]);
    return withGenerationVideoClip($edit,generationVideoURL($reference,$device),'uploadGenerationVideoFile');
}
function uploadGenerationVideoFile(string $path): string {
    global $config;

    $token=readReplicateToken($config["private_session_directory"]);
    if (!$token) fail("Configure the Replicate token first.",503);
    $curl=curl_init("https://api.replicate.com/v1/files");
    curl_setopt_array($curl,[CURLOPT_POST=>true,CURLOPT_RETURNTRANSFER=>true,CURLOPT_FOLLOWLOCATION=>false,CURLOPT_CONNECTTIMEOUT=>15,CURLOPT_TIMEOUT=>180,CURLOPT_HTTPHEADER=>["Authorization: Bearer ".$token],CURLOPT_POSTFIELDS=>["content"=>new CURLFile($path,"video/mp4","clip.mp4")]]);
    $raw=curl_exec($curl);$code=curl_getinfo($curl,CURLINFO_RESPONSE_CODE);$error=curl_errno($curl);curl_close($curl);
    if ($raw===false||$code<200||$code>=300) throw new ProviderFailure($raw===false ? 0:$code,30,$error);
    $reply=json_decode($raw,true,16,JSON_THROW_ON_ERROR);$url=$reply["urls"]["get"] ?? "";
    if (!is_string($url)) throw new RuntimeException("Replicate file upload returned an invalid URL.");
    $host=parse_url($url,PHP_URL_HOST);
    if (!is_string($url)||parse_url($url,PHP_URL_SCHEME)!=="https"||!is_string($host)||!($host==="api.replicate.com"||$host==="replicate.delivery"||str_ends_with($host,".replicate.delivery"))) throw new RuntimeException("Replicate file upload returned an invalid URL.");
    return $url;
}

// One bounded edited clip at a time; remove it after upload, on error, or shutdown.
// The original is always read from FileBeans and is never staged here.
function withGenerationVideoClip(array $edit,string $url,callable $consume): mixed {
    global $config;
    requireGenerationVideoRenderer();
    $root=datasetPrivateRoot()."/generation-video-scratch";
    if (!is_dir($root)&&!mkdir($root,0700)&&!is_dir($root)) throw new RuntimeException("Video scratch unavailable.");
    $lock=fopen($root."/lock","c");chmod($root."/lock",0600);
    if (!$lock||!flock($lock,LOCK_EX|LOCK_NB)) { if ($lock) fclose($lock);throw new RuntimeException("Another video is being prepared. Retry shortly."); }
    $path=null;$process=null;
    try {
        // A killed PHP worker can leave an interrupted clip. The exclusive lock
        // proves these files are no longer owned by another active preparation.
        foreach (glob($root."/.clip-*") ?: [] as $orphan) if (is_file($orphan)) unlink($orphan);
        if (disk_free_space($root)<250000000) throw new RuntimeException("Insufficient video scratch space.");
        $path=tempnam($root,".clip-");if ($path===false) throw new RuntimeException("Video scratch unavailable.");chmod($path,0600);
        register_shutdown_function(static function() use ($path): void { if (is_file($path)) unlink($path); });
        $crop=$edit["crop"] ?? ["x"=>0,"y"=>0,"width"=>1,"height"=>1];
        $filter=sprintf("crop=trunc(iw*%.9F/2)*2:trunc(ih*%.9F/2)*2:trunc(iw*%.9F/2)*2:trunc(ih*%.9F/2)*2,scale=1280:720:force_original_aspect_ratio=decrease:force_divisible_by=2,fps=30,setsar=1",$crop["width"],$crop["height"],$crop["x"],$crop["y"]);
        $command=["/usr/bin/timeout","--signal=KILL","300","/usr/bin/prlimit","--fsize=100000000","--as=2147483648","--cpu=300","--",$config["ffmpeg_binary"] ?? "/usr/bin/ffmpeg","-nostdin","-hide_banner","-loglevel","error","-y","-threads","2","-filter_threads","1","-ss",(string)$edit["start"],"-i",$url,"-t",(string)($edit["end"]-$edit["start"]),"-vf",$filter,"-map","0:v:0","-map","0:a?","-c:v","libx264","-threads","2","-preset","veryfast","-crf","20","-c:a","aac","-fs","95000000","-movflags","+faststart","-f","mp4",$path];
        $process=proc_open($command,[0=>["file","/dev/null","r"],1=>["file","/dev/null","w"],2=>["file","/dev/null","w"]],$pipes);
        if (!is_resource($process)) throw new RuntimeException("Video renderer unavailable.");
        set_time_limit(600);ignore_user_abort(true);
        $code=proc_close($process);$process=null;clearstatcache(true,$path);
        if ($code!==0||filesize($path)===0||filesize($path)>=94000000) throw new RuntimeException("The edited video could not be prepared within the time or size limit. Choose a shorter clip.");
        validateVideoOutput($path);
        return $consume($path);
    } finally {
        if (is_resource($process)) { proc_terminate($process,9);proc_close($process); }
        if (is_string($path)&&is_file($path)) unlink($path);
        flock($lock,LOCK_UN);fclose($lock);
    }
}
function serveGenerationVideo(): never {
    $payload=$_GET["payload"] ?? "";$signature=$_GET["signature"] ?? "";
    if (!is_string($payload)||strlen($payload)>20000||!is_string($signature)||!hash_equals(hash_hmac("sha256","generation-video|".$payload,generationVideoKey()),$signature)) fail("Video link unavailable.",403);
    $decoded=base64_decode($payload,true);$value=$decoded===false ? null:json_decode($decoded,true,16,JSON_THROW_ON_ERROR);
    if (!is_array($value)||($value["expires"] ?? 0)<time()) fail("Video link expired. Reopen the editor.",403);
    $device=query("SELECT * FROM makelora_devices WHERE id=?",[$value["device"]])->fetch();
    if (!$device||$device["status"]!=="active") fail("Device unavailable.",403);
    releaseDatabaseConnection();
    $reference=$value["reference"];filebeansLocation($reference);generationVideoCheck($reference);
    filebeansProxy($_SERVER["REQUEST_METHOD"],"datasets/source/content",$reference);
}
