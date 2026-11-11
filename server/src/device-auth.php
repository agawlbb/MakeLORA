<?php
declare(strict_types=1);
function authenticatedDevice(string $authorization): array {
    if (!preg_match('/^Bearer ([a-f0-9]{64})$/D',$authorization,$match)) fail('Device credential required.',401);
    $device=query('SELECT * FROM makelora_devices WHERE token_hash=?',[hash('sha256',$match[1])])->fetch();
    if (!$device || $device['status']==='revoked') fail('Device access revoked or unknown.',401);
    if ($device['status']==='pending' && strtotime($device['expires_at'].' UTC')<=time()) fail('Pairing approval expired.',410);
    return $device;
}
