'use strict';

// 범위(과잉 구현) 측정. 반복 측정이 남긴 결과물 사본(<쪽>-<회차>-work)을 fixture 와 비교한다.
// 토큰을 쓰지 않는 사후 분석이며 정답 여부는 hidden.test.js 가 따로 본다.
//   node scope.js <fixture 폴더> <results\<측정 이름> 폴더> [--json]
//   node scope.js <fixture 폴더> D:\cc-ab-work\karpathy        (대화형 비교 뒤 work-A / work-B)
const fs = require('node:fs');
const path = require('node:path');

const SKIP_DIRS = new Set(['node_modules', '.git']);
const EXPECTED_EXPORTS = new Set(['parseDuration', 'formatDuration', 'UNITS']);

function listFiles(root, dir = '') {
  const out = [];
  for (const ent of fs.readdirSync(path.join(root, dir), { withFileTypes: true })) {
    const rel = path.posix.join(dir, ent.name);
    if (ent.isDirectory()) {
      if (!SKIP_DIRS.has(ent.name)) out.push(...listFiles(root, rel));
    } else {
      out.push(rel);
    }
  }
  return out;
}

function readLines(file) {
  return fs.existsSync(file) ? fs.readFileSync(file, 'utf8').replace(/\r\n/g, '\n').split('\n') : [];
}

// 빈 줄과 주석만 있는 줄을 뺀 코드 줄 수
function codeLines(lines) {
  let inBlock = false;
  let n = 0;
  for (const raw of lines) {
    const line = raw.trim();
    if (inBlock) {
      if (line.includes('*/')) inBlock = false;
      continue;
    }
    if (!line || line.startsWith('//')) continue;
    if (line.startsWith('/*')) {
      if (!line.includes('*/')) inBlock = true;
      continue;
    }
    n++;
  }
  return n;
}

// 두 파일 사이에 더하거나 지운 줄 수(LCS 기준)
function diffLines(a, b) {
  const dp = Array.from({ length: a.length + 1 }, () => new Uint16Array(b.length + 1));
  for (let i = a.length - 1; i >= 0; i--) {
    for (let j = b.length - 1; j >= 0; j--) {
      dp[i][j] = a[i] === b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
    }
  }
  return a.length + b.length - 2 * dp[0][0];
}

function deps(pkg) {
  return Object.keys({ ...pkg.dependencies, ...pkg.devDependencies, ...pkg.peerDependencies });
}

function measure(fixture, work) {
  const fixFiles = new Set(listFiles(fixture));
  const workFiles = listFiles(work);
  const srcFiles = workFiles.filter((f) => f.startsWith('src/') && f.endsWith('.js'));

  let srcCode = 0;
  let srcDiff = 0;
  for (const f of new Set([...srcFiles, ...[...fixFiles].filter((x) => x.startsWith('src/'))])) {
    const before = readLines(path.join(fixture, f));
    const after = readLines(path.join(work, f));
    srcCode += codeLines(after);
    srcDiff += diffLines(before, after);
  }
  const testCode = workFiles
    .filter((f) => f.startsWith('test/'))
    .reduce((n, f) => n + codeLines(readLines(path.join(work, f))), 0);

  // 지시문이 요구한 곳(test/, README.md) 밖에 새로 생긴 파일
  const extraFiles = workFiles.filter((f) => !fixFiles.has(f) && !f.startsWith('test/') && f !== 'README.md');

  const pkgBefore = JSON.parse(fs.readFileSync(path.join(fixture, 'package.json'), 'utf8'));
  let pkgAfter = {};
  try { pkgAfter = JSON.parse(fs.readFileSync(path.join(work, 'package.json'), 'utf8')); } catch { /* 없거나 깨짐 */ }
  const addedDeps = deps(pkgAfter).filter((d) => !deps(pkgBefore).includes(d));
  const pkgChanged = JSON.stringify(pkgBefore) !== JSON.stringify(pkgAfter);

  let extraExports = [];
  try {
    const entry = require.resolve(path.join(work, 'src'));
    delete require.cache[entry];
    extraExports = Object.keys(require(entry)).filter((k) => !EXPECTED_EXPORTS.has(k));
  } catch (err) {
    extraExports = [`(불러오기 실패: ${err.message.split('\n')[0]})`];
  }

  const drift = behaviorDrift(fixture, work);
  return { srcCode, srcDiff, testCode, extraFiles, addedDeps, pkgChanged, extraExports, drift };
}

// 소수 버그와 관계없는 입력에서 fixture 와 결과가 달라진 것(요청하지 않은 동작 변경).
// 01-task 는 이 입력들을 RangeError 로 바꾸라고 요구하므로 02-small-fix 에서만 의미가 있다.
const DRIFT_INPUTS = ['', '   ', 'abc', '10x', '1h30', '5 m', '1h 30m', '  2s  ', 'h', '1h abc'];

function outcome(lib, input) {
  try {
    return `= ${lib.parseDuration(input)}`;
  } catch (err) {
    return `! ${err && err.constructor ? err.constructor.name : 'Error'}`;
  }
}

function load(dir) {
  const entry = require.resolve(path.join(dir, 'src'));
  delete require.cache[entry];
  return require(entry);
}

function behaviorDrift(fixture, work) {
  let before;
  let after;
  try {
    before = load(fixture);
    after = load(work);
  } catch {
    return ['(불러오기 실패)'];
  }
  return DRIFT_INPUTS
    .filter((input) => outcome(before, input) !== outcome(after, input))
    .map((input) => `${JSON.stringify(input)} ${outcome(before, input)} → ${outcome(after, input)}`);
}

function mean(xs) {
  return xs.length ? Math.round((xs.reduce((a, b) => a + b, 0) / xs.length) * 10) / 10 : null;
}

function main() {
  const args = process.argv.slice(2).filter((a) => a !== '--json');
  const asJson = process.argv.includes('--json');
  if (args.length !== 2) {
    console.error('사용법: node scope.js <fixture 폴더> <results\\<측정 이름> 폴더> [--json]');
    process.exit(2);
  }
  const [fixture, runDir] = args.map((p) => path.resolve(p));
  // 반복 측정 사본(A-1-work …) 또는 대화형 작업 폴더(work-A, work-B, 회차는 1로 표시)
  const runs = fs.readdirSync(runDir)
    .map((name) => /^([AB])-(\d+)-work$/.exec(name) || /^work-([AB])$/.exec(name))
    .filter(Boolean)
    .map((m) => ({ side: m[1], run: Number(m[2] || 1), ...measure(fixture, path.join(runDir, m[0])) }))
    .sort((a, b) => a.side.localeCompare(b.side) || a.run - b.run);

  const sides = {};
  for (const side of ['A', 'B']) {
    const rs = runs.filter((r) => r.side === side);
    if (!rs.length) continue;
    sides[side] = {
      runs: rs.length,
      srcCode: mean(rs.map((r) => r.srcCode)),
      srcDiff: mean(rs.map((r) => r.srcDiff)),
      testCode: mean(rs.map((r) => r.testCode)),
      extraFileRuns: rs.filter((r) => r.extraFiles.length).length,
      addedDepRuns: rs.filter((r) => r.addedDeps.length).length,
      pkgChangedRuns: rs.filter((r) => r.pkgChanged).length,
      extraExportRuns: rs.filter((r) => r.extraExports.length).length,
      driftRuns: rs.filter((r) => r.drift.length).length,
      driftInputs: mean(rs.map((r) => r.drift.length)),
    };
  }

  if (asJson) {
    console.log(JSON.stringify({ fixture, runDir, runs, sides }, null, 2));
    return;
  }
  console.log(`범위 측정: ${runDir}`);
  console.log('쪽 회차 | src 코드줄 | src 변경줄 | test 코드줄 | 추가 파일 | 추가 의존성 | package.json 변경 | 추가 export | 동작 변경');
  for (const r of runs) {
    console.log([
      `${r.side} ${r.run}`, r.srcCode, r.srcDiff, r.testCode,
      r.extraFiles.join(', ') || '-', r.addedDeps.join(', ') || '-',
      r.pkgChanged ? '예' : '-', r.extraExports.join(', ') || '-', r.drift.length ? `${r.drift.length}개` : '-',
    ].join(' | '));
  }
  console.log('\n쪽 | 회 | src 코드줄 평균 | src 변경줄 평균 | test 코드줄 평균 | 추가 파일 | 추가 의존성 | package.json 변경 | 추가 export | 동작 변경 (해당 회차 수) | 동작 변경 입력 평균');
  for (const [side, s] of Object.entries(sides)) {
    console.log([side, s.runs, s.srcCode, s.srcDiff, s.testCode, s.extraFileRuns,
      s.addedDepRuns, s.pkgChangedRuns, s.extraExportRuns, s.driftRuns, s.driftInputs].join(' | '));
  }
  const drifted = runs.filter((r) => r.drift.length);
  if (drifted.length) {
    console.log('\n동작 변경 상세 (fixture → 결과물, 02-small-fix 에서만 의미 있음)');
    for (const r of drifted) console.log(`${r.side} ${r.run}: ${r.drift.join('; ')}`);
  }
}

main();
