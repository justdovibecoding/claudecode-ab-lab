# 격리 원리

비교 실습의 신뢰도는 "A에는 정말 아무것도 없고, B에는 비교 대상만 더해졌는가"에 달려 있습니다.
이 문서는 Claude Code가 자동으로 읽는 것과, 이 도구가 그것을 어떻게 막는지 정리합니다.

## 1. Claude Code가 자동으로 읽는 것

| 위치 | 내용 | 범위 |
|---|---|---|
| `~/.claude/` | `settings.json`(권한·훅·환경 변수), `/plugin` 설치 플러그인, `skills\`, `agents\`, `commands\`, 전역 `CLAUDE.md`, 자동 메모리, 로그인 정보 | 사용자 |
| `~/.claude.json` | 사용자 범위 MCP 서버, 계정·프로젝트 상태 | 사용자 |
| claude.ai 계정 | 계정에 연결된 플러그인, 계정 스킬(pdf, docx 등), 커넥터(Notion, Google Drive 등 MCP) | 계정 |
| 작업 폴더와 **모든 상위 폴더** | `CLAUDE.md`, `CLAUDE.local.md`, `.claude\`(프로젝트 설정·스킬), `.mcp.json`, `.git` | 프로젝트 |
| 관리형 설정 | `C:\Program Files\ClaudeCode\managed-settings.json` | 시스템 |
| 환경 변수 | `ANTHROPIC_API_KEY`, `CLAUDE_CODE_*` 등 | 프로세스 |
| 프로그램 자체 | 내장 명령(`/init`, `/context` 등), 내장 플러그인(`cc-plugin-*`) | 기본 |

## 2. 각 항목을 막는 방법

### 사용자 범위 → `CLAUDE_CONFIG_DIR`

`CLAUDE_CONFIG_DIR` 환경 변수를 새 폴더로 지정하면 Claude Code는 `~/.claude` 대신 그 폴더를 씁니다.
그 폴더 안의 `settings.json`, `skills\`, `plugins\`, `.claude.json`, `.credentials.json`이 모두 따로 생깁니다.

- A: `config-vanilla\`
- B: `experiments\<이름>\config-B\`

평소 쓰는 `~/.claude`는 전혀 건드리지 않습니다. 스크립트(`start.ps1`, `run-headless.ps1`, `login.ps1`)는
실행이 끝나면 현재 창의 `CLAUDE_CONFIG_DIR`을 원래 값으로 되돌립니다.

로그인 정보도 설정 폴더 안에 저장되므로 **설정 폴더마다 한 번씩 로그인**해야 합니다.
로그인 파일을 복사해 쓰지 않는 이유는, 한쪽이 토큰을 갱신하면 다른 쪽 토큰이 무효가 될 수 있기 때문입니다.

### 계정 플러그인 → `syncClaudeAiPlugins: false`

설정 폴더를 비워도 같은 계정으로 로그인하면 claude.ai 계정에 연결된 플러그인이 동기화되어 들어옵니다.
`/plugin`의 Installed 탭에서 `User` 구역에 `synced`로 표시되는 항목입니다.
`templates\settings.json`에 들어 있는 다음 설정이 이를 막습니다.

```json
{ "syncClaudeAiPlugins": false }
```

- 사용자 설정(`<설정 폴더>\settings.json`), `.claude\settings.local.json`, 관리형 설정에서만 유효합니다.
  공유 프로젝트 설정(`.claude\settings.json`)에서는 무시됩니다.
- 이미 동기화된 플러그인은 다음 시작 때 해당 설정 폴더의 `plugins\.trash\`로 옮겨집니다.
- 공식 문서: https://code.claude.com/docs/en/settings-reference#syncclaudeaiplugins

### 계정 스킬 → 기본은 포함

`pdf`, `docx`, `xlsx`, `skill-creator` 같은 claude.ai 계정 스킬(`/plugin` Skills 구역의 `claude.ai sync`)은
같은 계정을 쓰는 일반 사용자도 보게 되는 환경이라 **A/B 모두에 남겨 두는 것이 기본값**입니다.

다음 경우에는 끄는 것이 맞습니다.

- 비교 대상이 이 스킬들과 겹칠 때(예: 문서 생성 스킬 비교, 스킬 제작 도구 비교).
  동기화된 `docx`나 `skill-creator`가 대신 불려 와 결과를 흐립니다.
- "Claude Code 단독"을 기준으로 삼고 싶을 때.

끄는 방법: `templates\settings.json`(새 실험용)과 `config-vanilla\settings.json`, 기존 실험의
`config-B\settings.json`에 `"syncClaudeAiSkills": false`를 추가합니다.

### 계정 커넥터(MCP) → `--strict-mcp-config`

claude.ai 커넥터는 로그인한 계정을 따라옵니다. 스크립트는 항상 다음 인자로 실행합니다.

- A: `--strict-mcp-config --mcp-config empty-mcp.json` → MCP 서버 없음
- B: `--strict-mcp-config --mcp-config experiments\<이름>\mcp-B.json` → 적은 서버만

`--strict-mcp-config`는 `--mcp-config`로 준 서버만 쓰게 합니다. 비교 대상 플러그인이 MCP 서버를 쓰는데
막힌다면 그 서버 정의를 `mcp-B.json`에 넣으세요.

> PowerShell에서 `--mcp-config '{"mcpServers":{}}'`처럼 JSON 문자열을 직접 넘기면
> 따옴표가 깨져 "MCP config file not found" 오류가 납니다. 그래서 항상 파일로 넘깁니다.

### 프로젝트 범위 → 저장소 밖 작업 폴더

Claude Code는 작업 폴더에서 드라이브 루트까지 올라가며 `CLAUDE.md` 등을 찾습니다.
작업 폴더를 이 저장소 안에 두면 저장소의 `.git`이 프로젝트로 잡히고, 상위 폴더의 `CLAUDE.md`도 읽힙니다.
그래서 작업 폴더는 `lab.local.json`의 `workRoot`(기본 `<드라이브>:\cc-ab-work`)에 만듭니다.

- `doctor.ps1`과 `start.ps1`은 작업 폴더 상위에 `CLAUDE.md`, `CLAUDE.local.md`, `.claude`, `.mcp.json`, `.git`이
  있으면 경고합니다.
- 실습 원본(`fixture\`) 안의 `CLAUDE.md`나 `.claude\`는 **의도한 프로젝트 맥락**이므로 A/B 모두에 똑같이 들어갑니다.
  비교 대상 스킬을 `fixture\.claude\skills\`에 넣으면 A에도 들어가니 넣지 마세요.

### 작업 폴더별 기록 → 초기화 때 메모리 삭제, 권한은 동등성 점검

설정 폴더를 분리해도, 랩의 설정 폴더 안에는 실행할 때마다 작업 폴더별 기록이 새로 쌓입니다.

| 위치 | 내용 | 처리 |
|---|---|---|
| `<설정 폴더>\projects\<경로 이름>\memory\` | 자동 메모리. 다음 세션이 읽음 | 작업 폴더 초기화(`Reset-Work`: reset, 반복 측정 매 회차, 앱의 "작업 폴더 초기화") 때 삭제. 남아 있으면 `doctor.ps1 -Exp`가 경고 |
| `<설정 폴더>\projects\<경로 이름>\*.jsonl` | 대화 기록. 자동으로 읽히지 않음(`--resume` 할 때만) | 남김 |
| `<설정 폴더>\.claude.json`의 `projects["D:/…/work-A"]` | "항상 허용"한 도구, MCP 사용 여부, 폴더 신뢰 | 동등성 점검에서 A/B 비교(신뢰 여부는 대화형 첫 화면에만 영향이라 제외) |

`<경로 이름>`은 작업 폴더 경로의 영문·숫자 외 문자를 모두 `-`로 바꾼 것입니다(`D:\cc-ab-work\x\work-A` → `D--cc-ab-work-x-work-A`).
작업 폴더 경로가 아주 길면 Claude Code가 이름을 다르게 줄일 수 있으니 `workRoot`는 짧게 두세요.

### 관리형 설정·환경 변수 → 점검만

이 두 가지는 설정 폴더로 막을 수 없고 A/B 모두에 똑같이 적용됩니다. `doctor.ps1`이 있는지 알려 줍니다.

- 특히 `ANTHROPIC_API_KEY`가 설정돼 있으면 구독 대신 API 과금으로 실행될 수 있습니다.
- Claude Code 세션 **안에서** 스크립트를 실행하면 `CLAUDECODE`, `CLAUDE_CODE_SESSION_ID` 같은 변수가 보입니다.
  비교 실행은 일반 터미널에서 하세요.

## 3. `--bare`를 쓰지 않는 이유

`claude --bare`는 훅, 플러그인 동기화, 자동 메모리, `CLAUDE.md` 자동 탐색 등을 끄는 **최소 모드**입니다.
일반 사용자의 기본 환경보다 기능이 적어 "기본"의 기준으로 쓰기 어렵고, OAuth 로그인을 쓰지 않고
`ANTHROPIC_API_KEY`(또는 `apiKeyHelper`)만 받습니다. 그래서 이 도구는 `CLAUDE_CONFIG_DIR` 방식을 씁니다.

## 4. 실행 화면에서 확인하는 법 (녹화 첫 장면 추천)

| 명령 | A에서 기대하는 모습 | B에서 기대하는 모습 |
|---|---|---|
| `/plugin` → Installed | Built-in(`cc-plugin-*`)만, 계정 스킬(`claude.ai sync`) | A + 비교 대상 플러그인 |
| `/mcp` | 서버 없음 | `mcp-B.json`에 적은 서버만 |
| `/memory` | 불러온 `CLAUDE.md` 없음(실습 원본에 있으면 그것만) | A와 같음 |
| `/context` | 스킬·메모리·MCP 도구 목록과 토큰 | A + 비교 대상, 토큰 차이 |
| `/status` | 로그인 방식, 설정 폴더 | 같음 |

`/context`는 A와 B의 차이가 한 화면에 가장 잘 드러나 영상에 쓰기 좋습니다.
