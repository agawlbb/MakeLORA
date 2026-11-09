"""Wait for the uploaded MakeLORA build to finish Apple's processing."""
import base64
import json
import os
import subprocess
import time
import urllib.parse
import urllib.request
from pathlib import Path

def request(path, body=None):
    def b64(value):
        return base64.urlsafe_b64encode(value).decode().rstrip('=')
    now = int(time.time())
    header = b64(json.dumps({'alg': 'ES256', 'kid': os.environ['ASC_KEY_ID'], 'typ': 'JWT'}).encode())
    payload = b64(json.dumps({'iss': os.environ['ASC_ISSUER_ID'], 'iat': now, 'exp': now + 600, 'aud': 'appstoreconnect-v1'}).encode())
    signing_input = (header + '.' + payload).encode()
    signature = subprocess.run(['openssl', 'dgst', '-sha256', '-sign', os.environ['ASC_KEY_PATH']], input=signing_input, capture_output=True, check=True).stdout
    assert signature[0] == 0x30 and signature[1] < 128
    offset = 2
    parts = []
    for _ in range(2):
        assert signature[offset] == 2
        size = signature[offset + 1]
        parts.append(int.from_bytes(signature[offset+2:offset+2+size], 'big').to_bytes(32, 'big'))
        offset += size + 2
    token = header + '.' + payload + '.' + b64(b''.join(parts))
    req = urllib.request.Request('https://api.appstoreconnect.apple.com/v1/' + path, data=json.dumps(body).encode() if body else None, headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=30) as response:
        content = response.read()
        return json.loads(content) if content else {}

apps = request('apps?' + urllib.parse.urlencode({'filter[bundleId]': 'dev.makelora.app'}))['data']
assert len(apps) == 1, 'MakeLORA App Store Connect app missing or ambiguous'
app = apps[0]['id']
if os.environ.get('CHECK_BUILD_NUMBER_ONLY') == 'true':
    # Inspect uploaded builds before creating an archive or submitting anything.
    path = 'builds?' + urllib.parse.urlencode({'filter[app]': app, 'limit': 200})
    numbers = []
    while path:
        page = request(path)
        numbers.extend(int(item['attributes']['version']) for item in page['data']
                       if item['attributes']['version'].isdigit())
        next_url = page.get('links', {}).get('next')
        path = next_url.removeprefix('https://api.appstoreconnect.apple.com/v1/') if next_url else None
    highest = max(numbers, default=0)
    print('Highest uploaded build number: ' + str(highest), flush=True)
    if int(os.environ['BUILD_NUMBER']) <= highest:
        raise SystemExit('Choose build number ' + str(highest + 1) + ' or greater before uploading.')
    print('Build number ' + os.environ['BUILD_NUMBER'] + ' is available.', flush=True)
    raise SystemExit(0)

deadline = time.monotonic() + 1200
last = None
while time.monotonic() < deadline:
    builds = request('builds?' + urllib.parse.urlencode({'filter[app]': app, 'filter[version]': os.environ['BUILD_NUMBER'], 'include': 'preReleaseVersion'}))
    if builds['data']:
        assert len(builds['data']) == 1, 'Build is ambiguous'
        build = builds['data'][0]
        state = build['attributes']['processingState']
        if state != last:
            print('Apple processing: ' + state, flush=True)
            last = state
        if state in ('FAILED', 'INVALID'):
            raise SystemExit('Apple processing rejected build')
        if state == 'VALID':
            detail = request('builds/' + build['id'] + '/buildBetaDetail')['data']['attributes']
            groups = request('apps/' + app + '/betaGroups')['data']
            internal = [group for group in groups if group['attributes'].get('isInternalGroup')]
            named = [group for group in internal if group['attributes']['name'].lower() == 'internal testing']
            chosen = named if len(named) == 1 else internal
            assert len(chosen) == 1, 'Existing internal testing group missing or ambiguous'
            assigned = request('betaGroups/' + chosen[0]['id'] + '/builds?limit=200')['data']
            if not any(item['id'] == build['id'] for item in assigned):
                request('builds/' + build['id'] + '/relationships/betaGroups', {'data':[{'type':'betaGroups','id':chosen[0]['id']}]})
                assigned = request('betaGroups/' + chosen[0]['id'] + '/builds?limit=200')['data']
            assert any(item['id'] == build['id'] for item in assigned), 'Internal group assignment not confirmed'
            detail = request('builds/' + build['id'] + '/buildBetaDetail')['data']['attributes']
            result = {'build_id': build['id'], 'internal_groups': [chosen[0]['attributes']['name']], 'build': build['attributes']['version'], 'processingState': state, 'expired': build['attributes']['expired'], 'usesNonExemptEncryption': build['attributes'].get('usesNonExemptEncryption'), 'beta': detail, 'marketingVersions': [item['attributes']['version'] for item in builds.get('included', []) if item['type'] == 'preReleaseVersions']}
            print(json.dumps(result), flush=True)
            Path('build').mkdir(exist_ok=True)
            with open('build/testflight-processing.json', 'w') as output:
                json.dump(result, output, indent=2)
            break
    time.sleep(20)
else:
    raise SystemExit('Apple processing has not completed within 20 minutes')

