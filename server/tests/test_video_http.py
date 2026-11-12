"""Exercise authenticated media delivery over HTTP, using a local fake catalog only."""
import json
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[1]


class VideoHTTPTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='makelora-video-http-')
        root = Path(cls.temporary.name)
        (root / 'outputs').mkdir()
        cls.output_id = 'a' * 64
        cls.bytes = (ROOT / 'tests/fixtures/wan-output.mp4').read_bytes()
        (root / 'outputs' / (cls.output_id + '.mp4')).write_bytes(cls.bytes)
        # The router exercises the same active-device gate and delivery function as api.php.
        router = '''<?php
        $config=['private_session_directory'=>%s];
        function fail(string $message,int $code=400): never { http_response_code($code);header('Content-Type: application/json');echo json_encode(['error'=>$message]);exit; }
        function jsonResponse(array $data,int $code=200): never { http_response_code($code);echo json_encode($data);exit; }
        function query(string $sql,array $params=[]): object {
            $row=false;
            if (str_contains($sql,'makelora_devices') && ($params[0] ?? '')===hash('sha256',str_repeat('b',64))) $row=['id'=>'fixture','status'=>'active'];
            if (str_contains($sql,'makelora_outputs') && ($params[0] ?? '')===str_repeat('a',64)) $row=['id'=>str_repeat('a',64),'storage_key'=>str_repeat('a',64).'.mp4','media_type'=>'video','mime_type'=>'video/mp4'];
            return new class($row) { function __construct(private mixed $row) {} function fetch(): mixed { return $this->row; } };
        }
        require %s;
        require %s;
        header('Cache-Control: no-store');
        $device=authenticatedDevice($_SERVER['HTTP_AUTHORIZATION'] ?? '');
        generationAPI('output',$device);
        ''' % (json.dumps(str(root)), json.dumps(str(ROOT / 'src/generation.php')), json.dumps(str(ROOT / 'src/device-auth.php')))
        (root / 'router.php').write_text(router)
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            port = sock.getsockname()[1]
        cls.url = f'http://127.0.0.1:{port}/?id={cls.output_id}'
        cls.process = subprocess.Popen(['php', '-S', f'127.0.0.1:{port}', str(root / 'router.php')], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(100):
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=0.1):
                    break
            except OSError:
                time.sleep(0.03)
        else:
            cls.process.terminate()
            raise RuntimeError('Local PHP HTTP fixture did not start')

    @classmethod
    def tearDownClass(cls):
        cls.process.terminate()
        cls.process.wait(timeout=5)
        cls.temporary.cleanup()

    def request(self, byte_range=None, auth=True, method='GET'):
        headers = {'Authorization': 'Bearer ' + 'b' * 64} if auth else {}
        if byte_range is not None:
            headers['Range'] = byte_range
        request = urllib.request.Request(self.url, headers=headers, method=method)
        try:
            return urllib.request.urlopen(request, timeout=5)
        except urllib.error.HTTPError as error:
            return error

    def test_authentication_precedes_media_access(self):
        with self.request('bytes=0-9', auth=False) as reply:
            self.assertEqual(reply.status, 401)
            self.assertNotEqual(reply.read(), self.bytes[:10])

    def test_full_file_and_head(self):
        with self.request() as reply:
            self.assertEqual(reply.status, 200)
            self.assertEqual(reply.headers['Content-Type'], 'video/mp4')
            self.assertEqual(reply.headers['Accept-Ranges'], 'bytes')
            self.assertEqual(reply.read(), self.bytes)
        with self.request(method='HEAD') as reply:
            self.assertEqual(int(reply.headers['Content-Length']), len(self.bytes))
            self.assertEqual(reply.read(), b'')

    def test_partial_suffix_and_unsatisfiable_range(self):
        with self.request('bytes=10-29') as reply:
            self.assertEqual(reply.status, 206)
            self.assertEqual(reply.headers['Content-Range'], f'bytes 10-29/{len(self.bytes)}')
            self.assertEqual(reply.read(), self.bytes[10:30])
        with self.request('bytes=-10') as reply:
            self.assertEqual(reply.read(), self.bytes[-10:])
        with self.request('bytes=999999-') as reply:
            self.assertEqual(reply.status, 416)
            self.assertEqual(reply.headers['Content-Range'], f'bytes */{len(self.bytes)}')


if __name__ == '__main__':
    unittest.main()
