<?php
declare(strict_types=1);

// Keep the permit attached to PDO itself: a retained PDOStatement can keep its
// connection alive even after the request's global reference is cleared.
if (class_exists('PDO')) {
final class LimitedDatabaseConnection extends PDO {
    private $permit;
    public function __construct(array $settings, $permit) {
        $this->permit=$permit;
        parent::__construct($settings['dsn'],$settings['user'],$settings['password'],[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION,PDO::ATTR_DEFAULT_FETCH_MODE=>PDO::FETCH_ASSOC,PDO::ATTR_EMULATE_PREPARES=>false,PDO::ATTR_PERSISTENT=>false,PDO::ATTR_TIMEOUT=>3]);
    }
}
}

function databaseConnectionPermit(array $settings) {
    $limit=$settings['database_connection_limit'] ?? 8;
    if (!is_int($limit) || $limit<1 || $limit>8) throw new PDOException('Invalid database connection limit');
    $directory=($settings['private_session_directory'] ?? '').'/database-connections';
    if (empty($settings['private_session_directory']) || (!is_dir($directory) && !@mkdir($directory,0700,true) && !is_dir($directory))) throw new PDOException('Database permit directory unavailable');
    $deadline=hrtime(true)+3_000_000_000;
    do {
        for ($slot=0;$slot<$limit;$slot++) {
            $permit=@fopen($directory.'/'.$slot.'.lock','c');
            if ($permit===false) throw new PDOException('Database permit unavailable');
            if (flock($permit,LOCK_EX|LOCK_NB)) return $permit;
            fclose($permit);
        }
        usleep(10_000);
    } while (hrtime(true)<$deadline);
    throw new PDOException('Database connection capacity busy');
}

// Open at the first SQL operation, reuse within the request, never persist a
// connection across requests. Invalid/SQL-free requests consume no SQL slot.
function databaseConnection(): PDO {
    global $config,$db;
    if ($db instanceof PDO) return $db;
    try {
        $connection=new LimitedDatabaseConnection($config,databaseConnectionPermit($config));
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
