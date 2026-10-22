# RES 查看器 — 内部接口契约（Lead 与 UI 分工依据）

> 本文件是 `addons/res_inspector` 插件内部两个模块之间的硬契约。
> 改动 API 必须先改本文件。

## 1. 文件布局与写入边界

| 文件 | 负责人 | 说明 |
| --- | --- | --- |
| `addons/res_inspector/plugin.cfg` | Lead | 插件清单 |
| `addons/res_inspector/plugin.gd` | Lead | `EditorPlugin` 入口：注册底部面板、FileSystem 右键菜单、打开入口 |
| `addons/res_inspector/res_format.gd` | Lead | 解析核心 `class_name ResFileFormat`（二进制 RSRC / 文本 .tres / 属性树 / 报告） |
| `addons/res_inspector/res_dock.gd` | **UI** | 主面板 `class_name ResInspectorDock` |
| `addons/res_inspector/ui/*.gd` | **UI** | 子控件（十六进制视图、属性树、预览卡片…） |
| `addons/res_inspector/icon.svg` | Lead | 面板图标 |
| `addons/res_inspector/tests/*.gd` | Lead | 无头自检脚本 |

UI 侧 **只允许** 修改 `res_dock.gd` 与 `ui/` 下的文件；不要改 `plugin.gd` / `res_format.gd` / `plugin.cfg`。

## 2. `ResFileFormat`（解析核心，Lead 提供）

`res://addons/res_inspector/res_format.gd`，`class_name ResFileFormat extends RefCounted`，全部为 **static** 方法。

```gdscript
static func inspect(path: String, load_resource: bool = true) -> Dictionary
static func read_slice(path: String, offset: int, length: int) -> PackedByteArray
static func property_entries(obj: Object, filter: String = "") -> Array      # 顶层可见属性
static func child_entries(value: Variant) -> Array                           # 懒展开子项
static func format_report(info: Dictionary) -> String                        # 纯文本报告（复制/导出）
static func human_size(bytes: int) -> String                                 # "1.2 MB"
static func type_label(variant_type: int) -> String                          # "Vector3" / "Array[...]"
static func value_text(value: Variant, max_len: int = 120) -> String         # 单行值摘要
```

### 2.1 `inspect()` 返回结构（键名固定，缺省值见注释）

```gdscript
{
  "ok": bool,                  # 至少解析出头部 = true
  "path": String,              # 传入路径原样
  "abs_path": String,          # 绝对路径
  "in_project": bool,
  "exists": bool,
  "size": int,
  "mtime": int,                # Unix 秒
  "format": String,            # "binary" | "text" | "unknown"
  "error": String,             # 头部解析失败原因；成功时 ""
  "warnings": PackedStringArray,
  "confidence": String,        # "exact" | "partial" | "heuristic"
  "elapsed_ms": int,

  # ---- format=="binary" ----
  "binary": {
    "magic": "RSRC",
    "big_endian": bool,
    "use_real64": bool,
    "format_version": String,        # "4.7.6"
    "type": String,                  # "ArrayMesh"
    "header_tail_offset": int,       # 未识别头部尾部起点
    "header_tail": PackedByteArray,  # 未识别头部尾部原始字节（<=48）
    "flags_guess": int,              # 推测的 flags（识别不了给 -1）
    "uid": String,                   # "无" 或 "0x…"
    "string_table_offset": int,
    "strings": PackedStringArray,
    "external": [ {"index":int,"type":String,"path":String,"uid":String} ],
    "internal": [ {"index":int,"path":String,"offset":int} ],
    "data_offset": int,              # 根属性数据起点（内部表之后）
  },

  # ---- format=="text" ----
  "text": {
    "header_tag": String,            # "gd_resource" / "gd_scene"
    "type": String,
    "script_class": String,
    "uid": String,
    "load_steps": int,
    "format": int,
    "external": [ {"id":String,"type":String,"path":String,"uid":String} ],
    "sub_resources": [ {"id":String,"type":String,"properties":int} ],
    "root_properties": int,
    "line_count": int,
  },

  # ---- 载入结果 ----
  "resource": Resource,        # 载入失败为 null
  "resource_class": String,    # "ArrayMesh"
  "resource_script": String,   # 附加脚本 res:// 路径或 ""
  "load_error": String,
}
```

### 2.2 属性条目（`property_entries` / `child_entries` 统一形状）

```gdscript
{
  "name": String,        # 显示名（属性名 / "[0]" / "键名"）
  "type": int,           # Variant.Type
  "type_name": String,   # "Vector3"
  "value_text": String,  # 单行摘要
  "expandable": bool,    # 是否可展开（Dictionary/Array/Object/Resource）
  "value": Variant,      # 原值（UI 只读使用；展开时传给 child_entries）
  "resource_path": String, # 值为 Resource 且带 res:// 路径时填，否则 ""
  "read_only": bool,
}
```

## 3. `ResInspectorDock`（UI 侧，必须提供）

```gdscript
class_name ResInspectorDock
extends VBoxContainer

signal status_changed(text: String)      # 可选：供 plugin.gd 显示在状态栏

func open_path(path: String) -> void     # 唯一入口：加载并显示；path 可为 res:// 或绝对路径
func reload() -> void                    # 重新读取当前文件
func get_current_path() -> String        # 无文件时返回 ""
```

要求：

1. `_ready()` 里不得依赖 `ResFileFormat` 一定存在：用 `load("res://addons/res_inspector/res_format.gd")` 懒加载，为 `null` 时界面显示「解析模块未就绪」，但控件仍可实例化（便于无头冒烟测试）。
2. 不得在 `_ready()` 中访问 `EditorInterface` / `EditorPlugin` 等编辑器单例（无头测试会崩）。
3. 全中文界面，注释用中文，风格对齐仓库其它 addon（4 空格缩进、类型标注）。
4. 打开大文件（6 MB 级）必须可用：十六进制视图分页（每页 4 KB 起），属性树懒加载，不得一次性把全部字节塞进控件。

### 界面结构（分页 `TabContainer`）

- **摘要**：文件信息（路径/大小/修改时间/格式/类型/版本/UID/脚本）+ 类型专属规格卡片。
- **结构**：`Tree` — 头部字段、字符串表、外部依赖（路径+类型）、内部子资源（路径+类型+偏移）、属性键。
- **属性**：过滤框 + 懒加载属性树 + 值详情（只读）。
- **预览**：按类型给卡片：`Texture2D`/`Image` 显示缩略图与尺寸/格式/显存估算；`Mesh` 显示表面数/顶点/三角形/AABB + 2D 线框投影；`Animation` 显示轨道表；`AudioStream` 显示时长/采样率；其它显示类型说明。
- **原始**：分页十六进制（偏移/十六进制/ASCII）+ 可搜索 ASCII 串列表。

### 工具栏

`[打开…] [重载] [在文件系统中定位] | 路径(点击复制) | [复制报告] [导出报告…]`，右侧显示状态/耗时。

## 4. 无头自检约定

UI 必须能通过下面这行跑通（不崩、能 `open_path` 真实文件、能把五个分页都构建一次）：

```powershell
& "D:\godot\Godot_v4.7.2-stable_win64_console.exe" --headless --path "D:\sgames\CozyVale" --script res://addons/res_inspector/tests/ui_smoke.gd
```

测试脚本由 Lead 提供；UI 侧可自建 `.runtime/res_inspector_dev/` 下的临时脚本调试。
