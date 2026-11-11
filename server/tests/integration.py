"""Exercise the hosted prototype. Only use a VM test service/database.
Usage: python3 server/tests/integration.py https://vm.coffeybean.com/makelora
"""
import concurrent.futures
import html
import http.cookiejar
import json
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import subprocess
import socket
socket.setdefaulttimeout(20)

base = sys.argv[1].rstrip('/')
assert base.startswith('https://'), 'HTTPS required'
cookies = http.cookiejar.CookieJar()
browser = urllib.request.build_opener(urllib.request.HTTPCookieProcessor(cookies))

def page():
    return browser.open(base + '/').read().decode()

def form(action, **fields):
    token = re.search(r'name="csrf" value="([a-f0-9]+)"', page())[1]
    return browser.open(base+'/', urllib.parse.urlencode(dict(csrf=token, action=action, **fields)).encode()).read().decode()

def invite():
    source = form('invite')
    assert 'data:image/svg+xml;base64,' in source
    return json.loads(html.unescape(re.search(r'<textarea[^>]*>(.*?)</textarea>', source)[1]))

def api(action, token=None, body=None):
    headers = {'Content-Type':'application/json'}
    if token: headers['Authorization']='Bearer '+token
    req=urllib.request.Request(base+'/api.php?action='+action, data=None if body is None else json.dumps(body).encode(), headers=headers)
    try:
        with urllib.request.urlopen(req) as response: return response.status, json.load(response)
    except urllib.error.HTTPError as response: return response.code, json.load(response)

def sql(statement, value):
    # VM config is a private test-only file; never print its contents.
    code='$c=require "/home/dev/projects/.test-config/makelora.php"; $db=new PDO($c["dsn"],$c["user"],$c["password"]); $s=$db->prepare($argv[1]); $s->execute([$argv[2]]);'
    subprocess.run(['php','-r',code,statement,value],check=True)

created=[]
try:
    assert api('status')[0]==401
    try:
        browser.open(base+'/',b'action=invite&csrf=invalid')
        raise AssertionError('Missing CSRF rejection')
    except urllib.error.HTTPError as response: assert response.code==403
    invitation=invite()
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        replies=list(pool.map(lambda _:api('redeem',body={'invitation':invitation['invitation'],'name':'Integration <device>'}),range(2)))
    assert sorted(code for code,_ in replies)==[201,410], replies
    device=next(data for code,data in replies if code==201); created.append(device['deviceID'])
    assert api('status',device['token'])[1]['status']=='pending'
    source=page(); assert 'Integration &lt;device&gt;' in source and device['confirmation'] in source
    form('approve',id=device['deviceID'])
    assert api('status',device['token'])[1]['status']=='active'
    form('revoke',id=device['deviceID'])
    assert api('status',device['token'])[0]==401
    invitation=invite()
    sql('UPDATE makelora_invites SET expires_at=DATE_SUB(UTC_TIMESTAMP(),INTERVAL 1 MINUTE) WHERE id=SHA2(?,256)',invitation['invitation'])
    assert api('redeem',body={'invitation':invitation['invitation'],'name':'Expired'})[0]==410
    invitation=invite()
    code,device=api('redeem',body={'invitation':invitation['invitation'],'name':'Pending expiry'}); assert code==201; created.append(device['deviceID'])
    sql('UPDATE makelora_devices SET expires_at=DATE_SUB(UTC_TIMESTAMP(),INTERVAL 1 MINUTE) WHERE id=?',device['deviceID'])
    form('approve',id=device['deviceID'])
    assert api('status',device['token'])[0]==410
    invitation=invite()
    code,device=api('redeem',body={'invitation':invitation['invitation'],'name':'Disconnect'}); assert code==201; created.append(device['deviceID'])
    assert api('disconnect',device['token'],{})[0]==200
    assert api('status',device['token'])[0]==401
    assert api('redeem',body={'invitation':'bad','name':'Bad'})[0]==400
    assert api('redeem',body={'invitation':'a'*64,'name':['bad']})[0]==400
    print('PASS: QR generation, CSRF, concurrent single-use redemption, approval, escaping, revocation, invitation/approval expiry, disconnect, invalid requests')
finally:
    for device_id in created: sql('DELETE FROM makelora_devices WHERE id=?',device_id)
