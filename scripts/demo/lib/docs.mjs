// The HTML we publish into the work library. Six layouts, one stylesheet — enough
// variety that the tree and the preview do not look like the same page twelve times.

const CSS = `
*{box-sizing:border-box}
body{margin:0;background:#f6f7f9;color:#101828;font:16px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Hiragino Sans GB","Microsoft YaHei",sans-serif;-webkit-font-smoothing:antialiased}
.wrap{max-width:880px;margin:0 auto;padding:44px 40px 60px}
.kicker{font:600 11.5px/1 ui-monospace,Menlo,monospace;letter-spacing:.16em;text-transform:uppercase;color:#8a97a8}
h1{font-size:clamp(26px,3.4vw,38px);line-height:1.16;letter-spacing:-.02em;margin:12px 0 0}
.lede{color:#5b6a7f;margin:12px 0 0;max-width:66ch}
h2{font-size:15px;letter-spacing:.02em;margin:34px 0 10px;padding-bottom:8px;border-bottom:1px solid #e4e8ee}
p{margin:10px 0}
ul{margin:10px 0 10px 20px;padding:0}
li{margin:6px 0}
.card{background:#fff;border:1px solid #e4e8ee;border-radius:16px;padding:22px 24px;margin-top:18px}
table{width:100%;border-collapse:collapse;font-size:14.5px;margin-top:6px}
th{text-align:left;font-size:11.5px;letter-spacing:.1em;text-transform:uppercase;color:#8a97a8;padding:0 10px 9px;border-bottom:1px solid #e4e8ee;font-weight:600}
td{padding:10px;border-bottom:1px solid #eef1f5;color:#33425a;vertical-align:top}
td.num{font-variant-numeric:tabular-nums;text-align:right}
.check{list-style:none;margin:0;padding:0}
.check li{display:flex;gap:10px;padding:7px 0}
.check li::before{content:"✓";color:#0e8a5f;font-weight:700;flex:none}
.check li.off::before{content:"○";color:#b3c0d1}
.grid{display:grid;grid-template-columns:repeat(3,1fr);gap:14px;margin-top:18px}
.tile{background:#fff;border:1px solid #e4e8ee;border-radius:14px;padding:16px}
.tile b{display:block;font-size:22px;letter-spacing:-.02em}
.tile span{color:#5b6a7f;font-size:13px}
.bars{margin-top:16px}
.bar{display:grid;grid-template-columns:140px 1fr 56px;align-items:center;gap:12px;font-size:13.5px;margin:8px 0}
.bar i{display:block;height:10px;border-radius:99px;background:#e6eefd}
.bar i b{display:block;height:10px;border-radius:99px;background:#2563eb}
.bar s{text-decoration:none;color:#5b6a7f;text-align:right;font-variant-numeric:tabular-nums}
.tl{margin-top:18px;border-left:2px solid #e4e8ee;padding-left:20px}
.tl div{position:relative;padding:6px 0 14px}
.tl div::before{content:"";position:absolute;left:-27px;top:13px;width:10px;height:10px;border-radius:50%;background:#2563eb}
.tl time{font:600 11.5px/1 ui-monospace,Menlo,monospace;color:#8a97a8;letter-spacing:.08em}
`

const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')

export function page({ kicker, title, lede, body }) {
  return `<!doctype html><html lang="zh-CN"><head><meta charset="utf-8">
<title>${esc(title)}</title><style>${CSS}</style></head>
<body><div class="wrap">
<p class="kicker">${esc(kicker)}</p>
<h1>${esc(title)}</h1>
${lede ? `<p class="lede">${esc(lede)}</p>` : ''}
${body}
</div></body></html>`
}

export const templates = {
  report: (s) => page({
    kicker: s.kicker, title: s.title, lede: s.lede,
    body: s.sections.map((sec) => `
<h2>${esc(sec.heading)}</h2>
${sec.paragraphs.map((p) => `<p>${esc(p)}</p>`).join('')}
${sec.bullets ? `<ul>${sec.bullets.map((b) => `<li>${esc(b)}</li>`).join('')}</ul>` : ''}`).join(''),
  }),

  table: (s) => page({
    kicker: s.kicker, title: s.title, lede: s.lede,
    body: `<div class="card"><table><thead><tr>${s.columns.map((c) => `<th>${esc(c)}</th>`).join('')}</tr></thead>
<tbody>${s.rows.map((r) => `<tr>${r.map((cell, i) => `<td${i > 0 && s.numeric?.includes(i) ? ' class="num"' : ''}>${esc(cell)}</td>`).join('')}</tr>`).join('')}</tbody></table></div>`,
  }),

  checklist: (s) => page({
    kicker: s.kicker, title: s.title, lede: s.lede,
    body: `<div class="card"><ul class="check">${s.items.map((it) => `<li${it.done ? '' : ' class="off"'}>${esc(it.text)}</li>`).join('')}</ul></div>`,
  }),

  onepager: (s) => page({
    kicker: s.kicker, title: s.title, lede: s.lede,
    body: `<div class="grid">${s.tiles.map((t) => `<div class="tile"><b>${esc(t.value)}</b><span>${esc(t.label)}</span></div>`).join('')}</div>
${s.body ? `<h2>${esc(s.body.heading)}</h2>${s.body.paragraphs.map((p) => `<p>${esc(p)}</p>`).join('')}` : ''}`,
  }),

  chart: (s) => page({
    kicker: s.kicker, title: s.title, lede: s.lede,
    body: `<div class="card"><div class="bars">${s.bars.map((b) => `<div class="bar"><span>${esc(b.label)}</span><i><b style="width:${Math.max(2, Math.round((b.value / s.max) * 100))}%"></b></i><s>${esc(b.display ?? b.value)}</s></div>`).join('')}</div></div>`,
  }),

  timeline: (s) => page({
    kicker: s.kicker, title: s.title, lede: s.lede,
    body: `<div class="tl">${s.events.map((e) => `<div><time>${esc(e.time)}</time><p>${esc(e.text)}</p></div>`).join('')}</div>`,
  }),
}
