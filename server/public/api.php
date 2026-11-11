<?php
declare(strict_types=1);
define('MAKELORA_DEVICE_API', true);
require dirname(__DIR__).'/src/bootstrap.php';
try {
    $action = $_GET['action'] ?? '';
    require_once dirname(__DIR__).'/src/generation.php';
    if ($action==='generation_webhook' && $_SERVER['REQUEST_METHOD']==='POST') generationWebhook();
    if ($action==='weights' && $_SERVER['REQUEST_METHOD']==='GET') serveWeights();
    if ($action === 'redeem' && $_SERVER['REQUEST_METHOD'] === 'POST') {
        if ((int)($_SERVER['CONTENT_LENGTH'] ?? 0) > 4096) fail('Request too large.',413);
        $raw = file_get_contents('php://input', false, null, 0, 4097);
        if (strlen($raw)>4096) fail('Request too large.',413);
        $input = json_decode($raw, true, 8, JSON_THROW_ON_ERROR);
        $invite=$input['invitation'] ?? ''; $name=trim($input['name'] ?? '');
        if (!is_string($invite) || !preg_match('/^[a-f0-9]{64}$/D',$invite) || $name==='' || mb_strlen($name)>100) fail('Invalid pairing request.');
        $db->beginTransaction();
        $row=query('SELECT * FROM makelora_invites WHERE id=? FOR UPDATE',[hash('sha256',$invite)])->fetch();
        if (!$row || $row['used_at'] || strtotime($row['expires_at'].' UTC')<=time()) { $db->rollBack(); fail('Invitation expired or already used.',410); }
        $id=bin2hex(random_bytes(16)); $token=bin2hex(random_bytes(32)); $code=str_pad((string)random_int(0,999999),6,'0',STR_PAD_LEFT);
        query("INSERT INTO makelora_devices (id,name,token_hash,confirmation,status,created_at,expires_at) VALUES (?,?,?,?,'pending',UTC_TIMESTAMP(),DATE_ADD(UTC_TIMESTAMP(), INTERVAL 5 MINUTE))",[$id,$name,hash('sha256',$token),$code]);
        query('UPDATE makelora_invites SET used_at=UTC_TIMESTAMP() WHERE id=?',[$row['id']]);
        $db->commit(); jsonResponse(['deviceID'=>$id,'token'=>$token,'confirmation'=>$code,'status'=>'pending'],201);
    }
    $auth=$_SERVER['HTTP_AUTHORIZATION'] ?? '';
    if ($auth === '') {
        foreach (getallheaders() as $key=>$value) { if (strcasecmp($key,'Authorization')===0) $auth=$value; }
    }
    require_once dirname(__DIR__).'/src/device-auth.php';
    $row=authenticatedDevice($auth);
    if ($action==='status' && $_SERVER['REQUEST_METHOD']==='GET') {
        query('UPDATE makelora_devices SET last_seen_at=UTC_TIMESTAMP() WHERE id=?',[$row['id']]);
        jsonResponse(['deviceID'=>$row['id'],'name'=>$row['name'],'status'=>$row['status'],'confirmation'=>$row['confirmation']]);
    }
    if ($action==='disconnect' && $_SERVER['REQUEST_METHOD']==='POST') {
        query("UPDATE makelora_devices SET status='revoked' WHERE id=?",[$row['id']]); jsonResponse(['status'=>'revoked']);
    }
    if (in_array($action,['models','generate','prediction','gallery','output','remove_output'],true)) generationAPI($action,$row);
    fail('Unknown operation or method.',405);
} catch (JsonException|TypeError $e) { fail('Invalid request.'); }
catch (Throwable $e) { if ($db->inTransaction()) $db->rollBack(); error_log('MakeLORA pairing failure: '.get_class($e)); fail('Pairing service unavailable.',503); }
