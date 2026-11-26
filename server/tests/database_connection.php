<?php
declare(strict_types=1);
// Real PDO lifecycle and transaction guard, isolated in-memory SQLite only.
require dirname(__DIR__)."/src/database-connection.php";
function check(bool $ok,string $message): void { if (!$ok) throw new RuntimeException($message); }
$config=['dsn'=>'sqlite::memory:','user'=>'','password'=>''];$db=null;
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
echo "PDO connection release, idempotence and transaction protection passed.\n";
