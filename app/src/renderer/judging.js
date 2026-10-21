// 블라인드 판정: 반복 측정 결과를 A/B를 가린 "답안 N"으로 보여 주고 판정을 저장한다.
'use strict';

const Judging = (() => {
  const J = window.AbJudge;
  const LABELS = { pass: '통과', partial: '부분', fail: '실패' };
  let current = null; // { run, order, items, verdicts }

  // 목록만 다시 그린다. 고른 측정은 남아 있으면 유지한다.
  async function loadRuns() {
    if (!state.exp) return;
    const sel = $('#jd-run');
    const keep = sel.value;
    const runs = await api.listResults(state.exp.name);
    sel.textContent = '';
    if (!runs.length) sel.append(new Option('반복 측정 결과 없음', ''));
    for (const r of runs) sel.append(new Option(`${r.name} · 답안 ${r.count}개 · 판정 ${r.judged}`, r.name));
    if (keep && runs.some((r) => r.name === keep)) sel.value = keep;
  }

  function renderSummary() {
    const out = $('#jd-summary');
    if (!current) { out.textContent = ''; return; }
    const judged = Object.values(current.verdicts).filter((v) => v.verdict).length;
    if (!$('#jd-reveal').checked) {
      out.textContent = `판정 ${judged}/${current.order.length} — 쪽별 집계는 "정체 공개"를 켜면 보입니다.`;
      return;
    }
    const s = J.summarize(current.verdicts, current.order);
    const fmt = (x) => `통과 ${x.pass} · 부분 ${x.partial} · 실패 ${x.fail} (판정 ${x.judged}/${x.total})`;
    out.textContent = `A: ${fmt(s.A)}   /   B: ${fmt(s.B)}`;
  }

  function renderItems() {
    const box = $('#jd-items');
    box.textContent = '';
    if (!current) return;
    const reveal = $('#jd-reveal').checked;
    current.items.forEach((item, idx) => {
      const v = current.verdicts[item.key] || { verdict: '', note: '' };
      const name = `jd-${idx}`;
      const head = el('div', { class: 'jd-head' }, el('strong', { text: `답안 ${idx + 1}` }));
      if (reveal) head.append(el('span', { class: 'badge', text: `${item.key.replace('-', ' 쪽 ')}회` }));
      if (item.check) head.append(el('span', { class: `badge ${item.check.passed ? 'ok' : 'bad'}`, text: item.check.passed ? '확인 통과' : '확인 실패', title: item.check.text }));

      const verdict = el('fieldset', { class: 'jd-verdict' }, el('legend', { text: '판정' }));
      for (const key of J.VERDICTS) {
        const id = `${name}-${key}`;
        verdict.append(el('label', { for: id },
          el('input', {
            type: 'radio', name, id, value: key, checked: v.verdict === key,
            onChange: () => { current.verdicts[item.key] = { ...v, verdict: key, note: (current.verdicts[item.key] || v).note }; renderSummary(); },
          }),
          ` ${LABELS[key]}`));
      }
      const note = el('textarea', { rows: '2', placeholder: '메모(선택)', 'aria-label': `답안 ${idx + 1} 메모` });
      note.value = v.note || '';
      note.addEventListener('input', () => {
        const cur = current.verdicts[item.key] || { verdict: '', note: '' };
        current.verdicts[item.key] = { ...cur, note: note.value };
      });

      const changes = el('details', { class: 'changes' }, el('summary', { text: `변경 파일 ${item.changes.length}개` }),
        el('ul', {}, ...item.changes.map((c) => el('li', { text: c }))));

      box.append(el('div', { class: 'jd-card' }, head, el('pre', { class: 'jd-text', text: item.result }), changes, verdict, note));
    });
    renderSummary();
  }

  async function load() {
    if (!needExp()) return;
    const run = $('#jd-run').value;
    if (!run) return toast('판정할 측정을 고르세요.', true);
    const data = await guard(() => api.readResultItems(state.exp.name, run));
    if (!data) return;
    const verdicts = {};
    for (const [k, v] of Object.entries(data.judgments || {})) verdicts[k] = { verdict: v.verdict || '', note: v.note || '' };
    current = { run, order: data.order, items: data.items, verdicts };
    savedSnapshot = JSON.stringify(verdicts);
    $('#jd-reveal').checked = false;
    renderItems();
  }

  async function save() {
    if (!current) return toast('먼저 측정을 불러오세요.', true);
    const summary = await guard(() => api.saveJudgments(state.exp.name, current.run, current.verdicts));
    if (!summary) return;
    savedSnapshot = JSON.stringify(current.verdicts);
    const judged = summary.A.judged + summary.B.judged;
    toast(`판정 저장: ${judged}/${current.order.length}개. "보고서 만들기"를 누르면 표에 반영됩니다.`);
    renderSummary();
    guard(loadRuns);
  }

  function bind() {
    $('#jd-load').addEventListener('click', load);
    $('#jd-save').addEventListener('click', save);
    $('#jd-reveal').addEventListener('change', renderItems);
  }

  function show() { guard(loadRuns); }

  // 다른 실험으로 바꿀 때만 판정 화면을 비운다. 저장 안 한 판정이 있으면 알려 준다.
  function onExperiment() {
    current = null;
    savedSnapshot = '';
    $('#jd-items').textContent = '';
    $('#jd-summary').textContent = '';
    if (!$('#view-results').hidden) show();
  }

  // 같은 실험을 다시 고른 경우: 판정 중인 카드는 두고 측정 목록만 갱신한다.
  function onSameExperiment() {
    if (!$('#view-results').hidden) guard(loadRuns);
  }

  let savedSnapshot = '';
  function hasUnsaved() {
    return !!current && JSON.stringify(current.verdicts) !== savedSnapshot;
  }

  return { bind, show, onExperiment, onSameExperiment, hasUnsaved };
})();
