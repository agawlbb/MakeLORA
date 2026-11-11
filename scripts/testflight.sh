#!/bin/bash
set -euo pipefail
: "${ASC_KEY_ID:?}" "${ASC_ISSUER_ID:?}" "${ASC_KEY_PATH:?}" "${IOS_TEAM_ID:?}" "${BUILD_NUMBER:?}"
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]{0,8}$ ]]
auth=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
swift test
xcodegen generate
mkdir -p build
xcodebuild -project MakeLORA.xcodeproj -scheme MakeLORA -configuration Release \
  -jobs 2 -destination 'generic/platform=iOS' -archivePath build/MakeLORA.xcarchive \
  DEVELOPMENT_TEAM="$IOS_TEAM_ID" CODE_SIGN_STYLE=Automatic CODE_SIGNING_ALLOWED=YES \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" -allowProvisioningUpdates "${auth[@]}" archive
python3 - <<'PY'
import os, plistlib
from pathlib import Path
apps=list(Path('build/MakeLORA.xcarchive/Products/Applications').glob('*.app'))
assert len(apps)==1, 'Expected one iOS application'
info=plistlib.loads((apps[0]/'Info.plist').read_bytes())
assert info['CFBundleIdentifier']=='dev.makelora.app'
assert info['CFBundleVersion']==os.environ['BUILD_NUMBER']
assert set(info['UIDeviceFamily'])=={1,2}, 'Expected an iPhone and iPad application'
assert info['UISupportedInterfaceOrientations']==['UIInterfaceOrientationPortrait']
assert set(info['UISupportedInterfaceOrientations~ipad'])=={'UIInterfaceOrientationPortrait','UIInterfaceOrientationPortraitUpsideDown','UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight'}
Path('build/ExportOptions.plist').write_bytes(plistlib.dumps({
  'method':'app-store-connect','teamID':os.environ['IOS_TEAM_ID'],
  'signingStyle':'automatic','manageAppVersionAndBuildNumber':False,'destination':'export'}))
PY
xcodebuild -exportArchive -archivePath build/MakeLORA.xcarchive -exportPath build/signed \
  -exportOptionsPlist build/ExportOptions.plist -allowProvisioningUpdates "${auth[@]}"
python3 - <<'PY'
import os, plistlib, subprocess, tempfile, zipfile
from pathlib import Path
packages=list(Path('build/signed').glob('*.ipa'))
assert len(packages)==1, 'Expected one signed IPA'
with tempfile.TemporaryDirectory() as temp:
    with zipfile.ZipFile(packages[0]) as archive: archive.extractall(temp)
    app=next((Path(temp)/'Payload').glob('*.app'))
    subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
    signature=subprocess.run(['codesign','-d','--verbose=4',str(app)],capture_output=True,text=True,check=True).stderr
    assert 'Identifier=dev.makelora.app\n' in signature
    assert 'TeamIdentifier='+os.environ['IOS_TEAM_ID'] in signature
    entitlements=plistlib.loads(subprocess.run(['codesign','-d','--entitlements',':-',str(app)],capture_output=True,check=True).stdout)
    assert not entitlements.get('get-task-allow',False), 'Expected a distribution signature'
    assert (app/'embedded.mobileprovision').is_file()
PY
if [[ "${UPLOAD:-false}" == true ]]; then
  python3 - <<'PY'
import plistlib
from pathlib import Path
options=plistlib.loads(Path('build/ExportOptions.plist').read_bytes()); options['destination']='upload'
Path('build/UploadOptions.plist').write_bytes(plistlib.dumps(options))
PY
  xcodebuild -exportArchive -archivePath build/MakeLORA.xcarchive -exportPath build/upload \
    -exportOptionsPlist build/UploadOptions.plist -allowProvisioningUpdates "${auth[@]}"
fi
