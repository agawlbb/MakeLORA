<?php
declare(strict_types=1);

function datasetFolderConfigured(): bool {
    global $config;return is_string($config['dataset_export_directory'] ?? null) && $config['dataset_export_directory']!=='';
}
function datasetFolderRoot(): string {
    global $config;$path=$config['dataset_export_directory'] ?? '';
    if (!is_string($path) || !str_starts_with($path,'/') || is_link($path)) throw new RuntimeException('FileBrowser export storage is not configured. Ask the server administrator to connect its dataset folder.');
    $root=realpath($path);$private=realpath(driveRoot());
    if ($root===false || !is_dir($root) || !is_writable($root) || (fileperms($root)&0022)!==0 || $root===$private || str_starts_with($root,$private.'/')) throw new RuntimeException('FileBrowser export storage is unavailable. Check the dataset folder mount and permissions, then export again.');
    foreach ([dirname(__DIR__,2),$_SERVER['DOCUMENT_ROOT'] ?? '', '/var/www/html'] as $public) {
        $public=$public!=='' ? realpath($public) : false;
        if ($public!==false && ($root===$public || str_starts_with($root,$public.'/'))) throw new RuntimeException('Choose a private FileBrowser export directory outside application and web roots.');
    }
    return $root;
}
function datasetFolderLabel(): string {
    global $config;return (string)($config['dataset_export_label'] ?? 'FileBrowser Quantum / MakeLORA datasets');
}
function datasetExportFormat(): string { return datasetFolderConfigured() ? 'folder' : 'zip'; }
function datasetFolderStage(string $project): string {
    $root=datasetFolderRoot();$project=datasetID($project);
    // Only remove this job's crash leftovers while the global dataset worker lock is held.
    foreach (glob($root.'/.makelora-'.$project.'-*') ?: [] as $old) {
        if (preg_match('/^\.makelora-[a-f0-9]{32}-[a-f0-9]{32}$/D',basename($old)) && is_dir($old) && !is_link($old)) datasetRemoveTree($old);
    }
    $path=$root.'/.makelora-'.$project.'-'.bin2hex(random_bytes(16));
    if (!mkdir($path,02700)) throw new RuntimeException('Could not create the FileBrowser export folder. Check available storage and permissions.');
    chmod($path,02700);return $path;
}
function datasetFolderFile(string $source,string $destination): void {
    if (!is_file($source) || is_link($source) || !copy($source,$destination)) throw new RuntimeException('Could not copy a rendered clip to FileBrowser. Check storage and retry the export.');
    if (!chmod($destination,0660)) throw new RuntimeException('Could not set FileBrowser dataset permissions.');
}
function datasetFolderFromZIP(string $archive,string $stage,array $p): void {
    $zip=new ZipArchive();
    if ($zip->open($archive)!==true) throw new RuntimeException('The saved ZIP could not be opened. Render the dataset again before copying it.');
    try {
        if ($zip->numFiles!==count($p['clips'])*2) throw new RuntimeException('The saved export does not match the dataset. Render it again.');
        $n=0;
        foreach ($p['clips'] as $clip) {
            $n++;
            foreach (['mp4','txt'] as $extension) {
                $name=$n.'.'.$extension;$stat=$zip->statName($name);
                if (!$stat || $stat['name']!==$name || ($stat['size'] ?? 0)>($extension==='txt' ? 1024*1024 : 8*1024*1024*1024)) throw new RuntimeException('The saved export has missing or invalid files. Render it again.');
                $input=$zip->getStream($name);$output=fopen($stage.'/'.$name,'xb');
                if (!$input || !$output) throw new RuntimeException('Could not copy the saved dataset to FileBrowser. Check storage and retry.');
                try { $bytes=stream_copy_to_stream($input,$output);if ($bytes!==$stat['size']) throw new RuntimeException('The dataset copy did not finish. Check available storage and retry.'); }
                finally { fclose($input);fclose($output); }
                chmod($stage.'/'.$name,0660);
            }
            if (file_get_contents($stage.'/'.$n.'.txt')!==$clip['caption']) throw new RuntimeException('The saved export captions do not match this revision. Render the dataset again.');
        }
    } finally { $zip->close(); }
}
function datasetFolderName(array $p): string {
    $name=preg_replace('/[^\p{L}\p{N} ._-]+/u','_', $p['name']);
    $name=trim(mb_strcut($name ?? '',0,120,'UTF-8'),' ._-');return $name!=='' ? $name : 'Dataset';
}
/** Publish a complete snapshot. Existing folders and user files are never replaced. */
function datasetPublishFolder(string $stage,array $p): string {
    $root=datasetFolderRoot();$base=datasetFolderName($p);
    for ($attempt=0;$attempt<10;$attempt++) {
        $name=$attempt===0 ? $base : $base.'-r'.$p['revision'].($attempt===1 ? '' : '-'.bin2hex(random_bytes(4)));
        $target=$root.'/'.$name;
        if (file_exists($target) || is_link($target)) continue;
        // Reserve a fresh empty directory exclusively. Rename replaces only our reservation;
        // if someone adds files meanwhile, rename fails and those files remain untouched.
        if (!@mkdir($target,02700)) { if (file_exists($target)) continue;throw new RuntimeException('Could not reserve a FileBrowser export folder. Check its permissions.'); }
        chmod($target,02700);
        if (!rename($stage,$target)) { @rmdir($target);throw new RuntimeException('Could not publish the completed FileBrowser dataset folder. Retry the export.'); }
        if (!chmod($target,02770)) throw new RuntimeException('The dataset was copied but its FileBrowser permissions could not be set. Ask the server administrator to check the export folder.');
        return $name;
    }
    throw new RuntimeException('Could not choose an unused dataset folder name. Rename the dataset and export again.');
}
