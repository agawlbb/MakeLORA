<?php
declare(strict_types=1);

// Open at the first SQL operation, reuse within the request, never persist a
// connection across requests. Invalid/SQL-free requests consume no SQL slot.
function databaseConnection(): PDO {
    global $config,$db;
    if ($db instanceof PDO) return $db;
    try {
        $connection=new PDO($config['dsn'],$config['user'],$config['password'],[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION,PDO::ATTR_DEFAULT_FETCH_MODE=>PDO::FETCH_ASSOC,PDO::ATTR_EMULATE_PREPARES=>false,PDO::ATTR_PERSISTENT=>false,PDO::ATTR_TIMEOUT=>3]);
        if ($connection->getAttribute(PDO::ATTR_DRIVER_NAME)==='mysql') $connection->exec("SET time_zone = '+00:00'");
        return $db=$connection;
    } catch (PDOException $error) {
        error_log('MakeLORA database unavailable: '.get_class($error));
        if (function_exists('fail')) fail('Database temporarily unavailable. Please retry.',503);
        throw $error;
    }
}
// Media transfer needs an authorization result, not an idle database session.
function releaseDatabaseConnection(): void {
    global $db;
    if ($db instanceof PDO && $db->inTransaction()) throw new LogicException("Cannot release a database connection during a transaction.");
    $db=null;
}
