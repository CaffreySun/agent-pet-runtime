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

## 3. 动画轨道模型（修正 §9.1 / §12.1）

### 3.1 轨道不是状态的同义词

原方案隐含「9 个 atlas 行 ↔ 9 个 Agent 状态」。**错的。**

实测的 9 行中，只有 **4 行**由 `AgentState` 驱动。其余 5 行由别的输入驱动：

| 类别 | 行 | 驱动源 |
|---|---|---|
| **State track** | 0 `idle`, 5 `failed`, 6 `waiting`, 7 `running` | `AgentState` |
| **Gesture track** | 3 `waving`, 4 `jumping`, 8 `review` | 瞬时事件（完成 / 会话开始 / review 模式） |
| **Locomotion track** | 1 `running-right`, 2 `running-left` | 位移方向（拖动 / 移动），与 Agent 无关 |

### 3.2 状态 → 轨道映射表（**这是原方案缺失的核心产物**）

| `AgentState` | `AnimationTrack` | row | 帧数 | fps | 播放 | 备注 |
|---|---|---|---|---|---|---|
| `idle` | `.idle` | 0 | 6 | 8 | loop | |
| `running` | `.running` | 7 | 6 | 12 | loop | 默认用 row 7，不用方向行 |
| `waitingInput` | `.waiting` | 6 | 6 | 6 | loop | |
| `waitingApproval` | `.waiting` | 6 | 6 | 6 | loop | 与上一行同轨，靠 UI 徽标区分 |
| `completed` | `.waving` | 3 | 4 | 8 | once→idle | 手势轨 |
| `failed` | `.failed` | 5 | 8 | 10 | loop | |
| `paused` | `.idle` | 0 | 6 | 8 | loop | |
| `unknown` | `.idle` | 0 | 6 | 8 | loop | |

**瞬时轨道**（由事件触发，不由状态触发）：

| 事件 | `AnimationTrack` | row | 帧数 | fps | 播放 |
|---|---|---|---|---|---|
| session 建立 | `.jumping` | 4 | 5 | 12 | once→状态轨 |
| 完成（保留手势） | `.waving` | 3 | 4 | 8 | once→idle |

**未驱动轨道**（v0.1 保留但不由 Agent 触发）：

| 轨道 | row | 状态 |
|---|---|---|
| `.runningRight` | 1 | v0.2 由拖动方向驱动 |
| `.runningLeft` | 2 | v0.2 由拖动方向驱动 |
| `.review` | 8 | **保留**。Codex 有 `codex review` 子命令，v0.2 可引入 `reviewing` 状态 |

> **`review` 的处置需要决策**：v0.1 不驱动它，意味着 8 帧 × 6 列 = 48 个单元格被浪费。
> 两个选项：(a) 接受浪费，等 v0.2；(b) v0.1 就加 `AgentState.reviewing` 并映射 Codex 的 review 事件。
> **默认选 (a)**，因为 (b) 需要先确认 Codex 是否在 hook 里暴露 review 模式。

### 3.3 播放参数为什么必须显式定义

原 contract 只给了**每行帧数**，没给**帧率与循环语义**。缺这两项时：

- `waving`（4 帧）该循环还是播一次？播一次后停在哪一帧？
- `completed` 状态的 Pet 如果循环 waving，用户会看到一个无限挥手的宠物。

§3.2 表中的数值是**设计建议，不是官方契约**。它们应当作为 `CompatibilityProfile` 内可覆盖的常量，便于调参而不改代码。

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
  "petID": "clippit",
  "displayName": "Clippy",
  "compatibilityProfile": "openaiCodexV1",
  "contentHash": "sha256:...",
  "provenance": {
    "kind": "imported",
    "originalSourcePath": "/Users/x/Downloads/clippit",
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

**V2 不得被拒绝**——用户本机已有 V2 资产（`~/.codex/pets/pet-ben-hill/`）。

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
