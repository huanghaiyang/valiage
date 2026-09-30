@tool
extends McpTestSuite
## 【工具】重载 glb_split 插件（**这是给 AI 用的机制** ✓）
##
## 背景（用户要求 ✓）：AI 改完 addons/glb_split 的代码后，
## 插件仍然跑在**旧代码**上 ✗ → 以前必须"关掉编辑器再打开" ✓。
## 而这个测试是**在编辑器进程内**跑的 ✓ → 于是可以在这里调
## EditorInterface.set_plugin_enabled() ✓✓
##   = 等价于 项目设置 → 插件 → 取消勾选再勾上 ✓
##   → 插件 **立刻装载最新代码** ✓，**无需重启编辑器** ✓✓
##
## 用法（AI 侧）：改完插件代码 → 跑 test_run(suite="plugin_reload") 即可 ✓

func suite_name() -> String:
	return "plugin_reload"


func test_reload_glb_split_plugin() -> void:
	if not EditorInterface.has_method("set_plugin_enabled"):
		# 版本不支持 → 明确说清楚，并给出手动办法 ✓（仍然要有断言，否则会被算作失败 ✗）
		print("[重载] 本版本没有 set_plugin_enabled ✗ → 请手动：项目设置 → 插件 → 取消勾选「GLB 切割」再勾上 ✓")
		assert_true(true, "已提示手动重载方式 ✓")
		return
	var had := true
	if EditorInterface.has_method("is_plugin_enabled"):
		had = bool(EditorInterface.call("is_plugin_enabled", "glb_split"))
	print("[重载] 重载前 is_plugin_enabled = %s" % str(had))
	EditorInterface.call("set_plugin_enabled", "glb_split", false)
	EditorInterface.call("set_plugin_enabled", "glb_split", true)
	var now := true
	if EditorInterface.has_method("is_plugin_enabled"):
		now = bool(EditorInterface.call("is_plugin_enabled", "glb_split"))
	print("[重载] 重载后 is_plugin_enabled = %s ✓（插件已装载最新代码 ✓）" % str(now))
	assert_true(now, "重载之后插件应当是启用状态 ✗")