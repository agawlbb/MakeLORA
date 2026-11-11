<?php
declare(strict_types=1);
// Only temporary tables in the VM test database; no production credentials.
$config=require '/home/dev/projects/.test-config/makelora.php';
$db=new PDO($config['dsn'],$config['user'],$config['password'],[
    PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION,PDO::ATTR_DEFAULT_FETCH_MODE=>PDO::FETCH_ASSOC]);
$old=file_get_contents(dirname(__DIR__).'/migrations/004_generations.sql');
$db->exec(str_replace('CREATE TABLE IF NOT EXISTS','CREATE TEMPORARY TABLE',$old));
$db->exec("INSERT INTO makelora_generations (id,device_id,created_at) VALUES ('old-provider-job','device-a',UTC_TIMESTAMP())");
$migration=file_get_contents(dirname(__DIR__).'/migrations/005_server_gallery.sql');
$db->exec(str_replace('CREATE TABLE IF NOT EXISTS','CREATE TEMPORARY TABLE',$migration));
$legacy=$db->query("SELECT * FROM makelora_generations WHERE id='old-provider-job'")->fetch();
if ($legacy['provider_id']!=='old-provider-job') throw new RuntimeException('Legacy job migration failed.');
$db->exec("UPDATE makelora_generations SET model_name='Model',prompt='Prompt' WHERE id='old-provider-job'");
$id=str_repeat('a',64);
$stmt=$db->prepare('INSERT INTO makelora_outputs (id,generation_id,output_index,storage_key,created_at) VALUES (?,?,?,?,UTC_TIMESTAMP())');
$stmt->execute([$id,'old-provider-job',0,$id.'.jpg']);
function query(string $sql,array $params=[]): PDOStatement {
    global $db; $statement=$db->prepare($sql); $statement->execute($params); return $statement;
}
function fail(string $message,int $status=400): never { throw new RuntimeException($message); }
require dirname(__DIR__).'/src/generation.php';
$page=galleryPage();
if (count($page['jobs'])!==1 || $page['jobs'][0]['latestStatus']!=='Starting…') throw new RuntimeException('Pending gallery SQL failed.');
if (count($page['outputs'])!==1 || $page['outputs'][0]['prompt']!=='Prompt') throw new RuntimeException('Gallery SQL failed.');
if (galleryPage($id)['outputs']!==[]) throw new RuntimeException('Gallery cursor failed.');
$db->exec("UPDATE makelora_outputs SET deleted_at=UTC_TIMESTAMP()");
if (galleryPage()['outputs']!==[]) throw new RuntimeException('Deleted image listed.');
echo "Temporary-table migration, legacy job, gallery SQL and deletion checks passed.\n";
