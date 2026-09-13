# Agent Pet Runtime v0.1 — 方案评审

> 对 `Agent_Pet_Runtime_v0.1.md` 的逐项核验、纠错与补全。
> 核验时间：2026-09-12 · 核验环境：macOS 15.7.9 / Swift 6.2.4 / Xcode 26.3 / arm64

本文档中每一条结论都标注了证据等级：

| 标记 | 含义 |
|---|---|
| **[实测]** | 在本机实际运行命令 / 读取文件得到，附命令或文件路径 |
| **[文档]** | 来自官方文档、官方仓库源码，附 URL |
| **[推理]** | 由前两者推导，未经直接验证 |
| **[未验证]** | 无法确认，需要进一步实验 |

---

## 0. 结论摘要

方案的**分层架构是正确的**，但**接入层（Event Bridge）的核心假设是错的**，且在 9 个地方存在会导致无法实现的规格空洞。

三个必须修的问题：

1. **§6.5 / §4 把 Event Bridge 描述成"Agent 连接过来的服务器"，这是错的。** 实测四个 Agent 中三个通过 **hook 进程派生（spawn）** 交付事件，一个通过 **进程内扩展**。Bridge 的入站端不是 server socket，而是一个**被 Agent 调用的 CLI shim**。方案从未定义这个 shim——这是最大的架构遗漏。
2. **Hook 位于 Agent 的关键路径上，方案对此零约束。** 没有延迟预算、没有超时策略、没有"永不阻塞"要求。一个卡住的桌宠会拖慢用户每一次工具调用。§20 的性能目标只关心 Pet 的观感，完全没覆盖这一条。
3. **存在三套互不映射的状态词汇表**（`AgentState` 8 态 / `PetState` 5 态 / atlas 9 行），方案没有给出映射表。没有这张表，Pet Runtime 无法实现。

此外，方案 §9.4 关于 V2 atlas（1536×2288 / 8×11）的猜测**已被实测证实**——用户本机就装着一个 V2 Pet。若 v0.1 按 §9.4 的措辞拒绝 V2，则无法渲染用户已有资产。

---

## 1. 已核验为正确的部分

这些结论经实测或官方文档确认，可以直接作为实现基线。

### 1.1 Atlas 几何与行契约 **[文档]**

来自 `openai/skills` 仓库 `hatch-pet` 的 composer 与 validator 源码：

```python
COLUMNS = 8
ROWS = 9
CELL_WIDTH = 192
CELL_HEIGHT = 208
ATLAS_WIDTH  = COLUMNS * CELL_WIDTH    # 1536
ATLAS_HEIGHT = ROWS * CELL_HEIGHT      # 1872
```

行→动画→帧数契约（`ROW_SPECS`，两个脚本一致）：

| row | 动画名 | 帧数 |
|---|---|---|
| 0 | `idle` | 6 |
| 1 | `running-right` | 8 |
| 2 | `running-left` | 8 |
| 3 | `waving` | 4 |
| 4 | `jumping` | 5 |
| 5 | `failed` | 8 |
| 6 | `waiting` | 6 |
| 7 | `running` | 6 |
| 8 | `review` | 6 |

方案 §9.1 的表述与此一致。**新增关键信息：每行的帧数是契约的一部分，且未使用单元格必须完全透明。** 方案完全没有记录帧数——没有帧数就无法实现播放器。

- <https://github.com/openai/skills/blob/main/skills/.curated/hatch-pet/scripts/compose_atlas.py>
- <https://github.com/openai/skills/blob/main/skills/.curated/hatch-pet/scripts/validate_atlas.py>

### 1.2 Pet package 组织 **[文档]**

`hatch-pet` SKILL.md 明确：

```bash
# 打包命令等价于
jq -n '{id: $id, displayName: $displayName, description: $description,
        spritesheetPath: "spritesheet.webp"}'
# 安装到
${CODEX_HOME:-$HOME/.codex}/pets/<pet-name>/
```

与方案 §9.2 / §9.3 一致。

**但方案遗漏了一件重要的事：Codex 官方约定的安装位置是 `~/.codex/pets/`。** 实测本机该目录已存在且已有 5 个 Pet：

```
~/.codex/pets/pet-one/         pet.json + spritesheet.webp  (1536x1872)
~/.codex/pets/pet-two/          pet.json + spritesheet.webp  (1536x1872)
~/.codex/pets/some-v2-pet/    pet.json + spritesheet.webp  (1536x2288)  ← V2
~/.codex/pets/pet-three/         pet.json + spritesheet.webp  (1536x1872)
~/.codex/pets/x-mega-pet/      run/ 目录，无 pet.json       ← 不完整
```

方案 §14.1 定义的 `~/Library/Application Support/AgentPetRuntime/pets/` 是**第二个**位置，与 Codex 约定并存。方案既没承认这个目录的存在，也没定义两者关系。见 §3.5。

### 1.3 四套 Agent 均在本机安装 **[实测]**

```
codex    /opt/homebrew/bin/codex                          codex-cli 0.153.4
claude   (via PATH)                                       Claude Code 2.1.268
grok     /opt/homebrew/bin/grok                           grok 1.0.24 (Grok Build TUI)
pi       .../node_modules/@earendil-works/pi-coding-agent 0.85.1
```

---

## 2. 必须修正的错误

### 2.1 【严重】Event Bridge 的接入方向搞反了

**方案原文**（§4 架构图、§6.5）：

```
┌─────────────┐
│ Event Bridge│   ← 隐含：Agent 主动连过来
└─────────────┘
"Local IPC | Unix Domain Socket / local IPC"   (§13.1)
```

**实测的真相**：三种交付机制，**没有一种是 Agent 主动连接我们的 socket**。

| Agent | 事件交付机制 | 证据 |
|---|---|---|
| Claude Code | hook 命令：Agent **spawn 一个进程**，JSON 走 **stdin** | hooks 机制 |
| Grok | hook 命令：同上，`type = "command"`, `command = "/abs/path.sh"` | `~/.grok/README.md:1782` |
| Codex | `notify` 配置项：**spawn 一个进程**，参数走 **argv** | `~/.codex/config.toml` |
| Pi | **进程内 TypeScript 扩展**，`pi.on("tool_call", ...)` | `pi/docs/extensions.md` |

Grok 的 hook 配置原文（`~/.grok/README.md:1774-1790`）：

```toml
[[hooks.PreToolUse]]
matcher = "Bash|Write|Edit"
  [[hooks.PreToolUse.hooks]]
  type = "command"
  command = "/opt/guard/pretooluse.sh"   # use an absolute path
  timeout = 10
```

注意 `type = "command"` 和绝对路径要求——这就是**进程派生**，不是 socket 连接。Grok 文档还明确说 "The schema matches the JSON `hooks` object"，即与 Claude Code 的 hooks JSON schema 同构 **[文档]**。

Codex 的 `notify` 实测值：

```toml
notify = ["/Users/.../SkyComputerUseClient", "turn-ended"]
```

即 `[可执行文件, 参数...]`，Codex 自己 spawn 它 **[实测]**。

**修正后的架构**：

```
Agent 进程
   │  spawn (stdin: JSON)          ← 事件从这里出来
   ▼
agentpet-hook  (CLI shim, 无状态, 必须极快)
   │  连接 / 写入
   ▼
UDS: ~/Library/Application Support/AgentPetRuntime/bridge.sock
   │
   ▼
BridgeServer (App 内)
   │
   ▼
EventNormalizer → ActivityEngine → PetStateMachine → Renderer
```

**Bridge 是"出站 shim + 入站 socket"两段式**，不是单一 server。方案缺的是前半段。

### 2.2 【严重】Hook 在关键路径上，方案无任何约束

由于 hook 是**进程派生 + 同步等待**，shim 的耗时会被直接加到用户的每一次工具调用上。方案 §20 的性能目标里**完全没有这一项**。

必须补充的硬约束：

```
shim 冷启动 + 投递  P50 < 5ms, P99 < 25ms
shim 总超时（含重试）     < 100ms 硬上限
Agent 未运行 / App 未启动  → 立即静默退出 0，绝不重试阻塞
socket 连接失败            → 立即退出 0（事件丢失，不是错误）
```

以及最重要的：**shim 永远 exit 0**。

理由：Claude Code hook 语义中，**非 0 退出码是有意义的**（exit 2 = 阻断该工具调用并把 stderr 反馈给模型）。如果 shim 在桌宠崩溃时返回非 0，会**改变 Agent 的行为**——直接违反方案 §7.4「不侵入原则」。这条约束方案完全没有，但它是最容易踩的坑。

**[推理]** 基于 hook 的常规语义推导；Claude Code 的确切退出码语义待确认。

### 2.3 【严重】三套状态词汇表没有映射

方案中存在三套互不相同的状态集合：

| 来源 | 位置 | 取值 |
|---|---|---|
| A | §10.4 `AgentState` | `idle` `running` `waitingInput` `waitingApproval` `completed` `failed` `paused` `unknown` （8） |
| B | §12.1 `PetStateMachine` | `Idle` `Running` `Ready` `NeedsInput` `Blocked` （5） |
| C | §9.1 atlas 行 | `idle` `running-right` `running-left` `waving` `jumping` `failed` `waiting` `running` `review` （9） |

方案**没有给出 A→B→C 的映射**。§10.4 的表格只覆盖了 A 的 6 个取值，且写的是 `completed → ready / celebration`——`celebration` 既不是 B 也不是 C 的成员。

没有这张表，`PetStateMachine` 和 `AnimationResolver` 无法实现。**补齐的表见 `ARCHITECTURE.md` §4。**

### 2.4 `PetState` 层是多余的 **[推理]**

即便补齐映射，B 层（5 态）带来的信息量为零：它是 A→C 的一个纯函数中间层，且丢失信息（把 `waitingInput`/`waitingApproval` 合并，又把 `completed` 拆成新名字）。

**建议：删除 `PetState` 这一层，改为 `AgentState → AnimationTrack` 直接映射。** 少一层、少一套词汇、少一类 bug。§12.1 的状态机图可以保留，但应标注为"动画轨道之间的转移"，而不是独立状态机。

### 2.5 §8.6「卸载不删用户源目录」不可实现

> **2026-09-13 反转**：运行时自有存储后来被整体删除，本项目不再安装 / 卸载任何 pet，也就没有"删不删源目录"的问题。以下推理保留原样，替代方案见 `ARCHITECTURE.md` §6.3。

方案原文：

```
Runtime managed storage  └── removable
User source directory    └── never delete automatically
```

但没有定义**运行时如何区分这两者**。如果用户从 `~/Downloads/MyPet/` 导入，运行时在 `pets/my-pet/` 建了一份副本，卸载时删副本——这是对的。但如果用户指定 `~/.codex/pets/pet-two/` *本身*为安装位置，就分不清了。

**修正：安装时必须写入 provenance 记录**（见 `ARCHITECTURE.md` §6），至少包含：

```json
{
  "provenance": {
    "kind": "imported",            // bundled | imported | discovered
    "originalSourcePath": "/Users/x/Downloads/MyPet",
    "installedAt": "2026-09-12T01:00:00Z",
    "contentHash": "sha256:...",
    "managedByRuntime": true       // 唯一决定"能否删除"的字段
  }
}
```

`managedByRuntime == false` 时卸载**只移除注册表条目，不碰磁盘**。

### 2.6 §24 ADR-009 是悬空的

> ADR-009 | 第三方扩展优先 XPC | 降低主进程崩溃与供应链风险

XPC 在 §24 出现一次，之后全文再未提及。而 §15.3 明确规定 Pet package **永不执行脚本**——即 v0.1 里根本没有第三方可执行代码需要隔离。

**修正：删除 ADR-009，或在 v0.3「第三方 Agent Adapter SDK」条目下重新引入。** 保留一条从不使用的 ADR 会误导后续实现者去设计 XPC 边界。

### 2.7 §9.4 对 V2 的态度会导致无法渲染用户已有资产

方案原文：

> 当前社区已有 V2 / `1536×2288` / `8×11` 的真实实现与兼容项目……但 v0.1 不把未经正式确认的扩展直接定义为稳定标准。

**实测确认 V2 真实存在**：

```
~/.codex/pets/some-v2-pet/spritesheet.webp   1536x2288
~/.codex/pets/some-v2-pet/pet.json           {"spriteVersionNumber": 2, ...}
```

`2288 / 208 = 11` 行，与方案描述一致 **[实测]**。

问题在于：按 §9.4 的措辞，v0.1 会把这个 Pet 判为"不符合稳定标准"而拒绝——**但它就在用户机器上，是用户的真实资产**。

**修正：`spriteVersionNumber` 是 manifest 的显式版本字段，应当作为 profile 选择的第一依据**（而非按尺寸猜测）。V2 在 v0.1 中：

- **必须能被解析和加载**（不得拒绝）
- **必须能播放 row 0–8**（与 V1 重合的部分，行语义一致）
- row 9–10 **标记为 experimental，不播放**，在 UI 中显示为"部分兼容"

即：**降级兼容（degrade gracefully），而不是拒绝**。这比方案原措辞更安全，且成本极低。

**[未验证]** V2 的 row 9/10 分别是什么动画。需要拿到一个 V2 样本目视确认，或找到 V2 composer 源码。这是 v0.1 实现 V2 支持前唯一的前置未知项。

### 2.8 §8.2 `PetMetadata` 字段不完整 **[实测]**

实测 5 个真实 manifest，出现了方案未记录的字面字段：

`~/.codex/pets/pet-one/pet.json`：
```json
{
  "id": "pet-one",
  "displayName": "pet-two",
  "description": "...",
  "spritesheetPath": "spritesheet.webp",
  "kind": "object",                  // ← 方案未记录
  "source": "codex-pets.net",        // ← 方案未记录
  "sourceId": "pet-one"              // ← 方案未记录
}
```

`~/.codex/pets/some-v2-pet/pet.json`：
```json
{
  "id": "v2-pet",             // ← 与目录名 some-v2-pet 不一致 !
  "displayName": "真实头像宠物",
  "description": "...",
  "spriteVersionNumber": 2,          // ← 方案未记录
  "spritesheetPath": "spritesheet.webp"
}
```

三个方案必须处理的现实：

1. **manifest 的 `id` 与目录名可以不一致。** 方案 §8.5 用 `petID` 作为升级/卸载的主键，但安装来源目录名不等于 `id`。**主键必须是 manifest 的 `id`，目录名仅作展示。**
2. `kind` / `source` / `sourceId` 是第三方生态（codex-pets.net）的事实字段，解析器**必须宽容忽略未知字段**，而不是 strict decode 失败。
3. package 里允许有**任意额外文件**（`some-v2-pet` 里有 `readme.txt`）。校验器不能假设目录里只有两个文件。

### 2.9 校验器规格缺失——只有"Validate atlas"四个字

§8.4 的安装流程写着 `Validate atlas`，§21.1 写着 `atlas validation`，但**没有任何一处定义了校验什么**。

基于 §1.1 的官方 validator，必须校验的最小集合：

```
1. 解码成功（WebP 或 PNG）
2. 尺寸 == profile 期望尺寸（V1: 1536x1872，V2: 1536x2288）
3. 存在 alpha 通道
4. 每行前 N 帧（N = 该行帧数）的单元格非空
5. 每行第 N 帧起的单元格完全透明            ← 官方 validator 的硬要求
6. manifest.spritesheetPath 解析后仍在 package root 内（路径穿越）
7. 不包含可执行扩展名
```

第 5 条是最容易被忽略、也最容易导致「Pet 显示成一坨残影」的一条。

**性能约束**：WebP 解码 1536×1872 ≈ 11MB RGBA。校验必须**流式/分块**，不能整张解码进内存后再遍历。§20 的 "Pet Manager 安装/预览过程不阻塞主 Pet Renderer" 隐含了这一点但没写。

### 2.10 §11.1 Activity Engine 的数值全是空白

方案列出了正确的机制名，但没有一个数值：

| 机制 | 方案原文 | 缺失 |
|---|---|---|
| `focus hold` | "避免频繁抢占" | 多长时间？ |
| `completion dwell` | "完成动画保持短暂时间" | 多短？ |
| `priority aging` | "长期等待的 Activity 自动提高优先级" | 时间尺度？斜率？上限？ |
| `session dedupe` | "同一 session 只能有一个 active activity" | 去重键是什么？ |

且**完全没有 tie-break 规则**：两个 session 同时 `waitingInput` 时显示谁？一个 `waitingInput` 已等 10 分钟、另一个刚进入 `waitingInput`，谁赢？

也**完全没有迟滞（hysteresis）**：A 和 B 交替发事件时，Pet 会在两个 Agent 之间高频闪烁。

这些数值决定了产品的"手感"，是必须显式定义的核心业务逻辑。**补齐值见 `ARCHITECTURE.md` §5。**

### 2.11 §7.2 集成状态机不完整

```
NotDetected → Detected → Configuring → Configured → Connected → Degraded/Disconnected
```

缺失：

- **App 重启后状态如何恢复？** `Connected` 依赖"事件源存活"这个运行时事实，不能持久化。必须区分**持久化状态**（Configured: 我们写过配置）与**派生状态**（Connected: 最近 N 秒收到过事件）。
- **`Degraded` 的判定条件是什么？** 建议：配置在位但超过 `staleThreshold` 未收到事件。
- **回退边。** `Connected → Configured`（事件超时）、`Configured → Detected`（用户手工删了 hook）都要有定义。
- `NotDetected → Detected` 不是用户动作，是轮询结果，不应画成主动转移。

---

## 3. 需要补齐的业务逻辑

### 3.1 Hook shim 契约（方案完全缺失）

```
agentpet-hook --agent <agent-id> --event <event-name>
```

| 输入 | 来源 |
|---|---|
| argv | Agent 的 hook 配置里固定写死（`--agent claude-code --event PreToolUse`） |
| stdin | Agent 传入的 JSON payload（透传，不解析） |
| env | `AGENTPET_SESSION_ID` 等可选覆盖 |

| 输出 | 值 |
|---|---|
| 正常（含 App 未运行、socket 不可达、超时） | **exit 0** |
| 参数错误 | exit 64（仅开发期） |

**硬要求**：

- 无状态，不写日志到 stdout（会污染 Agent 的输出解析）
- 不做 JSON 解析（透传原始字节，解析在 App 侧做，失败隔离更干净）
- 不等待 App 的应答（单向投递，fire-and-forget）
- 单文件静态链接，冷启动 < 5ms

### 3.2 Bridge wire protocol（方案只有一句 "Local event protocol"）

需要一个**带版本号的信封**，而非直接把 `AgentEvent` 序列化：

```json
{
  "v": 1,
  "shimVersion": "0.1.0",
  "agentID": "claude-code",
  "eventName": "PreToolUse",
  "receivedAt": "2026-09-12T01:23:45.678Z",
  "rawPayload": { /* Agent 原样透传 */ }
}
```

`rawPayload` 保持不解析，由 App 侧对应 Adapter 的 `EventNormalizer` 解释。这样**协议版本与 Agent 私有协议解耦**——新增 Agent 不改 wire format，正是方案 §2.1「新增 Agent 不修改 Pet Runtime Core」的实现方式。

**幂等性**：需要 `dedupeKey`。同一 hook 可能因重试投递两次。建议用 `(agentID, eventName, payload.session_id, payload 中可用的唯一 id)` 组合；无法构造时退化为「同 session 同状态 N 秒内忽略」。

### 3.3 Session 关联（方案 §26 Q2 自己提出的开放问题）

**诚实的结论：hook payload 里没有 TTY，也没有父进程 PID。**

Claude Code hooks 传 JSON 含 `session_id`、`transcript_path`、`cwd` **[未验证，待研究确认]**，但**不含终端窗口标识**。这意味着方案 §3.4 / §13.3 的「点击 Activity → 聚焦对应 Agent session」在 v0.1 **无法用 hook 数据实现**。

可行路径（按成本排序）：

1. **降级为 `open()`**：用 `cwd` 打开 Finder / 对应 IDE。方案 §13.3 已经预留了这个降级，**应当把它作为 v0.1 的默认行为而非降级行为**。
2. **shim 采集进程信息**：shim 在被 spawn 时，其**父进程就是 Agent**。`getppid()` 即可拿到 Agent PID，再 `sysctl(KERN_PROC_PID)` 拿 TTY。这是**免费且可靠**的——比事后做窗口关联简单得多。强烈建议 v0.1 就在 shim 里做这件事。
3. **Accessibility API 做窗口关联**：成本高、需要授权、脆弱。推迟到 v0.2+。

第 2 条是本方案最有价值的实现技巧，方案里完全没有。

### 3.4 配置事务（§5.4 / §7.3 只有图，没有实现）

`backup → modify → validate → commit` 的四个空缺点：

| 问题 | 必需的处理 |
|---|---|
| Agent 自己也会写 settings.json | 修改前记录 mtime+size，提交前复查；不一致则放弃并重读 |
| 写入中途崩溃 | 写临时文件 + `rename()` 原子替换，不原地改写 |
| 备份无限增长 | 备份目录按时间保留最近 N 份（建议 N=10） |
| 部分应用（写了一半） | 所有写入先在内存中构造完整结果，一次性落盘 |
| 回滚后残留 | 回滚 = 把备份文件 rename 回去，并删除我们写的临时文件 |

**幂等性的实现方式**（§6.3 要求但未定义）：不靠字符串匹配 command 路径（App 移动位置就会失配），而是**在配置里写入带标记的条目 + 在集成状态文件里记录我们写入的确切内容**。uninstall 时用记录的内容做精确匹配删除。

Grok 的 hook 配置天然支持这一点——`[[hooks.PreToolUse]]` 是数组，追加即可，删除时按 `command` 字段精确匹配。

### 3.5 `~/.codex/pets` 与运行时自有存储的关系（§26 Q7）

> **2026-09-13 反转**：没有运行时自有存储，也没有 Import。`~/.codex/pets`（更准确地说 `$CODEX_HOME/pets`）就是唯一的来源，运行时只读。以下模型保留原样，现实行方案见 `ARCHITECTURE.md` §6。

方案自己提出了这个问题但没有回答。**建议的模型**：

```
~/.codex/pets/                    ← 只读发现源 (discovered source)
        │  用户在 Pet Manager 里「Import」
        ▼
App Support/AgentPetRuntime/pets/ ← 运行时唯一的可写存储
        │
        ├─ 渲染用这份
        └─ metadata.json 记录 provenance.originalSourcePath
```

即方案 §27 结尾主张的**「Pet 安装一次、Agent 只配置 Event Bridge」单一模型**。理由：

- 运行时可以自由做原子升级 / 回滚，不必担心破坏 Codex 的资产
- Codex 自己也会写 `~/.codex/pets`，运行时不能假设独占
- 卸载语义清晰（删运行时副本，源目录不动）
- 与方案 §2.1「安装后的 Pet 是 Runtime 的资源，不需要把 Pet 代码注入 Agent」自洽

**可选**：v0.2 增加「Publish to Codex」动作，把运行时管理的 Pet 单向复制回 `~/.codex/pets`。v0.1 不做。

### 3.6 动画播放参数（方案完全缺失）

仅有行→帧数契约还不够，播放器还需要每行的**帧率与循环方式**：

| 行 | 帧数 | 建议帧率 | 循环 |
|---|---|---|---|
| idle | 6 | 8 fps | loop |
| running-right | 8 | 12 fps | loop |
| running-left | 8 | 12 fps | loop |
| waving | 4 | 8 fps | once → idle |
| jumping | 5 | 12 fps | once → idle |
| failed | 8 | 10 fps | loop |
| waiting | 6 | 6 fps | loop |
| running | 6 | 12 fps | loop |
| review | 6 | 8 fps | loop |

**[推理]** 帧率是设计建议，官方 contract 未规定。应做成 profile 内可覆盖的常量，便于后续调参。这属于必须显式定义、但可以随便先给一组值的参数——**空着不行，因为它决定动画是否可播放**。

### 3.7 冷启动与丢事件策略（方案完全没有）

场景：Agent 触发 hook，但 Pet Runtime App 没运行。

| 策略 | 取舍 |
|---|---|
| shim 启动 App | 冷启动 App 要几百 ms，**违反 §2.2 的关键路径约束**。否决。 |
| shim 静默丢弃 | 成本 0，用户体验：App 启动后看不到启动前的事件。**推荐 v0.1**。 |
| shim 写本地 spool 文件 | App 启动后回放。多一次磁盘写，但保证不丢。**推荐 v0.2**。 |

v0.1 用丢弃 + App 启动后主动探测当前有哪些 Agent 进程在跑（process scan），补一个初始状态。

### 3.8 可执行 payload 的允许列表（§15.3 只说"拒绝"）

实测 package 中出现的文件类型：

```
pet.json           期望
spritesheet.webp   期望
readme.txt        实际存在，应允许
.DS_Store          实际存在，应忽略
run/               实际存在（hatch-pet 中间产物），应忽略或提示
```

**白名单扩展名**：`.json` `.webp` `.png` `.jpg` `.jpeg` `.gif` `.txt` `.md`
**一律拒绝**：`.sh` `.command` `.app` `.dylib` `.so` `.scpt` `.workflow` 及任何带可执行位（`0o111`）的文件
**忽略**：`.DS_Store`、`.` 开头的文件、`run/` 目录

---

## 4. 任务拆分

按依赖顺序。每个任务标注**验收标准**（TDD 的测试目标）。

### M0 — 项目骨架与规格冻结

| # | 任务 | 验收 |
|---|---|---|
| 0.1 | SwiftPM 包结构：`AgentPetCore`(lib) + `agentpet-hook`(exe) + `AgentPetApp`(exe) | `swift build` 通过 |
| 0.2 | 冻结 `ARCHITECTURE.md` 中的映射表与常量 | 文档评审通过 |

### M1 — 纯逻辑核心（**全部可 headless 测试，本里程碑的主体**）

| # | 任务 | 验收标准（测试） |
|---|---|---|
| 1.1 | `PetManifest` 宽容解码 | 5 个真实 manifest 全部解析成功；未知字段不报错；缺 `id` 报错；`id` 与目录名不一致时不报错 |
| 1.2 | `CompatibilityProfile` V1/V2 解析 | `spriteVersionNumber:2` → V2；缺失 → 按尺寸推断 → V1；1536×2288 → V2 |
| 1.3 | `SpriteAtlas` 几何 | 8×9/192×208 与 8×11/192×208 两种切分正确；越界行列抛错 |
| 1.4 | Atlas 校验器 | 尺寸错误/无 alpha/未使用单元格非透明/缺帧 各自能检出；对 4 个真实 webp 全部通过 |
| 1.5 | 路径穿越防护 | `../../etc/passwd`、绝对路径、符号链接逃逸 全被拒 |
| 1.6 | 可执行 payload 拒绝 | 上表白/黑名单逐项测试 |
| 1.7 | `AgentEvent` 归一化 | 每个 Agent 的原始 payload → `AgentEvent` 的分支全覆盖 |
| 1.8 | `AgentState → AnimationTrack` 映射 | 8 态 × 全部取值，含 V1/V2 profile 差异 |
| 1.9 | `ActivityEngine` 优先级 | P0..P4 排序；tie-break；aging 提升；hold 生效；dwell 生效 |
| 1.10 | `ActivityEngine` session 去重 | 同 session 连续事件只产生一个 activity；乱序事件不产生回退 |
| 1.11 | `BridgeEnvelope` 编解码 | 版本字段；未知版本拒绝；`rawPayload` 原样往返 |
| 1.12 | 配置事务 | backup→modify→validate→rollback 全路径；并发修改检测；幂等（连续 configure 两次结果相同） |

### M2 — Bridge 进程与 shim

| # | 任务 | 验收 |
|---|---|---|
| 2.1 | `agentpet-hook` CLI | 冷启动 < 5ms（实测）；App 未运行 → exit 0 |
| 2.2 | shim 采集 `getppid()` / TTY | 能从 hook 上下文拿到 Agent PID |
| 2.3 | `BridgeServer` UDS 监听 | 并发 100 连接不丢事件；畸形 JSON 不崩溃 |
| 2.4 | Agent 崩溃隔离 | 单 Agent 投递异常不影响其他 Agent |

### M3 — Pet 渲染

| # | 任务 | 验收 |
|---|---|---|
| 3.1 | `AnimationResolver` + `FrameScheduler` | 帧序列与 §3.6 表一致；`once` 型播完回 idle |
| 3.2 | `NSPanel` 浮动窗口 | 透明/无边框/不抢焦点/多显示器/位置持久化 |
| 3.3 | 拖动与 Reduced Motion | —— |

### M4 — Pet Manager UI

> **2026-09-13**：4.2 / 4.3 已随自有存储一起删除；4.1 变为只读列表（Codex 的 pet 目录）+ 动画预览。

| # | 任务 | 验收 |
|---|---|---|
| 4.1 | Installed 列表 + 动画预览 | 预览与桌面渲染用同一 resolver（§8.3 要求） |
| 4.2 | Import（folder / zip） | 非法包给出具体错误 |
| 4.3 | Upgrade / Uninstall | 升级失败 rollback；卸载不删源目录 |

### M5 — Agent Integrations UI

| # | 任务 | 验收 |
|---|---|---|
| 5.1 | 检测 + 状态展示 | 4 个 Agent 都能检出（本机全部已安装） |
| 5.2 | 一键 Configure | Claude Code / Grok 写 config；幂等；可回滚 |
| 5.3 | Test Event | 合成事件走通 Bridge→Pet |
| 5.4 | Remove Integration | 精确移除，不误删用户自己的 hook |

### M6 — Activity Center

| # | 任务 | 验收 |
|---|---|---|
| 6.1 | 列表 + 聚合展示 | 多 Agent 并发正确聚合 |
| 6.2 | 点击 → `open(cwd)` | v0.1 用降级行为（见 §3.3） |

---

## 5. 对方案的总体判断

**架构分层是对的**，`Agent → AgentEvent → Activity → PetIntent → Animation` 这条链每一段都可独立测试，这是好设计。

**但方案把 60% 的篇幅花在"有哪些功能"，而不是"功能怎么实现"。** 具体表现为：状态映射、播放参数、优先级数值、事务语义、shim 契约——这些**决定能不能跑起来**的东西全部缺失，而 GUI 的按钮清单写得非常细。

**最需要警惕的一点**：方案的措辞给人一种"先把 UI 画出来，逻辑自然就有了"的倾向（§17 GUI 信息架构占了整整一节，且比 §11 Activity Engine 更详细）。对这类项目这是**反的**——Pet 的所有难度都在 Activity Engine 的数值调优和桥接的可靠性上，UI 是最容易的部分。

**建议的推进顺序因此与方案 §22 的 P0-P6 不同**：先做 M1（纯逻辑 + 测试），把状态映射、优先级数值、事务语义用测试固化下来，再动 UI。方案 §22 把 `Pet State Machine` 放在 P0、把 `Activity Engine` 放在 P2，但实际上**两者是同一个问题的两半，应当一起做**——否则 P0 的状态机会因为没有优先级规则而无法确定输入。

---

## 6. 待验证问题（更新版）

替代方案 §26：

| # | 问题 | 状态 |
|---|---|---|
| 1 | Claude Code hooks 的确切事件名与 payload schema | 研究进行中 |
| 2 | Codex `notify` 传递的参数集（`turn-ended` 之外还有什么） | 研究进行中 |
| 3 | Codex app-server IPC（`~/.codex/ipc/ipc.sock`）能否作为被动事件源 | **未验证**，可能是最佳路径 |
| 4 | V2 atlas 的 row 9/10 是什么动画 | **未验证**，需样本 |
| 5 | shim 的 `getppid()` 是否稳定指向 Agent 主进程 | **未验证**，需实验 |
| 6 | Grok hook 支持的事件全名（文档只举例了 `PreToolUse`） | 待确认 |
| 7 | Pi 扩展投递事件的实际延迟开销 | 待确认 |

原方案的 Q1/Q3/Q4/Q5/Q6 已由本文档 §2.1 / §3.1 / §3.3 部分回答或转化。
