// Electron 메인 프로세스: 창, A/B 터미널(node-pty), PowerShell 스크립트 실행, 세션 기록.
const { app, BrowserWindow, Menu, ipcMain, shell, clipboard, dialog } = require('electron');
const fs = require('fs');
const path = require('path');
const { execFileSync, spawn } = require('child_process');
const pty = require('node-pty');

const { buildChildEnv } = require('./env');
const { runPs, killTree } = require('./powershell');
const { resolveClaude } = require('./claude-resolve');
const lab = require('./lab');

const APP_DIR = path.resolve(__dirname, '..', '..');
const LAB_ROOT = lab.resolveLabRoot(process.env, APP_DIR);
const SIDES = ['A', 'B'];
const SCRIPTS = new Set(['doctor', 'reset', 'run-headless', 'report', 'new-exp', 'list-exp', 'b-config']);
const PERMISSION_MODES = new Set(['', 'manual', 'acceptEdits', 'auto', 'plan', 'dontAsk', 'bypassPermissions']);

let win = null;
let claudeExe = null;
let claudeVersion = '';
const terms = { A: null, B: null };
let live = null; // { exp, session, launches }
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

function psEnv() {
  return buildChildEnv(process.env);
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

function stopLive() {
  for (const side of SIDES) killTerm(side);
  if (live) {
    try { live.session.updateMeta({ endedAt: new Date().toISOString() }); } catch { /* 기록 실패는 무시 */ }
  }
  live = null;
}

async function startLive({ exp, reset, permissionMode, sizes }) {
  lab.assertName(exp);
  if (!PERMISSION_MODES.has(permissionMode || '')) throw new Error(`잘못된 권한 모드: ${permissionMode}`);
  if (!claudeExe) throw new Error('claude.exe 를 찾지 못했습니다. Claude Code 설치를 확인하거나 CC_AB_CLAUDE 환경 변수로 경로를 지정하세요.');
  stopLive();

  if (reset) {
    const r = await runPs(scriptPath('reset'), { Exp: exp }, { cwd: LAB_ROOT, env: psEnv() }).done;
    if (r.code !== 0) throw new Error(`작업 폴더 초기화 실패: ${r.stderr || r.stdout}`.trim());
  }
  const launches = {};
  for (const side of SIDES) launches[side] = await getLaunch(exp, side, permissionMode);

  const session = lab.createSession(lab.experimentDir(LAB_ROOT, exp), {
    experiment: exp, claudeExe, claudeVersion, reset: !!reset, permissionMode: permissionMode || '', launches,
  });
  live = { exp, session, launches };

  for (const side of SIDES) {
    const size = (sizes && sizes[side]) || {};
    spawnSide(side, size.cols, size.rows);
  }
  return { sessionDir: session.dir, launches };
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
  p.onData((data) => {
    if (terms[side] !== p) return; // 이미 끝내거나 바꾼 프로세스의 남은 출력
    if (live && live.session) live.session.appendOutput(side, data);
    send('live:data', { side, data });
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
  handle('lab:info', () => ({ labRoot: LAB_ROOT, claudeExe, claudeVersion }));
  handle('exp:list', () => lab.listExperiments(LAB_ROOT));
  handle('exp:prompt', (exp, name) => lab.readPrompt(lab.experimentDir(LAB_ROOT, exp), name));
  handle('exp:report', (exp) => {
    const file = path.join(lab.experimentDir(LAB_ROOT, exp), 'REPORT.md');
    return fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '';
  });

  handle('live:start', (opts) => startLive(opts || {}));
  handle('live:stop', () => stopLive());
  handle('live:restart', async (side, opts) => {
    checkSide(side);
    if (!live) throw new Error('진행 중인 세션이 없습니다.');
    killTerm(side);
    spawnSide(side, opts && opts.cols, opts && opts.rows);
    live.session.logTurn({ event: 'restart', side });
  });
  ipcMain.on('live:write', (_e, side, data) => {
    if (SIDES.includes(side) && terms[side] && typeof data === 'string') terms[side].write(data);
  });
  ipcMain.on('live:resize', (_e, side, cols, rows) => {
    if (SIDES.includes(side) && terms[side] && cols > 0 && rows > 0) {
      try { terms[side].resize(Math.floor(cols), Math.floor(rows)); } catch { /* 끝난 터미널 */ }
    }
  });
  handle('live:logTurn', (record) => {
    if (!live) throw new Error('진행 중인 세션이 없습니다.');
    live.session.logTurn(record);
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

  handle('shell:login', (exp) => {
    const params = ['-NoExit', '-ExecutionPolicy', 'Bypass', '-File', path.join(LAB_ROOT, 'login.ps1')];
    if (exp) params.push('-Exp', lab.assertName(exp));
    spawn('cmd.exe', ['/c', 'start', '"Claude Code 로그인"', 'powershell.exe', ...params], {
      cwd: LAB_ROOT, env: psEnv(), detached: true, windowsHide: true,
    }).unref();
  });
  handle('shell:open', (target, exp) => {
    let p = LAB_ROOT;
    if (target === 'exp') p = lab.experimentDir(LAB_ROOT, exp);
    else if (target === 'session') { if (!live) throw new Error('진행 중인 세션이 없습니다.'); p = live.session.dir; }
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
    backgroundColor: '#E9ECF1',
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
      app.quit();
    });
  }
  win.on('closed', () => { win = null; });
}

app.whenReady().then(() => {
  claudeExe = resolveClaude();
  if (claudeExe) {
    try {
      claudeVersion = execFileSync(claudeExe, ['--version'], { encoding: 'utf8', windowsHide: true, env: buildChildEnv(process.env) }).trim();
    } catch { claudeVersion = '(버전 확인 실패)'; }
  }
  registerIpc();
  createWindow();
});

app.on('window-all-closed', () => {
  stopLive();
  for (const child of scripts.values()) killTree(child.pid);
  app.quit();
});
