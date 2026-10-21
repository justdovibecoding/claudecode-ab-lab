// 터미널에서 직접 실행할 claude.exe 위치를 찾는다.
// npm 설치는 claude / claude.cmd / claude.ps1 껍데기만 PATH 에 있고 실제 파일은 node_modules 안에 있다.
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

function defaultWhere(name) {
  try {
    return execFileSync('where.exe', [name], { encoding: 'utf8', windowsHide: true })
      .split(/\r?\n/)
      .map((s) => s.trim())
      .filter(Boolean);
  } catch {
    return [];
  }
}

function resolveClaude({ env = process.env, exists = fs.existsSync, where = defaultWhere } = {}) {
  if (env.CC_AB_CLAUDE && exists(env.CC_AB_CLAUDE)) return env.CC_AB_CLAUDE;
  for (const candidate of where('claude')) {
    if (candidate.toLowerCase().endsWith('.exe')) return candidate;
    const npmExe = path.win32.join(path.win32.dirname(candidate), 'node_modules', '@anthropic-ai', 'claude-code', 'bin', 'claude.exe');
    if (exists(npmExe)) return npmExe;
  }
  // 설치 스크립트(네이티브) 기본 위치
  if (env.USERPROFILE) {
    const native = path.win32.join(env.USERPROFILE, '.local', 'bin', 'claude.exe');
    if (exists(native)) return native;
  }
  return null;
}

module.exports = { resolveClaude };
