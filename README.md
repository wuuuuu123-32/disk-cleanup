# disk-cleanup

一个 DSH skill：分析磁盘占用，找出「下载后长期没动」的东西，**然后停手**。

它只产出**候选清单和证据缺口**，永远不替用户决定删什么。删除是用户逐项点名后才执行的不可逆动作。

## 为什么会有这个东西

2026-11-25 的一场对话里，我（agent）在同一个会话中连续判错两次：

- 拿「`ollama list` 里没有这个模型」当成「系统里没在用」——实际它被 `D:\ollama\chat-server.py` 第 46-58 行按绝对路径写死成写作档位，删了会报「找不到模型文件」
- 拿「两个目录同名、体积接近」当成「重复」——实际是一个游戏的一代（UE4 打包）和二代（GDK 打包）

两次都不是查得不够多，而是**判据本身错了**。后来陆续又踩了六个坑：junction 重复计数、`Get-Process` 看不见服务占用、清单说可删实际正在写、云缓存里其实是别人的解压包、计划任务会把删掉的自启项写回来、把文件长度之和当成了占多少盘。

于是把「怎么不判错」写成了流程。

## 核心原则

**技术证据永远无法推出「用户不再需要」。** 一个文件可以零引用、哈希独有、半年没写、无进程无服务占着，而它仍然是用户要留着的课程软件、离线素材、存档或历史项目。

所以：

- 所有检查都是**否决式**的 —— 任一条命中就永久排除；全部通过**不等于**可删，只等于「我没找到反对的理由」
- 交付物是**三张表**（候选 / 保留项汇总 / 未完成项），不是一个结论
- 「授权状态」是独立一列，只有用户能把它从 `未授权` 改成 `已授权`

## 五阶段

| 阶段 | 做什么 | 关键约束 |
|---|---|---|
| 1 · 扫描 | 一级目录体积/文件数/首末 LastWrite | 自报不完整性；junction 只记不跟；逻辑长度 ≠ 实际占用 |
| 2 · 分类 | 按用途分七类 | **只标用途，不标「能否动」** |
| 3 · 定证 | 引用 / 重复 / 活跃度 三道否决 | 全过 ≠ 可删 |
| 4 · 交付 | 候选 / 保留 / 未完成 三张表 | 每项写证据缺口 + 授权状态 |
| 5 · 执行 | 只执行用户逐项点名的准确路径 | 先列清单再执行，不许边列边删 |

详细流程见 [`SKILL.md`](SKILL.md)，逐条检查法见 [`references/checklist.md`](references/checklist.md)，八条真实误判见 [`references/misjudgments.md`](references/misjudgments.md)。

## 扫描脚本

`scripts/scan.ps1`，纯 ASCII + CRLF（PowerShell 5.1 无 BOM 时按 GBK 解码，中文表头会把脚本解析炸掉）。

```powershell
$ps = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"

# 一级目录体积普查（分钟级扫完 1.6M 文件）
& $ps -NoProfile -ExecutionPolicy Bypass -File scripts/scan.ps1 -Root 'D:\' -TopN 40

# 带年龄分桶
& $ps -NoProfile -ExecutionPolicy Bypass -File scripts/scan.ps1 -Root 'E:\' -Aging

# 最终候选：同时量逻辑长度与实际占用，并去重硬链接
& $ps -NoProfile -ExecutionPolicy Bypass -File scripts/scan.ps1 -Root 'D:\anaconda3' -Physical

# 把跳过的 junction 全量落盘，逐条核对目标路径与卷
& $ps -NoProfile -ExecutionPolicy Bypass -File scripts/scan.ps1 -Root 'D:\' -ReparseOut reparse.json
```

### 参数

| 参数 | 作用 |
|---|---|
| `-Root` | 盘符根或任意目录，一级子目录并行扫描 |
| `-TopN` | 打印前 N 行（默认 40），JSON 里始终是全量 |
| `-OutFile` | 落 UTF-8 无 BOM JSON，便于前后对比 |
| `-Aging` | 按 LastWrite 分 5 桶：0-30 / 31-90 / 91-180 / 181-365 / >365 天 |
| `-Physical` | 另测分配大小并按文件 id 去重硬链接（每文件多一次系统调用，用在候选级而非整盘） |
| `-ReparseOut` | 把跳过的 reparse 全量落盘：kind / path / target / targetVolume |

### 三件事它一定要报出来

**1. 不完整性。** `reparse-skipped` / `denied` / `unreadable-dirs` 任一非零就打印 `WARNING: scan is PARTIAL. Do not present totals as complete.` 不完整的扫描被当成完整结论，等于把「我没看到」说成「不存在」。

**2. junction 的目标在哪。** 只报「跳过了 N 个」是不够的 —— 数字小了，你不知道少的字节去了哪里。三分类：

| 分类 | 含义 | 少算了吗 |
|---|---|---|
| `same-volume` | 目标在本卷，字节仍能在本卷别处被扫到 | 只是没重复计 |
| `other-volume` | 目标在**另一个卷**，完全不在本次扫描里 | **真漏计** |
| `unresolved` | 目标解析失败 | **未知，当漏计报** |

实测 D 盘（2026-11-25）：1035 个 reparse 全部 `same-volume`，`other-volume=0 / unresolved=0`。为验证这个结论，把 1035 个目标去重成 888 个逐一求和 = **2.41 GB**；而「跟随 junction」的旧版本报 45.21 GB、「跳过」的新版本报 42.66 GB，差 **2.55 GB** —— 对得上（0.14 GB 出入对应 4 个 denied + 2 个不可读目录 + 期间文件变化）。

**3. 逻辑长度和实际占用。** `FileInfo.Length` 是逻辑长度：硬链接按链接数重复计、稀疏文件报名义大小、NTFS 压缩报未压缩大小。`-Physical` 改用 `GetCompressedFileSize` 取分配大小并按文件 id 去重。

实测 `D:\anaconda3`：

```
total 9.74 GB (logical)
physical: allocated 5.12 GB / hardlink-dedup saved 4.62 GB
```

那 4.62 GB 全是硬链接 —— `pkgs\pandoc-...\bin\pandoc.exe` 与 `anaconda3\Library\bin\pandoc.exe` 是同一个 inode，所以 `conda clean --all` 清不掉 `pkgs` 那 5 GB 是对的：删 pkgs 等于删 base 环境里的包。

## 安装

```powershell
New-Item -ItemType Junction -Path "$HOME\.dsh\skills\disk-cleanup" -Target '<repo path>'
```

必须是 **Junction**（免提权）。`SymbolicLink` 会要求管理员权限，且失败时会把旧目录改名后卡住。

## 局限

这份流程挡不住的情况，写在这里以免被当成万灵药：

- **程序退出期间做的检查**：程序每天读同一素材库但从不修改，检查时刚好退出 → 旧时间戳 + 无占用 = 看起来完全可删
- **目录外宿主访问**：服务通过别的进程读数据，目标目录里查不到占用
- **用户用途无法从文件推断**：课程软件、存档、历史项目——技术上全都不活跃，但用户要留着
- **首尾指纹碰撞**：两个镜像长度与首尾 8MB 相同但中间不同
- **检查后的状态变化**：检查完到真正删除之间，自动启动的同步服务可能开始写

⇒ 最后一条防线永远是：**用户逐项点名**。

## 许可

MIT