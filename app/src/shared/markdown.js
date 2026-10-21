// REPORT.md 를 화면에 보여 주려고 마크다운을 블록·인라인 조각으로 나눈다(보고서에 쓰는 문법만).
// HTML 을 만들지 않고 조각만 돌려준다. 렌더러가 textContent 로 요소를 만든다.
// 렌더러(<script>)와 Node(require) 양쪽에서 쓴다.
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.AbMarkdown = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  // 인라인: `코드`, **굵게**, [글자](주소) → 글자. 결과: [{ t: 'text'|'code'|'b', v }]
  function inline(text) {
    const out = [];
    const re = /`([^`]+)`|\*\*(.+?)\*\*|\[([^\]]+)\]\([^)]*\)/g;
    let last = 0;
    let m;
    while ((m = re.exec(text)) !== null) {
      if (m.index > last) out.push({ t: 'text', v: text.slice(last, m.index) });
      if (m[1] !== undefined) out.push({ t: 'code', v: m[1] });
      else if (m[2] !== undefined) out.push({ t: 'b', v: m[2] });
      else out.push({ t: 'text', v: m[3] });
      last = re.lastIndex;
    }
    if (last < text.length) out.push({ t: 'text', v: text.slice(last) });
    return out;
  }

  // 표의 한 줄을 칸으로 나눈다. 칸 안의 `\|` 는 글자 | 로 둔다.
  function cells(line) {
    const s = line.trim().replace(/^\|/, '').replace(/\|$/, '');
    return s.split(/(?<!\\)\|/).map((c) => c.trim().replace(/\\\|/g, '|'));
  }

  const isTableSep = (line) => /^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*$/.test(line);

  // 블록: h(level,text) · p(text) · ul(items) · table(head,rows) · quote(text) · code(text) · hr
  function parse(md) {
    const lines = String(md || '').replace(/\r\n?/g, '\n').split('\n');
    const blocks = [];
    let i = 0;
    while (i < lines.length) {
      const line = lines[i];
      if (!line.trim()) { i++; continue; }
      if (/^```/.test(line)) {
        const body = [];
        i++;
        while (i < lines.length && !/^```/.test(lines[i])) body.push(lines[i++]);
        i++;
        blocks.push({ type: 'code', text: body.join('\n') });
        continue;
      }
      const h = /^(#{1,6})\s+(.*)$/.exec(line);
      if (h) { blocks.push({ type: 'h', level: h[1].length, text: h[2].trim() }); i++; continue; }
      if (/^\s*(-{3,}|\*{3,}|_{3,})\s*$/.test(line)) { blocks.push({ type: 'hr' }); i++; continue; }
      if (/^\s*\|/.test(line) && i + 1 < lines.length && isTableSep(lines[i + 1])) {
        const head = cells(line);
        const rows = [];
        i += 2;
        while (i < lines.length && /^\s*\|/.test(lines[i])) rows.push(cells(lines[i++]));
        blocks.push({ type: 'table', head, rows });
        continue;
      }
      if (/^>\s?/.test(line)) {
        const body = [];
        while (i < lines.length && /^>\s?/.test(lines[i])) body.push(lines[i++].replace(/^>\s?/, ''));
        blocks.push({ type: 'quote', text: body.join(' ') });
        continue;
      }
      if (/^\s*[-*]\s+/.test(line)) {
        const items = [];
        while (i < lines.length && /^\s*[-*]\s+/.test(lines[i])) {
          let item = lines[i++].replace(/^\s*[-*]\s+/, '');
          // 들여쓴 이어지는 줄은 같은 항목에 붙인다.
          while (i < lines.length && /^\s{2,}\S/.test(lines[i]) && !/^\s*[-*]\s+/.test(lines[i])) item += ' ' + lines[i++].trim();
          items.push(item);
        }
        blocks.push({ type: 'ul', items });
        continue;
      }
      const body = [];
      while (i < lines.length && lines[i].trim() && !/^(#{1,6}\s|```|>|\s*[-*]\s+|\s*\|)/.test(lines[i])) body.push(lines[i++].trim());
      if (!body.length) body.push(lines[i++].trim());
      blocks.push({ type: 'p', text: body.join(' ') });
    }
    return blocks;
  }

  return { parse, inline };
});
