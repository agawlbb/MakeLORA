"""Exercise Drive management CSRF/PKCE/state without following redirects to Google."""
import http.client
import json
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import time
import unittest
from urllib.parse import parse_qs, urlencode, urlsplit

ROOT = Path(__file__).resolve().parents[1]


class DriveOAuthTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temporary = tempfile.TemporaryDirectory(prefix='makelora-drive-oauth-')
        cls.root = Path(cls.temporary.name)
        private = cls.root / 'private'
        private.mkdir(mode=0o700)
        (cls.root / 'src').symlink_to(ROOT / 'src', target_is_directory=True)
        (cls.root / 'public').mkdir()
        cls.private = private
        with socket.socket() as sock:
            sock.bind(('127.0.0.1', 0))
            cls.port = sock.getsockname()[1]
        bootstrap = cls.root / 'bootstrap.php'
        bootstrap.write_text('''<?php
        $config=['private_session_directory'=>%s,'base_url'=>'https://fixture.invalid/MakeLORA','google_drive_client_id'=>'synthetic-client','google_drive_client_secret'=>'synthetic-secret'];
        header('Cache-Control: no-store');header('Referrer-Policy: no-referrer');
        function escape(string $s): string { return htmlspecialchars($s,ENT_QUOTES,'UTF-8'); }
        ''' % json.dumps(str(private)))
        (cls.root / 'public/drive.php').write_text((ROOT / 'public/drive.php').read_text().replace("require dirname(__DIR__).'/src/bootstrap.php';", 'require ' + json.dumps(str(bootstrap)) + ';'))
        cls.process = subprocess.Popen(['php', '-S', f'127.0.0.1:{cls.port}', '-t', str(cls.root / 'public')], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        for _ in range(100):
            try:
                with socket.create_connection(('127.0.0.1', cls.port), timeout=.1):
                    break
            except OSError:
                time.sleep(.03)
        else:
            raise RuntimeError('Local OAuth fixture did not start')

    @classmethod
    def tearDownClass(cls):
        cls.process.terminate()
        cls.process.wait(timeout=5)
        cls.temporary.cleanup()

    def request(self, path='/drive.php', body=None, cookie=''):
        # http.client never follows the authorization Location (no external calls).
        client = http.client.HTTPConnection('127.0.0.1', self.port, timeout=5)
        client.request('GET' if body is None else 'POST', path, body=None if body is None else urlencode(body), headers={'Cookie': cookie, 'Content-Type': 'application/x-www-form-urlencoded'})
        reply = client.getresponse()
        result = reply.status, dict(reply.getheaders()), reply.read().decode()
        client.close()
        return result

    def session(self):
        status, headers, page = self.request()
        self.assertEqual(status, 200)
        self.assertIn('HttpOnly', headers['Set-Cookie'])
        self.assertIn('secure', headers['Set-Cookie'].lower())
        self.assertIn('SameSite=Lax', headers['Set-Cookie'])
        return headers['Set-Cookie'].split(';')[0], re.search(r'name="csrf" value="([a-f0-9]+)"', page)[1]

    def test_connection_consent_csrf_and_pkce(self):
        cookie, csrf = self.session()
        status, _, _ = self.request(body={'action': 'connect', 'csrf': 'bad'}, cookie=cookie)
        self.assertEqual(status, 403)
        status, headers, _ = self.request(body={'action': 'connect', 'csrf': csrf}, cookie=cookie)
        self.assertEqual(status, 303)
        self.assertIn("form-action 'self' https://accounts.google.com", headers['Content-Security-Policy'])
        auth = urlsplit(headers['Location'])
        self.assertEqual(auth.netloc, 'accounts.google.com')
        params = parse_qs(auth.query)
        self.assertEqual(params['scope'], ['https://www.googleapis.com/auth/drive.readonly'])
        self.assertEqual(params['access_type'], ['offline'])
        self.assertEqual(params['code_challenge_method'], ['S256'])
        self.assertEqual(params['redirect_uri'], ['https://fixture.invalid/MakeLORA/drive.php'])
        self.assertGreaterEqual(len(params['code_challenge'][0]), 43)
        self.assertNotIn('code_verifier', params)
        self.assertNotIn('client_secret', params)
        self.assertFalse((self.private / 'google-drive.json').exists())

    def test_callback_rejects_wrong_state_and_is_single_use(self):
        cookie, csrf = self.session()
        _, headers, _ = self.request(body={'action': 'connect', 'csrf': csrf}, cookie=cookie)
        state = parse_qs(urlsplit(headers['Location']).query)['state'][0]
        _, _, page = self.request('/drive.php?' + urlencode({'state': state, 'error': 'access_denied'}), cookie=cookie)
        self.assertIn('authorization was not completed', page)
        _, _, page = self.request('/drive.php?' + urlencode({'state': state, 'error': 'access_denied'}), cookie=cookie)
        self.assertIn('Authorization expired', page)
        _, _, page = self.request('/drive.php?state=attacker&code=synthetic-code', cookie=cookie)
        self.assertIn('Authorization expired', page)
        self.assertFalse((self.private / 'google-drive.json').exists())

    def test_disconnect_is_csrf_protected_and_preserves_datasets(self):
        cookie, csrf = self.session()
        tokens = self.private / 'google-drive.json'
        tokens.write_text('{"connection":"synthetic-account"}')
        datasets = self.private / 'datasets'
        datasets.mkdir(exist_ok=True)
        (datasets / 'original-fixture').write_bytes(b'fixture')
        self.assertEqual(self.request(body={'action': 'disconnect', 'csrf': 'bad'}, cookie=cookie)[0], 403)
        self.assertTrue(tokens.exists())
        _, _, page = self.request(body={'action': 'disconnect', 'csrf': csrf}, cookie=cookie)
        self.assertIn('Drive disconnected', page)
        self.assertFalse(tokens.exists())
        self.assertTrue((datasets / 'original-fixture').exists())


if __name__ == '__main__':
    unittest.main()
