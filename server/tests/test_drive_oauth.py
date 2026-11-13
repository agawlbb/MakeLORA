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
        if (is_file($config['private_session_directory'].'/unconfigured')) { unset($config['google_drive_client_id'],$config['google_drive_client_secret']); }
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

    def setUp(self):
        (self.private / 'unconfigured').unlink(missing_ok=True)
        (self.private / 'google-drive-client.json').unlink(missing_ok=True)
        (self.private / 'google-drive.json').unlink(missing_ok=True)

    def request(self, path='/drive.php', body=None, cookie='', content_type='application/x-www-form-urlencoded'):
        # http.client never follows the authorization Location (no external calls).
        client = http.client.HTTPConnection('127.0.0.1', self.port, timeout=5)
        client.request('GET' if body is None else 'POST', path, body=None if body is None else (body if isinstance(body, bytes) else urlencode(body)), headers={'Cookie': cookie, 'Content-Type': content_type})
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

    def upload(self, cookie, csrf, download, replace=True):
        boundary = 'makelora-synthetic-upload-boundary'
        parts = []
        fields = {'csrf': csrf, 'action': 'save_client'}
        if replace:
            fields['replace_client'] = '1'
        for key, value in fields.items():
            parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="{key}"\r\n\r\n{value}\r\n'.encode())
        raw = download if isinstance(download, bytes) else json.dumps(download).encode()
        parts.append(f'--{boundary}\r\nContent-Disposition: form-data; name="client_json"; filename="client.json"\r\nContent-Type: application/json\r\n\r\n'.encode() + raw + b'\r\n')
        parts.append(f'--{boundary}--\r\n'.encode())
        return self.request(body=b''.join(parts), cookie=cookie, content_type='multipart/form-data; boundary=' + boundary)

    def client_download(self):
        return {'web': {'client_id': '123456-fixture.apps.googleusercontent.com', 'client_secret': 'synthetic-upload-secret', 'redirect_uris': ['https://fixture.invalid/MakeLORA/drive.php'], 'token_uri': 'https://untrusted.invalid/ignored'}}

    def test_first_client_upload_needs_no_server_configuration_or_replacement(self):
        (self.private / 'unconfigured').touch()
        cookie, csrf = self.session()
        _, _, page = self.request(cookie=cookie)
        self.assertIn('Set up your Google client', page)
        self.assertNotIn('name="replace_client"', page)
        self.assertEqual(self.upload(cookie, csrf, self.client_download(), replace=False)[0], 303)
        _, _, page = self.request(cookie=cookie)
        self.assertIn('Connect Google Drive', page)
        self.assertNotIn('synthetic-upload-secret', page)

    def test_replacing_client_invalidates_other_browsers_pending_consent(self):
        old_cookie, old_csrf = self.session()
        _, headers, _ = self.request(body={'action': 'connect', 'csrf': old_csrf}, cookie=old_cookie)
        state = parse_qs(urlsplit(headers['Location']).query)['state'][0]
        new_cookie, new_csrf = self.session()
        self.assertEqual(self.upload(new_cookie, new_csrf, self.client_download())[0], 303)
        _, _, page = self.request('/drive.php?' + urlencode({'state': state, 'code': 'synthetic-code-never-sent-to-google'}), cookie=old_cookie)
        self.assertIn('Google client settings changed', page)
        self.assertFalse((self.private / 'google-drive.json').exists())

    def test_client_upload_is_private_and_used_for_consent(self):
        cookie, csrf = self.session()
        (self.private / 'google-drive.json').write_text('{"connection":"synthetic-old-connection"}')
        status, headers, page = self.upload(cookie, csrf, self.client_download())
        self.assertEqual(status, 303)
        saved = self.private / 'google-drive-client.json'
        self.assertEqual(saved.stat().st_mode & 0o777, 0o600)
        settings = json.loads(saved.read_text())
        self.assertEqual(set(settings), {'client_id', 'client_secret'})
        self.assertFalse((self.private / 'google-drive.json').exists())
        _, _, page = self.request(cookie=cookie)
        self.assertIn('Google client saved securely', page)
        self.assertNotIn('synthetic-upload-secret', page)
        _, headers, _ = self.request(body={'action': 'connect', 'csrf': csrf}, cookie=cookie)
        self.assertEqual(parse_qs(urlsplit(headers['Location']).query)['client_id'], [settings['client_id']])
        self.assertNotIn(settings['client_secret'], headers['Location'])

    def test_client_upload_rejects_csrf_and_requires_replace_confirmation(self):
        cookie, csrf = self.session()
        self.assertEqual(self.upload(cookie, 'bad', self.client_download())[0], 403)
        self.assertFalse((self.private / 'google-drive-client.json').exists())
        self.assertEqual(self.upload(cookie, csrf, self.client_download(), replace=False)[0], 400)
        self.assertFalse((self.private / 'google-drive-client.json').exists())

    def test_client_upload_rejects_invalid_files_without_overwriting_credentials(self):
        cookie, csrf = self.session()
        self.assertEqual(self.upload(cookie, csrf, self.client_download())[0], 303)
        saved = (self.private / 'google-drive-client.json').read_bytes()
        wrong_redirect = self.client_download()
        wrong_redirect['web']['redirect_uris'] = ['https://other.invalid/drive.php']
        missing_secret = self.client_download()
        del missing_secret['web']['client_secret']
        for bad in [b'not JSON', {'installed': self.client_download()['web']}, wrong_redirect, missing_secret, b'x' * 32769]:
            with self.subTest(bad_type=type(bad).__name__):
                status, _, page = self.upload(cookie, csrf, bad)
                self.assertEqual(status, 400)
                self.assertNotIn('synthetic-upload-secret', page)
                self.assertEqual((self.private / 'google-drive-client.json').read_bytes(), saved)

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
