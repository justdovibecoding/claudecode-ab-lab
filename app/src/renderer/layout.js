// 화면 나누기 손잡이: 끌어서(또는 화살표 키로) 크기를 바꾸고, 더블클릭하면 기본값으로 돌아간다.
// 크기는 CSS 변수로 넣고 localStorage 에 기억한다(저장소를 못 쓰면 기본값으로 동작).
// 터미널은 .term 의 ResizeObserver 가 크기 변화를 받아 다시 맞춘다(app.js).
'use strict';

const Layout = (() => {
  const KEY = 'ab-lab:layout';
  // side: 사이드바 px · ab: A 쪽 % · draft: 예비 입력창 px · bc/res: 왼쪽 열 %
  const DEFAULTS = { side: 220, ab: 50, draft: 116, bc: 50, res: 56 };
  const LIMITS = { side: [180, 360], ab: [20, 80], draft: [72, 420], bc: [30, 70], res: [30, 75] };
  let v = { ...DEFAULTS };

  const clamp = (k, x) => Math.min(LIMITS[k][1], Math.max(LIMITS[k][0], Math.round(x)));

  function load() {
    try {
      const saved = JSON.parse(localStorage.getItem(KEY) || '{}');
      for (const k of Object.keys(DEFAULTS)) if (Number.isFinite(saved[k])) v[k] = clamp(k, saved[k]);
    } catch { /* 저장소 없음 */ }
  }
  function save() {
    try { localStorage.setItem(KEY, JSON.stringify(v)); } catch { /* 저장소 없음 */ }
  }

  function apply() {
    const s = document.documentElement.style;
    s.setProperty('--side-w', `${v.side}px`);
    s.setProperty('--ab-a', `${v.ab}fr`);
    s.setProperty('--ab-b', `${100 - v.ab}fr`);
    s.setProperty('--draft-h', `${v.draft}px`);
    s.setProperty('--bc-a', `${v.bc}fr`);
    s.setProperty('--bc-b', `${100 - v.bc}fr`);
    s.setProperty('--res-a', `${v.res}fr`);
    s.setProperty('--res-b', `${100 - v.res}fr`);
    for (const h of document.querySelectorAll('.splitter[data-split]')) h.setAttribute('aria-valuenow', String(v[h.dataset.split]));
  }

  // 손잡이 위치(마우스 좌표) → 값
  function valueAt(kind, handle, ev) {
    if (kind === 'side') return ev.clientX - document.querySelector('.app').getBoundingClientRect().left;
    if (kind === 'draft') {
      const r = handle.closest('.pane').getBoundingClientRect();
      // 머리줄·터미널 최소 높이(약 150px)는 남긴다.
      return Math.min(r.bottom - ev.clientY, r.height - 150);
    }
    const box = handle.parentElement.getBoundingClientRect();
    return ((ev.clientX - box.left) / box.width) * 100;
  }

  function set(kind, x) {
    v[kind] = clamp(kind, x);
    apply();
  }

  function bindHandle(h) {
    const kind = h.dataset.split;
    const [lo, hi] = LIMITS[kind];
    h.setAttribute('aria-valuemin', String(lo));
    h.setAttribute('aria-valuemax', String(hi));
    h.addEventListener('pointerdown', (ev) => {
      if (ev.button !== 0) return;
      ev.preventDefault();
      h.setPointerCapture(ev.pointerId);
      document.body.classList.add(h.classList.contains('split-y') ? 'resizing-y' : 'resizing-x');
      h.classList.add('active');
      const move = (e) => set(kind, valueAt(kind, h, e));
      const up = () => {
        h.removeEventListener('pointermove', move);
        h.removeEventListener('pointerup', up);
        h.removeEventListener('pointercancel', up);
        document.body.classList.remove('resizing-x', 'resizing-y');
        h.classList.remove('active');
        save();
      };
      h.addEventListener('pointermove', move);
      h.addEventListener('pointerup', up);
      h.addEventListener('pointercancel', up);
    });
    h.addEventListener('dblclick', () => { set(kind, DEFAULTS[kind]); save(); });
    // 키보드: 화살표 한 칸(Shift 와 함께면 크게). 입력창 높이는 위쪽 화살표가 키운다.
    h.addEventListener('keydown', (ev) => {
      const step = (ev.shiftKey ? 5 : 1) * (kind === 'side' || kind === 'draft' ? 10 : 2);
      const sign = { ArrowLeft: -1, ArrowRight: 1, ArrowUp: 1, ArrowDown: -1 }[ev.key];
      if (sign === undefined) {
        if (ev.key === 'Home' || ev.key === 'End') { set(kind, ev.key === 'Home' ? lo : hi); save(); ev.preventDefault(); }
        return;
      }
      ev.preventDefault();
      set(kind, v[kind] + sign * step);
      save();
    });
  }

  function init() {
    load();
    apply();
    for (const h of document.querySelectorAll('.splitter[data-split]')) bindHandle(h);
  }

  return { init, DEFAULTS };
})();
