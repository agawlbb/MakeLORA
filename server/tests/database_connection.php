<?php
declare(strict_types=1);
// Real PDO lifecycle and transaction guard, isolated in-memory SQLite only.
require dirname(__DIR__)."/src/database-connection.php";
function check(bool $ok,string $message): void { if (!$ok) throw new RuntimeException($message); }
$db=new PDO("sqlite::memory:");$reference=WeakReference::create($db);
check($db->query("SELECT 1")->fetchColumn()===1,"Fixture connection usable");
releaseDatabaseConnection();
check($db===null&&$reference->get()===null,"Release destroys the actual PDO connection");
releaseDatabaseConnection();
$db=new PDO("sqlite::memory:");$db->beginTransaction();
$blocked=false;
try { releaseDatabaseConnection(); }
catch (LogicException $expected) { $blocked=true; }
check($blocked&&$db instanceof PDO&&$db->inTransaction(),"Transaction remains intact");
$db->rollBack();releaseDatabaseConnection();
check($db===null,"Release succeeds after transaction completes");
echo "PDO connection release, idempotence and transaction protection passed.\n";
