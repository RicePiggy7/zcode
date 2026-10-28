---
name: zcode
description: 将编码、代码库探索、实现、评审和验证任务委托给持久化 ZCode CLI Agent。仅当用户明确要求"用 ZCode""让 ZCode 执行"，或要求继续某个 ZCode Agent 任务时使用。
---

# ZCode CLI Agent

命令中的 `SKILL_DIR` 为当前已安装 zcode Skill 的绝对目录，不是固定宿主路径。

## 核心规则

- 通过内置包装脚本调用 ZCode，不要直接执行 `zcode -p`。包装脚本通过 `zcode app-server` 协议驱动 ZCode，负责完成模型握手、显示有效进度、记录会话 ID，并生成精简的 Markdown 结果。
- 常规调用不选择或传递模型与思考强度，由本机 ZCode 配置决定；包装脚本会自动同步本机账号的可用模型并选择默认模型。
- 每个任务先调用一次包装脚本。成功后读取 `output_path`，检查工作区结果，再判断是否需要继续同一会话。
- 委托提示词应包含目标、完成标准、约束和必要背景，不要规定每一个实现步骤，也不要粘贴大段文件内容。
- 使用 `--file` 提供 1–4 个重要入口文件，其余路径让 ZCode 自己探索。
- 调用方仍负责范围、安全和最终验收。

## 委托契约

每次只委托一个边界清楚的任务。提示词应简短覆盖：

- 目标：要修改或查明什么，以及明确不应改动的范围。
- 完成标准：预期行为、必须覆盖的边界情况。
- 验证：从仓库配置中确认真实的测试、检查或构建命令，不要只写"运行测试"。
- 安全边界：不执行 `git add`、`git commit`，不顺手重构无关代码。
- 最终报告：说明改动与原因、涉及文件、验证结果，以及仍需决定或未完成的事项。

缺少的仓库事实应先查找；无法确认时明确报告，不要猜测。评审或诊断任务要求结论引用代码证据，并区分事实与推断。

## 包装脚本

macOS 与 Linux：

```text
"$SKILL_DIR"/scripts/ask_zcode.sh
```

`~/.claude/skills/zcode` 可以作为兼容软链接指向同一个 Skill。

## 常用调用

新任务：

```bash
"$SKILL_DIR"/scripts/ask_zcode.sh "实现请求的改动"
```

指定工作区和入口文件：

```bash
"$SKILL_DIR"/scripts/ask_zcode.sh "重构这些组件并完成验证" \
  --workspace "/path/to/repo" \
  --file "src/components/UserList.tsx" \
  --file "src/components/UserDetail.tsx"
```

探索或评审：

```bash
"$SKILL_DIR"/scripts/ask_zcode.sh "追踪当前请求路径并引用文件和行号" \
  --workspace "/path/to/repo" \
  --read-only
```

继续已有会话：

```bash
"$SKILL_DIR"/scripts/ask_zcode.sh "继续修复刚才发现的问题" \
  --session <session_id>
```

附加图片：

```bash
"$SKILL_DIR"/scripts/ask_zcode.sh "比较截图与当前实现" \
  --image "/path/to/screenshot.png"
```

## 工作流程

1. 读取足够的本地上下文，明确目标和重要限制。
2. 默认以 `yolo`（最高权限）模式运行 ZCode；只有用户明确要求限制权限时，才为新会话指定 `--read-only`。
3. 使用包装脚本派发一段聚焦的提示词，通常控制在 500 字以内。
4. 读取脚本返回的 `output_path`。
5. 先检查测试是否被删除、跳过或弱化，再检查工作区改动是否越界。
6. 重新运行真实验证命令；ZCode 的"测试通过"只是报告，不能替代调用方验收。
7. 检查硬编码成功结果、吞掉异常、未经确认的 API、死代码和无调用方的抽象。
8. 需要返工时继续原会话，只发送新发现和修正要求，不重复整个任务。

包装脚本通过自动应答协议内的授权请求，使 ZCode 在 `yolo` 模式下不受逐项审批限制；交互式提问（AskUserQuestion、计划确认）会被自动拒绝，因此委托提示词必须自足，不依赖追问。调用方仍须检查 ZCode 的改动与验证结果。

## 思考强度

常规调用不要指定思考强度，由本机 ZCode 配置决定（GLM 模型默认档位由 Provider 配置给出）。确有需要时通过环境变量覆盖：

- `ZCODE_SKILL_MODEL=providerId/modelId`：固定模型，档位走本机默认。
- `ZCODE_SKILL_MODEL=providerId/modelId$level`：同时指定思考档位（如 `high`、`max`）。

不要仅因为任务描述较长就自动使用 `max`；先收窄目标和上下文。

## 输出

成功后脚本输出：

```text
session_id=<sess_...>
runtime=app-server
output_path=<path>
result_path=<path>
events_path=<path>
elapsed=<seconds>s
```

Markdown 结果包含：

- `## Summary`：ZCode 的最终结论。
- `## Details`：工具调用及其有效输出；纯读取与搜索会被省略。
- 耗时、工具调用数和可用的 token 使用信息。

每次运行使用独立目录，避免并行任务覆盖结果。`result_path` 是原子写入的结构化状态，包含 `completed` 或 `failed`、退出码、运行环境、会话 ID、最终消息、耗时及错误尾部；`events_path` 保留会话事件 JSONL，`protocol.log` 保留协议原始帧，便于失败诊断和恢复。调用方平时只需读取 `output_path`，出现异常时再读取其余文件。

## 图片

`--image` 通过会话附件发送给 ZCode，支持 png/jpg/gif/webp。

## 对外参数

- `--workspace <path>`：工作目录，默认使用当前目录。
- `--file <path>`：优先入口文件，可重复使用。
- `--image <path>`：附加图片，可重复使用。
- `--session <id>`：继续已有会话。
- `--read-only`：创建只读会话（plan 模式，不改文件）。
- `--mode <mode>`：显式指定权限模式（build/edit/plan/yolo/guarded），常规调用不要传递。
- `--notify`：长任务结束后发送桌面通知。
- `--output <path>`：指定 Markdown 结果路径。

## 会话约束

续接会话保留原工作区上下文与模型配置。`--read-only` 不能与 `--session` 同时使用；需要受限权限时开启新会话。续接会话使用本机默认 ZCode 配置。

## 失败处理

- 非零退出码或 `turn.failed` 事件都视为失败。
- 失败运行也会输出 `result_path`、`events_path` 与 `protocol_path`；先读取结构化错误和事件，再决定缩小任务、修正配置或续接会话。
- 会话没有可用模型时，脚本会提示设置 `ZCODE_SKILL_MODEL`；通常说明共享凭据存储不可读或桌面端未登录。
- 凭据为 `enc:v1:` 加密格式时需要 `node`（zcode CLI 本身的依赖）参与解密。
- Skill 或插件加载警告通常不影响任务，除非 ZCode 回合本身失败。

## 环境变量

- `ZCODE_BIN`：zcode CLI 路径，默认 `zcode`。
- `ZCODE_SKILL_MODEL`：`providerId/modelId[$level]`，固定模型与思考档位。
- `ZCODE_SKILL_TIMEOUT`：回合超时秒数，默认 1800。
- `ZCODE_SKILL_CREDENTIALS`：共享凭据存储路径，默认 `~/.zcode/v2/credentials.json`。
- `ZCODE_CREDENTIAL_SECRET`：凭据解密密钥，仅当本机未使用默认回退方案时需要。

## 持久化默认值

惯用的模型与超时可以写入配置文件，避免每次显式指定：

```bash
~/.config/zcode-skill/env
```

格式为 KEY=VALUE（支持 `#` 注释与引号），常用键为 `ZCODE_SKILL_MODEL` 与 `ZCODE_SKILL_TIMEOUT`。优先级为：调用方环境变量 > 配置文件 > 内置默认。配置文件里的模型固定值只作用于新会话；续接会话始终保留自己的模型，除非在调用环境中显式 export `ZCODE_SKILL_MODEL`。路径可用 `ZCODE_SKILL_ENV_FILE` 覆盖。
