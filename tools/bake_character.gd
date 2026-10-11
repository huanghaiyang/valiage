extends SceneTree

## 为任意角色烘焙动画库（支持调整"修正参数"）：
##   godot --headless --path <项目> --script res://tools/bake_character.gd -- \
##         <模型路径> <输出tres路径> [源目录] [选项...]
##
## 选项（都可省略，省略即用默认值）：
##   --ratio=0.25       目标"两脚间距/腿长"（越小站姿越窄；默认 0.25）
##   --no-leg-fix       关闭"收腿"（不修劈叉）
##   --no-foot-fix      关闭"脚掌外八转正"
##   --no-inplace       关闭"原地化"（保留动画自带位移）
##   --fps=30           采样帧率
##
## 例：
##   -- res://assets/models/characters/主角.glb res://assets/animations/zhujue.tres res://assets/mixamo --ratio=0.20

const Core := preload("res://addons/mixamo_retarget/core/retarget_core.gd")


func _log(msg: String) -> void:
	print("   " + msg)


func _initialize() -> void:
	var raw := OS.get_cmdline_user_args()
	var pos: Array = []
	var opts := {
		"sample_fps": 30.0,
		"in_place": true,
		"fix_leg_splay": true,
		"leg_stance_ratio": 0.25,
		"fix_foot_splay": true,
	}
	for a in raw:
		var s := String(a)
		if s.begins_with("--"):
			var body := s.substr(2)
			if body == "no-leg-fix":
				opts["fix_leg_splay"] = false
			elif body == "no-foot-fix":
				opts["fix_foot_splay"] = false
			elif body == "no-inplace":
				opts["in_place"] = false
			elif body.begins_with("ratio="):
				opts["leg_stance_ratio"] = float(body.substr(6))
			elif body.begins_with("fps="):
				opts["sample_fps"] = float(body.substr(4))
			else:
				print("⚠ 未识别选项：" + s)
		else:
			pos.append(s)
	if pos.size() < 2:
		print("用法：-- <模型路径> <输出tres路径> [源目录] [--ratio=0.25] [--no-leg-fix] [--no-foot-fix] [--no-inplace] [--fps=30]")
		quit()
		return
	var tgt: String = pos[0]
	var out: String = pos[1]
	var src: String = pos[2] if pos.size() >= 3 else "res://assets/mixamo"
	print("源 = %s｜目标 = %s｜输出 = %s" % [src, tgt.get_file(), out.get_file()])
	print("选项：收腿=%s（比值 %.2f）｜脚掌转正=%s｜原地化=%s｜采样 %.1f fps" % [
		opts["fix_leg_splay"], opts["leg_stance_ratio"], opts["fix_foot_splay"],
		opts["in_place"], opts["sample_fps"]])
	var r: Dictionary = Core.bake_all(src, tgt, opts, _log)
	if String(r["error"]) != "":
		print("✗ 烘焙失败：" + String(r["error"]))
		quit()
		return
	var lib: AnimationLibrary = r["library"]
	var m: Dictionary = r["measures"]
	print("映射 %d 对（骨骼 %d → %d）｜动画 %d 条" % [
		int(r["mapping_size"]), int(m["src_bones"]), int(m["tgt_bones"]),
		(r["clips"] as Array).size()])
	var err := ResourceSaver.save(lib, out)
	print("保存 → %s｜%s" % ["OK ✓" if err == OK else "失败 %d" % err, out])
	quit()
