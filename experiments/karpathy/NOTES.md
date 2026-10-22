# karpathy

- 목적: Karpathy 가이드라인 스킬 유무 비교. 이 스킬이 내세우는 "단순하게, 필요한 곳만 고친다"가 실제로 나타나는지
- 기본(A): Claude Code + claude.ai 계정 기본 스킬, 계정 플러그인·MCP 제외
- 비교(B): A + 이 실험의 plugins\ / skills\ / /plugin 설치 / mcp-B.json
- 모델: claude-opus-5-5 (superpowers 실험과 같게 맞춤)
- 만든 날: 2026-10-21

## B에 넣은 것

| 종류 | 이름 | 버전/커밋 | 출처 |
|---|---|---|---|
| 로컬 플러그인 | andrej-karpathy-skills | 1.0.0 @ 2c606141936f | https://github.com/forrestchang/andrej-karpathy-skills (b-config add-git, 상세는 b-manifest.json) |

- 공식 목록(anthropic-plugin-directory)에는 없어서 Git 커밋을 고정해 `plugins\`로 넣었다.
- 플러그인이 B에 주는 것은 스킬 `karpathy-guidelines` 하나뿐이다. 저장소의 `CLAUDE.md`는 플러그인으로 넣으면 읽히지 않는다.
  "CLAUDE.md로 넣는 방식"은 다른 비교 대상이므로, 필요하면 따로 실험한다.
- 스킬이라 모델이 필요하다고 판단할 때만 불린다. 호출 여부는 보고서의 대상 호출(TargetCalls)로 확인한다.

## fixture(실습 프로젝트)

- 출처: experiments\superpowers\fixture 복사(duration-kit 0.1.0, 의존성 없음, `node --test`)

## 지시문과 채점

| 지시문 | 내용 | 숨은 테스트 |
|---|---|---|
| 01-task | superpowers 의 02-task 와 **같은 문장**(버그 수정 + formatDuration 추가, 명세가 빡빡함) | `check\hidden-01-task.test.js` = superpowers 의 hidden.test.js (8개) |
| 02-small-fix | 사용자 제보 형식의 소수 버그 하나만 고쳐 달라는 짧은 요청. 범위를 넓힐 여지를 일부러 남김 | `check\hidden-02-small-fix.test.js` (3개: 소수, 원래 되던 입력, 공개 API) |

- 확인 명령은 `%AB_PROMPT%`(run-headless 가 넘기는 지시문 이름)로 지시문별 숨은 테스트를 고른다.
- 02 숨은 테스트는 지시문에 없는 동작(해석 불가 입력 처리)을 채점하지 않는다. 그런 변경은 과잉 구현 지표로만 센다.
- 검증(토큰 0): fixture 2/3, 최소 수정(정규식 한 줄) 3/3, 과잉 구현 결과물(superpowers 01 결과) 3/3.
  01 숨은 테스트는 `%AB_PROMPT%` 경로로 정상 결과물 8/8.

### 범위(과잉 구현) 지표 — `check\scope.js`

측정이 남긴 결과물 사본을 fixture 와 비교하는 사후 분석(토큰 0):

```powershell
node experiments\karpathy\check\scope.js experiments\karpathy\fixture experiments\karpathy\results\<측정 이름>
```

src 코드 줄, src 변경 줄(LCS), test 코드 줄, 지시문 밖 새 파일, 추가 의존성, package.json 변경, 추가 export,
관계없는 입력의 동작 변경(02 전용). 기준점: 최소 수정 = src 변경 2줄·동작 변경 0, 과잉 구현 예 = 64줄·8개.

## 판정 기준 (측정 전에 정함, 2026-10-21)

- 보고서 판정 카드: experiment.json 의 decision(품질 ±10%p, 비용 +30%, 시간 +50%, 대상 호출 50% 이상).
- **02-small-fix 추가 기준(범위)**: 아래를 모두 만족하면 "범위 효과 있음".
  1. B의 src 변경 줄 평균이 A보다 30% 이상 적다.
  2. 그 차이가 A/A 에서 두 열 사이에 난 차이보다 크다.
  3. 관계없는 입력의 동작을 바꾼 회차 수가 B ≤ A.
  4. 숨은 테스트 통과율이 A보다 낮지 않다.
- 01-task 에는 범위 기준을 적용하지 않는다(명세가 넓은 변경을 요구함). 같은 과제에서 superpowers 와 비교하는 용도.

## 측정 계획 (토큰 사용, 아직 안 함)

1. 한글 전달 확인: `.\run-headless.ps1 -Exp karpathy -Prompt 02-small-fix -Runs 1` 뒤 `*-result.md`에서 지시문을 제대로 읽었는지 본다.
2. 02-small-fix: `-Mode AA -Runs 3` → `-Runs 5` → `report.ps1` + `scope.js`.
3. (선택) 01-task: 같은 방식. superpowers 02-task 를 재면 3파전 비교가 된다.

## 환경 기준 변경 (2026-10-21, 측정 전)

- A/B 모두 claude.ai 계정 스킬 동기화를 끔(`syncClaudeAiSkills: false`)과 Claude in Chrome 끔(`--no-chrome`).
- `inventory.ps1 -Exp karpathy` 확인: A/B 모두 MCP 0, 계정 스킬 0, 내장 스킬 19·내장 플러그인 3·에이전트 5.
  B에만 `andrej-karpathy-skills` 플러그인과 스킬 `karpathy-guidelines`.
- 그 전에 연 대화형 세션 2개(`sessions/20261021-203421`, `sessions/20261021-203844`)는 옛 기준(계정 스킬 19개·Chrome MCP 22개)이라 비교에 쓰지 않음. 판정 기준·숨은 테스트는 바꾸지 않음.

## 관찰

## 결론
