# Electron 앱(GUI)

A/B 두 Claude Code 화면을 한 창에 나란히 띄우고, **공통 입력 → 쪽별 예비 입력창 → 전송** 흐름으로
비교하는 데스크톱 앱입니다. 점검·반복 측정·보고서는 기존 PowerShell 스크립트를 그대로 호출합니다.

구성: Electron + xterm.js(화면) + node-pty(Windows ConPTY 가상 터미널). VS Code 통합 터미널과 같은 조합입니다.

## 1. 준비와 실행

처음 한 번은 CLI와 같은 준비가 필요합니다([usage.md](usage.md) 1–3절).

```powershell
.\setup.ps1          # A 설정 폴더·작업 폴더 위치
.\login.ps1          # A 로그인
.\new-exp.ps1 -Name superpowers -Description "..."   # 앱의 "새 실험"으로도 가능
.\login.ps1 -Exp superpowers                          # 앱의 "점검 · 로그인" 화면에서도 가능
```

앱 실행:

```powershell
.\app.ps1            # 처음이면 app\ 에 npm install 후 실행
.\app.ps1 -Dev       # F12 개발자 도구, 화면 로그 출력
```

또는 `cd app; npm install; npm start`. Node.js 20 이상이 필요합니다(22.19에서 시험).

## 2. 화면

```
┌ 왼쪽 ─────────┐┌ 실험 이름 · 설명 · 모델 · B 구성 · B 로그인 · 측정 횟수 ─────────────┐
│ 실험 목록      ││ [세션 시작] □작업 폴더 초기화  권한 모드[ ]  [세션 종료]  창 크기[ ] [기록 폴더] │
│ 새로고침/새 실험││ ┌ 공정성 배너: 동일(초록) / 호출 문구(주황) / 내용 변경(빨강) ┐            │
│               ││ ┌ A 기본 ─ 설정 폴더 · 창 제목 · 상태 ┐ ┌ B 비교 ─ … ┐                 │
│ 화면           ││ │  Claude Code 대화 화면             │ │            │                 │
│  대화형 비교    ││ └────────────────────────────────────┘ └────────────┘                 │
│  점검 · 로그인  ││ ┌ A 예비 입력 [수정됨] [되돌리기][A만] ┐ ┌ B 예비 입력 … ┐               │
│  반복 측정      ││ ┌ 공통 입력 [지시문 불러오기▾] [                 ] [A·B 둘 다 보내기] ┐  │
│  결과          ││                                                                       │
└───────────────┘└───────────────────────────────────────────────────────────────────────┘
```

| 화면 | 하는 일 |
|---|---|
| 대화형 비교 | A/B Claude Code를 앱 안에서 실행하고 지시문을 보냄 |
| B 구성 | A/B 동등성 점검, B 구성 목록(버전·커밋·출처, 켜고 끄기·토큰·제거), 공식 목록 검색·설치, 마켓플레이스 추가, 로컬 폴더·Git 추가 |
| 점검 · 로그인 | `doctor.ps1 -Exp` 실행 결과, A/B 로그인 창 열기, 실험 폴더 열기 |
| 반복 측정 | `run-headless.ps1` 실행(지시문·회차·권한 모드·예산·쪽), 확인 명령 편집, 진행 로그, 취소 |
| 결과 | `report.ps1` 실행 후 `REPORT.md` 표시, 블라인드 판정 |

B 구성을 바꾸면 진행 중인 대화형 세션의 B에는 바로 반영되지 않습니다. B의 "다시 시작"을 누르세요.

- 지시문·결과 폴더 이름은 한글도 됩니다. 실험 이름만 영문·숫자·`._-`입니다.
- 반복 측정이 끝나거나 B 구성을 바꾸면 실험 정보를 다시 읽지만, 판정 중인 카드·고른 지시문·편집 중인 확인 명령은 그대로 둡니다.
  저장하지 않은 판정이 있는 채로 다른 실험을 고르면 한 번은 막고 알려 주며, 한 번 더 누르면 판정을 버리고 바꿉니다.
- 세션 시작 때 "작업 폴더 초기화"를 켜 두면 그 작업 폴더의 자동 메모리도 지웁니다. 끄면 이어서 작업하므로 메모리도 남습니다.
자세한 동작은 [usage.md](usage.md) 3절(B 구성)과 6절(확인 명령·동등성·판정)을 참고하세요.

## 3. 대화형 비교 순서

1. 왼쪽에서 실험을 고릅니다.
2. **세션 시작**: "작업 폴더 초기화"가 켜져 있으면 `reset.ps1`로 실습 원본 상태로 되돌린 뒤 시작합니다.
   권한 모드를 고르면 양쪽에 똑같이 `--permission-mode`로 들어갑니다.
3. 새 작업 폴더에서 처음 실행하면 Claude Code가 **폴더 신뢰 확인**을 묻습니다. 기본 선택이 "No, exit"이므로
   터미널을 클릭한 뒤 **아래 화살표로 "Yes, I trust this folder"를 고르고 Enter**를 누릅니다.
   신뢰 여부는 설정 폴더에 경로별로 저장되므로 같은 작업 폴더에서는 다시 묻지 않습니다.
4. 양쪽 `/context`를 한 번씩 입력해 A/B 환경 차이를 보여 줍니다(영상 첫 장면용).
5. 지시문을 보냅니다(아래 4절).
6. 끝나면 **세션 종료**. 기록은 "기록 폴더"에 남습니다.

한쪽만 문제가 생기면 그쪽 **다시 시작**을 누릅니다(기록에 `restart`로 남음). 작업 폴더는 그대로 둡니다.

## 4. 공통 입력과 예비 입력창

| 동작 | 결과 |
|---|---|
| 공통 입력에 쓰기 | **수정하지 않은** 예비 입력창에 그대로 따라 들어감 |
| 예비 입력창 고치기 | 그쪽은 "수정됨"이 되고 더 이상 따라오지 않음. 공통과 같게 고치면 다시 "공통과 같음" |
| 공통으로 되돌리기 | 그쪽 예비 입력창을 공통 입력으로 되돌리고 다시 동기화 |
| 지시문 불러오기 | `prompts\<이름>.md`를 공통으로, `<이름>.A.md`/`<이름>.B.md`가 있으면 그쪽 예비 입력창으로 |
| A·B 둘 다 보내기 / Ctrl+Enter(공통 입력) | 양쪽 예비 입력창 내용을 각각 전송 |
| A만 / B만 보내기 / Ctrl+Enter(예비 입력창) | 그쪽만 전송 |

**공정성 배너**

| 색 | 의미 |
|---|---|
| 초록 | A·B 지시문 동일 |
| 주황 "호출 문구" | 공통 문장을 그대로 두고 덧붙임(예: B에만 "superpowers 스킬을 사용해줘"). 덧붙인 문구를 배너에 표시 |
| 빨강 "내용 변경" | 공통 문장 자체가 달라짐. 비교 조건이 달라지므로 영상·보고서에서 반드시 밝힐 것 |

스킬은 이름을 지시문에 적어야 쓰이는 경우가 있어 "호출 문구"를 허용합니다. 대신 배너와 기록으로 공개합니다.
판단 기준은 [methodology.md](methodology.md)를 참고하세요.

**전송 방식**: 한국어는 예비 입력창(일반 입력칸)에서 완성한 뒤 보내므로 터미널 안의 한글 조합 입력 문제를 피합니다.
Claude Code가 붙여넣기 모드(bracketed paste)를 켜 두었으면 붙여넣기로 보내고(여러 줄 그대로), 아니면 줄바꿈을
Ctrl+J로 바꿔 보낸 뒤 Enter를 보냅니다.

## 5. 기록(`experiments\<이름>\sessions\<시각>\`)

| 파일 | 내용 |
|---|---|
| `session.json` | 실험, claude.exe 경로·버전, 초기화 여부, 권한 모드, 양쪽 실행 정보(설정 폴더·작업 폴더·인자), 시작·종료 시각 |
| `turns.jsonl` | 전송마다 한 줄: 시각, 보낸 쪽, 공통 입력, A/B에 실제로 보낸 문장, 공정성 판정, 덧붙인 문구. 다시 시작 기록 |
| `A.log`, `B.log` | 터미널 출력 원본(VT 시퀀스 포함). 터미널에서 `Get-Content A.log -Raw`로 다시 볼 수 있음 |

`sessions\`는 `.gitignore`로 제외됩니다.

## 6. 키

| 키 | 동작 |
|---|---|
| Ctrl+C | 터미널에서 글자를 선택했으면 복사, 아니면 Claude Code로(중단) |
| Ctrl+V | 붙여넣기 |
| Ctrl+W, Ctrl+R, Ctrl+T 등 | 앱 메뉴를 없애 두었으므로 그대로 Claude Code로 전달 |
| Alt+V | Claude Code 이미지 붙여넣기(Windows) — **아직 확인 안 함** |
| F12 | `-Dev`로 실행했을 때 개발자 도구 |

## 7. 구조

```
app\
├─ package.json
├─ src\main\main.js        창, A/B 가상 터미널, 스크립트 실행, 세션 기록
├─ src\main\preload.js     화면에 열어 주는 기능 목록(이것만 쓸 수 있음)
├─ src\main\lab.js         실험·지시문 읽기, 세션 기록
├─ src\main\powershell.js  PowerShell 스크립트 실행(UTF-8 출력)
├─ src\main\env.js         자식 프로세스 환경 변수 정리
├─ src\main\claude-resolve.js  claude.exe 위치 찾기
├─ src\shared\prompt.js    공통/예비 입력 상태와 공정성 판정
├─ src\shared\judge.js     블라인드 순서 섞기, 판정 검사·집계
├─ src\renderer\           화면(index.html, styles.css, app.js, bconfig.js, judging.js)
└─ test\logic.test.js      단위 테스트(npm test)
```

- **실행 정보는 PowerShell 한 곳에서**: 앱은 `start.ps1 -Exp <이름> -Side <A|B> -PrintLaunchJson`이 출력한
  설정 폴더·작업 폴더·`claude` 인자를 그대로 써서 터미널을 띄웁니다. 격리 규칙은 `lib\common.ps1`에만 있습니다.
- **claude.exe 직접 실행**: npm 설치는 PATH에 껍데기(`claude.cmd`, `claude.ps1`)만 있으므로 그 옆
  `node_modules\@anthropic-ai\claude-code\bin\claude.exe`를 찾아 실행합니다. 설치 스크립트(네이티브) 설치는
  `%USERPROFILE%\.local\bin\claude.exe`. 다른 위치면 `CC_AB_CLAUDE` 환경 변수로 지정합니다.
- **같은 claude 실행 파일**: 앱이 찾은 claude.exe 경로를 스크립트(점검·반복 측정·B 구성)에 `CC_AB_CLAUDE`로 넘겨,
  대화형과 측정이 같은 버전으로 돌게 합니다. 반복 측정의 `conditions.json`에 `claudePath`로 남습니다.
- **환경 변수**: 앱을 Claude Code 세션 안에서 띄워도 `CLAUDECODE`, `CLAUDE_CODE_SESSION_ID` 등 세션 변수와 기존
  `CLAUDE_CONFIG_DIR`은 자식 프로세스에 넘기지 않습니다. `COLORTERM=truecolor`를 양쪽에 똑같이 줍니다.
- **보안**: 화면은 Node 기능 없이(`contextIsolation`, `sandbox`, `nodeIntegration: false`) 동작하고, 외부 페이지
  이동·새 창을 막습니다. 화면이 부를 수 있는 기능은 `preload.js`의 목록뿐이며, 실행할 수 있는 스크립트도
  정해 둔 것(doctor, reset, run-headless, report, new-exp, list-exp, b-config, start)만입니다. 실험·측정 이름은
영문·숫자·`._-`만 받고 `.`·`..`처럼 점으로만 된 이름은 거부해 상위 폴더로 빠져나가지 못하게 합니다.
네트워크 포트를 열지 않습니다.

## 8. 환경 변수

| 이름 | 용도 |
|---|---|
| `CC_AB_LAB_ROOT` | 저장소 위치(기본: `app\`의 상위 폴더) |
| `CC_AB_CLAUDE` | claude.exe 경로 직접 지정. PowerShell 스크립트도 이 값을 따름(`lib\common.ps1`의 `$ClaudeCmd`) |
| `CC_AB_DEV=1` | F12 개발자 도구, 화면 로그를 콘솔에 출력(`.\app.ps1 -Dev`) |
| `CC_AB_TEST_SCRIPT`, `CC_AB_SNAPSHOT`, `CC_AB_TEST_LOG` | 개발 점검용: 화면에서 스크립트 실행 → 화면 캡처 저장 → 종료 |

## 9. 알려진 한계 (2026-10-21, Claude Code 2.1.306, Electron 45)

- **상태 표시**: Claude Code는 시작할 때 터미널에 상태 신호(OSC 7501) 지원 여부를 묻습니다(`?`). 응답 형식이 공개
  문서에 없어 앱은 응답하지 않으며, 그래서 "작업 중/입력 대기" 신호는 오지 않습니다. 대신 출력 활동으로
  "출력 중 / 조용함 / 종료됨"을 표시하고, Claude Code가 바꾸는 창 제목을 보여 줍니다.
- **한글 글자 간격**: 터미널 글꼴(Cascadia Mono)에 한글이 없어 대체 글꼴로 그려 글자 사이가 벌어져 보일 수 있습니다.
  D2Coding 같은 한글 고정폭 글꼴을 설치하면 `app.js`의 `fontFamily` 앞쪽에 추가하세요.
- **이미지 붙여넣기(Alt+V)**: 확인하지 않았습니다.
- **설치 파일(exe) 만들기**: 아직 없습니다. 지금은 `.\app.ps1`로 실행합니다.
- Windows 전용입니다(PowerShell 스크립트, ConPTY, `robocopy` 사용).
