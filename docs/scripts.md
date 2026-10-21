# 스크립트 참고

모든 스크립트는 저장소 폴더에서 `.\이름.ps1`로 실행합니다. 공용 함수는 `lib\common.ps1`에 있습니다.

## setup.ps1

처음 한 번. A 설정 폴더와 이 PC 전용 설정을 만들고 `doctor.ps1`을 실행합니다.

| 옵션 | 기본값 | 설명 |
|---|---|---|
| `-WorkRoot <경로>` | `<드라이브>:\cc-ab-work` | 작업 폴더 루트. 저장소 밖이어야 함 |
| `-DefaultModel <모델>` | `claude-opus-5-5` | 새 실험의 기본 모델 |

`config-vanilla\settings.json`이 이미 있으면 덮어쓰지 않습니다. 옵션을 주면 `lab.local.json`을 갱신합니다.

## login.ps1

| 사용 | 동작 |
|---|---|
| `.\login.ps1` | A(`config-vanilla`) 로그인. 이미 돼 있으면 상태만 표시 |
| `.\login.ps1 -Exp <이름>` | 그 실험의 B(`config-B`) 로그인 |
| `.\login.ps1 [-Exp <이름>] -Logout` | 로그아웃 |

내부적으로 `claude auth status`(JSON)로 상태를 확인하고 `claude auth login`을 실행합니다.

## doctor.ps1

| 사용 | 점검 범위 |
|---|---|
| `.\doctor.ps1` | 공용 환경 + A |
| `.\doctor.ps1 -Exp <이름>` | 위 + 그 실험의 B |

점검 항목:

- `claude` 명령과 버전, Windows Terminal 유무
- 관리형 설정 파일 유무
- `ANTHROPIC_*`, `CLAUDE_*` 환경 변수(값은 표시하지 않음)
- `empty-mcp.json`이 비어 있는지
- 작업 폴더 루트가 저장소 밖인지, 상위에 `CLAUDE.md`·`.claude`·`.mcp.json`·`.git`이 없는지
- A/B `settings.json`의 `syncClaudeAiPlugins`·`syncClaudeAiSkills`, `hooks`·`enabledPlugins`·`mcpServers`·`env` 항목
- A/B 로그인 상태(방식·요금제)
- A 설정 폴더의 `agents\`, `commands\`, `CLAUDE.md`
- B: 실습 원본이 비었는지, 플러그인 폴더의 `.claude-plugin\plugin.json`, 스킬 폴더의 `SKILL.md`, `/plugin` 설치 기록, `mcp-B.json` 서버, 지시문 목록, 확인 명령
- B: A/B 작업 폴더에 남은 자동 메모리
- A/B 동등성: 계정·요금제, 계정 스킬 목록, settings.json(enabledPlugins·theme 제외), 설정 폴더에 직접 넣은 파일, `.claude.json`의 작업 폴더별 권한·MCP

결과 등급: `[OK]` 정상 · `[정보]` 확인만 · `[주의]` 비교에 영향 가능 · `[오류]` 고쳐야 함.

## new-exp.ps1

| 옵션 | 필수 | 설명 |
|---|---|---|
| `-Name <이름>` | O | 실험 이름(`A-Z a-z 0-9 . _ -`) |
| `-Description <설명>` | | `experiment.json`, `NOTES.md`에 기록 |
| `-Model <모델>` | | 생략 시 `defaultModel` |
| `-FixtureFrom <경로>` | | 실습 원본으로 복사할 폴더 |

이미 있는 이름이면 중단합니다.

## list-exp.ps1

실험별 `Name`, `Model`, `Plugins`(plugins\ 폴더), `Skills`(skills\ 폴더), `Installed`(B에 /plugin 설치 기록),
`Prompts` 수, `Results` 수, `BLogin`(B 로그인 파일 유무), `Description`을 표로 보여 줍니다.

## start.ps1

| 옵션 | 필수 | 설명 |
|---|---|---|
| `-Exp <이름>` | O | 실험 |
| `-Side A\|B` | O | 실행할 쪽 |
| `-Model <모델>` | | 실험 기본 모델 대신 |
| `-PermissionMode <모드>` | | `manual`, `acceptEdits`, `auto`, `plan`, `dontAsk`, `bypassPermissions` |
| `-PrintLaunchJson` | | 실행하지 않고 `{"experiment","side","model","config","work","args","warnings"}` JSON 한 줄을 출력(GUI 앱이 사용) |

- 작업 폴더가 없으면 실습 원본에서 만듭니다(있으면 그대로 이어서 작업).
- B는 실행 전에 `skills\` → `config-B\skills\`를 맞춥니다. 계정 스킬이 저장되는 `config-B\skills\synced\`, `.trash\`는 건드리지 않습니다.
- 실행 인자: `--model <모델> --strict-mcp-config --mcp-config <A:empty-mcp.json | B:mcp-B.json> [--permission-mode] [B: --plugin-dir ...]`
- 끝나면 창의 `CLAUDE_CONFIG_DIR`, 위치, 창 제목을 원래대로 되돌립니다.

## open-both.ps1

| 옵션 | 설명 |
|---|---|
| `-Exp <이름>` | 필수 |
| `-Model`, `-PermissionMode` | 양쪽에 똑같이 전달 |
| `-NoReset` | 작업 폴더를 초기화하지 않음 |

`wt -w new new-tab ... ; split-pane -V ...`로 새 창을 좌우로 나눠 `start.ps1 -Side A`, `-Side B`를 실행합니다.

## reset.ps1

| 옵션 | 기본값 | 설명 |
|---|---|---|
| `-Exp <이름>` | 필수 | |
| `-Side A\|B\|Both` | `Both` | 초기화할 쪽 |

`robocopy fixture work-X /MIR /XF .gitkeep` — 작업 폴더에만 있는 파일은 지워집니다.
그 작업 폴더의 자동 메모리(`<설정 폴더>\projects\<경로 이름>\memory\`)도 함께 지웁니다(대화 기록은 남김).

## run-headless.ps1

| 옵션 | 기본값 | 설명 |
|---|---|---|
| `-Exp <이름>` | 필수 | |
| `-Prompt <이름\|경로>` | 필수 | `prompts\` 안 파일 이름(.md 생략 가능) 또는 파일 경로 |
| `-Runs <N>` | 3 | 쪽마다 실행 횟수(1–50) |
| `-Model <모델>` | 실험 기본 | |
| `-PermissionMode <모드>` | `acceptEdits` | `acceptEdits`, `auto`, `plan`, `dontAsk`, `bypassPermissions` |
| `-MaxBudgetUsd <금액>` | 0(제한 없음) | 실행 한 번당 `--max-budget-usd` |
| `-Side A\|B\|Both` | `Both` | 한쪽만 측정할 때 |

- PowerShell 5.1의 파이프 인코딩을 UTF-8로 바꿔 한국어 지시문을 전달하고, 끝나면 되돌립니다.
- 지시문 옆에 `<이름>.A.md` / `<이름>.B.md`가 있으면 그쪽에는 변형을 보내고 `conditions.json`의 `promptOverride`에 기록합니다.
- 시작할 때 A/B 동등성을 점검해 `conditions.json`의 `equivalence`에 남기고, 다르면 경고합니다(측정은 계속).
- `experiment.json`의 `check.command`가 있으면 매 실행 뒤 작업 폴더에서 실행해 `CheckPassed`와 `<쪽>-<회차>-check.txt`로 기록합니다.
- 결과 파일 목록은 [usage.md 6절](usage.md#6-반복-측정-근거용)을 보세요.

## report.ps1

| 옵션 | 설명 |
|---|---|
| `-Exp <이름>` | 필수 |

`results\*\summary.csv`와 `conditions.json`, `judgments.json`을 모아 `REPORT.md`를 씁니다(덮어씀).
측정마다 B 구성 기록(버전·커밋), 지시문 변형, A/B 동등성 경고, 확인 명령을 적고, 표에 "확인 통과"와 "사람 판정(통과·부분/판정)" 열을 둡니다.

## b-config.ps1

| 옵션 | 설명 |
|---|---|
| `-Exp <이름>` | 필수 |
| `-Action` | `list`(기본), `available`, `install`, `uninstall`, `enable`, `disable`, `add-marketplace`, `add-local`, `add-git`, `remove-local`, `details`, `equivalence` |
| `-Plugin <id>` | `install`·`uninstall`·`enable`·`disable`·`details` 대상(`이름@마켓플레이스`) |
| `-Source <주소>` | `add-marketplace`: owner/repo, git·https URL, 경로 |
| `-Path <폴더>` | `add-local`: 플러그인(`.claude-plugin\plugin.json`) 또는 스킬(`SKILL.md`) 폴더 |
| `-Url`, `-Ref`, `-SubPath` | `add-git`: 저장소, 태그·커밋(선택), 저장소 안 하위 경로(선택) |
| `-Kind plugin\|skill`, `-Name` | `add-local`/`add-git`에서 종류·폴더 이름 지정, `remove-local` 대상 |
| `-Json` | 결과를 JSON 한 줄로 출력(앱용) |

모든 동작은 `CLAUDE_CONFIG_DIR=<실험>\config-B`로 `claude plugin ...`을 실행하거나 실험 폴더의 `plugins\`·`skills\`를
바꿉니다. 기록은 `b-manifest.json`. 실패하면 오류 메시지와 함께 종료 코드 1.
`-Url`·`-Ref`·`-Source`가 `-`로 시작하거나 `ext::` 주소면 거부하고(git 옵션 주입 방지), git 에는 `--` 구분자를 씁니다.
`-SubPath`는 저장소 안 상대 경로만 받습니다(`..`, 드라이브, 절대 경로 거부).

## app.ps1

| 옵션 | 설명 |
|---|---|
| (없음) | GUI 앱 실행. `app\node_modules`가 없으면 `npm install` 먼저 |
| `-Dev` | 이 창에서 실행하며 F12 개발자 도구, 화면 로그 출력 |

자세한 내용은 [app.md](app.md).

## lib\common.ps1 주요 함수

| 함수 | 역할 |
|---|---|
| `Get-LabConfig` | `lab.local.json` 읽기(`WorkRoot`, `DefaultModel`) |
| `Get-Experiment` | 실험 폴더·메타 정보 |
| `Get-WorkDir` | `<workRoot>\<실험>\work-<쪽>` |
| `Get-SideLaunch` | 쪽별 설정 폴더·작업 폴더·`claude` 인자 |
| `Sync-Skills` | `skills\` → `config-B\skills\` |
| `Reset-Work` | 실습 원본 → 작업 폴더 |
| `Invoke-Mirror` | `robocopy /MIR` 래퍼(종료 코드 8 이상이면 오류). 세 번째 인자로 보존할 폴더 이름(`/XD`) |
| `Get-AuthStatus` | 설정 폴더별 `claude auth status` |
| `Find-AncestorContext` | 상위 폴더의 `CLAUDE.md` 등 찾기 |
| `Compare-Tree` | 두 폴더의 파일 해시 비교(추가/수정/삭제) |
| `Invoke-ClaudeIn` | 지정한 설정 폴더로 `claude` 명령 실행(끝나면 환경 변수 복원) |
| `Get-BManifest` / `Set-BManifestItem` / `Remove-BManifestItem` | B 구성 기록 읽기·쓰기 |
| `Get-GitInfo` | 폴더의 git 커밋·수정 여부·원격 주소 |
| `Get-SyncedSkills` | 설정 폴더의 claude.ai 계정 스킬 이름 목록 |
| `Get-Equivalence` | A/B 동등성(계정·요금제·계정 스킬·settings.json·설정 폴더 추가 파일·작업 폴더별 권한) |
| `$ClaudeCmd` / `Get-ClaudePath` | 쓸 claude 실행 파일(`CC_AB_CLAUDE`가 있으면 그것, 없으면 PATH 의 claude)과 그 경로 |
| `Get-SideConfig` | 쪽별 설정 폴더(A: config-vanilla, B: config-B) |
| `Get-ProjectSlug` / `Get-ProjectMemoryCount` / `Clear-ProjectMemory` | 작업 폴더별 기록 폴더 이름, 자동 메모리 개수·삭제 |
| `Get-ProjectEntry` | `.claude.json`의 작업 폴더별 항목 |
| `Get-ConfigExtras` | 설정 폴더에 직접 넣은 파일(CLAUDE.md, agents, commands, output-styles, skills)의 해시 |
| `Invoke-CheckCommand` | 작업 폴더에서 확인 명령 실행(제한 시간, 종료 코드 0 = 통과) |
