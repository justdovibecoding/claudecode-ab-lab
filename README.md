# claudecode-ab-lab

Claude Code의 **스킬·플러그인을 넣은 환경(B)**과 **기본 환경(A)**을 한 PC에서 완전히 분리해
같은 조건으로 비교하는 실습 도구입니다. 비교 실습 영상이나 자료를 만들 때
"정말 그 스킬 덕분인가?"를 근거와 함께 보여 주는 것이 목적입니다.

> 비공식 개인 도구입니다. Anthropic이 만들거나 보증한 도구가 아닙니다.

## 무엇을 해 주나

- **환경 분리**: `CLAUDE_CONFIG_DIR`로 설정 폴더를 A/B로 나눠, 평소 쓰는 `~/.claude`의 플러그인·스킬·훅·메모리·MCP가 섞이지 않게 합니다.
- **실험 단위 관리**: 비교 주제마다 `experiments\<이름>\`에 실습 프로젝트, 비교 대상, 지시문, 결과를 모아 둡니다.
- **B 구성 관리**: 공식 플러그인 목록 검색·설치, 로컬 폴더·Git(커밋 고정) 추가, 켜고 끄기, 예상 토큰 확인.
  무엇을 어디서 어떤 버전으로 넣었는지 `b-manifest.json`에 기록해 측정 조건과 보고서에 붙입니다(`b-config.ps1`, 앱의 "B 구성").
- **품질 판정**: 매 측정 뒤 확인 명령(예: `npm test`)을 자동 실행해 통과 여부를 기록하고, 앱에서 A/B를 가린 블라인드 판정을 합니다.
- **A/B 동등성 점검**: 비교 대상 말고는 같은지(계정·요금제·계정 스킬·설정) 확인해 점검·측정 조건·보고서에 남깁니다.
- **GUI 앱**: A/B Claude Code 화면을 한 창에 나란히 띄우고, 공통 입력을 쪽별 예비 입력창에 동기화한 뒤
  쪽마다 고쳐서 보냅니다. 지시문 차이는 공정성 배너와 기록으로 공개합니다([docs/app.md](docs/app.md)).
- **나란히 실행**: Windows Terminal을 좌우로 나눠 왼쪽 A, 오른쪽 B를 동시에 띄웁니다(녹화용).
- **반복 측정**: 같은 지시문을 A/B에서 번갈아 N회 실행하고 비용·턴·시간·토큰·변경 파일 수를 모읍니다.
  비교 대상이 **실제로 로드·호출됐는지**(스킬·에이전트·MCP 호출 횟수)와 **상시 컨텍스트 비용**(첫 요청 토큰)도 기록합니다.
- **보고서**: 측정 결과를 `REPORT.md` 비교표로 정리합니다.
- **점검**: 녹화·측정 전에 환경이 깨끗한지 `doctor.ps1`로 확인합니다.

## 요구 사항

| 항목 | 내용 |
|---|---|
| OS | Windows 10/11 (Windows 11 Pro에서 작성·시험) |
| 셸 | Windows PowerShell 5.1 이상 |
| Claude Code | 2.1.273 이상(`syncClaudeAiPlugins` 설정). 2.1.306에서 시험 |
| 계정 | Claude 구독(Pro/Max 등) 또는 Anthropic Console |
| 선택 | Windows Terminal(`wt`). 없으면 창 2개로 대체 |
| GUI 앱 | Node.js 20 이상(22.19에서 시험). 처음 실행 때 `app\`에 Electron 등을 설치 |

## 빠른 시작

```powershell
cd D:\_dzp\VIBE_CODING\claudecode-ab-lab

# 0) 스크립트 실행이 막히면 한 번만
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned

# 1) 처음 설정: A 기본 환경 폴더, 이 PC 전용 설정(작업 폴더 위치) 생성 + 점검
.\setup.ps1                      # 작업 폴더 기본 위치: <드라이브>:\cc-ab-work

# 2) A 기본 환경 로그인 (한 번)
.\login.ps1

# 3) 실험 만들기 (기존 프로젝트를 실습 원본으로 복사)
.\new-exp.ps1 -Name superpowers -Description "superpowers 유무 비교" -FixtureFrom D:\some\project

# 4) B에 비교 대상 넣기 (앱의 "B 구성" 화면 또는 b-config.ps1, 자세한 방법은 docs\usage.md)
.\b-config.ps1 -Exp superpowers -Action available                      # 공식 목록
.\b-config.ps1 -Exp superpowers -Action install -Plugin superpowers@anthropic-plugin-directory
.\b-config.ps1 -Exp superpowers -Action add-local -Path D:\src\my-skill  # 로컬 플러그인·스킬 폴더
#    (선택) 품질 확인 명령: experiments\superpowers\experiment.json 의 check.command (예: "npm test")

# 5) 지시문 작성: experiments\superpowers\prompts\01-task.md

# 6) B 로그인 (실험마다 한 번) + 점검
.\login.ps1 -Exp superpowers
.\doctor.ps1 -Exp superpowers

# 7-a) GUI 앱으로 비교 (예비 입력창·공정성 배너·기록 포함)
.\app.ps1

# 7-a') 또는 Windows Terminal로 나란히 실행
.\open-both.ps1 -Exp superpowers

# 7-b) 반복 측정 + 보고서 (근거용)
.\run-headless.ps1 -Exp superpowers -Prompt 01-task -Runs 3
.\report.ps1 -Exp superpowers
```

## A와 B의 정의

| | A: 기본 | B: 비교 |
|---|---|---|
| 설정 폴더 | `config-vanilla\` (모든 실험이 공용) | `experiments\<이름>\config-B\` (실험마다 따로) |
| Claude Code 내장 기능·명령 | 포함 | 포함 |
| claude.ai 계정의 기본 스킬 동기화 (pdf, docx 등) | 포함 | 포함 |
| claude.ai 계정의 플러그인 동기화 | **제외** (`syncClaudeAiPlugins: false`) | **제외** |
| claude.ai 계정 커넥터(MCP) | **제외** (`--strict-mcp-config` + 빈 구성) | **제외** (`mcp-B.json`에 적은 것만) |
| 평소 `~/.claude`의 플러그인·스킬·훅·메모리 | 제외 | 제외 |
| 랩 설정 폴더 안에 쌓이는 작업 폴더별 자동 메모리 | 작업 폴더 초기화 때 지움 | 작업 폴더 초기화 때 지움 |
| 비교 대상 | 없음 | `plugins\`, `skills\`, `/plugin` 설치, `mcp-B.json` |

"기본"을 **Claude Code 단독**(계정 스킬도 제외)으로 잡고 싶으면 `templates\settings.json`과
`config-vanilla\settings.json`에 `"syncClaudeAiSkills": false`를 추가합니다.
자세한 원리는 [docs/isolation.md](docs/isolation.md)를 보세요.

## 폴더 구조

```
claudecode-ab-lab\
├─ README.md
├─ setup.ps1          처음 설정(+ 점검)
├─ login.ps1          A 또는 실험 B 로그인/로그아웃
├─ doctor.ps1         환경 점검
├─ new-exp.ps1        실험 만들기
├─ list-exp.ps1       실험 목록
├─ start.ps1          한쪽(A/B) 대화형 실행
├─ open-both.ps1      A/B 나란히 실행
├─ reset.ps1          작업 폴더를 실습 원본 상태로 되돌리기
├─ run-headless.ps1   A/B 반복 측정
├─ report.ps1         측정 결과 → REPORT.md
├─ b-config.ps1       B 구성: 설치·제거·로컬/Git 추가·토큰·동등성 점검
├─ app.ps1            GUI 앱 실행(처음이면 의존성 설치)
├─ app\               Electron 앱 소스(docs\app.md)
├─ lib\common.ps1     공용 함수
├─ templates\settings.json   A/B 설정 폴더의 출발점
├─ empty-mcp.json     A용 빈 MCP 구성
├─ docs\              상세 문서
├─ config-vanilla\    (git 제외) A 설정 폴더 · 로그인 토큰 포함
├─ lab.local.json     (git 제외) 이 PC 전용 설정
└─ experiments\
   └─ <이름>\
      ├─ experiment.json   설명·모델·만든 날·품질 확인 명령(check)
      ├─ b-manifest.json   B 구성 기록(종류·이름·버전·출처·커밋)
      ├─ NOTES.md          B 구성·관찰·결론 기록
      ├─ REPORT.md         report.ps1 결과
      ├─ fixture\          실습 원본 프로젝트
      ├─ plugins\          B 전용 --plugin-dir 플러그인
      ├─ skills\           B 전용 스킬 원본
      ├─ prompts\          지시문(.md). 쪽별 변형은 <이름>.A.md / <이름>.B.md
      ├─ mcp-B.json        B 전용 MCP 서버
      ├─ config-B\         (git 제외) B 설정 폴더 · 로그인 토큰 포함
      ├─ results\          (git 제외) 반복 측정 결과
      └─ sessions\         (git 제외) GUI 앱 대화형 세션 기록

<드라이브>:\cc-ab-work\<이름>\work-A, work-B   ← 실제 작업 폴더(저장소 밖)
```

작업 폴더를 저장소 **밖**에 두는 이유: 저장소 안에서 실행하면 Claude Code가 이 저장소의 `.git`과
상위 폴더의 `CLAUDE.md` 등을 프로젝트 맥락으로 읽어 A/B 모두 오염됩니다.

## 문서

| 문서 | 내용 |
|---|---|
| [docs/isolation.md](docs/isolation.md) | 격리 원리: Claude Code가 자동으로 읽는 것과 각각을 막는 방법, 막지 못하는 것 |
| [docs/usage.md](docs/usage.md) | 단계별 상세 사용법: 실험 준비, B 구성 3가지, 나란히 실행, 반복 측정, 보고서 |
| [docs/app.md](docs/app.md) | GUI 앱: 화면, 공통/예비 입력과 공정성 배너, 세션 기록, 키, 구조, 알려진 한계 |
| [docs/methodology.md](docs/methodology.md) | 공정한 비교를 위한 규칙, 결과 해석, 영상 촬영 팁 |
| [docs/scripts.md](docs/scripts.md) | 스크립트별 옵션과 예시 |
| [docs/troubleshooting.md](docs/troubleshooting.md) | 자주 겪는 문제와 해결 |

## 보안 주의

- `config-vanilla\`와 `experiments\*\config-B\`에는 **로그인 토큰(`.credentials.json`)**이 들어 있습니다.
  `.gitignore`로 제외되어 있으니 이 규칙을 지우지 마세요.
- `run-headless.ps1 -PermissionMode bypassPermissions`는 확인 없이 명령을 실행합니다.
  실습 원본에 믿을 수 없는 코드가 있다면 쓰지 마세요.

## 검증 상태 (2026-10-21, Claude Code 2.1.306)

| 항목 | 상태 |
|---|---|
| 스크립트 구문 검사(PowerShell 5.1) | 통과 |
| setup / new-exp / list-exp / reset / doctor | 임시 폴더에서 실행 확인 |
| start / run-headless / report | 가짜 `claude`로 인자·환경 변수 복원·결과 수집·보고서 확인 |
| 실제 `claude -p`에 한국어 지시문 파이프 전달 + JSON 결과 해석 | 확인 |
| `syncClaudeAiPlugins: false`로 계정 플러그인 제외 | 공식 문서 기준. 실행 화면 `/plugin`으로 확인 권장 |
| B `skills\` 동기화가 계정 스킬(`skills\synced\`)을 지우지 않음 | 확인 |
| GUI 앱: 실행, 세션 시작, 한국어 지시문 A/B 전송(B 변형 포함), 전송 기록, 점검·반복 측정·보고서 화면 | 실제 claude(Haiku)로 확인 |
| 반복 측정의 쪽별 지시문 변형(`.B.md`) → `conditions.json`·보고서 표시 | 확인 |
| `open-both.ps1`의 Windows Terminal 분할, `--plugin-dir` 실제 로드, B `skills\` 인식 | **미확인** - 첫 실험에서 `/plugin`, `/context`로 확인 필요 |
| GUI 앱의 이미지 붙여넣기(Alt+V), 상태 신호(OSC 7501) | **미확인 / 미지원** - [docs/app.md](docs/app.md) 9절 |
| B 구성: 공식 목록 조회, 설치(출처·커밋 기록), 켜고 끄기, 토큰 확인, 제거, 로컬 폴더·Git(하위 경로) 추가 | 실제 claude로 확인(짧은 경로의 시험 랩) |
| 품질 확인 명령 → 결과·보고서, 블라인드 판정 → `judgments.json`·보고서 | 가짜 claude 와 앱 화면으로 확인 |
| A/B 동등성 점검(다른 계정·요금제·계정 스킬·설정 차이 감지) | 가짜 claude 로 확인 |
| 마켓플레이스 추가(`add-marketplace`), 실행 확인이 필요한 플러그인 설치 | **미확인** |
| 앱의 로그인 버튼(새 PowerShell 창), 한글 지시문·결과 이름, 판정 중 상태 보존 | 앱 화면으로 확인 |
| 작업 폴더 초기화 때 자동 메모리 삭제·점검 경고, 동등성 확대(설정 폴더 추가 파일·작업 폴더별 권한) | 가짜 claude 로 확인. 폴더 이름 규칙은 실제 Claude Code 가 만든 폴더와 대조 |
| Git 추가의 옵션 주입·경로 탈출 차단, 스크립트의 claude 실행 파일 통일(`CC_AB_CLAUDE`) | 확인 |
| `stream-json` 형식(init 로드 목록, `Skill` 호출, 훅 문맥, 첫 요청 사용량) | 실제 claude(Haiku)로 형식 확인 |
| 반복 측정의 로드 확인·대상 호출·첫 요청 컨텍스트 → `conditions.json`·`summary.csv`·보고서 | 가짜 claude 로 확인 |
