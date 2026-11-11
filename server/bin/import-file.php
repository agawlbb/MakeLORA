<?php
// CLI only. Storage is outside the web document root; no download route exists.
declare(strict_types=1);
if (PHP_SAPI !== 'cli') { http_response_code(404); exit; }
if ($argc !== 2 || !is_file($argv[1])) { fwrite(STDERR,"Usage: php server/bin/import-file.php FILE\n"); exit(1); }
$config = require (getenv('MAKELORA_CONFIG') ?: '/home/dev/projects/.test-config/makelora.php');
if (($config['environment'] ?? '') !== 'prototype') { throw new RuntimeException('VM prototype configuration required'); }
$root = dirname(__DIR__).'/storage/files';
if (!is_dir($root) && !mkdir($root,0700,true)) { throw new RuntimeException('Cannot create storage'); }
$temp = tempnam($root,'.import-');
if ($temp === false) { throw new RuntimeException('Cannot create import snapshot'); }
try {
    if (!copy($argv[1],$temp)) { throw new RuntimeException('Cannot copy source'); }
    chmod($temp,0600);
    $process=proc_open(['python3',__DIR__.'/inspect_safetensors.py',$temp],[1=>['pipe','w'],2=>['pipe','w']],$pipes);
    if (!is_resource($process)) { throw new RuntimeException('Cannot start scanner'); }
    $report=stream_get_contents($pipes[1]); fclose($pipes[1]);
    $errors=stream_get_contents($pipes[2]); fclose($pipes[2]);
    if (proc_close($process)!==0) { throw new RuntimeException(trim($errors)); }
    $scan=json_decode($report,true,512,JSON_THROW_ON_ERROR);
    $key=$scan['sha256'].'.safetensors';
    $destination=$root.'/'.$key;
    if (is_file($destination)) {
        if (hash_file('sha256',$destination)!==$scan['sha256']) { throw new RuntimeException('Existing storage checksum mismatch'); }
        unlink($temp);
    } elseif (!rename($temp,$destination)) { throw new RuntimeException('Cannot finalize storage'); }
    $db=new PDO($config['dsn'],$config['user'],$config['password'],[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION,PDO::ATTR_EMULATE_PREPARES=>false]);
    $tensors=json_encode($scan['tensors'],JSON_THROW_ON_ERROR); unset($scan['tensors']);
    $sql='INSERT INTO makelora_files (sha256,original_name,storage_key,size_bytes,inspection_json,tensors_json,imported_at,inspected_at) VALUES (?,?,?,?,?,?,UTC_TIMESTAMP(),UTC_TIMESTAMP()) ON DUPLICATE KEY UPDATE inspection_json=VALUES(inspection_json),tensors_json=VALUES(tensors_json),inspected_at=UTC_TIMESTAMP()';
    $db->prepare($sql)->execute([$scan['sha256'],basename($argv[1]),$key,$scan['size_bytes'],json_encode($scan,JSON_THROW_ON_ERROR),$tensors]);
    echo json_encode($scan,JSON_PRETTY_PRINT|JSON_UNESCAPED_SLASHES|JSON_THROW_ON_ERROR)."\n";
} finally { if (is_file($temp)) { unlink($temp); } }
