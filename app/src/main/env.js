// 자식 프로세스(claude, powershell)에 넘길 환경 변수.
// 앱을 Claude Code 세션 안에서 띄웠을 때 넘어오는 세션 변수와 기존 CLAUDE_CONFIG_DIR 을 지운다.
const STRIP = [
  'CLAUDECODE',
  'CLAUDE_CODE_ENTRYPOINT',
  'CLAUDE_CODE_SESSION_ID',
  'CLAUDE_CODE_CHILD_SESSION',
  'CLAUDE_CODE_MESSAGING_SOCKET',
  'CLAUDE_CODE_MESSAGING_TOKEN',
  'CLAUDE_CODE_SESSION_ATTENDED',
  'CLAUDE_PID',
  'CLAUDE_CONFIG_DIR',
  'ELECTRON_RUN_AS_NODE',
];

function buildChildEnv(base, configDir, extra) {
  const strip = new Set(STRIP.map((k) => k.toUpperCase()));
  const out = {};
  for (const [key, value] of Object.entries(base || {})) {
    if (value === undefined || strip.has(key.toUpperCase())) continue;
    out[key] = value;
  }
  if (configDir) out.CLAUDE_CONFIG_DIR = configDir;
  return Object.assign(out, extra || {});
}

module.exports = { STRIP, buildChildEnv };
