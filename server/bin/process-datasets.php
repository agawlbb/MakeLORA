#!/usr/bin/env php
<?php
declare(strict_types=1);
define('MAKELORA_DEVICE_API',true);
require dirname(__DIR__).'/src/bootstrap.php';
require dirname(__DIR__).'/src/dataset-worker.php';
try {
    datasetRoot();datasetFFmpeg();requireVideoTools();
    if (datasetFolderConfigured()) datasetFolderRoot();
    if (!class_exists(ZipArchive::class)) throw new RuntimeException('Install the PHP zip extension.');
    if (in_array('--check',$argv,true)) { echo "Dataset storage and video tools ready.\n";exit; }
    datasetWorker();
} catch (Throwable $e) { fwrite(STDERR,"Dataset worker failed: ".get_class($e)."\n");exit(1); }
