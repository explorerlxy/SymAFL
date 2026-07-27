# SymAFL 项目管理手册

> 版本：v1.0（2026-07-25，随 `v0.1.0-baseline` 发布）
>
> 本文档总结 SymAFL 从本地多仓库工作区迁移到 GitHub 远程协作体系的全部决策、
> 实际操作记录，以及后续多版本迭代研发/测试应遵循的管理哲学与最佳实践。
> 所有命令均可直接复制执行；路径以集成仓库克隆根目录（下称 `$SYMAFL_ROOT`）为准。

---

## 第一部分：迁移成果档案

### 1.1 仓库拓扑

```
GitHub (private)                          本地
─────────────────────────────────────────────────────────────
explorerlxy/SymAFL                  ←→  SymAFL-integrated/          ← 集成仓库（工作入口）
├── AFLplusplus  (submodule)        ←→  explorerlxy/SymAFL-AFLplusplus
├── RSan         (submodule)        ←→  explorerlxy/SymAFL-RSan
└── symcc        (submodule)        ←→  explorerlxy/SymAFL-Symcc
```

| 仓库 | 角色 | 基线 main | upstream（只读同步源） |
|---|---|---|---|
| `SymAFL` | 集成 manifest：submodule SHA、脚本、测试、文档、实验配置 | `v0.1.0-baseline` | — |
| `SymAFL-AFLplusplus` | PCBT、`-K` 筛选、低价值分支剪枝、队列逻辑 | `7a995cb8` | `AFLplusplus/AFLplusplus` |
| `SymAFL-RSan` | LLVM 16 CodeGen、SafeStack、SymCC pass、TCMalloc、链接器 | `3403b14db` | 无（`original-rsan` 分支 + `upstream-base` tag 记录来源） |
| `SymAFL-Symcc` | 平直化单仓库：compiler + vendored symcc-rt/qsym 运行时 | `a5fa0858` | `eurecom-s3/symcc` |

**关键架构决策（为什么这样设计）**

1. **集成仓库不复制组件源码**，只用 git submodule 固定精确 SHA。三组件迭代节奏不同、各有上游，复制会造成双写漂移。
2. **symcc 平直化（vendoring）而非嵌套 fork**。SymAFL 的运行时改动横跨 symcc-rt 与 qsym 两层，单一仓库可以一次提交原子锁定整个符号执行层；溯源信息（基线 SHA、排除物）写入 vendoring 提交信息。排除 `third_party/z3`（构建用系统 Z3）与 200MB Intel Pin（仅独立 pintool 构建需要）。
3. **契约集中声明**：`config/compatibility.yaml` 是三组件组合的唯一权威声明（SHA、ABI 版本、SHM 通道名、trace 格式、pass 顺序、`insert_depth` 语义）。

### 1.2 迁移执行摘要（已完成的动作）

| 阶段 | 动作 | 证据 |
|---|---|---|
| Phase 0 | 全量 git bundle × 5（含 symcc-rt/qsym granular 历史）、fsck、状态/补丁/未跟踪清单、SHA-256 manifest | `backup/SymAFL/{bundles,evidence,patches,manifests}` |
| Phase 1a | AFL++：symccTest 移出、410 个 VS Code 缓存 + pctTest 取消追踪、`-L.` 链接修复、outdir SHM `strcpy` 修复、gitignore、文档 | 6 commits → `7a995cb8`；`gmake source-only` ✅ |
| Phase 1b | RSan：env.sh 自定位化、CLAUDE.md、`upstream-base` tag | 2 commits → `3403b14db` |
| Phase 1c | symcc：构建树删除、vendor runtime+qsym、文档 | 6 commits → `a5fa0858`；QSYM runtime 重建 ✅ |
| Phase 2 | 三组件 remote 切 SSH、全分支/tag 推送 | 远程分支清单见 §3.2 |
| Phase 3 | 集成仓库：submodule 固定、脚本迁移、fixture 迁移、compatibility.yaml、README/CLAUDE 更新 | `cc83b91` → `8b60790` |
| Phase 4 | 全新 recursive clone 验证、fixture 构建、`afl-fuzz -K` 45s 冒烟（`.pct-*` 产出） | 通过 ✅ |
| Phase 5 | `v0.1.0-baseline` annotated tag | 已推送 |

### 1.3 备份与灾难恢复

备份根：`/media/hahafish/Data/ForUbuntu/backup/SymAFL/`

```
backup/SymAFL/
├── bundles/            # 5 个 git bundle（迁移前全量 + 含 SymAFL 提交的 symcc-rt/qsym）
├── evidence/           # 迁移前 branch/remote/status/未跟踪清单
├── patches/            # 工作区/暂存 binary patch
├── manifests/          # SHA-256 校验单
├── nested-gitdirs/     # 被平直化的 symcc-rt 完整 gitdir（含 nested qsym/z3）
└── (完整工作区副本)     # 用户迁移前手动复制的整棵树
```

**恢复单个仓库到迁移前状态**：

```bash
# 从 bundle 克隆完整历史（bundle 即自包含仓库）
git clone /media/hahafish/Data/ForUbuntu/backup/SymAFL/bundles/aflplusplus-pre-migration-20260725.bundle afl-restore
cd afl-restore && git log --oneline -5
```

**恢复被平直化的 symcc-rt 独立仓库**：

```bash
git clone /media/hahafish/Data/ForUbuntu/backup/SymAFL/bundles/symcc-rt-with-symafl-20260725.bundle symcc-rt-restore
```

**验证备份完整性**（建议每季度执行一次）：

```bash
for b in /media/hahafish/Data/ForUbuntu/backup/SymAFL/bundles/*.bundle; do git bundle verify "$b" | tail -1; done
```

---

## 第二部分：管理哲学

### 2.1 五条核心原则

**P1 — 源码与生成物严格分离。**
Git 只追踪"人写的、审阅的、需要演化对比的内容"：源码、脚本、配置、最小 fixture、文档、实验 manifest/摘要。构建目录、AFL 输出、`.pct-*`、PCBT 图、原始 benchmark 数据一律 `.gitignore` 或入外部存储。判断标准：**"这个文件删了能否由仓库内容重新生成？"能，就不入库。**

**P2 — 一次提交一个意图，提交信息即设计文档。**
feat/fix/chore/docs/build/test 前缀；跨模块契约变更必须在提交信息中声明。迁移期间的反例（410 个编辑器缓存被 `git add -A` 卷入）说明：**提交前必看 `git status` 分类统计**，禁止无脑 `git add -A`（用 `git add <path>` 精确暂存）。

**P3 — 集成仓库是唯一权威版本点。**
组件仓库的 `main` 只代表"该组件自身通过测试"；只有集成仓库的 tag 才代表"经过跨模块验证的 SymAFL 版本"。论文、实验、对外引用一律用集成仓库 tag + 三组件 SHA 四元组。

**P4 — 契约变更显式版本化。**
PCBT API、SHM 通道名、`.pct-*` 格式、`insert_depth` 语义、pass 顺序、模式切换协议——任一变化必须同步：`config/compatibility.yaml` 版本号 + 集成测试 + 提交信息声明。隐式破坏契约是跨仓库开发最大的风险源。

**P5 — 破坏性操作前先留可验证的退路。**
bundle → verify → 再操作。分支指针操作（reset/force-push/删除分支）前创建 `archive/<desc>-<date>` 分支。这条规则在迁移中实际救场两次（误合并提交拆分、submodule 平直化）。

### 2.2 分支模型（四仓库统一）

```
main                          稳定主线：仅接受 PR 合并，CI 通过
release/vX.Y                  发布/论文冻结线：只接受 cherry-pick 修复
feature/<topic>               功能开发（单仓库内）
fix/<issue>                   缺陷修复
experiment/<hypothesis>       研究性实验，可丢弃，不保证 CI
archive/<desc>-<date>         只读安全锚点（破坏性操作前创建）
upstream-sync/<date>          上游同步与冲突处理专用
```

**规则**：
- 不允许直接向 `main` push（GitHub 分支保护强制执行）。
- `release/*` 创建后只进不出：bug 在 `fix/*` 修好后 cherry-pick 进 release，再把 release 合回 main。
- `experiment/*` 定期清理：三个月无活动即删除（历史仍在 reflog/PR 中可查）。

### 2.3 两篇论文的版本线规划

```
SymAFL 集成仓库
├── tag: v0.1.0-baseline          ← 当前，迁移基线
├── branch: paper/a-pcbt-screening
│     └── tag: paper-a-submission → 冻结：PCBT 预筛 + 吞吐 + non-inferiority 实验
├── branch: paper/b-test-space-focus
│     └── tag: paper-b-submission → 冻结：interface hook + 漏洞导向规约 + focus fuzzing
└── release/v1.x                  ← 工程发布线（与论文线正交）
```

- Paper B 必须以 Paper A 的 tag 为 baseline，消融对比才可归因。
- 论文 tag 对应的实验 manifest（见 §4.3）随 tag 一并归档。

---

## 第三部分：日常开发工作流（命令级）

### 3.1 环境准备（新机器/新克隆）

```bash
git clone --recurse-submodules git@github.com:explorerlxy/SymAFL.git
cd SymAFL

# NTFS/fuseblk 检出必须（否则全库出现幻影 mode-change 差异）：
git config core.filemode false
for m in AFLplusplus RSan symcc; do git -C $m config core.filemode false; done

# 若提交脚本类文件，可执行位须显式登记（NTFS 上 chmod 不影响 git）：
git update-index --chmod=+x scripts/<script>

# 加载环境（自定位，无需 export SYMAFL_ROOT）
source scripts/symafl-env.sh

# 全量构建三子系统（幂等，按依赖顺序 rsan → symcc → aflpp；可单独构建）
scripts/build-all.sh            # 或 scripts/build-all.sh rsan|symcc|aflpp
```

> ⚠️ NTFS 检出上 `git clone --recurse-submodules` 默认会把 AFL++ 上游的 9 个重型
> submodule（qemu/unicorn/nyx 等）一并拉取。只初始化顶层：
> `git submodule update --init`（不带 `--recursive`），按需再进组件单独初始化。

### 3.2 身份与远程（每仓库一次性）

```bash
for r in . AFLplusplus RSan symcc; do
  git -C $r config user.name "Hahafish"
  git -C $r config user.email "caroulder@163.com"
done

# 检查远程（任何 URL 中不得出现 token）
git remote -v
# 上游同步源保持只读用途，绝不 push：
#   AFLplusplus: upstream = AFLplusplus/AFLplusplus
#   symcc:       upstream = eurecom-s3/symcc
```

### 3.3 单组件功能开发（以 AFL++ 改 PCBT 为例）

```bash
cd $SYMAFL_ROOT/AFLplusplus
git checkout main && git pull
git checkout -b feature/pcbt-screening-v2

# …编辑…
git status --porcelain=v1 | cut -c1-3 | sort | uniq -c   # 提交前分类审查
git add src/PathConTree.cpp                               # 精确暂存
git commit -m "feat: <一句话意图>

<动机、方案、契约影响（如有）>

Co-Authored-By: Claude <noreply@anthropic.com>"

gmake source-only && gmake unit                           # 组件级验证
git push -u origin feature/pcbt-screening-v2
# → GitHub 提 PR → 合并入 main
```

### 3.4 集成升级（推进 submodule SHA）——跨仓库联动的标准动作

组件 PR 合并后，在集成仓库显式推进 gitlink：

```bash
cd $SYMAFL_ROOT
git checkout main && git pull
git checkout -b integration/pcbt-screening-v2

git -C AFLplusplus fetch origin
git -C AFLplusplus checkout origin/main        # 或指定 SHA
git add AFLplusplus                            # 暂存 gitlink 变化

# 同步更新契约清单（SHA + 必要时协议版本）
$EDITOR config/compatibility.yaml

# 契约自检：gitlink 与 manifest 必须一致
diff <(git ls-tree HEAD AFLplusplus | awk '{print $3}') \
     <(grep -A1 'aflplusplus:' config/compatibility.yaml | grep commit | cut -d'"' -f2) \
  && echo "PIN CONSISTENT"

git commit -m "chore: bump AFLplusplus to <sha> for pcbt-screening-v2

Contract impact: none / <描述>（protocol_version 是否变化）"
git push -u origin integration/pcbt-screening-v2
# → PR → 集成 CI（构建 + 冒烟）→ 合并
```

**铁律：禁止 `git submodule update --remote` 浮动跟进组件 main。** 每次推进都必须经过上述 PR，留下契约审查点。

### 3.5 跨组件原子变更（同一意图改两个以上组件）

以修改 SHM 协议为例（AFL++ 生产端 + symcc 消费端）：

```
1. 两组件分别开同名分支 feature/shm-abi-v2，各自提交、自测
2. 集成仓库开 integration/shm-abi-v2，同时推进两个 gitlink
3. compatibility.yaml：protocol_version: symafl-abi-v1 → v2
4. 集成测试同时覆盖新协议两端
5. 三个 PR 按“组件先合、集成后合”的顺序合并
6. 合并后立即打 pre-release tag：v0.2.0-rc1
```

顺序错了（先合集成）会让集成仓库在某段时间内指向未验证组合。

### 3.6 上游同步（每季度或有安全修复时）

```bash
# AFL++ 示例；symcc 同理（RSan 无上游）
cd $SYMAFL_ROOT/AFLplusplus
git checkout -b upstream-sync/2026-q3
git fetch upstream
git merge upstream/stable        # 或 rebase；冲突在分支内解决
gmake source-only && gmake unit
git push -u origin upstream-sync/2026-q3
# → PR → main → 集成仓库推进 SHA + 全量集成测试
```

### 3.7 打 tag 与发布

```bash
cd $SYMAFL_ROOT
git tag -a v0.2.0 -m "SymAFL v0.2.0 — <主题>

Components:
- AFLplusplus <sha>
- RSan        <sha>
- symcc       <sha>

Contract: symafl-abi-v<N> | Verified: <冒烟/集成测试摘要>"
git push origin v0.2.0
```

tag 信息必须包含三组件 SHA 与验证证据——tag 是给未来的自己和审稿人看的复现凭据。

---

## 第四部分：测试与实验管理

### 4.1 验证分层（什么改动跑什么测试）

| 层级 | 触发 | 内容 | 命令 |
|---|---|---|---|
| L0 静态 | 每次提交前 | 语法、状态分类、契约一致性 | `bash -n scripts/*`、`git status --porcelain`、§3.4 PIN CONSISTENT |
| L1 组件 | 组件 PR | AFL++ `gmake source-only/unit`；symcc QSYM 重建；RSan `ninja LLVMCodeGen clang lld` + `nm …grep createSymCC` | 见各组件 CLAUDE.md |
| L2 集成冒烟 | 集成 PR | fixture 构建 + 插桩检查 + 短时 `-K` 运行 | 见 §4.2 |
| L3 基准/论文 | nightly / release | 多轮覆盖率、漏洞发现、统计检验 | 实验配置驱动（待建 CI） |

### 4.2 L2 集成冒烟标准流程

```bash
cd $SYMAFL_ROOT && source scripts/symafl-env.sh

# 1. 构建 fixture（输出到被忽略的 build/ 目录）
mkdir -p tests/fixtures/simpletest/build
scripts/symafl-build --symcc tests/fixtures/simpletest/read.c \
  -o tests/fixtures/simpletest/build/read-symafl

# 2. 插桩验证
nm tests/fixtures/simpletest/build/read-symafl | grep '_sym_notify_basic_block'
nm tests/fixtures/simpletest/build/read-symafl | grep '__afl_area_ptr'
objdump -t tests/fixtures/simpletest/build/read-symafl | grep malloc_symbolized   # 仅应用代码

# 3. 短时 -K 运行（输出必须在源树之外）
AFL_NO_UI=1 timeout 60 scripts/symafl-fuzz \
  tests/fixtures/simpletest/build/read-symafl \
  tests/fixtures/simpletest/seeds /tmp/symafl-smoke

# 4. 产物断言
ls /tmp/symafl-smoke/default/sym_mode_stats
ls /tmp/symafl-smoke/default/queue/.pct-* | head -1
```

### 4.3 实验可复现性（论文数据铁律）

每次正式实验生成 manifest，**Git 只追踪 manifest 与摘要，原始输出存外部**：

```bash
EXP=exp-$(date +%Y%m%d)-pcbt-throughput
mkdir -p results/manifests results/raw/$EXP
cat > results/manifests/$EXP.json <<EOF
{
  "experiment": "$EXP",
  "symafl_tag": "$(git describe --tags)",
  "components": {
    "aflplusplus": "$(git -C AFLplusplus rev-parse HEAD)",
    "rsan":        "$(git -C RSan rev-parse HEAD)",
    "symcc":       "$(git -C symcc rev-parse HEAD)"
  },
  "compatibility_sha256": "$(sha256sum config/compatibility.yaml | cut -d' ' -f1)",
  "z3_version": "$(z3 --version)",
  "llvm_version": "$($RSAN_C --version | head -1)",
  "target": "<benchmark+commit>", "seed_corpus_sha256": "<...>",
  "command": "<完整命令行>", "started": "$(date -Is)"
}
EOF
# 运行实验，原始输出到 results/raw/$EXP/（.gitignore 已排除 raw/）
```

论文评审需要复现时：集成仓库 tag + manifest 即可精确定位全部代码、配置、工具链与数据版本。

### 4.4 生成物防入库自检（提交前必做）

```bash
# 本次提交是否混入可疑大文件/二进制？
git diff --cached --stat | tail -3
git diff --cached --numstat | awk '$1=="-" || $2=="-"'   # 非空 = 有二进制，逐个确认

# 某路径为何被忽略/未被忽略？
git check-ignore -v --no-index <path>

# 仓库里是否已有历史遗留生成物？
git ls-files | grep -E '(^|/)(CMakeFiles|build|afl-out|tmp)(/|$)|\.(o|a|so)$' | head
```

---

## 第五部分：常见事故处置手册

| 事故 | 处置 |
|---|---|
| 误 `git add -A` 暂存了生成物 | `git reset`（mixed，不动工作区）→ 重新精确 `git add <path>` |
| 提交信息写错（未推送） | `git commit --amend` |
| 提交拆错了（未推送） | `git reset --soft <base>` → 重新分批提交；迁移中实际案例：junk 清理被卷入 symccTest 提交，`reset --mixed` 后拆成两个提交 |
| 分支被误删 | 从备份 bundle 或 reflog 找回：`git reflog` / `git clone <bundle>` |
| submodule 检出到错误 SHA | `git -C <m> checkout <正确SHA>` → `git add <m>` → 提交 |
| NTFS 上全库幻影修改 | `git config core.filemode false`（每个仓库各设一次） |
| 新文件在 GitHub 上不可执行 | `git update-index --chmod=+x <file>` 后提交 |
| remote URL 泄露 token | 立即 GitHub revoke → 改 SSH URL → 检查 shell history/文档/备份中的残留 |
| 推送超时（大仓库慢网） | 后台推送；或先本地 `git submodule add <本地路径>` 再改 `.gitmodules` URL 并 `git submodule sync`（迁移中实际使用） |

---

## 第六部分：路线图（待建设施）

按优先级排序，每项都应对应集成仓库的一个 issue：

1. **组件 CI（L1）**：GitHub Actions — AFL++ source-only 构建、symcc QSYM 构建、RSan pass 符号检查。
2. **集成 CI（L2）**：容器化固定 Ubuntu + LLVM 16 + Z3，自动跑 §4.2 冒烟。
3. **契约自检 CI**：PR 时自动校验 gitlink SHA 与 compatibility.yaml 一致；protocol 文件变更时要求版本号 diff。
4. **夜间基准（L3）**：Paper A 所需的吞吐量/漏洞发现 non-inferiority 多轮统计流水线。
5. **GitHub 分支保护**：`main`/`release/*` 禁 force-push、必过 CI（需在网页端设置，见 §3.1 后）。
6. **旧工作区退役**：确认无遗漏后，将 `/media/hahafish/Data/ForUbuntu/SymAFL`（迁移前工作区）整体归档，日常工作统一在 `SymAFL-integrated`。

---

## 附录 A：迁移期遗留的已知技术债

| 债务 | 位置 | 建议处理时机 |
|---|---|---|
| symcc runtime `main` 基于 symcc-rt@892f817，落后 upstream main 2 个提交 | SymAFL-Symcc | 首次 upstream-sync 时合并 |
| 新克隆中 LLVM/TCMalloc/pld.so/QSYM runtime 需从零重建（数小时） | RSan | 空闲时段执行 `scripts/build-all.sh rsan symcc`，之后集成 CI 缓存 |
| `symafl_runner`（独立 SHM 包装器）未迁入仓库 | 旧工作区 | Paper A 实验需要时补入 `scripts/` |
| AFL++ 上游 9 个重型 submodule 未初始化 | AFLplusplus | 仅开发 qemu/unicorn/nyx 模式时按需初始化 |
| `docs/SymAFL_TESTING_WORKFLOW.md` 中部分路径仍为旧布局 | docs/ | 下次文档更新时统一修订 |

## 附录 B：命令速查卡

```bash
# 状态总览（四仓库）
for r in . AFLplusplus RSan symcc; do echo "== $r =="; git -C $r status --short --branch | head -3; done

# submodule 推进（标准动作）
git -C AFLplusplus fetch origin && git -C AFLplusplus checkout origin/main
git add AFLplusplus && git commit -m "chore: bump AFLplusplus to $(git -C AFLplusplus rev-parse --short HEAD)"

# 克隆后必做（NTFS）
git config core.filemode false
for m in AFLplusplus RSan symcc; do git -C $m config core.filemode false; done

# 契约一致性
git submodule status
grep -A2 'components:' config/compatibility.yaml | grep commit

# 备份（大动作前）
git bundle create /path/to/backup/$(basename $PWD)-$(date +%Y%m%d).bundle --all
git bundle verify /path/to/backup/*.bundle | tail -1

# 安全锚点（破坏性操作前）
git branch archive/$(date +%Y%m%d)-before-<action>
```
