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
 // Required for Wan video validation; PHP must permit proc_open.
 // Dedicated Google OAuth web client; configure privately, never in the app.
 // Register base_url + /drive.php as its exact authorized redirect URI.
 'google_drive_client_id'=>'',
 'google_drive_client_secret'=>'',
 'ffmpeg_binary'=>'/usr/bin/ffmpeg',
 'dataset_video_limit_bytes'=>2*1024*1024*1024,
 // Scoped publication root, mapped into FileBrowser Quantum; originals stay private.
 'dataset_export_directory'=>'',
 'dataset_export_label'=>'VPS / MakeLORA datasets',
 'dataset_storage_limit_bytes'=>50*1024*1024*1024,
 'ffprobe_binary'=>'/usr/bin/ffprobe',
 'private_session_directory'=>'/var/lib/makelora/private-sessions',
];
