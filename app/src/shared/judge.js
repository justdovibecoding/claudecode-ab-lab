// 블라인드 판정: A/B 실행 결과를 섞어 "답안 N"으로만 보여 주고, 판정을 쪽별로 집계한다.
// 렌더러(<script>)와 Node(require) 양쪽에서 쓴다.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.AbJudge = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  const VERDICTS = ['pass', 'partial', 'fail'];
  const KEY_RE = /^(A|B)-(\d+)$/;

  // Fisher-Yates. random 은 시험에서 고정값을 넣을 수 있게 받는다.
  function makeBlindOrder(keys, random) {
    const rnd = random || Math.random;
    const order = keys.slice();
    for (let i = order.length - 1; i > 0; i--) {
      const j = Math.floor(rnd() * (i + 1));
      [order[i], order[j]] = [order[j], order[i]];
    }
    return order;
  }

  // 저장된 순서가 지금 결과 목록과 맞지 않으면(실행이 추가·삭제됨) 새로 섞는다.
  function ensureOrder(saved, keys, random) {
    const ok = Array.isArray(saved) && saved.length === keys.length && keys.every((k) => saved.includes(k));
    return ok ? saved.slice() : makeBlindOrder(keys, random);
  }

  function parseKey(key) {
    const m = KEY_RE.exec(key);
    return m ? { side: m[1], run: Number(m[2]) } : null;
  }

  function summarize(items, keys) {
    const out = {};
    for (const side of ['A', 'B']) out[side] = { total: 0, judged: 0, pass: 0, partial: 0, fail: 0 };
    for (const key of keys) {
      const p = parseKey(key);
      if (!p) continue;
      const s = out[p.side];
      s.total++;
      const v = items && items[key] && items[key].verdict;
      if (VERDICTS.includes(v)) {
        s.judged++;
        s[v]++;
      }
    }
    return out;
  }

  // 저장 전에 판정 내용을 검사한다.
  function validate(items, keys) {
    const clean = {};
    for (const [key, value] of Object.entries(items || {})) {
      if (!keys.includes(key)) throw new Error(`알 수 없는 답안: ${key}`);
      const verdict = value && value.verdict ? String(value.verdict) : '';
      if (verdict && !VERDICTS.includes(verdict)) throw new Error(`잘못된 판정: ${verdict}`);
      const note = value && value.note ? String(value.note).slice(0, 2000) : '';
      if (verdict || note) clean[key] = { verdict, note, judgedAt: value.judgedAt || new Date().toISOString() };
    }
    return clean;
  }

  return { VERDICTS, KEY_RE, makeBlindOrder, ensureOrder, parseKey, summarize, validate };
});
