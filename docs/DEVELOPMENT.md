# 한Q 개발 및 유지보수 안내

직접 빌드하고 코드를 수정하는 개발자를 위한 안내다. 제품 소개·설치·사용법·지원 환경은 [README](../README.md), 이용 조건은 [LICENSE](../LICENSE)를 참고한다.

## 로컬 빌드

macOS에서 Swift 컴파일러를 포함한 Xcode Command Line Tools가 필요하다. 실행 중인 한Q를 종료한 뒤 프로젝트 루트에서 실행한다.

```sh
bash scripts/build-app.sh
open build/HanQ.app
```

[빌드 스크립트](../scripts/build-app.sh)는 컴파일, 자동 검사, plist·ad-hoc 서명 검증을 마친 뒤 `build/HanQ.app`을 생성한다. 기존 앱이 있으면 `.build/hanq/backups/`에 보관하고 교체하며, 실행 중인 앱은 교체하지 않는다. 서명이 바뀌면 손쉬운 사용 권한 재등록이 필요할 수 있다.

앱 버전은 `version.env`에서 읽으며 변경 규칙은 [버전 관리](VERSIONING.md)를 따른다. 작업자는 AI를 포함해 별도 요청 없이 변경 내용·공개 상태에 맞는 버전과 변경 이력을 갱신한다. 문서 수정이나 동일 입력의 재빌드만으로 번호를 올리지 않는다. 배포 대상·번들 ID는 빌드 스크립트에서 관리하고 컴파일 아키텍처는 arm64로 고정한다. 기존 설치를 업데이트할 때는 번들 ID와 앱 경로를 유지하고 사용자 설정이 보존되는지 확인한다.

### 별도 후보 빌드와 업데이트 의존성

`bash scripts/build-app.sh --candidate`는 `build/candidate/HanQ.app`을 생성한다. 기존 `build/HanQ.app`은 계속 실행할 수 있으며 후보 앱 자체가 실행 중이면 교체하지 않는다. 실제 입력 검증은 기존 앱을 종료한 뒤 같은 설치 경로에서 수행한다. 후보 생성과 실제 실행 검증은 구분한다.

Sparkle 2.10.0 공식 아카이브와 SHA-256은 `scripts/prepare-sparkle.sh`에 고정한다. 최초 빌드에는 네트워크가 필요하고 이후 검증된 로컬 아카이브를 사용한다. 프레임워크의 심볼릭 링크·서명과 라이선스를 보존해 앱에 포함한다. 공개 업데이트 주소·검증키는 `updates/config.json`에 있으며 개인키는 포함하지 않는다.

`bash scripts/test-update-policy.sh`는 정책 서명·경계·만료·적용 범위와 네트워크 실패·정책 철회의 기능 복귀 결정을 검사한다. `test-lifecycle.sh`는 제한 시 입력 해제·재활성화 방지·설정 보존도 확인한다. 실서버 조회는 `bash scripts/test-update-network.sh`로 별도 확인한다. `bash scripts/test-update-integration.sh`는 별도 번들에서 실제 안내창·AppDelegate 제한·오프라인 복귀·서명된 정책 철회를 함께 검사한다. `--interactive`는 재확인 버튼을 직접 확인할 때 사용한다. 운영 정책·실제 한Q 설정·전역 입력 탭은 변경하지 않는다.

실제 Sparkle 설치 검증용 별도 앱은 `Tests/UpdateEndToEnd/`와 `scripts/prepare-update-e2e.sh`에 있다. `.build/hanq/update-e2e/server`를 만든 뒤 `python3 Tests/UpdateEndToEnd/server.py .build/hanq/update-e2e`를 별도 터미널에서 실행하고 준비 스크립트를 실행한다. 서버는 127.0.0.1에만 바인딩한다. `installed/HanQ Update E2E.app`에서 테스트 업데이트를 실행해 설치·재실행 후 `result.json`의 빌드 2·설정 유지·동일 경로를 확인한다. 잘못된 서명과 취소 경로도 확인한다. 테스트 전용 HTTP 허용·번들 ID·임시 키는 해당 테스트 앱에만 포함된다. 종료 후 앱·서버를 닫고 `test-signing.key`를 삭제한다. 재실행할 때는 이전 테스트 디렉터리를 옮겨 새 환경을 만든다.

필수 정책과 설치를 연결하는 검증은 `.build/hanq/update-required-e2e/server`를 만들고 같은 서버 스크립트에 `.build/hanq/update-required-e2e`를 전달한 뒤 `bash scripts/prepare-update-e2e.sh --required`로 준비한다. 별도 번들 `taek.in.hanq.required-tests`에서 동일하게 서명된 최소 빌드 2 정책을 유지하며 빌드 1의 제한 안내 → Sparkle 설치·재실행 → 빌드 2의 제한 해제를 확인한다. `result.json`의 `policyChecked`, `restricted`, 빌드·설정 유지 값을 검사한다. 정책 GET과 다운로드 가능 여부 HEAD는 테스트 응답이며, 실제 운영 HTTPS 정책 조회나 키 입력 중단·복귀를 대신하지 않는다. 종료 후 해당 서버와 테스트 앱을 종료하고 임시 `test-signing.key`를 삭제한다.

이 검사는 한Q 배포본의 손쉬운 사용 권한 유지나 최초 다운로드 Gatekeeper 검증을 대신하지 않는다.

### 수동 테스트 창을 포함한 개발 빌드

일반 빌드는 수동 테스트 창을 포함하지 않는다. 개발용 검증이 필요하면 한Q를 종료한 뒤 `bash scripts/build-app.sh --development`로 빌드한다. 기존과 같은 `build/HanQ.app`을 백업·교체하므로 개발 빌드를 배포 파일로 사용하지 않는다.

`bash scripts/test-development-build.sh`로 앱 초기화 없이 일반·개발 모드의 테스트 액션 포함 여부를 실행 검증할 수 있다.

개발 빌드에서만 다음 실행 옵션을 사용할 수 있다. 앱이 이미 실행 중이면 먼저 종료한다.

```sh
open build/HanQ.app --args --test-jamo-panel
# 또는
open build/HanQ.app --args --test-hanja-panel
```

테스트 창은 Edge의 자모 변환과 TextEdit의 한자 처리를 수동으로 확인하는 도구다. 실제 우측 키 입력 검증을 대신하지 않는다. 창·버튼·지연 실행 코드는 `DevelopmentTestPanels.swift`에 있으며 `HANQ_DEVELOPMENT` 조건에서만 컴파일한다.

## 코드 구조

| 위치 | 역할 |
| --- | --- |
| [main.swift](../Sources/HanQ/main.swift) | 앱 수명, 메뉴·권한 안내, 이벤트 탭 및 기능 연결 |
| [CommandFilter.swift](../Sources/HanQ/CommandFilter.swift), [InputSourceObserver.swift](../Sources/HanQ/InputSourceObserver.swift) | 키 이벤트 처리와 입력 소스 관찰 |
| [JamoComposer.swift](../Sources/HanQ/JamoComposer.swift), [KoreanKeyboardLayout.swift](../Sources/HanQ/KoreanKeyboardLayout.swift) | 자모·음절 조합, 배열별 영타 변환, 시스템 자판 자료 로딩 및 텍스트 범위 계산 |
| [JamoRepair.swift](../Sources/HanQ/JamoRepair.swift), [HanjaReplacement.swift](../Sources/HanQ/HanjaReplacement.swift) | 접근성 API(AX) 기반 편집, 한자 호출 및 원문 중복 보정 |
| [RomanSwitchController.swift](../Sources/HanQ/RomanSwitchController.swift) | Caps Lock 전환 설정의 비공개 HIToolbox API 격리 |
| [FreshPermissionMonitor.swift](../Sources/HanQ/FreshPermissionMonitor.swift), [InputSafetyWatchdog.swift](../Sources/HanQ/InputSafetyWatchdog.swift), [PermissionRecovery.swift](../Sources/HanQ/PermissionRecovery.swift) | 권한 감시, 응답 중단 방어, 권한 상실 후 재실행 |
| [HUDController.swift](../Sources/HanQ/HUDController.swift) | 입력 소스 이름 표시 |
| [FeedbackForm.swift](../Sources/HanQ/FeedbackForm.swift) | 피드백 폼 주소·필드 ID 및 자동 입력값 구성 |
| [AppUpdater.swift](../Sources/HanQ/AppUpdater.swift), [UpdatePolicy.swift](../Sources/HanQ/UpdatePolicy.swift), [UpdatePolicyClient.swift](../Sources/HanQ/UpdatePolicyClient.swift) | 업데이트 메뉴·Sparkle 연결·서명 정책 판정과 조회 |
| [InputDiagnostics.swift](../Sources/HanQ/InputDiagnostics.swift) | 입력 진단 |
| [Tests/](../Tests/), [scripts/](../scripts/) | 자동 검사와 빌드·진단 도구 |

InputFocusAccess는 첫 자음·입력 불일치 보정에서 실제 키보드 포커스 소유 프로세스와 입력칸을 선택한다. `bash scripts/test-input-focus.sh`로 비활성 패널·뒤쪽 앱의 오래된 포커스·일시 조회 실패·소유 프로세스 변경을 검사한다.

InputSourceAccess는 현재 입력 소스 ID 조회와 지정 ID 선택만 담당한다. 한Q 한영키는 SelectionPreservingSourceSwitch를 통해 실제 커서 이동으로 조합을 확정하고 전환 전후 명시적 선택을 보존한다. AX 범위 변경만으로 조합이 해제됐다고 가정하지 않는다. `bash scripts/test-selection-source-switch.sh`는 전체·부분 UTF-16 범위, 포커스·본문·선택·소스 변경, 권한·AX 실패·기한 초과 시 처리와 중복 전환 요청 방지를 검사한다. 전환 대상·배열 대체 정책은 각 호출부에 유지한다. PhysicalLetterKeys는 첫 자음·불일치 복구에서 사용하는 영문 물리 키 표를 공유한다.

[Resources/](../Resources/)에는 앱 아이콘 원본(`HanQ.icon`)과 번들 아이콘(`HanQ.icns`), 메뉴바 템플릿 이미지(`HanQ-MenuBar-Template.pdf`), 로고 원본(`HanQ-Logo.svg`)과 앱에서 사용하는 이미지(`HanQ-Logo.png`)가 있다.

빌드에는 실행용 ICNS·메뉴 PDF·로고 PNG만 복사한다. HanQ.icon과 HanQ-Logo.svg 편집 원본은 저장소에 유지하며 앱 번들에는 포함하지 않는다.

### 외부 키보드 설정 검증

`bash scripts/test-external-keyboards.sh`는 임시 UserDefaults와 합성 이벤트로 기기 식별·설정 보존·두 키 등록·반복·놓음·기기 분리·다른 키보드 modifier 보존을 검사한다. `--inventory`는 실제 IORegistry에서 읽은 키보드 서비스 개수만 출력한다. `--ui`는 별도 테스트 프로세스에서 실제 설정 창을 열고 저장·취소·분리 경로를 확인하며 `.build/hanq/external-keyboard-setup.png`를 생성한다. 전역 이벤트 탭과 실제 한Q 설정은 사용하지 않는다.

구현은 `ExternalKeyboardModel.swift`(식별·설정·키 상태), `ExternalKeyboardDevices.swift`(읽기 전용 기기 알림·비공개 이벤트 기기 필드), `ExternalKeyboardController.swift`(확인 흐름·기기별 처리), `ExternalKeyboardSetupView.swift`(확인 창 레이아웃)에 나뉜다. Quartz 비공개 필드 87의 값은 현재 키보드 서비스 목록과 정확히 일치할 때만 사용한다. 필드의 지속 지원이나 실제 키보드 입력과의 연결은 자동 검사로 보증하지 않는다.

실물에서는 USB/Bluetooth 최초 연결·기연결 시작·다시 연결·앱 재시작·내장/외장 번갈아 입력·포커스 변경·물리 한영/한자키·동일 모델 두 대·외부 매핑 앱·잠자기·보안 입력을 확인한다. 일련번호가 없는 기기의 포트 변경과 연결 방식 변경은 새 기기 등록이 필요할 수 있다. 연결 위치마저 없는 기기는 재연결 시 다시 등록한다.

## 수정 시 주의할 점

### 권한과 프로세스 수명

권한 감시·watchdog·재실행을 수정할 때는 [권한과 프로세스 수명 명세](SPEC.md#권한과-프로세스-수명)를 기준으로 다음을 검증한다.

- 권한 없는 인스턴스와 검사·재실행용 보조 프로세스가 입력을 가로채지 않는지.
- 탭 해제 시 눌린 키 상태와 대기 작업이 정리되고 UI 중복 실행이 차단되는지.
- 확인된 권한 거부에만 한 번 재실행하며, 사용자 종료·검사 오류·시간 초과에는 재실행하거나 반복 재시작하지 않는지.

### 텍스트 편집

자판 배열 선택과 두벌식 대체 조건은 [선택 영타 변환 명세](SPEC.md#선택-영타-변환)를 따른다. OS 변경 시 세벌식·로마자 자판 자료 로딩과 실패 시 기본값 적용을 함께 확인한다.

자판 자료는 `KoreanKeyboardLayout`에서 읽고 로마자 조합 규칙은 `JamoComposer`에서 공유한다. 선택 영타 변환 검사는 기존 실제 IME 관측값 중 로마자 274개를 대조한다. 배열 처리를 변경할 때는 감지·변환·후속 조합과 실제 IME 결과를 각각 검증한다.

순수 변환 로직과 AX·붙여넣기 처리를 분리한다. 텍스트 범위는 AX와 동일하게 UTF-16 기준으로 처리하고, 명시적 선택은 커서 문단 범위보다 우선한다.

비동기 편집 전에는 권한·보안 입력·포커스·텍스트·선택·입력 변경 여부를 재확인한다. 클립보드 복원 시 사용자가 새로 복사한 내용을 덮어쓰지 않는다. 입력 내용은 로그에 기록하지 않는다.

편집기마다 AX 지원과 한자 후보 처리, Undo 동작이 다르다. 한자 원문 중복 보정은 정상 대체 결과를 다시 편집하지 않도록 제한한다. 기본 입력기의 변환과 보정 붙여넣기는 별도 편집이므로 Undo 한 번으로 원문까지 복원된다고 가정하지 않는다.

### 비공개 API

Caps Lock 전환 설정의 비공개 HIToolbox API 호출은 `RomanSwitchController.swift`에 격리한다. [Roman Switch 명세](SPEC.md#roman-switch-직접-제어--현재-구현-계약)를 기준으로 새 macOS에서 ABI·심볼 로딩 실패·설정 후 실제 상태를 확인한다. 최초 실행에 사용자의 시스템 설정을 덮어쓰지 않는다.

## 원래 입력 대상 보존

InputDeliveryOrigin은 별도 HID 탭에서 원래 활성 앱 대상을 기록하고 주 입력 처리 전후에 앱 전환을 확인한다. 불일치 보정의 HID 언어 의도와 같은 식별자를 유지하며, 직접 전달된 원래 키의 이력은 한 번 소비한다. 불일치 게이트 재시작 뒤에는 원래 대상 관측을 앞단에 다시 설치한다. `bash scripts/test-input-delivery-origin.sh`는 실제 키 전송 없이 이벤트 시각 변경·대상 변경·중복 소비·패널·합성 표식·만료·수명 해제를 검사한다. 대상 PID 지정 필드만 바꾸는 것으로 실제 전달 대상을 고정했다고 가정하지 않는다. 실제 지연·앱 전환·기본 IME와 누름·놓음 수신 검사는 별도로 수행한다.

## 첫 자음 조합 보정 개발

`OnsetRecoveryController.swift`가 대상 앱과 한Q 입력 수명을 연결하고, `OnsetRecoveryEngine.swift`와 `OnsetInputGate.swift`가 보정·입력 대기를 담당한다. 실험 도구의 입력 로그와 UI는 제품에 포함하지 않는다. `bash scripts/test-onset-recovery.sh`는 실제 키 전송 없이 제품 엔진의 선택 대체·선택 해제 지연·선택 재시도·입력 순서·실패 복원을 검사한다. AppKit 검사는 제한된 실행 샌드박스 밖에서 수행한다. 실제 검증 시 독립 OnsetRecoveryProbe를 먼저 종료하여 두 보정기가 겹치지 않게 한다.

`bash scripts/test-onset-native-layouts.sh`는 별도 NSTextView에서 실제 다섯 IME의 첫 자음 대체·보관 모음/종성 조합을 확인한다. 로마자의 Shift 쌍자음과 배열별 복합 모음도 검사한다. 본문 조회·선택 변경·게이트 통과는 시험 대역을 사용하고 키는 해당 시험 프로세스에만 전송한다. 시험 후 입력 소스 선택·활성 상태를 복원한다. 설치본 전역 AX·물리 키 검증을 대신하지 않는다.

## 입력 소스 불일치 복구 개발

`MismatchRecoveryController.swift`는 제품 수명·설정, `MismatchRecoveryEngine.swift`는 감지·선택 덮어쓰기·결과 확인, `MismatchTextReader.swift`와 `MismatchSnapshotWorker.swift`는 본문 좌표와 비동기 조회를 담당한다. 앱별 예외 목록은 두지 않는다. `MismatchSourceSwitch.swift`와 `MismatchSwitchGate.swift`가 소스 재지정·복구 중 한영 경계를 처리한다. 시험 도구의 원문 로그·장치 감시는 제품에 포함하지 않는다.

`bash scripts/test-mismatch-recovery.sh`는 제품 소스로 24개 회귀 모드와 제품 수명·진단 비밀값 제외 검사를 실행한다. 실제 키 전송은 테스트 대역을 사용한다. 통합 빌드는 이 검사와 기존 첫 자음·앱 수명 검사를 함께 수행한다. 이전에 설치한 독립 AutoRecoveryProbe가 있다면 실제 앱 시험 전에 종료한다. 제품 진단은 복구 상태만 기록하므로 실제 문자 대조에는 별도 시험 driver의 기대값·결과를 사용한다. `--disable-mismatch-recovery`로 해당 실행에서만 복구를 끄고 비교할 수 있다. 일반 실행에서는 저장된 켜기/끄기 설정을 사용하지 않으며, 이전 `mismatchRecoveryEnabled` 값은 시작 시 제거한다. 독립 자동 복구 실험 앱 실행 중에는 제품 감시를 시작하지 않는다.

`MismatchKeyboardLayout.swift`는 Apple 한국어 다섯 배열의 물리 키 대응과 복구 결과 조합을 담당한다. `Tests/MismatchRecovery/NativeLayoutExpectations.json`에는 실제 IME에서 관측한 결과 중 중복을 제외한 349개 사례를 보존한다. 모든 키 조합을 검증한 자료는 아니다. 배열 검사에서는 이 결과와 소스 ID 유지·숫자 자모·정상 영문 제외를 확인한다. 공유 조합기의 기존 기본 동작은 유지한다.

`bash scripts/test-mismatch-native-layouts.sh`는 별도 AppKit 입력창에서 실제 다섯 IME와 제품 복구 엔진을 연결한다. 각 배열의 영문·혼합 접두부와 두벌식 전체 혼합 단어 복구를 포함한 11개 사례를 검사한다. 원래 키와 대기 중인 모음·종성의 최종 문자·커서·전송 횟수·잔여 키·소스 ID를 확인한다. 이 검사는 본문 조회와 선택 변경에 테스트 대역을 사용하고 소스를 직접 선택하므로, 설치본의 전역 접근성 조회·전환 단축키·물리 키 검증은 별도로 수행한다. 시험마다 새 입력창을 사용해 이전 IME 조합이 다음 사례로 넘어가지 않게 한다.

불일치 복구 중 이미 편집기에 전달한 키의 놓음은 즉시 통과시키고, 새로 보관한 키의 누름·놓음은 함께 전달한다. Control-Space 합성 이벤트는 하나의 유지되는 private Quartz 상태를 공유한다. 주 입력 처리도 복구 중 전환 의도를 처리하여 보조 전환 감시가 우회된 경우 임시 영어 소스를 기준으로 반대로 전환하지 않는다. 관련 회귀 검사는 키 놓음 10건, 실제 Quartz 상태 ID 6건 및 앱 수명 검사의 주 전환 경로를 포함한다.

복구 중 Command-A는 보정이 본문·커서를 검증할 때까지 후속 입력과 함께 보관한다. 보정 완료 후 검증한 입력칸과 이력을 SourceSwitchBarrier에 넘기고 전체 선택·삭제·한영 전환·대체 입력을 도착 순서대로 처리한다. 실제 본문과 선택을 확인하기 전에는 후속 편집 키를 전달하지 않는다. 검증되지 않은 본문이나 바뀐 입력칸에는 선택·재전송하지 않는다.

### 전환 대기와 선택 보존

SourceSwitchBarrier는 주 입력 경로에서 앞선 문자·선택의 예상 상태를 추적하고, 한Q 전환 요청 뒤 후속 키를 보관한다. 같은 입력칸의 실제 상태와 보정 완료를 확인한 뒤 소스를 전환하고 키를 하나씩 전달한다. 조회 실패와 다른 입력칸의 확인을 구분한다. `bash scripts/test-source-switch-barrier.sh`는 키 전송 대역으로 이전 입력 반영 지연, 새 소스 입력, 부분·전체 선택, 연속 전환, 키 놓음, 다른 보정의 진행, 일시 조회 실패, 포커스 변경과 시간 초과를 검사한다. 실제 Spotlight 시험과 구분하며, 자판표를 읽는 실행 환경이 필요하다.

### 검증 수준과 최근 설치본 확인

| 검증 | 방법 | 확인 범위 |
| --- | --- | --- |
| 자동 회귀 검사 | `test-input-focus.sh`, `test-selection-source-switch.sh`, `test-source-switch-barrier.sh`, `test-mismatch-recovery.sh` 및 전체 빌드 | 테스트 대역으로 포커스·선택·전환·지연·실패 시 보존 검사. 사람의 물리 키 검증과 구분 |
| 실제 IME 검사 | `test-onset-native-layouts.sh`, `test-mismatch-native-layouts.sh` | 별도 입력창과 실제 IME 사용. 설치 앱의 전역 입력 경로와 구분 |
| 설치본 합성 입력 | 독립 진단 엔진을 종료하고 실제 한Q 앱에 합성 키 전달 | 최종 문구·UTF-16 커서·보정 완료·잔여 입력 확인 |
| 물리 키 확인 | 사용자가 실제 키보드로 입력 | 기기별 키 동작과 체감 확인. 합성 시험 통과로 대체하지 않음 |

후보 130의 설치본 합성 시험은 TextEdit 12회, 메모 12회, Edge 본문 12회, Edge 주소창 36회, Spotlight 36회로 총 108회 통과했다. 오른쪽 Command 전환, 전체 선택 후 대체, 긴 단어와 띄어쓰기를 포함했다. 키 누름·놓음 각각의 간격은 5ms 또는 10ms다. 92회는 기대 문구와 정확히 일치했고, TextEdit·메모의 16회는 편집기의 첫 ASCII 자동 대문자화를 허용했다. 커서 위치도 함께 확인했다. Safari와 사람의 물리 키 확인은 이 결과에 포함하지 않으며, 모든 환경의 입력을 보장하는 결과로 해석하지 않는다.

## 검증과 진단

첫 자음 보정을 제외한 비교 진단은 실행 중인 한Q를 종료한 뒤 `open build/HanQ.app --args --disable-onset-recovery`로 시작한다. 해당 실행에만 적용하며 일반 실행은 보정을 활성화한다.

`bash scripts/test-versioning.sh`는 기존 앱이 없는 작업 폴더에서도 버전이 동일한지와 버전 형식 검사를 확인한다. `bash scripts/build-app.sh --print-version`으로 앱을 교체하지 않고 현재 배포 준비 번호를 확인할 수 있다.

빌드 스크립트는 `Tests/main.swift`의 로직 검사와 다음 검사를 실행한다.

- `scripts/test-diagnostics.sh`: 진단 모드에서만 메시지 평가·기록
- `scripts/test-lifecycle.sh`: 이벤트 탭 해제
- `scripts/test-watchdog.sh`: 응답 중단 시 종료
- `scripts/test-permission-monitor.sh`: 권한 감시 실패·중단 경로
- `scripts/test-recovery.sh`: 권한 상실 후 재실행과 반복 방지

LaunchServices를 통한 실제 재실행 경로는 별도로 검사한다.

```sh
bash scripts/test-recovery-app.sh
```

자동 검사만으로 물리 키 입력과 대상 편집기의 IME 동작을 검증할 수는 없다. 변경한 기능에 따라 실제 우측 키 입력, 한자 후보 확정·취소, 붙여넣기·Undo·클립보드 복원, 권한 철회·재허용을 확인한다.

텍스트 변환의 요청·선택 준비·정상 중단 등 상세 과정은 `--diagnose-input` 모드에서만 기록한다. 대상 앱 식별자는 상세 로그에서 제외한다. AX 읽기 실패·선택 반영 시간 초과·편집 결과 확인 실패와 권한 안전 종료·입력 소스 전환 실패는 일반 실행에서도 시스템 로그에 남긴다. 입력 문자열과 클립보드 내용은 기록하지 않는다.

권한 문제는 [run-app-input-diagnostic.py](../scripts/run-app-input-diagnostic.py)로 LaunchServices를 통해 재현한다. 터미널 자식으로 직접 실행하면 일반 앱 실행과 권한 조회 결과가 다를 수 있다. 사용 가능한 옵션은 다음 명령으로 확인한다.

```sh
python3 scripts/run-app-input-diagnostic.py --help
```

## 베타 검증 운영

0.3.0 베타의 물리 키·키보드별 실사용 확인은 배포 후 사용자 피드백으로 보완한다. 물리 키 미확인 자체를 이번 배열 대응 작업의 미완료 항목이나 별도 배포 대기 조건으로 두지 않는다. 자동 검사와 실제 앱에서 합성 키로 확인한 결과, 사용자가 직접 키를 눌러 확인한 결과는 구분해 기록한다. 배포 전 빌드·설치·업데이트 검사는 [배포 안내](RELEASE.md)를 따른다.

피드백에는 앱·입력 소스·키보드 종류와 모델·재현 순서·기대 결과·실제 결과를 함께 받는다. 새로 접수한 문제는 기존 검증 결과와 대조하고 재현 여부와 영향 범위를 확인해 후속 수정으로 관리한다.

## 지원 범위와 추가 검증

한국어 입력기 지원 범위는 모든 기능에 공통으로 적용하는 [지원 정책](SPEC.md#한국어-입력기-지원-정책)을 따른다. 아래 항목은 앱·물리 키·환경별 동작을 확인하기 위한 추가 검증 대상이다. 알려진 호환성 문제는 각 기능 명세에서 관리한다.

최소 배포 대상은 macOS 13이며 안내 대상은 Apple Silicon이다.

- 여러 macOS 버전에서 입력·손쉬운 사용 권한·Caps Lock 설정 동작.
- 지원 입력 소스별 실제 입력·붙여넣기·Undo, 편집기별 한자 확정·취소와 원문 중복 보정.
- 클립보드 복원, 자판 자료 조회 실패, 입력 도중 포커스·입력 소스 변경 시 편집 취소.
- 내장·외장 키보드, 잠자기·깨우기, 장시간 실행과 권한 철회 후 입력 복구.
- 실제 로그아웃·로그인 및 재부팅 후 자동 실행과 중복 실행 여부.
- 권한 검사 보조 프로세스를 포함한 CPU·메모리·wakeups·전력 영향.

단기 CPU 관측을 배터리 사용량으로 환산하지 않는다. 성능 측정 도구는 `scripts/measure-energy.sh`다. 결과를 공유할 때는 다른 프로세스나 개인 환경 정보가 포함되지 않았는지 확인한다.

변경 사항을 제출할 때는 PR 본문에 실행한 검사·환경·관측 결과·미검증 항목을 요약한다. PR을 만들기 전에는 로컬 작업 기록으로 보관한다. 원본 로그는 개인 환경 정보와 입력 내용이 없는지 확인한 뒤 필요한 부분만 공유한다.

## 문서 갱신

사용자에게 보이는 기능·사용 조건은 README에, 빌드·구현·진단 절차는 이 문서에 반영한다.

GitHub 머지·업로드, 배포용 서명·공증, Release 생성·공개와 운영 업데이트 피드 반영은 유지관리자가 직접 수행하거나 AI에 요청하여 수행한다. 기여자와 AI는 요청받은 코드·문서 수정, 로컬 검사, 배포 후보와 릴리스 노트 준비를 수행하며, 원격 변경·배포 작업은 사용자가 요청한 범위에서 수행한다. 로컬 개발 빌드의 ad-hoc 서명은 위 배포용 서명과 구분한다. 상세 절차는 [배포 안내](RELEASE.md)를 참고한다.
