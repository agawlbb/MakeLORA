<?php
// Install outside the public document root. Never commit actual credentials.
return [
 'environment'=>'prototype',
 'open_management'=>true,
 'base_url'=>'https://your-test-host.example/makelora',
 'dsn'=>'mysql:host=database;dbname=makelora_test;charset=utf8mb4',
 'user'=>'makelora_test',
 'password'=>'configure-outside-git',
 // Pre-create outside ALL web roots and Git checkouts, owned by the PHP user,
 // mode 0700. Sessions and the persistent provider token use mode 0600.
 // Never serve this path. Session expiry does not remove the provider token.
 'private_session_directory'=>'/var/lib/makelora/private-sessions',
];
