<?php
declare(strict_types=1);
// Real PDO lifecycle and transaction guard, isolated in-memory SQLite only.
require dirname(__DIR__)."/src/database-connection.php";
function check(bool $ok,string $message): void { if (!$ok) throw new RuntimeException($message); }
$private=sys_get_temp_dir().'/makelora-permits-'.bin2hex(random_bytes(8));
mkdir($private,0700);
register_shutdown_function(static function() use ($private): void {
    foreach (glob($private.'/database-connections/*.lock') ?: [] as $file) unlink($file);
    @rmdir($private.'/database-connections');rmdir($private);
});
$config=['dsn'=>'sqlite::memory:','user'=>'','password'=>'','private_session_directory'=>$private];$db=null;
check($db===null,"No eager connection");
$created=databaseConnection();check($created===$db,"First SQL request opens shared connection");
check(databaseConnection()===$created,"Subsequent SQL reuses the connection");unset($created);
$reference=WeakReference::create($db);
check($db->query("SELECT 1")->fetchColumn()===1,"Fixture connection usable");
releaseDatabaseConnection();
check($db===null&&$reference->get()===null,"Release destroys the actual PDO connection");
releaseDatabaseConnection();
$reopened=databaseConnection();check($reopened instanceof PDO,"SQL can reconnect after a released media request");unset($reopened);
$db->beginTransaction();
$blocked=false;
try { releaseDatabaseConnection(); }
catch (LogicException $expected) { $blocked=true; }
check($blocked&&$db instanceof PDO&&$db->inTransaction(),"Transaction remains intact");
$db->rollBack();releaseDatabaseConnection();
check($db===null,"Release succeeds after transaction completes");
$connections=[];
for ($i=0;$i<8;$i++) { $connections[]=databaseConnection(); $db=null; }
$start=microtime(true);$blocked=false;
try { databaseConnection(); } catch (PDOException $expected) { $blocked=true; }
check($blocked && microtime(true)-$start>=2.9,"Ninth connection waits then fails safely");
array_pop($connections);
$statement=databaseConnection()->query('SELECT 1');
releaseDatabaseConnection();
$blocked=false;
try { databaseConnection(); } catch (PDOException $expected) { $blocked=true; }
check($blocked,"Live statement retains its connection permit");
unset($statement);
databaseConnection();releaseDatabaseConnection();
$connections=[];
echo "PDO connection release, idempotence and transaction protection passed.\n";
