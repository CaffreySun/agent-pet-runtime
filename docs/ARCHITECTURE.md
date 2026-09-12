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

**关键差异**：Agent 从不连接我们。它们 `fork/exec` 一个 shim，shim 主动写 socket。App 未运行时，事件被静默丢弃（§3.7 of SPEC-REVIEW）。

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
| `completed` | 4 `jumping` | **once → idle** | "anticipation, lift, peak, descent, and settle"——唯一适合表达"做好了"的行 |
| `failed` | 5 | **once → idle** | "readable error, sad, or deflated reaction" |
| `paused` / `unknown` | 0 | loop | 无可展示信息 |

**`waving`（row 3）不由任何 AgentState 选择。** 契约说它是 "greeting or attention gesture"——那是对**用户**的反应，不是对 Agent 的。本 runtime 用它作为**点击宠物时的问候动作**。

`completed` 与 `failed` 都是 one-shot：播完落到下面的层，而不是冻结在最后一帧。否则任务失败后你会得到一个永远哭丧着脸的宠物。

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
| `running` | 30s | `unknown` |
| `unknown` | 60s | `idle` |
| `waitingInput` | 不超时 | — （用户可能离开很久） |
| `waitingApproval` | 5min | `unknown` |
| `completed` | `completionDwell` | `idle` |
| `failed` | 10min | `idle` |
| `idle` | — | — |

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

---

## 6. Pet Provenance 与生命周期（补齐 §8.4 / §8.6）

### 6.1 存储布局

```
~/Library/Application Support/AgentPetRuntime/
├── pets/<pet-id>/
│   ├── pet.json
│   ├── spritesheet.webp
│   └── .agentpet/metadata.json      ← 运行时私有，不污染 package
├── integrations/<agent-id>.json
├── backups/<agent-id>/<timestamp>/  ← 保留最近 10 份
├── staging/                         ← 安装事务的临时区
└── logs/
```

**metadata.json 放在 `.agentpet/` 子目录**而不是 package root，因为 §6.2 的校验器会拒绝 package 里出现未预期的文件。运行时自己的元数据必须与用户资产隔离。

### 6.2 `metadata.json`

```json
{
  "schemaVersion": 1,
  "petID": "pet-one",
  "displayName": "pet-two",
  "compatibilityProfile": "openaiCodexV1",
  "contentHash": "sha256:...",
  "provenance": {
    "kind": "imported",
    "originalSourcePath": "/Users/x/Downloads/pet-one",
    "originalSourceRemoved": false,
    "installedAt": "2026-09-12T01:00:00Z",
    "managedByRuntime": true
  },
  "installedVersion": null,
  "lastValidatedAt": "2026-09-12T01:00:00Z"
}
```

**`managedByRuntime` 是卸载时唯一决定"能否删磁盘"的字段。**

| 值 | 来源 | 卸载行为 |
|---|---|---|
| `true` | 用户 Import 到运行时存储 | 删除 `pets/<pet-id>/` 整个目录 |
| `false` | 指向 `~/.codex/pets/...` 的发现条目 | **只删注册表条目，磁盘不动** |

### 6.3 安装事务

```
1. 复制到 staging/<uuid>/
2. 校验（manifest → 路径安全 → payload → atlas）
3. 计算 contentHash
4. 写 staging/<uuid>/.agentpet/metadata.json
5. 原子 rename: staging/<uuid> → pets/<pet-id>
   ├── 若 pets/<pet-id> 已存在 → 先 rename 到 staging/<uuid>.old
   └── 失败 → 把 .old rename 回去
6. 删除 .old
```

**顺序关键**：先全部校验再落盘。校验失败时 `pets/` 目录从未被触碰，天然实现"失败自动恢复"。

### 6.4 `PetSource` 扩展（修正 §8.7）

原方案的 `enum PetSource { bundled, local, imported, registry(URL) }` 不够，因为实测存在一个重要的真实来源：

```swift
enum PetSource: Equatable {
    case bundled
    case imported(from: URL)        // 用户主动 Import
    case codexPets                  // ~/.codex/pets/ 发现  ← 新增
    case local                      // 已在运行时存储中
    case registry(URL)              // v0.2
}
```

`~/.codex/pets/` 作为**只读发现源**：Pet Manager 的 "Discover" 扫描它，展示为可 Import 的条目。导入即复制，之后两者独立。

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

### 8.6 持久化状态 vs 派生状态

```
持久化（写 integrations/<agent>.json）:
    notConfigured | configured | configureFailed

派生（每次从现实重新计算，不持久化）:
    detected      ← 可执行文件在哪
    connected     ← lastEventAt 在 30s 内
    degraded      ← configured 但 lastEventAt 超过 30s
    disconnected  ← configured 但配置文件里我们的条目已消失
```

UI 显示的组合状态：

| 持久化 | 派生 | 显示 |
|---|---|---|
| — | 未检测到 | `Not Detected` |
| notConfigured | detected | `Detected` + [Configure] |
| configured | connected | `Connected` ● |
| configured | degraded | `Degraded` ● (黄) |
| configured | disconnected | `Needs Attention` ! + [Reconfigure] |
| configureFailed | — | `Error` + [Fix] |

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
    static let runningStale    : TimeInterval = 30
    static let unknownStale    : TimeInterval = 60
    static let approvalStale   : TimeInterval = 300
    static let failedStale     : TimeInterval = 600

    // Bridge
    static let bridgeProtocolVersion = 1
    static let dedupeWindow    : TimeInterval = 0.5
    static let shimTimeout     : TimeInterval = 0.1

    // 集成
    static let connectedWindow : TimeInterval = 30
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
| `~/.codex/pets` | 未提及 | 只读发现源 | 实测已存在 5 个 Pet |
| 卸载安全 | "不删源目录" | 靠 `managedByRuntime` 字段 | 原表述不可实现 |
| ADR-009 XPC | 保留 | **删除** | v0.1 无第三方代码需隔离 |
| 开发顺序 | P0 状态机 → P2 Activity | **合并为一个里程碑** | 状态机的输入由 Activity Engine 决定，不能分开 |
