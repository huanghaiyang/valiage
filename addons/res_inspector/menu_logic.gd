@tool
extends RefCounted
## 右键菜单的**纯逻辑**（不继承编辑器类）。
##
## 为什么不直接写在 res_context_menu.gd 里：
## `EditorContextMenuPlugin` 只在编辑器进程里能实例化，`--headless --script`（非编辑器模式）下
## `load(...).new()` 会返回 null，于是那段逻辑就变成「测不到」。把判定逻辑抽出来，它就能被无头单测覆盖。

## 允许查看的后缀（与 plugin.gd 保持一致）。
const OPENABLE_EXTS := ["res", "tres", "scn", "tscn"]


## 这个路径是不是本插件关心的资源文件（后缀忽略大小写）。
static func is_openable(path: String) -> bool:
	return OPENABLE_EXTS.has(path.get_extension().to_lower())


## 从多选路径里挑第一个资源文件；没有则返回 ""。
static func pick(paths: PackedStringArray) -> String:
	for p in paths:
		if is_openable(p):
			return p
	return ""


## 解读菜单回调收到的参数：不同引擎版本可能传 PackedStringArray / Array / String / 别的。
## 认不出来就返回 ""，调用方回落到自己缓存的路径。
static func pick_arg(arg: Variant) -> String:
	if arg is PackedStringArray:
		return pick(arg)
	if arg is Array:
		var arr := PackedStringArray()
		for v in (arg as Array):
			arr.append(str(v))
		return pick(arr)
	if arg is String:
		return arg if is_openable(arg) else ""
	return ""
