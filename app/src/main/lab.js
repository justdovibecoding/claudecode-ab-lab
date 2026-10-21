// 저장소(실험 폴더) 읽기와 대화형 세션 기록.
const fs = require('fs');
const path = require('path');

const NAME_RE = /^[A-Za-z0-9._-]+$/;
const VARIANT_RE = /\.(A|B)\.md$/i;

function resolveLabRoot(env, appDir) {
  return env.CC_AB_LAB_ROOT ? path.resolve(env.CC_AB_LAB_ROOT) : path.resolve(appDir, '..');
}

function assertName(name) {
  if (typeof name !== 'string' || !NAME_RE.test(name)) throw new Error(`잘못된 이름: ${name}`);
  return name;
}

function readJson(file) {
  return JSON.parse(fs.readFileSync(file, 'utf8').replace(/^﻿/, ''));
}

function subdirs(dir) {
  try {
    return fs.readdirSync(dir, { withFileTypes: true }).filter((d) => d.isDirectory()).map((d) => d.name);
  } catch {
    return [];
  }
}

function experimentDir(labRoot, name) {
  return path.join(labRoot, 'experiments', assertName(name));
}

function listPrompts(expDir) {
  let files = [];
  try {
    files = fs.readdirSync(path.join(expDir, 'prompts')).filter((f) => f.toLowerCase().endsWith('.md'));
  } catch {
    return [];
  }
  const set = new Set(files.map((f) => f.toLowerCase()));
  return files
    .filter((f) => !VARIANT_RE.test(f))
    .map((f) => {
      const base = f.slice(0, -3);
      return {
        name: base,
        hasA: set.has(`${base}.a.md`.toLowerCase()),
        hasB: set.has(`${base}.b.md`.toLowerCase()),
      };
    })
    .sort((a, b) => a.name.localeCompare(b.name));
}

// 지시문과 쪽별 변형(.A.md/.B.md). 없는 쪽은 null.
function readPrompt(expDir, name) {
  assertName(name);
  const read = (file) => {
    const p = path.join(expDir, 'prompts', file);
    return fs.existsSync(p) ? fs.readFileSync(p, 'utf8').replace(/^﻿/, '') : null;
  };
  return { common: read(`${name}.md`) || '', A: read(`${name}.A.md`), B: read(`${name}.B.md`) };
}

function listExperiments(labRoot) {
  const root = path.join(labRoot, 'experiments');
  return subdirs(root)
    .filter((name) => NAME_RE.test(name) && fs.existsSync(path.join(root, name, 'experiment.json')))
    .map((name) => {
      const dir = path.join(root, name);
      let meta = {};
      try {
        meta = readJson(path.join(dir, 'experiment.json'));
      } catch {
        meta = { description: '(experiment.json 을 읽지 못함)' };
      }
      return {
        name,
        description: meta.description || '',
        model: meta.model || '',
        plugins: subdirs(path.join(dir, 'plugins')),
        skills: subdirs(path.join(dir, 'skills')),
        installed: fs.existsSync(path.join(dir, 'config-B', 'plugins', 'installed_plugins.json')),
        prompts: listPrompts(dir),
        results: subdirs(path.join(dir, 'results')).length,
        bLogin: fs.existsSync(path.join(dir, 'config-B', '.credentials.json')),
      };
    });
}

function stamp(date = new Date()) {
  const p = (n) => String(n).padStart(2, '0');
  return `${date.getFullYear()}${p(date.getMonth() + 1)}${p(date.getDate())}-${p(date.getHours())}${p(date.getMinutes())}${p(date.getSeconds())}`;
}

// 대화형 세션 기록: experiments\<이름>\sessions\<시각>\ 에 A.log, B.log(터미널 출력 원본), turns.jsonl(전송 기록)
function createSession(expDir, meta) {
  const dir = path.join(expDir, 'sessions', stamp());
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(path.join(dir, 'session.json'), JSON.stringify({ ...meta, startedAt: new Date().toISOString() }, null, 2));
  return {
    dir,
    appendOutput(side, data) {
      fs.appendFileSync(path.join(dir, `${side}.log`), data);
    },
    logTurn(record) {
      fs.appendFileSync(path.join(dir, 'turns.jsonl'), JSON.stringify({ time: new Date().toISOString(), ...record }) + '\n');
    },
    updateMeta(patch) {
      const file = path.join(dir, 'session.json');
      const cur = readJson(file);
      fs.writeFileSync(file, JSON.stringify({ ...cur, ...patch }, null, 2));
    },
  };
}

module.exports = {
  NAME_RE, resolveLabRoot, assertName, experimentDir, listExperiments, listPrompts, readPrompt, createSession, stamp,
};
