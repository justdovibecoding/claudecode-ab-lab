// 저장소(실험 폴더) 읽기와 대화형 세션 기록.
const fs = require('fs');
const path = require('path');

// 실험 이름: 영문·숫자·._- 만, 단 "." ".." 처럼 점으로만 된 이름은 상위 폴더를 가리키므로 거부한다.
const NAME_RE = /^(?!\.+$)[A-Za-z0-9._-]+$/;
// 지시문·결과 폴더 이름: 한글 등 허용. 경로 구분자, Windows 금지 문자, 제어 문자, 점으로만 된 이름만 거부한다.
// eslint-disable-next-line no-control-regex
const FILE_NAME_RE = /^(?!\.+$)[^\\/:*?"<>|\x00-\x1f]+$/;
const VARIANT_RE = /\.(A|B)\.md$/i;

function resolveLabRoot(env, appDir) {
  return env.CC_AB_LAB_ROOT ? path.resolve(env.CC_AB_LAB_ROOT) : path.resolve(appDir, '..');
}

function assertName(name) {
  if (typeof name !== 'string' || !NAME_RE.test(name)) throw new Error(`잘못된 이름: ${name}`);
  return name;
}

function assertFileName(name) {
  if (typeof name !== 'string' || name.length > 200 || !FILE_NAME_RE.test(name)) throw new Error(`잘못된 이름: ${name}`);
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
  assertFileName(name);
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
        check: {
          command: (meta.check && meta.check.command) || '',
          timeoutSec: (meta.check && meta.check.timeoutSec) || 600,
        },
        plugins: subdirs(path.join(dir, 'plugins')),
        skills: subdirs(path.join(dir, 'skills')),
        installed: fs.existsSync(path.join(dir, 'config-B', 'plugins', 'installed_plugins.json')),
        prompts: listPrompts(dir),
        // 결과 화면·보고서와 같이 summary.csv 가 있는(끝까지 돈) 측정만 센다.
        results: subdirs(path.join(dir, 'results')).filter((r) => fs.existsSync(path.join(dir, 'results', r, 'summary.csv'))).length,
        bLogin: fs.existsSync(path.join(dir, 'config-B', '.credentials.json')),
      };
    });
}

function stamp(date = new Date()) {
  const p = (n) => String(n).padStart(2, '0');
  return `${date.getFullYear()}${p(date.getMonth() + 1)}${p(date.getDate())}-${p(date.getHours())}${p(date.getMinutes())}${p(date.getSeconds())}`;
}

// 대화형 세션 기록: experiments\<이름>\sessions\<시각>\ 에 A.log, B.log(터미널 출력 원본), turns.jsonl(전송 기록),
// markers.jsonl(표시). A.cast·B.cast(터미널 기록), shots\, recordings\ 는 main.js 가 쓴다.
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
    // 표시(전송·멈춤 추정·캡처·녹화 시작/끝 등). 녹화 챕터와 편집용.
    appendMarker(marker) {
      fs.appendFileSync(path.join(dir, 'markers.jsonl'), JSON.stringify(marker) + '\n');
    },
    updateMeta(patch) {
      const file = path.join(dir, 'session.json');
      const cur = readJson(file);
      fs.writeFileSync(file, JSON.stringify({ ...cur, ...patch }, null, 2));
    },
  };
}

// 품질 확인 명령(experiment.json 의 check). 다른 항목은 그대로 둔다.
function updateExperimentCheck(expDir, check) {
  const file = path.join(expDir, 'experiment.json');
  const meta = readJson(file);
  const command = String((check && check.command) || '').trim();
  if (command.length > 500) throw new Error('확인 명령이 너무 깁니다(500자 이하).');
  const timeoutSec = Math.round(Number(check && check.timeoutSec) || 600);
  if (timeoutSec < 10 || timeoutSec > 7200) throw new Error('제한 시간은 10–7200초 사이여야 합니다.');
  meta.check = { command, timeoutSec };
  fs.writeFileSync(file, JSON.stringify(meta, null, 2) + '\n');
  return meta.check;
}

// ---------- 반복 측정 결과와 블라인드 판정 ----------

const Judge = require('../shared/judge');
const RESULT_KEY_FILE = /^(A|B)-(\d+)\.json$/;

function readText(file, limit) {
  if (!fs.existsSync(file)) return null;
  const text = fs.readFileSync(file, 'utf8').replace(/^﻿/, '');
  return limit && text.length > limit ? text.slice(0, limit) + '\n…(생략)' : text;
}

function resultKeys(runDir) {
  return fs.readdirSync(runDir)
    .map((f) => RESULT_KEY_FILE.exec(f))
    .filter(Boolean)
    .map((m) => `${m[1]}-${m[2]}`)
    .sort();
}

function listResultRuns(expDir) {
  const root = path.join(expDir, 'results');
  return subdirs(root)
    .filter((name) => FILE_NAME_RE.test(name) && fs.existsSync(path.join(root, name, 'summary.csv')))
    .sort()
    .reverse()
    .map((name) => {
      const dir = path.join(root, name);
      let cond = {};
      try { cond = readJson(path.join(dir, 'conditions.json')); } catch { /* 없음 */ }
      let judged = 0;
      try { judged = Object.keys(readJson(path.join(dir, 'judgments.json')).items || {}).length; } catch { /* 없음 */ }
      return { name, prompt: cond.prompt || '', model: cond.model || '', count: resultKeys(dir).length, judged };
    });
}

function runDirOf(expDir, run) {
  return path.join(expDir, 'results', assertFileName(run));
}

// 판정 화면용: 섞인 순서와 답안별 내용(최종 응답, 변경 목록, 확인 결과).
function readRunItems(expDir, run, random) {
  const dir = runDirOf(expDir, run);
  const keys = resultKeys(dir);
  let saved = {};
  try { saved = readJson(path.join(dir, 'judgments.json')); } catch { /* 처음 */ }
  const order = Judge.ensureOrder(saved.blindOrder, keys, random);
  if (!saved.blindOrder || saved.blindOrder.join() !== order.join()) {
    fs.writeFileSync(path.join(dir, 'judgments.json'), JSON.stringify({ blindOrder: order, items: saved.items || {} }, null, 2));
  }
  const items = order.map((key) => {
    const check = readText(path.join(dir, `${key}-check.txt`), 4000);
    const changes = readText(path.join(dir, `${key}-changes.txt`));
    return {
      key,
      result: readText(path.join(dir, `${key}-result.md`), 20000) || '(최종 응답 없음 — JSON 원본을 확인하세요)',
      changes: changes ? changes.split(/\r?\n/).filter(Boolean) : [],
      check: check === null ? null : { passed: /^결과: 통과/m.test(check), text: check },
    };
  });
  return { order, items, judgments: saved.items || {} };
}

function saveJudgments(expDir, run, items) {
  const dir = runDirOf(expDir, run);
  const keys = resultKeys(dir);
  let saved = {};
  try { saved = readJson(path.join(dir, 'judgments.json')); } catch { /* 처음 */ }
  const order = Judge.ensureOrder(saved.blindOrder, keys);
  const clean = Judge.validate(items, keys);
  fs.writeFileSync(path.join(dir, 'judgments.json'), JSON.stringify({ blindOrder: order, items: clean }, null, 2));
  return Judge.summarize(clean, keys);
}

module.exports = {
  NAME_RE, FILE_NAME_RE, resolveLabRoot, assertName, assertFileName, experimentDir, listExperiments, listPrompts, readPrompt, createSession, stamp,
  updateExperimentCheck, listResultRuns, readRunItems, saveJudgments,
};
