<?php
declare(strict_types=1);
// Actual SQL and private temporary storage; no provider traffic or production credentials.
require __DIR__.'/test_database.php';
$db=vmTestDatabase();
$db->exec(str_replace('CREATE TABLE IF NOT EXISTS','CREATE TEMPORARY TABLE',file_get_contents(dirname(__DIR__).'/schema.sql')));
function query(string $sql,array $params=[]): PDOStatement { global $db;$s=$db->prepare($sql);$s->execute($params);return $s; }
final class RecipeReply extends RuntimeException { public function __construct(public int $status) { parent::__construct('HTTP '.$status); } }
function fail(string $message,int $code=400): never { throw new RecipeReply($code); }
function jsonResponse(array $data,int $code=200): never { throw new RecipeReply($code); }
function check(bool $condition,string $message): void { if (!$condition) throw new RuntimeException($message); }
require dirname(__DIR__).'/src/generation.php';
$root=sys_get_temp_dir().'/makelora-recipes-'.bin2hex(random_bytes(8));mkdir($root,0700);
$config=['private_session_directory'=>$root];
$file=['sha256'=>str_repeat('a',64),'display_name'=>'Glasses','target_model'=>'Qwen/Qwen-Image-Edit-2509'];
$bytes=hex2bin('ffd8ffc00011080001000103011100021100031100ffd9');
$input=['model'=>$file['sha256'],'image'=>'data:image/jpeg;base64,'.base64_encode($bytes),'prompt'=>'Exact prompt','aspect_ratio'=>'4:3','lora_scale'=>0.75,'retry_offline'=>false];
function job(string $status='succeeded'): string {
    $id=bin2hex(random_bytes(32));
    query('INSERT INTO makelora_generations (id,device_id,model_name,prompt,status,created_at) VALUES (?,?,?,?,?,UTC_TIMESTAMP())',[$id,'fixture-device','Glasses','Old prompt',$status]);return $id;
}
function output(string $job,int $index=0): string {
    $id=bin2hex(random_bytes(32));
    query('INSERT INTO makelora_outputs (id,generation_id,output_index,storage_key,created_at) VALUES (?,?,?,?,UTC_TIMESTAMP())',[$id,$job,$index,$id.'.jpg']);
    return $id;
}
try {
    $id=job();saveGenerationRecipe($id,$input,$file);$a=output($id);$b=output($id,1);
    $details=generationDetails($a);
    check(!$details['legacy'] && $details['hasInput'],'New output exposes original/settings');
    check($details['settings']['modelID']===$file['sha256'] && $details['settings']['aspectRatio']==='4:3' && $details['settings']['loraScale']===0.75,'Exact stable weight and settings snapshot');
    check($details['settings']['seed']===null && !$details['settings']['retryOffline'],'Blank seed and disabled retry retained');
    check(!str_contains(json_encode($details),'input_key') && !str_contains(json_encode($details),'base64'),'Details omit storage references and image bytes');
    check(originalImageForOutput($a)===$bytes,'Original image served exactly');
    $path=recipeInputPath($id.'.jpg');
    check((fileperms($path)&0777)===0600 && (fileperms(recipeDirectory())&0777)===0700,'Input files remain private');
    $resolved=resolveGenerationSource(['source_output_id'=>$a,'model'=>$file['sha256'],'prompt'=>'New prompt']);
    check($resolved['image']===$input['image'] && $resolved['prompt']==='New prompt' && !isset($resolved['source_output_id']),'Replay resolves the original and preserves edits');
    try { resolveGenerationSource(['source_output_id'=>$a,'image'=>$input['image']]);throw new RuntimeException('Conflicting source accepted'); }
    catch (RecipeReply $e) { check($e->status===400,'Conflicting sources rejected'); }
    query('UPDATE makelora_generation_recipes SET resolved_seed=? WHERE generation_id=?',[123,$id]);
    check(generationDetails($a)['resolvedSeed']===123 && generationDetails($a)['settings']['seed']===null,'Resolved seed does not replace submitted random choice');
    $copy=job();saveGenerationRecipe($copy,$resolved,$file);$copiedOutput=output($copy);
    // Removing one output keeps the common original; final removal deletes it and preserves tombstones.
    removeOutput($a);check(is_file($path) && generationDetails($b)['hasInput'],'Shared original remains for surviving output');
    removeOutput($b);check(!is_file($path),'Last output removes original');
    check(originalImageForOutput($copiedOutput)===$bytes,'Rerun owns an independent original when its source is removed');
    check((int)query('SELECT COUNT(*) FROM makelora_outputs WHERE generation_id=? AND deleted_at IS NOT NULL',[$id])->fetchColumn()===2,'Deletion tombstones preserved');
    try { originalImageForOutput($b);throw new RuntimeException('Deleted source read'); }
    catch (RecipeReply $e) { check($e->status===404,'Deleted sources cannot be reused'); }
    $legacyID=job();$legacy=output($legacyID);
    $details=generationDetails($legacy);check($details['legacy'] && !$details['hasInput'] && $details['settings']['prompt']==='Old prompt','Legacy output preserves known fields without invented settings');
    try { originalImageForOutput($legacy);throw new RuntimeException('Legacy original invented'); }
    catch (RecipeReply $e) { check($e->status===404,'Legacy input clearly unavailable'); }
    $failed=job('failed');saveGenerationRecipe($failed,$input,$file);
    $active=job('processing');saveGenerationRecipe($active,$input,$file);
    $kept=job();saveGenerationRecipe($kept,$input,$file);output($kept);
    query('UPDATE makelora_generation_recipes SET created_at=DATE_SUB(UTC_TIMESTAMP(),INTERVAL 13 HOUR)');
    purgeUnusedRecipeInputs();
    check(!is_file(recipeInputPath($failed.'.jpg')),'Failed request inputs expire without outputs');
    check(is_file(recipeInputPath($active.'.jpg')),'Accepted active run retains its original');
    check(is_file(recipeInputPath($kept.'.jpg')),'Successful output retains original beyond retry window');
    $orphan=recipeInputPath(str_repeat('f',64).'.jpg');file_put_contents($orphan,'orphan');touch($orphan,time()-43201);
    purgeUnusedRecipeInputs();check(!is_file($orphan),'Crash orphan removed after retention window');
    foreach (['pending','revoked'] as $status) {
        try { generationAPI('generation_details',['status'=>$status]);throw new RuntimeException('Unapproved device accepted'); }
        catch (RecipeReply $e) { check($e->status===403,'Unapproved device denied details'); }
        try { generationAPI('generation_input',['status'=>$status]);throw new RuntimeException('Unapproved device accepted'); }
        catch (RecipeReply $e) { check($e->status===403,'Unapproved device denied original'); }
    }
    echo "VM temporary-table recipe snapshots, exact original reuse, legacy fallback, access control, retention and deletion checks passed.\n";
} finally {
    foreach (glob($root.'/generation-inputs/*') ?: [] as $path) unlink($path);
    if (is_dir($root.'/generation-inputs')) rmdir($root.'/generation-inputs');
    if (is_dir($root.'/outputs')) rmdir($root.'/outputs');rmdir($root);
}
