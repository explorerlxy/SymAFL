# SymAFL 测试流程文档

## 基于 AFL++ / RSan / SymCC 的混合模糊测试系统

---

## 一、SymAFL 系统架构概览

SymAFL 是一个集成了**覆盖率引导模糊测试 (AFL++)**、**轻量级动态符号执行 (SymCC)** 和**内存漏洞检测 (RSan)** 的混合模糊测试系统。

### 1.1 核心设计思想

SymAFL 的核心创新在于：**利用轻量级路径约束分析替代大量低价值的程序具体执行**，从而极大提升模糊测试的吞吐率。具体而言：

1. **路径约束二叉树 (Path Constraint Binary Tree, PCBT)**：维护程序探索过的所有路径约束，形成二叉树结构
2. **CheckInput() 快速预筛**：在具体执行种子前，先通过 SMT 求解器检查该种子是否能在 PCBT 中触发新分支
3. **仅对有趣种子具体执行**：只有通过 CheckInput() 判定为"有趣"的种子，才会被具体执行并评估覆盖率
4. **漏洞-路径强绑定**：通过 RSan（RangeSanitizer）将内存漏洞状态转化为程序分支，使漏洞检测与路径覆盖直接关联

### 1.2 系统架构图

```
┌─────────────────────────────────────────────────────────────────────┐
│                          AFL++ (afl-fuzz)                           │
│  ┌─────────────┐  ┌──────────────┐  ┌──────────────────────────┐   │
│  │ 变异引擎     │  │ 种子队列管理  │  │ PathConTree (C++ 动态库) │   │
│  │ havoc/splice │  │ save_if_int  │  │ - CheckInput() 预筛      │   │
│  │ custom_mut   │  │ calibrate    │  │ - InsertTrace() 增量插入 │   │
│  └──────┬───────┘  └──────┬───────┘  │ - 全局 PC 树遍历          │   │
│         │                 │           └────────────┬─────────────┘   │
│         │         共享内存 (5 通道)                 │                 │
│         │         ├─ __AFL_SHM_ID       (覆盖率位图)                │
│         │         ├─ __AFL_SHM_OUTDIR   (输出目录)                  │
│         │         ├─ __AFL_SHM_SYMBOLIC (符号/具体模式切换)         │
│         │         ├─ __AFL_SHM_QUEUE    (队列条目ID)                │
│         │         └─ __AFL_SHM_DEPTH    (约束插入起始深度)           │
│         │                 │                                         │
│         ▼                 ▼                                         │
│  ┌──────────────────────────────────────────────────────────────┐   │
│  │        SymCC + RSan 编译的目标程序 (Forkserver 子进程)         │   │
│  │  ┌────────────────────────────────────────────────────────┐  │   │
│  │  │  RSan SafeStack (LTO CodeGen Pass, 先运行)              │  │   │
│  │  │  - 栈拆分 (Safe/Unsafe Stack)                          │  │   │
│  │  │  - 内存边界检查 (Redzone)                               │  │   │
│  │  │  - Use-After-Free 检测 (Explicit/Implicit Tag)          │  │   │
│  │  │  - 复合指针标记 (x86): size tag(bits 41-46) + LAM(bits 57-62) │   │
│  │  └────────────────────────────────────────────────────────┘  │   │
│  │                            ↓                                   │   │
│  │  ┌────────────────────────────────────────────────────────┐  │   │
│  │  │  SymCC SymbolizePass (LTO CodeGen Pass, 后运行)         │  │   │
│  │  │  - 符号表达式追踪 (_sym_build_*)                        │  │   │
│  │  │  - 路径约束记录 (_sym_push_path_constraint)             │  │   │
│  │  │  - AFL 覆盖率插桩 (BB边缘计数)                          │  │   │
│  │  │  - 影子内存管理 (_sym_read/write_memory)                │  │   │
│  │  │  - Per-call-site 外部函数拦截重定向                     │  │   │
│  │  └────────────────────────────────────────────────────────┘  │   │
│  │                            ↓                                   │   │
│  │  ┌────────────────────────────────────────────────────────┐  │   │
│  │  │  运行时库 (libsymcc-rt)                                  │  │   │
│  │  │  - QSYM/Simple Backend                                  │  │   │
│  │  │  - Z3 SMT 求解器                                         │  │   │
│  │  │  - Solver 状态持久化 (save_solver_to_file)              │  │   │
│  │  │  - 信号处理 + atexit 双重崩溃保护                        │  │   │
│  │  └────────────────────────────────────────────────────────┘  │   │
│  └──────────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────────┘
```

### 1.3 Pass 管线顺序

在 SymAFL 的 LTO (Link-Time Optimization) 编译模型中，pass 执行顺序如下：

```
源码 (.c/.cpp)
  │
  ▼
Per-TU 编译 (clang -c -flto=full)
  ├── Clang 前端 → LLVM IR → Bitcode
  │   （此阶段 SymCC 和 RSan 均不运行）
  ▼
LTO Link (clang -flto=full → lld)
  │
  ├── buildLTODefaultPipeline()         ← LTO IR 优化管线
  │   ├── FullLinkTimeOptimizationEarlyEPCallbacks
  │   ├── ... 全局优化 (inlining, DCE, ...)
  │   ├── FullLinkTimeOptimizationLastEPCallbacks
  │   └── HelloWorldPass()              ← RSan IR 级分析预留 (当前 no-op)
  │
  ├── CodeGen Pipeline (TargetPassConfig)
  │   ├── addPreISel()                  ← 预指令选择准备
  │   ├── SafeStackLegacyPass           ← **RSan SafeStack 栈保护** (Step 1)
  │   ├── SymbolizeLegacyPass           ← **SymCC 符号执行插桩** (Step 2)
  │   ├── StackProtectorPass            ← 栈金丝雀保护
  │   └── createVerifierPass()          ← IR 验证
  │
  ├── Instruction Selection (IR → MIR)  ← llvm.x86.bmi.bzhi → 已替换为 SHL+SHR
  ├── Register Allocation
  └── Code Emission → 目标文件 (.o)
```

**关键设计决策**：SymCC 的 `SymbolizeLegacyPass` 在 RSan 的 `SafeStackLegacyPass` **之后**运行，确保 SymCC 能够对 SafeStack 插入的内存安全检查代码（如边界检查、`int3` 断点等）也进行符号化追踪。

---

## 二、组件说明

### 2.1 AFL++ (American Fuzzy Lop plus plus)

**角色**：覆盖率引导的模糊测试引擎，负责种子变异、队列管理、Forkserver 通信。

**关键修改**：

| 修改项 | 说明 |
|--------|------|
| PathConTree 集成 | 将 `PathConTree.cpp` 编译为 `libpathcontree.so` 动态库，通过 C 接口在 `afl-fuzz` 中调用 |
| 五路共享内存通道 | `__afl_area_ptr`（覆盖率）、`__out_dir`（输出目录）、`__symbolic`（模式切换）、`__queue_entry_id`（队列ID）、`__insert_depth`（约束深度） |
| SymCC Mode | 新增 `-K` 选项，启用基于路径约束二叉树的种子预筛模式 |
| `save_if_interesting()` | 在种子入队时调用 `pathcon_tree_insert_trace()`，完成 PCBT 增量维护 |
| `test_if_interesting()` | 在具体执行前调用 `pathcon_tree_check_input()`，判定种子是否触发了新分支 |
| 运行时模式切换 | 通过共享内存变量 `__symbolic`（经 `__AFL_SHM_SYMBOLIC_ENV_ID` 映射）在每轮 fork 前动态控制具体/符号模式 |

**运行时模式切换机制 (reset_gconfig)**：

运行时模式切换不是通过环境变量实现的（环境变量在进程启动后不可更改），而是通过共享内存变量 `__symbolic` 配合 Forkserver 的 `reset_gconfig()` 函数实现的：

```cpp
// SymCC runtime Runtime.cpp: Forkserver 主循环
while (1) {
    read(FORKSRV_FD, &was_killed, 4);  // 等待 AFL++ 唤醒
    reset_gconfig();                    // ← 每轮 fork 前读取 __symbolic 切换模式
    child_pid = fork();
    ...
}

// reset_gconfig(): 根据共享内存变量切换模式
static void reset_gconfig(void) {
    switch(*__symbolic) {
      case 0:  // → 纯具体执行模式 (No symbolic input)
        g_config.input = NoInput{};
        inputFileDescriptor = -1;   // 关键: 设为 -1 使 read_symbolized() 不构建符号表达式
        break;
      case 1:  // → 符号执行模式 (Symbolic stdin)
        g_config.input = StdinInput{};
        inputFileDescriptor = 0;    // 关键: 设为 0 使 read_symbolized() 标记读取数据为符号化
        break;
    }
}
```

**关键实现细节**：仅仅修改 `g_config.input` 是不够的，必须同时修改 `inputFileDescriptor`。`inputFileDescriptor` 控制 `read_symbolized()` 的行为——当值为 -1 时，程序读取的所有数据都不会被标记为符号化，从而实现真正的"纯具体执行"（无符号计算开销）。这就是为什么需要 shared memory 而不是环境变量——`reset_gconfig()` 在每轮 fork 前动态执行，确保：

| 变量 | 控制范围 | 设置方式 |
|------|---------|---------|
| `*__symbolic` | 共享内存，AFL++ 写入 | 0 = 具体模式, 1 = 符号模式 |
| `g_config.input` | 进程全局，`reset_gconfig()` 写入 | NoInput / StdinInput |
| `inputFileDescriptor` | 进程全局，`reset_gconfig()` 写入 | -1 (不符号化) / 0 (stdin 符号化) |

**C++ 动态库接口** (`libpathcontree.so`)：

```c
// PathConTree.h
PathConTree* pathcon_tree_create(uint32_t max_input_size);
void pathcon_tree_destroy(PathConTree* tree);
int pathcon_tree_insert_trace(PathConTree* tree, const char* smtfile);
uint32_t pathcon_tree_check_input(PathConTree* tree, const uint8_t* input, uint32_t size);
void visualize_pathcon_tree(PathConTree* tree, const char* filename);
```

### 2.2 RSan (RangeSanitizer)

**角色**：基于 SafeStack 扩展的内存错误检测器，检测空间和时间内存错误。

> **注意**：目前 SymAFL 仅适配了 **x86_64** 架构。AArch64 的 RSan（Explicit Tagging / TBI 方案）尚未集成至 SymAFL 测试框架。

**x86_64 指针标记机制**：

RSan 在 x86_64 上采用 **隐式 size tag + 显式 mem tag** 的复合标记方案，利用 LAM (Linear Address Masking) 的 U57 位在指针中嵌入元数据：

```
63 62  57 56  53 52  47 46  41 40                                      0
┌─┬──────┬──────┬──────┬──────┬──────────────────────────────────────────┐
│S│ LAM  │ LAM  │ LAM  │ size │              Address Bits               │
│E│ bit  │ bit  │ bit  │class │            (常规用户空间地址             │
│ │ 62   │ 61   │57-60 │41-46 │              零扩展至 bit 40)            │
└─┴──────┴──────┴──────┴──────┴──────────────────────────────────────────┘
  ▲      ▲                      ▲              ▲
  │      └─ LAM/U57 显式 mem tag (bits 57-62)  │
  │          由 TCMalloc 编码 size class 等信息  │
  └─ 符号扩展位 (bit 63)                └─ 隐式 size tag (bits 41-46)
                                             由 TCMalloc 编码 log2(size)
```

**元数据提取流程**（[SafeStack.cpp:1953-1977](RSan/llvm-project-16/llvm/lib/CodeGen/SafeStack.cpp#L1953)）：

```cpp
// Step 1: 从指针高位提取复合 tag 值
tag_shift = 41;  // x86 implicit tagging
Tag = ptr >> 41;  // 提取 bits [41:63]，包含 size class + LAM 元数据

// Step 2: (ptr >> tag) << tag 清零低 tag 位，定位分配基址
//         使用通用 SHL+LSHR，不再依赖 BMI2 的 BZHI+XOR
Value *ShiftedRight = builder.CreateLShr(PtrAsInt, Tag);  // SHRX
Value *Base = builder.CreateShl(ShiftedRight, Tag);        // SHLX

// Step 3: base - 8 获取元数据指针（8 字节的 redzone metadata）
MetadataOffset = builder.CreateSub(Base, ConstantInt::get(Int64Ty, 8));
```

**核心机制对比**：

| 特性 | x86_64 (Implicit Tagging) |
|------|--------------------------|
| 标记方式 | 隐式 size tag (bits 41-46) + 显式 mem tag / LAM U57 (bits 57-62) |
| 基址定位 | `(ptr >> tag) << tag`（SHLX + SHRX，**不再依赖 BMI2**） |
| 元数据位置 | 分配基址 - 8 字节处 (redzone metadata) |
| 全局变量标记 | 链接器脚本分段 (`basebounds_section_{sizeclass}`) |
| 指令集要求 | SSE4.2（无 BMI2 依赖） |
| 运行时要求 | TCMalloc (modified) + 自定义动态链接器 (pld.so) |
| 编译器标志 | `-fsanitize=safe-stack -flto=full` |

**关键修改**：

| 修改项 | 文件 | 说明 |
|--------|------|------|
| BZHI → SHL+SHR | [SafeStack.cpp](RSan/llvm-project-16/llvm/lib/CodeGen/SafeStack.cpp) (4处) | 替换 `Intrinsic::x86_bmi_bzhi_64` 为通用 `CreateLShr`+`CreateShl`，消除 BMI2 指令选择崩溃，且不再要求 `-mbmi2` |
| `-flto=full` 支持 | 编译流程 | 通过 FullLTO 在 link 阶段运行 CodeGen pass |
| SafeStack Pass 保持原有位置 | [TargetPassConfig.cpp](RSan/llvm-project-16/llvm/lib/CodeGen/TargetPassConfig.cpp) | 在 `addISelPrepare()` 中运行 |

### 2.3 SymCC (Symbolic Execution Compiler)

**角色**：编译器驱动的轻量级符号执行引擎，在 LLVM IR 级别注入符号追踪和路径约束收集代码。

**核心 Pass** ([SymCC/Pass.cpp](RSan/llvm-project-16/llvm/lib/CodeGen/SymCC/Pass.cpp))：

| 功能模块 | 说明 |
|----------|------|
| `instrumentModule()` | 创建 AFL 全局变量、注册构造函数 (`_sym_initialize`, `__afl_auto_init`) |
| `instrumentFunction()` | 指令级符号化插桩 + AFL 覆盖率边缘更新 |
| `Symbolizer::visit()` | 对每条 LLVM IR 指令注入对应的 `_sym_build_*` 运行时调用 |
| `Symbolizer::handleFunctionCall()` | Per-call-site 外部函数拦截重定向（`malloc` → `malloc_symbolized`） |
| `shortCircuitExpressionUses()` | 短路优化：全部具体输入时跳过符号计算 |

**关键修改**：

| 修改项 | 说明 |
|--------|------|
| LTO CodeGen 集成 | 将 SymCC pass 从 per-TU pass plugin 改造为 CodeGen 管线的一部分 |
| Pass 顺序调整 | 在 `TargetPassConfig::addISelPrepare()` 中 SafeStack 之后运行 |
| 选择性插桩 | 新增 `shouldInstrument()` 函数，跳过 `__noinstrument_*`、`__safestack_init`、`__interceptor_*` 等 SafeStack 运行时函数 |
| Per-call-site 重定向 | 将全局函数重命名改为 `handleFunctionCall()` 中的逐调用点重定向 |
| BZHI 适配 | 配合 RSan 将 BMI2 `BZHI` intrinsic 替换为 `SHL+SHR` |
| LLVM 16 API 适配 | `CreateLoad`/`CreateGEP` 需显式类型参数，`None` → `std::nullopt` |

**选择性插桩规则** (`shouldInstrument()`)：

```
跳过条件:
├── F.isDeclaration()                       → 外部声明
├── F.getName().startswith("__noinstrument_") → SafeStack 运行时 (如 __noinstrument_dyn_alloc)
├── F.getName().startswith("__sym_ctor")      → SymCC 自身构造函数
├── F.getName() == "__safestack_init"         → SafeStack 初始化函数
├── F.getName().startswith("__interceptor_")  → compiler-rt 拦截函数
└── F.hasFnAttribute(DisableSanitizerInstrumentation) → LLVM 禁用属性
```

---

## 三、编译构建流程

### 3.1 环境依赖

| 依赖 | 版本 | 说明 |
|------|------|------|
| LLVM/Clang | 16.0.6 (modified) | RSan 定制的 LLVM，包含 SafeStack 修改和 SymCC pass 集成 |
| GCC | 9+ | **编译运行时 stubs（不能使用 $RSAN_C）** |
| LLD | 16.0.6 | LTO 链接器 |
| CMake | ≥3.20 | 构建系统 |
| Ninja | ≥1.10 | 构建加速 |
| TCMalloc | 2.15 (modified) | RSan 定制的内存分配器 |
| Python 3 | ≥3.8 | RSan 测试框架 |

> **设计要点**：SymCC pass 通过 `-enable-symcc` 编译选项控制开关（默认关闭）。与 `-fsanitize=safe-stack` 控制 SafeStack 一样，SymCC 也遵循"按需启用"的原则，避免对非目标代码的不必要插桩。

### 3.2 环境变量配置

```bash
# === RSan 环境 (必须) ===
source /home/hahafish/SymAFL/RSan/env.sh
# RSAN_TOP, RSAN_C, RSAN_CXX, RSAN_LLVM_BUILD 等
# 注意：source 后当前目录变为 $RSAN_TOP，需 cd 回工作目录

# === SymCC pass 编译环境 ===
export CPATH=/usr/include/z3:$CPATH

# === 运行时库路径 ===
export LD_LIBRARY_PATH=/usr/lib/x86_64-linux-gnu/:$LD_LIBRARY_PATH
```

### 3.3 构建 RSan LLVM (含集成 SymCC pass)

```bash
# 步骤 1: 构建或增量编译 LLVM
cd /home/hahafish/SymAFL/RSan
source env.sh

# 如果 LLVM 未构建，运行完整安装
# ./install-all.sh

# 如果 LLVM 已构建，仅需增量编译修改后的组件
cd $RSAN_LLVM_BUILD
ninja LLVMCodeGen clang lld
```

**构建验证**：

```bash
# 确认 SymCC pass 已编译进 LLVMCodeGen
nm $RSAN_LLVM_BUILD/lib/libLLVMCodeGen.a | grep "createSymCC" 
# 应输出: 0000000000000000 T createSymCCSymbolizePass()

$RSAN_C --version
# 应输出: clang version 16.0.6
```

### 3.4 编译 SymCC 运行时库（使用 LLVM 16 工具链）

> **lmporant**：上一节描述的 stubs 仅用于快速验证编译管线。要启用完整的符号执行引擎（Z3 求解、路径约束生成、`.pct` 文件持久化），需要从头编译 SymCC 运行时库。

**Simple Backend**（无 LLVM 依赖，基础 Z3 求解）：

```bash
cd /home/hahafish/SymAFL/symcc/runtime
RSAN_C=/home/hahafish/SymAFL/RSan/llvm-build/bin/clang
RSAN_CXX=/home/hahafish/SymAFL/RSan/llvm-build/bin/clang++

cmake -G Ninja \
  -DCMAKE_C_COMPILER=$RSAN_C \
  -DCMAKE_CXX_COMPILER=$RSAN_CXX \
  -DCMAKE_BUILD_TYPE=Release \
  -DSYMCC_RT_BACKEND=simple \
  -DZ3_TRUST_SYSTEM_VERSION=ON \
  -S . -B /tmp/symcc-rt-simple && ninja -C /tmp/symcc-rt-simple
```

**QSYM Backend**（需要 LLVM 16 support 库，完整功能：路径剪枝、`.pct` 持久化、去重约束）：

```bash
cmake -G Ninja \
  -DCMAKE_C_COMPILER=$RSAN_C \
  -DCMAKE_CXX_COMPILER=$RSAN_CXX \
  -DCMAKE_BUILD_TYPE=Release \
  -DSYMCC_RT_BACKEND=qsym \
  -DLLVM_VERSION=16 \
  -DLLVM_DIR=/home/hahafish/SymAFL/RSan/llvm-build/lib/cmake/llvm \
  -DZ3_TRUST_SYSTEM_VERSION=ON \
  -S . -B /tmp/symcc-rt-qsym && ninja -C /tmp/symcc-rt-qsym
```

> **注意**：SymAFL 修改版 Runtime 在 `_sym_initialize()` 中嵌入了 AFL forkserver 和共享内存初始化逻辑。因此运行 target 前需要预先创建共享内存段并设置环境变量（见 §4.7 独立测试包装器）。

**验证**：

```bash
nm /tmp/symcc-rt-qsym/libsymcc-rt.a | grep "T _sym_push_path"
# 应有输出，确认运行时包含路径约束求解函数

```bash
objdump -d symcc_stubs.o | grep -A1 '_sym_notify_basic_block>:'
# 应输出: ret  (单条返回指令，无 AFL 插桩代码)
```

---

## 四、编译目标程序

### 4.0 快速开始：使用构建脚本

项目提供了三个便捷脚本，位于 `scripts/` 目录，封装了完整的编译和测试流程：

#### 环境初始化

```bash
source /home/hahafish/SymAFL/scripts/symafl-env.sh
```

设置所有必需的环境变量（`RSAN_C`、`RT_DIR`、`AFL_PATH`、共享库路径等）。

#### `symafl-build` — 一键编译

```bash
# 仅 RSan SafeStack（内存错误检测，无符号执行）
symafl-build read.c -o read-safe

# RSan + SymCC（完整 SymAFL：内存检测 + 符号执行）
symafl-build --symcc read.c -o read-symafl

# 多源文件 + 自定义优化级别
symafl-build -O0 --symcc main.c util.c -o myapp

# 查看所有选项
symafl-build --help
```

| 选项 | 说明 |
|------|------|
| `-O0..-Oz` | 优化级别（默认 `-O2`） |
| `-o <file>` | 输出二进制文件名 |
| `--symcc` | 启用 SymCC 符号执行插桩 |
| `--no-rsan` | 禁用 RSan SafeStack |

#### `symafl-fuzz` — 一键模糊测试

```bash
# 自动创建种子 + 输出目录，启动 AFL++
symafl-fuzz ./read-symafl

# 指定种子和输出目录
symafl-fuzz ./read-symafl my_seeds/ /tmp/my-output

# 完整工作流（两步）
symafl-build --symcc read.c -o read && symafl-fuzz ./read
```

脚本自动处理：
- 输出目录放到 `/tmp`（NTFS 不支持 AFL++ 文件名中的 `:`）
- 种子目录不存在时自动创建默认种子
- `AFL_SKIP_BIN_CHECK=1` 等环境变量
- `-K` 选项启用 PathConTree + 符号模式

> 以下章节为手动编译的详细说明，用于理解底层机制或需要自定义编译参数时参考。

### 4.1 编译选项控制

与 RSan SafeStack（通过 `-fsanitize=safe-stack` 控制）一样，SymCC 通过独立的编译选项控制开关：

| 选项 | 作用 | 传递方式 |
|------|------|---------|
| `-enable-symcc` | 启用 SymCC 符号执行插桩（默认关闭） | 非 LTO: `-mllvm -enable-symcc` |
| | | LTO: `-Wl,-plugin-opt=-enable-symcc` |
| `-fsanitize=safe-stack` | 启用 RSan SafeStack 栈保护 | 标准 clang flag |

> **设计原则**：SafeStack 和 SymCC **独立控制**。可以只用 SafeStack（无符号执行），也可以只用 SymCC（无栈保护），或两者同时启用。

### 4.2 ✅ 已验证的编译命令（x86_64，完整 SymAFL）

```bash
# 环境变量（避免 source env.sh 后目录跳转带来的问题）
export RSAN_C=/home/hahafish/SymAFL/RSan/llvm-build/bin/clang
export RSAN_TC=/home/hahafish/SymAFL/RSan/tcmalloc-impl-build
export RSAN_LDS=/home/hahafish/SymAFL/RSan/linker-implicit/globals/linkglobals.ld
export RSAN_PLD=/home/hahafish/SymAFL/RSan/linker-implicit/libdl/pld.so
export RT_DIR=/tmp/symcc-rt-qsym  # QSYM runtime (推荐)
# export RT_DIR=/tmp/symcc-rt-simple  # Simple runtime (备选)

# === 仅 RSan SafeStack（无 SymCC，无符号执行）===
$RSAN_C -O2 -fno-builtin-malloc -fno-builtin-calloc \
  -fno-builtin-realloc -fno-builtin-free \
  -g -flto=full -fsanitize=safe-stack \
  -fuse-ld=lld -no-pie \
  -T $RSAN_LDS -z max-page-size=0x1000 \
  -Wl,--dynamic-linker=$RSAN_PLD \
  -L$RSAN_TC/lib/ -Wl,-rpath,$RSAN_TC/lib/ \
  target.c -ltcmalloc_minimal -o target-safe

# === RSan + SymCC (完整符号执行) ===
$RSAN_C -O2 -fno-builtin-malloc -fno-builtin-calloc \
  -fno-builtin-realloc -fno-builtin-free \
  -g -flto=full -fsanitize=safe-stack \
  -fuse-ld=lld -no-pie \
  -T $RSAN_LDS -z max-page-size=0x1000 \
  -Wl,--dynamic-linker=$RSAN_PLD \
  -L$RSAN_TC/lib/ -Wl,-rpath,$RSAN_TC/lib/ \
  -Wl,-plugin-opt=-enable-symcc \
  target.c \
  -L$RT_DIR -lsymcc-rt -lz3 -lpthread -ldl \
  -Wl,-rpath,$RT_DIR \
  -ltcmalloc_minimal -o target-symafl
```

### 4.3 LTO 编译过程分解

```
Step 1: Per-TU 编译 (clang -c -flto=full)
  ├── 前端: C → LLVM IR
  ├── IR 优化管线 (per-TU)
  └── 输出 LLVM Bitcode (.o 文件)
      （SafeStack 和 SymCC 此时均不运行——CodeGen 不触发）

Step 2: LTO Link (clang -flto=full → lld)
  ├── 合并所有 Bitcode 为一个 LTO Module
  ├── LTO 优化管线 (buildLTODefaultPipeline)
  │   ├── FullLinkTimeOptimizationEarlyEPCallbacks
  │   ├── ... 全局优化 (inlining, GlobalDCE, ...)
  │   └── FullLinkTimeOptimizationLastEPCallbacks
  │
  ├── CodeGen Pipeline (TargetPassConfig::addISelPrepare)
  │   ├── SafeStackLegacyPass      ← if -fsanitize=safe-stack: RSan 栈保护
  │   ├── SymbolizeLegacyPass      ← if -enable-symcc: SymCC 符号执行 + AFL
  │   │                               否则: no-op（立即返回 false）
  │   ├── StackProtectorPass
  │   └── createVerifierPass
  │
  ├── Instruction Selection       ← SHL+SHR 替换了 BZHI，无 BMI2 依赖
  ├── Register Allocation
  └── Code Emission → 机器码
      （Regular .o 文件（stubs）直接链接，不经 LTO 处理）
```

### 4.4 ✅ 验证编译结果

```bash
# 检查 SymCC 插桩已执行（仅 LTO 阶段的警告）
$RSAN_C ... 2>&1 | grep "Warning"
# 预期输出: "skipping over inline assembly int3"（证明 SymCC 在 SafeStack 之后运行）

# 确认 SafeStack 运行时未被插桩
nm target | grep -c "__noinstrument.*_sym_"  # 应为 0

# 确认 main 被插桩（引用了 SymCC 和 AFL 符号）
nm target | grep "U _sym_notify_basic_block"  # 应有输出
nm target | grep "U __afl_area_ptr"            # 应有输出

# 确认 malloc_symbolized 仅被 main 引用（非 SafeStack 运行时）
objdump -t target | grep "malloc_symbolized"   # 应仅在 main 中出现
```

### 4.5 ✅ 测试验证结果（2026-06-08 实测，LLVM 16 + QSYM Backend）

```
╔══════════════════════════════════════════════════════════════╗
║  SymAFL End-to-End Test (QSYM backend, LLVM 16 toolchain)    ║
╠══════════════════════════════════════════════════════════════╣
║ Test 1: Concrete mode - valid access                         ║
║   SymCC: "running with the QSYM backend"                     ║
║   obj allocated at: 0xc000000ef00                            ║
║   access at index 20... → 0                                  ║
║   ✅ PASS: Returns normally                                  ║
╠══════════════════════════════════════════════════════════════╣
║ Test 2: Concrete mode - OOB detection                        ║
║   ✅ PASS: SIGTRAP (exit 133)                                ║
╠══════════════════════════════════════════════════════════════╣
║ Test 3: Symbolic mode - Z3 path constraint solving            ║
║   (assert (not (= stdin0 #x41)))                             ║
║   → Solved: stdin0 -> #x00                                   ║
║   (assert (= stdin0 #x41) (= stdin1 #x42))                   ║
║   → Solved: stdin0 -> #x41, stdin1 -> #x42                   ║
║   ✅ PASS: Z3 correctly explores alternative paths            ║
╠══════════════════════════════════════════════════════════════╣
║ Test 4: .pct persistence (QSYM backend)                      ║
║   Solver state saved to queue/.pct-000000                    ║
║   ✅ PASS: Constraints persisted for AFL++ integration        ║
╚══════════════════════════════════════════════════════════════╝
```

### 4.6 独立测试包装器

SymAFL 修改版 Runtime 内嵌 AFL forkserver + 共享内存初始化，需预建共享内存段。独立测试（脱离 AFL++）使用以下包装器：

```c
// symafl_runner.c — 编译: gcc -O2 symafl_runner.c -o symafl_runner
// 用法: ./symafl_runner [-s] <target> [args...]
//   -s : 符号模式 (*__symbolic=1), 否则为具体模式 (*__symbolic=0)
```
```bash
# 具体模式（仅 RSan 漏洞检测）
./symafl_runner ./target-symafl 20

# 符号模式（stdin 输入符号化 + Z3 求解）
echo "AAAA" | ./symafl_runner -s ./target-symafl
```
> 在 AFL++ 集成测试中**不需要包装器**——AFL++ 自身通过 `__AFL_SHM_ID` 等环境变量提供共享内存。

### 4.7 常见构建问题

| 问题 | 原因 | 解决 |
|------|------|------|
| `BZHI` / `Cannot select` 崩溃 | 旧版 SafeStack 使用了 BMI2 intrinsic | 确认 `SafeStack.cpp` 中 4 处 BZHI 已替换为 SHL+SHR |
| `malloc_symbolized` 被 `__noinstrument_*` 引用 | `instrumentModule` 仍有全局重命名 | 确认重命名已迁移至 `handleFunctionCall` per-call-site |
| `Unable to create queue/...` (NTFS) | NTFS 不支持文件名中的 `:` | 使用 `-o /tmp/...` 将输出放到 ext4 分区 |
| 无 PathConTree 输出 | `setup_outdir_shmem()` 未写入 `out_dir` 到共享内存 | 在 `afl_shm_init` 之后添加 `strcpy((char *)map, afl->out_dir)` |
| `undefined symbol: _sym_*` | Stubs 未链接或符号名不匹配 | 确认 stubs 中包含全部 `_sym_*` 符号，确认 stubs 被传递给链接器 |

## 五、模糊测试流程

### 5.1 快速启动（推荐）

```bash
# 一条命令完成编译 + 模糊测试
source scripts/symafl-env.sh
symafl-build --symcc read.c -o read && symafl-fuzz ./read
```

### 5.2 手动启动

```bash
# 步骤 1: 编译目标程序
symafl-build --symcc read.c -o read
# 或手动: $RSAN_C ... -Wl,-plugin-opt=-enable-symcc ... read.c -o read

# 步骤 2: 准备初始种子
mkdir seeds && echo "AAAA" > seeds/seed1

# 步骤 3: 启动 AFL++ (SymAFL 模式)
AFL_SKIP_BIN_CHECK=1 AFL_SKIP_CPUFREQ=1 AFL_MAP_SIZE=65536 \
afl-fuzz -i seeds -o /tmp/output -K -m none -t 1000+ -- ./read
```

> **注意**：`-o` 输出目录必须放在 ext4/xfs 等 Linux 原生文件系统上（如 `/tmp`），NTFS 不支持队列条目文件名中的 `:` 字符。

### 5.3 SymAFL 模式测试流程

```
┌─────────────────────────────────────────────────────────┐
│                  afl-fuzz 主循环 (fuzz_one)               │
│                                                         │
│  1. 从种子队列中选择一个种子                               │
│       ↓                                                 │
│  2. Havoc 变异 (多次)                                    │
│       ↓                                                 │
│  3. 对于每个变异候选:                                   │
│       ├── pathcon_tree_check_input(input, size)         │
│       │    ├── 遍历 Path Constraint Binary Tree       │
│       │    ├── 对每个节点: solver.check(pathCon ∧ input) │
│       │    ├── 触发未探索分支 → 返回 depth (> 0)          │
│       │    ├── 未触发新分支 → 返回 -1                    │
│       │    └── PCBT 已充分探索 → 返回 -2                 │
│       │                                                 │
│       ├── depth < 0 → 跳过 (不启动目标程序)              │
│       │                                                 │
│       └── depth >= 0 → concolic execution               │
│            ├── 写入 *__symbolic = 1 (stdin 符号化)        │
│            ├── fuzz_run_target()                        │
│            │    ├── Forkserver fork 前调用 reset_gconfig() │
│            │    │   └── 读取 *__symbolic→1: StdinInput   │
│            │    │       inputFileDescriptor = 0          │
│            │    ├── 子进程执行目标程序并收集路径约束        │
│            │    ├── RSan 内存错误检测 (SIGTRAP)           │
│            │    ├── AFL 覆盖率位图更新                    │
│            │    └── 退出时保存增量 Solver 状态 (.pct)     │
│            ├── 恢复 *__symbolic = 0                      │
│            ├── save_if_interesting()                    │
│            │    ├── 有覆盖增益 → 入队 + InsertTrace      │
│            │    └── 无覆盖增益 → 丢弃候选并增加分支低价值计数 │
│                                                         │
│  4. 每入队 200 个种子：PCBT 可视化输出                    │
│       └── visualize_pathcon_tree(tree, "pct_snapshot")  │
└─────────────────────────────────────────────────────────┘
```

### 5.4 低价值分支剪枝

SymAFL-v1 不包含 focus fuzzing。PCBT 只用于执行前筛选；为防止循环或递归符号分支导致树无限膨胀，每个尚未插入的右侧分支都维护一个“准入后无覆盖增益”计数器：

```
分支反馈流程:
1. CheckInput() 发现候选可到达某个未探索分支
   ├── 记录 insertPoint
   └── 不提前增加低价值计数

2. 候选完成 concolic execution
   ├── 覆盖率有增益
   │   ├── 候选入队
   │   └── InsertTrace() 将该分支纳入 PCBT
   └── 覆盖率无增益
       ├── 删除未使用的 .pct trace
       └── insertPoint 对应分支 no_cov_gain 计数 +1

3. 某分支 no_cov_gain 计数达到 MAX_ALLOWED_RIGHT_CHILD_CNT
   ├── 将该分支视为已充分探索的低价值分支
   ├── 向上传播 expCnt，标记已耗尽的子树
   └── 后续 CheckInput() 不再选择该分支
```

该机制只统计“通过 PCBT 筛选并正常执行后仍无覆盖率增益”的候选；崩溃、超时等异常反馈不按低价值分支处理。

### 5.5 候选吞吐量定义

SymAFL-v1 的吞吐量以 PCBT 处理的候选数为准，而不是目标程序实际执行次数：

```
candidate_throughput = pcbt_candidate_cnt / pcbt_wall_tm

pcbt_candidate_cnt = 被准入候选 + 被拒绝候选 + 触发 PCBT 耗尽的候选
```

`pcbt_concolic_exec_cnt`、拒绝率、CheckInput 耗时和无覆盖增益计数用于解释吞吐量来源；PCBT 耗尽后的普通 AFL 执行阶段必须单独统计，不能与 PCBT 活跃阶段混合。

---

## 六、漏洞检测流程

### 6.1 RSan 内存错误类型

| 错误类型 | 检测方式 | 程序行为 |
|---------|---------|---------|
| 空间越界读/写 (OOB) | Redzone 检查 | `int3` 断点 → SIGTRAP |
| 时序错误 (UAF) | 指针标记 + 元数据检查 | `int3` 断点 → SIGTRAP |
| 双重释放 (Double Free) | 指针标记 + 元数据检查 | `int3` 断点 → SIGTRAP |

### 6.2 崩溃时的约束保存

```cpp
// SymCC runtime: Save solver state on crash
void signal_handler(int sig) {
    save_solver_to_file();  // 保存 .pct-XXXXXX (SMT-LIB 格式)
    signal(sig, SIG_DFL);
    raise(sig);             // 恢复默认处理
}

void save_solver_to_file() {
    // 仅保存 __insert_depth 之后的新增约束
    z3::expr_vector asserts = g_solver->getSolver().assertions();
    for (uint32_t i = *__insert_depth; i < asserts.size(); i++)
        smt2_str << "(assert " << asserts[i].to_string() << ")\n";
    // 写入 {out_dir}/queue/.pct-{queue_entry_id}
}
```

### 6.3 崩溃复现

```bash
# 使用 .pct 文件复现崩溃触发的路径约束
# .pct 文件存储在 output_dir/queue/.pct-XXXXXX

# 使用 Z3 验证约束可满足性
z3 output_dir/queue/.pct-000042

# 若有解，z3 会输出满足约束的输入值 → 复现崩溃
```

---

## 七、关键设计决策与技术难点

### 7.1 Pass 顺序：SafeStack → SymCC

**原因**：SymCC 需要对 SafeStack 插入的检查代码也进行符号化追踪。

```cpp
// TargetPassConfig::addISelPrepare()
addPass(createSafeStackPass());          // Step 1: 栈保护
addPass(createSymCCSymbolizePass());     // Step 2: 符号执行插桩
addPass(createStackProtectorPass());     // Step 3: 栈金丝雀
```

**验证方法**：
- SymCC 警告中出现 SafeStack 特有的 `int3` 内联汇编
- SymCC 警告中出现 SafeStack 的 `extractelement` 指令

### 7.2 BZHI → SHL+SHR 替换

**问题**：RSan 的隐式指针标记使用 `llvm.x86.bmi.bzhi.64` intrinsic，在 LLVM 16 指令选择阶段崩溃。

**解决**：用通用 LLVM IR 指令替换 BMI2 intrinsic，避免 `X86ISD::BZHI` 节点：

```cpp
// 旧代码 (BZHI intrinsic → 崩溃)
Value *BZHImask = builder.CreateIntrinsic(Int64Ty,
    Intrinsic::x86_bmi_bzhi_64, {PtrAsInt, Tag});
Value *BZHIbase = builder.CreateXor(BZHImask, PtrAsInt);

// 新代码 (通用 SHL + LSHR)
Value *ShiftedRight = builder.CreateLShr(PtrAsInt, Tag);  // ptr >> tag
Value *Base = builder.CreateShl(ShiftedRight, Tag);        // (ptr >> tag) << tag
```

### 7.3 选择性插桩

**问题**：SafeStack 运行时函数（`__noinstrument_*`, `__safestack_init`）不应被 SymCC 符号化插桩，否则会导致：
- `malloc_symbolized` 无限递归（asan interceptor + symcc notify_call）
- SafeStack 内部管理的 unsafe stack 被符号化污染

**解决**：在 `shouldInstrument()` 中按函数名前缀/属性精确跳过。

### 7.4 Per-call-site 拦截重定向

**问题**：全局函数重命名（`malloc` → `malloc_symbolized`）会影响所有函数，包括 SafeStack 运行时。

**解决**：移除 `instrumentModule()` 中的全局重命名，改为在 `Symbolizer::handleFunctionCall()` 中逐调用点重定向：

```cpp
// Symbolizer::handleFunctionCall()
if (callee != nullptr && isInterceptedFunction(*callee)) {
    std::string symbolName = (callee->getName() + "_symbolized").str();
    FunctionCallee symbolCallee =
        I.getModule()->getOrInsertFunction(symbolName, callee->getFunctionType());
    I.setCalledFunction(cast<Function>(symbolCallee.getCallee()));
}
```

### 7.5 SymCC Pass 的开关控制

SymCC pass 默认**关闭**，通过 `-enable-symcc` 显式启用。这遵循与 SafeStack 一致的"按需启用"设计：

| 编译场景 | CodeGen 触发？ | SymCC 运行？ |
|---------|---------------|-------------|
| `$RSAN_C -c test.c`（非 LTO，无 flag） | ✅ | ❌ 默认关闭 |
| `$RSAN_C -c -mllvm -enable-symcc test.c`（非 LTO，启用） | ✅ | ✅ |
| `$RSAN_C -c -flto=full test.c`（per-TU LTO） | ❌ | ❌ （CodeGen 不触发） |
| `$RSAN_C -flto=full ... -o bin`（LTO link，无 flag） | ✅ | ❌ 默认关闭 |
| `$RSAN_C -flto=full ... -Wl,-plugin-opt=-enable-symcc -o bin` | ✅ | ✅ |

**实现**：在 `SymbolizeLegacyPass::doInitialization()` / `runOnFunction()` 入口处检查 `ClEnableSymCC`，若为 `false` 则直接返回 `false`（无修改）：

```cpp
// Pass.cpp
static cl::opt<bool> ClEnableSymCC(
    "enable-symcc",
    cl::desc("Enable SymCC symbolic execution instrumentation"),
    cl::init(false));  // 默认关闭

bool SymbolizeLegacyPass::doInitialization(Module &M) {
  if (!ClEnableSymCC)         // ← Pass 仍在管线中，但成为 no-op
    return false;
  return instrumentModule(M);
}
```

**非 LTO 时传递 flag**：`-mllvm -enable-symcc`
**LTO 时传递 flag**：`-Wl,-plugin-opt=-enable-symcc`

### 7.6 双 Forkserver 架构（未来方向）

为进一步降低 SymCC 具体模式的性能开销，考虑采用双 Forkserver 架构：

```
Forkserver 1 (afl-clang 编译的程序):
  └── 传统 fuzzing (高吞吐率具体执行)

Forkserver 2 (symcc 编译的程序):
  └── 符号执行 (路径约束收集)

CheckServer:
  └── PathConTree::CheckInput() (高速约束求解预筛)
```

---

## 八、测试验证清单

### 8.1 编译验证

- [x] LLVM 构建成功 (`ninja LLVMCodeGen clang lld`) ✅ 2026-06-04
- [x] `nm libLLVMCodeGen.a | grep "createSymCC"` 有输出 ✅
- [x] RSan examples (`oob.c`, `uaf.c`) LTO 编译成功（通过 CodeGen，无 BZHI 崩溃） ✅
- [x] `malloc_symbolized` 仅被 `main` 引用，不被 `__noinstrument_*` 引用 ✅
- [x] SymCC 警告中出现 SafeStack 的 `int3` 内联汇编（证明 SymCC 在 SafeStack 后运行） ✅

### 8.2 功能验证

- [x] `shouldInstrument()` 正确跳过 `__noinstrument_*` 函数 ✅
- [x] `shouldInstrument()` 正确跳过 `__safestack_init` ✅
- [x] `shouldInstrument()` 正确跳过 `__interceptor_*` 函数 ✅
- [x] Per-call-site 重定向在 instrumented 函数中生效（`main`→`malloc_symbolized`） ✅
- [x] Per-call-site 重定向在 skipped 函数中不生效（`__noinstrument_*`→`malloc`） ✅

### 8.3 运行时测试

- [x] oob valid (index 30): 正常返回 0 ✅
- [x] oob invalid (index 40): SIGTRAP (exit 133) 正确检测 OOB ✅
- [x] uaf: SIGTRAP (exit 133) 正确检测 UAF ✅
- [x] `-enable-symcc` flag 正确控制 SymCC 开关 ✅
- [x] SymCC ON: main() 1308 行汇编（插桩）/ OFF: 65 行（无插桩）✅

---

## 九、常见问题排查

### Q0: 如何启用/禁用 SymCC？

- **启用**：LTO link 时传递 `-Wl,-plugin-opt=-enable-symcc`
- **禁用**：省略该 flag（默认关闭）
- SymCC 与 SafeStack 独立控制：`-fsanitize=safe-stack` 控制 RSan，`-enable-symcc` 控制 SymCC

### Q1: `Cannot select: X86ISD::BZHI` 崩溃

**原因**：使用了旧版 BZHI intrinsic 的 SafeStack。

**解决**：确认 SafeStack.cpp 中 4 处 BZHI 已替换为 SHL+SHR。

### Q2: `__noinstrument_dyn_alloc` 引用了 `malloc_symbolized`

**原因**：全局函数重命名未被移除。

**解决**：确认 `instrumentModule()` 中不再有 `function.setName(name + "_symbolized")`。

### Q3: 链接器报 `undefined symbol: _sym_*`

**原因**：SymCC 运行时库未链接。

**解决**：使用 `symcc`/`sym++` wrapper 编译，或手动添加 `-lsymcc-rt -L<runtime_dir> -Wl,-rpath,<runtime_dir>`。

### Q4: 编译 stubs 时出现递归插桩 / segfault

**原因**：使用了不带 `-enable-symcc` 的旧版 SymCC pass（无条件运行）。SymCC 对 `_sym_notify_basic_block` 等 stub 函数插桩后，形成自递归调用。

**解决**：已通过 `-enable-symcc` flag 修复。确认 `ClEnableSymCC` 默认值为 `false`，编译 stubs 时不用传递任何 flag。

### Q5: AFL++ 报告 "not instrumented"

**原因**：AFL++ 检查 `__AFL_SHM_ID` 符号。

**解决**：设置 `export AFL_SKIP_BIN_CHECK=1`。

---

## 十、参考文献

- SymCC: Compiler-based Concolic Execution. USENIX Security 2020.
- RangeSanitizer: Efficient Range Checks for Spatial and Temporal Memory Safety. USENIX Security 2025.
- AFL++: Combining Incremental Steps of Fuzzing Research. USENIX WOOT 2020.
- [SymCC Analysis Report](symcc/SYMCC_ANALYSIS_REPORT.md)
