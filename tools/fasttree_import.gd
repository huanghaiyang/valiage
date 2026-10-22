extends SceneTree
## ============================================================================
## fast-tree GLB → Godot 资产（命令行入口）
## ----------------------------------------------------------------------------
## 真正的转换逻辑在 addons/fasttree_import/convert.gd（编辑器右键菜单共用同一份）。
##
## 用法：
##   & 'D:\godot\Godot_v4.7.2-stable_win64_console.exe' --headless --path . `
##       --script res://tools/fasttree_import.gd -- --glb=res://path/to/tree.glb
##   可选：
##     --name=<名字>                  默认 = GLB 文件名
##     --res-dir=<res目录>            默认 res://assets/models/树/<name>/wind
##     --scene-dir=<res目录>          默认 res://scenes/树/<name>
##     --leaf-nodes=Leaves,Flowers    哪些节点用"叶片"材质（默认按名字猜）
##     --collision=none|convex|trimesh
##     --force                        覆盖已存在文件
##     --dry-run                      只解析不落盘
## ============================================================================

const Convert := preload("res://addons/fasttree_import/convert.gd")

const USAGE := "用法：godot --headless --path . --script res://tools/fasttree_import.gd -- --glb=res://xxx.glb [--name=xxx] [--res-dir=...] [--scene-dir=...] [--leaf-nodes=Leaves,Flowers] [--collision=none|convex|trimesh] [--force] [--dry-run]"


func _initialize() -> void:
	var glb := ""
	var opts := {}
	for a in OS.get_cmdline_user_args():
		var s := String(a)
		if s.begins_with("--glb="):
			glb = s.substr(6)
		elif s.begins_with("--name="):
			opts["name"] = s.substr(7)
		elif s.begins_with("--res-dir="):
			opts["res_dir"] = s.substr(10)
		elif s.begins_with("--scene-dir="):
			opts["scene_dir"] = s.substr(12)
		elif s.begins_with("--leaf-nodes="):
			opts["leaf_nodes"] = s.substr(13)
		elif s.begins_with("--collision="):
			opts["collision"] = s.substr(12)
		elif s == "--force":
			opts["force"] = true
		elif s == "--dry-run":
			opts["dry_run"] = true
	if glb == "":
		print(USAGE)
		quit(1)
		return
	var res: Dictionary = Convert.new().run(glb, opts)
	print("[ft] %s" % String(res.get("message", "")))
	if res.get("scene", "") != "":
		print("[ft] 场景：%s" % String(res["scene"]))
	quit(0 if bool(res.get("ok", false)) else 1)
