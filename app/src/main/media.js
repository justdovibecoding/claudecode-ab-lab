// 녹화·캡처용 순수 함수: 계정 정보 가리기, 유튜브 챕터, ffmpeg 찾기, 터미널 기록(asciicast v2).
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

// ---------- 계정 정보 가리기 ----------

// 화면에서 두 칸을 차지하는 글자(한글·한자·가나·전각). 가린 뒤에도 화면 폭이 같도록 '*' 두 개로 바꾼다.
const WIDE_RE = /[ᄀ-ᅟ⺀-〾ぁ-㏿㐀-䶿一-鿿ꥠ-꥿가-힣豈-﫿︰-﹏＀-｠￠-￦]/;

function maskWord(word) {
  return Array.from(word).map((ch) => (WIDE_RE.test(ch) ? '**' : '*')).join('');
}

// 가릴 낱말 목록: 이메일, 이메일 앞부분(잘려 보일 때 대비), 조직 이름. 4글자 미만은 오탐이 많아 뺀다.
function redactWords(auth) {
  const words = new Set();
  for (const a of [].concat(auth || [])) {
    if (!a) continue;
    if (a.email) {
      words.add(a.email);
      const local = String(a.email).split('@')[0];
      if (local.length >= 4) words.add(local);
    }
    if (a.orgName) words.add(a.orgName);
  }
  return [...words].map(String).filter((w) => w.length >= 4).sort((x, y) => y.length - x.length);
}

// 출력 조각이 낱말 중간에서 잘려 올 수 있으므로, 낱말의 앞부분일 수 있는 꼬리는 다음 조각까지 잡아 둔다.
// 꼬리를 먼저 떼고 나머지만 가린다(먼저 가리면 이메일 앞부분만 짧은 낱말로 가려져 나머지가 드러남).
// push(조각) → 내보낼 글자, flush() → 잡아 둔 글자를 가려서(잠시 출력이 없으면 호출).
function createRedactor(words) {
  const list = (words || []).filter(Boolean);
  let carry = '';
  function replaceAll(text) {
    for (const w of list) {
      if (text.includes(w)) text = text.split(w).join(maskWord(w));
    }
    return text;
  }
  function holdLength(text) {
    let hold = 0;
    for (const w of list) {
      for (let n = Math.min(w.length - 1, text.length); n > hold; n--) {
        if (text.endsWith(w.slice(0, n))) { hold = n; break; }
      }
    }
    return hold;
  }
  return {
    active: list.length > 0,
    push(chunk) {
      if (!list.length) return chunk;
      const text = carry + chunk;
      const hold = holdLength(text);
      carry = hold ? text.slice(text.length - hold) : '';
      return replaceAll(hold ? text.slice(0, text.length - hold) : text);
    },
    flush() {
      const out = replaceAll(carry);
      carry = '';
      return out;
    },
  };
}

// ---------- 표시 → 유튜브 챕터 ----------

function formatClock(sec) {
  const s = Math.max(0, Math.floor(sec));
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const ss = String(s % 60).padStart(2, '0');
  return h ? `${h}:${String(m).padStart(2, '0')}:${ss}` : `${m}:${ss}`;
}

const CHAPTER_KINDS = new Set(['send', 'done', 'restart', 'manual']);

// markers: [{ rec(녹화 시작 기준 초), kind, label }]. 유튜브 규칙: 첫 챕터 0:00, 챕터마다 10초 이상.
// 10초 안에 몰린 표시는 앞의 것만 남긴다. 단 0:00 근처의 첫 표시는 "시작" 대신 그 이름을 0:00 에 쓴다.
// 결과: { lines, valid(3개 이상), dropped }
function buildChapters(markers, { firstLabel = '시작', minGap = 10 } = {}) {
  const items = (markers || [])
    .filter((m) => m && CHAPTER_KINDS.has(m.kind) && typeof m.rec === 'number' && m.rec >= 0)
    .sort((a, b) => a.rec - b.rec);
  const kept = [{ rec: 0, label: firstLabel }];
  let dropped = 0;
  for (const m of items) {
    const label = String(m.label || m.kind).replace(/\s+/g, ' ').trim();
    if (m.rec - kept[kept.length - 1].rec < minGap) {
      if (kept.length === 1 && !kept[0].named) Object.assign(kept[0], { label, named: true });
      else dropped++;
      continue;
    }
    kept.push({ rec: m.rec, label });
  }
  return { lines: kept.map((k) => `${formatClock(k.rec)} ${k.label}`), valid: kept.length >= 3, dropped };
}

// ---------- ffmpeg ----------

function defaultWhere(name) {
  try {
    return execFileSync('where.exe', [name], { encoding: 'utf8', windowsHide: true }).split(/\r?\n/).map((s) => s.trim()).filter(Boolean);
  } catch {
    return [];
  }
}

function resolveFfmpeg({ env = process.env, exists = fs.existsSync, where = defaultWhere } = {}) {
  if (env.CC_AB_FFMPEG && exists(env.CC_AB_FFMPEG)) return env.CC_AB_FFMPEG;
  return where('ffmpeg').find((p) => p.toLowerCase().endsWith('.exe')) || null;
}

// MediaRecorder 의 webm 은 프레임 간격이 고르지 않고 길이 정보가 없어 편집기에서 다루기 어렵다.
// 30fps 고정 H.264 mp4 로 바꾼다(yuv420p 는 가로·세로가 짝수여야 함).
function mp4Args(input, output) {
  return ['-y', '-hide_banner', '-loglevel', 'error', '-i', input,
    '-vf', 'scale=trunc(iw/2)*2:trunc(ih/2)*2', '-r', '30', '-c:v', 'libx264', '-preset', 'veryfast', '-crf', '20',
    '-pix_fmt', 'yuv420p', '-movflags', '+faststart', output];
}

// ---------- 터미널 기록(asciicast v2) ----------
// 한 줄 머리말 + [초, "o"|"r"|"m", 데이터] 줄. asciinema play / agg 로 재생·영상화할 수 있다.

function createCast(file, { cols, rows, title, start = Date.now() } = {}) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const header = { version: 2, width: cols || 100, height: rows || 30, timestamp: Math.floor(start / 1000), title: title || '', env: { TERM: 'xterm-256color' } };
  fs.writeFileSync(file, JSON.stringify(header) + '\n');
  const t = () => Math.round((Date.now() - start) / 1000 * 1000) / 1000;
  const line = (kind, data) => fs.appendFileSync(file, JSON.stringify([t(), kind, data]) + '\n');
  return {
    output: (data) => line('o', data),
    resize: (c, r) => line('r', `${c}x${r}`),
    marker: (label) => line('m', String(label)),
  };
}

module.exports = { maskWord, redactWords, createRedactor, formatClock, buildChapters, resolveFfmpeg, mp4Args, createCast };
