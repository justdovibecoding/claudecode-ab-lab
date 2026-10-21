// 공통 입력과 A/B 예비 입력창 상태, 공정성 판정.
// 렌더러(<script>)와 Node 테스트(require) 양쪽에서 쓴다.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.AbPrompt = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  const SIDES = ['A', 'B'];

  function initial(common) {
    const text = common || '';
    return { common: text, A: text, B: text, dirty: { A: false, B: false } };
  }

  // 공통 입력이 바뀌면 수정하지 않은 예비 입력창에만 따라 들어간다.
  function setCommon(state, common) {
    return {
      common,
      A: state.dirty.A ? state.A : common,
      B: state.dirty.B ? state.B : common,
      dirty: { ...state.dirty },
    };
  }

  // 예비 입력창을 고치면 공통 입력과 다를 때만 "수정됨"이 된다.
  function editDraft(state, side, text) {
    const next = { ...state, dirty: { ...state.dirty } };
    next[side] = text;
    next.dirty[side] = text !== state.common;
    return next;
  }

  function resetDraft(state, side) {
    const next = { ...state, dirty: { ...state.dirty } };
    next[side] = state.common;
    next.dirty[side] = false;
    return next;
  }

  // 지시문 파일에서 불러올 때: 쪽별 변형 파일(.A.md/.B.md)이 있으면 그쪽만 수정됨 상태로.
  function load(common, variants) {
    let state = initial(common);
    for (const side of SIDES) {
      if (variants && typeof variants[side] === 'string') state = editDraft(state, side, variants[side]);
    }
    return state;
  }

  // same: 공통과 같음 / call: 공통 문장을 그대로 두고 덧붙임(스킬 호출 문구 등) / content: 내용 변경
  function classify(common, draft) {
    if (draft === common) return { kind: 'same', extra: '' };
    const core = common.trim();
    if (core && draft.includes(core)) {
      return { kind: 'call', extra: draft.replace(core, '').trim() };
    }
    return { kind: 'content', extra: '' };
  }

  function fairness(state) {
    const A = classify(state.common, state.A);
    const B = classify(state.common, state.B);
    const kinds = [A.kind, B.kind];
    const level = kinds.includes('content') ? 'content' : kinds.includes('call') ? 'call' : 'same';
    return { level, A, B };
  }

  // 지시문 파일의 <!-- --> 주석을 지운다(run-headless.ps1 과 같은 규칙).
  function stripComments(text) {
    return String(text || '').replace(/<!--[\s\S]*?-->/g, '').trim();
  }

  return { SIDES, initial, setCommon, editDraft, resetDraft, load, classify, fairness, stripComments };
});
