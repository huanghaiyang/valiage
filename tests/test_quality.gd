@tool
extends McpTestSuite
## 画质分级自检（以地表贴图为例）。

const TIERS := "res://scripts/quality/quality_tiers.gd"
const SAMPLE_4K := "res://assets/textures/杂草泥土/brown_mud_leaves_01_diff_4k.jpg"


func suite_name() -> String:
	return "quality"


func _load(p: String) -> GDScript:
	return ResourceLoader.load(p, "", ResourceLoader.CACHE_MODE_IGNORE) as GDScript


func test_presets_are_sane() -> void:
	var s := _load(TIERS)
	assert_true(s != null, "档位数据加载失败")
	if s == null:
		return
	var tiers: Array = s.all_tiers()
	assert_eq(tiers.size(), 4, "应有 4 档")
	var prev_lod := -1.0
	var prev_dist := -1.0
	for t in tiers:
		var p: Dictionary = s.get_preset(t)
		for key in ["terrain_texture_suffix", "terrain_lod0_range", "terrain_mesh_size", "shadow_quality", "view_distance"]:
			assert_true(p.has(key), "档位 %d 缺少字段 %s" % [t, key])
		# 档位越高，LOD 距离与视距应当不减（分级必须单调才有意义）
		assert_true(float(p["terrain_lod0_range"]) >= prev_lod, "档位 %d 的 LOD 距离比上一档小" % t)
		assert_true(float(p["view_distance"]) >= prev_dist, "档位 %d 的视距比上一档小" % t)
		prev_lod = float(p["terrain_lod0_range"])
		prev_dist = float(p["view_distance"])
		print("[画质] %s：贴图 %s ｜ LOD %.0f ｜ 视距 %.0f" % [
				s.tier_name(t), p["terrain_texture_suffix"], float(p["terrain_lod0_range"]), float(p["view_distance"])])


func test_resolution_suffix_swap() -> void:
	var s := _load(TIERS)
	if s == null:
		return
	var cases := [
		["res://a/brown_mud_leaves_01_diff_4k.jpg", "2k", "res://a/brown_mud_leaves_01_diff_2k.jpg"],
		["res://a/brown_mud_leaves_01_nor_gl_4k.png", "1k", "res://a/brown_mud_leaves_01_nor_gl_1k.png"],
		["res://a/rock.png", "2k", "res://a/rock_2k.png"],
		["res://a/t_2048.png", "1k", "res://a/t_1k.png"],
		["res://a/t_2k.png", "4k", "res://a/t_4k.png"],
		["res://a/grass_01_1k.png", "2k", "res://a/grass_01_2k.png"],
	]
	for c in cases:
		var got := String(s.call("swap_resolution_suffix", c[0], c[1]))
		print("[画质] %s + %s → %s" % [c[0].get_file(), c[1], got.get_file()])
		assert_eq(got, c[2], "后缀替换不对")


func test_fallback_when_only_4k_exists() -> void:
	# 关键保证：只有一套 4K 贴图时，低档位必须**回退**到 4K，绝不能返回不存在的路径
	var s := _load(TIERS)
	if s == null:
		return
	assert_true(ResourceLoader.exists(SAMPLE_4K), "样本 4K 贴图不存在")
	var low := String(s.call("resolve_existing", SAMPLE_4K, 0))
	var high := String(s.call("resolve_existing", SAMPLE_4K, 2))
	print("[画质] 只有 4K 时：低档 → %s ｜ 高档 → %s" % [low.get_file(), high.get_file()])
	assert_true(ResourceLoader.exists(low), "低档回退后仍然指向了不存在的文件")
	assert_eq(high, SAMPLE_4K, "高档应当就是 4K 原图")


func test_apply_on_terrain_assets() -> void:
	var ts := _load("res://scripts/quality/terrain_quality.gd")
	assert_true(ts != null, "地表应用器加载失败")
	if ts == null:
		return
	# 造一个真实的 Terrain3DAssets（用外部的 4K 贴图）
	var assets := Terrain3DAssets.new()
	var tex_asset := Terrain3DTextureAsset.new()
	tex_asset.id = 0
	tex_asset.albedo_texture = load(SAMPLE_4K)
	# 再塞一个"内嵌贴图"（没有 resource_path）——必须被跳过
	var inner := ImageTexture.new()
	var img := Image.create(4, 4, false, Image.FORMAT_RGBA8)
	inner.set_image(img)
	var tex_asset2 := Terrain3DTextureAsset.new()
	tex_asset2.id = 1
	tex_asset2.albedo_texture = inner
	assets.texture_list = [tex_asset, tex_asset2] as Array[Terrain3DTextureAsset]

	var r: Dictionary = ts.call("apply_on_assets", assets, 0)     # 低档
	print("[画质] 低档应用结果：%s" % str(r))
	assert_true(bool(r["ok"]), "应用失败：" + str(r.get("message", "")))
	assert_eq(int(r["inner"]), 1, "内嵌贴图必须被跳过（不碰它）")
	assert_true(ResourceLoader.exists((tex_asset.albedo_texture as Texture2D).resource_path),
			"换完之后必须仍指向存在的文件")
	# 高档应当回到 4K 原图
	var r2: Dictionary = ts.call("apply_on_assets", assets, 2)
	print("[画质] 高档应用结果：%s" % str(r2))
	assert_eq(String((tex_asset.albedo_texture as Texture2D).resource_path), SAMPLE_4K, "高档应当换回 4K")

func test_applier_is_editor_safe_by_default() -> void:
	# 关键：编辑器里默认**不**自动改贴图引用，否则切档会把档位烤进场景文件 ✗
	var ts := _load("res://scripts/quality/terrain_quality.gd")
	if ts == null:
		return
	var inst: Node = ts.new()
	assert_true(inst.get("apply_in_editor") == false, "apply_in_editor 默认必须是 false")
	var src := FileAccess.get_file_as_string("res://scripts/quality/terrain_quality.gd")
	assert_true(src.contains("Engine.is_editor_hint() and not apply_in_editor"),
			"缺少编辑器安全阀判断")
	print("[画质] 编辑器安全阀：默认不动场景 ✓（要预览某档可临时勾 apply_in_editor ✓）")
	inst.free()