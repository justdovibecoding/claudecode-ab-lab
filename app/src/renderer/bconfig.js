// B 구성 화면: b-config.ps1 을 -Json 으로 호출해 목록·설치·제거·동등성 점검을 한다.
'use strict';

const BConfig = (() => {
  let available = null; // 마지막으로 불러온 설치 가능 목록
  let installedIds = new Set();
  let busy = false;
  let shownFor = null; // 마지막으로 목록을 그린 실험

  const log = (line, isErr) => appendOut($('#bc-log'), line, isErr);
  const short = (s, n) => (s && s.length > n ? s.slice(0, n) : s || '');

  // 한 번에 하나씩 실행하고, 끝나면 목록과 왼쪽 실험 정보를 새로 읽는다.
  async function run(label, params, { refresh = true } = {}) {
    if (!needExp()) return null;
    if (busy) { toast('다른 B 구성 작업이 진행 중입니다.', true); return null; }
    busy = true;
    for (const b of $$('#view-bconfig button')) b.disabled = true;
    log(`${label}…`);
    try {
      const result = await api.runJson('b-config', { Exp: state.exp.name, ...params });
      log(`${label}: 완료`);
      if (refresh) {
        await loadList();
        await loadExperiments(state.exp.name);
      }
      if (state.running) toast('B 구성이 바뀌었습니다. 대화형 세션의 B를 "다시 시작"해야 반영됩니다.', true);
      return result;
    } catch (err) {
      log(`${label}: ${err.message}`, true);
      toast(err.message, true);
      return null;
    } finally {
      busy = false;
      for (const b of $$('#view-bconfig button')) b.disabled = false;
    }
  }

  function actionButton(text, onClick, cls) {
    return el('button', { type: 'button', class: `small ${cls || ''}`.trim(), text, onClick });
  }

  function versionCell(version, commit, dirty) {
    const parts = [];
    if (version) parts.push(version);
    if (commit) parts.push(`@${short(commit, 12)}${dirty ? '(수정본)' : ''}`);
    return el('td', { class: 'mono', text: parts.join(' ') || '-' });
  }

  function sourceCell(source, recorded) {
    const td = el('td', { title: source || '' });
    td.append(document.createTextNode(short(source, 60) || '-'));
    if (!recorded) td.append(' ', el('span', { class: 'badge warn', text: '기록 없음', title: 'B 터미널의 /plugin 등으로 넣어 출처·커밋이 기록되지 않았습니다' }));
    return td;
  }

  async function loadList() {
    if (!state.exp) return;
    const body = $('#bc-items');
    const data = await api.runJson('b-config', { Exp: state.exp.name, Action: 'list' });
    shownFor = state.exp.name;
    installedIds = new Set(data.installed.map((p) => p.id));
    body.textContent = '';
    for (const p of data.installed) {
      const id = p.id;
      body.append(el('tr', {},
        el('td', {}, '설치 플러그인 ', el('span', { class: `badge ${p.enabled ? 'ok' : ''}`, text: p.enabled ? '켜짐' : '꺼짐' })),
        el('td', { class: 'mono', text: id }),
        versionCell(p.version, p.commit),
        sourceCell(p.source, p.recorded),
        el('td', { class: 'actions' },
          actionButton(p.enabled ? '끄기' : '켜기', () => run(`${id} ${p.enabled ? '끄기' : '켜기'}`, { Action: p.enabled ? 'disable' : 'enable', Plugin: id })),
          actionButton('토큰', () => showDetails(id)),
          actionButton('제거', () => run(`${id} 제거`, { Action: 'uninstall', Plugin: id }))),
      ));
    }
    for (const [kind, items] of [['plugin', data.localPlugins], ['skill', data.localSkills]]) {
      for (const it of items) {
        body.append(el('tr', {},
          el('td', {}, kind === 'plugin' ? '로컬 플러그인' : '로컬 스킬', it.valid ? null : el('span', { class: 'badge bad', text: kind === 'plugin' ? 'plugin.json 없음' : 'SKILL.md 없음' })),
          el('td', { class: 'mono', text: it.name }),
          versionCell(it.version, it.commit),
          sourceCell(it.source, it.recorded),
          el('td', { class: 'actions' },
            actionButton('제거', () => run(`${it.name} 제거`, { Action: 'remove-local', Kind: kind, Name: it.name })))),
        );
      }
    }
    if (!body.children.length) body.append(el('tr', {}, el('td', { colspan: '5', class: 'hint', text: 'B에 넣은 것이 없습니다. 오른쪽에서 추가하세요. (지금은 A와 같은 환경)' })));
    if (available) renderAvailable();
  }

  async function showDetails(id) {
    const r = await run(`${id} 상세`, { Action: 'details', Plugin: id }, { refresh: false });
    if (!r) return;
    log(r.alwaysOnTokens !== null && r.alwaysOnTokens !== undefined
      ? `${id}: 매 세션 항상 추가되는 토큰 약 ${r.alwaysOnTokens}`
      : `${id}: 토큰 정보를 찾지 못함`);
    for (const line of r.text.split('\n')) log(`  ${line}`);
  }

  function renderAvailable() {
    const list = $('#bc-available');
    list.textContent = '';
    const q = $('#bc-search').value.trim().toLowerCase();
    const matches = available.filter((p) => !q || `${p.name} ${p.description || ''} ${p.marketplace}`.toLowerCase().includes(q));
    for (const p of matches.slice(0, 80)) {
      const installed = installedIds.has(p.id);
      list.append(el('li', {},
        el('div', { class: 'info' },
          el('span', { class: 'name', text: `${p.name}${p.version ? ' ' + p.version : ''}` }),
          el('span', { class: 'desc', text: p.description || '', title: p.description || '' }),
          el('span', { class: 'hint mono', text: `${p.marketplace}${p.sha ? ' @' + short(p.sha, 12) : ''}` })),
        installed
          ? el('span', { class: 'badge ok', text: '설치됨' })
          : actionButton('설치', () => run(`${p.id} 설치`, { Action: 'install', Plugin: p.id }), 'outline')));
    }
    if (matches.length > 80) list.append(el('li', { class: 'hint', text: `${matches.length - 80}개 더 있음 — 검색어로 좁히세요` }));
    if (!matches.length) list.append(el('li', { class: 'hint', text: '검색 결과 없음' }));
  }

  async function loadAvailable() {
    const r = await run('설치 가능한 플러그인 목록 불러오기', { Action: 'available' }, { refresh: false });
    if (!r) return;
    available = r;
    log(`플러그인 ${r.length}개`);
    renderAvailable();
  }

  async function checkEquivalence() {
    const r = await run('A/B 동등성 점검', { Action: 'equivalence' }, { refresh: false });
    if (!r) return;
    const ul = $('#bc-eq');
    ul.textContent = '';
    ul.className = `eq ${r.ok ? 'ok' : 'bad'}`;
    if (r.ok) {
      const n = r.details && r.details.syncedSkills ? r.details.syncedSkills.A : 0;
      ul.append(el('li', { text: `통과: 같은 계정, 계정 스킬 ${n}개 동일, 설정 동일` }));
    } else {
      for (const issue of r.issues) ul.append(el('li', { text: issue }));
    }
  }

  function bind() {
    $('#bc-refresh').addEventListener('click', () => guard(loadList));
    $('#bc-eq-run').addEventListener('click', checkEquivalence);
    $('#bc-load-available').addEventListener('click', loadAvailable);
    $('#bc-search').addEventListener('input', () => { if (available) renderAvailable(); });
    $('#bc-market-add').addEventListener('click', async () => {
      const source = $('#bc-market').value.trim();
      if (!source) return toast('마켓플레이스 주소를 입력하세요.', true);
      const r = await run(`마켓플레이스 추가 ${source}`, { Action: 'add-marketplace', Source: source }, { refresh: false });
      if (r) { $('#bc-market').value = ''; available = null; await loadAvailable(); }
    });
    $('#bc-add-local').addEventListener('click', async () => {
      const dir = await guard(() => api.pickFolder('B에 넣을 플러그인 또는 스킬 폴더'));
      if (dir) await run(`로컬 폴더 추가 ${dir}`, { Action: 'add-local', Path: dir });
    });
    $('#bc-add-git').addEventListener('click', async () => {
      const url = $('#bc-git-url').value.trim();
      if (!url) return toast('Git 주소를 입력하세요.', true);
      const r = await run(`Git 가져오기 ${url}`, {
        Action: 'add-git', Url: url, Ref: $('#bc-git-ref').value.trim(), SubPath: $('#bc-git-sub').value.trim(),
      });
      if (r) for (const id of ['#bc-git-url', '#bc-git-ref', '#bc-git-sub']) $(id).value = '';
    });
  }

  function show() {
    if (state.exp && shownFor !== state.exp.name) guard(loadList);
  }

  function onExperiment() {
    shownFor = null;
    $('#bc-items').textContent = '';
    const ul = $('#bc-eq');
    ul.className = 'eq';
    ul.textContent = '';
    ul.append(el('li', { text: '아직 점검하지 않았습니다.' }));
    if (!$('#view-bconfig').hidden) show();
  }

  return { bind, show, onExperiment };
})();
