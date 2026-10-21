# 문제 해결

## 스크립트를 실행할 수 없음

```
.\setup.ps1 : File ... cannot be loaded because running scripts is disabled on this system.
```

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

## 한국어가 깨짐

- 스크립트 파일은 **UTF-8 BOM**으로 저장되어 있어야 Windows PowerShell 5.1이 한국어를 제대로 읽습니다.
  편집기에서 "UTF-8 with BOM"으로 저장하세요. `.gitattributes`가 줄바꿈을 CRLF로 맞춥니다.
- JSON 파일(`settings.json`, `mcp-B.json` 등)은 **BOM 없는 UTF-8**이 안전합니다.
  PowerShell 5.1의 `Set-Content -Encoding utf8`은 BOM을 붙이니 쓰지 마세요.
- 헤드리스 지시문이 `???`로 전달된다면 `run-headless.ps1`을 거치지 않고 직접 파이프한 경우입니다.
  직접 할 때는 먼저 `$OutputEncoding = [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false`.

## `MCP config file not found: ...{"mcpServers":{}}`

PowerShell에서 JSON 문자열을 `--mcp-config`에 직접 넘겨 따옴표가 깨진 경우입니다. 파일 경로로 넘기세요.
스크립트는 항상 `empty-mcp.json`, `mcp-B.json` 파일을 씁니다.

## A에 플러그인이나 커넥터가 보임

- `/plugin`의 `User` 구역에 `synced` 항목이 있으면: `config-vanilla\settings.json`에 `"syncClaudeAiPlugins": false`가 있는지 확인하고 Claude Code를 다시 시작합니다.
- `/mcp`에 커넥터가 보이면: `start.ps1`을 거치지 않고 `claude`를 직접 실행한 경우입니다(`--strict-mcp-config` 누락).
- 평소 환경의 플러그인이 보이면: `CLAUDE_CONFIG_DIR`이 적용되지 않은 것입니다. `/status`에서 설정 폴더를 확인하세요.

## B에 플러그인·스킬이 안 보임

- `plugins\<이름>\.claude-plugin\plugin.json`이 있는지 확인합니다. 한 단계 더 깊은 폴더를 넣은 경우가 많습니다(`doctor.ps1 -Exp`가 알려 줌).
- 스킬은 `skills\<이름>\SKILL.md` 구조여야 하고, frontmatter에 `name`과 `description`이 있어야 합니다.
- 스킬을 `config-B\skills\`에 직접 넣었다면 다음 실행 때 지워집니다. 실험 폴더의 `skills\`에 넣으세요.
- B 화면의 `/plugin` → Errors 탭에 불러오기 오류가 나옵니다.

## 로그인 관련

- 실험마다 B 로그인이 필요합니다: `.\login.ps1 -Exp <이름>`.
- 상태 확인: `.\doctor.ps1 -Exp <이름>` 또는

  ```powershell
  $env:CLAUDE_CONFIG_DIR = '<설정 폴더>'; claude auth status; Remove-Item env:CLAUDE_CONFIG_DIR
  ```
- `ANTHROPIC_API_KEY` 환경 변수가 있으면 구독 대신 API 키가 쓰일 수 있습니다. `doctor.ps1`이 알려 줍니다.

## 평소 `claude`가 이상하게 동작함 (설정이 사라진 것처럼)

현재 창에 `CLAUDE_CONFIG_DIR`이 남아 있을 수 있습니다. 스크립트는 끝날 때 되돌리지만,
직접 `$env:CLAUDE_CONFIG_DIR = ...`을 설정했다면 다음으로 지우세요.

```powershell
Remove-Item env:CLAUDE_CONFIG_DIR
```

## `open-both.ps1`이 창을 띄우지 않음

- `wt` 명령이 없으면 PowerShell 창 2개로 띄웁니다. Microsoft Store에서 Windows Terminal을 설치하면 분할 화면으로 열립니다.
- 창이 열렸다가 바로 닫히면 `.\start.ps1 -Exp <이름> -Side A`를 직접 실행해 오류를 확인하세요.

## 헤드리스 실행이 실패함

| 증상 | 원인과 해결 |
|---|---|
| `IsError=True`, `Subtype`에 예산 관련 값 | `-MaxBudgetUsd`를 넘음. 한도를 올리거나 과제를 줄임 |
| 파일이 안 바뀜, 응답에 "권한" 언급 | 필요한 명령이 권한 모드에서 거부됨. `-PermissionMode auto` 또는 `bypassPermissions`(A/B 같게) |
| `Subtype = JSON 해석 실패` | `A-1.json`을 열어 원본 출력 확인. 로그인 만료, 네트워크 오류 등 |
| `지시문이 비어 있습니다` | 지시문 파일에 주석만 있음. 주석을 지우고 내용 작성 |

## `복사 실패 (robocopy N)`

robocopy 종료 코드 8 이상은 실패입니다. 작업 폴더의 파일이 다른 프로그램(편집기, 실행 중인 Claude Code, 개발 서버)에
잡혀 있는 경우가 대부분입니다. 해당 프로그램을 닫고 다시 실행하세요.

## 작업 폴더 상위 경고

```
작업 폴더 상위에 Claude Code가 읽을 수 있는 항목: ...
```

작업 폴더 루트를 그 항목이 없는 위치로 옮기세요.

```powershell
.\setup.ps1 -WorkRoot E:\cc-ab-work
```

사용자 홈 폴더 아래를 고르면 `C:\Users\<이름>\.claude`가 잡힙니다. 드라이브 루트 바로 아래를 권장합니다.
