"""Exercise Unix setgid publication as PHP UID 33 outside FileBrowser group 1000."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]

@unittest.skipUnless(os.geteuid() == 0, 'Run this isolated permission regression as root inside development/CI')
class FolderPermissionTests(unittest.TestCase):
    def test_php_user_preserves_inherited_filebrowser_group(self):
        with tempfile.TemporaryDirectory(prefix='makelora-group-test-') as temporary:
            root = Path(temporary)
            root.chmod(0o755)
            private = root / 'private'; private.mkdir(); os.chown(private, 33, 33); private.chmod(0o700)
            exports = root / 'exports'; exports.mkdir(); os.chown(exports, 33, 1000); exports.chmod(0o2750)
            fixture = root / 'check.php'
            fixture.write_text('''<?php
            $config=['private_session_directory'=>%s,'dataset_export_directory'=>%s];
            require %s;
            $stage=datasetFolderStage(str_repeat('a',32));
            $source=driveRoot().'/caption.txt';file_put_contents($source,'Synthetic caption');chmod($source,0600);
            datasetFolderFile($source,$stage.'/1.txt');
            $name=datasetPublishFolder($stage,['id'=>str_repeat('a',32),'name'=>'permissions','revision'=>1]);
            $path=datasetFolderRoot().'/'.$name.'/1.txt';
            if (filegroup($path)!==1000 || (fileperms($path)&0777)!==0660) throw new RuntimeException('Published file is not readable by the FileBrowser group.');
            echo "Group inheritance and FileBrowser file permissions passed.\\n";
            ''' % (json.dumps(str(private)), json.dumps(str(exports)), json.dumps(str(ROOT / 'src/datasets.php'))))
            def php_user():
                os.setgroups([])
                os.setgid(33)
                os.setuid(33)
            result = subprocess.run(['php', str(fixture)], preexec_fn=php_user, capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual((exports / 'permissions/1.txt').stat().st_gid, 1000)

if __name__ == '__main__':
    unittest.main()
