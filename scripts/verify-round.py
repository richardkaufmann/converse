#!/usr/bin/env python3
"""Verify built production/demo pairs share release/content but not identity."""
import hashlib,json,plistlib,sys,subprocess,tempfile,shutil
from pathlib import Path
root=Path(__file__).resolve().parents[1]
v=json.loads((root/'VERSION.json').read_text())
folder=Path(sys.argv[1]) if len(sys.argv)>1 else root/'.build'/('round'+str(v['build']))
def plist(p):return plistlib.loads(p.read_bytes())
def digest(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def version(p):
 assert p['CFBundleShortVersionString']==v['version'] and p['CFBundleVersion']==str(v['build'])
def pair(a,b,aid,bid,info,executable,helpfile):
 pa,pb=plist(a/info),plist(b/info)
 version(pa);version(pb)
 assert pa['CFBundleIdentifier']==aid and pb['CFBundleIdentifier']==bid
 assert not pa.get('ConverseDemo') and pb.get('ConverseDemo') is True
 assert pb['CFBundleDisplayName']=='Converse Demo'
 assert digest(a/helpfile)==digest(b/helpfile), 'Help differs'
 if executable:
  # Signing a different bundle ID changes the Mach-O signature, not its code.
  with tempfile.TemporaryDirectory() as temporary:
   copies=[]
   for n,source in enumerate((a/executable,b/executable)):
    target=Path(temporary)/str(n);shutil.copy2(source,target)
    subprocess.run(['codesign','--remove-signature',str(target)],check=True,capture_output=True)
    copies.append(digest(target))
   assert copies[0]==copies[1],'Mac executable code differs'
 print('PASS paired release, Help and distinct identities:',a.name,b.name)
if (folder/'Converse.app').exists():
 pair(folder/'Converse.app',folder/'Converse Demo.app','local.richard.Converse','local.richard.Converse.Demo',Path('Contents/Info.plist'),Path('Contents/MacOS/Converse'),Path('Contents/Resources/Help/Content.json'))
if (folder/'iOS-production.xcarchive').exists():
 pair(folder/'iOS-production.xcarchive/Products/Applications/Converse.app',folder/'iOS-demo.xcarchive/Products/Applications/Converse.app','app.kaoslabs.Converse.iPad','app.kaoslabs.Converse.Demo',Path('Info.plist'),None,Path('Help/Content.json'))
 for edition in ('production','demo'):
  assert plist(folder/f'iOS-{edition}.xcarchive/Products/Applications/Converse.app/Info.plist')['UIDeviceFamily']==[1,2]
 print('PASS both mobile editions support iPhone and iPad')
for rid in ('linux-x64','linux-arm64'):
 if (folder/rid).exists():
  assert digest(folder/rid/'converse')==digest(folder/(rid+'-demo')/'converse')
  assert json.loads((folder/rid/'VERSION.json').read_text())==v
  assert (folder/(rid+'-demo')/'converse-demo').is_file()
  print('PASS Linux pair:',rid)
