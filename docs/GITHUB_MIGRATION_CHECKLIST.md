# SymAFL GitHub 仓库迁移检查清单

> **✅ 迁移已于 2026-07-25 完成。以下为计划原文；实际执行与计划的差异记录于此：**
>
> 1. **实际仓库名**：`SymAFL`（集成）、`SymAFL-AFLplusplus`、`SymAFL-RSan`、`SymAFL-Symcc`（均为 private）。
> 2. **symcc 已平直化**：symcc-rt 与 qsym 未使用独立 fork，而是 vendor 进 `SymAFL-Symcc`（提交信息含溯源 SHA；排除 `third_party/z3` 与 200MB Intel Pin 工具链）。因此无需 `SymAFL-Symcc-rt` / `SymAFL-Qsym` 仓库。
> 3. **NTFS/fuseblk 注意事项**：源码盘为 NTFS，`chmod` 无效，三个组件仓库均已设置 `core.filemode=false`；superproject 中脚本可执行位用 `git update-index --chmod=+x` 显式登记。
> 4. **AFL++ 额外清理**：`tmp/`（410 个 VS Code Remote 缓存）与 `pctTest`（本地二进制）已取消追踪；`GNUmakefile`（`-L.`）与 `src/afl-fuzz-init.c`（outdir SHM `strcpy`）两个真实修复已单独成提交保留。
> 5. **备份位置**：`/media/hahafish/Data/ForUbuntu/backup/SymAFL/`（含完整工作区副本、bundles、嵌套 gitdir、证据与 checksums）。
> 6. **基线 SHA**：AFLplusplus `7a995cb8`、RSan `3403b14db`、symcc `a5fa0858`，superproject 基线见 `config/compatibility.yaml`；端到端冒烟（fixture 构建 + `afl-fuzz -K` + `.pct-*` 产出）已通过。
>
> ---
>
> **目标**：将当前三个独立开发仓库（AFL++、RSan、SymCC）与根目录的集成脚本、测试和文档组织为“**三个组件 fork + 一个 SymAFL 集成仓库（Git submodule manifest）**”。
>
> **迁移原则**：先保护已有历史和实验资产，再建立干净基线；先验证跨模块组合，再冻结论文/实验版本。禁止把本地构建目录、AFL 输出、临时队列和权限位漂移误作为源码成果提交。

---

## 0. 目标仓库与职责

在 GitHub 账号 `explorerlxy` 下准备以下仓库。建议将前三个保留为独立 fork，第四个作为项目主入口。

| 仓库 | 建议可见性 | 角色 | 应追踪内容 | 不应追踪内容 |
|---|---|---|---|---|
| `AFLplusplus` | Private（开发期）或 Public（发布后） | SymAFL 修改的 AFL++ fork | PCBT、`-K`、队列逻辑、focus fuzzing、AFL++ 模块测试 | AFL output、队列、crash、PCBT snapshot、构建产物 |
| `rangesanitizer` | Private 或 Public | RSan/LLVM/TCMalloc/linker fork | SafeStack、RSan、集成 SymCC CodeGen pass、模块测试 | LLVM build、TCMalloc build、临时链接产物 |
| `symcc` | Private 或 Public | SymCC runtime fork | QSYM/Simple runtime、SHM、`.pct-*` 持久化、runtime 测试 | CMake build、Ninja 文件、运行日志、临时 target |
| `SymAFL` | **项目主入口** | 集成 manifest 仓库 | submodule SHA、脚本、配置、文档、跨模块测试、实验协议、CI | 子模块源码副本、构建输出、benchmark 原始海量输出 |

推荐的公开策略：开发期全部 private；形成 `paper-a-submission` 的可复现 tag 后，按论文/开源计划将 `SymAFL` 及必要组件公开。若上游许可证、子模块许可或未公开漏洞样例有约束，公开前先完成许可证和样例脱敏审计。

---

## 1. 迁移前的不可跳过安全与备份步骤

### 1.1 轮换 GitHub 凭据

- [ ] 在 GitHub 设置中**立即撤销并重新创建**曾写入 Git remote URL 的 Personal Access Token（PAT）。
- [ ] 新 token 使用最小权限；若仅推送私有仓库，优先使用 fine-grained token 并只授权目标仓库。
- [ ] 不再在 `origin` URL、脚本、文档、shell history、CI YAML 或实验日志中出现 token。
- [ ] 所有 remote 改为 SSH URL，例如：

```bash
git remote set-url origin git@github.com:explorerlxy/AFLplusplus.git
git remote set-url origin git@github.com:explorerlxy/rangesanitizer.git
git remote set-url origin git@github.com:explorerlxy/symcc.git
```

- [ ] 执行 `ssh -T git@github.com`，确认 SSH key 可用；不要把 private key 纳入任何仓库。

### 1.2 保护当前历史、未提交修改和实验材料

在每个组件仓库分别完成以下步骤，**不应先执行 reset、clean、checkout -- . 或删除构建目录**。

```bash
# 在 AFLplusplus、RSan、symcc 中分别运行
git status --short --branch
git log --oneline --decorate -20
git remote -v
git bundle create ../<repo>-pre-migration.bundle --all
git ls-files --others --exclude-standard > ../<repo>-untracked-files.txt
```

- [ ] 将三个 `*.bundle` 文件复制到不依赖当前工作区的备份位置。
- [ ] 将种子、AFL 输出、崩溃样例、`.pct-*`、实验 CSV、绘图脚本及测试日志单独打包，并记录 SHA-256。
- [ ] 为每个暂存或未跟踪的**真实源码改动**建立 `WIP` 分支或 patch；不将构建输出混入该提交。
- [ ] 确认任何历史实验仍至少有一份可读取副本。

### 1.3 当前工作区特别检查

当前已观察到 AFL++ 和 SymCC 有大量状态变化，其中主要包含文件权限位漂移、构建/测试产物变化或删除；RSan 相对干净。处理前逐项确认：

- [ ] AFL++：区分真正的 SymAFL 源码变更、`test/symccTest/` 生成物、子模块未初始化状态和普遍 `100644 → 100755` 权限漂移。
- [ ] SymCC：检查历史上被错误追踪的 CMake/Ninja build 目录；在新的清理提交中删除这些**确认属于生成物**的文件，并补充 `.gitignore`。
- [ ] 不使用全局 `chmod` 或批量恢复权限。先核实哪些脚本本应可执行。
- [ ] 不用 `git clean -fdx` 清理任何组件，除非 bundle、patch、实验数据备份均已验证。

建议检查命令：

```bash
git diff --summary
git status --porcelain=v1
git ls-files | grep -E '(^|/)(CMakeFiles|build|llvm-build|\.ninja_|CMakeCache\.txt)(/|$)'
git check-ignore -v <candidate-file>
```

---

## 2. 三个组件仓库的标准化

### 2.1 上游与 fork 关系

| 组件 | `origin` | `upstream` | 策略 |
|---|---|---|---|
| AFL++ | `explorerlxy/AFLplusplus` | `AFLplusplus/AFLplusplus` | 保留 upstream；定期同步上游并在独立 PR/分支中处理冲突 |
| RSan | `explorerlxy/rangesanitizer` | 建议添加其实际上游仓库 | 记录 RSan 原始基线；LLVM/TCMalloc 的深层来源只在文档中记录，不直接把所有来源设为 Git remote |
| SymCC | `explorerlxy/symcc` | `eurecom-s3/symcc` | 保留 upstream；SymAFL 使用 RSan 内集成的 compiler pass，`symcc/compiler/` 不作为目标插桩修改位置 |

- [ ] 为 RSan 添加实际原始上游 remote；若无可用上游，创建 `upstream-base` tag 指向导入时基线提交。
- [ ] 禁止向上游 remote push；确保 `upstream` 为只读 fetch URL 或在 GitHub 侧无写权限。
- [ ] 在每个 fork 的 README 或 `UPSTREAM.md` 记录：上游 URL、基线 commit、SymAFL 差异类别、同步日期、已知冲突点。

### 2.2 建议分支结构

所有仓库统一采用如下分层。若不希望改历史分支名，可从当前稳定提交创建这些分支。

```text
main                         已验证的 SymAFL 稳定主线
release/vX.Y                 冻结的论文、实验或补丁维护线
feature/<topic>              短期功能开发
fix/<issue>                  缺陷修复
experiment/<hypothesis>      可丢弃的研究性实验
upstream-sync/<date-or-tag>  上游同步与冲突处理
```

- [ ] 从每个已验证基线创建并推送 `main`。
- [ ] 不再将开发主线分散为 `master`、`SymAFL`、`SymAFL-RSan` 等多个语义不一致的长期分支。
- [ ] 当前旧分支保留为只读历史分支，并在 README 写明其替代关系。
- [ ] 每项跨模块功能使用一致 topic，例如 `feature/trace-abi-v2` 同时存在于 AFL++ 和 SymCC。

### 2.3 组件级提交规范

- [ ] 一个提交只覆盖一个可解释变化：算法、ABI、构建、测试或文档，不混杂生成物。
- [ ] 提交消息使用 Conventional Commit 或相同语义前缀：`feat:`、`fix:`、`test:`、`docs:`、`build:`、`refactor:`。
- [ ] 任何变更 SHM 名、`.pct-*` 格式、`insert_depth` 语义或 PCBT API 的提交，都必须包含兼容性版本说明和跨模块测试更新。
- [ ] 每个真实功能在合入 `main` 前完成 Pull Request，即使只有一位开发者，也便于保留设计说明、测试结果和可回滚点。

---

## 3. 创建 SymAFL 集成仓库

### 3.1 推荐目录与责任划分

```text
SymAFL/
├── AFLplusplus/                  # submodule，固定 SHA
├── RSan/                         # submodule，固定 SHA
├── symcc/                        # submodule，固定 SHA
├── scripts/                      # symafl-env / build / fuzz / runner
├── config/
│   ├── compatibility.yaml         # 三模块组合及 ABI 契约
│   ├── toolchains/
│   └── experiments/
├── tests/
│   ├── smoke/
│   ├── integration/
│   ├── regression/
│   └── fixtures/
├── benchmarks/
│   ├── manifests/
│   └── seeds/
├── docs/
│   ├── architecture/
│   ├── theory/
│   └── experiment-protocols/
├── results/README.md              # 只追踪说明与 manifest，不追踪海量原始输出
├── .github/
│   ├── workflows/
│   ├── pull_request_template.md
│   └── ISSUE_TEMPLATE/
├── .gitmodules
├── README.md
├── VERSION
└── GITHUB_MIGRATION_CHECKLIST.md
```

- [ ] 根仓库仅存放集成层资产，**不复制**三个组件的完整源码。
- [ ] 现有根目录的 `symafl-env.sh`、`symafl-build`、`symafl-fuzz`、`symafl_runner`、主 README、理论文档、测试流程文档迁入上述目录或根目录。
- [ ] 在集成仓库中维护相对路径，逐步移除 `/home/hahafish/SymAFL` 等个人绝对路径依赖。
- [ ] `RSan/env.sh` 仍可能需要兼容旧路径；在集成脚本中显式封装其副作用，避免调用方 cwd 被意外改变。

### 3.2 安全创建流程

建议在**新的干净目录**创建集成仓库，而不是直接在当前含三个嵌套 Git 仓库的目录运行 `git init`。

```bash
# 1. 在 GitHub 创建空的 explorerlxy/SymAFL 仓库（不自动创建 README/.gitignore）
# 2. 克隆到新的工作目录
git clone git@github.com:explorerlxy/SymAFL.git /path/to/SymAFL-integrated
cd /path/to/SymAFL-integrated

# 3. 添加三个已清理并已推送的组件作为 submodule
git submodule add -b main git@github.com:explorerlxy/AFLplusplus.git AFLplusplus
git submodule add -b main git@github.com:explorerlxy/rangesanitizer.git RSan
git submodule add -b main git@github.com:explorerlxy/symcc.git symcc

git submodule update --init --recursive
```

- [ ] 不使用 `git submodule add --force` 接管当前嵌套仓库目录。
- [ ] 不在三个组件存在未确认变更时移动或删除原目录。
- [ ] 先验证三个独立仓库均能从 GitHub 全新 clone 和构建，再添加为 submodule。
- [ ] 首个集成提交应只包含 `.gitmodules`、固定的 submodule SHA、脚本/文档/测试与 `compatibility.yaml`。

### 3.3 克隆与更新规范

所有使用者采用：

```bash
git clone --recurse-submodules git@github.com:explorerlxy/SymAFL.git
cd SymAFL
git submodule update --init --recursive
```

切换到任一集成 tag 或分支后必须执行：

```bash
git submodule sync --recursive
git submodule update --init --recursive
```

- [ ] 文档明确：集成仓库固定的是**精确 commit SHA**，不是浮动追踪组件 `main`。
- [ ] 不在日常开发中执行 `git submodule update --remote`；组件更新必须通过显式 PR 更新 submodule SHA。

---

## 4. 跨模块兼容性 manifest

在根仓库创建 `config/compatibility.yaml`。首次提交可使用以下模板：

```yaml
schema_version: 1
symafl_version: 0.1.0
protocol_version: symafl-abi-v1
trace_format_version: pct-smtlib-v1

platform:
  architecture: x86_64
  operating_system: linux
  llvm_version: "16.0.6"
  runtime_backend: qsym

components:
  aflplusplus:
    repository: explorerlxy/AFLplusplus
    commit: "<exact-submodule-sha>"
    pcbt_api: pcbt-api-v1
  rsan:
    repository: explorerlxy/rangesanitizer
    commit: "<exact-submodule-sha>"
    compiler_contract: rsan-symcc-lto-v1
  symcc:
    repository: explorerlxy/symcc
    commit: "<exact-submodule-sha>"
    runtime_contract: qsym-shm-v1

contracts:
  required_lto_flags:
    - -flto=full
    - -Wl,-plugin-opt=-enable-symcc
  pass_pipeline:
    - SafeStackLegacyPass
    - SymbolizeLegacyPass
    - StackProtectorPass
  shared_memory_channels:
    - __AFL_SHM_ID
    - __AFL_SHM_OUTDIR_ENV_ID
    - __AFL_SHM_SYMBOLIC_ENV_ID
    - __AFL_SHM_QUEUE_ENTRY_ID
    - __AFL_SHM_INSERT_DEPTH__ID
  trace_artifact: queue/.pct-<queue-entry-id>
  insert_depth_semantics: first-new-solver-assertion-index
```

以下变化必须提升 `protocol_version` 或对应子版本，并更新集成测试：

- [ ] `path_con_tree_*` / `PathConTree.hpp` API；
- [ ] 5 路 SHM 的变量名、类型、初始化和读取时序；
- [ ] `insert_depth` 语义；
- [ ] `.pct-*` 路径、文件名或 SMT-LIB 内容；
- [ ] QSYM 具体/符号模式切换协议；
- [ ] SymCC 与 SafeStack 的 pass 顺序或插桩排除规则；
- [ ] RSan 漏洞检测分支如何进入符号路径约束。

---

## 5. `.gitignore` 与实验数据治理

### 5.1 各组件应覆盖的生成物

| 模块 | 最小忽略类别 |
|---|---|
| AFL++ | `afl-out/`、`queue/`、`crashes/`、`hangs/`、`.pct-*`、`.PathConTree-*`、测试生成二进制、覆盖率/临时日志 |
| RSan | `llvm-build/`、`build/`、`CMakeFiles/`、`CMakeCache.txt`、TCMalloc/linker build、测试二进制、LLVM 临时文件 |
| SymCC | `build/`、`CMakeFiles/`、`.ninja_*`、`CMakeCache.txt`、runtime build、测试生成物、trace/log 文件 |
| 集成仓库 | `results/raw/`、`outputs/`、`afl-out/`、`*.pct-*`、容器 cache、下载依赖、私有 benchmark 二进制 |

- [ ] 对每条 `.gitignore` 规则执行 `git check-ignore -v` 验证。
- [ ] 不忽略真实源文件、最小测试 fixture、实验配置、分析脚本和摘要结果 manifest。
- [ ] 真实 benchmark 原始输出放入对象存储、Zenodo、OSF、机构存储或 GitHub Release asset；Git 仅追踪其下载说明、校验和、配置和结果摘要。

### 5.2 推荐实验目录策略

```text
results/
├── README.md
├── manifests/                 # 纳入 Git：版本、配置、hash、环境
├── summaries/                 # 纳入 Git：聚合 CSV/JSON、图表数据
└── raw/                       # .gitignore：原始 AFL output、trace、崩溃、重日志
```

每次正式实验生成：

```text
results/manifests/<experiment-id>.json
results/summaries/<experiment-id>.csv
results/raw/<experiment-id>/              # 不入 Git
```

manifest 至少包含：集成 tag、三个 submodule SHA、`compatibility.yaml` hash、目标程序/benchmark commit、种子 corpus hash、Z3/LLVM 版本、CPU/RAM/磁盘信息、随机种子、开始/结束时间、命令行与容器镜像 digest。

---

## 6. GitHub 分支保护、PR 与 Issue 规则

### 6.1 保护分支

对所有仓库的 `main` 和 `release/*` 设置：

- [ ] 禁止 force push 与直接删除分支；
- [ ] 要求 Pull Request 合并；
- [ ] 要求通过至少一个 status check；
- [ ] 要求讨论 resolved；
- [ ] 要求线性历史或 squash merge（四仓库选择同一策略）；
- [ ] 只允许维护者创建/删除 release tag；
- [ ] 使用签名 tag 发布正式版本（可选但推荐）。

单人开发可将 required reviewer 设置为 0，但仍坚持 PR 模式和 CI，保留实验与设计决策记录。

### 6.2 Issue 标签

建议统一标签：

```text
component:afl
component:rsan
component:symcc
component:integration
kind:bug
kind:feature
kind:experiment
kind:compatibility
kind:documentation
protocol-change
paper-a
paper-b
needs-reproduction
blocked
```

### 6.3 Pull Request 模板必须包含

- [ ] 修改的组件、问题和假设；
- [ ] 是否改动 PCBT/SHM/trace/ABI 契约；
- [ ] 所涉及组件 commit 或关联 PR；
- [ ] 已运行的模块与集成测试；
- [ ] 对覆盖率、吞吐量、bug finding 或 focus 成功率的预期影响；
- [ ] 是否需要更新 `compatibility.yaml`、实验协议或论文数据；
- [ ] 可复现命令与原始结果路径（若为实验 PR）。

---

## 7. GitHub Actions 分层 CI

### 7.1 每个组件的 PR CI（快速）

| 仓库 | 最低检查 |
|---|---|
| AFL++ | 格式检查、`gmake source-only`、PCBT API 编译、PathConTree focused test |
| RSan | 静态/格式检查、Pass 注册存在性、关键源码编译检查 |
| SymCC | QSYM/Simple runtime build、关键 runtime test、trace fixture 测试 |
| SymAFL | submodule SHA 与 manifest 一致性、ShellCheck、YAML schema、文档链接、测试脚本语法 |

### 7.2 集成仓库合入 `main` 后的构建/冒烟 CI

- [ ] 构建 modified LLVM：`ninja LLVMCodeGen clang lld`；
- [ ] 检查 `createSymCCSymbolizePass`；
- [ ] 构建 QSYM runtime；
- [ ] 使用 `symafl-build --symcc` 编译最小 fixture；
- [ ] 验证 `_sym_notify_basic_block` 与 `__afl_area_ptr`；
- [ ] 验证 skipped SafeStack runtime 不调用 `malloc_symbolized`；
- [ ] 验证有效访问正常返回、OOB/UAF 产生预期 `SIGTRAP`；
- [ ] 验证 QSYM 在具体/符号模式之间正确切换；
- [ ] 验证 `afl-fuzz -K` 创建 SHM、产生 `.pct-*`；
- [ ] 验证 `.pct-*` 被 `InsertTrace()` 消费，PCBT 可以增长；
- [ ] 验证已探索候选能被拒绝、可达未探索分支候选能被接受。

### 7.3 夜间或 release 前 benchmark CI

不应作为普通 PR 的硬阻塞项：

- [ ] 多轮覆盖率与漏洞发现对比；
- [ ] CheckInput 耗时、具体执行次数、筛选接受/拒绝率；
- [ ] PCBT 大小、增量 trace 数、Z3 timeout；
- [ ] focus mode 启动次数、约束—变量闭包规模、突破成功率；
- [ ] 与 AFL++、未筛选 SymCC-AFL 和其他指定基线的可复现比较；
- [ ] 上传摘要结果、manifest、日志校验和；原始大文件存外部制品存储。

---

## 8. 论文与发布线冻结

### 8.1 Paper A：PCBT 预筛选、吞吐量与 non-inferiority

```text
integration branch: paper/a-pcbt-screening
release branch:     release/paper-a
immutable tags:     paper-a-submission, paper-a-camera-ready
```

冻结范围：

- [ ] PCBT 构建、`CheckInput()`、`InsertTrace()`、`insert_depth` 和 `.pct-*` 协议；
- [ ] 预筛选 throughput / reject rate / concrete execution savings；
- [ ] 覆盖率和漏洞发现能力的 non-inferiority 实验；
- [ ] 理论模型、适用条件、assertion 对齐契约及成本模型；
- [ ] 固定 benchmark、种子、容器、统计脚本和原始数据 manifest。

### 8.2 Paper B：动态测试空间发现与漏洞导向优化

```text
integration branch: paper/b-test-space-focus
release branch:     release/paper-b
immutable tags:     paper-b-submission, paper-b-camera-ready
```

冻结范围：

- [ ] test-interface hook；
- [ ] 多阶段测试协议；
- [ ] sanitizer vulnerability detection logic 到 PCBT 分支的映射；
- [ ] 测试空间规约、focus target 选择、表达式—变量闭包；
- [ ] 与 Paper A tag 的受控消融对比。

Paper B 必须以 Paper A 的正式 tag 作为明确 baseline，避免两篇论文的贡献或实验归因交叉不清。

---

## 9. 推荐迁移执行顺序与验收条件

### Phase 0：安全与备份

- [ ] PAT 已撤销并更换，remote 已切换为 SSH；
- [ ] 三个 Git bundle 与未跟踪文件清单已验证；
- [ ] 实验资产完成独立备份和 hash 记录。

### Phase 1：组件清理与基线

- [ ] 每个仓库仅保留确认的源码/测试/文档变更；
- [ ] 构建产物已经从索引移除并纳入 `.gitignore`；
- [ ] 每个组件均可从全新 clone 构建；
- [ ] 每个组件 `main` 已有一条带说明的 `chore: establish clean SymAFL baseline` 提交。

### Phase 2：集成仓库与 submodule

- [ ] `explorerlxy/SymAFL` 已创建；
- [ ] 三个组件以精确 SHA 作为 submodule 加入；
- [ ] `compatibility.yaml` 中 commit 与 `git submodule status` 一致；
- [ ] 新机器可使用 `git clone --recurse-submodules` 获取完整源树。

### Phase 3：可复现集成验证

- [ ] 由全新 clone 执行环境初始化和完整 build；
- [ ] 完成 LTO、RSan、SymCC、AFL++ `-K` 冒烟测试；
- [ ] 生成 `.pct-*`、完成 PCBT 插入和预筛选；
- [ ] 所有命令、环境、失败日志和结果摘要写入集成仓库文档。

### Phase 4：首个发布基线

- [ ] 打集成 tag `v0.1.0-baseline`；
- [ ] 建立 GitHub Release，附 `compatibility.yaml`、构建说明与已知限制；
- [ ] 创建 Paper A 开发分支；
- [ ] 之后所有跨模块改动都通过“组件 PR → 集成 PR → integration test → 更新 submodule SHA”的流程进入稳定线。

---

## 10. 迁移完成的定义

当且仅当以下条件都满足时，迁移视为完成：

1. GitHub 上存在三个可独立 clone、构建和追溯上游的组件 fork；
2. GitHub 上存在一个可 `--recurse-submodules` clone 的 SymAFL 集成仓库；
3. 根仓库精确固定并声明当前兼容的三组件 SHA、ABI 和 trace 格式；
4. 新机器/干净环境能通过文档重建完整 SymAFL 工具链并运行 `-K` 集成冒烟测试；
5. 任何历史论文或实验结果都能定位到不可变 tag、配置 hash、benchmark/seed hash 与环境 manifest；
6. 没有 PAT、私钥、私人绝对路径、构建目录或大规模 AFL 运行产物被提交到 Git；
7. 所有跨模块协议变更都有对应的版本标识、测试和 PR 记录。
