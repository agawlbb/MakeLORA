<?php
// Install outside the public document root. Never commit actual credentials.
return [
 'environment'=>'prototype',
 'open_management'=>true,
 'base_url'=>'https://your-test-host.example/makelora',
 'dsn'=>'mysql:host=database;dbname=makelora_test;charset=utf8mb4',
 'user'=>'makelora_test',
 'password'=>'configure-outside-git',
];
