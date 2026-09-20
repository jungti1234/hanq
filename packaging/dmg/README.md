# DMG 디자인

현재 렌더러는 승인된 디자인이다. 상단 소개 두 줄은 일반 굵기로 표시하고, 중앙 설치 안내는 21pt로 표시한다.

Finder 배경 참조는 Foundation의 기본 북마크로 생성한다. 합성 북마크가 마운트 후 해석되지 않는 문제를 피하며, HFS+ 이미지 안에 배경과 보기 설정을 포함한다.

기존 한Q 로고와 파란색 계열 배경, 설치 방향 화살표, 권한 안내를 Finder 아이콘 보기에 배치한다. 버전·빌드 번호는 입력 앱의 Info.plist에서 읽는다. 배경은 720×480pt, 2배 해상도 TIFF로 생성한다.

```sh
python3 -m pip install --target .build/dmg-design-tools -r packaging/dmg/requirements.txt
python3 scripts/prepare-designed-dmg.py
```

기본 입력은 `build/candidate/HanQ.app`, 출력은 `dist/dmg-design/`이다. 출력 폴더가 이미 있으면 `--output`으로 새로운 폴더를 지정한다. 기존 산출물은 덮어쓰지 않는다. AppKit과 dmgbuild를 사용하며 Finder UI 자동화 없이 배경·창 크기·아이콘 위치를 저장한다.

앱 번들은 수정하거나 재서명하지 않는다. 이 명령은 별도 디자인 산출물 생성용이며 Sparkle 서명·GitHub 업로드·운영 피드 반영은 하지 않는다. 정식 배포 준비 명령 `python3 scripts/release.py prepare`도 같은 디자인 생성기를 사용하며, 새 DMG의 마운트·앱 무결성·Sparkle 서명·체크섬을 검증한다. 이전 DMG의 업데이트 서명을 재사용하면 안 된다.
