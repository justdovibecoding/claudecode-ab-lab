# 상세 사용법

모든 명령은 저장소 폴더에서 실행합니다.

```powershell
cd D:\_dzp\VIBE_CODING\claudecode-ab-lab
```

비교 실행은 **일반 터미널**(Windows Terminal, PowerShell 창)에서 하세요. Claude Code 세션 안에서 실행하면
그 세션의 환경 변수가 섞입니다.

---

## 1. 처음 설정 (PC당 한 번)

### 1-1. 스크립트 실행 허용

```powershell
Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
```

### 1-2. `setup.ps1`

```powershell
.\setup.ps1
# 작업 폴더 위치나 기본 모델을 바꾸려면
.\setup.ps1 -WorkRoot E:\cc-ab-work -DefaultModel claude-sonnet-5-5
```

하는 일:

1. `config-vanilla\settings.json`을 `templates\settings.json`에서 만듭니다(이미 있으면 그대로 둠).
2. `lab.local.json`에 `workRoot`(작업 폴더 위치)와 `defaultModel`을 저장합니다.
3. `experiments\`와 작업 폴더 루트를 만듭니다.
4. `doctor.ps1`로 점검합니다.

`workRoot`는 **이 저장소 밖**이어야 하고, 상위 폴더에 `CLAUDE.md`나 `.git`이 없는 곳이 좋습니다.
기본값 `<드라이브>:\cc-ab-work`가 대부분 적당합니다.

### 1-3. A 기본 환경 로그인

```powershell
.\login.ps1
```

브라우저가 열리면 평소 계정으로 로그인합니다. 로그인 정보는 `config-vanilla\.credentials.json`에 저장되고,
평소 쓰는 `~/.claude` 로그인과는 별개입니다.

---

## 2. 실험 만들기

```powershell
.\new-exp.ps1 -Name superpowers -Description "superpowers 플러그인 유무 비교"
.\new-exp.ps1 -Name pdf-skill -Description "PDF 스킬 비교" -FixtureFrom D:\some\project -Model claude-sonnet-5-5
```

- `-Name`: 영문·숫자·`.`·`_`·`-`만 씁니다. 폴더 이름이 됩니다.
- `-FixtureFrom`: 실습 원본으로 쓸 폴더를 통째로 복사합니다(`.git` 포함). 생략하면 빈 `fixture\`.
- `-Model`: 이 실험의 기본 모델. 생략하면 `lab.local.json`의 `defaultModel`.

만들어지는 것:

```
experiments\superpowers\
├─ experiment.json   {"name","description","model","createdAt","check":{"command":"","timeoutSec":600}}
├─ NOTES.md          기록 양식
├─ fixture\          실습 원본
├─ plugins\          B 전용 플러그인
├─ skills\           B 전용 스킬
├─ prompts\01-task.md  지시문 양식
├─ mcp-B.json        {"mcpServers": {}}
├─ config-B\settings.json   templates\settings.json 복사본
└─ results\
(나중에 생기는 것: b-manifest.json — B 구성 기록, sessions\ — 앱 대화형 기록, REPORT.md — 보고서)
```

- 실험 이름은 영문·숫자·`._-`만 씁니다(`.`·`..`처럼 점으로만 된 이름은 거부). 지시문 파일 이름은 한글도 됩니다.

### 실습 원본(`fixture\`) 고르기

- 결과를 눈으로 확인할 수 있는 작은 프로젝트가 좋습니다(예: 테스트가 있는 작은 앱, 고칠 버그가 있는 저장소).
- 실습 원본에 git 저장소가 있으면 결과 비교 때 작업 폴더에서 `git diff`로 변경 내용을 보기 쉽습니다.
- 매 실행 전 작업 폴더는 `fixture\`와 똑같이 맞춰지므로(`robocopy /MIR`) 원본은 바뀌지 않습니다.

---

## 3. B에 비교 대상 넣기

어떤 방법이든 **A에는 들어가지 않습니다.** 가장 쉬운 방법은 앱의 **B 구성** 화면이나 `b-config.ps1`입니다.

### 방법 0. `b-config.ps1` (앱의 "B 구성" 화면과 같은 기능)

```powershell
.\b-config.ps1 -Exp superpowers                                   # 현재 B 구성
.\b-config.ps1 -Exp superpowers -Action available                 # 설치 가능한 플러그인(공식 목록 포함)
.\b-config.ps1 -Exp superpowers -Action install -Plugin superpowers@anthropic-plugin-directory
.\b-config.ps1 -Exp superpowers -Action details -Plugin superpowers@anthropic-plugin-directory   # 구성 요소·예상 토큰
.\b-config.ps1 -Exp superpowers -Action disable -Plugin <id>      # enable 도 같은 방식
.\b-config.ps1 -Exp superpowers -Action uninstall -Plugin <id>
.\b-config.ps1 -Exp superpowers -Action add-marketplace -Source owner/repo
.\b-config.ps1 -Exp superpowers -Action add-local -Path D:\src\my-plugin      # 플러그인/스킬 자동 판별
.\b-config.ps1 -Exp superpowers -Action add-git -Url https://github.com/o/r -Ref v1.2 -SubPath plugins/x
.\b-config.ps1 -Exp superpowers -Action remove-local -Kind skill -Name my-skill
```

- 설치·추가할 때마다 `experiments\<이름>\b-manifest.json`에 **종류·이름·버전·출처·커밋**이 기록되고, 반복 측정의
  `conditions.json`과 보고서의 "B 구성" 아래에 그대로 붙습니다. 같은 버전으로 다시 찍을 때 근거가 됩니다.
- 로컬 폴더가 git 저장소 안이면 커밋과 "수정본" 여부를 함께 기록합니다. Git 추가는 지정한 태그·커밋으로 받습니다.
- `details`의 "항상 추가되는 토큰"은 B가 매 세션 컨텍스트를 얼마나 늘리는지 보여 줍니다(추정치).
- B 터미널에서 `/plugin`으로 직접 설치한 것도 목록에 나오지만 출처가 기록되지 않아 "기록 없음"으로 표시됩니다.
- 플러그인 설치는 `config-B\plugins\cache\` 아래로 git 복제를 하므로, 저장소 경로가 길면 Windows 경로 길이 제한에
  걸릴 수 있습니다([troubleshooting.md](troubleshooting.md)).

아래 방법 1–3은 같은 일을 손으로 하는 방법입니다.

### 방법 1. 플러그인 폴더 넣기 (`plugins\`, 설치 없이)

```
experiments\superpowers\plugins\superpowers\
├─ .claude-plugin\plugin.json
├─ skills\...
├─ agents\...
└─ hooks\...
```

- 플러그인 저장소를 내려받아 **플러그인 최상위 폴더**(`.claude-plugin\plugin.json`이 있는 폴더)를 `plugins\` 아래에 둡니다.
- `start.ps1 -Side B`와 `run-headless.ps1`이 `plugins\` 아래 폴더마다 `--plugin-dir <폴더>`를 붙여 실행합니다.
- 이번 실행에만 불러오므로 설치 기록이 남지 않습니다. 버전을 고정하기 쉽고(폴더째 보관), 여러 실험에서 버전을 달리 비교하기 좋습니다.
- 마켓플레이스 저장소처럼 한 저장소에 플러그인이 여러 개 있으면 비교할 플러그인 폴더만 넣습니다.
- `doctor.ps1 -Exp <이름>`이 `.claude-plugin\plugin.json` 유무를 확인합니다.

### 방법 2. 스킬 폴더 넣기 (`skills\`)

```
experiments\my-skill\skills\commit-helper\SKILL.md
```

```markdown
---
name: commit-helper
description: 커밋 메시지를 작성할 때 사용한다. ...
---

(스킬 본문)
```

- B를 실행할 때마다 `skills\`가 `config-B\skills\`로 똑같이 맞춰집니다(원본은 실험 폴더 쪽).
  그래서 `config-B\skills\`에 직접 넣은 스킬은 다음 실행 때 지워집니다.
- B의 사용자 스킬로 들어가므로 이름 앞에 플러그인 접두어가 붙지 않습니다(`/commit-helper`).
- 처음 쓸 때 B 화면의 `/context`나 `/plugin` Skills 구역에서 스킬이 보이는지 확인하세요.

### 방법 3. B에서 `/plugin`으로 정식 설치

```powershell
.\start.ps1 -Exp superpowers -Side B
# Claude Code 화면에서 /plugin → Marketplaces 추가 → Discover → 설치
```

- 설치 과정을 영상에 담을 때 좋습니다.
- 설치 정보는 `config-B\plugins\`와 `config-B\settings.json`(`enabledPlugins`)에 저장되어 그 실험에만 남습니다.
- `list-exp.ps1`의 `Installed` 열과 `doctor.ps1`이 설치 기록 유무를 알려 줍니다.
- 설치한 플러그인 이름·버전은 `NOTES.md`의 "B에 넣은 것" 표에 직접 적어 두세요(재현용).

### 방법 4(보조). B 전용 MCP 서버 (`mcp-B.json`)

```json
{
  "mcpServers": {
    "context7": { "type": "http", "url": "https://mcp.context7.com/mcp" },
    "local-tool": { "command": "npx", "args": ["-y", "some-mcp-server"] }
  }
}
```

비교 대상이 MCP 서버이거나, 플러그인이 MCP 서버를 써야 할 때 씁니다. A는 항상 `empty-mcp.json`입니다.

### B 로그인 (실험마다 한 번)

```powershell
.\login.ps1 -Exp superpowers
```

### 점검

```powershell
.\doctor.ps1 -Exp superpowers
```

`[주의]`, `[오류]`가 없도록 정리한 뒤 다음 단계로 넘어갑니다. `[정보]`는 확인만 하면 됩니다.

---

## 4. 지시문 쓰기 (`prompts\*.md`)

```
experiments\superpowers\prompts\01-task.md
experiments\superpowers\prompts\02-bugfix.md
```

- 파일 하나가 지시문 하나입니다. 여러 개를 만들어 과제별로 비교할 수 있습니다.
- `<!-- -->` 주석은 지우세요(주석만 있으면 `run-headless.ps1`이 실행을 거부합니다).
- **비교 대상 이름을 지시문에 직접 쓰지 않습니다.** "superpowers 스킬로 해줘"는 A에 없는 것을 요구해 불공정합니다.
  스킬이 스스로 불려 오는지까지가 비교 대상입니다.
- 완료 조건을 분명히 적습니다(예: "`npm test`가 모두 통과하면 끝"). 결과 판정이 쉬워집니다.
- 사람에게 되묻지 않고 끝까지 진행하도록 적어 두면 헤드리스 실행에서 중간에 멈추지 않습니다.

### 쪽별 변형 지시문 (`<이름>.A.md`, `<이름>.B.md`)

스킬은 이름을 지시문에 적어야 쓰이는 경우가 있습니다. 그럴 때는 공통 지시문 옆에 변형 파일을 둡니다.

```
prompts\01-task.md      README를 읽고 요약해줘
prompts\01-task.B.md    README를 읽고 요약해줘 (superpowers 스킬을 사용해줘)
```

- `run-headless.ps1 -Prompt 01-task`는 B에 `01-task.B.md` 내용을 보냅니다. A 변형 파일이 없으면 A는 공통 지시문.
- 결과 폴더에 `prompt.B.md`가 함께 저장되고, `conditions.json`의 `promptOverride`에 `["B"]`, 보고서에 "지시문 변형" 경고가 붙습니다.
- GUI 앱의 "지시문 불러오기"도 같은 규칙으로 B 예비 입력창을 채웁니다.
- 변형은 비교 조건을 바꾸므로 공통 문장은 그대로 두고 **덧붙이기만** 하는 것을 권합니다(GUI 배너의 "호출 문구").

---

## 5. 나란히 실행 (녹화용)

> GUI 앱(`.\app.ps1`)을 쓰면 한 창 안에서 A/B를 띄우고 예비 입력창·공정성 배너·전송 기록까지 함께 쓸 수 있습니다.
> 자세한 내용은 [app.md](app.md). 아래는 Windows Terminal로 띄우는 방법입니다.

```powershell
.\open-both.ps1 -Exp superpowers
.\open-both.ps1 -Exp superpowers -NoReset                # 작업 폴더를 지우지 않고
.\open-both.ps1 -Exp superpowers -PermissionMode acceptEdits
.\open-both.ps1 -Exp superpowers -Model claude-sonnet-5-5
```

1. 작업 폴더 A/B를 `fixture\` 상태로 초기화합니다(`-NoReset`이면 생략).
2. Windows Terminal 새 창을 좌우로 나눠 왼쪽 `A 기본`, 오른쪽 `B 비교`를 띄웁니다.
   Windows Terminal이 없으면 PowerShell 창 2개를 띄웁니다.
3. 각 창 위쪽에 설정 폴더, 작업 폴더, 실제 `claude` 실행 인자가 출력됩니다(영상 근거로 그대로 보여 주기 좋음).

진행 순서 추천:

1. 양쪽에서 `/context`를 열어 A/B 차이를 보여 줍니다.
2. `prompts\01-task.md` 내용을 양쪽에 붙여 넣고 거의 동시에 Enter를 누릅니다.
3. 권한 확인 창이 뜨면 양쪽에 같은 답을 합니다(또는 `-PermissionMode acceptEdits`로 통일).
4. 끝나면 양쪽에서 `/cost` 또는 `/context`로 사용량을 보여 줍니다.
5. 다른 창에서 결과물을 비교합니다: `<workRoot>\superpowers\work-A`, `work-B`.

한쪽만 다시 열 때:

```powershell
.\start.ps1 -Exp superpowers -Side B
.\reset.ps1 -Exp superpowers -Side B   # 그쪽 작업 폴더만 초기화
```

---

## 6. 반복 측정 (근거용)

화면 비교는 한 번의 결과라 운이 섞입니다. 영상에 숫자를 넣는다면 반복 측정 결과를 쓰세요.

```powershell
.\run-headless.ps1 -Exp superpowers -Prompt 01-task                  # 기본 3회
.\run-headless.ps1 -Exp superpowers -Prompt 01-task -Runs 5 -MaxBudgetUsd 2
.\run-headless.ps1 -Exp superpowers -Prompt 01-task -PermissionMode bypassPermissions
.\run-headless.ps1 -Exp superpowers -Prompt D:\prompts\custom.md -Side B   # B만
```

동작:

- 회차마다 A/B를 번갈아 실행합니다. 홀수 회차는 A→B, 짝수 회차는 B→A(순서 효과 완화).
- 실행 직전마다 그쪽 작업 폴더를 `fixture\`로 초기화하고, 그 작업 폴더의 **자동 메모리**도 지웁니다
  (`conditions.json`의 `memoryReset: true`). 남겨 두면 2회차부터 이전 회차가 배운 내용을 안고 시작해 회차가 독립 표본이 아닙니다.
- `claude -p --output-format json --permission-mode <모드> --model <모델> --strict-mcp-config --mcp-config <구성> [--plugin-dir ...] [--max-budget-usd N]`로 실행합니다.

권한 모드(`-PermissionMode`):

| 모드 | 의미 | 쓰임 |
|---|---|---|
| `acceptEdits` (기본) | 파일 수정은 자동 허용, 그 밖에 확인이 필요한 명령은 거부 | 파일 수정 위주 과제 |
| `auto` | 분류기가 안전하다고 본 작업은 자동 허용 | 명령 실행이 필요한 과제 |
| `bypassPermissions` | 확인 없이 모두 실행 | 테스트 실행 등이 꼭 필요하고 원본을 믿을 수 있을 때만 |
| `plan` | 계획만 세우고 실행하지 않음 | 계획 품질 비교 |

헤드리스에는 사람이 없어 확인 창에 답할 수 없습니다. 과제에 필요한 권한이 막히면 결과가 실패로 나오니,
A/B에 **같은 모드**를 쓰는 한에서 과제에 맞는 모드를 고르세요.

결과 폴더 `experiments\<이름>\results\<날짜-시간>-<지시문>\`:

| 파일 | 내용 |
|---|---|
| `conditions.json` | 실험, 지시문, 변형을 받은 쪽(`promptOverride`), 회차, 모델, 권한 모드, 예산 한도, B 구성(플러그인·스킬·설치 여부·MCP·`bManifest`), 확인 명령(`check`), A/B 동등성(`equivalence`), Claude Code 버전, 시작 시각 |
| `A-1-check.txt` … | 확인 명령의 결과와 출력(확인 명령이 있을 때) |
| `judgments.json` | 블라인드 판정(섞인 순서와 답안별 판정·메모). 앱에서 판정하면 생김 |
| `prompt.md`, `prompt.A.md`, `prompt.B.md` | 사용한 지시문 사본(변형이 있을 때만 쪽별 파일) |
| `A-1.json` … | `claude -p` JSON 원본 |
| `A-1-result.md` … | 최종 응답 텍스트 |
| `A-1-changes.txt` … | 실습 원본 대비 바뀐 파일(`A` 추가 / `M` 수정 / `D` 삭제, `.git` 제외) |
| `A-1-work\` … | 실행 직후 작업 폴더 사본 |
| `summary.csv` | 실행별 Exit, IsError, Subtype, CostUSD, Turns, Seconds, 토큰, ChangedFiles, SessionId |

---

### 품질 확인 명령

`experiments\<이름>\experiment.json`의 `check`에 명령을 적으면(앱의 "반복 측정" 화면에서도 편집 가능),
매 실행 뒤 결과물 사본을 뜬 다음 **작업 폴더에서** `cmd.exe`로 실행해 종료 코드 0이면 통과로 기록합니다.

```json
"check": { "command": "npm test", "timeoutSec": 600 }
```

- 실행별 `<쪽>-<회차>-check.txt`(명령·결과·출력), `summary.csv`의 `CheckPassed`, 보고서의 "확인 통과" 열.
- 제한 시간을 넘기면 실패로 기록하고 프로세스를 끝냅니다.
- `findstr`처럼 BOM 붙은 UTF-8 파일을 못 읽는 명령이 있으니, 확인 명령은 실제 작업 폴더에서 먼저 손으로 돌려 보세요.

### A/B 동등성

반복 측정을 시작할 때 A/B 설정 폴더가 비교 대상 말고는 같은지 점검하고 `conditions.json`의 `equivalence`에 남깁니다.
다르면 경고만 하고 측정은 계속하며, 보고서에 "A/B 동등성 경고"로 표시됩니다. 보는 항목:

| 항목 | 다르면 생기는 문제 |
|---|---|
| 로그인 계정·요금제 | 계정 스킬, 사용량 한도, 모델 접근이 달라짐 |
| claude.ai 계정 스킬 목록(`skills\synced\`) | 한쪽에만 스킬이 있음. 양쪽을 한 번씩 실행하면 다시 동기화됨 |
| `settings.json`(`enabledPlugins`, `theme` 제외) | 권한 모드·훅·환경 변수 등 조건 차이 |

`.\doctor.ps1 -Exp <이름>`, `.\b-config.ps1 -Exp <이름> -Action equivalence`, 앱의 "B 구성" 화면에서도 볼 수 있습니다.

## 7. 보고서

```powershell
.\report.ps1 -Exp superpowers
```

`results\` 아래 모든 측정을 모아 `experiments\superpowers\REPORT.md`에 측정별 비교표를 씁니다.

| 쪽 | 성공/전체 | 확인 통과 | 사람 판정(통과·부분/판정) | 평균 비용(USD) | 평균 턴 | 평균 시간(초) | 평균 출력 토큰 | 평균 변경 파일 |
|---|---|---|---|---|---|---|---|---|
| A | 3/3 | 1/3 | 1·1/3 | … | … | … | … | … |
| B | 3/3 | 3/3 | 3·0/3 | … | … | … | … | … |
| 차이 | | | | +12% | -20% | … | … | … |

- 평균은 오류 없이 끝난 실행만으로 계산합니다.
- 비용은 Claude Code가 보고한 **API 기준 추정값**입니다. 구독 요금제에서는 실제 청구액이 아닙니다.
- 품질은 두 가지로 표에 들어갑니다.
  - **확인 통과**: 확인 명령이 있으면 통과 수/실행 수.
  - **사람 판정**: 앱의 "결과" 화면 → "블라인드 판정"에서 A/B를 가린 "답안 N"을 보고 통과·부분·실패를 고르면
    `results\<측정>\judgments.json`에 저장되고 "통과·부분/판정" 수로 표시됩니다. 순서는 처음 열 때 섞여 고정되며,
    "정체 공개"를 켜야 쪽과 쪽별 집계가 보입니다. 판정 기준은 [methodology.md](methodology.md)를 참고하세요.

---

## 8. 정리

```powershell
.\list-exp.ps1                        # 실험 목록
.\login.ps1 -Exp superpowers -Logout  # B 로그아웃
```

실험을 지우려면 `experiments\<이름>\`과 `<workRoot>\<이름>\`을 지웁니다.
B 설정 폴더 안의 로그인 정보도 함께 사라집니다.

## 9. git에 올라가는 것

| 올라감 | 제외(.gitignore) |
|---|---|
| 스크립트, 문서, `templates\`, `empty-mcp.json`, `app\`(소스) | `config-vanilla\`, `experiments\*\config-B\` (로그인 토큰) |
| `experiments\<이름>\experiment.json`, `NOTES.md`, `REPORT.md` | `experiments\*\results\`, `experiments\*\sessions\` (용량 큼) |
| `fixture\`, `plugins\`, `skills\`, `prompts\`, `mcp-B.json` | `lab.local.json` (PC 전용), `app\node_modules\` |

`plugins\`에 외부 플러그인을 통째로 넣으면 그 라이선스를 따라야 합니다. 공개 저장소라면
플러그인 출처·커밋만 `NOTES.md`에 적고 폴더는 `.gitignore`에 추가하는 방법도 있습니다.
