# Agent Pet Runtime — 修正后架构与规格

> 本文档补全 `SPEC-REVIEW.md` 中识别出的规格空洞，并作为实现的唯一事实源。
> 凡本文档与原方案 `Agent_Pet_Runtime_v0.1.md` 冲突处，**以本文档为准**。

---

## 1. 修正后的架构

原方案的 Bridge 被画成"Agent 连过来的服务器"。实测（见 `SPEC-REVIEW.md` §2.1）Agent 的交付机制是**进程派生**，因此 Bridge 必须是两段式。

```
┌────────────────────────────────────────────────────────────────────┐
│ 外部 Agent 进程（不是我们启动的，在用户自己的终端里）                  │
│  ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌──────────┐              │
│  │Codex     │ │Claude    │ │Grok      │ │Pi        │              │
│  └────┬─────┘ └────┬─────┘ └────┬─────┘ └────┬─────┘              │
│       │notify      │hook        │hook        │TS extension        │
└───────┼────────────┼────────────┼────────────┼────────────────────┘
        │            │            │            │
        └────────────┴─────┬──────┴────────────┘
                           │  spawn(argv + stdin JSON)
                           ▼
              ┌────────────────────────────┐
              │  agentpet-hook (CLI shim)  │  ← 原方案缺失的一段
              │  无状态 · 不解析 · 永不阻塞  │
              │  采集 getppid()/TTY         │
              └─────────────┬──────────────┘
                            │  UDS 单向写 (fire-and-forget)
                            ▼
              ~/Library/Application Support/AgentPetRuntime/bridge.sock
                            │
┌───────────────────────────┼────────────────────────────────────────┐
│ AgentPetRuntime.app       ▼                                        │
│  ┌──────────────────────────────────┐                              │
│  │ BridgeServer                     │  接收 · 去重 · 限流 · 隔离     │
│  └──────────────┬───────────────────┘                              │
│                 ▼                                                   │
│  ┌──────────────────────────────────┐                              │
│  │ AgentRegistry → Adapter          │  agentID 路由                 │
│  │  └─ EventNormalizer              │  rawPayload → AgentEvent      │
│  └──────────────┬───────────────────┘                              │
│                 ▼                                                   │
│  ┌──────────────────────────────────┐                              │
│  │ ActivityEngine                   │  优先级 · 老化 · 保持 · 去重   │
│  └──────────────┬───────────────────┘                              │
│                 ▼                                                   │
│  ┌──────────────────────────────────┐                              │
│  │ AnimationResolver                │  AgentState → AnimationTrack  │
│  └──────────────┬───────────────────┘                              │
│                 ▼                                                   │
│  ┌──────────────────────────────────┐                              │
│  │ FrameScheduler → NSPanel         │                              │
│  └──────────────────────────────────┘                              │
└─────────────────────────────────────────────────────────────────────┘
```

**关键差异**：Agent 从不连接我们。它们 `fork/exec` 一个 shim，shim 主动写 socket。App 未运行时，shim 把事件**减字段后落盘**（spool），下次启动回放（§5.4）；在此之前这里是"静默丢弃"，代价是升级/重启后宠物对正在运行的会话一无所知。

---

## 2. 模块结构（修正 §16）

```
agent-pet-runtime/
├── Package.swift
├── Sources/
│   ├── AgentPetCore/                 # 纯逻辑，零 UI 依赖，100% 可测
│   │   ├── Domain/
│   │   │   ├── AgentState.swift
│   │   │   ├── AgentEvent.swift
│   │   │   ├── AgentActivity.swift
│   │   │   ├── AgentSession.swift
│   │   │   └── Confidence.swift
│   │   ├── Pet/
│   │   │   ├── PetManifest.swift      # 宽容解码
│   │   │   ├── PetDefinition.swift
│   │   │   ├── SpriteAtlas.swift
│   │   │   ├── AnimationTrack.swift
│   │   │   ├── CompatibilityProfile.swift
│   │   │   └── Validation/
│   │   │       ├── ManifestValidator.swift
│   │   │       ├── AtlasValidator.swift
│   │   │       ├── PathSafetyValidator.swift
│   │   │       └── PayloadValidator.swift
│   │   ├── Activity/
│   │   │   ├── ActivityEngine.swift
│   │   │   ├── PriorityModel.swift
│   │   │   └── ActivityClock.swift    # 可注入时钟，测试用
│   │   ├── Bridge/
│   │   │   ├── BridgeEnvelope.swift
│   │   │   └── EventDeduplicator.swift
│   │   └── Integration/
│   │       ├── ConfigTransaction.swift
│   │       └── IntegrationState.swift
│   ├── AgentPetApp/                   # AppKit + SwiftUI
│   └── agentpet-hook/                 # shim CLI
└── Tests/
    └── AgentPetCoreTests/
        └── Fixtures/                  # 真实 manifest / atlas 样本
```

`AgentPetCore` **不 import AppKit**。这是硬约束——保证 `swift test` 可以在无 GUI 环境下跑全部核心逻辑。

---

## 3. 动画轨道模型（依官方契约修正）

> 本节在拿到官方契约全文后**重写过**。此前基于猜测的版本有四处错误，见 §3.5。

契约来源（本机即有一份，随 ChatGPT.app 分发）：
`/Applications/ChatGPT.app/Contents/Resources/skills/skills/.curated/hatch-pet/references/`

- `codex-pet-contract.md`
- `animation-rows.md`

### 3.1 播放参数是逐帧毫秒，不是帧率

原方案只给了每行**帧数**，据此实现是错的。契约给出**每一帧的毫秒时长**，且**不均匀**：

| 行 | 帧时长 |
|---|---|
| 0 `idle` | **280, 110, 110, 140, 140, 320 ms** |
| 1 `running-right` | 120 ×7，末帧 220 |
| 2 `running-left` | 120 ×7，末帧 220 |
| 3 `waving` | 140 ×3，末帧 280 |
| 4 `jumping` | 140 ×4，末帧 280 |
| 5 `failed` | 140 ×7，末帧 240 |
| 6 `waiting` | 150 ×5，末帧 260 |
| 7 `running` | 120 ×5，末帧 220 |
| 8 `review` | 150 ×5，末帧 280 |
| 9–10 | 注视方向，见 §3.4 |

`idle` 首末帧是中间帧的 2–3 倍长——那是**呼吸**，不是匀速循环。用单一 fps 无法表达，近似会走形。

因此 `AnimationTrack` 持有 `frameDurations: [TimeInterval]`，**没有 fps 字段**。

### 3.1a Codex 的播放形状（2026-09-13 对齐，两处独立实现互证）

契约给的是**创作值**；Codex 播放时又叠了两个变换，本运行时现在照做：

1. **idle：Codex 的表是 6 倍慢速，本项目不跟。** App 端确实有 `ger = her.map(frameDurationMs * 6)`（TUI 的 `idle_animation` 同样是 1680/660/… 一档），但那个慢速版本在 Codex 里只是**状态播完后的沉降尾巴**——宠物的常态是"有任务"，idle 很少被看到。本项目的桌面宠物**大部分时间就处于 idle**：照搬 ×6 会让常驻呼吸变成 0.6fps，实测反馈"比其他状态慢、像卡住"（2026-09-13）。因此 idle 播放契约创作值 280/110/110/140/140/320，与其它状态同一节奏量级。
2. **一次性状态 = 整行播 3 遍，再落进 idle 段并从那里循环。** App：`uer` 返回 `frames: [...row, ...row, ...row, ...ger], loopStartIndex: 3 * row.length`；TUI：`app_state_animation` 同样是三遍 + `idle_animation().frames`，测试名就叫 `app_running_animation_repeats_then_settles_into_idle`。

本实现落在 `AnimationResolver` 第 3 层：`repeats > 1` 的轨道播完那几遍后交给 idle 轨（用剩余时长取帧），因此不需要"播完标记"。**但 `repeats = 1` 的轨道（running / waiting）是"持续状态"，整行一直循环**——这是对 Codex 组合的一个有意偏离，理由是实测：Codex 里 running/waiting 是*通知*，随状态更新不断重设，而本项目的状态可以持续几十分钟；照搬"三遍后沉降"会让宠物在 agent 明显还在干活时三秒就进入慢速呼吸，看起来像睡着了（用户实测反馈，2026-09-13）。"播三遍再沉降"保留给真正的一次性状态（completed → review、failed）。

**与 Codex 无法对齐的两处，均为有意保留**：拖动中的 locomotion 持续循环（Codex 的拖动是另一种状态机，且拖到一半改为发呆不合理）；`waving`/`jumping` 仍是本项目的手势层（点击问候），不套用三遍+沉降。

### 3.2 轨道分类与驱动源

| 类别 | 行 | 驱动源 |
|---|---|---|
| **State** | 0 `idle`, 5 `failed`, 6 `waiting`, 7 `running` | `AgentState` |
| **Gesture** | 3 `waving`, 4 `jumping` | 瞬时事件 / 用户点击 |
| **Locomotion** | 1 `running-right`, 2 `running-left` | **拖动方向** |
| **Look** | 9, 10（仅 V2） | **指针方位角** |

`review`（row 8）是 state 轨，但 v0.1 没有映射到它的 Agent 状态——Codex 的 review 模式尚未在 hook 中暴露。

### 3.3 状态 → 轨道映射表

契约只说明每行**是什么**，没有规定哪个状态选它。下表是本 runtime 对契约语义的解读，每条都注明依据：

| `AgentState` | row | 播放 | 依据 |
|---|---|---|---|
| `idle` | 0 | loop | "calm, low-distraction breathing/blinking loop" |
| `running` | 7 | loop | "active task work or processing, **not literal foot-running**" |
| `waitingInput` | 6 | loop | "expectant asking pose for approval, help, or user input" |
| `waitingApproval` | 6 | loop | 同上——atlas 只有一个 waiting 姿态 |
| `completed` | 8 `review` | 3 遍 → idle | Codex 自己的映射：回合完成时播 review（"focused inspection of completed output"）并发 "Ready" |
| `failed` | 5 | 3 遍 → idle | "readable error, sad, or deflated reaction"；3 遍之后落进 idle 就是"停止哭丧" |
| `paused` / `unknown` | 0 | loop | 无可展示信息 |

**`waving`（row 3）不由任何 AgentState 选择。** 契约说它是 "greeting or attention gesture"——那是对**用户**的反应，不是对 Agent 的。本 runtime 用它作为**点击宠物时的问候动作**。

`completed` 与 `failed` 走 §3.1a 的播放形状：整行三遍，然后落进 idle 段循环。**没有任何状态会冻结在最后一帧**，也不需要"once"特例——沉降本身就是停止表达。

**reduced motion**：系统要求 + 设置允许时，每一层都退化为所选中帧的第 0 帧（App 的 `uer(e, true)` 就是 `frames:[n[0]]`）。此前 `respectsReduceMotion` 只是个无人读取的设置项，现已接通。

### 3.4 注视方向（V2 row 9–10）——原方案标为 [未验证] 的问题

契约明确：

> Rows `9-10`: 16 clockwise look directions.
> Row `9`: `000`, `022.5`, `045`, `067.5`, `090`, `112.5`, `135`, `157.5` degrees.
> Row `10`: `180`, `202.5`, `225`, `247.5`, `270`, `292.5`, `315`, `337.5` degrees.
> `000` means up / 12 o'clock, not neutral/front.
> Neutral/front is the no-vector deadzone and falls back to idle.

**已用真实资产验证**：从本机 `some-v2-pet`（V2）导出 row 9–10 全部 16 帧，目视确认是连续顺时针的注视姿态——row 9 c0 仰视、c4 正右、row 10 c0 俯视、c7 回到左上。见 `--diagnose --export-frames`。

实现：

```
sector = floor(((angle + 11.25) mod 360) / 22.5) mod 16
row    = sector < 8 ? 9 : 10
column = sector mod 8
```

半扇区偏移让每个姿态落在扇区中心，指针在 45° 附近抖动时不会来回跳两个姿态。

"Neutral/front 是 deadzone" 的含义是：**没有方向向量时无法确定角度**，回落到 idle。本实现取指针到宠物中心距离小于 28pt 为 deadzone。

### 3.5 此前版本的四处错误

| # | 曾经的写法 | 实际 |
|---|---|---|
| 1 | 每行一个 fps（8/12/10…） | 逐帧毫秒，且首末帧显著更长 |
| 2 | V2 row 9–10 = "reserved，不播放" | 16 个注视姿态，全部使用 |
| 3 | `completed` → `waving` | → `jumping`；`waving` 是点击问候 |
| 4 | `running-right/left` = "v0.2 由拖动驱动" | v0.1 就由拖动方向驱动 |
| 5 | V2 "部分兼容"，发 warning | V2 完全支持；V1 才是"中间产物" |

契约原文甚至更强硬：

> The 8x9 `1536x1872` atlas is an intermediate assembly artifact only. Never package it as a newly hatched pet.

即 **V2 才是主格式，V1 是遗留**。本 runtime 两者都支持，但 V1 不再被当作基线。

### 3.6 播放层级

`AnimationResolver` 按此顺序决定画面，**先命中者胜**：

```
1. 拖动中        → running-left / running-right   （用户手上拿着它）
2. 手势播放中    → waving / jumping               （one-shot，播完下沉）
3. Agent 状态    → 见 §3.3                        （inactive 状态跳过）
4. 注视方向      → row 9/10                       （仅 V2，仅在有角度时）
5. idle
```

两条容易写错的规则：

- **inactive 状态必须跳过而不是返回**。`idle` 是兜底，不是"有话说"的状态。若在第 3 层就返回 idle 轨道，决策提前结束，注视永远轮不到——宠物会永远直视前方。
- **one-shot 播完必须下沉**。只对 `failed` 下沉、对 `completed` 不下沉，会让庆祝动作永久冻结（这个 bug 在实现时真实出现过，被测试抓住）。

拖动的方向判定：横向位移取符号；**竖向拖动保持原方向**——atlas 没有"向上走"的行，光标一抖就翻转会像故障。

---

## 4. Activity Engine 数值规格（补齐 §11.1）

原方案列出了机制名但没有一个数值。以下是 v0.1 的完整规格，**全部通过 `ActivityClock` 注入时间，因此可确定性测试**。

### 4.1 优先级类

```swift
enum PriorityClass: Int, Comparable {
    case attention = 0   // 用户被阻塞，最高
    case failure   = 1
    case active    = 2
    case settled   = 3
    case inactive  = 4
}
```

| `AgentState` | Class | 说明 |
|---|---|---|
| `waitingInput` | `.attention` | 回合结束，轮到用户 |
| `waitingApproval` | `.attention` | 权限提示，通常短暂 |
| `failed` | `.failure` | |
| `running` | `.active` | |
| `completed` | `.settled` | |
| `idle` / `unknown` / `paused` | `.inactive` | |

同类内 tie-break（按顺序比较，先满足者胜）：

1. `waitingInput` 优先于 `waitingApproval`（前者是"该你了"，后者常被自动批准）
2. `enteredStateAt` 更早者胜（先来先服务）
3. `agentID` 字典序（保证完全确定性，避免测试 flaky）

### 4.2 老化（aging）

```
agingThreshold = 90s         // 在非 attention 类中停留超过此值
promotionStep  = 1 class     // 提升一级
maxPromotions  = 2           // 最多提升 2 级
```

目的：一个 10 分钟前 `failed` 的会话，不应该被一个刚刚开始的 `running` 压过去。
`attention` 类不参与老化（已在最高级）。

> **注意**：老化**不能提升到 `.attention` 之上**，也不改变 `attention` 内部顺序。

### 4.3 焦点保持（focus hold）

```
focusHold      = 3.0s   // 绝对保底：刚获得焦点的活动 3s 内不可被抢占
urgentOverride = 1.0s   // 例外：抢占者 ∈ .attention 且当前 ∈ {.settled,.inactive}
```

`urgentOverride` 的存在是为了让"用户被阻塞"能立刻打断"完成动画"或"空闲"，同时不打断正在 `running` 的展示（避免闪烁）。

### 4.4 完成停留（completion dwell）

```
completionDwell = 4.0s   // completed 状态至少展示 4s 才可让位给更低优先级
```

避免「任务完成 → 立刻跳回 idle」的突兀感。

### 4.5 静默超时（stale TTL）

事件流可能中断（Agent 崩溃、终端被杀）。每个状态的静默容忍度不同：

| 当前状态 | 静默阈值 | 超时后转为 |
|---|---|---|
| `running` | **5min** | `unknown` |
| `unknown` | 60s | `idle` |
| `waitingInput` | 不超时 | — （用户可能离开很久） |
| `waitingApproval` | 5min | `unknown` |
| `completed` | `completionDwell` | `idle` |
| `failed` | 10min | `idle` |
| `idle` | — | — |

**`running` 为什么是 5 分钟而不是 30 秒（2026-09-14 修正）**：hook 只在工具调用前后触发，而**单次** Bash 工具可以跑 2 分钟（默认超时上限 10 分钟）、子 Agent 可以跑更久，中间一个事件都没有。30 秒的阈值意味着宠物在 Agent 明明还在干活时放弃动画——这是"宠物不准"的直接来源。代价：会话在回合中被杀（终端被关且没有 `SessionEnd`）时，会以 `running` 多演 5 分钟才沉降。两害相权取其轻。

### 4.6 Session 去重

```
dedupeKey = (agentID, sessionID)
```

- 同一 key 同时最多存在一个 `AgentActivity`。
- 新事件到达时**原地更新**，不新建。
- 若 `state` 未变：保留 `enteredStateAt`（不打断老化计时与保持窗口）。
- 若 `state` 改变：重置 `enteredStateAt`。
- 事件乱序（`updatedAt` 早于当前）时**丢弃**，不产生状态回退。

### 4.7 多 Pet 模式（保持方案 §11.2 不变）

Multi Pet 不做全局抢占，按 `agentID` 静态绑定：

```
Pet A ← agentID X 的所有 activity
Pet B ← agentID Y 的所有 activity
```

只共享 ActivityEngine 的状态源，不共享焦点。绑定的 agentID 相同时回退到单 Pet 抢占规则。

---

## 5. Bridge Wire Protocol（补齐 §6.5）

### 5.1 信封格式

shim 投递的是**带版本的信封**，不是已解析的事件：

```json
{
  "v": 1,
  "shimVersion": "0.1.0",
  "agentID": "claude-code",
  "eventName": "PreToolUse",
  "receivedAt": "2026-09-12T01:23:45.678Z",
  "proc": {
    "ppid": 48213,
    "pid": 48214,
    "tty": "/dev/ttys004"
  },
  "rawPayload": "eyJzZXNzaW9uX2lkIjoiYWJjIiwi..."   // base64(原始 stdin 字节)
}
```

设计要点：

| 字段 | 理由 |
|---|---|
| `v` | 协议版本。未知版本 → 丢弃并记一条诊断，**不崩溃** |
| `agentID` / `eventName` | 由 argv 写死，不依赖 payload 解析 |
| `proc` | **shim 的 `getppid()` 就是 Agent 进程**。这是唯一免费可靠的进程关联方式 |
| `rawPayload` | base64 原始字节。**App 侧才解析**，解析失败被隔离在单个 Adapter 内 |

`rawPayload` 用 base64 而非嵌套 JSON 的原因：Agent 的 payload 可能不是合法 JSON（有些 hook 传纯文本），嵌套会导致整个信封解码失败。

### 5.1a 实测延迟（2026-09-12，arm64 / macOS 15.7.9）

shim 位于 Agent 的关键路径上，因此这些数字是**决定方案是否可行**的指标，而不是参考值。

| 场景 | P50 | P95 | P99 | max |
|---|---|---|---|---|
| **Runtime 运行中**（正常路径） | **4.33 ms** | 6.27 ms | 6.59 ms | 6.90 ms |
| Runtime 未运行（connect 失败） | 3.81 ms | 5.62 ms | 6.51 ms | 6.53 ms |

预算 P50 < 5ms / P99 < 25ms，**通过**。n=500 时无任何样本超过 8ms。

语言选择依据（最小可执行文件冷启动实测）：

| 实现 | 启动 |
|---|---|
| C | 2.23 ms |
| Swift（仅 Darwin） | 2.56 ms |
| **Swift + Foundation（采用）** | **3.72 ms** |

选 Foundation 而非裸 Darwin：JSON 信封可以用 `nc -U` 直接调试，而换来的 1.2ms 在 5ms 预算内可以承受。

> **注意**：首次调用实测出现过一次 58ms 离群值，发生在 App 刚启动、正在加载并解码 Pet 的瞬间。稳定后（n=500）最大值降到 6.90ms。如果后续观察到周期性尖刺，应检查 App 主线程是否有阻塞工作。

### 5.1b Claude Code 事件映射（依实测修正）

原始映射是**猜的**，且是用户报告 "多个 Claude 运行时宠物卡在等待输入" 的根因。

实测依据：
- 从本机 `claude` 二进制（2.1.268）提取的**完整事件列表**
- 实际 hook payload 抓包（`--log-events`，用自己的会话当样本）
- 同机 `Otty.app` 的成熟实现作交叉验证
  （`/Applications/Otty.app/Contents/Resources/agent-integration/`）

当前 build 派发 **15 个事件**：

```
SessionStart  SessionEnd  UserPromptSubmit
PreToolUse    PostToolUse  PreCompact      PostCompact
PermissionRequest  Notification  Stop  StopFailure
SubagentStart  SubagentStop  TaskCompleted  TeammateIdle
```

修正内容：

| 事件 | 原映射（错） | 现映射 | 依据 |
|---|---|---|---|
| `Notification` | `waitingInput`（**永不过期**） | 仅 `permission_prompt` → `waitingApproval`；其余**不改变状态** | `notification_type` 有 4 种取值：`permission_prompt` `idle_prompt` `auth_success` `elicitation_dialog`。把提醒当"等待输入"会让宠物永久卡住 |
| `PermissionRequest` | 未安装 | `waitingApproval` | 这是**唯一**真正的"被阻塞"信号 |
| `StopFailure` | 未安装 | `failed` | 否则失败和成功无法区分 |
| `Stop` | `completed` | `completed`，但**4 秒后沉降为 idle**，且后台任务运行时降级为 `working` | `Stop` 每回合都触发，不是会话结束 |
| `TaskCompleted` | 未安装 | `completed` | 这才是"任务真的做完了" |
| `SubagentStart` | 未安装 | `working` | 主 Agent 继续跑 |
| `completed` 状态 | 永不超时 | 4 秒后 → `idle` | 否则每个回过的会话都永远显示"已完成" |

**根因说明**：`Notification` 是**杂类事件**，`idle_prompt` 只是"Agent 静了一会儿"的提醒。
把它映射到永不超时的 `waitingInput`，导致只要开过两个会话，宠物就永久显示"等待输入"。
现在唯一会保持的注意状态是 `waitingApproval`——因为那是 Agent **真的无法继续**。

**`Stop` 的后台任务抑制**：`Stop` 在主 Agent 让出控制权时就触发，而后台子 Agent 可能还在跑。
payload 里的 `background_tasks` 若含 `status: running`，说明任务未完成，映射降级为 `working`。
（此技巧来自 Otty 的实现注释，已在本机二进制中确认 `background_tasks` 字段存在。）

**Grok 冲突**：Grok Build 会扫描并信任 `~/.claude/settings.json`，
因此安装在其中的 Claude hook **也会在 Grok 事件上执行**。
shim 现检测 `GROK_HOOK_NAME` 环境变量（Grok 的 hook runner 注入，Claude Code 自身不设）
并把 agentID 改判为 `grok`。

### 5.1c Hook 配置热加载 —— 实测结论

**Claude Code 每次派发 hook 时重新读取 `~/.claude/settings.json`，不是启动时读一次。**

实测方法：`SubagentStart` / `SubagentStop` 原先**不在这套 hook 配置里**，
是在一个已运行数小时的会话存活期间通过 `--configure` 新增的。
新增后 spawn 一个子 agent，两个事件**在同一进程（ppid 未变）中正常触发**。

**产品含义**：配置完不需要重启 Agent——正在跑的任务不会被中断。

**一个需要注意的边界**：hook 是热加载的，但**已发生的状态不会追溯**。
引擎里残留的旧状态会一直挂着直到该 session 发出下一个事件。
UI 因此需要一个显式的 `Clear Activities` 动作。

### 5.2 Session 关联策略

**hook payload 不含终端窗口标识**（见 `SPEC-REVIEW.md` §3.3）。v0.1 的关联顺序：

```
1. payload.session_id        ← 最可靠，若 Agent 提供
2. proc.ppid                 ← shim 采集的 Agent PID
3. (agentID, cwd)            ← 最弱，同目录多会话会冲突
```

`FocusTarget` 只承诺 `open(cwd)`。Accessibility 窗口聚焦推迟到 v0.2。

### 5.3 去重

```swift
dedupeKey = hash(agentID, eventName, sessionID, payloadEventID)
```

`payloadEventID` 从 payload 中尽力提取（如 `tool_use_id`、`call_id`）。提取不到时退化为：

```
同 (agentID, sessionID, eventName) 在 500ms 内只接受第一条
```

### 5.4 未送达事件（spool）——2026-09-14 新增

**问题**：`quit` 后重启、或 `brew upgrade --cask`（先 TERM 掉旧 App 再替换 bundle）期间，hook 照常触发但 socket 不存在，事件被丢弃。结果是宠物重启后对"几秒前还在回合中的会话"一无所知，要等那个会话的下一个 hook 才知道——长工具调用是几分钟之后，多会话时更是只有一部分会陆续报到。用户报告为"重启/升级后无法准确获取 agent 状态，activity 只能抓到部分 session"。

**方案**：shim 投递失败时把事件写进 spool，App 启动时回放。

| 属性 | 取值 | 理由 |
|---|---|---|
| 位置 | `~/Library/Application Support/AgentPetRuntime/pending-events/` | 与 socket 同目录，测试可用 `AGENTPET_SPOOL` 覆盖 |
| 内容 | `EventCapture.sanitizedPayload` 减字段后的信封 | **落盘 = 必须过日志同一条白名单**：session_id、cwd、tool_name、notification_type 等；prompt、tool_input/response、last_assistant_message 一律不写 |
| 权限 | 文件 0600、目录 0700 | 与事件日志同一标准（不用 `Data.write(.atomic)`：原子写会先建临时文件，权限是 umask 而不是我们的） |
| 上限 | 200 条，超出删最旧 | 文件名前缀是 16 位零填充毫秒时间戳（**不能用 `%016d`**：该格式读 32 位参数，毫秒时间戳会被截断成负数，排序反转、剪枝删掉最新的） |
| 回放 | 启动时 drain，按 `receivedAt` 升序 | 与实时事件走同一条 `BridgeCoordinator.deliver`，因此计数、`--log-events`、归一化行为完全一致；读完即删 |
| 语义 | 回放事件保留**原始时间戳** | 引擎的静默超时按事件自身年龄计算：一小时前的 `working` 回放出来会立刻过期，而不是把宠物点亮 |

回放与实时事件在时间上可能交错：同一个 session 若实时事件先到，旧的回放事件会被引擎乱序保护丢弃（§4.6）——结局仍然是最新状态胜出。

---

## 6. Pet 来源与生命周期（2026-09-13 修正）

### 6.1 唯一的来源：Codex 自己的 pet 目录

```
$CODEX_HOME/                      # 未设置 CODEX_HOME 时即 ~/.codex/
├── pets/<folder>/                # 目录名不必等于 id；manifest 的 id 才是主键
│   ├── pet.json
│   └── spritesheet.webp          # 文件名由 spritesheetPath 指定，缺省即此
└── avatars/<folder>/             # 旧位置，Codex 仍在读
    ├── avatar.json               # 同一格式；id/displayName 可缺省，回退见下
    └── spritesheet.webp
```

运行时**只读**这两个目录，任何情况下都不写入。`CODEX_HOME` 是**替换**而不是追加（与 `codex-pets` CLI、hatch-pet skill 一致）；两个都搜会列出终端 Codex 根本加载不了的 pet。`pets/` 后扫，因此两边同名时以 `pets/` 的包为准——与 Codex 的 picker 一致（它也是先 `avatars` 后 `pets` 覆盖同名条目）。

清单字段的回退照抄 Codex 的 loader（`codex-rs/tui/src/pets/model.rs`）：`id` 缺省取目录名（旧 `avatar.json` 就是这么写的），`displayName` 缺省取 id，`spritesheetPath` 缺省 `spritesheet.webp`。目录名当 id 时仍须通过本项目的 id 校验——`Clippy/` 这样的大写目录若无显式 id 会被跳过，而不是被悄悄改名：本项目存进 config 的每个 id 都要能原样匹配回来。

增 / 改 / 删都不由本项目做：

| 操作 | 标准做法 |
|---|---|
| 安装 | `npx codex-pets add <pet-id>`（codex-pets.net；整包用 `add-collection <slug>`） |
| 更新 | 再跑一次 `add`：它直接覆盖 `pet.json` 与 `spritesheet.webp`（实测 codex-pets@0.3.0 的 installer 就是 `mkdir -p` + `writeFile`） |
| 移除 | 删除 `$CODEX_HOME/pets/<folder>/`。生态里没有 remove 命令；Codex TUI 只有 "Disable terminal pets"（不加载，也不删除） |
| 其他来源 | 手动解压、hatch-pet skill 生成后直接写入——只要目录里有合法 `pet.json` + spritesheet 即可 |

实测 codex-cli 0.153.4 没有任何 pet 子命令，TUI 只有交互式 picker；`codex-pets` CLI 只有 `add` 与 `add-collection`。所以"移除"在标准生态里**就是删目录**，本项目不为此发明第二套语义。

### 6.2 本项目只写一样东西：用户选了哪只

`config.json` 的 `pet.defaultPetID`（`~/Library/Application Support/AgentPetRuntime/config.json`）。启动时按 id 在上面那个目录里解析；解析不到（pet 被删除）则回退第一只，不报错、也不清除旧值——重新装回来即恢复原选择。`--pet <id>` 是仅本次运行的覆盖，不写回。

这是 app 与 pet 唯一的状态关系：**不复制、不注册、不记哈希**。

### 6.3 为什么删掉运行时的自有存储（2026-09-13 反转）

v0.1 实现过一份自有存储（`Application Support/AgentPetRuntime/pets/`，带 provenance metadata、staging 安装事务、Import / Upgrade / Uninstall）。**已整体删除。** 理由：

- **两套列表必然漂移**：用户用 Codex 的标准工具装了一只 pet，本 app 要等一次 Import 才看得到；两个"已安装"列表给出不同答案，是设计缺陷。
- **来源不可复制**：Import 把 `~/.codex/pets/<id>` 复制一份，Codex 侧一更新副本就过期，同一只 pet 出现两个内容哈希。
- **选择入口在 Codex**：终端里跑哪只由 Codex 的 picker 决定，桌面这只由本 app 决定；但"有没有这只 pet"两边读同一份目录，才不会出现两个答案。
- 删除的代价只是一套安装事务、一份元数据格式和 20 个测试。加载与校验（§7）不变——非法包与 Codex 一样被跳过，不做兜底。

`docs/SPEC-REVIEW.md` §2.5 / §3.5 保留了当时的 store 结论，已在该文标注反转。

### 6.4 宠物旁的提示元素（2026-09-13 移植自 Codex）

Codex 的 ambient pet 带一个 notification：四种状态、一行标签、可选第二行正文。TUI 的 PR #21206 自己写明 "The ambient text overlay is currently disabled" —— 数据模型与触发逻辑是完整的，绘制被暂时关掉（所以 TUI 的测试断言标签**不**出现在终端缓冲里）；Codex App 里这个元素是可见的。本运行时把模型完整移植过来，并自己绘制。

| kind | 标签 | 回退正文 | 生命周期 | 触发（Codex → 本项目） |
|---|---|---|---|---|
| running | Running | Thinking | 3 分钟 | 回合开始 → `.running` |
| waiting | Needs input | Needs input | 24 小时 | 审批 / elicitation → `.waitingApproval`、`.waitingInput` |
| review | Ready | Ready | 7 天 | 回合完成（Codex 的正文 = 助手消息预览） → `.completed` |
| failed | Blocked | Blocked | 1 小时 | 出错 → `.failed` |

- **正文 == 标签 → 只画一行，否则两行**：Codex 用同样的字符串比较决定终端里占一行还是两行（`notification_height`）。running 的回退正文是 "Thinking"，所以它总是两行。
- **生命周期从设置时刻起算，状态不变就不重新计时**：渲染循环 60fps，若每帧重打时间戳，一条消息会被无限续命。过期即不再显示，直到状态再次变化。
- **正文来源**（2026-09-13 修订）：`review` 填助手消息预览——Claude Code 的 `Stop` 自带 `last_assistant_message`（该字段存在的目的就是让 hook 不必去读 transcript），归一化时按 Codex 的 `agent_turn_preview` 处理：折叠空白、截到 200 个字符（按 grapheme 截，emoji 不会被劈开）。`waiting`/`failed` 填工具名 / 错误文本。`running` 仍然不填：那里的 `summary` 是用户 prompt，把用户输入摆到悬浮窗上不是本项目的取舍。
- **预览只进内存，绝不落盘**：`last_assistant_message` 不在事件日志白名单里（`EventCapture.capturableKeys`），测试断言它既不在名单、也不会出现在记录中。抓包里它只以 `_omitted_keys` 的名字出现。
- **画在精灵上方，窗口向上生长、原点不动**：等价于 Codex 在精灵上方预留终端行，而不是盖在 transcript 上。窗口高度 = 默认 156pt + 31pt（一行）或 46pt（两行）；`hitTest` 只认精灵区域，点提示文字不会拖动宠物。
- **与动画的关系**：Codex 用 notification 同时驱动动画（running/waiting/review/failed 行）；本项目的动画已由 Activity Engine 的状态表驱动，提示元素只补文字与生命周期，不再重复驱动动画。

### 6.5 会话面板（2026-09-14）

单一提示元素被推广成**每个会话一行**的面板：同一 agent 的会话相邻，组与组之间按各自最优会话的排名排序（即 §4.1 的优先级），组内同样按排名——需要用户的会话永远在最上面，与宠物动画的焦点一致（`ActivityEngine.rankedActivities()` 就是 `currentFocus` 用的那个排序）。

| 项 | 内容 | 数据来源 |
|---|---|---|
| `agent` | 显示名 | `AgentProfiles.displayName` |
| `session` | session id **后六位** | `AgentActivity.sessionID` |
| `task` | 会话名 > 仓库名 > 目录名 | 状态栏 tap（名字/仓库）或 `focusTarget`（cwd） |
| `model` | 模型显示名，有 effort 时拼 `· level` | 状态栏 tap |
| `tool` | 当前工具，**仅 `running` 时显示** | 规则的 `toolNameField`（**不是** `summary`） |
| `context` | 百分比 + 荧光绿横条（#39FF14） | 状态栏 tap；无 tap 则该项不画 |
| `cost` | 会话估计花费 `$x.xx` | 状态栏 tap |
| `limits` | `5h 41% · 7d 13%` | 状态栏 tap |
| `message` | §6.4 的标签（+ 正文） | 每个会话自己的状态 |

**字号、宽度、对齐（2026-09-14 追加）**：行高 18pt，agent 11.5pt semibold、其余 10.5pt、session 用等宽；面板宽度 = 宠物宽度的百分比（设置里 100–200%，滑杆 + 数值框 + 加减按钮，默认 200%），文字可宽于宠物本体；对齐可选左/中/右——**对齐只动行内文字，不动宠物**（窗口始终以精灵为轴左右对称生长）。

规则与理由：

- **"当前工具"只来自 `toolNameField`，绝不取 `title`**：`summary` 可能是用户 prompt（`UserPromptSubmit` 的 summaryField 正是 `prompt`），而面板悬浮在所有窗口之上。为此 `AgentActivity.toolName` 是独立字段，只由声明了 `toolNameField: "tool_name"` 的规则填充。
- **完成/失败的行显示正文，running 的行不显示**——与 §6.4 同一条取舍。
- **idle 行有寿命**：终端被关掉时不会有 `SessionEnd`，一行"闲置会话"如果常驻，就会在宠物旁边飘一辈子。闲置行（`state == .idle`）在 `max(updatedAt, context.capturedAt)` 之后 10 分钟消失；状态栏还在报数的会话因此一直可见（它确实还活着）。
- **`alwaysVisible=false`** 时，面板仅在存在非 idle 会话时出现；出现后显示全部行。
- **窗口横向也要长**：面板最宽 520pt（超出则截断文本），窗口以精灵为轴左右对称加宽，底边不动——这样宠物在屏幕上纹丝不动。位置持久化存的是**还原到默认宽度时的原点**，否则宽面板一次、窄面板一次地退出会把宠物一步步挪走。
- **配置**（`AppConfig.messagePanel`）：`alwaysVisible` + 有序 `items`（开关与顺序即数组顺序）+ `widthPercent` + `alignment`。两处逐字段 `decodeIfPresent`：`AppConfig` 与 `MessagePanelConfig` 各自实现——合成解码会让"旧版本写下的配置文件缺新键"变成整份配置解码失败，而 store 拒绝半读，结果就是用户的所有设置被静默重置。**新增 item kind 时不需要迁移**：解码时把 items 里不存在的 kind 追加到末尾（管理器只能开关、不能删除条目，所以"缺失"只可能意味着"旧文件"）。
- **重建时机**：每次事件 + 至多每秒一次（状态机会按时钟老化，只在事件时重建会错过它）。管理器不参与：[`MainWindow` 的 1s ticker] 只刷管理器的副本，宠物自己走这条路径。
- **诊断行与画面同源**：`--verbose` 的 `[pet] panel:` 行用与绘制相同的 `MessagePanelLayout.items(for:config:)` 构造，不会打印用户已关掉的项。

### 6.6 状态栏 tap：上下文用量的唯一来源（2026-09-14）

hook payload **不含**任何 token 计数——在 2.1.268 的二进制里逐字段确认过：`used_percentage` / `context_window` 只出现在**状态栏** JSON 的 schema 中（`context_window.used_percentage`、`context_window_size`、`total_input_tokens`、`session_name`、`workspace.repo.name`）。这个数字只有 Claude Code 自己算得对：上下文窗口大小取决于模型，而网关背后的模型名外部无从得知（本机实测同一条会话已占用 302k token）。

因此 tap 的做法是**包住用户已有的状态栏命令**，而不是替换它：

```
statusLine.command = "<shim>" --agent claude-code --statusline --original <base64(原命令)>
```

- shim 依次做两件事：把 stdin 的 JSON **减字段**（`session_id` / `session_name` / `used_percentage` / `window` / `tokens` / `repo 或 project 目录名`，与原命令无关的 transcript_path、cost、rate_limits 全部丢弃），投递到 bridge；然后 `bash -c` 运行原命令，**stdin 原样传入、stdout/stderr 原样透传、退出码原样返回**。Claude Code 看到的仍是它原来的状态栏。
- **永不 spool**：状态栏每次渲染都会被调用，spool 会被同一事实的副本淹没。投递失败即丢弃。
- **协议**：`Statusline` 事件 → 规则 kind `.contextUpdate` → `AgentEvent.context`。引擎里它走独立路径：**不改状态、不刷新 `updatedAt`、不参与超时**——状态栏在提示符处也在渲染，若算作"活着"，用户中断的回合会永远显示 running。它同时是"这个会话存在"的证据：对未知会话会创建一条 `idle` 活动（这就是重启后面板能立刻列全开会话的原因）。
- **敏感度**：`session_name` 是用户自己起的名字（`/rename`），显示在用户自己的屏幕上，但不进任何日志（不在 `EventCapture.capturableKeys`，也不在 shim 的归约之外）。
- **事务与可撤销**：走与 hook 相同的 `ConfigTransaction`；`entriesPresent` 检查"现在文件里的命令是否仍是我们写的那条"；若用户后来自己改了状态栏则显示 drifted，卸载时**不动别人的东西**。记录里 `statusLine.original` 保存原命令用于还原；没有原命令时卸载会把 `statusLine` 键整个删掉（不留空壳）。
- **幂等与去嵌套**：重装时先解包——识别依据是 `--original` 的 base64 内容而不是 shim 路径，所以 app 换位置后重装得到的是"包住原命令的新 wrapper"，而不是"wrapper 套 wrapper"。
- **自毁保护（2026-09-14）**：wrapper 是 `if [ -x <shim> ]; then …; else <原命令>; fi`。用户 `brew uninstall` 把 app（连同 shim）删掉时，状态栏自动退回他们自己的命令——否则他们的提示符会试图执行一个不存在的路径。fallback 单独成行而不是跟在 `;` 后面：原命令以 `#` 注释结尾时会把后面的东西一起吞掉。
- **字段范围（对齐官方文档）**：tap 之后 `SessionContext` 覆盖 `context_window.used_percentage/context_window_size/total_input_tokens`、`model.display_name`、`effort.level`、`cost.total_cost_usd`、`rate_limits.five_hour/seven_day.used_percentage`、`session_name`、`workspace.repo.name/project_dir`。**不取**：`transcript_path`（绝不）、`prompt_id`、`cost` 的时长/行数、`rate_limits.*.resets_at`、`prompt_cache.*`、`workspace.added_dirs/git_worktree/host/owner`、`exceeds_200k_tokens`、`thinking`、`fast_mode`、`output_style`、`version`。`session_name` 可能是 AI 生成的会话标题（模型输出）——与助手预览同一决策：只进内存、上屏，不落盘。
- **成本（实测 2026-09-14，release，arm64）**：裸命令 `sh -c` 6.21ms/次；经 wrapper（shim + bash + 管道）8.19ms/次，即 **tap 只加约 2ms**（hook 事件本身约 7.3ms，同量级）。Claude Code 每次渲染都会调用、300ms 去抖；这个数字必须守住。**注意**：`Foundation.Process` 在本机每次 spawn 要 ~65ms（同一命令 `posix_spawn` 2.15ms / `Process` 66.78ms）——最初版本用 Process 直接给状态栏加了 68ms，已改为 `posix_spawn` + 管道。谁再改这里，先跑基准。
- **生效时机**：Claude Code 会热重载设置——文档原话 "reloads settings automatically and runs your script as soon as you save the file"，改 `command` 会立即用新命令重跑一次。因此 enable/disable 不需要重启会话。

### 6.7 其他 agent 的状态行能力（2026-09-14 调研，逐本机二进制取证）

面板里 tap 才能提供的项（model/context/cost/limits）在各 agent 上的可得性，按本机安装的具体版本来确认，不靠文档转述：

| Agent | 版本 | 机制 | 结论 |
|---|---|---|---|
| Claude Code | 2.1.268 | `statusLine.command`，stdin 传 JSON（§6.6） | **已实现**：tap 直接读取 |
| Grok Build | 1.0.24 | `[ui.status_line]`，`type = "command"` 时**同一套 JSON 契约**（二进制内置示例：`echo '{"session_id":"t",...,"context_window":{"used_percentage":25}}' \| ./statusline.sh`），300ms 去抖、启动时读取 `config.toml` | **可对接但未接线**：契约与我们 shim 的 `--statusline` 完全一致（`--agent grok` 即可），但安装需要安全地改写 TOML（`ConfigTransaction` 只懂 JSON），且该用户当前 `[ui.status_line]` 未启用（`type="builtin"` 项无法"包裹"，只能替换）。留待需要时做 |
| Codex | codex-cli 0.153.4 | `tui.status_line = [...]` 只有**内置项**（`context-used` 等，无自定义命令）；`notify` hook 的 payload 不含任何 token 数据 | **不可得**：唯一的替代是读 rollout/transcript，本项目不读 |
| Pi | @earendil-works/pi-coding-agent | 扩展 API 暴露 `ctx.getContextUsage()`、`ctx.sessionManager.getEntries()`（token 统计）、`ctx.model`（类型定义原文："Context usage on ctx.getContextUsage(), token stats on ctx.sessionManager.getEntries(), model info on ctx.model"） | **可得但要写扩展**：需要一个 Pi 扩展把 `getContextUsage()` 通过 shim（`--agent pi`）转发给 bridge；未实现 |

三者共同的**不做**：不读 transcript、不读 rollout 文件、不猜窗口大小——这正是 Claude Code 的 `used_percentage` 值得专门包一层的原因（网关模型窗口只有它知道）。

---

## 7. 校验规格（补齐 §8.4 "Validate atlas"）

### 7.1 校验顺序（短路，前面失败不执行后面）

```
1. ManifestValidator
   ├─ JSON 可解析
   ├─ 必需字段存在: id, displayName, spritesheetPath
   │   (description 缺失时用 displayName 兜底，不报错)
   ├─ id 非空、匹配 ^[a-z0-9][a-z0-9._-]{0,63}$
   └─ 未知字段 → 忽略（不报错）

2. PathSafetyValidator
   ├─ spritesheetPath 规范化后仍在 package root 内
   ├─ 无符号链接逃逸（对每一段路径段做 lstat）
   └─ 无绝对路径

3. PayloadValidator
   ├─ 白名单: .json .webp .png .jpg .jpeg .gif .txt .md
   ├─ 黑名单: .sh .command .app .dylib .so .scpt .workflow
   ├─ 任何带可执行位 (mode & 0o111) 的文件 → 拒绝
   └─ 忽略: .DS_Store, .* 前缀, run/, .agentpet/

4. AtlasValidator
   ├─ 可解码
   ├─ 尺寸 == profile 期望 (V1 1536x1872 / V2 1536x2288)
   ├─ 存在 alpha 通道
   ├─ 每行前 N 帧非空 (N = contract 帧数)
   └─ 每行第 N 帧起完全透明
```

### 7.2 未使用单元格必须透明的原因

这是官方 validator 的硬要求，也是最容易出的问题。若未使用单元格残留像素，播放器在切换到短行（如 `waving` 只有 4 帧）时会画出第 5、6 帧的残影。**必须在安装时拦截，运行时不做防御。**

### 7.3 性能约束

`1536 × 1872` 解码后约 11 MB RGBA。校验必须**逐行采样 + 分块解码**，不整张载入后再遍历。§20 的 "Pet Manager 安装/预览过程不阻塞主 Pet Renderer" 隐含此要求。

### 7.4 降级兼容（修正 §9.4）

| 情况 | 行为 |
|---|---|
| V1 尺寸 + 无 `spriteVersionNumber` | 完整兼容 |
| V2 尺寸 + `spriteVersionNumber: 2` | **加载并播放 row 0–8**，row 9–10 标记 experimental 不播放，UI 显示"部分兼容" |
| 尺寸不匹配任何 profile | 拒绝，显示实际尺寸与期望尺寸 |
| V2 尺寸但 `spriteVersionNumber` 缺失 | 按尺寸推断为 V2，走上一行逻辑 |

**V2 不得被拒绝**——用户本机已有 V2 资产（`~/.codex/pets/some-v2-pet/`）。

---

## 8. 集成配置事务（补齐 §5.4 / §7.3）

### 8.1 协议

```swift
protocol ConfigTransaction {
    func snapshot() async throws -> ConfigSnapshot
    func apply(_ edits: [ConfigEdit], snapshot: ConfigSnapshot) async throws
    func validate() async throws -> ValidationResult
    func rollback(to snapshot: ConfigSnapshot) async throws
    func commit() async throws
}
```

### 8.2 执行序列

```
1. snapshot()
   ├─ 读原文件字节 → 存 backups/<agent>/<ts>/
   └─ 记录 (mtime, size, sha256)

2. apply()
   ├─ 在内存中构造完整结果（不增量改写）
   ├─ 写 <file>.agentpet-tmp
   └─ rename(tmp, file)          ← 原子

3. validate()
   └─ 重新解析文件，确认我们写的条目存在且格式合法

4. commit()  |  rollback(to:)
   ├─ commit   → 删除 .agentpet-tmp，保留 backup
   └─ rollback → rename(backup, file)
```

### 8.3 并发修改检测

Agent 自己会写配置（Claude Code 的 settings.json 存了大量状态）。因此：

- `apply()` 前复查 `(mtime, size, sha256)` 与 snapshot 是否一致
- **不一致 → 放弃本次事务，重新 snapshot，最多重试 2 次**
- 仍失败 → 报 `ConfigurationError.concurrentModification`，不强行写入

### 8.4 幂等性实现（§6.3 要求但未定义）

**不靠字符串匹配 command 路径**（App 移动位置即失配）。方案：

1. 配置条目用绝对路径写入 shim，`command` 形如 `/Applications/AgentPetRuntime.app/Contents/MacOS/agentpet-hook --agent claude-code --event PreToolUse`
2. `integrations/<agent-id>.json` 中记录**我们写入的确切条目内容**
3. `configure()` 先读集成状态：若已配置且当前文件中的条目与记录一致 → **no-op**
4. `uninstall()` 按记录内容精确匹配删除，**绝不删除匹配不到的条目**

这样即使 App 被移动，uninstall 仍能找到旧条目（记录里存着旧路径）；重新 configure 会先清理旧条目再写新条目。

### 8.5 集成状态文件

```json
{
  "schemaVersion": 1,
  "agentID": "claude-code",
  "integrationVersion": "1",
  "status": "configured",
  "configuredAt": "2026-09-12T01:00:00Z",
  "lastValidatedAt": "2026-09-12T01:00:00Z",
  "lastEventAt": "2026-09-12T02:30:00Z",
  "configFingerprint": "sha256:...",
  "writtenEntries": [
    { "file": "~/.claude/settings.json",
      "path": "hooks.PreToolUse[2]",
      "content": { "matcher": "*", "hooks": [ { "type": "command", "command": "...", "timeout": 5 } ] } }
  ],
  "capabilities": ["detect","configure","uninstall","test","liveEvents"]
}
```

**不写入**：API Key、OAuth token、prompt 内容、模型配置。

### 8.6 持久化状态 vs 派生状态（2026-09-14 修正 health 判据）

```
持久化（写 integrations/<agent>.json）:
    notConfigured | configured | configureFailed
    lastEventAt   ← 唯一持久化的运行时事实：最后一次收到事件的时间戳（限流写，≥10s/次）

派生（每次从现实重新计算，不持久化）:
    detected      ← 可执行文件在哪
    connected     ← configured + 条目在位 + 曾经收到过事件（本次或历史）
    degraded      ← configured + 条目在位 + 至今一个事件都没收到
    disconnected  ← configured + 条目在位 + 配置文件里我们的条目已消失
```

**判据是"证据"，不是"新鲜度"**：hook 只在回合前后触发，空闲的 Agent 安静几分钟到几小时都正常。原来的判据是"30 秒内有过事件"，于是用户每次停下来读回答，卡片就报 `Degraded — no events have arrived recently`；重启后（时间戳只在内存里）更是必然误报。因此 `lastEventAt` 落盘、`Degraded` 只保留"装好 hook 后从未收到过任何事件"这一种真正需要处理的情况，"最后事件时间"作为**事实**显示在行内，而不是结论。

`Degraded` 的文案据此改为可操作的："Hooks are installed, but no event has ever reached the pet. Agents read their hooks at startup, so restart it once."

UI 显示的组合状态：

| 持久化 | 派生 | 显示 |
|---|---|---|
| — | 未检测到 | `Not Detected` |
| notConfigured | detected | `Detected` + [Configure] |
| configured | connected | `Connected` ●（行内显示最后事件时间） |
| configured | degraded | `Degraded` ● (黄) + 提示重启 Agent |
| configured | disconnected | `Needs Attention` ! + [Reconfigure] |
| configureFailed | — | `Error` + [Fix] |

管理窗口打开期间，卡片和 Activity 列表由 1s ticker 驱动重新求值（复用已有的 detection 结果，不重复 spawn `--version`）；此前卡片只是"打开那一刻的快照"，会在事件不断到达时继续显示"没有事件"。

### 8.7 可执行文件到哪儿找（2026-09-14 修正：GUI 的 PATH 不是终端的 PATH）

`Not Detected` 曾是 pi 在本机的常态，原因不在 agent 本身：

- Finder / 登录项启动的 .app 由 launchd 拉起，`PATH` 是 `/usr/bin:/bin:/usr/sbin:/sbin`；
  终端里那个 PATH（fnm / nvm / pnpm / …）在 app 进程里**根本不存在**。
- 本机 pi 由 fnm 安装，真实位置 `~/.local/share/fnm/node-versions/<ver>/installation/bin/pi`。
  终端能看到它，只是靠 fnm 给每个 shell 建的临时软链目录
  `~/.local/state/fnm_multishells/<pid>_<ts>/bin`（PID 命名、随 shell 生灭）——不能作为搜索依据。
- 实测（同一台机器）：终端下 `--status` 四个 agent 全 ●；`env -i HOME=$HOME PATH=/usr/bin:/bin`
  下只有 pi 变 ○。claude / codex / grok 是 Mach-O 原生二进制，且恰好落在固定目录里，
  把这个缺陷盖住了。

`AgentDetector.defaultSearchPaths()` 现在在 PATH **之后**追加各版本管理器的默认目录：

```
~/.local/share/fnm/node-versions/*/installation/bin    按目录名里的版本号，新的在前
~/.nvm/versions/node/*/bin                             同上
~/.volta/bin   ~/.bun/bin   ~/Library/pnpm   ~/.asdf/shims   ~/.local/share/mise/shims
```

三条理由，写给下一个想改这里的人：

1. **顺序由我们定，不交给文件系统**：通配目录按名字里的数字排序，否则同一台机器两次启动
   可能报出不同版本的路径。`newestFirst` 有测试（`AgentDetectorTests`）。
2. **PATH 排在枚举目录之前**：从终端启动时，shell 自己解析出的那一条比我们枚举的更准；
   枚举目录只兜 launchd 那种"什么都没有"的情况。
3. **不解析 login shell 的 PATH**（`$SHELL -lic 'echo $PATH'`）：能覆盖自建目录，但本机实测
   **461 ms**，还要执行用户的 rc 文件——有副作用（fnm env 会写状态目录）、rc 卡住就只能超时放弃。
   用一个会超时的不确定换一个罕见场景不值。**代价明确接受**：非默认位置（如 `~/opt/node/bin`）
   检测不到，这是有意的取舍，不是遗漏。

版本探针（`--version`）继承的 PATH 里也追加了这些目录：版本管理器装的 CLI 通常是脚本
（`pi` 的 shebang 是 `#!/usr/bin/env node`），没有 node 就退 127，表现为"检测到了但没有版本号"。
实测 `env -i PATH=/usr/bin:/bin pi --version` → `env: node: No such file or directory`。

另外 `Specification.extraSearchPaths` 此前是个**死字段**（声明、赋值、注释都在，没有读取方），
现已接上：先扫 agent 自己的 extra，再扫全局表。

---

## 9. 常量汇总

集中在一处便于调参。

```swift
enum RuntimeConstants {
    // Activity Engine
    static let agingThreshold  : TimeInterval = 90
    static let maxPromotions   : Int = 2
    static let focusHold       : TimeInterval = 3.0
    static let urgentOverride  : TimeInterval = 1.0
    static let completionDwell : TimeInterval = 4.0

    // 静默超时
    static let runningStale    : TimeInterval = 300   // 单次工具调用可以跑好几分钟
    static let unknownStale    : TimeInterval = 60
    static let approvalStale   : TimeInterval = 300
    static let failedStale     : TimeInterval = 600

    // Bridge
    static let bridgeProtocolVersion = 1
    static let dedupeWindow    : TimeInterval = 0.5
    static let shimTimeout     : TimeInterval = 0.1

    // 未送达事件
    static let spoolMaxEvents  : Int = 200
    static let spoolDirectory  = "pending-events"

    // 集成
    static let lastEventPersistInterval : TimeInterval = 10   // 时间戳落盘的限流窗口
    static let maxBackups      : Int = 10

    // 校验
    static let maxPackageBytes = 64 * 1024 * 1024
}
```

---

## 10. 与原方案的决策差异汇总

| 项 | 原方案 | 本方案 | 理由 |
|---|---|---|---|
| Bridge 方向 | Agent 连接 server | 双向：shim 出站 + socket 入站 | 实测 Agent 只支持进程派生 |
| `PetState` 层 | 独立 5 态状态机 | **删除**，`AgentState → AnimationTrack` 直连 | 中间层无信息增量，只是多一套词汇 |
| atlas 行驱动 | 隐含 9 行 ← 9 态 | 4 行状态驱动 + 3 行手势 + 2 行位移 | 行语义与状态语义不同构 |
| V2 atlas | 不定义为稳定，倾向拒绝 | **降级兼容**，播放 row 0–8 | 用户已有 V2 资产 |
| `~/.codex/pets` | 未提及 | **唯一的 pet 来源**，只读 | 与 Codex TUI、`codex-pets` CLI 读同一目录，两个答案的问题不复存在 |
| 卸载安全 | "不删源目录" | **不适用**：本项目不持有 pet，增删改都在 Codex 侧 | 自有存储已删除（§6.3） |
| ADR-009 XPC | 保留 | **删除** | v0.1 无第三方代码需隔离 |
| 开发顺序 | P0 状态机 → P2 Activity | **合并为一个里程碑** | 状态机的输入由 Activity Engine 决定，不能分开 |
