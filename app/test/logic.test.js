const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');

const P = require('../src/shared/prompt');
const { buildChildEnv } = require('../src/main/env');
const { psQuote, buildPsArgs } = require('../src/main/powershell');
const { resolveClaude } = require('../src/main/claude-resolve');
const lab = require('../src/main/lab');

test('공통 입력은 수정하지 않은 예비 입력창에만 동기화된다', () => {
  let s = P.initial('작업해줘');
  s = P.editDraft(s, 'B', '작업해줘 (superpowers 스킬 사용)');
  s = P.setCommon(s, '테스트까지 작업해줘');
  assert.equal(s.A, '테스트까지 작업해줘');
  assert.equal(s.B, '작업해줘 (superpowers 스킬 사용)');
  assert.deepEqual(s.dirty, { A: false, B: true });
});

test('예비 입력창을 공통과 같게 고치면 수정됨이 풀린다', () => {
  let s = P.initial('x');
  s = P.editDraft(s, 'A', 'y');
  assert.equal(s.dirty.A, true);
  s = P.editDraft(s, 'A', 'x');
  assert.equal(s.dirty.A, false);
  s = P.editDraft(s, 'A', 'z');
  s = P.resetDraft(s, 'A');
  assert.equal(s.A, 'x');
  assert.equal(s.dirty.A, false);
});

test('공정성 판정: 같음 / 호출 문구 / 내용 변경', () => {
  assert.equal(P.fairness(P.initial('작업해줘')).level, 'same');
  const call = P.fairness(P.editDraft(P.initial('작업해줘'), 'B', '작업해줘 (superpowers 스킬 사용)'));
  assert.equal(call.level, 'call');
  assert.equal(call.B.extra, '(superpowers 스킬 사용)');
  assert.equal(call.A.kind, 'same');
  const content = P.fairness(P.editDraft(P.initial('작업해줘'), 'A', '다른 일을 해줘'));
  assert.equal(content.level, 'content');
  assert.equal(P.fairness(P.editDraft(P.initial(''), 'B', '뭔가')).level, 'content');
});

test('지시문 불러오기: 변형 파일이 있는 쪽만 수정됨', () => {
  const s = P.load('작업해줘', { A: null, B: '작업해줘 + 스킬' });
  assert.equal(s.A, '작업해줘');
  assert.equal(s.B, '작업해줘 + 스킬');
  assert.deepEqual(s.dirty, { A: false, B: true });
  assert.equal(P.stripComments('<!-- 주석\n여러 줄 -->\n본문 '), '본문');
});

test('자식 환경 변수: 세션 변수 제거, 설정 폴더 지정(대소문자 무시)', () => {
  const env = buildChildEnv(
    { Path: 'C:\\x', CLAUDECODE: '1', claude_code_session_id: 's', CLAUDE_CONFIG_DIR: 'old', ANTHROPIC_BASE_URL: 'keep' },
    'D:\\cfg',
    { COLORTERM: 'truecolor' },
  );
  assert.deepEqual(env, { Path: 'C:\\x', ANTHROPIC_BASE_URL: 'keep', CLAUDE_CONFIG_DIR: 'D:\\cfg', COLORTERM: 'truecolor' });
  assert.equal(buildChildEnv({ CLAUDE_CONFIG_DIR: 'x' }).CLAUDE_CONFIG_DIR, undefined);
});

test('PowerShell 인자: 작은따옴표 이스케이프, 스위치, 빈 값 생략', () => {
  assert.equal(psQuote("it's"), "'it''s'");
  const args = buildPsArgs('D:\\lab\\start.ps1', { Exp: "a'b", Side: 'B', PrintLaunchJson: true, Model: '', NoReset: false });
  const cmd = args[args.length - 1];
  assert.ok(cmd.includes("& 'D:\\lab\\start.ps1' -Exp 'a''b' -Side 'B' -PrintLaunchJson"));
  assert.ok(!cmd.includes('-Model'));
  assert.ok(!cmd.includes('-NoReset'));
  assert.throws(() => buildPsArgs('x.ps1', { 'Bad;Name': 1 }));
});

test('claude 위치: npm 껍데기 옆 node_modules 의 claude.exe 를 찾는다', () => {
  const npmExe = 'C:\\npm\\node_modules\\@anthropic-ai\\claude-code\\bin\\claude.exe';
  const found = resolveClaude({
    env: {},
    where: () => ['C:\\npm\\claude', 'C:\\npm\\claude.cmd'],
    exists: (p) => p === npmExe,
  });
  assert.equal(found, npmExe);
  assert.equal(resolveClaude({ env: {}, where: () => ['C:\\bin\\claude.exe'], exists: () => true }), 'C:\\bin\\claude.exe');
  assert.equal(resolveClaude({ env: { CC_AB_CLAUDE: 'D:\\c.exe' }, where: () => [], exists: () => true }), 'D:\\c.exe');
  assert.equal(resolveClaude({ env: {}, where: () => [], exists: () => false }), null);
});

test('실험 목록과 지시문(변형 포함) 읽기, 세션 기록', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ablab-'));
  const exp = path.join(root, 'experiments', 'demo');
  for (const d of ['plugins/p1', 'skills/s1', 'prompts', 'results/r1', 'config-B']) fs.mkdirSync(path.join(exp, d), { recursive: true });
  fs.writeFileSync(path.join(exp, 'experiment.json'), '\uFEFF{"name":"demo","description":"설명","model":"m"}');
  fs.writeFileSync(path.join(exp, 'prompts', '01-task.md'), '공통');
  fs.writeFileSync(path.join(exp, 'prompts', '01-task.B.md'), '공통 + 스킬');
  fs.writeFileSync(path.join(exp, 'prompts', '02-other.md'), '둘째');
  fs.mkdirSync(path.join(root, 'experiments', 'bad name'), { recursive: true });

  const list = lab.listExperiments(root);
  assert.equal(list.length, 1);
  assert.equal(list[0].description, '설명');
  assert.deepEqual(list[0].plugins, ['p1']);
  assert.deepEqual(list[0].skills, ['s1']);
  assert.equal(list[0].results, 1);
  assert.equal(list[0].bLogin, false);
  assert.deepEqual(list[0].prompts, [
    { name: '01-task', hasA: false, hasB: true },
    { name: '02-other', hasA: false, hasB: false },
  ]);
  assert.deepEqual(lab.readPrompt(exp, '01-task'), { common: '공통', A: null, B: '공통 + 스킬' });
  assert.throws(() => lab.experimentDir(root, '..\\x'));

  const s = lab.createSession(exp, { experiment: 'demo' });
  s.appendOutput('A', 'abc');
  s.logTurn({ sentA: 'x', sentB: 'y' });
  s.updateMeta({ endedAt: 'now' });
  assert.equal(fs.readFileSync(path.join(s.dir, 'A.log'), 'utf8'), 'abc');
  assert.equal(JSON.parse(fs.readFileSync(path.join(s.dir, 'turns.jsonl'), 'utf8')).sentB, 'y');
  assert.equal(JSON.parse(fs.readFileSync(path.join(s.dir, 'session.json'), 'utf8')).endedAt, 'now');
  fs.rmSync(root, { recursive: true, force: true });
});
