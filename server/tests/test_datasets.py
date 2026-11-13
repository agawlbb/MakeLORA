"""Private server datasets over HTTP and real FFmpeg rendering; no Google or paid calls."""
import hashlib
import hmac
import io
import json
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.parse
import urllib.request
import zipfile

ROOT = Path(__file__).resolve().parents[1]
TOKEN = 'b' * 64
DEVICE = 'd' * 32
VIDEO = 'a' * 32
SIGNING = 'fixture-only-signing-key'


class DatasetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='makelora-datasets-')
        cls.root = Path(cls.temporary.name)
        cls.root.chmod(0o700)
        (cls.root / 'dataset-signing-key').write_text(SIGNING)
        (cls.root / 'google-drive.json').write_text(json.dumps({'connection': 'fixture-connection'}))
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        cls.base = f'http://127.0.0.1:{port}'
        cls.router = cls.root / 'router.php'
        # Only the database authentication boundary is faked. API, locking, files, ranges,
        # worker claims, validation, FFmpeg and ZIP processing are the production functions.
        cls.bootstrap = '''<?php
        $config=['private_session_directory'=>%s,'base_url'=>%s];
        function fail(string $message,int $code=400): never { http_response_code($code);header('Content-Type: application/json');echo json_encode(['error'=>$message]);exit; }
        function jsonResponse(array $data,int $code=200): never { http_response_code($code);header('Content-Type: application/json');echo json_encode($data);exit; }
        function query(string $sql,array $params=[]): object {
            global $config;
            $row=false;
            if (!is_file($config['private_session_directory'].'/revoked')) {
                if (($params[0] ?? '')===hash('sha256',str_repeat('b',64)) || ($params[0] ?? '')===str_repeat('d',32)) $row=['id'=>str_repeat('d',32),'status'=>'active'];
            }
            return new class($row) { function __construct(private mixed $row) {} function fetch(): mixed { return $this->row; } };
        }
        require %s;
        require %s;
        ''' % (json.dumps(str(cls.root)), json.dumps(cls.base), json.dumps(str(ROOT / 'src/dataset-worker.php')), json.dumps(str(ROOT / 'src/device-auth.php')))
        cls.router.write_text(cls.bootstrap + '''
        try {
            $action=$_GET['action'] ?? '';
            if ($action==='dataset_media') serveDatasetMedia();
            $device=authenticatedDevice($_SERVER['HTTP_AUTHORIZATION'] ?? '');
            datasetsAPI($action,$device);
        } catch (Throwable $e) { fail('Fixture failed: '.$e->getMessage(),503); }
        ''')
        cls.process = subprocess.Popen(['php', '-S', f'127.0.0.1:{port}', str(cls.router)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(100):
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=0.1):
                    break
            except OSError:
                time.sleep(0.03)
        else:
            raise RuntimeError('Local PHP fixture did not start')

    @classmethod
    def tearDownClass(cls):
        cls.process.terminate()
        cls.process.wait(timeout=5)
        cls.temporary.cleanup()

    def setUp(self):
        (self.root / 'revoked').unlink(missing_ok=True)
        for path in (self.root / 'datasets').glob('*'):
            if path.is_dir():
                shutil.rmtree(path)
        self.project = self.api('dataset_create', body={'name': 'Drive fixture'})[1]
        self.directory = self.root / 'datasets' / self.project['id']

    def request(self, url, body=None, auth=True, headers=None, method=None):
        hdr = {'Authorization': 'Bearer ' + TOKEN} if auth else {}
        hdr.update(headers or {})
        if body is not None:
            hdr['Content-Type'] = 'application/json'
        request = urllib.request.Request(url, data=json.dumps(body).encode() if body is not None else None, headers=hdr, method=method)
        try:
            return urllib.request.urlopen(request, timeout=15)
        except urllib.error.HTTPError as error:
            return error

    def api(self, action, body=None, auth=True, **params):
        with self.request(self.base + '/api.php?' + urllib.parse.urlencode({'action': action, **params}), body, auth) as reply:
            return reply.status, json.load(reply)

    def ready_source(self):
        p = json.loads((self.directory / 'project.json').read_text())
        p['videos'] = {}
        p['videos'][VIDEO] = {'id': VIDEO, 'driveID': 'fixture-drive-id', 'name': 'original.mp4', 'status': 'ready', 'duration': 2.0, 'width': 320, 'height': 180, 'connection': 'fixture-connection', 'device': DEVICE}
        source = self.directory / VIDEO
        source.mkdir(exist_ok=True)
        shutil.copyfile(ROOT / 'tests/fixtures/wan-output.mp4', source / 'preview.mp4')
        (self.directory / 'project.json').write_text(json.dumps(p))
        return {'id': 'c' * 32, 'videoID': VIDEO, 'start': 0.25, 'end': 1.25, 'caption': 'A blue video.\nA second line.', 'crop': None}

    def test_device_gate_and_import_queue_duplicate_prevention(self):
        status, _ = self.api('datasets', auth=False)
        self.assertEqual(status, 401)
        for _ in range(2):
            status, p = self.api('dataset_import', id=self.project['id'], body={'files': ['drive_video']})
            self.assertEqual(status, 202)
            self.assertEqual(len(p['videos']), 1)
            self.assertEqual(p['videos'][0]['status'], 'queued')
            self.assertNotIn('connection', p['videos'][0])
            self.assertNotIn('device', p['videos'][0])
        self.assertFalse((self.directory / p['videos'][0]['id']).exists(), 'web request must only queue download')
        self.assertEqual(self.api('dataset_import', id=self.project['id'], body={'files': ['../../escape']})[0], 400)

    def test_validation_and_optimistic_concurrency(self):
        clip = self.ready_source()
        status, p = self.api('dataset_save', id=self.project['id'], body={'name': 'Edited', 'revision': 0, 'clips': [clip]})
        self.assertEqual(status, 200)
        self.assertEqual(p['revision'], 1)
        self.assertEqual(p['clips'][0]['caption'], clip['caption'])
        self.assertEqual(self.api('dataset_save', id=p['id'], body={'name': 'Stale', 'revision': 0, 'clips': []})[0], 400)
        invalid = [dict(clip, start=-1), dict(clip, end=2.1), dict(clip, start=1.24), dict(clip, crop={'x': .9, 'y': 0, 'width': .5, 'height': 1}), dict(clip, videoID='f' * 32)]
        for bad in invalid:
            with self.subTest(bad=bad):
                self.assertEqual(self.api('dataset_save', id=p['id'], body={'name': 'Bad', 'revision': 1, 'clips': [bad]})[0], 400)
        self.assertEqual(self.api('dataset', id=p['id'])[1]['name'], 'Edited')

    def test_scoped_streaming_ranges_expiry_and_revocation(self):
        self.ready_source()
        _, p = self.api('dataset', id=self.project['id'])
        url = p['videos'][0]['previewURL']
        expected = (ROOT / 'tests/fixtures/wan-output.mp4').read_bytes()
        with self.request(url, auth=False, headers={'Range': 'bytes=10-29'}) as reply:
            self.assertEqual(reply.status, 206)
            self.assertEqual(reply.headers['Accept-Ranges'], 'bytes')
            self.assertEqual(reply.read(), expected[10:30])
        with self.request(url, auth=False, method='HEAD') as reply:
            self.assertEqual(int(reply.headers['Content-Length']), len(expected))
            self.assertEqual(reply.read(), b'')
        with self.request(url.replace('kind=preview', 'kind=export'), auth=False) as reply:
            self.assertEqual(reply.status, 401)
        with self.request(url, auth=False, headers={'Range': 'bytes=9999999-'}) as reply:
            self.assertEqual(reply.status, 416)
        params = dict(urllib.parse.parse_qsl(urllib.parse.urlsplit(url).query))
        params['expires'] = str(int(time.time()) - 1)
        params['signature'] = hmac.new(SIGNING.encode(), '|'.join(params[k] for k in ['action', 'project', 'video', 'kind', 'device', 'expires']).encode(), hashlib.sha256).hexdigest()
        with self.request(self.base + '/?' + urllib.parse.urlencode(params), auth=False) as reply:
            self.assertEqual(reply.status, 401)
        (self.root / 'revoked').touch()
        with self.request(url, auth=False) as reply:
            self.assertEqual(reply.status, 401)

    @unittest.skipUnless(shutil.which('ffmpeg') and shutil.which('ffprobe'), 'real FFmpeg required')
    def test_worker_renders_trim_crop_short_side_480_and_flat_zip(self):
        clip = self.ready_source()
        source = self.directory / VIDEO / 'original'
        subprocess.run(['ffmpeg', '-v', 'error', '-f', 'lavfi', '-i', 'color=red:size=320x180:rate=24:duration=0.5', '-f', 'lavfi', '-i', 'color=green:size=320x180:rate=24:duration=0.5', '-f', 'lavfi', '-i', 'color=blue:size=320x180:rate=24:duration=1', '-filter_complex', '[0:v][1:v][2:v]concat=n=3:v=1:a=0[out]', '-map', '[out]', '-c:v', 'libx264', '-pix_fmt', 'yuv420p', str(source) + '.mp4'], check=True)
        clip['start'], clip['end'] = .75, 1.75
        Path(str(source) + '.mp4').rename(source)
        clip['crop'] = {'x': .25, 'y': 0, 'width': .5, 'height': 1}
        _, p = self.api('dataset_save', id=self.project['id'], body={'name': 'Rendered', 'revision': 0, 'clips': [clip]})
        self.assertEqual(self.api('dataset_export', id=p['id'], body={})[0], 202)
        worker = self.root / 'worker.php'
        worker.write_text(self.bootstrap + 'datasetWorker();')
        subprocess.run(['php', str(worker)], check=True, timeout=60)
        _, p = self.api('dataset', id=p['id'])
        self.assertEqual(p['exportStatus'], 'ready', p.get('exportError'))
        with self.request(p['exportURL'], auth=False) as reply:
            zipped = zipfile.ZipFile(io.BytesIO(reply.read()))
        self.assertEqual(zipped.namelist(), ['1.mp4', '1.txt'])
        self.assertEqual(zipped.read('1.txt').decode(), clip['caption'])
        output = self.root / 'export.mp4'
        output.write_bytes(zipped.read('1.mp4'))
        probe = json.loads(subprocess.check_output(['ffprobe', '-v', 'error', '-show_streams', '-show_format', '-of', 'json', str(output)]))
        stream = probe['streams'][0]
        self.assertEqual(min(stream['width'], stream['height']), 480)
        self.assertAlmostEqual(stream['width'] / stream['height'], 160 / 180, delta=.01)
        self.assertAlmostEqual(float(probe['format']['duration']), 1.0, delta=.06)
        self.assertEqual(len(probe['streams']), 1)
        first = subprocess.check_output(['ffmpeg', '-v', 'error', '-i', str(output), '-frames:v', '1', '-vf', 'scale=1:1', '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-'])
        self.assertGreater(first[1], first[0] + 50, 'first exported frame must start in green source segment')
        self.assertGreater(first[1], first[2] + 50)
        self.assertEqual(self.api('dataset_save', id=p['id'], body={'name': 'Edited again', 'revision': p['revision'], 'clips': [clip]})[0], 200)
        with self.request(p['exportURL'], auth=False) as reply:
            self.assertEqual(reply.status, 404, 'changed dataset must invalidate previous export URL')

    def test_delete_invalidates_preview_and_busy_delete_is_rejected(self):
        self.ready_source()
        _, p = self.api('dataset', id=self.project['id'])
        url = p['videos'][0]['previewURL']
        internal = json.loads((self.directory / 'project.json').read_text())
        internal['videos'][VIDEO]['status'] = 'processing'
        (self.directory / 'project.json').write_text(json.dumps(internal))
        self.assertEqual(self.api('dataset_delete', id=p['id'], body={})[0], 400)
        internal['videos'][VIDEO]['status'] = 'ready'
        (self.directory / 'project.json').write_text(json.dumps(internal))
        self.assertEqual(self.api('dataset_delete', id=p['id'], body={})[0], 200)
        with self.request(url, auth=False) as reply:
            self.assertEqual(reply.status, 404)
        self.assertFalse(self.directory.exists())


if __name__ == '__main__':
    unittest.main()
