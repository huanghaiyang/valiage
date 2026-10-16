extends SceneTree
## 一次性工具：扫描「活体/蝴蝶」目录，量出每张 PNG 的不透明包围盒，写 sprite_manifest.json。
##
## 用法（无头）：
##   D:\godot\Godot_v4.7.2-stable_win64_console.exe --headless --path D:\sgames\CozyVale \
##       --script res://addons/butterfly_swarm/tools/analyze_butterflies.gd
##
## ★ 为什么需要它（而不是运行时现场扫）★
##   逐像素解码 20 张 1200×800 的 PNG 约 1~3 秒。运行时每次开场景都扫一遍太浪费，
##   所以把结果固化成清单：运行时只读 JSON（毫秒级），改了素材再手动重跑这个脚本
##   （或用编辑器菜单「项目 -> 工具 -> 蝴蝶：重新扫描蝴蝶素材」）。
##
## ★ 清单有什么用 ★
##   ① ButterflySwarm 没配 sprites 时按清单兜底自动补素材
##   ② 编辑器「选择蝴蝶素材…」对话框按清单列条目
##   ③ `body_x`（蝶身横轴诊断值）给以后微调折叠轴留依据

const BFLY_IO := preload("res://addons/butterfly_swarm/butterfly_io.gd")
const OUT_PATH := "res://addons/butterfly_swarm/sprite_manifest.json"


func _init() -> void:
	var entries := BFLY_IO.analyze()
	if entries.is_empty():
		printerr("没有扫到任何蝴蝶 PNG，检查目录：", BFLY_IO.DEFAULT_DIR)
		quit(1)
		return
	var paths: Array = []
	for e in entries:
		paths.append(String((e as Dictionary).get("path", "")))
	var payload := {
		"generated_by": "tools/analyze_butterflies.gd",
		"source_dir": BFLY_IO.DEFAULT_DIR,
		"count": entries.size(),
		"sprite_paths": paths,
		"sprites": entries,
	}
	var f := FileAccess.open(OUT_PATH, FileAccess.WRITE)
	if f == null:
		printerr("写入失败：", OUT_PATH, " err=", FileAccess.get_open_error())
		quit(1)
		return
	f.store_string(JSON.stringify(payload, "  "))
	f.close()
	print("已写入 ", OUT_PATH, " ｜ ", entries.size(), " 条")
	for e in entries:
		var d: Dictionary = e
		print("  %s  %dx%d  bbox=%dx%d @(%d,%d)  body_x=%.4f" % [
			d["file"], int(d["w"]), int(d["h"]), int(d["bbox_w"]), int(d["bbox_h"]),
			int(d["min_x"]), int(d["min_y"]), float(d["body_x"])])
	quit(0)
