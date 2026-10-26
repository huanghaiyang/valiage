extends Node
## ============================================================================
## mod_loader.gd —— Mod 系统总入口（autoload `Mods`）
## ----------------------------------------------------------------------------
## 【职责】
##   启动时扫描固定目录 `user://mods/`，逐个读 `mod.json` 清单，把 Mod 声明的内容
##   注册进游戏现有系统；运行期按需给场景树里的资源打"贴图覆盖"。
##   本文件**不做任何具体玩法**，只负责"读清单 → 校验 → 交给各系统的注册接口"。
##
## 【目录约定】
##   user://mods/
##     config.json            ← 可选，玩家自己的配置（见下）
##     <任意文件夹>/
##       mod.json             ← 必需，清单
##       props/xxx.tscn       ← Mod 自带资源（路径相对本文件夹写）
##       textures/xxx.png
##
##   Windows 下 user:// 的实际位置：%APPDATA%\Godot\app_userdata\Cozy Vale\mods
##
## 【mod.json 规范（api = 1）】
##   {
##     "id": "my_mod",              // 必需，全局唯一
##     "name": "我的 Mod",           // 显示用
##     "version": "1.0.0",
##     "api": 1,                    // 接口版本，不匹配直接跳过
##     "enabled": true,             // false = 玩家手动禁用
##     "allow_scripts": false,      // ★ 脚本放行开关：只有这里写 true 才允许加载 .gd / .tscn
##     "load_order": 0,             // 越小越先加载；同值按文件夹名排序
##     "spells": [                  // 新增法术（需要 allow_scripts）
##       {"id": "mod_meteor", "name": "陨石术", "script": "spells/meteor.gd",
##        "sheet": {"mana_cost": 25, "one_shot": true, "duration": 2.0}}
##     ],
##     "props": [                   // 新增/替换可摆放物件（需要 allow_scripts 才能给 .tscn）
##       {"category": "flower", "name": "月光花", "scene": "props/flower.tscn"},
##       {"category": "tree", "id": "mod_pine", "name": "松树", "scene": "props/pine.tscn", "base": 1.0},
##       {"category": "house", "id": "mod_hut", "name": "木屋", "scene": "props/hut.tscn"},
##       {"category": "furniture", "replace_res": "res://assets/models/furniture/chair.glb",
##        "scene": "props/chair_mod.tscn"}   // 替换原版模型的写法
##     ],
##     "maps": [                    // 整张地图（需要 allow_scripts）
##       {"id": "sky_isle", "name": "天空岛", "scene": "maps/sky_isle.tscn"}
##     ],
##     "overrides": {               // 贴图覆盖：原版资源路径 -> Mod 里的图片/材质
##       "res://assets/models/树/大樱花树_leaf_diff.png": "textures/leaf.png"
##     }
##   }
##
## 【脚本放行规则（安全边界）】
##   · allow_scripts = false（默认）：只允许数据与资源（图片、.res/.tres 材质/网格）；
##     清单里出现 .gd / .tscn 的条目会被**跳过并记日志**，不会执行任何 Mod 代码。
##   · allow_scripts = true：允许 .gd 脚本与 .tscn 场景。**玩家必须自己改这一行**，
##     等于对这份 Mod 的明确授权（.tscn 里可以内嵌脚本，所以一律按脚本对待）。
##
## 【加载时机与顺序】
##   · 本节点排在 autoload 列表最后 → `_ready()` 时 SpellCaster 等已完成初始化。
##   · 法术在这里直接注册；可摆放物件/房屋要等场景里的 Vegetation / BuildingManager
##     出现（每次换地图都会出现），所以走 `node_added` 钩子按节点类型补注册。
##   · 贴图覆盖同样走 `node_added`：任何 MeshInstance3D / MultiMeshInstance3D 进树时
##     检查它的材质，命中覆盖表的贴图参数就换成 Mod 图（**只换材质副本，不改原资源**）。
##
## 【配置 config.json（可选，玩家自己写）】
##   {"start_map": "sky_isle", "disabled_mods": ["some_mod"]}
##   也支持命令行：`--map=sky_isle`（`OS.get_cmdline_user_args()`）
##
## 【已知边界】
##   · 模型替换按"原版资源路径"精确匹配，只能替换**摆放系统里用到的模型表项**；
##     世界烘焙好的静态网格（地形、场景里已摆好的物件）不做模型替换，只做贴图覆盖。
##   · 不提供游戏内管理界面：启用/禁用靠 mod.json 的 enabled 与 config.json。
## ============================================================================

## Mod 根目录（固定，不随游戏目录变化；导出后同样可写）
const MOD_ROOT := "user://mods"
## 玩家配置
const CONFIG_PATH := "user://mods/config.json"
## 当前接口版本；清单里 api 不等于它的一律跳过（避免旧 Mod 按旧字段把游戏带崩）
const API_VERSION := 1
## 允许被"贴图覆盖"的图片扩展名（用 Image.load_from_file 直接读，导出后也可用）
const IMAGE_EXTS := ["png", "jpg", "jpeg", "webp", "bmp", "tga"]
## 需要脚本放行的扩展名（.tscn 可内嵌脚本，一律按代码对待）
const SCRIPT_EXTS := ["gd", "tscn", "gdshader"]
## StandardMaterial3D / ORMMaterial3D 上可能挂贴图的属性名
const BASE_TEX_PROPS := ["albedo_texture", "normal_texture", "orm_texture", "roughness_texture",
		"metallic_texture", "emission_texture", "detail_albedo", "detail_normal"]
## 目标场景节点的脚本路径（用于 node_added 钩子识别）
const VEGETATION_SCRIPT := "res://scripts/world/vegetation.gd"
const BUILDING_SCRIPT := "res://scripts/world/building_manager.gd"
## 每帧最多处理的"待打覆盖"网格数（防止一次性涌入时卡帧）
const OVERRIDE_BATCH := 256

## 法术数值表（注入 Mod 行用）
const SpellSheet := preload("res://scripts/spells/spell_sheet.gd")

## 已加载的 Mod：{id, name, version, folder, allow_scripts, order}
var mods: Array = []
## 法术声明：{id, name, source(GDScript/PackedScene), sheet(Dictionary), mod}
var spells: Array = []
## 可摆放物件声明：{category, id, name, path, base, replace_res, mod}
var props: Array = []
## 地图：id -> {name, path, mod}
var maps: Dictionary = {}
## 贴图覆盖：原版 res:// 路径 -> Mod 绝对路径（user://...）
var overrides: Dictionary = {}

## 玩家启动地图（config.json / 命令行）
var _start_map := ""
## 被 config 禁用 / 清单 enabled=false 的 mod id
var _disabled: Array = []
## 图片缓存：绝对路径 -> Texture2D
var _tex_cache := {}
## 打补丁后的材质缓存：原材质 instance_id -> Material（null 表示"该材质没有命中覆盖"）
var _patched_cache := {}
## 待处理覆盖的网格（node_added 里入队，_process 里限流处理）
var _pending_mesh: Array = []
## 已经做过"物件注册"的节点 instance_id（防止同一场景重复注册）
var _applied_nodes := {}
## 覆盖命中计数（只用于日志）
var _override_hits := 0
## 已检查过的网格数（只用于日志：排查"配了覆盖却没生效"时看它有没有涨）
var _checked_meshes := 0
## 是否有内容需要"等节点出现"再注册
var _need_node_hooks := false


# ============================================================================
# 生命周期
# ============================================================================

func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_ensure_dir()
	_read_config()
	_scan()
	_apply_registrations()
	# 有物件要注册、或有贴图覆盖（运行时生成的网格也要覆盖）时才需要 node_added 钩子
	if _need_node_hooks or not overrides.is_empty():
		get_tree().node_added.connect(_on_node_added)
	set_process(false)
	_log_summary()
	if _need_node_hooks:
		# 主场景是整体进入场景树的，实测不会给里面每个节点都发 node_added
		# → 首帧补扫一次现有场景里的 Vegetation / BuildingManager
		_sweep_registrants_next_frame()
	if not overrides.is_empty():
		# 两个来源都要覆盖：
		#   1) 启动时主场景里的网格可能在钩子接上之前就进树了 → 首帧整场景扫一遍
		#   2) 之后运行时生成的（植被撒点、蝴蝶、Mod 物件）→ 靠 node_added
		_sweep_next_frame()
		get_tree().create_timer(1.0).timeout.connect(_report_overrides)
	if not _start_map.is_empty():
		_deferred_start_map()


func _process(_delta: float) -> void:
	if _pending_mesh.is_empty():
		set_process(false)
		return
	var budget := OVERRIDE_BATCH
	while budget > 0 and not _pending_mesh.is_empty():
		var n: Variant = _pending_mesh.pop_front()
		budget -= 1
		# 出队后必须校验：可能已经被释放（换地图 / Mod 自己删了节点）
		if n != null and is_instance_valid(n) and (n as Node).is_inside_tree():
			_apply_overrides_to_node(n as Node)


# ============================================================================
# 对外接口（Mod 脚本 / 其它系统可以调）
# ============================================================================

## 加载某张 Mod 地图（整场景替换）。返回 false 表示没这张图 / 文件缺失。
func load_map(map_id: String) -> bool:
	var m: Dictionary = maps.get(map_id, {})
	if m.is_empty():
		push_warning("[Mods] 没有地图: %s" % map_id)
		return false
	var path := String(m.get("path", ""))
	if path.is_empty() or not ResourceLoader.exists(path):
		push_warning("[Mods] 地图文件缺失: %s -> %s" % [map_id, path])
		return false
	print("[Mods] 载入地图：%s（%s）" % [m.get("name", map_id), path])
	get_tree().change_scene_to_file(path)
	if not overrides.is_empty():
		_sweep_next_frame()
	if _need_node_hooks:
		_sweep_registrants_next_frame()
	return true


## 所有 Mod 地图的 id 列表（给外部/调试用）
func map_ids() -> Array:
	return maps.keys()


## 某张地图的显示名
func map_name(map_id: String) -> String:
	var m: Dictionary = maps.get(map_id, {})
	return String(m.get("name", map_id))


## 某个 Mod 是否启用（清单 enabled 与 config.disabled_mods 都算）
func is_mod_enabled(mod_id: String) -> bool:
	return not _disabled.has(mod_id)


# ============================================================================
# 扫描与清单解析
# ============================================================================

func _ensure_dir() -> void:
	var abs_dir := ProjectSettings.globalize_path(MOD_ROOT)
	if not DirAccess.dir_exists_absolute(abs_dir):
		DirAccess.make_dir_recursive_absolute(abs_dir)


func _read_config() -> void:
	if FileAccess.file_exists(CONFIG_PATH):
		var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CONFIG_PATH))
		if typeof(parsed) != TYPE_DICTIONARY:
			push_warning("[Mods] config.json 解析失败，忽略: %s" % CONFIG_PATH)
		else:
			var cfg: Dictionary = parsed
			_start_map = String(cfg.get("start_map", ""))
			var dis: Variant = cfg.get("disabled_mods", [])
			if dis is Array:
				for d in dis:
					_disabled.append(String(d))
	# 命令行优先（方便自检/临时换图，不必改配置）；没有 config.json 时也能用
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--map="):
			_start_map = arg.trim_prefix("--map=").strip_edges()


## 扫描所有子文件夹里的 mod.json；先收齐再排序，保证 load_order 生效
func _scan() -> void:
	var dir := DirAccess.open(MOD_ROOT)
	if dir == null:
		push_warning("[Mods] 打不开目录: %s" % MOD_ROOT)
		return
	var entries: Array = []
	for folder in dir.get_directories():
		var base := MOD_ROOT.path_join(folder)
		var manifest := base.path_join("mod.json")
		if not FileAccess.file_exists(manifest):
			continue
		var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(manifest))
		if typeof(data) != TYPE_DICTIONARY:
			push_warning("[Mods] %s/mod.json 解析失败，跳过" % folder)
			continue
		entries.append({"folder": folder, "dir": base, "data": data})
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var oa := int((a.data as Dictionary).get("load_order", 0))
		var ob := int((b.data as Dictionary).get("load_order", 0))
		if oa != ob:
			return oa < ob
		return String(a.folder) < String(b.folder))
	for e in entries:
		_load_manifest(e.dir, e.folder, e.data)


func _load_manifest(dir_path: String, folder: String, data: Dictionary) -> void:
	var id := String(data.get("id", folder)).strip_edges()
	var name := String(data.get("name", id))
	if id.is_empty():
		push_warning("[Mods] %s：缺少 id，跳过" % folder)
		return
	if int(data.get("api", API_VERSION)) != API_VERSION:
		push_warning("[Mods] %s：api 版本不匹配（需要 %d），跳过" % [folder, API_VERSION])
		return
	if _disabled.has(id) or not bool(data.get("enabled", true)):
		print("[Mods] 已禁用：%s（%s）" % [name, id])
		return
	var allow_scripts := bool(data.get("allow_scripts", false))
	mods.append({"id": id, "name": name, "version": String(data.get("version", "")),
			"folder": folder, "allow_scripts": allow_scripts,
			"order": int(data.get("load_order", 0))})
	# ---- 法术 ----
	for e in _array_of(data, "spells"):
		_load_spell(id, dir_path, allow_scripts, e)
	# ---- 可摆放物件 ----
	for e in _array_of(data, "props"):
		_load_prop(id, dir_path, allow_scripts, e)
	# ---- 地图 ----
	for e in _array_of(data, "maps"):
		_load_map_entry(id, dir_path, allow_scripts, e)
	# ---- 贴图覆盖 ----
	var ov: Variant = data.get("overrides", {})
	if ov is Dictionary:
		for key in (ov as Dictionary).keys():
			var abs_p := _resolve(dir_path, String((ov as Dictionary)[key]), allow_scripts)
			if abs_p.is_empty():
				continue
			overrides[String(key)] = abs_p


func _array_of(data: Dictionary, key: String) -> Array:
	var v: Variant = data.get(key, [])
	return v if v is Array else []


## 把清单里的相对路径解析成 Godot 资源路径（res:// 或 user://），并按脚本放行规则校验
func _resolve(dir_path: String, rel: String, allow_scripts: bool) -> String:
	var p := rel.strip_edges()
	if p.is_empty():
		return ""
	if not (p.begins_with("res://") or p.begins_with("user://")):
		p = dir_path.path_join(p).simplify_path()
	if not (p.begins_with("res://") or p.begins_with("user://")):
		return ""
	var ext := p.get_extension().to_lower()
	if SCRIPT_EXTS.has(ext) and not allow_scripts:
		push_warning("[Mods] 需要脚本放行，已跳过：%s" % p)
		return ""
	if not FileAccess.file_exists(p) and not ResourceLoader.exists(p):
		push_warning("[Mods] 文件不存在，已跳过：%s" % p)
		return ""
	return p


func _load_spell(mod_id: String, dir_path: String, allow_scripts: bool, e: Variant) -> void:
	if not (e is Dictionary):
		return
	var row: Dictionary = e
	var sid := String(row.get("id", "")).strip_edges()
	if sid.is_empty():
		push_warning("[Mods] %s：法术条目缺 id，跳过" % mod_id)
		return
	var src_rel := String(row.get("script", ""))
	if src_rel.is_empty():
		src_rel = String(row.get("scene", ""))
	var src_path := _resolve(dir_path, src_rel, allow_scripts)
	if src_path.is_empty():
		return
	var src: Variant = load(src_path)
	if not (src is Script or src is PackedScene):
		push_warning("[Mods] %s：法术 %s 的来源既不是脚本也不是场景，跳过" % [mod_id, sid])
		return
	var sheet: Variant = row.get("sheet", {})
	spells.append({"id": sid, "name": String(row.get("name", sid)),
			"source": src, "sheet": sheet if sheet is Dictionary else {}, "mod": mod_id})


func _load_prop(mod_id: String, dir_path: String, allow_scripts: bool, e: Variant) -> void:
	if not (e is Dictionary):
		return
	var row: Dictionary = e
	var cat := String(row.get("category", "")).strip_edges().to_lower()
	if cat.is_empty():
		push_warning("[Mods] %s：物件条目缺 category，跳过" % mod_id)
		return
	var path := _resolve(dir_path, String(row.get("scene", "")), allow_scripts)
	# 替换写法：原版资源路径 -> 本 Mod 的场景/网格
	var replace_res := String(row.get("replace_res", "")).strip_edges()
	if replace_res.is_empty() and path.is_empty():
		push_warning("[Mods] %s：物件条目既没有 scene 也没有 replace_res，跳过" % mod_id)
		return
	if path.is_empty():
		push_warning("[Mods] %s：替换 %s 需要提供 scene，跳过" % [mod_id, replace_res])
		return
	props.append({"category": cat, "id": String(row.get("id", mod_id)),
			"name": String(row.get("name", "")), "path": path,
			"base": float(row.get("base", 1.0)), "replace_res": replace_res, "mod": mod_id})
	_need_node_hooks = true


func _load_map_entry(mod_id: String, dir_path: String, allow_scripts: bool, e: Variant) -> void:
	if not (e is Dictionary):
		return
	var row: Dictionary = e
	var mid := String(row.get("id", "")).strip_edges()
	if mid.is_empty():
		push_warning("[Mods] %s：地图条目缺 id，跳过" % mod_id)
		return
	var path := _resolve(dir_path, String(row.get("scene", "")), allow_scripts)
	if path.is_empty():
		return
	if maps.has(mid):
		push_warning("[Mods] 地图 id 重复，后者忽略: %s" % mid)
		return
	maps[mid] = {"name": String(row.get("name", mid)), "path": path, "mod": mod_id}


# ============================================================================
# 注册：法术（autoload 已就绪，直接注册）
# ============================================================================

func _apply_registrations() -> void:
	# 数值表：先把 Mod 法术的数值合并进去，术法脚本读表时就能取到
	var rows := {}
	for s in spells:
		if not (s.sheet as Dictionary).is_empty():
			rows[String(s.id)] = s.sheet
	if not rows.is_empty():
		SpellSheet.inject_mod_rows(rows)
	# 术法视觉：交给 SpellCaster（它是 autoload，_ready 已执行、圆盘已建好）
	var caster := get_node_or_null("/root/SpellCaster")
	if caster != null:
		for s in spells:
			var ok: bool = caster.call("register_spell", String(s.id), s.source, String(s.name))
			if not ok:
				push_warning("[Mods] 法术注册失败（重名或来源非法）：%s" % s.id)
	else:
		if not spells.is_empty():
			push_warning("[Mods] 找不到 SpellCaster，法术无法注册")


# ============================================================================
# 注册：可摆放物件（等 Vegetation / BuildingManager 出现）
# ============================================================================

func _on_node_added(n: Node) -> void:
	var sc: Script = n.get_script()
	var sp := "" if sc == null else String((sc as Script).resource_path)
	if sp == VEGETATION_SCRIPT or sp == BUILDING_SCRIPT:
		_try_register_node(n, sp)
	if overrides.is_empty():
		return
	if n is MeshInstance3D or n is MultiMeshInstance3D:
		_pending_mesh.append(n)
		set_process(true)


## 补扫当前场景里已存在的 Vegetation / BuildingManager（主场景整体进树时不发 node_added）
func _sweep_registrants_next_frame() -> void:
	await get_tree().process_frame
	_sweep_registrants()


func _sweep_registrants() -> void:
	var sc := get_tree().current_scene
	if sc == null:
		return
	for n in sc.find_children("*", "", true, false):
		var s: Script = n.get_script()
		if s == null:
			continue
		var sp := String((s as Script).resource_path)
		if sp == VEGETATION_SCRIPT or sp == BUILDING_SCRIPT:
			_try_register_node(n, sp)


## 给一个 Vegetation / BuildingManager 节点注册物件（同一节点只做一次）
func _try_register_node(n: Node, sp: String) -> void:
	var nid := n.get_instance_id()
	if _applied_nodes.has(nid):
		return
	_applied_nodes[nid] = true
	n.tree_exiting.connect(func() -> void: _applied_nodes.erase(nid))
	if sp == VEGETATION_SCRIPT:
		_apply_props_to_vegetation(n)
	else:
		_apply_props_to_building(n)


func _apply_props_to_vegetation(veg: Node) -> void:
	# 先做"替换原版模型"：把分类表里匹配的路径换成 Mod 的
	var replaced := 0
	for p in props:
		var old_path := String(p.replace_res)
		if old_path.is_empty() or String(p.category) in ["house"]:
			continue
		replaced += int(veg.call("replace_model_path", old_path, String(p.path)))
	# 再按分类追加新模型（保持同一分类内的声明顺序）
	var by_cat := {}
	for p in props:
		var cat := String(p.category)
		if cat == "house" or not String(p.replace_res).is_empty():
			continue
		if not by_cat.has(cat):
			by_cat[cat] = []
		(by_cat[cat] as Array).append(String(p.path))
	for cat in by_cat.keys():
		var added := int(veg.call("add_model_variants", String(cat), by_cat[cat]))
		if added <= 0:
			push_warning("[Mods] 分类 %s 不存在或没有新增模型（已跳过）" % cat)
	if replaced > 0:
		print("[Mods] 替换原版模型 %d 个（植被分类表）" % replaced)


func _apply_props_to_building(bm: Node) -> void:
	var tree_paths: Array = []
	var replaced := 0
	for p in props:
		var cat := String(p.category)
		var old_path := String(p.replace_res)
		if not old_path.is_empty() and cat in ["tree", "house"]:
			var entry := {"name": String(p.name), "base": float(p.base), "path": String(p.path)}
			replaced += int(bm.call("replace_model_path", old_path, entry))
			continue
		if cat == "tree":
			bm.call("add_tree_model", {"id": String(p.id), "name": String(p.name),
					"base": float(p.base), "path": String(p.path)})
			tree_paths.append(String(p.path))
		elif cat == "house":
			bm.call("add_house_model", {"id": String(p.id), "name": String(p.name),
					"base": float(p.base), "path": String(p.path)})
	# 树的两张表必须同序：vegetation 的 "tree" 分类也要补上同样的路径
	var veg := _find_vegetation_node()
	if veg != null and not tree_paths.is_empty():
		veg.call("add_model_variants", "tree", tree_paths)
	if replaced > 0:
		print("[Mods] 替换原版模型 %d 个（建筑表）" % replaced)


## 找当前场景里的 Vegetation 节点（树表同步用；找不到就跳过，下一帧该节点出现时会自己注册）
func _find_vegetation_node() -> Node:
	var sc := get_tree().current_scene
	if sc == null:
		return null
	for n in sc.find_children("*", "", true, false):
		var s: Script = n.get_script()
		if s != null and String((s as Script).resource_path) == VEGETATION_SCRIPT:
			return n
	return null


# ============================================================================
# 贴图覆盖
# ============================================================================

## 当前场景整树扫一遍（只收网格节点，不做子树重扫）。换地图后也会再调一次。
func _sweep_current_scene() -> void:
	var sc := get_tree().current_scene
	if sc == null:
		return
	for n in sc.find_children("*", "MeshInstance3D", true, false):
		_pending_mesh.append(n)
	for n in sc.find_children("*", "MultiMeshInstance3D", true, false):
		_pending_mesh.append(n)
	if not _pending_mesh.is_empty():
		set_process(true)


## 等一帧（确保 current_scene 已就绪）再扫
func _sweep_next_frame() -> void:
	await get_tree().process_frame
	_sweep_current_scene()


func _apply_overrides_to_node(n: Node) -> void:
	_checked_meshes += 1
	if n is MeshInstance3D:
		var mi := n as MeshInstance3D
		if mi.material_override != null:
			var po := _patch_material(mi.material_override)
			if po != null:
				mi.material_override = po
		var mesh := mi.mesh
		if mesh == null:
			return
		for s in range(mesh.get_surface_count()):
			var cur := mi.get_surface_override_material(s)
			if cur == null:
				cur = mesh.surface_get_material(s)
			var patched := _patch_material(cur)
			if patched != null:
				mi.set_surface_override_material(s, patched)
	elif n is MultiMeshInstance3D:
		var mmi := n as MultiMeshInstance3D
		# 注意：MultiMesh 资源本身没有 material_override，材质挂在 MultiMeshInstance3D 节点上
		if mmi.material_override == null:
			return
		var p := _patch_material(mmi.material_override)
		if p != null:
			mmi.material_override = p


## 返回"打过覆盖的材质副本"；没有任何贴图命中时返回 null（调用方保持原样）
func _patch_material(mat: Material) -> Material:
	if mat == null:
		return null
	var mid := mat.get_instance_id()
	if _patched_cache.has(mid):
		return _patched_cache[mid] as Material
	var dup: Material = null
	if mat is ShaderMaterial:
		var sm := mat as ShaderMaterial
		var sh := sm.shader
		if sh != null:
			for u in sh.get_shader_uniform_list():
				# 不能对任意 uniform 直接用 `as Texture2D`：Godot 里对标量/向量做 as 转型
				# 会抛 "Invalid cast: can't convert a non-object value" 并中断本函数。
				# 先 is 判断再转，非贴图 uniform 直接跳过。
				var uname := String(u.get("name", ""))
				var v: Variant = sm.get_shader_parameter(uname)
				if not (v is Texture2D):
					continue
				var tex := v as Texture2D
				var rep := _lookup_texture(tex)
				if rep == null:
					continue
				if dup == null:
					dup = sm.duplicate() as ShaderMaterial
				dup.set_shader_parameter(uname, rep)
	elif mat is BaseMaterial3D:
		for prop in BASE_TEX_PROPS:
			var v: Variant = mat.get(prop)
			if not (v is Texture2D):
				continue
			var tex := v as Texture2D
			var rep := _lookup_texture(tex)
			if rep == null:
				continue
			if dup == null:
				dup = (mat as BaseMaterial3D).duplicate() as BaseMaterial3D
			dup.set(prop, rep)
	_patched_cache[mid] = dup
	if dup != null:
		_override_hits += 1
	return dup


## 某张原版贴图是否在覆盖表里；命中就返回 Mod 贴图（带缓存）
func _lookup_texture(tex: Texture2D) -> Texture2D:
	if tex == null:
		return null
	var rp := tex.resource_path
	if rp.is_empty():
		return null
	var mod_path := String(overrides.get(rp, ""))
	if mod_path.is_empty():
		return null
	if _tex_cache.has(mod_path):
		return _tex_cache[mod_path] as Texture2D
	var loaded := _load_image(mod_path)
	_tex_cache[mod_path] = loaded
	if loaded == null:
		push_warning("[Mods] 贴图覆盖加载失败：%s" % mod_path)
	return loaded


## 读 Mod 目录里的图片/材质：图片走 Image（导出后也可用），.res/.tres 走 load()
func _load_image(path: String) -> Texture2D:
	var ext := path.get_extension().to_lower()
	if ext in ["res", "tres"]:
		var r: Variant = load(path)
		return r as Texture2D
	if not IMAGE_EXTS.has(ext):
		push_warning("[Mods] 不支持的覆盖资源类型：%s" % path)
		return null
	var img := Image.new()
	var abs_path := ProjectSettings.globalize_path(path)
	if img.load(abs_path) != OK:
		return null
	return ImageTexture.create_from_image(img)


# ============================================================================
# 启动地图 / 日志
# ============================================================================

func _deferred_start_map() -> void:
	# 等主场景真正进树（current_scene 就绪）再换，避免和启动加载抢同一个场景
	await get_tree().process_frame
	await get_tree().process_frame
	if not load_map(_start_map):
		push_warning("[Mods] start_map 加载失败: %s" % _start_map)


func _log_summary() -> void:
	print("[Mods] 扫描完成：%d 个 Mod（%s）｜法术 %d ｜物件 %d ｜地图 %d ｜贴图覆盖 %d" % [
			mods.size(),
			"、".join(mods.map(func(m): return String(m.name))),
			spells.size(), props.size(), maps.size(), overrides.size()])


## 延迟一秒报一次覆盖命中数（排查"配了覆盖却没生效"时用）
func _report_overrides() -> void:
	print("[Mods] 贴图覆盖：已检查 %d 个网格，命中材质 %d 个" % [_checked_meshes, _override_hits])
