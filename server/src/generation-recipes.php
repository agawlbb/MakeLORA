<?php
declare(strict_types=1);

function recipeDirectory(): string {
    global $config;
    $directory=$config['private_session_directory'].'/generation-inputs';
    if (!is_dir($directory) && !mkdir($directory,0700,true) && !is_dir($directory)) throw new RuntimeException('Original image storage unavailable.');
    return $directory;
}
function recipeInputPath(string $key): string {
    if (!preg_match('/^[a-f0-9]{64}\.jpg$/D',$key)) throw new RuntimeException('Invalid original image reference.');
    return recipeDirectory().'/'.$key;
}
function saveGenerationRecipe(string $id,array $input,array $file): void {
    $family=generationFamily($file['target_model']);
    $args=generationSettings($input,$family);
    $settings=['modelID'=>$file['sha256'],'modelName'=>$file['display_name'],'baseModel'=>$file['target_model'],
        'prompt'=>$args['prompt'],'aspectRatio'=>$args['aspect_ratio'],'loraScale'=>$args['lora_scale'],
        'seed'=>$args['seed'] ?? null,'outputFormat'=>$family==='wan' ? 'mp4':'jpg','disableSafetyChecker'=>$args['disable_safety_checker'],'retryOffline'=>$input['retry_offline'] ?? false];
    if ($family==='wan') $settings+=['negativePrompt'=>$args['negative_prompt'],'fastMode'=>$args['fast_mode'],'guidanceScale'=>$args['sample_guide_scale'],'inferenceSteps'=>$args['sample_steps'],'flowShift'=>$args['sample_shift'],'providerVersion'=>wanContract()['version']];
    $image=$family==='wan' ? $args['image']:$args['image'][0];
    $bytes=base64_decode(substr($image,strlen('data:image/jpeg;base64,')),true);
    if ($bytes===false || strlen($bytes)>11000000) fail('Invalid original image.',413);
    $key=$id.'.jpg'; $temporary=tempnam(recipeDirectory(),'.input-');
    if ($temporary===false) throw new RuntimeException('Original image storage unavailable.');
    try {
        chmod($temporary,0600);
        if (file_put_contents($temporary,$bytes,LOCK_EX)!==strlen($bytes) || !rename($temporary,recipeInputPath($key))) throw new RuntimeException('Could not store original image.');
        query('INSERT INTO makelora_generation_recipes (generation_id,settings_json,input_key,created_at) VALUES (?,?,?,UTC_TIMESTAMP())',[$id,json_encode($settings,JSON_THROW_ON_ERROR),$key]);
    } catch (Throwable $error) {
        if (is_file(recipeInputPath($key))) unlink(recipeInputPath($key));
        throw $error;
    } finally { if (is_file($temporary)) unlink($temporary); }
}
function recipeForOutput(string $id): array {
    $output=outputRecord($id);
    $recipe=query('SELECT * FROM makelora_generation_recipes WHERE generation_id=?',[$output['generation_id']])->fetch();
    return [$output,$recipe];
}
function generationDetails(string $id): array {
    [$output,$recipe]=recipeForOutput($id);
    $job=query('SELECT * FROM makelora_generations WHERE id=?',[$output['generation_id']])->fetch();
    if (!$recipe) return ['legacy'=>true,'settings'=>['modelName'=>$job['model_name'],'prompt'=>$job['prompt'] ?? ''],'hasInput'=>false,'resolvedSeed'=>null];
    return ['legacy'=>false,'settings'=>json_decode($recipe['settings_json'],true,16,JSON_THROW_ON_ERROR),
        'hasInput'=>!empty($recipe['input_key']) && is_file(recipeInputPath($recipe['input_key'])),
        'resolvedSeed'=>$recipe['resolved_seed']===null ? null:(int)$recipe['resolved_seed']];
}
function originalImageForOutput(string $id): string {
    global $db;
    $output=outputRecord($id);
    $db->beginTransaction();
    try {
        query('SELECT * FROM makelora_generations WHERE id=? FOR UPDATE',[$output['generation_id']])->fetch();
        [$output,$recipe]=recipeForOutput($id); // Recheck deletion after acquiring the shared archival/removal lock.
        if (!$recipe || empty($recipe['input_key']) || !is_file(recipeInputPath($recipe['input_key']))) fail('Original photo unavailable. Choose an input photo to run again.',404);
        $bytes=file_get_contents(recipeInputPath($recipe['input_key']));
        if ($bytes===false) throw new RuntimeException('Could not read original photo.');
        $db->commit();return $bytes;
    } catch (Throwable $error) { if ($db->inTransaction()) $db->rollBack();throw $error; }
}
function resolveGenerationSource(array $input): array {
    if (!array_key_exists('source_output_id',$input)) return $input;
    if (array_key_exists('image',$input) || !is_string($input['source_output_id'])) fail('Choose either an uploaded photo or a previous original.');
    $input['image']='data:image/jpeg;base64,'.base64_encode(originalImageForOutput($input['source_output_id']));
    unset($input['source_output_id']);return $input;
}
// Called while holding the generation row lock. Existing output tombstones remain intact.
function cleanRecipeInputLocked(array $job,bool $lastOutputRemoved=false): ?string {
    $recipe=query('SELECT * FROM makelora_generation_recipes WHERE generation_id=?',[$job['id']])->fetch();
    if (!$recipe || empty($recipe['input_key'])) return null;
    if (query('SELECT id FROM makelora_outputs WHERE generation_id=? AND deleted_at IS NULL LIMIT 1',[$job['id']])->fetch()) return null;
    $active=in_array($job['status'],['starting','processing','retry_submitting','retry_scheduled','retry_paused'],true);
    if ($active) return null;
    if (!$lastOutputRemoved && strtotime($recipe['created_at'].' UTC')>time()-GENERATION_RETRY_WINDOW) return null;
    $path=recipeInputPath($recipe['input_key']);
    query('UPDATE makelora_generation_recipes SET input_key=NULL WHERE generation_id=?',[$job['id']]);
    return $path;
}
function purgeUnusedRecipeInputs(): void {
    global $db;
    $rows=query("SELECT r.generation_id FROM makelora_generation_recipes r JOIN makelora_generations g ON g.id=r.generation_id WHERE r.input_key IS NOT NULL AND r.created_at<=DATE_SUB(UTC_TIMESTAMP(),INTERVAL 12 HOUR) AND g.status NOT IN ('starting','processing','retry_submitting','retry_scheduled','retry_paused') AND NOT EXISTS (SELECT 1 FROM makelora_outputs o WHERE o.generation_id=g.id AND o.deleted_at IS NULL)")->fetchAll();
    foreach ($rows as $row) {
        $db->beginTransaction();
        try {
            $job=query('SELECT * FROM makelora_generations WHERE id=? FOR UPDATE',[$row['generation_id']])->fetch();
            $path=$job ? cleanRecipeInputLocked($job):null;
            $db->commit();
            if ($path && is_file($path) && !unlink($path)) throw new RuntimeException('Could not remove original image.');
        } catch (Throwable $error) { if ($db->inTransaction()) $db->rollBack();throw $error; }
    }
    // A crash before inserting the recipe can leave an unreferenced private image.
    $known=[];
    foreach (query('SELECT input_key FROM makelora_generation_recipes WHERE input_key IS NOT NULL')->fetchAll() as $row) $known[$row['input_key']]=true;
    foreach (new DirectoryIterator(recipeDirectory()) as $file) {
        if (!$file->isFile() || $file->isLink() || $file->getMTime()>time()-GENERATION_RETRY_WINDOW) continue;
        $key=$file->getFilename();
        if (str_starts_with($key,'.input-')) { unlink($file->getPathname());continue; }
        if (!preg_match('/^[a-f0-9]{64}\.jpg$/D',$key)) continue;
        if (!isset($known[$key])) unlink($file->getPathname());
    }
}
