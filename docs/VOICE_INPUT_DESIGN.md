# 语音输入（Composer 点击说话，三层识别）

- **状态**：已实现（2026-10-10）
- **影响的服务**：`nanobus`（WS 端点、Realtime 会话客户端、平台配置）、`nanoportal`（REST 透传、nginx、Composer UI、管理员配置卡）
- **不涉及**：`nanosec`（音频不进 agent、不落盘），`nanogateway`（聊天 WS 与语音 WS 是两条独立通道）

## 1. 用户看到什么

Composer 的尾部按钮在草稿为空时是**麦克风**，占位文案是"在这里输入，或按住麦克风说话"；一旦有键盘输入就变回**发送键**。

- 取消：录音条上的 **✕** 或键盘 **Esc**（上滑手势已按用户要求删除）。
- **点击**麦克风开始：输入框位置变成只读预览，逐字出现**带下划线的临时文本**（真实流式；下划线表示"还没润色"），工具栏那一行换成"脉冲点 + 计时 + 音量条 + 状态 + ✕"。**没有滑动手势**：按钮上写着"点击结束"，再点一下就收尾。
- **再点一次**结束：下划线文本的**末尾**出现一个**闪烁的画笔**表示润色中；润色完成后内容被替换、下划线消失、输入框回到可编辑状态。
- 上游在录音中途把会话结束/报错时：**自动续接**（保留已得文本 → 领新号 → 换 socket 继续，最长 5 次）；确实接不上才收尾，并把原因（上游消息或关闭码）写进提示。
- 智能体正在跑回合（尾部是停止键）时**不提供**录音入口；平台没开语音、或浏览器拿不到麦克风（非 https/localhost）时，麦克风直接不出现。

## 2. 链路

```
浏览器  ──REST──▶ portal(Go) ──▶ bus(Go) ──▶ 网关(LiteLLM) ──▶ 上游 ASR
  │  ①POST /api/user/v1/voice/session  （领一次性 session id）
  │  ②POST /api/user/v1/voice/polish   （松手后润色整段文字）
  │
  └──WS──▶ portal 的 nginx ──▶ bus  /ws/voice?session=<id>  ──▶ 网关 /v1/realtime
     ③二进制帧 = 24kHz 单声道 PCM16      ④base64 包成 input_audio_buffer.append
```

- **音频不进 portal 的 Go 服务**：nginx 把 `/ws/voice` 直接转给 nanobus（`nanoportal/deploy/nginx.conf`），和聊天 WS 直连 gateway 是同一个套路。
- **只有 REST 走 portal**：`setting`/`session`/`polish`/`transcribe` 四个路由由 portal 鉴权后注入 `user_id` 转发（`nanoportal/server/internal/api/voice.go`）。

## 3. 事件序列

1. bus 先连上游（`nanobus/internal/voice/realtime.go` 的 `Dial`），发 GA 形状的 `session.update`：

   ```json
   {"type":"session.update","session":{"type":"transcription","audio":{"input":{
     "format":{"type":"audio/pcm","rate":24000},
     "transcription":{"model":"<别名>","language":"zh","prompt":"…"},
     "turn_detection":null}}}}
   ```

   `turn_detection` 刻意留 **null**：按住说话的手动回合边界比服务端 VAD 更符合这个交互（也避免依赖哪个模型支持 VAD）。
2. 等上游回 `session.updated` 才开录（握手超时 10s；上游拒绝会话会作为 HTTP 502 抛给浏览器，而不是静默断连）。
3. 浏览器每 ~170 ms 发一个二进制帧；bus 把它 base64 成 `input_audio_buffer.append`。
4. 松手时浏览器发 `{"type":"commit"}`，bus 转成 `input_audio_buffer.commit`。
5. 上游回 `…transcription.delta` / `…transcription.completed`；bus **归一化**成 `{type:delta|done|error}` 再给浏览器（同时接受 GA 与旧 beta 事件名，认不出的直接丢）。
6. 收到 `done` 后浏览器发润色请求，然后关会话。

`asr.commitIntervalMs` > 0 时 bus 会按音频字节数周期性主动 commit——当某个模型在整段音频上不吐 delta 时才需要（见 §6 的实测）。

**会话生命周期（四条路径，都收敛到同一个 `finalize()`）**
1. **用户点停** → 发 `commit` → 等 `done`（20s 上限）→ 润色。
2. **到 `asr.maxSeconds`** → 与点停同路径（跨续接也计时）。
3. **上游结束/报错** → 若还在录音则**自动续接**（`onUpstreamLost`，≤5 次）；否则/超限 → 用已有文本润色。
4. **取消**（✕ / Esc）→ 丢弃，不交付。
关键点：**只有"取消"跳过润色**。第一轮把"上游报错"也当成交付即结束，于是"断了之后没有润色"——这正是用户报的问题 2。

**上游自带 VAD**：探针实测（`workspace/voiceprobe`）我们 40 秒不 `commit` 也完全存活，而上游自己会发 `speech_started/stopped` 与 `input_audio_buffer.committed`。所以 `asr.commitIntervalMs` 保持 0；点停时发的那个 `commit` 可能被拒（缓冲已被上游提交）——那种错误按**警告**处理，不是失败。

**句段边界 ≠ 会话边界（很重要）**：上游会在听到停顿处**自己**发一次 `…transcription.completed`，此时用户往往还按着按钮。所以前端把 `done` 当作**一个句段的结束**（文本并入已定稿部分，继续听），只有**松手**（或到 `maxSeconds`）才收尾润色；这条判断是 `web/src/voice/events.ts` 的 `endsDictation()`，有单测钉着（早期版本把任何 `done` 都当结束，表现为"说着说着自己停了并开始润色"）。

## 4. 鉴权：为什么是一次性 session id

bus 对内网**不做任何鉴权**（它信任 portal 注入的 `user_id`），而 WS 握手没法像 REST 那样由 portal 逐请求代理。所以：

1. portal（已经验过 JWT）调 bus `POST /api/v1/user/voice/session` **领号**；
2. 浏览器拿号连 `GET /ws/voice?session=<id>`；
3. bus 只认**自己发过、没用过、没过期**的号（60s TTL，内存里，`nanobus/internal/server/voice_sessions.go`）。

这样 portal 仍是唯一的鉴权边界，bus 不需要 JWT 校验也不需要访问 nanoauth 的 JWKS；WS 里也不携带任何长期凭证（号是一次性的，进 nginx 访问日志也无害）。

## 4.1 设置是怎么读回来的（两种形状）

- **写**：管理端 `PUT /api/admin/v1/configs/voice/{key}` → portal 代理到 bus。
- **读**：管理端 `GET /api/admin/v1/configs/voice` → portal **直接读自己的库**，返回 `{component_type, updated_at, config:{key: value}}`（`nanoportal/server/internal/api/server.go:446`、`repository/mysql.go:442`）；bus 自己那条 `GET /api/v1/config/voice` 返回的是 `{items:[{key,value}]}`。

浏览器两种都认（`web/src/lib/voiceSettings.ts` 的 `parseVoiceSettings`，有单测）。**并且**：读不到任何已知键时返回 `null`（而不是"全部默认值"），管理卡据此**禁用保存**——否则一次"读失败→按保存"会把 providerId/model/润色模型/提示词全写空（这个坑踩过一次）。

## 5. 配置（平台一份，无用户级覆盖）

三层（`voice` 组件的 `service_config_items`），播种子 `nanobus/cmd/nanobus/main.go` 的 `defaultConfigItems()`；编辑入口是门户的管理页 **`/admin/voice`**（也等价于配置页 / `nanobus config set voice <key>`）。bus **每次请求重读配置**，改完立即生效，不用重启；前端在保存后会丢掉本地缓存，刷新即用新值。

**第一层：实时识别**（说话时流进去的那一层）

| 键 | 默认 | 说明 |
|---|---|---|
| `enabled` | `false` | 总开关。没配好之前保持 false，前端不显示麦克风 |
| `realtime.providerId` | 空 | 模型目录里**平台 scope** 的 provider id。user scope 会被拒 |
| `realtime.model` | 空 | 该 provider 的模型别名（`?model=`） |
| `realtime.language` | `zh` | 留空 = 让模型自动检测 |
| `realtime.prompt` | 空 | 关键词/术语提示（透传给远端会话） |
| `realtime.maxSeconds` | `120` | 单次录音上限（服务端与前端双重生效），夹到 10..600 |
| `realtime.commitIntervalMs` | `0` | 0 = 只在用户结束时 commit；夹到 0..2000 |

**第二层：高精度兜底**（整段录音再识别一次，默认**每次都跑**）

| 键 | 默认 | 说明 |
|---|---|---|
| `batch.enabled` | `false` | 兜底开关。没配 provider/model 时不生效 |
| `batch.trigger` | `always` | `always`＝每次都跑；`manual`＝输入框上方出现按钮，点了才跑；`empty`＝只在实时结果为空或明显过短时跑 |
| `batch.providerId` | 空 | 平台 scope 的 provider（LiteLLM / 任何 OpenAI 兼容端点） |
| `batch.model` | 空 | 文件转写模型别名（whisper-1 一类） |
| `batch.language` / `batch.prompt` | `zh` / 空 | 透传给外部模型的语言与提示，留空则**不发送该字段** |

**第三层：润色**

| 键 | 默认 | 说明 |
|---|---|---|
| `polish.enabled` | `true` | 识别完是否再走一次聊天模型 |
| `polish.modelId` | 空 | 平台 scope 的聊天模型 id |
| `polish.prompt` | 内置中文提示词 | 只在补标点/纠错字/去口头语，不许加信息 |
| `polish.thinking` | `none`（关闭） | 润色的思考强度：`none`=**显式向上游声明不思考**（省略 `reasoning_effort` 并不会让推理模型停下来，所以关闭必须发这个值），可选 `low`/`medium`/`high`；空值与认不出的值一律按 `none` 处理（老配置的行里存的正是空值）。聊天侧同理：composer 的「关闭」与模型中心的思考开关也发 `none`（`nanosec` 侧映射） |
| `polish.skipAfterBatch` | `false` | 兜底层真的改写了文本时，是否跳过润色 |

**可用性规则**：麦克风只在**实时层配好**（`enabled` + `realtime.providerId/model`）时才出现——录音是由实时会话驱动的，只有兜底层时前端连音频都采不起来。实时层**配了但跑挂**（本机服务没起、握手失败、结束超时）属于运行时故障，而本次已经录到的音频会交给兜底层，这正是第二层存在的意义。

**provider 的边界**：识别服务必须是 **OpenAI 兼容端点**（`base_url` 以 `/v1` 结尾）——平台的 LiteLLM，或任何同形状的外部服务。形状不同的厂商（Deepgram / Azure Speech 等）不在配置里解决，而是需要一层把该厂商契约翻译成 OpenAI 形状的适配服务；平台本身不再运行识别运行时。`model_providers.kind` 目前只是标签，**没有任何代码按它分支**。

**识别运行时已移出平台**：平台只保留服务端中继（provider key 不下发浏览器）与实时协议客户端；没有本地引擎、没有 `realtime.engine` 开关、没有热词配置——这些随 `nanoasr` 一起移除了。`realtime.providerId` 与 `realtime.model` 指向哪个外部服务，就由哪个服务识别。



## 6. 配置步骤（部署后一次）

1. **确认 provider**：`base_url` 必须以 `/v1` 结尾。实时层用外部实时服务（LiteLLM 的 realtime 池，别名如 `qwen-realtime`），兜底层用文件转写模型；两者都可以指向同一条平台 scope 的 provider。
2. **在 `/admin/voice` 里配三层**：实时层选 provider 与模型（点「检测识别服务」会列出可用别名）；兜底层按需打开并选模型；润色按现状。
3. 语言填 `zh`（或留空自动）；提示词按需改。
4. **先做一次 V0 探针**（下面两条，决定 `commitIntervalMs` 与模型选择），确认后 `enabled=true`。
5. `/admin/voice` 里的两个测试按钮分别验证两层：走**一次性文件转写**（上传一段音频）打 `/v1/audio/transcriptions`，`target=batch` 的那个打兜底层。**实时**转写请在对话里点一次麦克风试。

### V0 探针（未做前不要打开开关）

- 连 `wss://<网关>/v1/realtime?model=<别名>&intent=transcription` + `Authorization: Bearer <key>`，确认接受上面的 GA `session.update`。
- `turn_detection: null` 下持续 append，观察 **delta 是否在音频还在发送时就到**：是 → `commitIntervalMs=0`；否（要 commit 才吐）→ 设 `commitIntervalMs=500` 并检查拼接质量。
- 顺带确认该模型在网关账单里的单价（流式模型与文件模型差价很大）。

## 7. 隐私与边界

- 音频**只走内存**：不落库、不写 agent 工作区、不写临时文件；WS 关闭即丢。
- 不做逐会话审计（一次 2 分钟录音会有几十帧），只有配置变更走既有的 Configs 审计。
- 不做全双工语音对话（没有 TTS、没有打断），Realtime 会话只用来转写。

## 8. 失败与降级

| 情况 | 表现 |
|---|---|
| 平台未配置 / 关掉 | 麦克风不显示（`GET /voice/config` 返回 `enabled=false` + reason） |
| 浏览器不支持（http 直连、老引擎） | 麦克风不显示，占位退回普通文案 |
| 麦克风权限被拒 | toast"没有获得麦克风权限"，草稿不变 |
| WS 连不上 / 上游拒绝会话 | toast"实时语音不可用"，草稿不变（握手在升级之前，所以能看到 502） |
| 说话中途断线 | 保留已经识别到的文字 + toast"语音中断…" |
| 平台没有配润色模型 | 直接落识别原文（不显示画笔），不报错 |
| 上游在按住期间自己结束一个句段 | 只当一个句段结束：文本并入已定稿部分，继续听，不收尾 |
| 润色失败或返回离谱内容 | 落**识别原文** + 提示；`polishFallback` 兜住"模型开始解释自己"的情况（`web/src/voice/events.ts`） |
| 收音为空 | 提示"没有听清，请再说一次"，草稿不变 |

## 9. 为什么不用这些替代方案（2026-10-10 调研）

- **文件转写 + `stream=true`（SSE）**：它只是把"一整段已完成音频"的结果分批吐出来，首字 1–2s，社区大量反馈 delta 与完成事件几乎同时到 → 对"说话中出字"没用。**已否**。
- **3 秒切片分别 POST 再拼接**：实时颗粒度只有 3 秒，且短片段没有上下文，边界容易丢词/幻觉。**已否**（v1/v2 计划走过这条路）。
- **第三方流式 STT**（Deepgram / AssemblyAI / 国内厂商）：真流式、部分单价更低，但要新增厂商适配层与账号；**自建**（sherpa-onnx 等）零单价但要加容器、模型与运维。当前选 LiteLLM 的 Realtime 是"用现成网关、不新增外部依赖"的折中。
- **浏览器直连 provider 的 WebRTC**：延迟更低，但要把网关暴露给浏览器、用 API key 换临时 token，我们的后端也就看不到会话、无法限额与审计。**已否**。

## 10. 已知取舍

- 前置（本仓库之外）那层 nginx **必须放行 `/ws/voice` 的 Upgrade**，否则功能不通；如果它是按路径白名单配的（例如只配了 `/ws/agent/`），需要补一条。
- 一次说话对应一次 WS 会话，没有跨会话复用；`maxSeconds` 到点由服务端与前端各自收尾。
- iOS Safari 会忽略 `AudioContext({sampleRate:24000})`，改用整数比降采样（`web/src/voice/pcm.ts` 的 `downsampleTo`），质量略降。
- 录音期间工具栏里的模式切换/附件/设置按钮只是 `hidden`（麦克风按钮要一直挂着，录音条与它同处一行）。
- **不为 provider 的私有事件方言留分支**：第一轮上线时网关返回的是 `conversation.item.input_audio_transcription.text`（`text` + `stash`）而不是标准 `delta`，那段时间浏览器在录音期间一个字节都收不到；用户随后在网关侧把实时语音**归一成了标准 OpenAI `delta`**，所以客户端只认 `delta`/`done`，不留兼容分支（方言代码在开发分支上写完即回滚）。
- 自动续接是新会话接旧会话，接缝处可能丢半秒音频；这是刻意的取舍（相比"整段丢失"）。
