// 화면 동작. window.lab(preload)만 통해 메인 프로세스와 통신한다.
'use strict';

const P = window.AbPrompt;
const api = window.lab;
const SIDES = P.SIDES;
const Fit = window.FitAddon.FitAddon || window.FitAddon;

const $ = (sel, root = document) => root.querySelector(sel);
const $$ = (sel, root = document) => Array.from(root.querySelectorAll(sel));
const pane = (side, sel) => $(`.pane[data-side="${side}"] ${sel}`);
const delay = (ms) => new Promise((r) => setTimeout(r, ms));

const state = {
  exps: [],
  exp: null,
  prompt: P.initial(''),
  running: false,
  launches: null,
  lastData: { A: 0, B: 0 },
  exited: { A: null, B: null },
  osc: { A: '', B: '' },
  runs: new Map(), // runId -> { out, onDone }
  headlessRun: null,
  promptName: '', // 마지막으로 불러온 지시문 파일 이름(표시 이름용)
  // 보낸 뒤 출력이 나오다 멈추면 "멈춤" 표시. { at: 보낸 시각, label }
  pending: { A: null, B: null },
  rec: null, // { recorder, stream, chain, startedAt }
};
const QUIET_MS = 4000; // 이만큼 출력이 없으면 멈춤(응답 끝 또는 확인 대기)으로 본다

// 화면 설정(체크 상자) 기억. 저장소를 못 쓰는 환경에서도 기본값으로 동작한다.
const PREFS = ['opt-autorec', 'opt-autoshot', 'opt-mask'];
function loadPrefs() {
  for (const id of PREFS) {
    try {
      const v = localStorage.getItem(`ab-lab:${id}`);
      if (v !== null) document.getElementById(id).checked = v === '1';
    } catch { /* 저장소 없음 */ }
  }
}
function savePref(id) {
  try { localStorage.setItem(`ab-lab:${id}`, document.getElementById(id).checked ? '1' : '0'); } catch { /* 저장소 없음 */ }
}

function formatClock(sec) {
  const s = Math.max(0, Math.floor(sec));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const ss = String(s % 60).padStart(2, '0');
  return h ? `${h}:${String(m).padStart(2, '0')}:${ss}` : `${m}:${ss}`;
}
const terms = {};

// ---------- 공통 ----------

function toast(message, isError) {
  const el = $('#toast');
  el.textContent = message;
  el.classList.toggle('error', !!isError);
}

async function guard(fn) {
  try {
    return await fn();
  } catch (err) {
    toast(err.message || String(err), true);
    return undefined;
  }
}

// 요소 만들기(글자는 textContent 로만 넣는다).
function el(tag, attrs, ...children) {
  const node = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs || {})) {
    if (v === undefined || v === null || v === false) continue;
    if (k === 'class') node.className = v;
    else if (k === 'text') node.textContent = v;
    else if (k.startsWith('on')) node.addEventListener(k.slice(2).toLowerCase(), v);
    else node.setAttribute(k, v === true ? '' : String(v));
  }
  for (const c of children) if (c !== null && c !== undefined) node.append(c);
  return node;
}

function appendOut(out, line, isErr) {
  if (isErr) {
    const span = document.createElement('span');
    span.className = 'err';
    span.textContent = line + '\n';
    out.appendChild(span);
  } else {
    out.appendChild(document.createTextNode(line + '\n'));
  }
  out.scrollTop = out.scrollHeight;
}

// PowerShell 스크립트를 실행하고 출력을 out 에 흘린다. done 은 종료 코드로 끝난다.
async function startScript(name, params, out) {
  const runId = await api.runScript(name, params);
  let onDone;
  const done = new Promise((resolve) => { onDone = resolve; });
  state.runs.set(runId, { out, onDone });
  return { runId, done };
}

function runScript(name, params, out) {
  return startScript(name, params, out).then((r) => r.done);
}

api.onScriptLine(({ runId, line, kind }) => {
  const run = state.runs.get(runId);
  if (run && run.out) appendOut(run.out, line, kind === 'err');
});
api.onScriptDone(({ runId, code }) => {
  const run = state.runs.get(runId);
  if (!run) return;
  state.runs.delete(runId);
  if (run.out) appendOut(run.out, `[끝: 종료 코드 ${code}]`, code !== 0);
  run.onDone(code);
});

// ---------- 실험 ----------

async function loadExperiments(keep) {
  state.exps = await api.listExperiments();
  const list = $('#exp-list');
  list.textContent = '';
  for (const e of state.exps) {
    const li = document.createElement('li');
    const btn = document.createElement('button');
    btn.type = 'button';
    btn.dataset.exp = e.name;
    const name = document.createElement('span');
    name.textContent = e.name;
    const sub = document.createElement('span');
    sub.className = 'sub';
    const parts = [...e.plugins.map((p) => `플러그인 ${p}`), ...e.skills.map((s) => `스킬 ${s}`)];
    if (e.installed) parts.push('/plugin 설치');
    sub.textContent = parts.join(' · ') || 'B 비교 대상 없음';
    btn.append(name, sub);
    btn.addEventListener('click', () => selectExperiment(e.name));
    li.appendChild(btn);
    list.appendChild(li);
  }
  if (!state.exps.length) toast('실험이 없습니다. "새 실험"으로 만드세요.');
  const target = keep && state.exps.find((e) => e.name === keep) ? keep : state.exps[0] && state.exps[0].name;
  if (target) selectExperiment(target);
}

function selectExperiment(name) {
  if (state.running && state.exp && state.exp.name !== name) {
    toast('대화형 세션을 종료한 뒤 실험을 바꿀 수 있습니다.', true);
    return;
  }
  const e = state.exps.find((x) => x.name === name);
  if (!e) return;
  // 저장하지 않은 판정이 있으면 한 번은 막고 알린다. 같은 실험을 다시 누르면 버리고 바꾼다.
  if (state.exp && state.exp.name !== name && Judging.hasUnsaved() && state.discardTarget !== name) {
    state.discardTarget = name;
    toast(`저장하지 않은 판정이 있습니다. "판정 저장"을 누르거나, ${name} 을(를) 한 번 더 누르면 판정을 버리고 바꿉니다.`, true);
    return;
  }
  state.discardTarget = null;
  // 같은 실험을 다시 고르는 경우(측정 종료·B 구성 변경 뒤 목록 새로 읽기)에는 정보만 갱신하고
  // 판정 중인 화면, 고른 지시문, 편집 중인 확인 명령은 그대로 둔다.
  const same = !!state.exp && state.exp.name === name;
  state.exp = e;
  for (const btn of $$('#exp-list button')) btn.setAttribute('aria-current', String(btn.dataset.exp === name));
  $('#exp-title').textContent = e.name;
  const b = [...e.plugins.map((p) => `플러그인 ${p}`), ...e.skills.map((s) => `스킬 ${s}`)];
  if (e.installed) b.push('/plugin 설치');
  $('#exp-meta').textContent =
    `${e.description ? e.description + ' · ' : ''}모델 ${e.model || '-'} · B: ${b.join(', ') || '비교 대상 없음'} · B 로그인 ${e.bLogin ? '됨' : '안 됨'} · 측정 ${e.results}회`;

  for (const sel of [$('#prompt-file'), $('#hl-prompt')]) {
    const keep = same ? sel.value : '';
    sel.textContent = '';
    if (sel.id === 'prompt-file') sel.appendChild(new Option('지시문 불러오기…', ''));
    for (const p of e.prompts) {
      const mark = [p.hasA ? 'A변형' : '', p.hasB ? 'B변형' : ''].filter(Boolean).join(',');
      sel.appendChild(new Option(mark ? `${p.name} (${mark})` : p.name, p.name));
    }
    if (keep && e.prompts.some((p) => p.name === keep)) sel.value = keep;
  }
  if (same) {
    Judging.onSameExperiment();
    return;
  }
  $('#hl-check').value = e.check.command;
  $('#hl-check-timeout').value = e.check.timeoutSec;
  BConfig.onExperiment();
  Judging.onExperiment();
  if ($('#view-results').hidden === false) showReport();
}

// ---------- 지시문 상태 ----------

function renderPrompt(skipFocused) {
  const s = state.prompt;
  const focused = document.activeElement;
  const set = (el, value) => { if (el.value !== value && !(skipFocused && el === focused)) el.value = value; };
  set($('#common'), s.common);
  for (const side of SIDES) {
    set($(`#draft-${side}`), s[side]);
    const chip = pane(side, '.chip');
    chip.textContent = s.dirty[side] ? '수정됨' : '공통과 같음';
    chip.classList.toggle('dirty', s.dirty[side]);
  }
  const f = P.fairness(s);
  const banner = $('#banner');
  banner.className = `banner ${f.level}`;
  if (f.level === 'same') {
    banner.textContent = 'A·B 지시문 동일 — 양쪽에 같은 문장이 전송됩니다.';
  } else {
    const parts = [];
    for (const side of SIDES) {
      const c = f[side];
      if (c.kind === 'call') parts.push(`${side} + "${c.extra}"`);
      else if (c.kind === 'content') parts.push(`${side} 내용 변경`);
    }
    banner.textContent = (f.level === 'call' ? '지시문 변형(호출 문구): ' : '지시문 내용 변경 · 공정성 경고: ') + parts.join('  /  ');
  }
}

async function loadPromptFile(name) {
  if (!name || !state.exp) return;
  const p = await api.readPrompt(state.exp.name, name);
  const strip = (t) => (t === null ? null : P.stripComments(t));
  state.prompt = P.load(P.stripComments(p.common), { A: strip(p.A), B: strip(p.B) });
  state.promptName = name;
  renderPrompt(false);
}

// ---------- 터미널 ----------

function makeTerm(side) {
  const term = new window.Terminal({
    fontFamily: '"Cascadia Mono", Consolas, "Malgun Gothic", monospace',
    fontSize: 13,
    cursorBlink: true,
    scrollback: 5000,
    theme: { background: '#0F1115', foreground: '#D6DAE0' },
  });
  const fit = new Fit();
  term.loadAddon(fit);
  const el = pane(side, '.term');
  term.open(el);
  term.onData((data) => {
    if (!state.running) return;
    api.write(side, data);
    // 터미널에 직접 입력하고 Enter(확인 창 답 등)를 누른 경우도 멈춤 표시 대상으로 삼는다.
    if (data.includes('\r') && !state.pending[side]) state.pending[side] = { at: Date.now(), label: '입력' };
  });
  term.onTitleChange((title) => { pane(side, '.title').textContent = title; });
  // Claude Code 상태 신호(OSC 7501). 시작할 때 오는 "?"는 지원 여부 질문이며, 응답 형식이 공개돼 있지 않아
  // 지금은 응답하지 않는다(그러면 상태 신호도 오지 않음). 질문이 아닌 값이 오면 받은 그대로 보여 준다.
  term.parser.registerOscHandler(7501, (data) => {
    if (data !== '?') { state.osc[side] = data; renderStatus(); }
    return true;
  });
  term.attachCustomKeyEventHandler((ev) => {
    if (ev.type !== 'keydown') return true;
    const plain = ev.ctrlKey && !ev.shiftKey && !ev.altKey;
    // Ctrl+V: 브라우저 붙여넣기 이벤트로 넘겨 xterm 이 붙여넣기로 처리하게 한다.
    if (plain && (ev.key === 'v' || ev.key === 'V')) return false;
    // Ctrl+C: 선택한 글자가 있으면 복사(Windows Terminal 과 같은 동작), 없으면 터미널로.
    if (plain && (ev.key === 'c' || ev.key === 'C') && term.hasSelection()) {
      api.copy(term.getSelection());
      term.clearSelection();
      return false;
    }
    return true;
  });
  // 창 배치가 자리 잡는 동안 크기 변경이 여러 번 오면 Claude Code 가 매번 다시 그려 잔상이 남는다.
  // 잠깐 모았다가 실제로 바뀐 경우에만 한 번 보낸다.
  let timer = null;
  new ResizeObserver(() => {
    clearTimeout(timer);
    timer = setTimeout(() => {
      try {
        fit.fit();
        sendSize(side);
      } catch { /* 숨겨진 상태 */ }
    }, 150);
  }).observe(el);
  terms[side] = { term, fit, sentSize: '' };
}

function sendSize(side, force) {
  const t = terms[side];
  const key = `${t.term.cols}x${t.term.rows}`;
  if (!state.running || (!force && key === t.sentSize)) return;
  t.sentSize = key;
  api.resize(side, t.term.cols, t.term.rows);
}

api.onData(({ side, data }) => {
  terms[side].term.write(data);
  state.lastData[side] = Date.now();
});
api.onExit(({ side, code }) => {
  state.exited[side] = code;
  terms[side].term.write(`\r\n\x1b[90m[프로세스 종료: ${code}]\x1b[0m\r\n`);
  if (SIDES.every((s) => state.exited[s] !== null)) state.running = false;
  renderStatus();
});

function renderStatus() {
  for (const side of SIDES) {
    const el = pane(side, '.status');
    let text = '대기';
    let cls = '';
    if (state.exited[side] !== null) { text = `종료됨(${state.exited[side]})`; cls = 'exited'; }
    else if (state.running) {
      const busy = Date.now() - state.lastData[side] < 1200;
      text = busy ? '출력 중' : '조용함';
      cls = busy ? 'busy' : '';
    }
    if (state.osc[side]) text += ` · 상태 신호 ${state.osc[side]}`;
    el.textContent = text;
    el.className = `status ${cls}`;
    checkQuiet(side);
  }
  $('#btn-start').disabled = state.running;
  $('#btn-stop').disabled = !state.running;
  const rec = $('#rec-state');
  const on = !!(state.rec && state.rec.startedAt);
  rec.textContent = on ? `녹화 중 ${formatClock((Date.now() - state.rec.startedAt) / 1000)}` : (state.rec ? '녹화 준비 중…' : '녹화 안 함');
  rec.classList.toggle('on', on);
  $('#btn-rec').textContent = state.rec ? '녹화 끝' : '녹화 시작';
  $('#btn-rec').classList.toggle('on', !!state.rec);
}

// 보낸 뒤 출력이 나오다가 QUIET_MS 동안 멈추면 "멈춤" 표시(응답 끝 또는 확인 대기로 추정)와 자동 캡처.
function checkQuiet(side) {
  const p = state.pending[side];
  if (!p || !state.running) return;
  const last = state.lastData[side];
  if (last <= p.at + 300 || Date.now() - last < QUIET_MS) return;
  state.pending[side] = null;
  const label = `${side} 멈춤 · ${formatClock((last - p.at) / 1000)} 경과`;
  guard(() => api.mark('done', label));
  if ($('#opt-autoshot').checked) guard(() => api.shot(`${side}-done`));
}

// ---------- 녹화 ----------
// 메인 프로세스가 허락한 이 앱 화면만 getDisplayMedia 로 받아 webm 조각을 1초마다 보낸다.

async function startRecording() {
  if (!state.running) return toast('세션을 먼저 시작하세요.', true);
  if (state.rec) return;
  const r = await guard(() => api.recStart());
  if (!r) return;
  state.rec = { recorder: null, stream: null, chain: Promise.resolve(), startedAt: 0 };
  renderStatus();
  try {
    const stream = await navigator.mediaDevices.getDisplayMedia({ video: { frameRate: 30 }, audio: false });
    const mimeType = ['video/webm;codecs=vp9', 'video/webm;codecs=vp8', 'video/webm'].find((m) => MediaRecorder.isTypeSupported(m));
    const recorder = new MediaRecorder(stream, { mimeType, videoBitsPerSecond: 12000000 });
    const rec = state.rec;
    recorder.ondataavailable = (e) => {
      if (!e.data || !e.data.size) return;
      rec.chain = rec.chain.then(async () => api.recChunk(await e.data.arrayBuffer()));
    };
    rec.recorder = recorder;
    rec.stream = stream;
    recorder.start(1000);
    await api.recStarted();
    rec.startedAt = Date.now();
    toast(`녹화 시작: ${r.file}`);
  } catch (err) {
    if (state.rec && state.rec.stream) state.rec.stream.getTracks().forEach((t) => t.stop());
    state.rec = null;
    await guard(() => api.recAbort());
    toast(`녹화를 시작하지 못했습니다: ${err.message || err}`, true);
  }
  renderStatus();
}

async function stopRecording() {
  const rec = state.rec;
  if (!rec || !rec.recorder) return;
  const stopped = new Promise((resolve) => { rec.recorder.onstop = resolve; });
  rec.recorder.stop();
  await stopped;
  await rec.chain;
  rec.stream.getTracks().forEach((t) => t.stop());
  state.rec = null;
  renderStatus();
  const res = await guard(() => api.recStop());
  if (!res) return;
  const ch = res.chapters;
  const chText = ch.valid ? `챕터 ${ch.lines.length}개` : `챕터 ${ch.lines.length}개(유튜브는 3개 이상 필요)`;
  toast(res.converting ? `녹화 저장(${chText}). mp4 로 바꾸는 중…` : `녹화 저장: ${res.file} (${chText}${res.mp4 ? '' : ', ffmpeg 가 없어 webm 그대로'})`);
}

api.onRecConverted(({ ok, mp4, error }) => {
  toast(ok ? `mp4 저장: ${mp4}` : `mp4 변환 실패: ${error}`, !ok);
});
setInterval(renderStatus, 500);

async function startSession() {
  if (!state.exp) return toast('실험을 먼저 고르세요.', true);
  for (const side of SIDES) {
    terms[side].term.reset();
    terms[side].fit.fit();
    state.exited[side] = null;
    state.osc[side] = '';
    pane(side, '.title').textContent = '';
  }
  toast('세션 시작 중… (작업 폴더 초기화와 실행 준비)');
  $('#btn-start').disabled = true;
  const sizes = {};
  for (const side of SIDES) {
    sizes[side] = { cols: terms[side].term.cols, rows: terms[side].term.rows };
    terms[side].sentSize = `${sizes[side].cols}x${sizes[side].rows}`;
  }
  const r = await guard(() => api.startLive({
    exp: state.exp.name,
    reset: $('#opt-reset').checked,
    permissionMode: $('#opt-perm').value,
    sizes,
    mask: $('#opt-mask').checked,
  }));
  if (!r) { renderStatus(); return; }
  state.running = true;
  state.launches = r.launches;
  for (const side of SIDES) {
    const l = r.launches[side];
    pane(side, '.cfg').textContent = l.config.split(/[\\/]/).slice(-2).join('\\');
    pane(side, '.cfg').title = `${l.config}\n작업 폴더: ${l.work}\nclaude ${l.args.join(' ')}`;
    sendSize(side); // 준비하는 동안 창 크기가 바뀌었으면 맞춘다
  }
  state.pending = { A: null, B: null };
  const warnings = SIDES.flatMap((s) => r.launches[s].warnings || []);
  const maskNote = $('#opt-mask').checked && !r.masked ? ' · 계정 정보를 읽지 못해 가리지 않음' : '';
  toast(warnings.length ? `주의: 작업 폴더 상위에 ${warnings.join(', ')}` : `세션 기록: ${r.sessionDir}${maskNote}`, warnings.length > 0 || !!maskNote);
  terms.A.term.focus();
  renderStatus();
  if ($('#opt-autorec').checked) await startRecording();
}

async function stopSession() {
  if (state.rec) await stopRecording();
  await guard(() => api.stopLive());
  state.running = false;
  renderStatus();
}

// 예비 입력창 내용을 터미널로 보낸다. 붙여넣기 모드를 켠 프로그램에는 붙여넣기로, 아니면 Ctrl+J 줄바꿈으로.
async function sendTo(sides) {
  if (!state.running) return toast('세션을 먼저 시작하세요.', true);
  const f = P.fairness(state.prompt);
  const sent = {};
  for (const side of sides) {
    const text = state.prompt[side];
    if (!text.trim() || state.exited[side] !== null) continue;
    const { term } = terms[side];
    if (term.modes.bracketedPasteMode) term.paste(text);
    else api.write(side, text.replace(/\r?\n/g, '\n'));
    sent[side] = text;
  }
  const targets = Object.keys(sent);
  if (!targets.length) return toast('보낼 내용이 없거나 터미널이 종료됐습니다.', true);
  await delay(250);
  for (const side of targets) api.write(side, '\r');
  await guard(() => api.logTurn({
    event: 'send',
    targets,
    common: state.prompt.common,
    sentA: sent.A === undefined ? null : sent.A,
    sentB: sent.B === undefined ? null : sent.B,
    fairness: f.level,
    extraA: f.A.extra,
    extraB: f.B.extra,
  }));
  toast(`${targets.join('·')} 에 보냄${f.level === 'same' ? '' : ' (지시문 변형 기록됨)'}`);
  // 표시와 자동 캡처(영상 편집·챕터용)
  const now = Date.now();
  for (const side of targets) state.pending[side] = { at: now, label: '전송' };
  const firstLine = state.prompt.common.split(/\r?\n/).map((s) => s.trim()).find(Boolean) || '';
  const short = state.promptName || (firstLine.length > 24 ? `${firstLine.slice(0, 24)}…` : firstLine);
  await guard(() => api.mark('send', `지시문 전송(${targets.join('·')})${short ? `: ${short}` : ''}`));
  if ($('#opt-autoshot').checked) setTimeout(() => { if (state.running) guard(() => api.shot('send')); }, 1500);
}

// ---------- 다른 화면 ----------

function showView(view) {
  for (const tab of $$('.tabs button')) tab.setAttribute('aria-selected', String(tab.dataset.view === view));
  for (const sec of $$('.view')) sec.hidden = sec.dataset.view !== view;
  if (view === 'live') for (const side of SIDES) terms[side].fit.fit();
  if (view === 'bconfig') BConfig.show();
  if (view === 'results') { showReport(); Judging.show(); }
}

async function showReport() {
  if (!state.exp) return;
  const text = await guard(() => api.readReport(state.exp.name));
  $('#report-out').textContent = text || 'REPORT.md 가 아직 없습니다. 반복 측정 후 "보고서 만들기"를 누르세요.';
}

function needExp() {
  if (!state.exp) { toast('실험을 먼저 고르세요.', true); return false; }
  return true;
}

function bind() {
  $('#btn-refresh').addEventListener('click', () => guard(() => loadExperiments(state.exp && state.exp.name)));
  $('#btn-new-toggle').addEventListener('click', () => { $('#new-exp').hidden = !$('#new-exp').hidden; });
  $('#new-exp').addEventListener('submit', async (ev) => {
    ev.preventDefault();
    const name = $('#new-name').value.trim();
    const out = $('#check-out');
    out.textContent = '';
    showView('check');
    const code = await guard(() => runScript('new-exp', { Name: name, Description: $('#new-desc').value.trim() }, out));
    if (code === 0) {
      $('#new-exp').hidden = true;
      $('#new-name').value = '';
      $('#new-desc').value = '';
      await guard(() => loadExperiments(name));
    }
  });

  for (const tab of $$('.tabs button')) tab.addEventListener('click', () => showView(tab.dataset.view));

  $('#btn-start').addEventListener('click', startSession);
  $('#btn-stop').addEventListener('click', stopSession);
  $('#btn-open-session').addEventListener('click', () => guard(() => api.open('session')));
  $('#btn-rec').addEventListener('click', () => (state.rec ? stopRecording() : startRecording()));
  $('#btn-shot').addEventListener('click', async () => {
    if (!state.running) return toast('세션을 먼저 시작하세요.', true);
    const file = await guard(() => api.shot('manual'));
    if (file) toast(`캡처: ${file}`);
  });
  $('#btn-mark').addEventListener('click', async () => {
    if (!state.running) return toast('세션을 먼저 시작하세요.', true);
    const label = $('#mark-label').value.trim() || '표시';
    const m = await guard(() => api.mark('manual', label));
    if (m) {
      $('#mark-label').value = '';
      toast(`표시: ${label} (${formatClock(m.rec !== null ? m.rec : m.t)}${m.rec !== null ? ' 녹화 기준' : ' 세션 기준'})`);
    }
  });
  $('#mark-label').addEventListener('keydown', (ev) => { if (ev.key === 'Enter') { ev.preventDefault(); $('#btn-mark').click(); } });
  $('#btn-open-rec').addEventListener('click', () => guard(() => api.open('recordings')));
  for (const id of PREFS) document.getElementById(id).addEventListener('change', () => savePref(id));
  $('#opt-size').addEventListener('change', (ev) => {
    const [w, h] = ev.target.value.split('x').map(Number);
    if (w && h) guard(() => api.setWindowSize(w, h));
  });

  $('#common').addEventListener('input', (ev) => { state.prompt = P.setCommon(state.prompt, ev.target.value); renderPrompt(true); });
  $('#common').addEventListener('keydown', (ev) => {
    if (ev.key === 'Enter' && ev.ctrlKey) { ev.preventDefault(); sendTo(SIDES); }
  });
  $('#prompt-file').addEventListener('change', (ev) => { guard(() => loadPromptFile(ev.target.value)); ev.target.value = ''; });
  $('#btn-send-both').addEventListener('click', () => sendTo(SIDES));

  for (const side of SIDES) {
    $(`#draft-${side}`).addEventListener('input', (ev) => { state.prompt = P.editDraft(state.prompt, side, ev.target.value); renderPrompt(true); });
    $(`#draft-${side}`).addEventListener('keydown', (ev) => {
      if (ev.key === 'Enter' && ev.ctrlKey) { ev.preventDefault(); sendTo([side]); }
    });
    pane(side, '.reset-draft').addEventListener('click', () => { state.prompt = P.resetDraft(state.prompt, side); renderPrompt(false); });
    pane(side, '.send-one').addEventListener('click', () => sendTo([side]));
    pane(side, '.open-work').addEventListener('click', () => guard(() => api.open(`work${side}`)));
    pane(side, '.restart').addEventListener('click', async () => {
      if (!state.running && state.exited[side] === null) return toast('세션을 먼저 시작하세요.', true);
      terms[side].term.reset();
      state.exited[side] = null;
      const { cols, rows } = terms[side].term;
      terms[side].sentSize = `${cols}x${rows}`;
      const ok = await guard(() => api.restartSide(side, { cols, rows }).then(() => true));
      if (ok) { state.running = true; toast(`${side} 다시 시작함(기록에 남음)`); }
      renderStatus();
    });
  }

  $('#btn-doctor').addEventListener('click', () => {
    if (!needExp()) return;
    $('#check-out').textContent = '';
    guard(() => runScript('doctor', { Exp: state.exp.name }, $('#check-out')));
  });
  $('#btn-login-a').addEventListener('click', () => guard(() => api.openLogin(null)));
  $('#btn-login-b').addEventListener('click', () => { if (needExp()) guard(() => api.openLogin(state.exp.name)); });
  for (const id of ['#btn-open-exp', '#btn-open-exp2']) {
    $(id).addEventListener('click', () => { if (needExp()) guard(() => api.open('exp', state.exp.name)); });
  }

  $('#btn-hl-run').addEventListener('click', async () => {
    if (!needExp()) return;
    if (state.headlessRun) return toast('이미 측정 중입니다.', true);
    const params = {
      Exp: state.exp.name,
      Prompt: $('#hl-prompt').value,
      Runs: Number($('#hl-runs').value) || 3,
      PermissionMode: $('#hl-perm').value,
      Side: $('#hl-side').value,
    };
    const budget = Number($('#hl-budget').value);
    if (budget > 0) params.MaxBudgetUsd = budget;
    if (!params.Prompt) return toast('지시문을 고르세요.', true);
    const out = $('#headless-out');
    out.textContent = '';
    $('#btn-hl-run').disabled = true;
    const run = await guard(() => startScript('run-headless', params, out));
    if (run) {
      state.headlessRun = run.runId;
      await run.done;
    }
    state.headlessRun = null;
    $('#btn-hl-run').disabled = false;
    guard(() => loadExperiments(state.exp.name));
  });
  $('#btn-hl-check-save').addEventListener('click', async () => {
    if (!needExp()) return;
    const saved = await guard(() => api.setCheck(state.exp.name, {
      command: $('#hl-check').value,
      timeoutSec: Number($('#hl-check-timeout').value),
    }));
    if (saved) {
      state.exp.check = saved;
      toast(saved.command ? `확인 명령 저장: ${saved.command}` : '확인 명령을 비웠습니다(확인 안 함).');
    }
  });
  $('#btn-hl-cancel').addEventListener('click', () => {
    if (state.headlessRun) guard(() => api.cancelScript(state.headlessRun));
  });

  $('#btn-report').addEventListener('click', async () => {
    if (!needExp()) return;
    const out = $('#report-out');
    out.textContent = '';
    const code = await guard(() => runScript('report', { Exp: state.exp.name }, out));
    if (code === 0) showReport();
  });
}

async function init() {
  for (const side of SIDES) makeTerm(side);
  loadPrefs();
  bind();
  BConfig.bind();
  Judging.bind();
  renderPrompt(false);
  renderStatus();
  const info = await guard(() => api.info());
  if (info) {
    $('#lab-info').textContent = `저장소: ${info.labRoot}\nclaude: ${info.claudeExe || '찾지 못함'}\n${info.claudeVersion || ''}\nffmpeg: ${info.ffmpegExe || '없음(녹화는 webm 으로만 저장)'}`;
    if (!info.claudeExe) toast('claude.exe 를 찾지 못했습니다. CC_AB_CLAUDE 환경 변수로 경로를 지정하세요.', true);
  }
  await guard(() => loadExperiments(null));
}

// bconfig.js, judging.js 가 모두 읽힌 뒤 시작한다.
document.addEventListener('DOMContentLoaded', init);
