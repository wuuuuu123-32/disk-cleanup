# 删除安全核查清单

这份清单**只能否决，不能批准**。全部通过不意味着「可以删」，只等于「在已检查的范围内，我没找到反对的理由」。最终删不删由用户决定。

每一条都配了「它能证明什么 / 它不能证明什么」。这个区分是整个 skill 的重点——2026-11-25 那场对话里我判错的两次，都不是查得不够，而是把「已检查范围内没发现」当成了「不存在」。

---

## A. 引用检查

**能证明**：命中了 → 确实有依赖 → **否决**
**不能证明**：零命中 → 没依赖

### A1. 文件系统引用（最容易，也最容易漏）

全盘搜路径与文件名：

```powershell
# 搜路径字面量（注意：只覆盖文本文件，见下面的局限）
Get-ChildItem 'D:\' -Recurse -Include *.py,*.js,*.mjs,*.json,*.yml,*.yaml,*.ps1,*.bat,*.cmd,*.txt,*.md `
  -ErrorAction SilentlyContinue |
  Select-String -Pattern '目标文件名或路径片段' -SimpleMatch -Encoding UTF8
```

**局限（必须写在结论里）**：
- 只覆盖文本文件 → 二进制配置、注册表、快捷方式、数据库里的路径都搜不到
- 相对路径、环境变量展开、字符串拼接（`os.path.join(BASE, name)`）会绕过字面量匹配
- `-ErrorAction SilentlyContinue` 会静默吞掉权限失败 —— 这些文件等于没检查

### A2. 文本搜索覆盖不到的调用方（必须逐个查，不能靠 grep）

这是会审明确点出的缺口：「命中可以证明存在关联，零命中只能说明在已检查范围内未发现」。

| 调用方 | 查法 | 为什么 grep 不到 |
|---|---|---|
| 计划任务 | `Get-ScheduledTask \| Where-Object { $_.Actions.Execute -match '目标' -or $_.Actions.Arguments -match '目标' }` | 存在任务数据库里，不是文件 |
| Windows 服务 | `Get-CimInstance Win32_Service \| Where-Object { $_.PathName -match '目标' }` | 存在注册表 + SCM |
| 开机自启 | `Get-ItemProperty 'HKCU:\...\Run'`、`HKLM:\...\Run`、启动文件夹 | 注册表 / 目录里的 .lnk |
| 快捷方式 | 解析 .lnk 的 TargetPath（WScript.Shell） | .lnk 是二进制 |
| **环境变量 / PATH** | `[Environment]::GetEnvironmentVariable('X','Machine'/'User')`、`$env:PATH` 分段 | 值存在注册表，且程序自己在运行时拼接 |
| **应用配置文件里的路径模板** | 定位程序的配置目录（`%APPDATA%\<程序>`、程序目录下 `*.json/ini/cfg/toml/yaml`） | 存的是 `{model_dir}\{name}.gguf` 这类模板，字面量搜不到 |
| **最近使用记录** | `.lnk` 的 MRU（`HKCU:\...\Explorer\RecentDocs`）、文件打开历史、`%APPDATA%` 里应用的 recent 列表 | 这是「用户最近主动用过它」的唯一可查痕迹 |
| **驱动 / 内核组件** | `Get-CimInstance Win32_SystemDriver \| Where-Object { $_.PathName -match '目标' }` | 存在注册表，SCM 的另一个枚举面 |
| **包管理器持有** | `pip show` / `conda list` / `npm ls -g` 的记录，以及包元数据里的 `RECORD`、`direct_url.json` | 包管理器用自己的清单管文件，不写在被管文件里 |
| **容器 / 虚拟机磁盘** | `.vdi` / `.vmdk` / `.vhdx` / `.qcow2` 里可能装着目标文件的另一份 | 文本搜索看不进容器镜像 |

**真实案例（2026-11-25，`E:\pcsuite`）**：目录 295 天没动，`Get-Process` 查不到任何进程占用，看起来是死目录。删除后剩 39 个文件删不掉，报 `Access is denied`。真凶是三个开机自启服务（`Everything`、`vivoesService`、`vivoSyncService`）—— 它们由 SCM 持有，`Get-Process` 里根本看不到，只有查 `Win32_Service.PathName` 才现形。

**真实案例（2026-11-25，`E:\sing` 的 6.3 环境）**：`cover.local.json` 里 `engines.ddsp63` 的 `dir` 指向 6.3，但 `env` 指向 **6.2 的 python.exe** —— 光看目录结构会以为 6.3 是独立环境，读了配置才知道它从来没被引用过。这类「配置文件里的固定路径」只能靠读配置发现，grep 目录名没用。

**⇒ 硬规则：`Get-Process` 查不到占用，不等于没有占用。必须同时查服务、驱动、计划任务、环境变量、配置模板。**

### A3. 配置里的固定路径

即使文件本身没被引用，它也可能被配置指向。查配置文件里的绝对路径：

```powershell
Get-ChildItem -Recurse -Include *.json,*.yml,*.yaml,*.ini,*.cfg,*.conf -ErrorAction SilentlyContinue |
  Select-String -Pattern '目标路径' -SimpleMatch
```

**真实案例**：`D:\ollama\chat-server.py` 第 46-58 行把两个 gguf 的绝对路径写死成写作档位；`chat-server.py:379` 还有 `if not os.path.exists(m["gguf"]): return False, "找不到模型文件"` —— 删了直接报错，不是静默降级。

---

## B. 重复性证明

**能证明**：完整哈希不同 → 确实不重复 → **否决**
**不能证明**：哈希相同 → 可以删

### B1. 首尾指纹只能用来「筛出不相同的」

```powershell
function Get-EdgeHash([string]$path, [int]$chunkMB = 8) {
  $fs = [System.IO.File]::OpenRead($path)
  try {
    $len = $fs.Length
    $chunk = [Math]::Min($chunkMB * 1MB, [int][Math]::Min($len, [int64]2147483647))
    $buf = New-Object byte[] $chunk
    $null = $fs.Read($buf, 0, $chunk)
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $head = [BitConverter]::ToString($md5.ComputeHash($buf)).Replace('-','')
    $fs.Seek([Math]::Max(0, $len - $chunk), 'Begin') | Out-Null
    $buf2 = New-Object byte[] $chunk
    $null = $fs.Read($buf2, 0, $chunk)
    $tail = [BitConverter]::ToString($md5.ComputeHash($buf2)).Replace('-','')
    return "len=$len head=$head tail=$tail"
  } finally { $fs.Dispose() }
}
```

**这个函数曾经因为 `[Math]::Max(0, $len-1MB)` 报 `无法将"Max"的参数 val2 转换为 Int32` 而失败**（长整型溢出）—— 用 `[int64]` 或先 `if` 判再算。

**首尾相同 ≠ 重复**。会审给的反例：

> 「两个大型镜像长度、首尾各 8MB 完全相同，中间分区存放不同数据；首尾指纹相同却不是重复文件。」

指纹相同之后：
- 如果这是**最终候选** → 做完整哈希（`Get-FileHash`）
- 如果不是 → 不做结论，只在候选表里标「首尾相同，未做完整校验」

### B2. 完整哈希相同也不是删除的充分条件

还得确认三件事，缺一件就否决：

1. **保留副本可读** —— 副本本身没坏、权限正常、不是也在候选里（两份同时删 = 全没了）
2. **没有固定路径引用** —— 两个文件内容一样，但程序只认其中一个路径
3. **元数据不会丢** —— 时间戳、权限、备用数据流（ADS）

**真实案例**：`D:\piano\Salamander.sf2` 与 `D:\pycode\e_piano\piano.sf2` 首尾指纹完全相同（len=1266462334，head/tail 一致）。但 `e_piano` 代码用 `resource_path("piano.sf2")` 按相对路径找自己目录下那份 —— 所以删的是 `D:\piano` 那份（无引用），保留 `e_piano` 那份。**如果反过来删，程序会找不到音源。**

---

## C. 活跃度

**能证明**：最近有写入 → **否决**
**不能证明**：长期没写 → 没用

### C1. LastWrite 的正确用法

只用来**否决**，不用来批准：

```powershell
# 目标目录里最新的写入时间
Get-ChildItem '目标' -Recurse -File -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Descending | Select-Object -First 1 LastWriteTime, FullName
```

如果最新写入在**几分钟内** → 正在被写 → 停手。

**真实案例（2026-11-25，`E:\NetEase\Cache` 9.42 GB）**：清单上标着「网易云歌曲缓存，可清」。执行前一条命令查最新文件时间戳，发现 `11/25/2026 18:32:31` —— 就在动手前一分钟。⇒ 当前运行的网易云用的就是这个目录，删了会打断播放。**保留，并单独向用户提出**。这是这一轮里唯一一项「清单说可删但实际不能删」的东西。

**LastAccess 不要用**：本机 `fsutil behavior query disablelastaccess` 是 `System Managed, ENABLED`，访问时间确实会更新 —— 但扫描本身就会刷新它。用它判断「多久没动」是在测量自己的脚印。

### C2. 什么都不能证明的情况

会审列出的完整清单：

> 「某离线模型半年未修改，没有运行进程，路径由环境变量与模型名拼接生成，全盘文本搜索零命中；三项检查仍可能把唯一模型文件误判为可删。」

这种情况的正确处理不是「我判断它没用」，而是写进候选表：

```
路径: D:\xxx\model.bin   体积: 17.4 GB
用途: 推断为 LLM 权重（文件名含 35B / Q4）
否决检查: 未命中（grep 零命中，但该路径由环境变量拼接，文本搜索不可靠）
证据缺口: 无法确认是否被引用 —— 需要用户确认「这个模型还要不要」
```

---

## D. 冲突裁决

会审要求：「发现明确引用或用户仍需保留时，其他弱证据不能抵消它；无法检查的项目也不能按检查通过处理。」

裁决顺序（从强到弱，**上位覆盖下位，不可加权抵消**）：

1. 用户说过「要留着」→ **否决，终局**
2. 命中引用（A1/A2/A3 任一）→ **否决**
3. 最近有写入（C1）→ **否决**
4. 完整哈希不同（B2）→ **否决「重复」这个理由**
5. 以上都没命中 → **不构成批准**，只是「无可否决项」，交回用户

**注意第 5 条**：三道检查全过不等于可删。这正是会审 `fail` 的核心原因——我原来的设计把「三项都检查过」当成了「三项共同证明可删」。

---

## E. 执行前复查（检查到执行之间状态会变）

> 会审反例：「删前检查没有写入，随后自动启动的同步服务开始写文件；检查结果在 rd 执行前已经失效。」

执行前**紧邻地**再查一次，只对已被用户点名的路径：

```powershell
$t = '被点名的路径'
# 1) 占用：进程 + 服务（两个都要）
Get-Process | Where-Object { $_.Path -like "$t*" } | Select-Object Id, ProcessName, Path
Get-CimInstance Win32_Service | Where-Object { $_.PathName -like "*$t*" } | Select-Object Name, State, StartMode, PathName
# 2) 最新写入
Get-ChildItem $t -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
# 3) reparse：目标本身 + 所有后代 + 祖先
(Get-Item $t -Force).Attributes -band [IO.FileAttributes]::ReparsePoint
Get-ChildItem $t -Recurse -Force -ErrorAction SilentlyContinue | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }
```

**reparse point 检查必须覆盖祖先**，不只是目标本身。会审的措辞：「reparse point 防线没有明确覆盖候选目录本身、所有后代和祖先路径」。删一个 junction 会删到它指向的真实目录 —— 那是删穿到别处。

**真实案例**：`E:\sing\04_模型推理_DDSP-SVC-6.3\DDSP-SVC-6.3\env` 是指向 6.2 的 junction。如果按「6.3 目录占 8.75 GB」把它整个删掉，实际会删掉 6.2 的 env（7.77 GB）—— 另一个目录的核心依赖。

---

## F. 执行中的停止条件

任一条命中 → **立即停**，不继续后面的项，把状态如实报出来：

| 条件 | 为什么必须停 |
|---|---|
| 日志写不进去 | `Add-Content` 不保证成功。不能出现「删了但没记录」——事后无法对账 |
| 某项部分删除失败 | **「目录还在」不能表达已经发生的部分删除**。必须列出已删/未删 |
| 出现权限拒绝 | 不要跳过继续。跳过 = 把「没删成」当成「删完了」 |

**提权的坑（真实踩过两次）**：

1. **提权 + `.cmd` 日志重定向会静默失效**。用 `>> "%LOG%"` 时如果日志文件被 `sc`/`rd` 占用，**整段重定向失效**，只有部分输出进去。实测日志里 10 条 `另一个程序正在使用此文件，进程无法访问。`，对应 10 个 `sc` 命令全部没记录。
   ⇒ 改用提权 PowerShell 脚本 + `Add-Content -LiteralPath`。

2. **非管理员跑 `bcdedit` / `sc stop` 会报 Access denied**，而且这个失败可能被后续逻辑吞掉，表现为「脚本显示成功但没改」。
   ⇒ 每一步都用 `errorlevel` 检查，失败就置 `FAILED=1` 并跳报告段，明确输出 `NOT APPLIED`。

---

## G. 对账口径

三个数必须分开报，不能混成一个「释放了 X GB」：

1. **已删除路径清单** —— 逐项记字节数，落到文件
2. **估算体积** —— 删前扫出来的字节数之和
3. **实际空间变化** —— 删前删后的 `Get-PSDrive` 差值

三者不相等是正常的（并发写入、文件系统分配差异、回收站未清）。**差值本身不是错误，把它们当成一回事才是。**

**对账公式**：`净增 = 释放总量 − 期间新增`。如果对不上，说明有别的进程在写，要去找，不能就这么报一个数。

---

## 附：这份清单本身的局限

它挡不住的情况，写在这里以免被当成万灵药：

- **程序退出期间做的检查**：程序每天读同一素材库但从不修改，检查时刚好退出 → 旧时间戳 + 无占用 = 看起来完全可删
- **目录外宿主访问**：服务通过别的进程读数据，目标目录里查不到占用
- **用户用途无法从文件推断**：课程软件、存档、历史项目——技术上全都不活跃，但用户要留着
- **首尾指纹碰撞**（见 B1）
- **检查后的状态变化**（见 E）

⇒ 所以最后一条防线永远是：**用户逐项点名**。