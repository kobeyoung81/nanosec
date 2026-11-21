// A work-library document that shows what the platform can host: one HTML file,
// its own CSS, its own JS (the preview iframe runs with allow-scripts), no
// network and no libraries.
const DATA = {
  zh: {
    kicker: '季度复盘 · 2026 Q3',
    title: '2026 Q3 复盘',
    lede: '一个季度里做成了什么、卡在哪、下个季度只做三件事。',
    kpis: [
      { label: '会话数', value: '482', delta: '+38%', up: true },
      { label: '活跃账号', value: '12', delta: '+3', up: true },
      { label: '平均首响', value: '1.9s', delta: '−0.6s', up: true },
      { label: '未结问题', value: '7', delta: '−4', up: true },
    ],
    chartTitle: '每周会话（13 周）',
    weeks: ['W27', 'W28', 'W29', 'W30', 'W31', 'W32', 'W33', 'W34', 'W35', 'W36', 'W37', 'W38', 'W39'],
    series: [18, 24, 21, 30, 27, 39, 44, 41, 52, 48, 61, 58, 69],
    findings: [
      { n: '01', head: '发布节奏松动', body: '13 周里有 5 周没有发布，集中在月末。把发布切成每周一条，卡住的周会立刻显形。' },
      { n: '02', head: '首响时间被工具调用拖住', body: '带工具调用的回合平均 3.4 秒，纯对话 0.9 秒。默认模型上把思考档位降一级，回到 1.9 秒。' },
      { n: '03', head: '文档开始还债', body: '三篇设计文档与代码不一致，全部补了"以代码为准"的对照表。' },
    ],
    tableTitle: '下个季度的三件事',
    rows: [['产品初始化', '默认名本地化、示例数据开关', '10 月'], ['演示环境', '两套账号可一键重跑', '10 月'], ['发布节奏', '每周一条，不攒批', '持续']],
    cols: ['事项', '做到什么算完', '时间'],
    footer: '数据来源：平台会话日志 · 生成于 2026-10-08',
  },
  en: {
    kicker: 'Quarterly retro · Q3 2026',
    title: 'Q3 2026 retro',
    lede: 'What shipped, what stalled, and the three things next quarter is allowed to be about.',
    kpis: [
      { label: 'Sessions', value: '482', delta: '+38%', up: true },
      { label: 'Active accounts', value: '12', delta: '+3', up: true },
      { label: 'First response', value: '1.9s', delta: '−0.6s', up: true },
      { label: 'Open issues', value: '7', delta: '−4', up: true },
    ],
    chartTitle: 'Sessions per week (13 weeks)',
    weeks: ['W27', 'W28', 'W29', 'W30', 'W31', 'W32', 'W33', 'W34', 'W35', 'W36', 'W37', 'W38', 'W39'],
    series: [18, 24, 21, 30, 27, 39, 44, 41, 52, 48, 61, 58, 69],
    findings: [
      { n: '01', head: 'The release cadence slipped', body: 'Five of thirteen weeks shipped nothing, all at month end. Slicing releases weekly makes a stuck week visible immediately.' },
      { n: '02', head: 'Tool calls own the first response', body: 'Turns with tool calls averaged 3.4s against 0.9s for plain chat. One thinking level lower on the default model brought it back to 1.9s.' },
      { n: '03', head: 'The docs started paying interest', body: 'Three design documents disagreed with the code; each now carries a "the code wins" table.' },
    ],
    tableTitle: 'Three things next quarter',
    rows: [['Product onboarding', 'Localised default names, a sample-data switch', 'Oct'], ['Demo environment', 'Two accounts, one re-runnable seed', 'Oct'], ['Release cadence', 'Weekly, never batched', 'Ongoing']],
    cols: ['Item', 'Done means', 'When'],
    footer: 'Source: platform conversation logs · generated 2026-10-08',
  },
}

const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')

export function showcase(lang) {
  const d = DATA[lang]
  const max = Math.max(...d.series)
  const W = 720, H = 220, pad = 28
  const pts = d.series.map((v, i) => {
    const x = pad + (i * (W - pad * 2)) / (d.series.length - 1)
    const y = H - pad - ((v / max) * (H - pad * 2))
    return [x, y, v, d.weeks[i]]
  })
  const line = pts.map(([x, y], i) => `${i ? 'L' : 'M'}${x.toFixed(1)} ${y.toFixed(1)}`).join(' ')
  const area = `${line} L${pts[pts.length - 1][0].toFixed(1)} ${H - pad} L${pts[0][0].toFixed(1)} ${H - pad} Z`
  const dots = pts.map(([x, y, v, w]) => `<circle class="dot" cx="${x.toFixed(1)}" cy="${y.toFixed(1)}" r="3.5" data-v="${v}" data-w="${w}"/>`).join('')

  return `<!doctype html>
<html lang="${lang === 'zh' ? 'zh-CN' : 'en'}"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>${esc(d.title)}</title>
<style>
  :root{--ink:#0f172a;--dim:#5b6a7f;--line:#e4e8ee;--brand:#155dfc;--brand2:#6ea8ff;--paper:#fff}
  *{box-sizing:border-box}
  body{margin:0;background:#f6f7f9;color:var(--ink);font:15px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI","PingFang SC","Microsoft YaHei",sans-serif;-webkit-font-smoothing:antialiased}
  .page{max-width:760px;margin:0 auto;background:var(--paper)}
  .hero{position:relative;padding:34px 34px 30px;background:linear-gradient(135deg,#0b1a33 0%,#123a7a 55%,#155dfc 100%);color:#fff;overflow:hidden}
  .hero::after{content:"";position:absolute;inset:-40% -10% auto auto;width:60%;height:180%;background:radial-gradient(closest-side,rgba(255,255,255,.18),transparent 70%);transform:rotate(18deg)}
  .kicker{font:600 11px/1 ui-monospace,Menlo,monospace;letter-spacing:.18em;text-transform:uppercase;opacity:.72}
  h1{margin:12px 0 0;font-size:34px;line-height:1.15;letter-spacing:-.02em}
  .lede{margin:10px 0 0;max-width:52ch;color:rgba(255,255,255,.82)}
  .kpis{display:grid;grid-template-columns:repeat(4,1fr);gap:12px;padding:0 34px;margin:-18px 0 0;position:relative}
  .kpi{background:#fff;border:1px solid var(--line);border-radius:14px;padding:14px 16px;box-shadow:0 6px 18px rgba(16,24,40,.06)}
  .kpi b{display:block;font-size:24px;letter-spacing:-.02em}
  .kpi span{display:block;font-size:12px;color:var(--dim);margin-top:2px}
  .kpi i{font-style:normal;font-size:11.5px;color:#0e8a5f;font-weight:600}
  section{padding:28px 34px 0}
  h2{font-size:13px;letter-spacing:.06em;text-transform:uppercase;color:var(--dim);margin:0 0 12px}
  .chart{position:relative;background:#fff;border:1px solid var(--line);border-radius:16px;padding:14px 8px 6px}
  svg{display:block;width:100%;height:auto}
  .grid line{stroke:#eef1f5;stroke-width:1}
  .axis text{fill:#8a97a8;font-size:10.5px;font-family:ui-monospace,Menlo,monospace}
  .area{fill:url(#g);opacity:.5}
  .line{fill:none;stroke:var(--brand);stroke-width:2.5;stroke-linejoin:round;stroke-linecap:round}
  .dot{fill:#fff;stroke:var(--brand);stroke-width:2;cursor:pointer;transition:r .12s ease}
  .dot:hover{r:5.5}
  .tip{position:absolute;pointer-events:none;background:#0f172a;color:#fff;font-size:11.5px;padding:5px 8px;border-radius:7px;opacity:0;transform:translate(-50%,-130%);transition:opacity .12s ease;white-space:nowrap}
  .findings{display:grid;gap:10px}
  .finding{display:grid;grid-template-columns:38px 1fr;gap:12px;background:#fff;border:1px solid var(--line);border-radius:14px;padding:14px 16px}
  .finding b{display:block;font-size:14px}
  .finding p{margin:4px 0 0;color:var(--dim);font-size:13.5px}
  .finding em{font-style:normal;font-weight:700;font-size:13px;color:var(--brand);font-family:ui-monospace,Menlo,monospace}
  table{width:100%;border-collapse:collapse;font-size:13.5px;background:#fff;border:1px solid var(--line);border-radius:14px;overflow:hidden}
  th{text-align:left;font-size:10.5px;letter-spacing:.1em;text-transform:uppercase;color:#8a97a8;padding:10px 14px;border-bottom:1px solid var(--line);font-weight:600}
  td{padding:11px 14px;border-bottom:1px solid #eef1f5;color:#33425a}
  tr:last-child td{border-bottom:0}
  footer{padding:22px 34px 30px;color:#8a97a8;font-size:11.5px}
</style></head>
<body><div class="page">
  <header class="hero">
    <p class="kicker">${esc(d.kicker)}</p>
    <h1>${esc(d.title)}</h1>
    <p class="lede">${esc(d.lede)}</p>
  </header>

  <div class="kpis">
    ${d.kpis.map((k) => `<div class="kpi"><b>${esc(k.value)}</b><span>${esc(k.label)}</span><i>${esc(k.delta)}</i></div>`).join('\n    ')}
  </div>

  <section>
    <h2>${esc(d.chartTitle)}</h2>
    <div class="chart">
      <svg viewBox="0 0 ${W} ${H}" role="img" aria-label="${esc(d.chartTitle)}">
        <defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stop-color="#155dfc" stop-opacity=".55"/>
          <stop offset="1" stop-color="#155dfc" stop-opacity="0"/>
        </linearGradient></defs>
        <g class="grid">
          ${[0, 1, 2, 3].map((i) => `<line x1="${pad}" x2="${W - pad}" y1="${(pad + ((H - pad * 2) / 3) * i).toFixed(1)}" y2="${(pad + ((H - pad * 2) / 3) * i).toFixed(1)}"/>`).join('')}
        </g>
        <path class="area" d="${area}"/>
        <path class="line" d="${line}"/>
        ${dots}
        <g class="axis">
          ${pts.map(([x], i) => (i % 2 === 0 ? `<text x="${x.toFixed(1)}" y="${H - 6}" text-anchor="middle">${esc(d.weeks[i])}</text>` : '')).join('')}
        </g>
      </svg>
      <div class="tip" id="tip"></div>
    </div>
  </section>

  <section>
    <h2>${esc(d.findings.length ? d.kicker.split('·')[1]?.trim() || 'Findings' : '')}</h2>
    <div class="findings">
      ${d.findings.map((f) => `<div class="finding"><em>${f.n}</em><div><b>${esc(f.head)}</b><p>${esc(f.body)}</p></div></div>`).join('\n      ')}
    </div>
  </section>

  <section>
    <h2>${esc(d.tableTitle)}</h2>
    <table><thead><tr>${d.cols.map((c) => `<th>${esc(c)}</th>`).join('')}</tr></thead>
    <tbody>${d.rows.map((r) => `<tr>${r.map((c) => `<td>${esc(c)}</td>`).join('')}</tr>`).join('')}</tbody></table>
  </section>

  <footer>${esc(d.footer)}</footer>
</div>
<script>
  // The preview iframe runs with allow-scripts: this is the chart's readout.
  const tip = document.getElementById('tip')
  document.querySelectorAll('.dot').forEach((dot) => {
    dot.addEventListener('mouseenter', () => {
      const box = dot.ownerSVGElement.getBoundingClientRect()
      const cx = (dot.cx.baseVal.value / ${W}) * box.width
      const cy = (dot.cy.baseVal.value / ${H}) * box.height
      tip.textContent = dot.dataset.w + ' · ' + dot.dataset.v
      tip.style.left = cx + 'px'
      tip.style.top = cy + 'px'
      tip.style.opacity = '1'
    })
    dot.addEventListener('mouseleave', () => { tip.style.opacity = '0' })
  })
</script>
</body></html>`
}
