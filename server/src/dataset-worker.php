<?php
declare(strict_types=1);
require_once __DIR__.'/datasets.php';

function datasetRun(array $args,int $timeout=1800): string {
    $process=proc_open($args,[0=>['file','/dev/null','r'],1=>['pipe','w'],2=>['file','/dev/null','w']],$pipes);
    if (!is_resource($process)) throw new RuntimeException('Video processing unavailable.');
    stream_set_blocking($pipes[1],false);$raw='';$deadline=microtime(true)+$timeout;$exit=-1;
    try {
        do {
            $raw.=stream_get_contents($pipes[1]);$status=proc_get_status($process);
            if (strlen($raw)>1024*1024 || microtime(true)>$deadline) { proc_terminate($process,9);throw new RuntimeException('Video processing exceeded its time limit.'); }
            if (!$status['running']) { $exit=$status['exitcode'];$raw.=stream_get_contents($pipes[1]);break; }
            usleep(50000);
        } while (true);
    } finally { fclose($pipes[1]);proc_close($process); }
    if ($exit!==0) throw new RuntimeException('Could not process this video. Check that its format is supported.');
    return $raw;
}
function datasetFFmpeg(): string {
    global $config;$binary=$config['ffmpeg_binary'] ?? '/usr/bin/ffmpeg';
    if (!is_string($binary) || !is_executable($binary)) throw new RuntimeException('Install FFmpeg on the server.');
    return $binary;
}
function datasetProbe(string $path): array {
    $raw=datasetRun([requireVideoTools(),'-v','error','-protocol_whitelist','file,pipe','-format_whitelist','mov,matroska,webm,avi','-select_streams','v:0','-show_entries','stream=width,height,sample_aspect_ratio:stream_side_data=rotation:stream_tags=rotate:format=duration','-of','json',$path],30);
    $data=json_decode($raw,true,32,JSON_THROW_ON_ERROR);$v=$data['streams'][0] ?? [];
    $w=(int)($v['width'] ?? 0);$h=(int)($v['height'] ?? 0);$duration=(float)($data['format']['duration'] ?? 0);
    // Match FFmpeg's autorotation and normalize non-square pixels before cropping.
    $sar=explode(':',$v['sample_aspect_ratio'] ?? '1:1');
    if (count($sar)===2 && (float)$sar[1]>0 && (float)$sar[0]>0) $w=(int)round($w*(float)$sar[0]/(float)$sar[1]);
    $rotation=(float)($v['side_data_list'][0]['rotation'] ?? $v['tags']['rotate'] ?? 0);
    if (abs(fmod($rotation,180))>45 && abs(fmod($rotation,180))<135) [$w,$h]=[$h,$w];
    if ($w<2 || $h<2 || $w>8192 || $h>8192 || $w*$h>40000000 || max($w/$h,$h/$w)>16 || !is_finite($duration) || $duration<0.1 || $duration>1800) throw new RuntimeException('Use a supported video between 0.1 seconds and 30 minutes, with an aspect ratio no wider than 16:1.');
    return ['width'=>$w,'height'=>$h,'duration'=>$duration];
}
function datasetFilters(?array $crop=null,int $short=480): string {
    // First normalize display pixels. All crop coordinates refer to the rotated display image.
    $filters=['scale=trunc(iw*sar/2)*2:trunc(ih/2)*2','setsar=1'];
    if ($crop) $filters[]=sprintf('crop=trunc(iw*%.8F/2)*2:trunc(ih*%.8F/2)*2:trunc(iw*%.8F/2)*2:trunc(ih*%.8F/2)*2',$crop['width'],$crop['height'],$crop['x'],$crop['y']);
    $filters[]="scale=w='if(gte(iw,ih),round($short*iw/ih/2)*2,$short)':h='if(gte(iw,ih),$short,round($short*ih/iw/2)*2)'";
    $filters[]='setsar=1';return implode(',',$filters);
}
function datasetEncode(string $source,string $output,float $start,float $duration,?array $crop=null,bool $preview=false): void {
    $args=[datasetFFmpeg(),'-nostdin','-v','error','-y','-threads','2','-filter_threads','1','-protocol_whitelist','file,pipe','-format_whitelist','mov,matroska,webm,avi','-ss',sprintf('%.6F',$start),'-i',$source,'-t',sprintf('%.6F',$duration),'-map','0:v:0','-an','-sn','-dn','-vf',datasetFilters($crop,$preview ? 360:480),'-c:v','libx264','-threads','2','-preset','veryfast','-crf',$preview ? '28':'20','-pix_fmt','yuv420p','-g','24','-keyint_min','24','-movflags','+faststart','-map_metadata','-1',$output];
    datasetRun($args);chmod($output,0600);validateVideoOutput($output);
}
function datasetStorageCheck(int $extra): void {
    global $config;$root=datasetRoot();$size=0;$limit=(int)($config['dataset_storage_limit_bytes'] ?? 50*1024*1024*1024);
    foreach (new RecursiveIteratorIterator(new RecursiveDirectoryIterator($root,FilesystemIterator::SKIP_DOTS)) as $file) if ($file->isFile()) $size+=$file->getSize();
    $free=disk_free_space($root);
    if ($extra<0 || $size+$extra>$limit || $free===false || $free<$extra+1024*1024*1024) throw new RuntimeException('Server dataset storage is full. Remove unused datasets or increase its storage limit.');
}
function datasetDeviceActive(string $id): bool { return (bool)query("SELECT id FROM makelora_devices WHERE id=? AND status='active'",[$id])->fetch(); }
function datasetImportVideo(string $project,string $id,array $video): void {
    global $config;$directory=datasetPath($project).'/'.$id;
    if (!is_dir($directory)) mkdir($directory,0700);
    try {
        if (!datasetDeviceActive($video['device'])) throw new RuntimeException('The importing device was revoked. Import again from an approved device.');
        $file=driveJSON('files/'.driveID($video['driveID']),['fields'=>'id,name,mimeType,size,parents,capabilities(canDownload)','supportsAllDrives'=>'true'],$video['connection']);
        $limit=(int)($config['dataset_video_limit_bytes'] ?? 2*1024*1024*1024);
        if (!str_starts_with($file['mimeType'] ?? '','video/') || !($file['capabilities']['canDownload'] ?? false) || !isset($file['size']) || (int)$file['size']>$limit || (int)$file['size']<=0) throw new RuntimeException('Select a downloadable video within the server’s file size limit.');
        datasetStorageCheck((int)$file['size']*2);
        datasetUpdate($project,static function(&$p) use ($id,$file) { $p['videos'][$id]['name']=$file['name']; });
        $original=$directory.'/original';
        if (is_file($original)) unlink($original);
        driveDownload($file['id'],$original,$limit,$video['connection']);
        if (filesize($original)!==(int)$file['size']) throw new RuntimeException('Drive video changed while downloading. Import it again.');
        $info=datasetProbe($original);datasetStorageCheck((int)($info['duration']*1024*1024));$caption=driveCaption($file,$video['connection'],$directory);
        datasetEncode($original,$directory.'/preview.mp4',0,$info['duration'],null,true);
        for ($i=0;$i<8;$i++) {
            $position=min($info['duration']-0.05,$info['duration']*$i/8);
            datasetRun([datasetFFmpeg(),'-nostdin','-v','error','-y','-threads','1','-protocol_whitelist','file,pipe','-ss',sprintf('%.6F',$position),'-i',$directory.'/preview.mp4','-frames:v','1','-vf','scale=160:-2','-threads','1',$directory.'/thumb'.$i.'.jpg'],60);
            if (!is_file($directory.'/thumb'.$i.'.jpg')) throw new RuntimeException('Could not create video thumbnails.');
            chmod($directory.'/thumb'.$i.'.jpg',0600);
        }
        if (!datasetDeviceActive($video['device'])) throw new RuntimeException('The importing device was revoked.');
        datasetUpdate($project,static function(&$p) use ($id,$info,$caption) {
            $p['videos'][$id]=array_merge($p['videos'][$id],$info,['status'=>'ready','error'=>null]);
            $clip=bin2hex(random_bytes(16));$p['clips'][$clip]=['id'=>$clip,'videoID'=>$id,'start'=>0.0,'end'=>$info['duration'],'caption'=>$caption,'crop'=>null];$p['revision']++;
            if ($p['exportStatus']==='ready') $p['exportStatus']='none';
        });
    } catch (Throwable $e) {
        if (is_dir($directory)) datasetRemoveTree($directory);
        datasetUpdate($project,static function(&$p) use ($id,$e) { $p['videos'][$id]['status']='failed';$p['videos'][$id]['error']=$e instanceof RuntimeException ? $e->getMessage() : 'Video import failed. Import the video again to retry.'; });
    }
}
function datasetExportProject(string $id,array $p): void {
    $directory=datasetPath($id);$work=$directory.'/render';
    try {
        if (!datasetDeviceActive($p['exportDevice'])) throw new RuntimeException('The exporting device was revoked. Export again from an approved device.');
        if (is_dir($work)) datasetRemoveTree($work);mkdir($work,0700);
        $estimate=0;foreach ($p['clips'] as $clip) $estimate+=(int)(($clip['end']-$clip['start'])*2*1024*1024);
        datasetStorageCheck($estimate*2);
        $zip=new ZipArchive();
        if ($zip->open($work.'/dataset.zip',ZipArchive::CREATE|ZipArchive::OVERWRITE)!==true) throw new RuntimeException('Dataset ZIP unavailable. Install the PHP zip extension.');
        try {
            $n=0;$deadline=microtime(true)+18000;
            foreach ($p['clips'] as $clip) {
                if (microtime(true)>$deadline) throw new RuntimeException('Dataset export exceeded five hours. Split this dataset into smaller projects.');
                $n++;datasetClip($clip,$p);
                datasetEncode($directory.'/'.$clip['videoID'].'/original',$work.'/'.$n.'.mp4',$clip['start'],$clip['end']-$clip['start'],$clip['crop']);
                if (!$zip->addFile($work.'/'.$n.'.mp4',$n.'.mp4') || !$zip->addFromString($n.'.txt',$clip['caption'])) throw new RuntimeException('Could not add a clip to the dataset ZIP.');
            }
        } finally { if (!$zip->close()) throw new RuntimeException('Could not finish the dataset ZIP.'); }
        chmod($work.'/dataset.zip',0600);
        if (!datasetDeviceActive($p['exportDevice'])) throw new RuntimeException('The exporting device was revoked.');
        datasetUpdate($id,static function(&$current) use ($p,$work,$directory) {
            if ($current['revision']!==$p['revision']) { $current['exportStatus']='none';$current['exportError']='Dataset changed during rendering. Export again to include the changes.';return; }
            if (!rename($work.'/dataset.zip',$directory.'/dataset-'.$p['revision'].'.zip')) throw new RuntimeException('Could not save the dataset ZIP.');
            $current['exportStatus']='ready';$current['exportRevision']=$p['revision'];$current['exportError']=null;
        });
        $current=datasetRead($id);
        foreach (glob($directory.'/dataset-*.zip') ?: [] as $old) if ($old!==$directory.'/dataset-'.($current['exportRevision'] ?? -1).'.zip') unlink($old);
    } catch (Throwable $e) { datasetUpdate($id,static function(&$p) use ($e) { $p['exportStatus']='failed';$p['exportError']=$e instanceof RuntimeException ? $e->getMessage() : 'Dataset export failed. Check server video tools and retry.'; }); }
    finally { if (is_dir($work)) datasetRemoveTree($work); }
}
function datasetWorker(): void {
    $lock=fopen(datasetRoot().'/worker.lock','c');chmod(datasetRoot().'/worker.lock',0600);
    if (!$lock || !flock($lock,LOCK_EX|LOCK_NB)) return;
    try {
        file_put_contents(datasetRoot().'/heartbeat',(string)time());chmod(datasetRoot().'/heartbeat',0600);
        // One bounded job per pass. A surviving processing state means the prior worker crashed;
        // this global lock ensures no live worker still owns it, so it is safe to restart locally.
        foreach (glob(datasetRoot().'/*/project.json') ?: [] as $path) {
            $id=basename(dirname($path));
            try { $p=datasetRead($id); } catch (InvalidArgumentException $e) {
                $raw=@file_get_contents($path);$deleted=$raw!==false ? json_decode($raw,true) : null;
                if (($deleted['deleted'] ?? false) && is_dir(dirname($path))) datasetRemoveTree(dirname($path));
                continue;
            }
            foreach ($p['videos'] as $video) if (in_array($video['status'],['queued','processing'],true)) {
                $claimed=false;
                datasetUpdate($id,static function(&$p) use ($video,&$claimed) {
                    if (!($p['deleted'] ?? false) && in_array($p['videos'][$video['id']]['status'] ?? '',['queued','processing'],true)) { $p['videos'][$video['id']]['status']='processing';$claimed=true; }
                });
                if ($claimed) datasetImportVideo($id,$video['id'],$video);return;
            }
            if (in_array($p['exportStatus'],['queued','processing'],true)) {
                $p=datasetUpdate($id,static function(&$p) { if (!($p['deleted'] ?? false)) $p['exportStatus']='processing'; });
                if (!($p['deleted'] ?? false)) datasetExportProject($id,$p);return;
            }
        }
    } finally { flock($lock,LOCK_UN);fclose($lock); }
}
