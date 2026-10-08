@tool
extends EditorPlugin
## 贴图导入设置转换器 v2
##
## ★ 需求：**图片转换 / 扩展名不变** ✓
##   `.jpg` / `.png` 文件本身装不下 DXT1 数据 ✗ → 在 Godot 里"变成 DXT1"= **改导入设置** ✓
##   （即 Import 面板里那个 `compress/mode` ✓ 文件与扩展名**完全不动** ✓✓）
##
## 用法：FileSystem 里右键图片 → 选一项 → 立即重新导入 ✓ 扩展名不变 ✓
##   右栏「导入(Import)」面板会同步显示改后的设置 ✓
##
## 实现要点：
##   · `.import` 文件就是 **ConfigFile** 格式 ✓ → 用 ConfigFile 读写 ✓（不手改文本 ✓）
##   · 改完调 `EditorInterface.get_resource_filesystem().update_file(path)` → **自动重新导入** ✓
##   · 参考项目里已在跑的 addons/image_convert 的右键写法 ✓（签名 paths 参数 ✓ 防抖 ✓）

## 预设：设置名 → .import 里 [params] 的键值
const PRESETS: Array[Dictionary] = [
	{
		"name": "导入：VRAM 压缩（DXT/S3TC · 省显存）",
		"params": { "compress/mode": 2, "compress/high_quality": false, "detect_3d/compress_to": 0 },
	},
	{
		"name": "导入：VRAM 压缩 · 高质量（BPTC）",
		"params": { "compress/mode": 2, "compress/high_quality": true, "detect_3d/compress_to": 0 },
	},
	{
		"name": "导入：VRAM 未压缩（加载最快 · 显存最大）",
		"params": { "compress/mode": 3, "detect_3d/compress_to": 0 },
	},
	{
		"name": "导入：无损（像素级 · PNG 类）",
		"params": { "compress/mode": 0, "detect_3d/compress_to": 0 },
	},
	{
		"name": "导入：有损（体积最小 · JPG 类）",
		"params": { "compress/mode": 1 },
	},
	{
		"name": "导入：Basis Universal",
		"params": { "compress/mode": 4, "detect_3d/compress_to": 0 },
	},
	{ "name": "导入：开 Mipmaps", "params": { "mipmaps/generate": true } },
	{ "name": "导入：关 Mipmaps", "params": { "mipmaps/generate": false } },
	{ "name": "导入：法线贴图预设（Normal Map · BPTC + mip）", "params": { "compress/mode": 2, "compress/high_quality": true, "compress/normal_map": 1, "mipmaps/generate": true, "detect_3d/compress_to": 0 } },
]

var _menu: EditorContextMenuPlugin = null
var _picked: PackedStringArray = PackedStringArray()


func _enter_tree() -> void:
	_menu = FmtMenu.new()
	_menu.owner_plugin = self
	add_context_menu_plugin(EditorContextMenuPlugin.CONTEXT_SLOT_FILESYSTEM, _menu)
	print("[导入设置] 插件已启用 ✓ FileSystem 右键图片 → %d 个导入预设 ✓（扩展名不变 ✓）" % PRESETS.size())


func _exit_tree() -> void:
	if _menu != null:
		remove_context_menu_plugin(_menu)
		_menu = null


## 应用一个预设到若干文件（paths 是 res:// 路径 ✓）
func apply_picked(paths: PackedStringArray, index: int) -> void:
	if index < 0 or index >= PRESETS.size():
		return
	var preset: Dictionary = PRESETS[index]
	var params: Dictionary = preset.get("params", {})
	var fs := EditorInterface.get_resource_filesystem()
	var ok := 0
	var skip := 0
	for p in paths:
		var src := String(p)
		var imp := src + ".import"          # ★ 只改导入设置 ✓ 图片文件一个字节都不动 ✓ 扩展名不变 ✓
		if not FileAccess.file_exists(imp):
			push_warning("[导入设置] ⚠ 没有 .import（可能还没被导入过 ✗）：%s" % src)
			skip += 1
			continue
		var cf := ConfigFile.new()
		var err := cf.load(imp)
		if err != OK:
			push_error("[导入设置] ✗ 读 .import 失败：%s（err=%d）" % [imp, err])
			skip += 1
			continue
		for k in params.keys():
			cf.set_value("params", String(k), params[k])
		var serr := cf.save(imp)
		if serr != OK:
			push_error("[导入设置] ✗ 写 .import 失败：%s（err=%d）" % [imp, serr])
			skip += 1
			continue
		# ★ 立刻重新导入 ✓（编辑器会按新设置重新生成 .ctex ✓）
		fs.update_file(src)
		ok += 1
		print("[导入设置] ✓ %s ← %s" % [src.get_file(), preset["name"]])
	print("[导入设置] === 完成 ✓ 成功 %d ｜ 跳过 %d ===" % [ok, skip])
	if ok > 0:
		fs.scan()


# ---------------------------------------------------------------- 右键菜单
class FmtMenu extends EditorContextMenuPlugin:
	## ★★ 不要写 `: EditorPlugin` ✗ —— 那样访问插件的自定义变量会被解析成 Nil ✗
	##    （实测：`Invalid operands 'int' and 'Nil' in operator '-'` ✓）
	var owner_plugin = null
	var _added_at := 0        # 防抖计时放自己身上 ✓

	func _popup_menu(paths: PackedStringArray) -> void:
		if owner_plugin == null or paths.is_empty():
			return
		owner_plugin._picked = paths
		var now := Time.get_ticks_msec()
		if now - _added_at < 250:      # _popup_menu 会连续触发两次 ✗ → 防抖 ✓
			return
		_added_at = now
		for i in range(owner_plugin.PRESETS.size()):
			# ★ 引擎调用回调时会先传 paths ✓ → 绑定参数必须排最后 ✓
			add_context_menu_item(String(owner_plugin.PRESETS[i]["name"]), _on_item.bind(i))

	func _on_item(paths: Variant = null, index: int = -1) -> void:
		if owner_plugin == null or index < 0:
			return
		var p := PackedStringArray()
		if paths is PackedStringArray:
			p = paths
		elif paths is Array:
			for x in paths:
				p.append(str(x))
		if p.is_empty():
			p = owner_plugin._picked
		owner_plugin.apply_picked(p, index)
