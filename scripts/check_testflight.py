"""Wait for the uploaded MakeLORA build to finish Apple's processing."""
import base64
import json
import os
import subprocess
import time
import urllib.parse
import urllib.error
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
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            content = response.read()
            return json.loads(content) if content else {}
    except urllib.error.HTTPError as error:
        try:
            errors = json.loads(error.read()).get('errors', [])
            details = '; '.join(item.get('code', '') + ': ' + item.get('detail', item.get('title', '')) for item in errors)
        except (ValueError, TypeError):
            details = 'Apple returned an unreadable error response.'
        raise SystemExit('App Store Connect operation failed (HTTP ' + str(error.code) + '): ' + details) from None

def all_items(path):
    result = []
    while path:
        page = request(path)
        result.extend(page['data'])
        next_url = page.get('links', {}).get('next')
        path = next_url.removeprefix('https://api.appstoreconnect.apple.com/v1/') if next_url else None
    return result


def sole_tester_group(app, require_tester=True):
    email = os.environ['TESTFLIGHT_TESTER_EMAIL'].strip().casefold()
    if not email or '@' not in email:
        raise SystemExit('Set TESTFLIGHT_TESTER_EMAIL to the intended sole tester before releasing.')
    groups = all_items('apps/' + app + '/betaGroups?limit=200')
    for group in groups:
        if group['attributes'].get('publicLinkEnabled'):
            raise SystemExit('Disable public TestFlight links for this app before releasing to the sole tester.')
        testers = all_items('betaGroups/' + group['id'] + '/betaTesters?limit=200')
        if any(t['attributes']['email'].casefold() != email for t in testers):
            raise SystemExit("Remove other testers from this app's TestFlight groups before releasing. Other apps must remain unchanged.")
    internal = [g for g in groups if g['attributes'].get('isInternalGroup')]
    named = [g for g in internal if g['attributes']['name'].casefold() == 'internal testing']
    chosen = named if len(named) == 1 else internal
    if not chosen:
        group = request('betaGroups', {'data': {'type': 'betaGroups', 'attributes': {
            'name': 'Internal Testing', 'isInternalGroup': True, 'publicLinkEnabled': False,
        }, 'relationships': {'app': {'data': {'type': 'apps', 'id': app}}}}})['data']
    else:
        if len(chosen) != 1:
            raise SystemExit('Choose a single internal testing group for this app.')
        group = chosen[0]
    path = 'betaGroups/' + group['id'] + '/betaTesters?limit=200'
    testers = all_items(path)
    if not testers and not require_tester:
        print('Private internal group is empty; add the intended sole tester in App Store Connect before distribution.', flush=True)
        return group
    if len(testers) != 1 or testers[0]['attributes']['email'].casefold() != email:
        raise SystemExit('In App Store Connect, open this app → TestFlight → Internal Testing → Internal Testing and add only the intended tester. Internal tester assignment must be completed in the website.')
    print('Verified a private internal group with exactly the intended sole tester.', flush=True)
    return group


def main():
    apps = request('apps?' + urllib.parse.urlencode({'filter[bundleId]': 'dev.makelora.app'}))['data']
    if not apps:
        raise SystemExit('No accessible App Store Connect app record for dev.makelora.app. Create the iOS app MakeLORA at https://appstoreconnect.apple.com/apps with bundle ID dev.makelora.app and SKU MakeLORA, grant the intended tester app access, then rerun this workflow. Apple requires the website for creating app records.')
    if len(apps) != 1:
        raise SystemExit('App Store Connect returned ambiguous app records for dev.makelora.app. Resolve the duplicate records before releasing.')
    app = apps[0]['id']
    group = sole_tester_group(app, require_tester=False)
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
                group = sole_tester_group(app, require_tester=False)
                testers = all_items('betaGroups/' + group['id'] + '/betaTesters?limit=200')
                if not testers:
                    print('Build processed; waiting for the intended tester to be added to the internal group in App Store Connect.', flush=True)
                    time.sleep(20)
                    continue
                group = sole_tester_group(app)
                detail = request('builds/' + build['id'] + '/buildBetaDetail')['data']['attributes']
                assigned = request('betaGroups/' + group['id'] + '/builds?limit=200')['data']
                if not any(item['id'] == build['id'] for item in assigned):
                    request('builds/' + build['id'] + '/relationships/betaGroups', {'data':[{'type':'betaGroups','id':group['id']}]})
                    assigned = request('betaGroups/' + group['id'] + '/builds?limit=200')['data']
                assert any(item['id'] == build['id'] for item in assigned), 'Internal group assignment not confirmed'
                email = os.environ['TESTFLIGHT_TESTER_EMAIL'].strip().casefold()
                recipients = all_items('builds/' + build['id'] + '/individualTesters?limit=200')
                for assigned_group in all_items('builds/' + build['id'] + '/betaGroups?limit=200'):
                    if assigned_group['attributes'].get('publicLinkEnabled'):
                        raise SystemExit('The uploaded build has an unintended public testing link.')
                    recipients.extend(all_items('betaGroups/' + assigned_group['id'] + '/betaTesters?limit=200'))
                if not recipients or any(t['attributes']['email'].casefold() != email for t in recipients):
                    raise SystemExit('Uploaded build tester access does not match the sole intended tester.')
                detail = request('builds/' + build['id'] + '/buildBetaDetail')['data']['attributes']
                result = {'verified_sole_tester': True, 'build_id': build['id'], 'internal_groups': [group['attributes']['name']], 'build': build['attributes']['version'], 'processingState': state, 'expired': build['attributes']['expired'], 'usesNonExemptEncryption': build['attributes'].get('usesNonExemptEncryption'), 'beta': detail, 'marketingVersions': [item['attributes']['version'] for item in builds.get('included', []) if item['type'] == 'preReleaseVersions']}
                print(json.dumps(result), flush=True)
                Path('build').mkdir(exist_ok=True)
                with open('build/testflight-processing.json', 'w') as output:
                    json.dump(result, output, indent=2)
                break
        time.sleep(20)
    else:
        raise SystemExit('Apple processing has not completed within 20 minutes')


if __name__ == '__main__':
    main()
