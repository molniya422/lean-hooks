<h1 align="center">lean-hooks</h1>

<p align="center">
  <strong>给你的 Claude Code 装上跨会话记忆 + 自我进化 + 循环治理</strong>
</p>

<p align="center">
  便携、零依赖的自动化钩子框架——Hook、记忆、技能优化、多Agent检测、语义注意力、循环工程，一次安装全搞定
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue.svg?style=for-the-badge" alt="MIT License"></a>
  <a href="https://www.python.org/"><img src="https://img.shields.io/badge/Python-3.8+-green.svg?style=for-the-badge&logo=python&logoColor=white" alt="Python 3.8+"></a>
  <a href="https://github.com/molniya422/lean-hooks/stargazers"><img src="https://img.shields.io/github/stars/molniya422/lean-hooks?style=for-the-badge" alt="GitHub Stars"></a>
</p>

<p align="center">
  <a href="#快速上手">快速开始</a> · <a href="#三大自治反馈环路">工作原理</a> · <a href="#8-种循环模式">循环模式</a> · <a href="docs/ARCHITECTURE.md">架构文档</a>
</p>

---

## 为什么需要 lean-hooks？

Claude Code 有 Hook 事件（`SessionStart`、`UserPromptSubmit`、`Stop`），但没有内置的跨会话记忆、自我进化、或自动循环治理能力。lean-hooks 填补了这个空白：

- **永不重复工作** — 跨会话记忆 + SQLite 会话日志，下次启动自动注入历史上下文
- **越用越好** — 行为质量反馈环路，P/R/F1/EMA 指标实时追踪，阈值自动调节
- **自动检测复杂度** — 两阶段启发式评分，该并行时建议并行，不该并行时绝不干扰
- **治理自动化循环** — 预算杀手开关、9 种故障模式检测、L0→L3 就绪等级晋升
- **语义技能匹配** — ONNX 嵌入层找到最合适的 Skill（可选）

所有 Hook **只注入上下文**——它们从不直接执行 AI 操作。AI 保留独立判断权。

---

## 快速上手

```bash
git clone https://github.com/molniya422/lean-hooks.git
cd lean-hooks

# Linux / macOS / WSL
./install.sh

# Windows PowerShell
.\install.ps1

# 完成。重启 Claude Code 即可生效。
```

无需装 Python 包，无需 Node 依赖。只要 bash + Python 3.8+。

> 📋 安装器会自动：
> 1. 复制 Hook 脚本到 `~/.claude/harness/`
> 2. 复制模板文件（反馈、记忆、规则）
> 3. 合并配置（已有 `settings.json` / `CLAUDE.md` 不会覆盖）
> 4. 运行 `db-migrate --dry-run` 验证数据库

---

## 三大自治反馈环路

三个环路各自独立运行，通过 Hook 事件自动串联：

```
会话启动 ──► 健康检查 + 安全审计 + 记忆注入 + F1 告警 + 预算警告

用户发消息 ──► 完成关键词检测 + 并行 Agent 建议 + 语义技能匹配

会话结束 ──► 训练指标采集 (P/R/F1/EMA) + 循环故障扫描 + 预算跟踪
```

### 环路 1：记忆

```
有效会话 ──► auto-summary.py ──► SQLite session_logs
用户说"记住" ──► memory/*.md     ──► MEMORY.md 索引
下次会话      ──► 注入记忆提示 ──► AI 先搜索，不重复劳动
```

**双层记忆架构：**
- **Tier 1（自动）**：每个有实质性工作的会话自动写入一句摘要到 SQLite
- **Tier 2（手动）**：用户明确要求"记住"时，写入结构化 Markdown 文件

### 环路 2：TrainingLoop

```
AI 观察到质量问题 ──► 写入 feedback.md（3 个维度）
会话结束           ──► training-collect.py 计算 P/R/F1/EMA/loss
F1 < 目标值（3+ 会话）──► 自动调整多 Agent 阈值
下次会话启动       ──► F1 告警注入 ──► AI 自我纠正
```

三个训练维度：

| 维度 | 度量什么 | 反馈类型 |
|------|---------|---------|
| **SkillOpt** | Skill 触发准确性 | 命中 / 漏报 / 误报 |
| **MultiAgentOpt** | Agent 调度准确性 | 命中 / 漏报 / 误报 |
| **ToolCallOpt** | 工具调用质量 | 正面 / 负面 / 错失机会 |

损失函数：`L = [(1-P)² + (1-R)²] / [(1-P)+(1-R)+ε] + γ·complexity`

**v2.2 安全门控：** 系统初始为 L0（仅报告）模式。自动调整在全局 ≥50 条反馈信号、单维度 ≥10 条信号后才解锁。零信号时返回 `has_data=False`（不会虚空报告 P=R=F1=1.0）。

### 环路 3：循环工程

```
循环执行    ──► run-logger.py 记录审计轨迹
状态变化    ──► state-manager.py 每模式独立状态
Token 消耗   ──► budget-tracker.py 日/周额度上限
会话结束    ──► failure-detector.py 扫描 9 种故障模式
下次启动    ──► 预算警告 + 关键故障告警
```

---

## 架构一览

```
~/.claude/
├── lean-hooks.toml              ← 每个 Hook 的粒度配置（超时、启用、事件）
├── settings.json                ← Hook 链接入点
├── CLAUDE.md                    ← 行为规则 + Skill 触发表
│
├── harness/                     ← 所有 Hook 脚本
│   ├── env.sh                   ← Python/路径自动检测（双布局支持）
│   ├── error-handler.sh         ← 超时 + 非阻塞错误日志
│   ├── plugin-loader.sh         ← 插件自动发现与注册
│   │
│   ├── health-check.sh          ← 9 项完整性校验
│   ├── security-audit.sh        ← .env / 明文密钥扫描
│   ├── session-start-inject.sh  ← 7 块上下文注入
│   ├── post-task-detect.sh      ← ~60 个完成关键词检测
│   ├── multiagent-detect.sh     ← 两阶段并行 Agent 评分
│   ├── training-collect.sh/py   ← 3 维 EMA 指标引擎
│   │
│   ├── auto-summary.py          ← 会话摘要 → SQLite
│   ├── data-lifecycle.py        ← MEMORY.md 轮转 + 归档
│   ├── weighted-scoring.py      ← 时衰减 F1 + 趋势分析
│   ├── stats.py                 ← 查询 CLI
│   ├── test_all.py              ← 集成测试套件
│   ├── db-migrate.py            ← SQLite Schema 迁移
│   ├── role-collab-runner.py    ← 多角色并行审查编排器
│   ├── skill-attention.py       ← ONNX 语义技能匹配（可选）
│   ├── skill-attention-query.sh ← 语义匹配 Hook 封装
│   │
│   │  // 循环工程脚本
│   ├── loop-state-manager.py
│   ├── loop-run-logger.py
│   ├── loop-budget-tracker.py
│   ├── loop-readiness-audit.py
│   ├── loop-failure-detector.py
│   └── loop-checklist-validator.py
│
├── hooks/                       ← 插件目录（放入即注册）
├── training-loop/               ← 反馈 + 指标
│   ├── feedback.md
│   ├── meta.json
│   ├── metrics_core.py          ← 共享计算模块 (v2.2)
│   ├── adaptive-threshold.py    ← 独立优化器 (v2.2)
│   ├── metrics-design.md
│   └── metrics-schema.json
│
├── loop-engineering/            ← 循环治理
│   ├── LOOP.md                  ← 活跃循环 + 协调
│   ├── safety.md                ← 路径拒绝表 + 自动合并规则
│   ├── patterns/registry.yaml   ← 8 个模式定义
│   ├── states/                  ← 每模式可变状态（8 个文件）
│   ├── budget.json
│   ├── run-log.jsonl
│   ├── failure-report.json
│   └── archive/
│
├── data/                        ← SQLite 数据库
├── memory/                      ← MEMORY.md + 每项目文件
└── ERRORS.md                    ← 自动生成的错误日志
```

---

## Hook 链

| 事件 | 脚本 | 做什么 |
|------|------|--------|
| **SessionStart** | `health-check.sh` | 9 项完整性校验 |
| | `security-audit.sh` | .env / gitignore 扫描 |
| | `session-start-inject.sh` | 记忆索引 + 3 步检查清单 + F1 告警 + 循环故障告警 |
| **UserPromptSubmit** | `post-task-detect.sh` | 检测 ~60 个完成关键词 → 写入提醒 |
| | `multiagent-detect.sh` | 两阶段评分 → 并行 Agent 建议 |
| | `skill-attention-query.sh` | 语义技能匹配（可选，默认关闭） |
| **Stop** | `training-collect.sh` | 解析反馈 → 计算 EMA/F1 → 更新 meta.json |

---

## 核心特性

### 非阻塞错误处理

```
[Hook] ──► timeout_wrap ──► 成功 ──► 继续运行
                          └── 失败 ──► ERRORS.md ──► 继续运行
```

没有任何 Hook 会阻塞你的会话。超时可按 Hook 独立配置（`lean-hooks.toml`）。

### 多 Agent 检测

两阶段启发式：快速关键词过滤（零成本）→ 结构分析（任务动词、文件引用、技术边界）。倾向漏报而非误报。阈值根据 F1 自动收紧/放松。

```bash
# 试运行
echo '{"prompt":"fix auth and refactor login"}' | bash harness/multiagent-detect.sh --dry-run
```

### SkillAttention（可选）

ONNX 语义嵌入层：用户提示 → all-MiniLM-L6-v2 嵌入 → 与预计算技能语料库的余弦相似度 → 按每 Skill 的注意力权重门控。需要设置 `SKILL_ATTENTION_MODEL_DIR` 环境变量。未配置时优雅降级为纯关键词匹配。

**反馈闭环：** 正确触发 +0.02，误报 -0.05，漏报新增提示词 +0.03。

### 插件系统

把 `.sh` 文件丢进 `hooks/`，命名规则 `<Event>[_<Priority>]--<Name>.sh`，即自动注册：

```
hooks/
├── SessionStart_08--loop-budget-check.sh   ← 优先级 8（最先运行）
├── SessionStart_10--custom-health.sh      ← 优先级 10
└── Stop_10--loop-failure-check.sh         ← 优先级 10
```

默认优先级 = 100，数值越小越先执行。通过 `DISABLED_HOOKS` 环境变量或 `lean-hooks.toml` 禁用。

### Stats CLI

```bash
python harness/stats.py                  # 仪表盘总览
python harness/stats.py sessions         # 会话列表
python harness/stats.py hooks            # Hook 错误分析
python harness/stats.py skills           # SkillOpt P/R/F1
python harness/stats.py multiagent       # MultiAgentOpt 分析
python harness/stats.py trends --json    # 机器可读趋势
```

### 数据生命周期

| 数据 | 阈值 | 动作 |
|------|------|------|
| `MEMORY.md` | >64 KB | 轮转到 `archive/` |
| 会话日志 | >90 天 | 归档到 `archive/` |
| `ERRORS.md` | >1 MB | 轮转到 `archive/` |

---

## 8 种循环模式

| 模式 | 节奏 | 风险 | 制造者 | 检验者 |
|------|------|------|--------|--------|
| 每日 Triage | 1 天 | 低 | `issue-triage` | `verification-before-completion` |
| PR 看护 | 5-15 分钟 | 高 | `babysit` | `requesting-code-review` |
| CI 清道夫 | 5-15 分钟 | 极高 | `systematic-debugging` | `verification-before-completion` |
| 依赖清道夫 | 6 小时-1 天 | 中 | `security-guardian` | `verification-before-completion` |
| 变更日志草稿 | 1 天 | 低 | `repo-recap` | `verification-before-completion` |
| 合并后清理 | 1 天-6 小时 | 低 | `finishing-a-development-branch` | `verification-before-completion` |
| Issue Triage | 2 小时-1 天 | 低 | `issue-triage` | `verification-before-completion` |
| 角色协同 | 按需 | 中 | `role-collab` | `verification-before-completion` |

每个模式从 **L0**（草案）→ **L1**（仅报告）→ **L2**（辅助修复 + 人工关卡）→ **L3**（无人值守）逐级晋升。晋升条件：零关键故障、就绪审计得分 ≥65（L2）或 ≥85（L3）、人工明确批准。

### 9 种故障模式检测

`infinite_fix_loop` · `state_rot` · `verifier_theater` · `notification_fatigue` · `token_burn` · `over_reach` · `escalation_failure` · `dead_loop` · `budget_blowout`

---

## 环境变量

| 变量 | 默认值 | 用途 |
|------|--------|------|
| `HARNESS_PYTHON` | 自动检测 | 覆盖 Python 解释器 |
| `HARNESS_ROOT` | 自动检测 | 覆盖配置根目录 |
| `DISABLED_HOOKS` | — | 逗号分隔要禁用的 Hook 名 |
| `PROJECT_NAME` | 自动检测 | 按项目覆盖配置 |
| `LOOP_BUDGET_EXHAUSTED` | — | 设为 `1` 阻止所有循环执行 |
| `SKILL_ATTENTION_MODEL_DIR` | — | ONNX 模型目录（启用 SkillAttention） |
| `SKILL_ATTENTION_PYTHON` | `$PY` | 带有 onnxruntime + tokenizers 的 Python |
| `CLAUDE_MEM_DATA_DIR` | 自动检测 | 覆盖 claude-mem 数据库目录 |

---

## 会话生命周期

```
会话启动
├─ health-check.sh: 9 项校验
├─ session-start-inject.sh: 检查清单 + F1 告警 + 循环告警
├─ [插件] loop-budget-check.sh: 预算状态
│
用户消息
├─ post-task-detect.sh: 是否完成？→ 写入提醒
├─ multiagent-detect.sh: 复杂度？→ Agent 建议
├─ skill-attention-query.sh: 语义技能匹配（如已启用）
│
... AI 工作 ...
│
会话结束
├─ training-collect.sh: 计算 EMA/F1 → 更新 meta.json
├─ [插件] loop-failure-check.sh: 扫描 9 种故障模式
```

---

## 系统要求

- Claude Code CLI v2.1+
- Python 3.8+（Hook 内联脚本使用）
- Bash（Linux / macOS / WSL）或 Git Bash（Windows）

**可选**（SkillAttention）：
- `onnxruntime` + `tokenizers` Python 包
- all-MiniLM-L6-v2 ONNX 模型 → 设置 `SKILL_ATTENTION_MODEL_DIR`

---

## 致谢

- **[Loop Engineering](https://github.com/cobusgreyling/loop-engineering)** — 治理原语、就绪等级、故障模式目录
- **[Everything Claude Code](https://github.com/affaan-m/ECC)** — Hook 运行控制、安全审计模式
- **[LangGraph](https://github.com/langchain-ai/langgraph)** — 有状态 Agent 编排
- **[claude-mem](https://github.com/thedotmack/claude-mem)** — SQLite 跨会话记忆
- **[CodeGraphContext](https://github.com/CodeGraphContext/CodeGraphContext)** — tree-sitter 知识图谱 MCP 服务
- **Claude Code** — 让这一切成为可能的 Hook 基础设施

**Vibe Coded**: 构思和方向来自作者，每一行代码由 Claude Code 编写。

## License

[MIT](LICENSE)
