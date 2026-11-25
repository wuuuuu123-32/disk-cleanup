# 误判案例簿

这份文件收录**真实发生过的误判**，每条都写清楚：当时看到什么、我据此得出了什么结论、实际是什么、错误在判据的哪一环。

它的用途不是「长经验」这种空话。每次要判「这东西能不能删」之前，把这份簿子过一遍——**里面每一条都是我（agent）在同类判断上栽过的跟头**，而它们全都发生在「查得挺认真」的情况下。

---

## 案例 1 · 拿软件管理器的清单当系统的事实

**对象**：`D:\ollama\gguf\Qwen3.6-35B-A3B-Uncensored-HauhauCS-IQ4_XS.gguf`（17.44 GB）、`Qwen3.5-9B-Defiant-Fable-Q4_K_M.gguf`（6.36 GB）

**当时看到的**：`ollama list` 只有 3 个模型（9B、embedding、一个 abliterated 9b），**没有 35B**。于是我在候选表里写「35B 从没 build 成模型，可删」，把两项合计 23.80 GB 列进了「我可直接动手」那一档。

**用户的反应**：

> 「ollama 35B gguf 17.44（从没 build 成模型）+ 9B 重复 gguf 6.36 = 23.80**这个你确定**我们的本地的画图，写作等等都用不上或者说是重复的？」

**实际是什么**：这两个 gguf 根本不属于 ollama。`D:\ollama\chat-server.py`（1704 行，2026-11-14）第 46-58 行把它们写死成 llama.cpp 的两个档位：

```python
LC_MODELS = {
    "lc-9b":  {"gguf": r"D:\ollama\gguf\Qwen3.5-9B-Defiant-Fable-Q4_K_M.gguf",          "label": "⚡9B 快档",   "ctx": 16384},
    "lc-35b": {"gguf": r"D:\ollama\gguf\Qwen3.6-35B-A3B-Uncensored-HauhauCS-IQ4_XS.gguf", "label": "⚡35B 质量档", "ctx": 32768},
}
```

`chat-server.py:379` 还有存在性检查 `if not os.path.exists(m["gguf"]): return False, "找不到模型文件：%s"` —— 删了直接报错。

**证据是现成的**：`D:\ollama\_llamacpp-server.log`（223750 B）里有 40 多次 `load_model: loading model 'D:\ollama\gguf\Qwen3.6-35B...'` → `listening on http://127.0.0.1:8199` → `eval time ... 34.80 tokens per second`。

**9B 那份更微妙**：它与 ollama blob `sha256-d33db...` 的 SHA256 完全相同（`D33DB5E583B9C925...`，6828993824 字节）——按「重复」判据似乎可以删一份。但 `lc-9b` 档位和 `start-llamacpp-9b.cmd` 都直接指向 `gguf\` 里那个路径，**删了同样报错**。

**错在哪一环**：`ollama list` 是**某个软件的模型库**，不是**系统的使用事实**。同一个 gguf 文件可以被任何程序按绝对路径加载，完全绕开 ollama 的模型注册表。我把「A 系统的清单」当成了「全局事实」。

**判据修正**：查使用情况时，不能只看某个管理器的清单。必须查 `checklist.md` 的 A2 那四类调用方，其中**配置文件里的固定路径**这一项是最容易漏的。

---

## 案例 2 · 拿同名当重复

**对象**：`D:\load new\Minecraft Dungeons`（5.43 GB）与 `D:\Games\Minecraft Dungeons 2`（8.90 GB）

**当时看到的**：两个目录都叫「Minecraft Dungeons」，体积接近，其中一个是大量 UE4 的 `pakchunkN-WindowsNoEditor.pak`。我在候选表里写「`load new` 里有一份重复的 Minecraft Dungeons，5.43 GB，可删」。

**实际是什么**：

| | `load new\Minecraft Dungeons` | `Games\Minecraft Dungeons 2` |
|---|---|---|
| 主程序 | `Dungeons-Win64-Shipping.exe` 35.9 MB | `Dungeons-WinGDK-Shipping.exe` 184.2 MB |
| 资源 | `pakchunk0..12-WindowsNoEditor.pak`（UE4） | `Dungeons-WinGDK.ucas` 8.24 GB（GDK 打包） |
| 特征文件 | — | `Binaries\WinGDK\ms_emu.json` |

**是同一系列的两个不同游戏**（一代用 UE4 打包，二代用 GDK 容器）。`ms_emu.json` 这个文件说明二代是走 GDK 的版本。

**错在哪一环**：我把「名字像 + 体积接近」当成了「同一份东西的两次拷贝」。真正的重复必须有**内容证据**（完整哈希），而这里连首尾指纹都没做过——只是名字像。

**判据修正**：「同名/同大小」进候选表之前，必须先做首尾指纹。指纹不同就当场出局，不允许以「重复」的名义出现在候选里。

---

## 案例 3 · 被 junction 骗走 8.75 GB

**对象**：`E:\sing`（表面 31.45 GB，实际 22.70 GB）

**当时看到的**：`E:\sing` 下有 5 个子目录，其中 `04_模型推理_DDSP-SVC-6.3\DDSP-SVC-6.3` 报 8.75 GB，与 `02_模型推理_DDSP-SVC-6.2\DDSP-barbara-6.2` 的 9.20 GB 高度相似，两者合计看起来是「两套完整环境」。分类时我把 sing 算成 31.45 GB。

**实际是什么**：6.3 目录下的 `env` 和 `pretrain` 都是**指向 6.2 同名的 junction**。扫描器跟着 junction 走了一遍同一棵树，把 6.2 的 8.75 GB 又算了一次。

判断依据是三条：
- 两份 `env\Lib\site-packages` 目录名列表**完全相同**（各 183 个，独有 0 个）
- `torch\lib` 各 60 个文件，同名同大小 **60/60**
- `torch\lib\dnnl.lib`（2.17 GB）的 SHA256 前段三份环境全一致：`4B33901803A0DB40B067...`
- `D:\dsh\config\dsh-cover-pipeline\cover.local.json` 里 `engines.ddsp63` 的 `dir` 指向 6.3，但 `env` 指向 **6.2 的 python.exe** —— 6.3 自己的 env 从来没被引用过

**错在哪一环**：我用一个会跟随 reparse point 的递归枚举去量体积。junction 让同一份数据在树上出现两次，体积和「目录个数」一起虚高。

**判据修正**：扫描必须跳过 reparse point 并**把跳过的数量报出来**（`scripts/scan.ps1` 现在这么做了，实测 `E:\sing` 报 `reparse-skipped=2`、总数从 31.45 修正为 22.03 GB）。删除前必须检查目标本身、所有后代、**以及祖先**是不是 junction —— 删一个 junction 会删到它指向的真实目录，那是删穿到别处。

---

## 案例 4 · `Get-Process` 看不见服务占用

**对象**：`E:\pcsuite`（1.44 GB，295 天没动）

**当时看到的**：目录 295 天未修改，`Get-CimInstance Win32_Process` 查 `ExecutablePath -like 'E:\pcsuite\*'` **零命中**，没有任何进程占用。判定为死目录，开始删。

**实际是什么**：删到剩 **39 个文件 / 0.04 GB** 时 `rd /s /q` 报 39 条 `Access is denied`。真凶是三个 Running/Automatic 的 **Windows 服务**：

```
Everything      → "E:\pcsuite\drivers\x64\Everything\Everything.exe" -svc
vivoesService   → "E:\pcsuite\vivoesService\x64\vivoesService_x64.exe"
vivoSyncService → "E:\pcsuite\SyncService\vivoSyncService.exe"
```

服务由 SCM（服务控制管理器）持有，**不在 `Get-Process` 的进程列表里**，只有查 `Get-CimInstance Win32_Service` 的 `PathName` 才看得见。

**顺带一个损失**：那个 `Everything.exe` 是 pcsuite 捆绑版，被注册成开机自启服务，**全盘只有这一份**（`C:\Program Files`、`Program Files (x86)`、`D:\`、`E:\` 深度 4 递归只命中它自己）。删完后 Everything 搜索就没了 —— 桌面另有「图吧工具箱」里的便携版可代替，但这是我该提前告知的。

**错在哪一环**：我把「进程列表」当成了「占用者的全集」。文件的持有者有至少三种：进程、服务、驱动。只查第一种。

**判据修正**：`Get-Process` 查不到 ≠ 没占用。`checklist.md` A2 把服务列成必查项；执行前复查（E 节）两个都要查。

---

## 案例 5 · 清单说可删，实际正在写

**对象**：`E:\NetEase\Cache`（9.42 GB）

**当时看到的**：网易云的歌曲缓存目录，`.uc` 加密缓存文件，看名字就是缓存。清单里标「可清」。

**差一点就删了。** 执行前一条命令查最新时间戳：

```
11/25/2026 18:32:31  e\3347133433-4999-c66b41503211e701a55083f243e17315.uc  16.0 MB
11/25/2026 18:32:18  e\507585217-...e.info / .idx
11/25/2026 18:30:09  23.5 MB
```

**就在动手前一分钟还在写。** 而且 `D:\CloudMusic`（客户端本体）下**没有** Cache 目录 —— 说明当前运行的网易云用的就是 `E:\NetEase\Cache` 这个路径。删了会打断播放。

同一批里另一份 `E:\NetEase\CloudMusic\Cache`（6.31 GB）全部时间戳停在 `05/11/2026 18:54:46`，6 个月没动 —— 那份是真垃圾，删了。

**错在哪一环**：我把「文件的类型（缓存）」当成了「文件的状态（未被使用）」。缓存也可能正被当前会话写着。

**判据修正**：任何候选在动手前，必须查**目标目录内最新的写入时间**。几分钟内 → 停手。这一条救回了 9.42 GB 的误删，也把「清单」和「现场」这两件事分开了。

---

## 案例 6 · 云缓存看起来是垃圾，其实是别人的解压包

**对象**：`D:\Google drive locakl cashed\...\content_cache\d55\d4\457`（8.23 GB，2 个文件）

**当时看到的**：Google Drive 桌面版的 `content_cache`，路径名里还有拼写错误（`locakl cashed`）。按目录名判断就是传输缓存，清单标「会自动重下」。

**实际情况（删前查证）**：文件头是 `37 7A BC AF 27 1C` = 7z 魔数。`7z l` 列出来的内容是 **`GPT-SoVITS-v2pro-20250604-nvidia50`** —— 是用户 TTS 工具链的安装包。而 `D:\dsh\config\chiyu\gptsovits` 已经有 12.57 GB 的解压版。

⇒ 结论确实是「冗余，可删」，**但理由和我起初说的完全不同**：不是「缓存会自动重下」，而是「它的解压产物已经在别处存在」。如果我按「缓存可重下」这个理由报给用户，万一云端已经清掉、或者那是用户自己上传的本地构建，就删掉了唯一来源。

**错在哪一环**：我用**目录名和路径形态**推断内容。`content_cache` 这个名字完全没告诉我里面是一个 7z 安装包。

**判据修正**：体积以 GB 计的对象，删前至少做一次内容识别（文件头魔数 / `7z l` / 扩展名与真实类型的对照）。缓存目录里也可能存着唯一的一份东西。

---

## 案例 7 · 计划任务会把删掉的自启项写回来

**对象**：`HKCU\...\Run` 下的 `123` 项，值 `cmd.exe /c start www.rongronger.click`

**当时做的**：查注册表 Run 项，发现这个是推广劫持，删掉了。删完复核「`123` 已不存在」—— 收工。

**漏了什么**：还有一个**同名计划任务** `123`，BootTrigger + Delay PT15M，动作是

```
cmd.exe /c REG ADD HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Run /f /v 123 /t REG_SZ /d "cmd.exe /c start www.rongronger.click"
```

它每次开机 15 分钟后把那个 Run 项**写回去**（Author `DESKTOP-3H8TGBO\123`，Date 2015-10-10，LastRun `11/05/2026 13:49:09` LastResult=0）。

**怎么发现的**：用户重启电脑后又看到它出现。查计划任务才挖出来。

**错在哪一环**：我查了「Run 项」这一个位置就宣布清理完成，没有问「谁在写这个键」。持久化机制至少有几层：Run/RunOnce、计划任务、服务、启动文件夹、WMI 订阅。删了写入点不等于删了写入者。

**判据修正**：清理一个持久化项时，必须同时查「同名/同内容的计划任务」和「谁在写它」。删完要等一个完整周期（对本例就是重启 + 15 分钟）再复核一次。

---

## 案例 8 · 把「文件长度之和」当成「占了多少盘」

**对象**：`D:\anaconda3`（一直是「9.81 GB」）、以及 conda `pkgs` 那 5.04 GB

**当时看到的**：几轮扫描都报 anaconda3 9.81 GB，其中 `pkgs` 5.04 GB。我据此把「conda 缓存 5 GB 可清」写进候选，`conda clean --all` 跑完却报 `There are no unused tarball(s) / package(s) to remove` —— 一个字节都没清掉。

**实际是什么**：传 `-Physical` 重新测，**逻辑 9.74 GB / 实际分配 5.12 GB，硬链接去重省下 4.62 GB**。

那 5 GB 里的 `pkgs\pandoc-3.8-haa95532_0\Library\bin\pandoc.exe` 与 `anaconda3\Library\bin\pandoc.exe` 是**同一个 inode**：

```
fsutil hardlink list 'D:\anaconda3\pkgs\pandoc-3.8-haa95532_0\Library\bin\pandoc.exe'
  \anaconda3\pkgs\pandoc-3.8-haa95532_0\Library\bin\pandoc.exe
  \anaconda3\Library\bin\pandoc.exe
```

conda 装包时把文件硬链接进 base 环境。所以「pkgs 占 5 GB」这个说法本身是错的：**这 5 GB 里绝大部分和 base 环境共用同一份数据**，删 pkgs 等于删 base 环境里的包。`conda clean` 拒绝清理是对的，我前几轮却把它当成「清不掉」的缺陷来报。

**错在哪一环**：`FileInfo.Length` 是**逻辑长度**，不是磁盘占用。三种情况会让逻辑长度和实际占用差很远：

| 情况 | 逻辑长度 | 实际占用 |
|---|---|---|
| 硬链接（N 个链接指向同一 inode） | 按 N 份累加 | 只有一份 |
| 稀疏文件 | 报名义大小 | 只算实分配的块 |
| NTFS 压缩 | 报未压缩大小 | 只算压缩后 |

我用第一种当第三种用——把「同一份数据的多个名字」当成「多份数据」，于是既高估了体积，又误判了「删掉能省多少」。

**判据修正**：报体积时必须写清是逻辑长度还是实际占用。`scripts/scan.ps1` 的 `-Physical` 用 `GetCompressedFileSize` 取分配大小、按文件 id 去重硬链接，把两个数并排报出来。**用在最终候选上，不用在整盘普查上**（每文件多一次系统调用，全盘会明显变慢）。

**连带学到的一条**：`fsutil hardlink list <任意文件>` 是判断硬链接最直接的手段 —— 输出多于一行就是有链接。删一个「看着大」的目录之前，先抽一两个大文件跑这条，比事后发现「删完空间没变」便宜得多。

---

## 这份簿子的用法

判「能不能删」之前，先问自己三条，对应上面八条案例：

1. **我的证据是「某软件的清单」还是「系统的使用事实」？** → 案例 1
2. **我说「重复」时，有没有做过内容证明？** → 案例 2、案例 6
3. **我查占用时，查了进程之外的东西吗（服务、驱动、junction、硬链接）？** → 案例 3、案例 4、案例 7、案例 8

三条全过之后，仍然只是「我没有反对的理由」——**删不删还是用户的决定**。