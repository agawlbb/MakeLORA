"""MakeLORA metadata/API integration against a synthetic HTTPS FileBeans service."""
import http.server
import json
from pathlib import Path
import socket
import ssl
import subprocess
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
DEVICE = 'd' * 32
TOKEN = 'b' * 64
ORIGINAL = b'original-media-bytes' * 1024

class DatasetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix='makelora-filebeans-')
        cls.root = Path(cls.temp.name)
        cls.private = cls.root / 'private'; cls.private.mkdir(mode=0o700)
        cls.state = {'locked': False, 'revision': 'a' * 64, 'jobs': {}, 'activity': 0, 'uploads': {}}
        state = cls.state
        class FileBeans(http.server.BaseHTTPRequestHandler):
            def log_message(self, *args): pass
            def respond(self, status, value):
                data = json.dumps(value).encode(); self.send_response(status); self.send_header('Content-Type', 'application/json'); self.send_header('Content-Length', str(len(data))); self.end_headers(); self.wfile.write(data)
            def do_GET(self): self.handle_api()
            def do_HEAD(self): self.handle_api()
            def do_POST(self): self.handle_api()
            def handle_api(self):
                if self.headers.get('Authorization') != 'Bearer synthetic-filebeans-token': return self.respond(403, {})
                route = urllib.parse.urlsplit(self.path)
                path = urllib.parse.parse_qs(route.query).get('path', ['/'])[0]
                if state['locked']: return self.respond(423, {'code': 'locked'})
                if route.path == '/v1/fs/resources':
                    if path == '/': return self.respond(200, {'type': 'directory', 'children': []})
                    return self.respond(200, {'name': path.rsplit('/', 1)[-1], 'path': path, 'revision': state['revision'], 'type': 'video/mp4', 'size': 123, 'vault': 'fixture-vault'})
                if route.path == '/v1/datasets/source/content':
                    query = urllib.parse.parse_qs(route.query)
                    if query['revision'][0] != state['revision']: return self.respond(409, {'code': 'source_changed'})
                    raw = ORIGINAL; status = 200
                    if self.headers.get('Range'):
                        first, last = map(int, self.headers['Range'][6:].split('-'))
                        raw = ORIGINAL[first:last+1]; status = 206
                    self.send_response(status)
                    self.send_header('Content-Type', 'video/mp4'); self.send_header('Content-Length', str(len(raw))); self.send_header('Accept-Ranges', 'bytes')
                    if status == 206: self.send_header('Content-Range', f'bytes {first}-{last}/{len(ORIGINAL)}')
                    self.end_headers()
                    if self.command != 'HEAD':
                        gate = state.get('stream_gate')
                        if gate is not None:
                            self.wfile.write(raw[:1024]); self.wfile.flush()
                            gate.wait(timeout=4)
                            self.wfile.write(raw[1024:])
                        else: self.wfile.write(raw)
                    return
                if route.path == '/v1/datasets/source/info':
                    return self.respond(200, {'duration': 10, 'width': 1920, 'height': 1080, 'caption': 'Fixture'})
                if route.path == '/v1/datasets/uploads':
                    if path in state['uploads']: return self.respond(409, {'code': 'source_changed'})
                    state['uploads'][path] = self.rfile.read(int(self.headers['Content-Length'])); return self.respond(201, {'path': path})
                if route.path == '/v1/datasets/activity':
                    state['activity'] += 1; return self.respond(200, {'active': True})
                if route.path == '/v1/datasets/jobs':
                    body = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                    key = self.headers['Idempotency-Key']; job = state['jobs'].get(key)
                    if job is None:
                        job = {'id': key, 'state': 'ready', 'request': body, 'info': {'duration': 10, 'width': 1920, 'height': 1080, 'caption': 'Fixture'}, 'result': {'source': 'fixture', 'path': '/rendered'}}
                        state['jobs'][key] = job
                    return self.respond(202, job)
                if route.path.startswith('/v1/datasets/jobs/'):
                    key = route.path.split('/')[4]; return self.respond(200, state['jobs'][key])
                if route.path == '/v1/capabilities': return self.respond(200, {'features': ['datasetMediaV1', 'datasetOriginalsV1']})
                if route.path == '/v1/fs/sources': return self.respond(200, {'scopes': [{'name': 'fixture'}, {'name': 'excluded'}]})
                return self.respond(404, {})
        cert = cls.root / 'cert.pem'; key = cls.root / 'key.pem'
        subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(key), '-out', str(cert), '-days', '1', '-subj', '/CN=localhost', '-addext', 'subjectAltName=DNS:localhost'], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        cls.fb = http.server.ThreadingHTTPServer(('127.0.0.1', 0), FileBeans)
        ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(cert, key); cls.fb.socket = ctx.wrap_socket(cls.fb.socket, server_side=True)
        cls.thread = threading.Thread(target=cls.fb.serve_forever, daemon=True); cls.thread.start()
        (cls.private / 'filebeans.json').write_text(json.dumps({'url': f'https://localhost:{cls.fb.server_port}', 'token': 'synthetic-filebeans-token', 'sources': ['fixture']}))
        with socket.socket() as sock: sock.bind(('127.0.0.1', 0)); port = sock.getsockname()[1]
        cls.base = f'http://127.0.0.1:{port}'
        router = cls.root / 'router.php'
        router.write_text('''<?php
        $config=['private_session_directory'=>%s,'base_url'=>%s,'browser_base_url'=>'https://management.fixture.invalid/MakeLORA'];
        function fail(string $m,int $c=400): never {jsonResponse(['error'=>$m],$c);}
        function jsonResponse(array $v,int $c=200): never {http_response_code($c);header('Content-Type: application/json');echo json_encode($v);exit;}
        function query(string $s,array $p=[]): object {return new class {function fetch(){return ['id'=>str_repeat('d',32),'status'=>'active'];}};}
        require %s;
        if ($_GET['action']==='dataset_media') serveDatasetMedia();
        if (($_SERVER['HTTP_AUTHORIZATION'] ?? '')!=='Bearer '.str_repeat('b',64)) fail('Unauthorized',401);
        datasetsAPI($_GET['action'],['id'=>str_repeat('d',32),'status'=>'active']);
        ''' % (json.dumps(str(cls.private)), json.dumps(cls.base), json.dumps(str(ROOT / 'src/datasets.php'))))
        cls.php = subprocess.Popen(['php', '-d', 'output_buffering=1048576', '-d', f'curl.cainfo={cert}', '-S', f'127.0.0.1:{port}', str(router)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(100):
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=.1): break
            except OSError: time.sleep(.03)
    @classmethod
    def tearDownClass(cls):
        cls.php.terminate(); cls.php.wait(timeout=5); cls.fb.shutdown(); cls.fb.server_close(); cls.temp.cleanup()
    def setUp(self): self.state['locked'] = False; self.state['revision'] = 'a' * 64
    def api(self, action, body=None, id=None, **query):
        if id: query['id'] = id
        url = self.base + '/?' + urllib.parse.urlencode({'action': action, **query})
        raw = json.dumps(body).encode() if body is not None else None
        req = urllib.request.Request(url, data=raw, headers={'Authorization': 'Bearer ' + TOKEN, 'Content-Type': 'application/json'})
        try:
            with urllib.request.urlopen(req) as r: return r.status, json.load(r)
        except urllib.error.HTTPError as e: return e.code, json.load(e)
    def prepared(self):
        status, p = self.api('dataset_create', {'name': 'Fixture', 'model': 'wan'}); self.assertEqual(status, 201)
        status, p = self.api('dataset_import', {'files': [{'id': 'a' * 32, 'source': 'fixture', 'path': '/source.mp4'}]}, id=p['id']); self.assertEqual(status, 201)
        self.assertEqual(p['clips'], [])
        self.assertIsNone(p['videos'][0]['thumbnails'])
        status, info = self.api('dataset_source_info', id=p['id'], video='a' * 32); self.assertEqual(status, 200)
        clip = {'id': 'c' * 32, 'videoID': 'a' * 32, 'start': 0, 'end': 10, 'caption': 'Fixture'}
        status, p = self.api('dataset_save', {'revision': p['revision'], 'name': p['name'], 'clips': [clip]}, id=p['id']); self.assertEqual(status, 200)
        return p
    def test_original_range_streams_before_upstream_finishes(self):
        p = self.prepared()
        gate = threading.Event()
        self.state['stream_gate'] = gate
        try:
            request = urllib.request.Request(p['videos'][0]['sourceURL'], headers={'Range': 'bytes=0-8191'})
            with urllib.request.urlopen(request, timeout=2) as response:
                self.assertEqual(response.status, 206)
                self.assertEqual(response.headers['Content-Range'], f'bytes 0-8191/{len(ORIGINAL)}')
                self.assertEqual(response.read(1024), ORIGINAL[:1024])
                self.assertFalse(gate.is_set())
                gate.set()
                self.assertEqual(response.read(), ORIGINAL[1024:8192])
        finally:
            gate.set()
            self.state.pop('stream_gate', None)

    def test_uniform_clip_duration(self):
        p = self.prepared()
        self.assertEqual(p['clipDuration'], 5)
        self.assertEqual(p['clips'][0]['end'] - p['clips'][0]['start'], 5)
        body = {'revision': p['revision'], 'name': p['name'], 'clips': p['clips'], 'clipDuration': 3}
        status, changed = self.api('dataset_save', body, id=p['id'])
        self.assertEqual(status, 200)
        self.assertEqual(changed['clips'][0]['end'] - changed['clips'][0]['start'], 3)
        body.update(revision=changed['revision'], clipDuration=60)
        status, _ = self.api('dataset_save', body, id=p['id'])
        self.assertEqual(status, 400)
        status, unchanged = self.api('dataset', id=p['id'])
        self.assertEqual(unchanged['clipDuration'], 3)

    def test_registration_and_relink_only_record_original(self):
        jobs = dict(self.state['jobs'])
        status, p = self.api('dataset_create', {'name': 'Original', 'model': 'wan'})
        status, p = self.api('dataset_import', {'files': [{'id': 'a' * 32, 'source': 'fixture', 'path': '/source.mp4'}]}, id=p['id'])
        self.assertEqual(status, 201)
        self.assertEqual(p['clips'], [])
        self.assertEqual(self.state['jobs'], jobs)
        source = p['videos'][0]
        self.assertEqual(source['status'], 'ready')
        self.assertNotIn('job', source)
        self.assertNotIn('duration', source)
        self.assertIn('kind=source', source['sourceURL'])
        status, p = self.api('dataset_relink', {'video': source['id'], 'location': {'source': 'fixture', 'path': '/other.mp4'}}, id=p['id'])
        self.assertEqual(status, 200)
        self.assertEqual(self.state['jobs'], jobs)
        self.assertTrue(p['videos'][0]['reviewRequired'])
        self.assertEqual(p['clips'], [])

    def test_original_stream_ranges_head_and_locked_access(self):
        p = self.prepared(); url = p['videos'][0]['sourceURL']
        with urllib.request.urlopen(url) as response:
            self.assertEqual(response.read(), ORIGINAL)
        with urllib.request.urlopen(urllib.request.Request(url, headers={'Range': 'bytes=2-9'})) as response:
            self.assertEqual(response.status, 206)
            self.assertEqual(response.read(), ORIGINAL[2:10])
            self.assertEqual(response.headers['Content-Range'], f'bytes 2-9/{len(ORIGINAL)}')
        with urllib.request.urlopen(urllib.request.Request(url, method='HEAD')) as response:
            self.assertEqual(int(response.headers['Content-Length']), len(ORIGINAL))
            self.assertEqual(response.read(), b'')
        self.state['locked'] = True
        with self.assertRaises(urllib.error.HTTPError) as caught: urllib.request.urlopen(url)
        self.assertEqual(caught.exception.code, 423)
        self.assertIn('FileBeans mobile app', json.load(caught.exception)['error'])
        self.state['locked'] = False; self.state['revision'] = 'c' * 64
        with self.assertRaises(urllib.error.HTTPError) as caught: urllib.request.urlopen(url)
        self.assertEqual(caught.exception.code, 409)

    def test_legacy_queued_source_becomes_reference_without_polling_prepare_job(self):
        p = self.prepared()
        manifest = self.private / 'datasets' / p['id'] / 'project.json'
        saved = json.loads(manifest.read_text())
        saved['videos']['a' * 32].update({'job': 'nonexistent-legacy-job', 'status': 'queued'})
        manifest.write_text(json.dumps(saved))
        jobs = dict(self.state['jobs']); active = self.state['activity']
        status, fresh = self.api('dataset', id=p['id'])
        self.assertEqual(status, 200)
        self.assertEqual(fresh['videos'][0]['status'], 'ready')
        self.assertNotIn('job', fresh['videos'][0])
        self.assertEqual(self.state['jobs'], jobs)
        self.assertEqual(self.state['activity'], active)
        status, _ = self.api('dataset_source_access', id=p['id'], video='a' * 32)
        self.assertEqual(status, 200)
        self.assertGreater(self.state['activity'], active)

    def test_connection_uses_configured_management_origin(self):
        status, reply = self.api('dataset_connection')
        self.assertEqual(status, 200)
        self.assertTrue(reply['connected'])
        self.assertEqual(reply['managementURL'], 'https://management.fixture.invalid/MakeLORA/filebeans.php')
    def test_metadata_only_and_render(self):
        p = self.prepared(); self.assertEqual(p['videos'][0]['duration'], 10)
        status, p = self.api('dataset_export', {'destination': {'source': 'fixture', 'path': '/'}}, id=p['id']); self.assertEqual(status, 202)
        status, p = self.api('dataset', id=p['id']); self.assertEqual(p['exportFolder'], 'fixture / /rendered')
        files = [f.name for f in (self.private / 'datasets' / p['id']).iterdir()]
        self.assertEqual(sorted(files), ['lock', 'project.json'])
    def test_locked_activity_preserves_edits(self):
        p = self.prepared(); self.state['locked'] = True
        status, error = self.api('dataset_activity', {}, id=p['id']); self.assertEqual(status, 423); self.assertEqual(error['code'], 'locked'); self.assertIn('FileBeans mobile app', error['error'])
        self.state['locked'] = False
        status, fresh = self.api('dataset', id=p['id']); self.assertEqual(fresh['clips'], p['clips'])
    def test_changed_source_requires_relink(self):
        p = self.prepared(); self.state['revision'] = 'c' * 64
        status, error = self.api('dataset_export', {'destination': {'source': 'fixture', 'path': '/'}}, id=p['id']); self.assertEqual(status, 409); self.assertEqual(error['code'], 'source_changed')
    def test_conflict_and_scope_checks(self):
        p = self.prepared()
        status, _ = self.api('dataset_save', {'revision': -1, 'name': 'Stale', 'clips': []}, id=p['id']); self.assertEqual(status, 400)
        status, _ = self.api('dataset_files', source='excluded', path='/'); self.assertEqual(status, 400)
        status, _ = self.api('dataset_files', source='fixture', path='/../private'); self.assertEqual(status, 400)
        status, reply = self.api('dataset_sources'); self.assertEqual(reply['scopes'], [{'name': 'fixture'}])
    def test_streamed_upload(self):
        raw = b'synthetic upload' * 1024
        url = self.base + '/?' + urllib.parse.urlencode({'action': 'dataset_upload', 'source': 'fixture', 'path': '/upload.mp4'})
        req = urllib.request.Request(url, data=raw, headers={'Authorization': 'Bearer ' + TOKEN, 'Content-Type': 'application/octet-stream', 'Idempotency-Key': 'a' * 64, 'X-Content-SHA256': 'b' * 64})
        with urllib.request.urlopen(req) as r: self.assertEqual(r.status, 201)
        self.assertEqual(self.state['uploads']['/upload.mp4'], raw)
        with self.assertRaises(urllib.error.HTTPError) as caught: urllib.request.urlopen(req)
        self.assertEqual(caught.exception.code, 409)
        failure = json.load(caught.exception)
        self.assertEqual(failure['code'], 'conflict')
        self.assertIn('another name or folder', failure['error'])
    def test_private_configuration_during_management_session(self):
        code = '<?php $config=["private_session_directory"=>%s]; require %s; datasetPrivateRoot(); session_start(); filebeansSettings(); session_write_close(); echo "OK";' % (json.dumps(str(self.private)), json.dumps(str(ROOT / 'src/filebeans.php')))
        result = subprocess.run(['php', '-d', 'display_errors=1'], input=code, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, 'OK')
        self.assertEqual(result.stderr, '')
    def test_delete_removes_metadata_and_keeps_filebeans(self):
        p = self.prepared(); jobs = dict(self.state['jobs'])
        status, reply = self.api('dataset_delete', {}, id=p['id'])
        self.assertEqual(status, 200); self.assertTrue(reply['deleted'])
        saved = json.loads((self.private / 'datasets' / p['id'] / 'project.json').read_text())
        self.assertEqual(saved, {'id': p['id'], 'deleted': True})
        self.assertEqual(self.state['jobs'], jobs)
        status, _ = self.api('dataset', id=p['id']); self.assertEqual(status, 400)
