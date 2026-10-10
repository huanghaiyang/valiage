extends SceneTree

## 运行时节点的分步诊断（硬上限 10 帧，必然退出）

const Core := preload("res://addons/mixamo_retarget/core/retarget_core.gd")
const RT := preload("res://addons/mixamo_retarget/runtime/mix_retarget_node.gd")
const TGT := "res://assets/models/characters/森林男.glb"
const SRC := "res://assets/mixamo"
const CLIP := "Standard Walk"

var _node: Node3D
var _k := 0


func _initialize() -> void:
	# 1) 目标
	var tgt := Core.instantiate_scene(TGT)
	root.add_child(tgt)
	var tskel := Core.find_first(tgt, "Skeleton3D") as Skeleton3D
	print("1) 目标骨架 = %s（%d 骨骼）" % ["有" if tskel != null else "无", tskel.get_bone_count() if tskel != null else 0])

	# 2) 直接加载源文件
	var scan := Core.scan_sources(SRC)
	var found := ""
	for p in scan["files"]:
		if String(p).get_file().get_basename() == CLIP:
			found = String(p)
	print("2) 目录 %s：%d 个文件；按基名找到 = %s" % [SRC, (scan["files"] as Array).size(), found])
	if found == "":
		quit()
		return
	var ps: PackedScene = ResourceLoader.load(found, "PackedScene", ResourceLoader.CACHE_MODE_REUSE)
	print("3) load(%s) = %s" % [found.get_file(), "OK" if ps != null else "null"])
	if ps == null:
		quit()
		return
	var inst := ps.instantiate()
	var skel := Core.find_first(inst, "Skeleton3D") as Skeleton3D
	var ap := Core.find_first(inst, "AnimationPlayer") as AnimationPlayer
	print("4) 源骨架 = %s（%d 骨骼）｜源动画 = %s" % [
		"有" if skel != null else "无", skel.get_bone_count() if skel != null else 0,
		"有" if ap != null else "无"])
	var mapping := Core.build_mapping(skel, tskel)
	print("5) 直接 build_mapping = %d 对" % mapping.size())
	inst.free()

	# 3) 节点
	_node = RT.new()
	tgt.add_child(_node)
	_node.set("source_dir", SRC)
	print("6) 节点 _ready 后：target=%s" % ["有" if _node.get("target") != null else "无"])
	var ok: bool = _node.call("play", CLIP)
	print("7) play(\"%s\") = %s｜source_file=%s｜_src_skel=%s｜_src_ap=%s｜_pairs=%d" % [
		CLIP, ok, String(_node.get("source_file")),
		"有" if _node.get("_src_skel") != null else "无",
		"有" if _node.get("_src_ap") != null else "无",
		(_node.get("_pairs") as Array).size()])


func _process(_d: float) -> bool:
	_k += 1
	return _k >= 10
