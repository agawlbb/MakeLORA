<?php
declare(strict_types=1);
function vmTestDatabase(): PDO {
    $root=realpath('/home/dev/projects/.test-config');
    $file=realpath(getenv('MAKELORA_TEST_CONFIG') ?: '/home/dev/projects/.test-config/makelora.php');
    if (!$root || !$file || !str_starts_with($file,$root.'/') || pathinfo($file,PATHINFO_EXTENSION)!=='php') throw new RuntimeException('Select an existing VM .test-config PHP database configuration.');
    $config=require $file;
    $dsn=$config['dsn'] ?? sprintf('mysql:host=%s;port=%d;dbname=%s;charset=utf8mb4',$config['host'],$config['port'] ?? 3306,$config['database']);
    $db=new PDO($dsn,$config['user'] ?? $config['username'],$config['password'],[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION,PDO::ATTR_DEFAULT_FETCH_MODE=>PDO::FETCH_ASSOC,PDO::ATTR_EMULATE_PREPARES=>false]);
    if (!str_contains(strtolower((string)$db->query('SELECT DATABASE()')->fetchColumn()),'test')) throw new RuntimeException('Database name must identify a test schema.');
    $db->exec("SET time_zone='+00:00'");
    return $db;
}
