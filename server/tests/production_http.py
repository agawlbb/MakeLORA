"""Production routing/management checks with fixture sign-in and VM test DB only."""
import http.client
import re
import shutil
import socket
import subprocess
import tempfile
import time
from pathlib import Path
from urllib.parse import urlencode

source = Path(__file__).resolve().parents[1]
with tempfile.TemporaryDirectory(prefix='makelora-production-test-') as temporary, \
        tempfile.TemporaryDirectory(prefix='makelora-private-test-') as private_temporary:
    root = Path(temporary)
    app = root / 'app'
    for folder in ('src', 'public'):
        shutil.copytree(source / folder, app / folder)
    (app / 'vendor').symlink_to(source / 'vendor', target_is_directory=True)
    private = Path(private_temporary)
    auth = root / 'auth.php'
    auth.write_text('''<?php function vpsRequireUser(): array {
        if (($_COOKIE['fixture'] ?? '') !== 'authorized') {
            header('Location: /signin.php?next=/MakeLORA/', true, 302); exit;
        } return ['uid'=>'fixture-user'];
    }''')
    bootstrap = app / 'src/bootstrap.php'
    bootstrap.write_text(bootstrap.read_text().replace('/opt/vps-auth/bootstrap.php', str(auth)))
    config = root / 'settings.php'
    config.write_text("<?php $c=require '/home/dev/projects/.test-config/makelora.php'; "
                      "$c['environment']='production'; $c['open_management']=false; "
                      "$c['base_url']='https://vps.coffeybean.com/MakeLORA'; "
                      f"$c['private_session_directory']='{private}'; return $c;")
    router = root / 'router.php'
    router.write_text((source / 'deploy/gateway.php').read_text()
                      .replace('/opt/vps-auth/bootstrap.php', str(auth))
                      .replace('/run/site-private/makelora/settings.php', str(config))
                      .replace('/run/site-private/makelora/app/public/', str(app / 'public') + '/'))
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        port = sock.getsockname()[1]
    server = subprocess.Popen(['php', '-S', f'127.0.0.1:{port}', str(router)],
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def request(path='/MakeLORA/', data=None, cookie='', headers=None):
        connection = http.client.HTTPConnection('127.0.0.1', port, timeout=10)
        connection.request('GET' if data is None else 'POST', path,
                           None if data is None else urlencode(data),
                           {'Cookie': cookie, 'Content-Type': 'application/x-www-form-urlencoded', **(headers or {})})
        response = connection.getresponse()
        result = response.status, dict(response.getheaders()), response.read().decode()
        connection.close()
        return result

    try:
        for _ in range(50):
            try:
                request()
                break
            except ConnectionRefusedError:
                time.sleep(0.1)
        assert request()[0] == 302
        assert request(headers={'Remote-User': 'admin'})[0] == 302
        assert request('/MakeLORA/style.css')[0] == 302
        assert request('/MakeLORA/drive.php')[0] == 302
        assert request('/MakeLORA/api.php?action=status')[0] == 401
        for path in ('settings.php', 'vendor/autoload.php', '../private/settings.php', 'gateway.php'):
            assert request('/MakeLORA/' + path)[0] == 404
        status, headers, page = request(cookie='fixture=authorized')
        assert status == 200 and 'no-store' in headers['Cache-Control']
        assert 'browser session' not in page
        session = headers['Set-Cookie'].split(';')[0]
        cookie = 'fixture=authorized; ' + session
        csrf = re.search(r'name="csrf" value="([a-f0-9]+)"', page)[1]
        assert request(data={'csrf': 'bad', 'action': 'save_replicate', 'replicate_token': 'synthetic'}, cookie=cookie)[0] == 403
        assert request(data={'csrf': csrf, 'action': 'save_replicate', 'replicate_token': 'synthetic-private-token'}, cookie=cookie)[0] == 303
        # Fresh browser, no management session: token must remain saved.
        _, headers, page = request(cookie='fixture=authorized')
        assert 'value="remove_replicate"' in page and 'synthetic-private-token' not in page
        cookie = 'fixture=authorized; ' + headers['Set-Cookie'].split(';')[0]
        csrf = re.search(r'name="csrf" value="([a-f0-9]+)"', page)[1]
        assert request(data={'csrf': csrf, 'action': 'remove_replicate'}, cookie=cookie)[0] == 303
        assert not (private / 'replicate-token').exists()
        assert 'value="save_replicate"' in request(cookie='fixture=authorized')[2]
        print('Production HTTP checks passed: sign-in, route restrictions, device API auth, CSRF, token persistence and removal.')
    finally:
        server.terminate()
        server.wait(timeout=5)
