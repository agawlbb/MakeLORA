"""Check the real imported VM catalog and verify that model bytes are not served.
Run after importing addminus.safetensors. Uses VM test configuration only.
"""
import json
from pathlib import Path
import subprocess
import urllib.error
import urllib.request

BASE = 'https://vm.coffeybean.com/makelora'
DIGEST = 'debda67e29311ed3c710ee3b4f61aa298a372299cdbc1256e8eb8342461d17a5'
ROOT = Path(__file__).resolve().parents[2]
code = '''$c=require "/home/dev/projects/.test-config/makelora.php";
$db=new PDO($c['dsn'],$c['user'],$c['password'],[PDO::ATTR_ERRMODE=>PDO::ERRMODE_EXCEPTION]);
$s=$db->prepare('SELECT * FROM makelora_files WHERE sha256=?');
$s->execute([$argv[1]]); echo json_encode($s->fetchAll(PDO::FETCH_ASSOC),JSON_THROW_ON_ERROR);'''


def rows():
    return json.loads(subprocess.check_output(['php', '-r', code, DIGEST]))


before = rows()
assert len(before) == 1
row = before[0]
assert row['original_name'] == 'addminus.safetensors'
assert row['display_name'] == 'add minus glasses'
assert row['target_model'] == 'Qwen/Qwen-Image-Edit-2509'
assert int(row['size_bytes']) == 590058832
scan = json.loads(row['inspection_json'])
assert scan['model_family'] == 'qwen_image'
assert scan['exact_base_model'] is None
assert scan['lora_ranks'] == [32]
assert scan['tensor_count'] == 1680
assert len(json.loads(row['tensors_json'])) == 1680
stored = ROOT / 'server/storage/files' / row['storage_key']
assert stored.stat().st_mode & 0o777 == 0o600
# Reimport the stored copy: same database identity, first filename, and import time.
subprocess.run(['php', str(ROOT / 'server/bin/import-file.php'), str(stored)],
               check=True, stdout=subprocess.DEVNULL)
after = rows()
assert len(after) == 1
assert after[0]['original_name'] == row['original_name']
assert after[0]['imported_at'] == row['imported_at']
assert after[0]['target_model'] == row['target_model']
assert after[0]['display_name'] == row['display_name']
with urllib.request.urlopen(BASE + '/', timeout=30) as response:
    page = response.read().decode()
    assert 'no-store' in response.headers['Cache-Control'].split(', ')
for expected in ['addminus.safetensors', DIGEST, 'qwen_image', 'BF16',
                 'Qwen/Qwen-Image-Edit-2509', 'add minus glasses',
                 '1,680', '294,912,000']:
    assert expected in page, expected
from html.parser import HTMLParser


class CatalogMarkup(HTMLParser):
    def __init__(self):
        super().__init__()
        self.in_row = False
        self.row_text = []
        self.closed_files = 0

    def handle_starttag(self, tag, attrs):
        attrs = dict(attrs)
        if tag == 'details' and attrs.get('class') == 'file':
            assert 'open' not in attrs
            self.closed_files += 1
        if tag == 'summary' and attrs.get('class') == 'file-row':
            self.in_row = True

    def handle_endtag(self, tag):
        if tag == 'summary':
            self.in_row = False

    def handle_data(self, text):
        if self.in_row:
            self.row_text.append(text)


markup = CatalogMarkup()
markup.feed(page)
assert markup.closed_files >= 1
summary = ' '.join(markup.row_text)
assert 'add minus glasses' in summary
assert row['imported_at'][:16] in summary
assert 'Qwen-Image-Edit-2509' in summary
assert 'addminus.safetensors' not in summary
for removed in ['VM prototype', 'Downloads are not enabled', 'not proof of provenance',
                'user specified', 'not recorded in the file', 'Identification']:
    assert removed not in page, removed
assert 'href="' + row['storage_key'] not in page
for path in ['/storage/files/' + row['storage_key'],
             '/files/' + row['storage_key'], '/addminus.safetensors']:
    try:
        urllib.request.urlopen(BASE + path, timeout=30)
        raise AssertionError('Unexpected public access: ' + path)
    except urllib.error.HTTPError as response:
        assert response.code in (403, 404), (path, response.code)
print('Catalog row, tensor manifest, duplicate import, page attributes and private storage checks passed.')
