<?php
declare(strict_types=1);
function requireVideoTools(): string {
    global $config;
    $binary=$config['ffprobe_binary'] ?? '/usr/bin/ffprobe';
    if (!is_string($binary) || !is_executable($binary) || !function_exists('proc_open')) throw new RuntimeException('Video generation requires ffprobe and PHP process execution on the server.');
    return $binary;
}
function validateVideoOutput(string $path): void {
    $process=proc_open([requireVideoTools(),'-v','error','-protocol_whitelist','file,pipe','-format_whitelist','mov','-show_entries','stream=codec_type,codec_name,width,height:format=format_name,duration','-of','json',$path],
        [0=>['file','/dev/null','r'],1=>['pipe','w'],2=>['file','/dev/null','w']],$pipes);
    if (!is_resource($process)) throw new RuntimeException('Video inspection unavailable.');
    // ffprobe reads a local, bounded file and outputs only selected metadata.
    stream_set_blocking($pipes[1],false);$raw='';$deadline=microtime(true)+15;$exit=-1;
    try {
        do {
            $raw.=stream_get_contents($pipes[1]);$status=proc_get_status($process);
            if (strlen($raw)>1000000 || microtime(true)>$deadline) { proc_terminate($process,9);throw new RuntimeException('Video inspection exceeded its limit.'); }
            if (!$status['running']) { $exit=$status['exitcode'];$raw.=stream_get_contents($pipes[1]);break; }
            usleep(10000);
        } while (true);
    } finally { fclose($pipes[1]);proc_close($process); }
    $info=json_decode($raw,true);
    $video=false;
    foreach ($info['streams'] ?? [] as $stream) if (($stream['codec_type'] ?? '')==='video' && ($stream['width'] ?? 0)>0 && ($stream['height'] ?? 0)>0 && in_array($stream['codec_name'] ?? '',['h264','hevc','av1'],true)) $video=true;
    if ($exit!==0 || !$video || !str_contains($info['format']['format_name'] ?? '','mp4') || (float)($info['format']['duration'] ?? 0)<=0) throw new RuntimeException('Invalid output video.');
}
/** A single HTTP byte range, inclusive; false denotes an unsatisfiable range. */
function outputByteRange(?string $header,int $size): array|false {
    if ($size<=0) return false;
    if ($header===null) return [0,$size-1];
    if (!preg_match('/^bytes=([0-9]*)-([0-9]*)$/D',$header,$m) || ($m[1]==='' && $m[2]==='')) return false;
    if ($m[1]==='') { $suffix=(int)$m[2];return $suffix>0 ? [max(0,$size-$suffix),$size-1]:false; }
    $start=(int)$m[1];$end=$m[2]==='' ? $size-1:min($size-1,(int)$m[2]);
    return $start<$size && $end>=$start ? [$start,$end]:false;
}
