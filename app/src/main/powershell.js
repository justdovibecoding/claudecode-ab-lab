// 저장소의 PowerShell 스크립트를 실행한다. 출력은 UTF-8 로 받는다.
const { spawn } = require('child_process');

function psQuote(value) {
  return "'" + String(value).replace(/'/g, "''") + "'";
}

// { Exp: 'x', Runs: 3, NoReset: true } -> powershell.exe 인자 배열
function buildPsArgs(scriptPath, params) {
  const parts = [
    '[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false;',
    '&',
    psQuote(scriptPath),
  ];
  for (const [key, value] of Object.entries(params || {})) {
    if (!/^[A-Za-z]+$/.test(key)) throw new Error(`잘못된 매개변수 이름: ${key}`);
    if (value === true) parts.push(`-${key}`);
    else if (value === false || value === null || value === undefined || value === '') continue;
    else parts.push(`-${key}`, psQuote(value));
  }
  return ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', parts.join(' ')];
}

// 한 줄씩 onLine 으로 넘기고, 끝나면 { code, stdout, stderr } 로 끝나는 promise 를 준다.
function runPs(scriptPath, params, { cwd, env, onLine } = {}) {
  const child = spawn('powershell.exe', buildPsArgs(scriptPath, params), { cwd, env, windowsHide: true });
  let stdout = '';
  let stderr = '';
  const pending = { out: '', err: '' };
  const feed = (kind, chunk) => {
    if (kind === 'out') stdout += chunk; else stderr += chunk;
    pending[kind] += chunk;
    const lines = pending[kind].split(/\r?\n/);
    pending[kind] = lines.pop();
    if (onLine) for (const line of lines) onLine(line, kind);
  };
  child.stdout.setEncoding('utf8');
  child.stderr.setEncoding('utf8');
  child.stdout.on('data', (c) => feed('out', c));
  child.stderr.on('data', (c) => feed('err', c));
  const done = new Promise((resolve) => {
    child.on('error', (err) => resolve({ code: -1, stdout, stderr: stderr + String(err) }));
    child.on('close', (code) => {
      for (const kind of ['out', 'err']) if (pending[kind] && onLine) onLine(pending[kind], kind);
      resolve({ code, stdout, stderr });
    });
  });
  return { child, done };
}

// 자식 프로세스까지 함께 끝낸다(run-headless 가 띄운 claude 포함).
function killTree(pid) {
  if (!pid) return;
  spawn('taskkill', ['/PID', String(pid), '/T', '/F'], { windowsHide: true });
}

module.exports = { psQuote, buildPsArgs, runPs, killTree };
