# RES 查看器 · 技术文档

> 插件目录：`addons/res_inspector/`
> 编辑器：Godot 4.7.2-stable
> 定位：**只读**查看 `.res` / `.tres` / `.scn` / `.tscn` 资源文件的结构、属性与预览。

## 1. 需求与最终形态

工程里有一批不是手写出来的资源文件，典型例子：

- `.runtime/inline_test/A.res` —— 6.3 MB 的 `ArrayMesh`，从外部工具链导出的二进制资源；
- `.godot/imported/*.scn` —— 引擎导入产物，魔数是 `RSCC`；
- `.runtime/out_*/**.tres` —— 批量跑出来的小材质。

用编辑器自带的 Inspector 看这些文件有两个痛点：

1. **看不到结构**：不知道文件里到底嵌了几个子资源、依赖了哪些外部贴图、头部版本/flags/uid 是什么、为什么加载失败；
2. **看不清内容**：`ArrayMesh` 只能看到属性名，看不到顶点数/面数/AABB；`Gradient` 的色标要一层层点开。

所以做一个专门的查看器，把同一个文件从**字节层**到**对象层**摊开，五个分页分别回答五个问题：

| 分页 | 回答的问题 |
| --- | --- |
| 摘要 | 这是个什么文件？多大？什么类型？能不能载入？ |
| 结构 | 二进制头部写了什么？字符串表/外部依赖/内部子资源各有哪些？ |
| 属性 | 载入成对象后，属性树长什么样（可过滤、可展开、可看完整值）？ |
| 预览 | 纹理/网格/动画/音频/渐变分别长什么样、有哪些关键数字？ |
| 原始 | 原始字节长什么样（分页十六进制 + ASCII 串搜索）？ |

**非目标**：编辑、保存、重新序列化资源。查看器全程只读，不写回磁盘。

## 2. 总体架构

```
            ┌─────────────────────────────┐
入口         │ plugin.gd (EditorPlugin)     │  底部面板 / Tools 菜单 / 命令面板
            │ res_context_menu.gd          │  FileSystem 右键
            └──────────────┬──────────────┘
                           │ open_path(path)
                           ▼
            ┌─────────────────────────────┐
            │ res_dock.gd (VBoxContainer)  │  TabContainer × 5 + 工具栏 + 状态栏
            │  └ ui/*.gd 各分页            │
            └──────────────┬──────────────┘
                           │ 只调静态方法
                           ▼
            ┌─────────────────────────────┐
            │ res_format.gd (RefCounted)   │  纯逻辑，无编辑器依赖 → 可无头测试
            │  inspect / read_slice /      │
            │  property_entries / child_entries / format_report
            └─────────────────────────────┘
```

设计上刻意做了三条隔离：

1. **解析核心不依赖编辑器**。`res_format.gd` 只用 `FileAccess` / `ProjectSettings` / `ResourceLoader`，因此能在 `--headless --script` 下跑全工程回归（见第 6 节）。UI 的 bug 不会污染格式解析的验证。
2. **结构解析与属性读取是两条路**：
   - 「结构」页来自**原始字节**（不信任何加载结果，文件坏了也能看）；
   - 「属性」「预览」页来自 `ResourceLoader.load()` 得到的对象（属性编码太复杂，从对象反读最可靠）。

   两条路互为交叉验证：如果字节解析说 `type=ArrayMesh` 而载入结果是别的类，多半是文件损坏或脚本类名冲突。
3. **UI 之间只用 `preload` 常量互相引用**，不依赖 `class_name` 全局类表。原因见第 7 节第 ③ 条。

## 3. 二进制资源格式（本节是全篇最硬的部分）

### 3.1 探测方法

Godot 没有公开的二进制资源格式文档，本章结论全部来自**实测**：

1. 用 `ResourceSaver.save()` 生成已知内容的样本（`Gradient` / `ArrayMesh` / `Animation` / `Curve` / 带脚本的资源 / 空资源 / 压缩标志）；
2. 逐字节 dump 头部，对比不同样本的差异点定位字段（比如「挂了脚本」的样本 flags 从 3 变成 11，就锁定了 flags 的位置）；
3. 用「内部子资源表首项偏移 == 表结束位置」这条不变量反证整条解析链是否正确；
4. 最后在整个工程的 `.res`/`.tres` 上回归，0 失败。

### 3.2 布局（Godot 4.7.2 实测）

```
"RSRC"                      4 字节魔数
u32  big_endian             0=小端，1=大端（大端时后续所有数字都要翻）
u32  use_real64             0=float32，1=float64（影响数值编码，本查看器不解析数值块）
u32  ver_major              4      ┐
u32  ver_minor              7      ├ 资源格式版本（≠ 引擎版本，4.7.2 上实测为 4.7.6）
u32  ver_patch              6      ┘
u32  type_len               含结尾 0 的长度
...  type                   UTF-8，**不填充**
u32  head_a                 4.7.2 实测恒为 0，含义未确认
u32  head_b                同上
u32  flags                 实测：普通资源 = 3；挂了脚本 = 11（多出 bit3 = 0b1000）
u64  uid                   -1 表示无 UID；否则是 ResourceUID
...  script_class          pascal 字符串；长度为 0 表示没有（此时**只占 4 字节**）
...  reserved              40 字节保留区（4.7.2；全 0）
u32  n_strings             字符串表项数
...  n × pascal 字符串     属性名 / 轨道路径等
u32  n_external            外部依赖数
...  n × (pascal type, pascal path, u64 uid)
u32  n_internal            内部子资源数
...  n × (pascal path, u64 data_offset)   ← 根资源自己也算一项，路径形如 local://ArrayMesh_xxxxx
...  各资源的数据块（本查看器不解析）
```

**pascal 字符串** = `u32 字节长度（含结尾 0）` + UTF-8 字节。这里有个关键坑：**没有对齐填充**。`"resource_name\0"` 是 14 字节，下一个长度字段就紧跟在第 14 字节，不是第 16 字节。按 4 字节对齐去读会整段错位，读出来全是垃圾。

### 3.3 为什么能可靠地找到「字符串表」

头部里 `script_class` 与保留区的长度都可能随版本变化，硬编码偏移很脆。查看器的做法是**带校验的扫描**：

从 `script_class` 之后开始，逐字节尝试把当前位置当作字符串表起点，解析
`[字符串表] → [外部依赖表] → [内部子资源表]`，并要求：

1. 每一段都能完整读完，不越界；
2. 所有字符串都是合法 UTF-8、无控制字符；
3. 所有内部子资源的 `data_offset` 都 ≤ 文件大小；
4. **不变量：`internal[0].data_offset == 内部表结束位置`**（引擎写出时必然成立——根资源的数据紧跟在表后面）。

四条同时满足才接受。第 4 条基本排除了「撞进属性数据里」的误判——实测 4.7.2 下扫描窗口 4 KB 内一次命中。

### 3.4 两个特殊形态

**RSCC（压缩二进制资源）**

`.godot/imported/*.scn` 的魔数是 `RSCC` 而不是 `RSRC`。这是导入管线产出的压缩容器，内部是分块压缩的。查看器**不解压**，因此：

- 「结构」页只显示魔数、大小、头部若干字节；
- 但 `ResourceLoader` 依然能载入它，所以「属性」「预览」页照常可用（实测 `PackedScene` 正常载入）；
- 摘要页会同时显示「结构不支持」和「资源类」，不会整页变成错误提示。

**工程外的文件**

`ResourceLoader` 只认 `res://` 路径。传进来的绝对路径文件（比如从 D 盘别处拷来的 `.res`）只会做结构解析，属性/预览页显示「工程外文件：仅结构解析」。

### 3.5 为什么不解析证据块的属性数据

属性值区是紧凑流：字段类型、对象引用索引、变体编码混在一起，还要处理 `real64`、大端、`PackedByteArray` 的长度前缀。复刻这套编码投入产出比很低，而且**它只影响「文件里写了什么值」，不影响「对象现在是什么」**。既然 `ResourceLoader` 已经能做后者，属性页就直接读对象属性（`get_property_list()` + `get()`），字节解析只负责结构。

## 4. 关键文件

| 文件 | 行数级别 | 职责 |
| --- | --- | --- |
| `res_format.gd` | ~800 | 解析核心。`inspect()` 返回统一字典；`read_slice()` 供十六进制分页；`property_entries()`/`child_entries()` 供属性树；`format_report()` 生成可复制的文本报告 |
| `res_dock.gd` | ~550 | 面板主体：工具栏、五个分页、状态栏、文件对话框、拖放打开 |
| `ui/summary_panel.gd` | ~375 | 摘要页：文件信息 + 头部字段 + 载入状态 + 类型规格卡 |
| `ui/structure_panel.gd` | ~265 | 结构页：头部 / 字符串表 / 外部依赖 / 内部子资源 / 属性键（三列 Tree） |
| `ui/property_panel.gd` | ~370 | 属性页：过滤 + 限额建树 + 右侧完整值详情 |
| `ui/preview_panel.gd` | ~330 | 预览页：纹理/网格/动画/音频/渐变卡片 |
| `ui/mesh_wire_view.gd` | ~170 | 网格 X/Y 正交线框投影（纯 `_draw`，不建 3D 场景） |
| `ui/raw_panel.gd` | ~460 | 原始页：分页十六进制 + ASCII 串搜索 |
| `ui/res_stats.gd` | ~300 | 类型统计（网格/纹理/动画/音频/渐变、编码名） |
| `ui/ui_kit.gd` / `ui/fmt_util.gd` | ~150 / ~270 | 控件小工具 / 对解析核心的防御性调用封装 |
| `plugin.gd` | ~165 | 编辑器集成：底部面板、Tools 菜单、命令面板 |
| `res_context_menu.gd` | ~45 | FileSystem 右键「用 RES 查看器打开」（编辑器类，只做注册与转发） |
| `menu_logic.gd` | ~35 | 右键菜单的**纯逻辑**（后缀过滤 / 多选取首 / 回调参数解读），可无头单测 |
| `tests/fixtures.gd` | ~120 | **现造**测试夹具（产物在 `__probe__/`，已 gitignore） |
| `tests/format_test.gd` | ~300 | 解析核心无头自检（75 项断言 + 全工程扫描） |
| `tests/ui_smoke.gd` | ~180 | 面板无头冒烟（实例化 / 6 个样本 / 全分页 / 耗时上限） |
| `tests/context_menu_test.gd` | ~150 | 右键菜单自检（纯逻辑 + 回调契约静态检查，22 项断言） |
| `CONTRACT.md` | — | 解析核心与 UI 之间的接口契约（改 API 必须先改它） |

> 底部面板标签的图标取自编辑器主题（`EditorInterface` 的 `Search` 图标），**不放 svg**：插件在编辑器首次扫描之前就被加载，那时 `res://` 下的 svg 还没 import，`load()` 会打印 `Failed loading resource`。

## 5. 使用方式

### 5.1 三个入口

1. **底部面板**：底部标签栏出现「RES 查看器」，点开后在工具栏按「打开…」选文件；
2. **FileSystem 右键**：在资源管理器里右键任意 `.res`/`.tres`/`.scn`/`.tscn` → 「用 RES 查看器打开」；
3. **菜单 / 命令面板**：`项目 > 工具` 里有「RES 查看器：显示面板」「RES 查看器：查看选中的资源」；Godot 4.6+ 还可以在命令面板里搜 `RES`。

另外支持从 FileSystem 面板把文件**拖进面板**。

### 5.2 工具栏

`[打开…] [重载] [在文件系统中定位]` ｜ 路径（点击复制）｜ `[复制报告] [导出报告…]` ｜ `[仅结构解析]` ——最右侧是状态与耗时

- `仅结构解析`：不调用 `ResourceLoader`，只看字节。大文件、脚本缺失、只想看依赖关系时用；切换会对当前文件立即重读；
- `复制报告` / `导出报告…`：`format_report()` 生成的纯文本，适合贴进 issue 或存档。

### 5.3 分页要点

- **摘要**：文件信息（路径/绝对路径/项目内与否/大小/修改时间/容器格式/置信度/耗时）+ 二进制头部字段（魔数/字节序/real32-64/版本/类型/UID/flags/未识别尾部 hex/字符串表项数/依赖数/子资源数/数据起点）或文本头部字段（头标签/类型/script_class/UID/load_steps/format/外部依赖/子资源/根属性/行数）+ 载入状态 + 告警 + 类型规格卡。
- **结构**：三列 Tree（项 / 值·路径 / 附加信息），五段：头部字段、字符串表、外部依赖、内部子资源（带数据偏移）、属性键。默认只展开「头部字段」，长列表带「共 N 项，仅显示前 M」。
- **属性**：过滤框 + 三列 Tree + 右侧只读等宽值详情。**限量建树**（每层 ≤200 项、最深 4 层、全树 ≤4000 节点，超出挂「… 还有 N 项」），且调 `child_entries()` 之前先把超大集合截到 200 项——6.3 MB 的网格属性树 920 节点、约 230 ms。
- **预览**：按资源类型给卡片：
  - `Texture2D`/`Image`：缩略图 + 尺寸/格式/显存估算（>4096² 不出缩略图）；
  - `Mesh`：表面/顶点/三角形/图元/AABB + 2D 线框投影（上限 3000 边 / 8 万顶点 / 8 表面，超出标注「截断预览」）；
  - `Animation`：时长/循环/轨道表；`AudioStream`：时长/采样率/声道/编码；`Gradient`：色带；
  - 其它类型给类型说明。
- **原始**：每页大小 1K/2K/**4K 默认**/8K/16K；上一页/下一页/跳转偏移（支持 `0x1F00` 十进制）；左侧十六进制（偏移 · 16 字节 · ASCII），右侧 ASCII 串列表（打开时先扫前 512 KB，点「搜索」扫全文上限 32 MB、结果上限 400 条，双击跳到该偏移）。6.3 MB 文件 = 1540 页，单页 hex 文本 < 40 K 字符，绝不整包灌控件。

## 6. 验证方式

三条无头命令（不需要开编辑器）：

```powershell
$godot = "D:\godot\Godot_v4.7.2-stable_win64_console.exe"
$proj  = "D:\sgames\CozyVale"

# 1) 解析核心回归：75 项断言 + 全工程 .res/.tres 扫描 + 5 个 .scn 样本
& $godot --headless --path $proj --script res://addons/res_inspector/tests/format_test.gd

# 2) 面板冒烟：实例化面板、打开 6 个样本、切遍所有分页、检查耗时上限
& $godot --headless --path $proj --script res://addons/res_inspector/tests/ui_smoke.gd

# 3) 右键菜单：纯逻辑单测 + 回调契约静态检查
& $godot --headless --path $proj --script res://addons/res_inspector/tests/context_menu_test.gd
```

三条都要求退出码 0 并打印 `✅`，且日志里 **0 条 `SCRIPT ERROR` / `Parse Error`**（当前：75 / 25 / 22 项断言全过）。

夹具是**现造**的（`tests/fixtures.gd` 写进 `addons/res_inspector/__probe__/`，该目录已进 `.gitignore`，与 `addons/exr_tools/__probe__/` 同一约定），所以换机器/新克隆也能跑。如果工程里存在 `.runtime/inline_test/A.res`（6.3 MB），会额外跑大文件断言（否则跳过）。

回归项里的硬指标：

- 二进制：类型 / 格式版本 / flags / uid / 头部保留区长度 / 字符串表项数 / 内部子资源数 / **内部表不变量** / 置信度；
- 文本：`[gd_resource]` 头字段、外部依赖（路径+id）、子资源（类型+属性数）、`[resource]` 根属性计数、行数；
- 降级：不存在路径、垃圾字节、RSCC，三者都必须给出中文原因且不崩；
- 大文件：结构解析 + 载入 + 尾页切片裁剪都正确，打开耗时 < 5 s。

**编辑器侧**另有一次一次性验证：把插件复制进一个只有 `project.godot` 的最小工程，跑

```powershell
& $godot --headless --editor --quit --path <最小工程>
```

确认 `_enter_tree` 里底部面板 / FileSystem 右键 / Tools 菜单 / 命令面板全部注册成功且无报错（这条能抓到「只有编辑器上下文才会暴露」的 API 签名错误，实测抓到过两个，见第 7 节）。

## 7. 踩坑与结论（本节最值得回看）

| # | 坑 | 结论 |
| --- | --- | --- |
| ① | 二进制资源格式没有公开文档 | 用「生成已知样本 → 逐字节对比 → 不变量反证」自己测；结论写进 3.2 |
| ② | pascal 字符串**不做 4 字节对齐** | 按对齐读会整段落错位，读出来全是垃圾。`"resource_name\0"` 后面紧跟下一个长度字段 |
| ③ | `class_name` 全局类名在无头 `--script` 下不可靠 | 全局类表来自 `.godot/global_script_class_cache.cfg`，只有编辑器扫描过才有。UI 之间一律 `const X := preload("res://…")` |
| ④ | 插件在编辑器**首次扫描之前**加载 | `res://` 下的 svg/png 还没 import，`load()` 会报 `Failed loading resource`。底部标签图标改用编辑器主题内置图标 |
| ⑤ | `Tree` 在 Godot 4 **没有 `item_expanded` 信号** | 只有 `item_collapsed`，做不了「展开时才建子项」。改成**限量建树**（每层 ≤200 / 最深 4 层 / 全树 ≤4000） |
| ⑥ | `Mesh.PRIMITIVE_TRIANGLE_FAN` 不存在 | Godot 4 的 `Mesh.PrimitiveType` 只有 POINTS / LINES / LINE_STRIP / TRIANGLES / TRIANGLE_STRIP |
| ⑦ | `Gradient.get_color_count()` 不存在 | 用 `get_point_count()`；颜色 `get_color(i)` / `get_colors()` |
| ⑧ | `EditorCommandPalette.add_command` 是 **4 个参数** `(command_name, key_name, callable, shortcut_text)` | 用动态 `call()` 时引擎不补默认值，必须传满且顺序正确 |
| ⑨ | `.tres` 的 `[resource]` 段不是「未知段」 | 第一版把 `[xxx]` 一律当未知段，导致文本资源的「根属性数」恒为 0。必须显式识别 `[resource]` |
| ⑩ | 直接 `ResourceLoader.load()` 未知后缀会打引擎错误 | `No loader found for resource: …`。先 `ResourceLoader.exists()` 判断再 load |
| ⑪ | 编辑器里跑第二个 headless 实例会动 `.godot/editor` | 所以插件注册验证放在**独立最小工程**里做，不碰真实工程的编辑器布局 |
| ⑫ | `EditorContextMenuPlugin` 的菜单回调**会被引擎带 1 个参数调用** | 不能写成无参函数，更不能 `callback.bind(路径)`——bind 的参数接在调用参数之后，最终变成「期望 1 个、传入 2 个」：`Method expected 1 argument(s), but called with 2`。正确写法是回调收 1 个带默认值的可选参数，认得出参数就用、认不出回落到 `_popup_menu` 缓存 |
| ⑬ | `EditorContextMenuPlugin` 在非编辑器模式无法实例化 | `--headless --script` 下 `load(...).new()` 返回 `null`，所以判定逻辑抽到 `menu_logic.gd`（普通 RefCounted）才能无头覆盖 |

## 8. 已知限制

| 限制 | 原因 | 影响 |
| --- | --- | --- |
| `RSCC` 无结构表 | 内部是分块压缩，GDScript 里解压成本高 | `.scn` 导入产物只能看属性/预览 |
| 工程外文件不载入 | `ResourceLoader` 只认 `res://` | 只能看结构，没有属性/预览 |
| 属性值来自**当前载入结果** | 见 3.5 | 若脚本缺失导致载入失败，属性页为空（结构页仍可用） |
| 只读 | 设计如此 | 不能改值、不能另存 |
| 头部 `head_a/head_b` 含义未确认 | 4.7.2 实测恒为 0 | 有非 0 值时只在警告里报出来，不猜语义 |
| 头部保留区长度按 40 字节校准 | 版本相关 | 不一致只降置信度（`confidence=partial`）并告警，不阻断解析 |
| 属性树/线框/ASCII 串都有上限 | 防止超大资源拖死编辑器 | 超限处会显示「还有 N 项 / 截断预览」 |

## 9. 排障

| 现象 | 排查 |
| --- | --- |
| 底部没有「RES 查看器」标签 | `项目 > 项目设置 > 插件` 里确认 `res_inspector` 已启用；控制台看有无 `[RES 查看器] 面板脚本无法实例化` |
| 面板能出现但打开文件没反应 | 跑 `tests/format_test.gd`，先确认解析核心本身没问题 |
| 某个文件属性页空白 | 看状态栏「载入失败」原因：脚本缺失 / 类型未注册 / 工程外路径 |
| 某个 `.res` 报「找不到资源表」 | 不是引擎写出的标准 `RSRC`；结构页会给出头部原字节 |
| 面板卡顿 | 打开「仅结构解析」；十六进制页只渲染当前页 |
| FileSystem 右键没有新条目 | 右键菜单是 `EditorContextMenuPlugin`，需要点在那个 `.res/.tres/.scn/.tscn` 文件上才出现 |

## 10. 待办（可选）

- 结构页支持「按偏移跳转十六进制」；
- 外部依赖一键在 FileSystem 中定位；
- 把「内部子资源偏移」渲染成文件内的区块图（一眼看出数据分布）；
- `.tscn` 场景文件增加节点树摘要页（现在是按资源头解析，节点信息不在结构页）；
- 属性页支持把子项值复制成 JSON 片段。
