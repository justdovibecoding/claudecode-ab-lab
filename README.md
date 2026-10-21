# claudecode-ab-lab

Claude Code의 **스킬·플러그인을 넣은 환경(B)**과 **기본 환경(A)**을 한 PC에서 완전히 분리해
같은 조건으로 비교하는 실습 도구입니다. 비교 실습 영상이나 자료를 만들 때
"정말 그 스킬 덕분인가?"를 근거와 함께 보여 주는 것이 목적입니다.

> 비공식 개인 도구입니다. Anthropic이 만들거나 보증한 도구가 아닙니다.

## 무엇을 해 주나

- **환경 분리**: `CLAUDE_CONFIG_DIR`로 설정 폴더를 A/B로 나눠, 평소 쓰는 `~/.claude`의 플러그인·스킬·훅·메모리·MCP가 섞이지 않게 합니다.
- **실험 단위 관리**: 비교 주제마다 `experiments\<이름>\`에 실습 프로젝트, 비교 대상, 지시문, 결과를 모아 둡니다.
- **나란히 실행**: Windows Terminal을 좌우로 나눠 왼쪽 A, 오른쪽 B를 동시에 띄웁니다(녹화용).
- **반복 측정**: 같은 지시문을 A/B에서 번갈아 N회 실행하고 비용·턴·시간·토큰·변경 파일 수를 모읍니다.
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

# 4) B에 비교 대상 넣기 (셋 중 하나, 자세한 방법은 docs\usage.md)
#    experiments\superpowers\plugins\<플러그인>\      설치 없이 불러오기
#    experiments\superpowers\skills\<스킬>\SKILL.md   스킬만 비교
#    B를 열고 /plugin 으로 정식 설치                   설치 과정 촬영용

# 5) 지시문 작성: experiments\superpowers\prompts\01-task.md

# 6) B 로그인 (실험마다 한 번) + 점검
.\login.ps1 -Exp superpowers
.\doctor.ps1 -Exp superpowers

# 7-a) 나란히 실행 (녹화용)
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
├─ lib\common.ps1     공용 함수
├─ templates\settings.json   A/B 설정 폴더의 출발점
├─ empty-mcp.json     A용 빈 MCP 구성
├─ docs\              상세 문서
├─ config-vanilla\    (git 제외) A 설정 폴더 · 로그인 토큰 포함
├─ lab.local.json     (git 제외) 이 PC 전용 설정
└─ experiments\
   └─ <이름>\
      ├─ experiment.json   설명·모델·만든 날
      ├─ NOTES.md          B 구성·관찰·결론 기록
      ├─ REPORT.md         report.ps1 결과
      ├─ fixture\          실습 원본 프로젝트
      ├─ plugins\          B 전용 --plugin-dir 플러그인
      ├─ skills\           B 전용 스킬 원본
      ├─ prompts\          지시문(.md)
      ├─ mcp-B.json        B 전용 MCP 서버
      ├─ config-B\         (git 제외) B 설정 폴더 · 로그인 토큰 포함
      └─ results\          (git 제외) 반복 측정 결과

<드라이브>:\cc-ab-work\<이름>\work-A, work-B   ← 실제 작업 폴더(저장소 밖)
```

작업 폴더를 저장소 **밖**에 두는 이유: 저장소 안에서 실행하면 Claude Code가 이 저장소의 `.git`과
상위 폴더의 `CLAUDE.md` 등을 프로젝트 맥락으로 읽어 A/B 모두 오염됩니다.

## 문서

| 문서 | 내용 |
|---|---|
| [docs/isolation.md](docs/isolation.md) | 격리 원리: Claude Code가 자동으로 읽는 것과 각각을 막는 방법, 막지 못하는 것 |
| [docs/usage.md](docs/usage.md) | 단계별 상세 사용법: 실험 준비, B 구성 3가지, 나란히 실행, 반복 측정, 보고서 |
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
| `open-both.ps1`의 Windows Terminal 분할, `--plugin-dir` 실제 로드, B `skills\` 인식 | **미확인** - 첫 실험에서 `/plugin`, `/context`로 확인 필요 |
