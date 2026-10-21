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
const J = require('../src/shared/judge');
const M = require('../src/main/media');

// 시험용 고정 난수
function seq(values) {
  let i = 0;
  return () => values[i++ % values.length];
}

test('블라인드 순서: 모든 답안을 한 번씩 섞고, 저장된 순서가 맞으면 유지', () => {
  const keys = ['A-1', 'A-2', 'B-1', 'B-2'];
  const order = J.makeBlindOrder(keys, seq([0.1, 0.9, 0.5]));
  assert.deepEqual(order.slice().sort(), keys);
  assert.notDeepEqual(order, keys);
  assert.deepEqual(J.ensureOrder(['B-2', 'A-1', 'B-1', 'A-2'], keys), ['B-2', 'A-1', 'B-1', 'A-2']);
  assert.equal(J.ensureOrder(['A-1', 'B-1'], keys).length, 4); // 결과가 늘면 새로 섞음
});

test('판정 집계와 검사', () => {
  const keys = ['A-1', 'A-2', 'B-1', 'B-2'];
  const s = J.summarize({ 'A-1': { verdict: 'fail' }, 'A-2': { verdict: 'partial' }, 'B-1': { verdict: 'pass' } }, keys);
  assert.deepEqual(s.A, { total: 2, judged: 2, pass: 0, partial: 1, fail: 1 });
  assert.deepEqual(s.B, { total: 2, judged: 1, pass: 1, partial: 0, fail: 0 });
  assert.throws(() => J.validate({ 'C-1': { verdict: 'pass' } }, keys));
  assert.throws(() => J.validate({ 'A-1': { verdict: 'great' } }, keys));
  const clean = J.validate({ 'A-1': { verdict: 'pass', note: 'x' }, 'B-1': { verdict: '', note: '' } }, keys);
  assert.deepEqual(Object.keys(clean), ['A-1']);
});

test('반복 측정 결과 목록·판정 읽기/저장, 확인 명령 수정', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ablab-r-'));
  const exp = path.join(root, 'experiments', 'demo');
  const run = path.join(exp, 'results', '20261021-120000-과제');
  fs.mkdirSync(run, { recursive: true });
  fs.writeFileSync(path.join(exp, 'experiment.json'), '{"name":"demo","model":"m"}');
  fs.writeFileSync(path.join(run, 'summary.csv'), 'x');
  fs.writeFileSync(path.join(run, 'conditions.json'), '{"prompt":"01-task","model":"m"}');
  for (const k of ['A-1', 'B-1']) fs.writeFileSync(path.join(run, `${k}.json`), '{}');
  fs.writeFileSync(path.join(run, 'A-1-result.md'), '답 A');
  fs.writeFileSync(path.join(run, 'B-1-changes.txt'), 'M a.txt\nA b.txt\n');
  fs.writeFileSync(path.join(run, 'B-1-check.txt'), '명령: x\n결과: 통과 · 종료 코드 0');

  // 대화형 결과(save-live.ps1)도 같은 형식이고 mode 로만 구분된다.
  const live = path.join(exp, 'results', '20261021-130000-live');
  fs.mkdirSync(live, { recursive: true });
  fs.writeFileSync(path.join(live, 'summary.csv'), 'x');
  fs.writeFileSync(path.join(live, 'conditions.json'), '{"mode":"live","prompt":"live","model":"m"}');
  for (const k of ['A-1', 'B-1']) fs.writeFileSync(path.join(live, `${k}.json`), '{}');

  const runs = lab.listResultRuns(exp);
  assert.deepEqual(runs, [
    { name: '20261021-130000-live', mode: 'live', prompt: 'live', model: 'm', count: 2, judged: 0 },
    { name: '20261021-120000-과제', mode: 'AB', prompt: '01-task', model: 'm', count: 2, judged: 0 },
  ]);
  runs.shift();

  const data = lab.readRunItems(exp, runs[0].name, seq([0.0]));
  assert.equal(data.items.length, 2);
  const b = data.items.find((i) => i.key === 'B-1');
  assert.deepEqual(b.changes, ['M a.txt', 'A b.txt']);
  assert.equal(b.check.passed, true);
  assert.equal(data.items.find((i) => i.key === 'A-1').check, null);
  // 순서는 저장되어 다음에도 같다
  assert.deepEqual(lab.readRunItems(exp, runs[0].name).order, data.order);

  const summary = lab.saveJudgments(exp, runs[0].name, { 'B-1': { verdict: 'pass', note: '좋음' } });
  assert.equal(summary.B.pass, 1);
  assert.equal(lab.listResultRuns(exp).find((r) => r.name === runs[0].name).judged, 1);
  assert.throws(() => lab.readRunItems(exp, '..'));

  assert.deepEqual(lab.updateExperimentCheck(exp, { command: 'npm test', timeoutSec: 120 }), { command: 'npm test', timeoutSec: 120 });
  assert.equal(JSON.parse(fs.readFileSync(path.join(exp, 'experiment.json'), 'utf8')).model, 'm');
  assert.throws(() => lab.updateExperimentCheck(exp, { command: 'x', timeoutSec: 1 }));
  fs.rmSync(root, { recursive: true, force: true });
});

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
  fs.writeFileSync(path.join(exp, 'prompts', '과제.md'), '한글 지시문');
  fs.mkdirSync(path.join(exp, 'results', 'cancelled'), { recursive: true }); // 취소돼 summary.csv 없음
  fs.mkdirSync(path.join(root, 'experiments', 'bad name'), { recursive: true });

  const list = lab.listExperiments(root);
  assert.equal(list.length, 1);
  assert.equal(list[0].description, '설명');
  assert.deepEqual(list[0].plugins, ['p1']);
  assert.deepEqual(list[0].skills, ['s1']);
  assert.equal(list[0].results, 0); // results\r1 과 results\cancelled 모두 summary.csv 가 없음
  assert.equal(list[0].bLogin, false);
  assert.deepEqual(list[0].prompts.map((p) => p.name), ['01-task', '02-other', '과제']);
  assert.deepEqual(list[0].prompts[0], { name: '01-task', hasA: false, hasB: true });
  assert.deepEqual(lab.readPrompt(exp, '01-task'), { common: '공통', A: null, B: '공통 + 스킬' });
  assert.equal(lab.readPrompt(exp, '과제').common, '한글 지시문');
  for (const bad of ['..', '.', 'a\\b', 'a/b', 'x:y', 'a*b']) assert.throws(() => lab.readPrompt(exp, bad), undefined, bad);
  assert.throws(() => lab.experimentDir(root, '..\\x'));
  assert.throws(() => lab.experimentDir(root, '..'));
  assert.throws(() => lab.experimentDir(root, '.'));
  assert.ok(lab.experimentDir(root, 'v1.2-test'));

  const s = lab.createSession(exp, { experiment: 'demo' });
  s.appendOutput('A', 'abc');
  s.logTurn({ sentA: 'x', sentB: 'y' });
  s.appendMarker({ kind: 'send', t: 1.5 });
  s.updateMeta({ endedAt: 'now' });
  assert.equal(JSON.parse(fs.readFileSync(path.join(s.dir, 'markers.jsonl'), 'utf8')).kind, 'send');
  assert.equal(fs.readFileSync(path.join(s.dir, 'A.log'), 'utf8'), 'abc');
  assert.equal(JSON.parse(fs.readFileSync(path.join(s.dir, 'turns.jsonl'), 'utf8')).sentB, 'y');
  assert.equal(JSON.parse(fs.readFileSync(path.join(s.dir, 'session.json'), 'utf8')).endedAt, 'now');
  fs.rmSync(root, { recursive: true, force: true });
});

test('계정 정보 가리기: 낱말 목록, 조각 경계, 한글 폭', () => {
  const words = M.redactWords([
    { email: 'tester@example.com', orgName: "tester@example.com's Organization" },
    { email: 'tester@example.com', orgName: '한글조직' },
    null,
  ]);
  assert.deepEqual(words, ["tester@example.com's Organization", 'tester@example.com', 'tester', '한글조직']);
  assert.equal(M.maskWord('ab한'), '****');

  const r = M.createRedactor(words);
  // 한 조각 안
  assert.equal(r.push('hi tester@example.com!'), 'hi ******************!');
  // 조각 경계에 걸친 경우: 앞부분일 수 있는 꼬리는 잡아 뒀다가 다음 조각과 합쳐 가린다
  let out = r.push('login: test');
  assert.equal(out, 'login: ');
  out += r.push('er@example.com done');
  assert.equal(out, 'login: ****************** done');
  // 이메일이 조각 경계에서 잘려도 앞부분(tester)만 따로 가려지지 않는다
  assert.equal(r.push('done. tester@exa'), 'done. ');
  assert.equal(r.push('mple.com!'), '******************!');
  // 잠시 출력이 없어 flush 하면 잡아 둔 꼬리도 가릴 수 있는 만큼 가려서 내보낸다
  assert.equal(r.push('x tester@ex'), 'x ');
  assert.equal(r.flush(), '******@ex');
  // 낱말이 아니면 flush 로 그대로 나온다
  assert.equal(r.push('x te'), 'x ');
  assert.equal(r.flush(), 'te');
  assert.equal(r.flush(), '');
  // 한글 조직 이름은 화면 폭(2칸)에 맞춰 ** 로
  assert.equal(r.push('[한글조직]'), '[********]');
  // 가릴 낱말이 없으면 그대로
  const none = M.createRedactor([]);
  assert.equal(none.active, false);
  assert.equal(none.push('tester@example.com'), 'tester@example.com');
});

test('유튜브 챕터: 0:00 시작, 10초 안의 표시는 합침, 3개 이상이어야 유효', () => {
  const c = M.buildChapters([
    { kind: 'send', rec: 12.4, label: '지시문 전송(A·B): 01-task' },
    { kind: 'shot', rec: 13, label: 'send' }, // 캡처는 챕터가 아님
    { kind: 'done', rec: 15, label: 'A 멈춤' }, // 10초 안이라 빠짐
    { kind: 'done', rec: 95, label: 'B  멈춤 · 1:22 경과' },
    { kind: 'manual', rec: 3725, label: '결과 비교' },
    { kind: 'send', rec: null, label: '녹화 전' },
  ]);
  assert.deepEqual(c.lines, ['0:00 시작', '0:12 지시문 전송(A·B): 01-task', '1:35 B 멈춤 · 1:22 경과', '1:02:05 결과 비교']);
  assert.equal(c.valid, true);
  assert.equal(c.dropped, 1);
  assert.equal(M.buildChapters([{ kind: 'send', rec: 30, label: 'x' }]).valid, false);
  // 녹화 직후(10초 안) 전송은 0:00 챕터 이름이 된다
  const early = M.buildChapters([{ kind: 'send', rec: 2, label: '전송' }, { kind: 'done', rec: 5, label: 'A 멈춤' }, { kind: 'done', rec: 40, label: 'B 멈춤' }]);
  assert.deepEqual(early.lines, ['0:00 전송', '0:40 B 멈춤']);
  assert.equal(early.dropped, 1);
  assert.equal(M.formatClock(59.9), '0:59');
});

test('ffmpeg 찾기와 mp4 변환 인자', () => {
  const exists = (p) => p === 'C:\\ff\\ffmpeg.exe';
  assert.equal(M.resolveFfmpeg({ env: { CC_AB_FFMPEG: 'C:\\ff\\ffmpeg.exe' }, exists, where: () => [] }), 'C:\\ff\\ffmpeg.exe');
  assert.equal(M.resolveFfmpeg({ env: {}, exists, where: () => ['C:\\x\\ffmpeg', 'C:\\x\\ffmpeg.exe'] }), 'C:\\x\\ffmpeg.exe');
  assert.equal(M.resolveFfmpeg({ env: {}, exists, where: () => [] }), null);
  const args = M.mp4Args('in.webm', 'out.mp4');
  assert.equal(args[args.indexOf('-i') + 1], 'in.webm');
  assert.equal(args[args.length - 1], 'out.mp4');
  assert.ok(args.includes('yuv420p'));
});

test('터미널 기록(asciicast v2): 머리말과 출력·크기·표시 줄', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ab-cast-'));
  const file = path.join(dir, 'A.cast');
  const cast = M.createCast(file, { cols: 120, rows: 40, title: 'demo A', start: Date.now() - 1500 });
  cast.output('안녕\r\n');
  cast.resize(100, 30);
  cast.marker('지시문 전송');
  const lines = fs.readFileSync(file, 'utf8').trim().split('\n').map((l) => JSON.parse(l));
  assert.equal(lines[0].version, 2);
  assert.equal(lines[0].width, 120);
  assert.deepEqual(lines.slice(1).map((l) => l[1]), ['o', 'r', 'm']);
  assert.equal(lines[1][2], '안녕\r\n');
  assert.equal(lines[2][2], '100x30');
  assert.ok(lines[1][0] >= 1.4 && lines[1][0] < 5);
  fs.rmSync(dir, { recursive: true, force: true });
});

// ---------- 보고서 마크다운 ----------

const MD = require('../src/shared/markdown');

test('markdown: 제목·문단·목록·표·인용', () => {
  const blocks = MD.parse([
    '# 제목', '', '- 하나', '- **둘**', '  이어짐', '', '| 쪽 | 비용 |', '|---|---|', '| A | `0.2` |', '| B | a \\| b |',
    '', '> 주의', '> 계속', '', '첫 줄', '둘째 줄', '', '---',
  ].join('\r\n'));
  assert.deepEqual(blocks.map((b) => b.type), ['h', 'ul', 'table', 'quote', 'p', 'hr']);
  assert.deepEqual(blocks[1].items, ['하나', '**둘** 이어짐']);
  assert.deepEqual(blocks[2].head, ['쪽', '비용']);
  assert.deepEqual(blocks[2].rows, [['A', '`0.2`'], ['B', 'a | b']]);
  assert.equal(blocks[3].text, '주의 계속');
  assert.equal(blocks[4].text, '첫 줄 둘째 줄');
});

test('markdown: 인라인 코드·굵게·링크', () => {
  assert.deepEqual(MD.inline('a `x` **b** [c](d.md) e'), [
    { t: 'text', v: 'a ' }, { t: 'code', v: 'x' }, { t: 'text', v: ' ' }, { t: 'b', v: 'b' },
    { t: 'text', v: ' ' }, { t: 'text', v: 'c' }, { t: 'text', v: ' e' },
  ]);
});

test('markdown: 실제 REPORT.md 를 오류 없이 나눈다', () => {
  const file = path.join(__dirname, '..', '..', 'experiments', 'superpowers', 'REPORT.md');
  if (!fs.existsSync(file)) return;
  const blocks = MD.parse(fs.readFileSync(file, 'utf8'));
  assert.ok(blocks.some((b) => b.type === 'table' && b.rows.length));
  assert.ok(blocks.some((b) => b.type === 'h' && b.level === 2));
});
