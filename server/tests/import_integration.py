"""VM-only: same-named files get distinct storage names; labels survive reimport."""
import hashlib
import json
import os
from pathlib import Path
import struct
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
SQL = '''$c=require "/home/dev/projects/.test-config/makelora.php";
$db=new PDO($c['dsn'],$c['user'],$c['password'],[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
$s=$db->prepare($argv[1]); $s->execute([$argv[2]]);
echo json_encode($s->fetchAll(PDO::FETCH_ASSOC),JSON_THROW_ON_ERROR);'''


def sql(statement, digest):
    return json.loads(subprocess.check_output(['php', '-r', SQL, statement, digest]))


created = []
try:
    with tempfile.TemporaryDirectory() as directory:
        keys = []
        for index in range(2):
            source = Path(directory) / str(index) / 'same-name.safetensors'
            source.parent.mkdir()
            header = json.dumps({'__metadata__': {'test_id': os.urandom(16).hex()},
                                 'w': {'dtype': 'BF16', 'shape': [1], 'data_offsets': [0, 2]}}).encode()
            content = struct.pack('<Q', len(header)) + header + b'\0\0'
            source.write_bytes(content)
            digest = hashlib.sha256(content).hexdigest()
            assert not sql('SELECT * FROM makelora_files WHERE sha256=?', digest)
            created.append(digest)
            subprocess.run(['php', str(ROOT / 'server/bin/import-file.php'), str(source),
                            'Upload ' + str(index)], check=True, stdout=subprocess.DEVNULL)
            row, = sql('SELECT * FROM makelora_files WHERE sha256=?', digest)
            assert row['display_name'] == 'Upload ' + str(index)
            assert row['original_name'] == source.name
            stored = ROOT / 'server/storage/files' / row['storage_key']
            assert stored.read_bytes() == content
            keys.append(row['storage_key'])
        assert keys[0] != keys[1]
    print('Same-named uploads stored separately with independent display names.')
finally:
    for digest in created:
        sql('DELETE FROM makelora_files WHERE sha256=?', digest)
        (ROOT / 'server/storage/files' / (digest + '.safetensors')).unlink(missing_ok=True)
