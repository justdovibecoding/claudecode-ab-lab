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
- B: 실습 원본이 비었는지, 플러그인 폴더의 `.claude-plugin\plugin.json`, 스킬 폴더의 `SKILL.md`, `/plugin` 설치 기록, `mcp-B.json` 서버, 지시문 목록

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

- 작업 폴더가 없으면 실습 원본에서 만듭니다(있으면 그대로 이어서 작업).
- B는 실행 전에 `skills\` → `config-B\skills\`를 맞춥니다.
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
- 결과 파일 목록은 [usage.md 6절](usage.md#6-반복-측정-근거용)을 보세요.

## report.ps1

| 옵션 | 설명 |
|---|---|
| `-Exp <이름>` | 필수 |

`results\*\summary.csv`와 `conditions.json`을 모아 `REPORT.md`를 씁니다(덮어씀).

## lib\common.ps1 주요 함수

| 함수 | 역할 |
|---|---|
| `Get-LabConfig` | `lab.local.json` 읽기(`WorkRoot`, `DefaultModel`) |
| `Get-Experiment` | 실험 폴더·메타 정보 |
| `Get-WorkDir` | `<workRoot>\<실험>\work-<쪽>` |
| `Get-SideLaunch` | 쪽별 설정 폴더·작업 폴더·`claude` 인자 |
| `Sync-Skills` | `skills\` → `config-B\skills\` |
| `Reset-Work` | 실습 원본 → 작업 폴더 |
| `Invoke-Mirror` | `robocopy /MIR` 래퍼(종료 코드 8 이상이면 오류) |
| `Get-AuthStatus` | 설정 폴더별 `claude auth status` |
| `Find-AncestorContext` | 상위 폴더의 `CLAUDE.md` 등 찾기 |
| `Compare-Tree` | 두 폴더의 파일 해시 비교(추가/수정/삭제) |
