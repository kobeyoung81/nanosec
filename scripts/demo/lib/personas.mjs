// The demo content, in both languages. One account per language so a screenshot
// never shows Chinese data under an English UI (or the reverse).

export const BASE_URL = process.env.DEMO_BASE_URL || 'https://devnanosec.kobeyoung81.cn'

export const ACCOUNTS = [
  {
    key: 'zh',
    email: process.env.DEMO_ZH_EMAIL || 'demo.zh@nanosec.dev',
    password: process.env.DEMO_ZH_PASSWORD || 'Demo-NanoSec-2026',
    displayName: '演示账号 · 中文',
    lang: 'zh-CN',
    uiLang: 'zh-CN',
  },
  {
    key: 'en',
    email: process.env.DEMO_EN_EMAIL || 'demo.en@nanosec.dev',
    password: process.env.DEMO_EN_PASSWORD || 'Demo-NanoSec-2026',
    displayName: 'Demo account · English',
    lang: 'en',
    uiLang: 'en',
  },
]

// ── agents ────────────────────────────────────────────────────────────────
// Eight agents, three groups: enough that grouping means something (2–3 per
// group) and the sidebar shows a real list rather than one lonely row.
export const CONTENT = {
  zh: {
    groups: ['工作', '研究', '日常'],
    agents: [
      { name: '助理', group: '工作', about: '通用助手，管日程与杂事' },
      { name: '前端工程师', group: '工作', about: 'React 与 TypeScript，改界面' },
      { name: '运维助手', group: '工作', about: '部署、容器与排障' },
      { name: '数据分析', group: '研究', about: '日志与指标，出结论' },
      { name: '资料研究员', group: '研究', about: '查资料、做综述' },
      { name: '写作搭档', group: '日常', about: '文案与润色' },
      { name: '会议记录', group: '日常', about: '纪要整理与待办拆解' },
      { name: '代码评审', group: '日常', about: '看可读性与边界情况' },
    ],
    space: '季度工作台',
    folders: ['复盘', '文档', '报告'],
  },
  en: {
    groups: ['Work', 'Research', 'Everyday'],
    agents: [
      { name: 'Assistant', group: 'Work', about: 'General help, calendar and chores' },
      { name: 'Front-end Engineer', group: 'Work', about: 'React and TypeScript, UI work' },
      { name: 'Ops Assistant', group: 'Work', about: 'Deploys, containers and incidents' },
      { name: 'Data Analyst', group: 'Research', about: 'Logs and metrics, conclusions' },
      { name: 'Research Scout', group: 'Research', about: 'Reads around a topic, writes the summary' },
      { name: 'Writing Partner', group: 'Everyday', about: 'Copy and editing' },
      { name: 'Meeting Notes', group: 'Everyday', about: 'Minutes and follow-ups' },
      { name: 'Code Reviewer', group: 'Everyday', about: 'Readability and edge cases' },
    ],
    space: 'Quarterly workspace',
    folders: ['Retros', 'Docs', 'Reports'],
  },
}

// ── conversations ─────────────────────────────────────────────────────────
// Twelve per account. Four of them also schedule a task, two of them also write
// a file, so the Tasks panel and the Files panel fill up without extra turns.
export const TALKS = {
  zh: [
    { agent: '助理', prompt: '用三句话说明这个平台能做什么，别用营销词。' },
    { agent: '前端工程师', prompt: '登录页的按钮现在有三种圆角混在一起。列出你打算统一成哪几个值，以及要改哪些文件。' },
    { agent: '数据分析', prompt: '这是一份访问日志的样本（ts, path, status, ms）：\n10:01 /api/agent 200 240\n10:02 /api/agent 200 191\n10:03 /api/agent 500 3120\n10:04 /api/files 200 88\n10:05 /api/agent 200 205\n说三个你能直接看出来的结论。' },
    { agent: '资料研究员', prompt: '对比 RAG 和长上下文两种做法，用表格给我：适用场景、成本、主要缺点。' },
    { agent: '运维助手', prompt: '看一下工作区占了多少空间，给出三条清理建议。', followUp: { prompt: '顺便帮我排一个每天 22:00 检查一次备份的定时任务。', kind: 'task' } },
    { agent: '写作搭档', prompt: '把这句话改得克制一点：「我们打造了业界领先的、颠覆性的 AI 平台。」给我两版。' },
    { agent: '会议记录', prompt: '把这周的例会要点整理成纪要：\n- 发布延到下周三\n- 前端先合登录页\n- 监控告警阈值要重定\n- 需要一个人对接测试环境', followUp: { prompt: '把这份纪要存成 notes/2026-w47-meeting.md。', kind: 'file' } },
    { agent: '代码评审', prompt: '审一下这段组件的可读性，指出两处最该改的地方：\nfunction P({a,b,c}){return a?b?c?<X/>:<Y/>:<Z/>:<W/>}' },
    { agent: '助理', prompt: '帮我排一个每天 09:00 汇总待办的定时任务。', followUp: null },
    { agent: '数据分析', prompt: '写一份季度复盘的结论，三条，每条约两行。', followUp: { prompt: '把结论存成 notes/2026-q3-retro.md。', kind: 'file' } },
    { agent: '写作搭档', prompt: '排一个每周五 18:00 整理周报的定时任务。', followUp: null },
    { agent: '运维助手', prompt: '排一个每月 1 日清理临时文件的定时任务。', followUp: null },
  ],
  en: [
    { agent: 'Assistant', prompt: 'Explain what this platform does in three sentences, without marketing words.' },
    { agent: 'Front-end Engineer', prompt: 'The login page mixes three different button radii. List the values you would unify on, and which files change.' },
    { agent: 'Data Analyst', prompt: 'Here is a sample access log (ts, path, status, ms):\n10:01 /api/agent 200 240\n10:02 /api/agent 200 191\n10:03 /api/agent 500 3120\n10:04 /api/files 200 88\n10:05 /api/agent 200 205\nGive me three conclusions you can draw from it directly.' },
    { agent: 'Research Scout', prompt: 'Compare RAG and long context in a table: when each applies, cost, main drawback.' },
    { agent: 'Ops Assistant', prompt: 'How much space is the workspace using? Give me three cleanup suggestions.', followUp: { prompt: 'Also schedule a daily 22:00 backup check for me.', kind: 'task' } },
    { agent: 'Writing Partner', prompt: 'Make this less boastful, two versions: "We built the industry-leading, disruptive AI platform."' },
    { agent: 'Meeting Notes', prompt: 'Turn this week\'s standup notes into minutes:\n- release slips to next Wednesday\n- front end merges the login page first\n- alert thresholds need rethinking\n- someone must own the test environment hand-over', followUp: { prompt: 'Save the minutes as notes/2026-w47-meeting.md.', kind: 'file' } },
    { agent: 'Code Reviewer', prompt: 'Review this component for readability and name the two things worth changing:\nfunction P({a,b,c}){return a?b?c?<X/>:<Y/>:<Z/>:<W/>}' },
    { agent: 'Assistant', prompt: 'Schedule a daily 09:00 digest of my open tasks.', followUp: null },
    { agent: 'Data Analyst', prompt: 'Write a three-point conclusion for the quarterly retro, about two lines each.', followUp: { prompt: 'Save it as notes/2026-q3-retro.md.', kind: 'file' } },
    { agent: 'Writing Partner', prompt: 'Schedule a weekly Friday 18:00 report-writing task.', followUp: null },
    { agent: 'Ops Assistant', prompt: 'Schedule a monthly cleanup of temporary files on the first of the month.', followUp: null },
  ],
}

// ── work library ──────────────────────────────────────────────────────────
export const WORKS = {
  zh: [
    { folder: '复盘', showcase: true, template: 'report', spec: {
      kicker: '复盘 · 2026 Q3', title: '2026 Q3 复盘',
      lede: '一个季度里做成了什么、卡在哪、下个季度只做三件事。',
      sections: [
        { heading: '做成了什么', paragraphs: ['控制台换成石墨主题，深色下不再是"黑乎乎一团"：画布、卡片、边框分成三级，边界能看出来了。'], bullets: ['图标体系收敛到一套线稿 n，五个尺寸同一份几何', '设计令牌成为唯一源，配色与结构拆成两轴', '文档资产加了门禁，死图进不来了'] },
        { heading: '卡在哪', paragraphs: ['服务拆分收尾比预期慢：最后几处兼容转发牵动四个模块，每改一处都要重跑整套集成测试。'], bullets: ['集群前提（副本集、共享卷）还差一个演练', '演示数据一直是手工凑，截图时总是临时找'] },
        { heading: '下个季度只做三件事', paragraphs: ['一，把演示环境做成可重跑的；二，把产品初始化补上；三，发布节奏从"攒一批"改成"每周一条"。'] },
      ] } },
    { folder: '复盘', template: 'timeline', spec: {
      kicker: '事件复盘', title: '网关重启事件复盘',
      lede: '一次 14 分钟的重启循环，以及为什么监控没能提前叫。',
      events: [
        { time: '14:02', text: '网关开始重启，间隔 40 秒，连续 21 次。' },
        { time: '14:06', text: '聊天通道出现 502，第一个用户反馈进入工单。' },
        { time: '14:11', text: '定位到共享令牌被一处配置覆盖，容器起不来。' },
        { time: '14:16', text: '回滚配置，网关稳定；补了一条启动自检。' },
        { time: '14:40', text: '告警规则补上"重启次数"这一条指标。' },
      ] } },
    { folder: '复盘', template: 'checklist', spec: {
      kicker: '发布', title: '发布流程的三个断点',
      lede: '每次发版都要重新想一遍的三件事，做成清单。',
      items: [
        { text: '子仓先推、父仓后推，指针必须指向已在远端的提交', done: true },
        { text: '发布前跑一遍文档资产门禁（体积 / 引用 / 退役色）', done: true },
        { text: '初始化容器要 --force-recreate，否则种子不会重跑', done: true },
        { text: '灰度前确认副本集与共享卷就位', done: false },
        { text: '回滚脚本演练一次，别在夜里第一次执行', done: false },
      ] } },
    { folder: '文档', template: 'table', spec: {
      kicker: '接口', title: '接口对照表',
      lede: '门户对外暴露的三组路径，以及各自归谁。',
      columns: ['路径', '归属', '鉴权', '说明'], numeric: [],
      rows: [
        ['/api/auth/v1/*', 'nanoauth', '公开', '登录、注册、刷新、JWKS'],
        ['/api/user/v1/*', 'nanoportal', 'Bearer / 会话', '智能体、会话、文件、偏好'],
        ['/api/admin/v1/*', 'nanoportal', 'Bearer + 角色', '用户、组件、运行时、会话日志'],
        ['/api/v1/*', 'nanoadmin', 'Bearer', '配置、目录、告警、审计'],
        ['/nanoartifacts/api/v1/*', 'nanoartifacts', 'Bearer / 会话 cookie', '空间、节点、作品、版本'],
      ] } },
    { folder: '文档', template: 'checklist', spec: {
      kicker: '上线', title: '上线检查清单',
      lede: '发布前 30 分钟照着点一遍。',
      items: [
        { text: 'versions.lock 与十个镜像 tag 对齐', done: true },
        { text: '.env 里的三个密钥已轮换或确认沿用', done: true },
        { text: '数据库副本集可写，备份窗口没和发布撞车', done: true },
        { text: '初始化容器跑完，目录数据已灌', done: true },
        { text: '健康检查四个端点全绿', done: false },
        { text: '示例账号能登录、能发一条消息', done: false },
      ] } },
    { folder: '文档', template: 'onepager', spec: {
      kicker: '架构', title: '架构一页纸',
      lede: '八个服务、一个总线、一个库，每个模块一组前缀。',
      tiles: [
        { value: '8', label: '一等服务' }, { value: '1', label: 'MongoDB' }, { value: '5', label: '对外渠道' },
      ],
      body: { heading: '三条规则', paragraphs: ['总线只运消息；一个模块一组前缀，别人要用走 API；服务之间走内部 HTTP 带共享令牌。'] } } },
    { folder: '文档', template: 'report', spec: {
      kicker: '安全', title: '权限模型说明',
      lede: '谁能看到什么、谁能改什么，以及边界在哪里。',
      sections: [
        { heading: '三层', paragraphs: ['账号角色、智能体权限键、容器边界。前两层在应用里判，第三层靠容器本身。'], bullets: ['管理员动作写审计，用户动作写会话日志', '内部面只认共享令牌', '智能体只能碰自己容器里的东西'] },
      ] } },
    { folder: '报告', template: 'chart', spec: {
      kicker: '报告 · 访问日志', title: '访问日志分析',
      lede: '一周的请求按路径分布，/api/agent 占了大头。',
      max: 100,
      bars: [
        { label: '/api/agent', value: 62 }, { label: '/api/files', value: 14 },
        { label: '/api/admin', value: 9 }, { label: '/api/auth', value: 8 },
        { label: '/nanoartifacts', value: 7 },
      ] } },
    { folder: '报告', template: 'table', spec: {
      kicker: '报告 · 选型', title: '模型选型对比',
      lede: '三个候选，按"够不够用"而不是"跑分高不高"来比。',
      columns: ['模型', '上下文', '速度', '结论'], numeric: [],
      rows: [
        ['Basic', '1M', '中', '默认；日常对话与工具调用够用'],
        ['Pro', '1M', '慢', '长文档摘要与代码评审用'],
        ['Free', '200k', '快', '短问答与标题生成'],
      ] } },
    { folder: '报告', template: 'onepager', spec: {
      kicker: '模板', title: '周报模板',
      lede: '三段话讲完一周：做完了什么、卡在哪、下周做什么。',
      tiles: [{ value: '3', label: '段' }, { value: '≤10', label: '行' }, { value: '5min', label: '写完' }],
      body: { heading: '写法', paragraphs: ['每段最多三行；只写结论和下一步，不复述过程；卡点必须写清要谁配合。'] } } },
    { folder: '报告', template: 'chart', spec: {
      kicker: '报告 · 指标', title: '季度指标',
      lede: '四个数看一个季度：会话数、活跃账号、容器数、平均首响。',
      max: 100,
      bars: [
        { label: '会话数', value: 78, display: '482' }, { label: '活跃账号', value: 46, display: '12' },
        { label: '容器数', value: 33, display: '9' }, { label: '平均首响', value: 61, display: '1.9s' },
      ] } },
    { folder: '报告', template: 'report', spec: {
      kicker: '模板', title: '会议纪要模板',
      lede: '纪要只留四样东西：决定、待办、负责人、时间。',
      sections: [
        { heading: '结构', paragraphs: ['开头一句会议目的；中间按议题列决定；结尾一张待办表，每条都有负责人和日期。'], bullets: ['不写发言过程', '决定用完成时态', '待办必须能被别人接手'] },
      ] } },
  ],
  en: [
    { folder: 'Retros', showcase: true, template: 'report', spec: {
      kicker: 'Retro · Q3 2026', title: 'Q3 2026 retro',
      lede: 'What shipped, what stalled, and the three things next quarter is allowed to be about.',
      sections: [
        { heading: 'Shipped', paragraphs: ['The console moved to the graphite theme. Dark mode stopped being one flat black sheet: canvas, card and border are three distinguishable levels now.'], bullets: ['One line-art mark across five sizes', 'Design tokens became the single source, split into structure and palette', 'Docs assets have a gate, so dead images cannot come back'] },
        { heading: 'Stalled', paragraphs: ['The service split keeps taking longer than planned: the last compatibility forwards touch four modules, and every change re-runs the whole integration set.'], bullets: ['Cluster prerequisites still need one rehearsal', 'Demo data was hand-built every time, so screenshots were always a scramble'] },
        { heading: 'Three things next quarter', paragraphs: ['One: make the demo environment re-runnable. Two: finish product onboarding. Three: ship weekly instead of in batches.'] },
      ] } },
    { folder: 'Retros', template: 'timeline', spec: {
      kicker: 'Incident', title: 'Gateway restart loop',
      lede: 'Fourteen minutes of restart loops, and why monitoring stayed quiet.',
      events: [
        { time: '14:02', text: 'The gateway starts restarting every 40 seconds — 21 times.' },
        { time: '14:06', text: 'Chat returns 502; the first user report lands.' },
        { time: '14:11', text: 'Root cause: the shared token is overwritten by a config value, so the container cannot start.' },
        { time: '14:16', text: 'Config rolled back, gateway stable, a startup self-check added.' },
        { time: '14:40', text: 'Alert rule added on restart count.' },
      ] } },
    { folder: 'Retros', template: 'checklist', spec: {
      kicker: 'Release', title: 'Three seams in the release flow',
      lede: 'The three things we have to re-derive every release, written down.',
      items: [
        { text: 'Push submodules first, then the super-repo; pointers must exist upstream', done: true },
        { text: 'Run the docs-asset gate before releasing (size / references / retired colours)', done: true },
        { text: 'Init containers need --force-recreate, or the seed never re-runs', done: true },
        { text: 'Confirm replica set and shared volume before the canary', done: false },
        { text: 'Rehearse the rollback script — not for the first time at night', done: false },
      ] } },
    { folder: 'Docs', template: 'table', spec: {
      kicker: 'API', title: 'Endpoint map',
      lede: 'The four path groups the portal exposes, and who owns each.',
      columns: ['Path', 'Owner', 'Auth', 'What it does'], numeric: [],
      rows: [
        ['/api/auth/v1/*', 'nanoauth', 'public', 'login, register, refresh, JWKS'],
        ['/api/user/v1/*', 'nanoportal', 'bearer / session', 'agents, sessions, files, preferences'],
        ['/api/admin/v1/*', 'nanoportal', 'bearer + role', 'users, components, runtime, conversation logs'],
        ['/api/v1/*', 'nanoadmin', 'bearer', 'config, directory, alerts, audit'],
        ['/nanoartifacts/api/v1/*', 'nanoartifacts', 'bearer / cookie', 'spaces, nodes, works, versions'],
      ] } },
    { folder: 'Docs', template: 'checklist', spec: {
      kicker: 'Launch', title: 'Launch checklist',
      lede: 'Walk it 30 minutes before the release.',
      items: [
        { text: 'versions.lock matches all ten image tags', done: true },
        { text: 'Three secrets in .env rotated or confirmed', done: true },
        { text: 'Replica set writable; backup window does not collide', done: true },
        { text: 'Init containers finished, catalogues seeded', done: true },
        { text: 'Four health endpoints green', done: false },
        { text: 'Demo account can log in and send one message', done: false },
      ] } },
    { folder: 'Docs', template: 'onepager', spec: {
      kicker: 'Architecture', title: 'Architecture on one page',
      lede: 'Eight services, one bus, one database, one prefix per module.',
      tiles: [{ value: '8', label: 'services' }, { value: '1', label: 'MongoDB' }, { value: '5', label: 'channels' }],
      body: { heading: 'Three rules', paragraphs: ['The bus carries messages only; a module writes only its own prefix and everyone else reads over its API; services talk over internal HTTP with the shared token.'] } } },
    { folder: 'Docs', template: 'report', spec: {
      kicker: 'Security', title: 'Permission model',
      lede: 'Who sees what, who changes what, and where the boundary actually is.',
      sections: [
        { heading: 'Three layers', paragraphs: ['Account role, agent permission keys, container boundary. The first two are enforced in the app; the third is the container itself.'], bullets: ['Admin actions are audited; user actions land in the conversation log', 'Internal surfaces only accept the shared token', 'An agent can only touch what is inside its own container'] },
      ] } },
    { folder: 'Reports', template: 'chart', spec: {
      kicker: 'Report · Access log', title: 'Access log analysis',
      lede: 'One week of requests by path; /api/agent dominates.',
      max: 100,
      bars: [
        { label: '/api/agent', value: 62 }, { label: '/api/files', value: 14 },
        { label: '/api/admin', value: 9 }, { label: '/api/auth', value: 8 },
        { label: '/nanoartifacts', value: 7 },
      ] } },
    { folder: 'Reports', template: 'table', spec: {
      kicker: 'Report · Selection', title: 'Model comparison',
      lede: 'Three candidates, judged by "good enough" rather than benchmark score.',
      columns: ['Model', 'Context', 'Speed', 'Verdict'], numeric: [],
      rows: [
        ['Basic', '1M', 'medium', 'Default; daily chat and tool calls'],
        ['Pro', '1M', 'slow', 'Long documents and code review'],
        ['Free', '200k', 'fast', 'Short Q&A and title generation'],
      ] } },
    { folder: 'Reports', template: 'onepager', spec: {
      kicker: 'Template', title: 'Weekly report template',
      lede: 'Three paragraphs: what shipped, what is stuck, what is next.',
      tiles: [{ value: '3', label: 'paragraphs' }, { value: '≤10', label: 'lines' }, { value: '5min', label: 'to write' }],
      body: { heading: 'How', paragraphs: ['Three lines per paragraph; conclusions and next steps only, never the process; a blocker names who has to unblock it.'] } } },
    { folder: 'Reports', template: 'chart', spec: {
      kicker: 'Report · Metrics', title: 'Quarterly metrics',
      lede: 'Four numbers per quarter: sessions, active accounts, containers, first response.',
      max: 100,
      bars: [
        { label: 'Sessions', value: 78, display: '482' }, { label: 'Active accounts', value: 46, display: '12' },
        { label: 'Containers', value: 33, display: '9' }, { label: 'First response', value: 61, display: '1.9s' },
      ] } },
    { folder: 'Reports', template: 'report', spec: {
      kicker: 'Template', title: 'Meeting minutes template',
      lede: 'Four things only: decisions, actions, owners, dates.',
      sections: [
        { heading: 'Shape', paragraphs: ['One line of purpose, then decisions per agenda item, then an action table where every row has an owner and a date.'], bullets: ['No transcript', 'Decisions in the past tense', 'Every action can be picked up by someone else'] },
      ] } },
  ],
}
