// Electron 메인 프로세스: 창, A/B 터미널(node-pty), PowerShell 스크립트 실행, 세션 기록.
const { app, BrowserWindow, Menu, ipcMain, shell, clipboard, dialog } = require('electron');
const fs = require('fs');
const path = require('path');
const { execFile, execFileSync, spawn } = require('child_process');
const pty = require('node-pty');

const { buildChildEnv } = require('./env');
const { runPs, killTree } = require('./powershell');
const { resolveClaude } = require('./claude-resolve');
const lab = require('./lab');
const media = require('./media');

const APP_DIR = path.resolve(__dirname, '..', '..');
const LAB_ROOT = lab.resolveLabRoot(process.env, APP_DIR);
const SIDES = ['A', 'B'];
const SCRIPTS = new Set(['doctor', 'reset', 'run-headless', 'report', 'new-exp', 'list-exp', 'b-config', 'save-live']);
const PERMISSION_MODES = new Set(['', 'manual', 'acceptEdits', 'auto', 'plan', 'dontAsk', 'bypassPermissions']);

let win = null;
let claudeExe = null;
let claudeVersion = '';
let ffmpegExe = null;
const terms = { A: null, B: null };
// { exp, session, launches, start, words, redactors, flushTimers, casts, rec }
// rec: { file, out, startedAt, markers } — 녹화 중일 때만
let live = null;
const scripts = new Map(); // runId -> child
let nextRunId = 1;

// 개발 점검용 기록(CC_AB_TEST_LOG=<파일> 일 때만).
function testLog(message) {
  if (process.env.CC_AB_TEST_LOG) fs.appendFileSync(process.env.CC_AB_TEST_LOG, `${new Date().toISOString()} ${message}\n`);
}

function send(channel, payload) {
  if (win && !win.isDestroyed()) win.webContents.send(channel, payload);
}

function scriptPath(name) {
  if (!SCRIPTS.has(name) && name !== 'start') throw new Error(`허용되지 않은 스크립트: ${name}`);
  return path.join(LAB_ROOT, `${name}.ps1`);
}

// 스크립트도 앱과 같은 claude.exe 를 쓰도록 CC_AB_CLAUDE 로 넘긴다(lib\common.ps1 의 $ClaudeCmd).
function psEnv() {
  return buildChildEnv(process.env, null, claudeExe ? { CC_AB_CLAUDE: claudeExe } : {});
}

function checkSide(side) {
  if (!SIDES.includes(side)) throw new Error(`잘못된 쪽: ${side}`);
  return side;
}

// ---------- 대화형 세션 ----------

async function getLaunch(exp, side, permissionMode) {
  const params = { Exp: exp, Side: side, PrintLaunchJson: true };
  if (permissionMode) params.PermissionMode = permissionMode;
  const { code, stdout, stderr } = await runPs(scriptPath('start'), params, { cwd: LAB_ROOT, env: psEnv() }).done;
  const line = stdout.split(/\r?\n/).map((s) => s.trim()).filter((s) => s.startsWith('{')).pop();
  if (code !== 0 || !line) throw new Error(`start.ps1 실패(${side}): ${stderr || stdout}`.trim());
  return JSON.parse(line);
}

function killTerm(side) {
  const t = terms[side];
  terms[side] = null;
  if (t) {
    try { t.kill(); } catch { /* 이미 끝남 */ }
  }
}

// 세션을 끝내고 그 세션 이름(sessions\<이름>)을 돌려준다. 결과 저장(save-live)은 화면이 이어서 부른다.
function stopLive() {
  for (const side of SIDES) killTerm(side);
  const name = live ? path.basename(live.session.dir) : null;
  if (live) {
    if (live.rec) finishRecording().catch(() => { /* 화면이 먼저 닫힌 경우 */ });
    addMarker('end', '세션 종료');
    try { live.session.updateMeta({ endedAt: new Date().toISOString() }); } catch { /* 기록 실패는 무시 */ }
  }
  live = null;
  return name;
}

// ---------- 표시(markers.jsonl) ----------
// t: 세션 시작 기준 초, rec: 녹화 시작 기준 초(녹화 중일 때만). 터미널 기록(.cast)에도 표시를 남긴다.
function addMarker(kind, label, extra) {
  if (!live) return null;
  const now = Date.now();
  const m = {
    time: new Date(now).toISOString(), kind, label: String(label || ''),
    t: Math.round((now - live.start) / 100) / 10,
    rec: live.rec && live.rec.startedAt ? Math.round((now - live.rec.startedAt) / 100) / 10 : null,
    ...(extra || {}),
  };
  try { live.session.appendMarker(m); } catch { /* 기록 실패는 무시 */ }
  for (const side of SIDES) if (live.casts[side]) live.casts[side].marker(m.label || kind);
  if (live.rec && live.rec.startedAt) live.rec.markers.push(m);
  return m;
}

// ---------- 계정 정보 가리기 ----------

function authStatus(configDir) {
  // 실패하면 null(가리지 못한 채 진행하고 화면에 알림). 실행 자체가 막히면(EINVAL 등) execFile 이 바로 throw 한다.
  return new Promise((resolve) => {
    try {
      execFile(claudeExe, ['auth', 'status'], { encoding: 'utf8', windowsHide: true, timeout: 20000, env: buildChildEnv(process.env, configDir) },
        (_err, stdout) => {
          const text = String(stdout || '');
          try { resolve(JSON.parse(text.slice(text.indexOf('{')))); } catch { resolve(null); }
        });
    } catch { resolve(null); }
  });
}

// ---------- 녹화 ----------
// 화면(렌더러)이 getDisplayMedia + MediaRecorder 로 앱 화면을 webm 조각으로 보내면 파일에 이어 쓴다.
// 끝나면 표시로 유튜브 챕터를 만들고, ffmpeg 가 있으면 mp4 로 바꾼다.

async function finishRecording() {
  const rec = live && live.rec;
  if (!rec) throw new Error('녹화 중이 아닙니다.');
  addMarker('rec-stop', '녹화 끝');
  live.rec = null;
  await new Promise((resolve) => rec.out.end(resolve));
  const base = rec.file.replace(/\.webm$/, '');
  const chapters = media.buildChapters(rec.markers);
  fs.writeFileSync(`${base}-chapters.txt`, chapters.lines.join('\n') + '\n');
  fs.writeFileSync(`${base}-markers.json`, JSON.stringify(rec.markers, null, 2));
  const result = { file: rec.file, chapters, mp4: null, converting: false };
  if (ffmpegExe && fs.statSync(rec.file).size > 0) {
    result.converting = true;
    result.mp4 = `${base}.mp4`;
    execFile(ffmpegExe, media.mp4Args(rec.file, result.mp4), { windowsHide: true, timeout: 30 * 60 * 1000 }, (err, _o, stderr) => {
      send('rec:converted', { ok: !err, mp4: result.mp4, error: err ? String(stderr || err.message).trim().split(/\r?\n/).pop() : '' });
    });
  }
  return result;
}

async function startLive({ exp, reset, permissionMode, sizes, mask }) {
  lab.assertName(exp);
  if (!PERMISSION_MODES.has(permissionMode || '')) throw new Error(`잘못된 권한 모드: ${permissionMode}`);
  if (!claudeExe) throw new Error('claude.exe 를 찾지 못했습니다. Claude Code 설치를 확인하거나 CC_AB_CLAUDE 환경 변수로 경로를 지정하세요.');
  stopLive();

  // 이전 세션을 "종료" 없이 닫았으면(창 닫기 등) 작업 폴더를 건드리기 전에 그 결과를 먼저 남긴다.
  const pending = await runPs(scriptPath('save-live'), { Exp: exp, Pending: true }, { cwd: LAB_ROOT, env: psEnv() }).done;
  if (pending.code !== 0) throw new Error(`이전 대화형 세션 결과를 남기지 못했습니다: ${pending.stderr || pending.stdout}`.trim());

  if (reset) {
    const r = await runPs(scriptPath('reset'), { Exp: exp }, { cwd: LAB_ROOT, env: psEnv() }).done;
    if (r.code !== 0) throw new Error(`작업 폴더 초기화 실패: ${r.stderr || r.stdout}`.trim());
  }
  const launches = {};
  for (const side of SIDES) launches[side] = await getLaunch(exp, side, permissionMode);

  // 계정 정보 가리기: 양쪽 로그인 계정의 이메일·조직 이름을 화면·터미널 기록·캡처·녹화에서 '*'로 바꾼다(원본 .log 는 그대로).
  const words = mask ? media.redactWords(await Promise.all(SIDES.map((s) => authStatus(launches[s].config)))) : [];

  const session = lab.createSession(lab.experimentDir(LAB_ROOT, exp), {
    experiment: exp, claudeExe, claudeVersion, reset: !!reset, permissionMode: permissionMode || '', launches,
    mask: !!mask, maskedWords: words.length,
    autoSave: true, // 종료 때(또는 다음 초기화 전에) results\<세션>-live\ 로 결과를 남긴다(save-live.ps1)
  });
  live = { exp, session, launches, start: Date.now(), words, redactors: {}, flushTimers: {}, casts: {}, rec: null };
  addMarker('start', '세션 시작');

  for (const side of SIDES) {
    const size = (sizes && sizes[side]) || {};
    spawnSide(side, size.cols, size.rows);
  }
  return { sessionDir: session.dir, launches, masked: words.length };
}

// start.ps1 이 준 설정 폴더·작업 폴더·인자로 claude.exe 를 가상 터미널에서 실행한다.
function spawnSide(side, cols, rows) {
  const l = live.launches[side];
  const p = pty.spawn(claudeExe, l.args, {
    name: 'xterm-256color',
    cols: cols || 100,
    rows: rows || 30,
    cwd: l.work,
    env: buildChildEnv(process.env, l.config, { COLORTERM: 'truecolor' }),
  });
  terms[side] = p;
  // 터미널 기록(.cast)은 세션마다 쪽별로 하나. 다시 시작하면 화면을 지우는 신호(RIS)를 넣고 이어 쓴다.
  if (live.casts[side]) live.casts[side].output('\x1bc');
  else live.casts[side] = media.createCast(path.join(live.session.dir, `${side}.cast`), { cols, rows, title: `${live.exp} ${side}`, start: live.start });
  const cast = live.casts[side];
  const redactor = media.createRedactor(live.words);
  live.redactors[side] = redactor;
  const emit = (text) => {
    if (!text) return;
    cast.output(text);
    send('live:data', { side, data: text });
  };
  p.onData((data) => {
    if (terms[side] !== p || !live) return; // 이미 끝내거나 바꾼 프로세스의 남은 출력
    live.session.appendOutput(side, data);
    emit(redactor.push(data));
    // 낱말 앞부분일 수 있어 잡아 둔 글자는 잠시 출력이 없으면 내보낸다.
    clearTimeout(live.flushTimers[side]);
    live.flushTimers[side] = setTimeout(() => { if (live && live.redactors[side] === redactor) emit(redactor.flush()); }, 60);
  });
  p.onExit(({ exitCode }) => {
    // 다시 시작해서 이미 새 프로세스로 바뀌었으면 이전 프로세스의 종료는 알리지 않는다.
    if (terms[side] && terms[side] !== p) return;
    terms[side] = null;
    send('live:exit', { side, code: exitCode });
  });
}

// ---------- IPC ----------

function handle(channel, fn) {
  ipcMain.handle(channel, async (_e, ...args) => {
    try {
      return { ok: true, value: await fn(...args) };
    } catch (err) {
      return { ok: false, error: String(err && err.message ? err.message : err) };
    }
  });
}

function registerIpc() {
  handle('lab:info', () => ({ labRoot: LAB_ROOT, claudeExe, claudeVersion, ffmpegExe }));
  handle('exp:list', () => lab.listExperiments(LAB_ROOT));
  handle('exp:prompt', (exp, name) => lab.readPrompt(lab.experimentDir(LAB_ROOT, exp), name));
  handle('exp:report', (exp) => {
    const file = path.join(lab.experimentDir(LAB_ROOT, exp), 'REPORT.md');
    return fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '';
  });
  // 판정 카드 자료(report.ps1 이 쓰는 decision.json). PowerShell 이 BOM 을 붙일 수 있어 떼고 읽는다.
  handle('exp:decision', (exp) => {
    const file = path.join(lab.experimentDir(LAB_ROOT, exp), 'decision.json');
    if (!fs.existsSync(file)) return null;
    try { return JSON.parse(fs.readFileSync(file, 'utf8').replace(/^﻿/, '')); } catch { return null; }
  });

  handle('live:start', (opts) => startLive(opts || {}));
  handle('live:stop', () => stopLive());
  handle('live:restart', async (side, opts) => {
    checkSide(side);
    if (!live) throw new Error('진행 중인 세션이 없습니다.');
    killTerm(side);
    spawnSide(side, opts && opts.cols, opts && opts.rows);
    live.session.logTurn({ event: 'restart', side });
    addMarker('restart', `${side} 다시 시작`, { side });
  });
  ipcMain.on('live:write', (_e, side, data) => {
    if (SIDES.includes(side) && terms[side] && typeof data === 'string') terms[side].write(data);
  });
  ipcMain.on('live:resize', (_e, side, cols, rows) => {
    if (SIDES.includes(side) && terms[side] && cols > 0 && rows > 0) {
      try { terms[side].resize(Math.floor(cols), Math.floor(rows)); } catch { /* 끝난 터미널 */ }
      if (live && live.casts[side]) live.casts[side].resize(Math.floor(cols), Math.floor(rows));
    }
  });
  handle('live:logTurn', (record) => {
    if (!live) throw new Error('진행 중인 세션이 없습니다.');
    live.session.logTurn(record);
  });

  // 표시: 화면이 보내는 것(전송, 멈춤 추정, 직접 표시)
  handle('mark:add', (kind, label) => {
    if (!['send', 'done', 'manual'].includes(kind)) throw new Error(`잘못된 표시 종류: ${kind}`);
    if (!live) throw new Error('진행 중인 세션이 없습니다.');
    return addMarker(kind, String(label || '').slice(0, 200));
  });
  // 화면 캡처: 세션 기록 폴더의 shots\ 에 PNG 로 저장
  handle('shot:take', async (kind) => {
    if (!live) throw new Error('진행 중인 세션이 없습니다.');
    const tag = String(kind || 'manual').replace(/[^a-z0-9-]/gi, '').slice(0, 20) || 'manual';
    const img = await win.webContents.capturePage();
    const dir = path.join(live.session.dir, 'shots');
    fs.mkdirSync(dir, { recursive: true });
    const m = addMarker('shot', tag);
    const clock = media.formatClock(m.rec !== null ? m.rec : m.t).replace(/:/g, '-');
    const file = path.join(dir, `${String(fs.readdirSync(dir).length + 1).padStart(3, '0')}-${clock}-${tag}.png`);
    fs.writeFileSync(file, img.toPNG());
    return file;
  });
  handle('rec:start', () => {
    if (!live) throw new Error('세션을 먼저 시작하세요.');
    if (live.rec) throw new Error('이미 녹화 중입니다.');
    const dir = path.join(live.session.dir, 'recordings');
    fs.mkdirSync(dir, { recursive: true });
    const file = path.join(dir, `rec-${lab.stamp()}.webm`);
    live.rec = { file, out: fs.createWriteStream(file), startedAt: 0, markers: [] };
    return { file };
  });
  handle('rec:started', () => {
    if (!live || !live.rec) throw new Error('녹화 준비가 안 됐습니다.');
    live.rec.startedAt = Date.now();
    addMarker('rec-start', '녹화 시작', { file: path.basename(live.rec.file) });
  });
  ipcMain.on('rec:chunk', (_e, buf) => {
    if (live && live.rec && buf && buf.byteLength) live.rec.out.write(Buffer.from(buf));
  });
  handle('rec:stop', () => finishRecording());
  handle('rec:abort', async () => {
    if (!live || !live.rec) return;
    const { file, out } = live.rec;
    live.rec = null;
    await new Promise((resolve) => out.end(resolve));
    fs.rmSync(file, { force: true });
  });

  handle('script:run', (name, params) => {
    const runId = nextRunId++;
    const { child, done } = runPs(scriptPath(name), params || {}, {
      cwd: LAB_ROOT,
      env: psEnv(),
      onLine: (line, kind) => send('script:line', { runId, line, kind }),
    });
    scripts.set(runId, child);
    done.then(({ code }) => {
      scripts.delete(runId);
      send('script:done', { runId, code });
    });
    return runId;
  });
  // -Json 으로 실행해 마지막 JSON 줄을 돌려준다. 실패하면 PowerShell 오류의 첫 줄을 메시지로.
  handle('script:json', async (name, params) => {
    const { code, stdout, stderr } = await runPs(scriptPath(name), { ...(params || {}), Json: true }, { cwd: LAB_ROOT, env: psEnv() }).done;
    if (code !== 0) {
      const first = (stderr || stdout).split(/\r?\n/).map((s) => s.trim()).find((s) => s && !/^At |^\+|^\s*\+/.test(s));
      throw new Error(first || `${name} 실패(종료 코드 ${code})`);
    }
    const line = stdout.split(/\r?\n/).map((s) => s.trim()).filter((s) => s.startsWith('{') || s.startsWith('[')).pop();
    if (!line) throw new Error(`${name}: JSON 결과가 없습니다.`);
    return JSON.parse(line);
  });
  handle('dialog:folder', async (title) => {
    const r = await dialog.showOpenDialog(win, { title: String(title || '폴더 선택'), properties: ['openDirectory'] });
    return r.canceled ? null : r.filePaths[0];
  });
  handle('exp:setCheck', (exp, check) => lab.updateExperimentCheck(lab.experimentDir(LAB_ROOT, exp), check));
  handle('results:list', (exp) => lab.listResultRuns(lab.experimentDir(LAB_ROOT, exp)));
  handle('results:items', (exp, run) => lab.readRunItems(lab.experimentDir(LAB_ROOT, exp), run));
  handle('results:save', (exp, run, items) => lab.saveJudgments(lab.experimentDir(LAB_ROOT, exp), run, items));

  handle('script:cancel', (runId) => {
    const child = scripts.get(runId);
    if (child) killTree(child.pid);
  });

  // 새 콘솔 창에서 login.ps1 을 연다.
  // - powershell 을 detached 로 직접 띄우면 표준 입력이 NUL 이라 -NoExit 이어도 바로 닫힌다 → cmd 의 start 로 새 콘솔을 만든다.
  // - Node 가 인자를 다시 따옴표 처리하면 start 의 "제목"이 명령으로 해석되므로 windowsVerbatimArguments 로 그대로 넘긴다.
  handle('shell:login', (exp) => {
    const parts = ['start', '"Claude Code 로그인"', 'powershell.exe', '-NoExit', '-ExecutionPolicy', 'Bypass',
      '-File', `"${path.join(LAB_ROOT, 'login.ps1')}"`];
    if (exp) parts.push('-Exp', lab.assertName(exp));
    spawn('cmd.exe', ['/d', '/s', '/c', `"${parts.join(' ')}"`], {
      cwd: LAB_ROOT, env: psEnv(), windowsVerbatimArguments: true, detached: true, stdio: 'ignore', windowsHide: true,
    }).unref();
  });
  handle('shell:open', (target, exp) => {
    let p = LAB_ROOT;
    if (target === 'exp') p = lab.experimentDir(LAB_ROOT, exp);
    else if (target === 'session') { if (!live) throw new Error('진행 중인 세션이 없습니다.'); p = live.session.dir; }
    else if (target === 'recordings') {
      if (!live) throw new Error('진행 중인 세션이 없습니다.');
      p = path.join(live.session.dir, 'recordings');
      fs.mkdirSync(p, { recursive: true });
    }
    else if (target === 'workA' || target === 'workB') {
      if (!live) throw new Error('진행 중인 세션이 없습니다.');
      p = live.launches[target.slice(-1)].work;
    }
    return shell.openPath(p);
  });
  handle('clip:write', (text) => clipboard.writeText(String(text)));
  handle('win:size', (w, h) => {
    if (win && Number.isInteger(w) && Number.isInteger(h)) win.setContentSize(w, h);
  });
}

// ---------- 창 ----------

function createWindow() {
  win = new BrowserWindow({
    width: 1600,
    height: 960,
    minWidth: 1100,
    minHeight: 700,
    title: 'Claude Code A/B 랩',
    backgroundColor: '#050505',
    webPreferences: {
      preload: path.join(__dirname, 'preload.js'),
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });
  // 앱 메뉴를 없애 Ctrl+W(창 닫기), Ctrl+R(새로고침) 같은 기본 단축키가 터미널 키를 가로채지 않게 한다.
  Menu.setApplicationMenu(null);
  win.webContents.on('will-navigate', (e) => e.preventDefault());
  // 화면 녹화 요청: 녹화를 준비한 때(rec:start)만, 이 앱 화면(창 테두리 제외)만 허락한다. 다른 창·전체 화면은 주지 않는다.
  win.webContents.session.setDisplayMediaRequestHandler((request, callback) => {
    const ok = live && live.rec && !live.rec.startedAt && request.frame && request.frame === win.webContents.mainFrame;
    callback(ok ? { video: win.webContents.mainFrame } : null);
  });
  win.webContents.setWindowOpenHandler(() => ({ action: 'deny' }));
  win.webContents.on('before-input-event', (event, input) => {
    if (process.env.CC_AB_DEV === '1' && input.type === 'keyDown' && input.key === 'F12') {
      win.webContents.toggleDevTools();
      event.preventDefault();
    }
  });
  win.webContents.on('console-message', (event) => {
    if (process.env.CC_AB_DEV === '1') console.log(`[renderer] ${event.message}`);
    testLog(`[renderer] ${event.message}`);
  });
  win.webContents.on('did-fail-load', (_e, code, desc, url) => testLog(`did-fail-load ${code} ${desc} ${url}`));
  win.webContents.on('render-process-gone', (_e, details) => testLog(`render-process-gone ${JSON.stringify(details)}`));
  win.loadFile(path.join(__dirname, '..', 'renderer', 'index.html'));

  // 점검용(개발 중에만): CC_AB_TEST_SCRIPT=<js 파일> 이면 화면에서 그 스크립트를 실행하고,
  // CC_AB_SNAPSHOT=<png 경로> 이면 그 뒤 화면을 저장하고 끝낸다.
  if (process.env.CC_AB_SNAPSHOT || process.env.CC_AB_TEST_SCRIPT) {
    win.webContents.once('did-finish-load', async () => {
      testLog('did-finish-load');
      await new Promise((r) => setTimeout(r, 1000));
      if (process.env.CC_AB_TEST_SCRIPT) {
        try {
          const result = await win.webContents.executeJavaScript(fs.readFileSync(process.env.CC_AB_TEST_SCRIPT, 'utf8'));
          testLog(`test result ${JSON.stringify(result)}`);
        } catch (err) {
          testLog(`test error ${String(err)}`);
        }
      }
      await new Promise((r) => setTimeout(r, Number(process.env.CC_AB_SNAPSHOT_DELAY || 500)));
      if (process.env.CC_AB_SNAPSHOT) {
        const img = await win.webContents.capturePage();
        fs.writeFileSync(process.env.CC_AB_SNAPSHOT, img.toPNG());
        testLog('snapshot saved');
      }
      stopLive();  // 세션을 띄운 점검이면 터미널을 먼저 닫아야 앱이 끝난다
      app.quit();
    });
  }
  win.on('closed', () => { win = null; });
}

// 앱은 하나만 띄운다. 두 개가 뜨면 같은 작업 폴더를 서로 초기화해 다른 쪽 세션의 작업을 지울 수 있다.
const gotLock = app.requestSingleInstanceLock();
if (!gotLock) {
  app.quit();
} else {
  app.on('second-instance', () => {
    if (!win) return;
    if (win.isMinimized()) win.restore();
    win.focus();
  });
}

app.whenReady().then(() => {
  if (!gotLock) return;
  claudeExe = resolveClaude();
  if (claudeExe) {
    try {
      claudeVersion = execFileSync(claudeExe, ['--version'], { encoding: 'utf8', windowsHide: true, env: buildChildEnv(process.env) }).trim();
    } catch { claudeVersion = '(버전 확인 실패)'; }
  }
  ffmpegExe = media.resolveFfmpeg();
  registerIpc();
  createWindow();
});

app.on('window-all-closed', () => {
  stopLive();
  for (const child of scripts.values()) killTree(child.pid);
  app.quit();
});
