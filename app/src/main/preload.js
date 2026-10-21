// 화면(렌더러)에 열어 주는 기능은 여기 있는 것뿐이다. Node 기능은 직접 주지 않는다.
const { contextBridge, ipcRenderer } = require('electron');

async function call(channel, ...args) {
  const res = await ipcRenderer.invoke(channel, ...args);
  if (!res.ok) throw new Error(res.error);
  return res.value;
}

function on(channel, cb) {
  const listener = (_e, payload) => cb(payload);
  ipcRenderer.on(channel, listener);
  return () => ipcRenderer.removeListener(channel, listener);
}

contextBridge.exposeInMainWorld('lab', {
  info: () => call('lab:info'),
  listExperiments: () => call('exp:list'),
  readPrompt: (exp, name) => call('exp:prompt', exp, name),
  readReport: (exp) => call('exp:report', exp),
  readDecision: (exp) => call('exp:decision', exp),

  startLive: (opts) => call('live:start', opts),
  stopLive: () => call('live:stop'),
  restartSide: (side, opts) => call('live:restart', side, opts),
  write: (side, data) => ipcRenderer.send('live:write', side, data),
  resize: (side, cols, rows) => ipcRenderer.send('live:resize', side, cols, rows),
  logTurn: (record) => call('live:logTurn', record),
  onData: (cb) => on('live:data', cb),
  onExit: (cb) => on('live:exit', cb),
  mark: (kind, label) => call('mark:add', kind, label),
  shot: (kind) => call('shot:take', kind),
  recStart: () => call('rec:start'),
  recStarted: () => call('rec:started'),
  recChunk: (buf) => ipcRenderer.send('rec:chunk', buf),
  recStop: () => call('rec:stop'),
  recAbort: () => call('rec:abort'),
  onRecConverted: (cb) => on('rec:converted', cb),

  runScript: (name, params) => call('script:run', name, params),
  runJson: (name, params) => call('script:json', name, params),
  pickFolder: (title) => call('dialog:folder', title),
  setCheck: (exp, check) => call('exp:setCheck', exp, check),
  listResults: (exp) => call('results:list', exp),
  readResultItems: (exp, run) => call('results:items', exp, run),
  saveJudgments: (exp, run, items) => call('results:save', exp, run, items),
  cancelScript: (runId) => call('script:cancel', runId),
  onScriptLine: (cb) => on('script:line', cb),
  onScriptDone: (cb) => on('script:done', cb),

  openLogin: (exp) => call('shell:login', exp),
  open: (target, exp) => call('shell:open', target, exp),
  copy: (text) => call('clip:write', text),
  setWindowSize: (w, h) => call('win:size', w, h),
});
