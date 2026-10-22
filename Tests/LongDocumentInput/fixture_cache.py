from pathlib import Path
import hashlib,json,shutil,sys,time

sources=['Sources/HanQ/JamoComposer.swift','Sources/HanQ/KoreanKeyboardLayout.swift','Sources/HanQ/KeyboardStateMirror.swift',
 'Tests/OnsetRecovery/LateLayoutCases.swift','Tests/OnsetRecovery/LateApp/PostedKeys.swift',
 'Tests/Support/OwnedInputFocus.swift','Tests/Support/OwnedInputSourceGuard.swift','Tests/Support/OwnedInputSourceControl.swift',
 'Tests/LongDocumentInput/ProductIdentity.swift','Tests/LongDocumentInput/Support.swift',
 'Tests/LongDocumentInput/AutoMain.swift','Tests/LongDocumentInput/sender.swift',
 'scripts/build-long-document-fixture.sh','Tests/LongDocumentInput/fixture_cache.py']
binaries=['LongDocument.app/Contents/MacOS/LongDocument','LongDocument.app/Contents/Info.plist','sender','source-control']
def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
mode=sys.argv[1];root=Path(sys.argv[2])
if mode=='freeze':
 (root/'fixture-source-inputs.json').write_text(json.dumps({p:sha(p) for p in sources},indent=2)+'\n')
elif mode=='create':
 frozen=json.loads((root/'fixture-source-inputs.json').read_text())
 assert frozen=={p:sha(p) for p in sources},'test sources changed during compilation; cache rejected'
 data=dict(sources=frozen,files={p:sha(root/p) for p in binaries},frozenBeforeCompile=True,compiler='Swift default unoptimized; arm64 macOS13; same test tools before/after')
 (root/'fixture-manifest.json').write_text(json.dumps(data,indent=2)+'\n')
elif mode=='copy':
 data=json.loads((root/'fixture-manifest.json').read_text())
 assert data.get('frozenBeforeCompile'),'test inputs were not frozen before compilation'
 assert all(sha(p)==h for p,h in data['sources'].items()),'stale test source cache'
 assert all(sha(root/p)==h for p,h in data['files'].items()),'changed test executable cache'
 destination=Path(sys.argv[3]);shutil.copytree(root/'LongDocument.app',destination/'LongDocument.app',symlinks=True)
 for name in ['sender','source-control','fixture-manifest.json']:shutil.copy2(root/name,destination/name)
elif mode=='wait-ready':
 end=time.monotonic()+3
 while time.monotonic()<end:
  path=root/'source-control-ready.json'
  if path.exists():
   assert json.loads(path.read_text())['ax'],'source controller needs existing AX permission'
   break
  time.sleep(.01)
 else:raise SystemExit('source controller not ready; no fixture started')
else:raise SystemExit('unknown fixture operation')
