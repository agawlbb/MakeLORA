<?php
declare(strict_types=1);
// Isolated fixtures only; no database, credentials, network or provider jobs.
if (($argv[1] ?? '')==='child') {
    $root=$argv[2]; $method=$argv[3]; $valid=($argv[4] ?? '')==='valid';
    $config=['private_session_directory'=>$root,'file_storage_directory'=>$root];
    function query(string $sql,array $params=[]): object {
        return new class { public function fetch(): array { return ['storage_key'=>'fixture.safetensors']; } };
    }
    function fail(string $message,int $code=400): never { http_response_code($code); echo $message; exit; }
    require dirname(__DIR__).'/src/generation.php';
    $_SERVER['REQUEST_METHOD']=$method;
    $sha=str_repeat('a',64); $expires=(string)(time()+60);
    $_GET=['sha'=>$sha,'expires'=>$expires,'signature'=>$valid ? hash_hmac('sha256',$sha.':'.$expires,'fixture-token') : 'invalid'];
    ob_start();
    register_shutdown_function(static function(): void {
        $body=ob_get_clean();
        echo json_encode(['status'=>http_response_code() ?: 200,'body'=>base64_encode($body)]);
    });
    serveWeights();
}
$root=sys_get_temp_dir().'/makelora-weight-'.bin2hex(random_bytes(8));
mkdir($root,0700);
file_put_contents($root.'/replicate-token','fixture-token');
file_put_contents($root.'/fixture.safetensors','fixture model bytes');
try {
    foreach (['GET','HEAD'] as $method) foreach (['valid','invalid'] as $signature) {
        $process=proc_open([PHP_BINARY,'-n',__FILE__,'child',$root,$method,$signature],[1=>['pipe','w'],2=>['pipe','w']],$pipes);
        if (!is_resource($process)) throw new RuntimeException('Child process unavailable.');
        $result=json_decode(stream_get_contents($pipes[1]),true,512,JSON_THROW_ON_ERROR);
        $errors=stream_get_contents($pipes[2]);fclose($pipes[1]);fclose($pipes[2]);
        if (proc_close($process)!==0 || $errors!=='') throw new RuntimeException('Child check failed.');
        if ($result['status']!==($signature==='valid' ? 200 : 403)) throw new RuntimeException('Signature guard failed.');
        if ($signature==='valid' && base64_decode($result['body'])!==($method==='GET' ? 'fixture model bytes' : '')) throw new RuntimeException('GET/HEAD body mismatch.');
    }
    echo "Signed weight GET/HEAD and invalid-signature checks passed.\n";
} finally {
    unlink($root.'/replicate-token');unlink($root.'/fixture.safetensors');rmdir($root);
}
