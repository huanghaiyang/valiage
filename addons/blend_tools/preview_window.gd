@tool
extends Window
## .blend 预览 / 导出 .tscn
##
## 布局：顶栏（文件）| 左：对象树（勾选=要导出）| 右：3D 预览（左键转、右键平移、滚轮缩放）
## 导出：合并成一个 .tscn / 每个对象一个 .tscn（都写到你自己选的位置）

const BlendExport := preload("res://addons/blend_tools/blend_export.gd")
const BlendAutoSplit := preload("res://addons/blend_tools/blend_autosplit.gd")

const SCREEN_RATIO := 0.8
## WASD 移动速度 = 当前距离 * 该系数（每秒），这样远近视角手感一致
const MOVE_SPEED_RATIO := 1.6
const BG_GRAY := Color(0.157, 0.157, 0.165)
const PREVIEW_BG := Color(0.196, 0.196, 0.208)
const CHECK_BLUE := Color(0.25, 0.62, 1.0)

var _path := ""
var _holder: Node3D = null
var _meshes: Array = []                 ## 场景里所有 MeshInstance3D
var _highlight: Array = []              ## 勾选对象的蓝线框

var _tree: Tree = null
var _status: Label = null
var _info: Label = null
var _vp_box: SubViewportContainer = null


## ★★ C2：导出预览弹窗 ✓（分类表 + 预估 + 进度条 + 试看/导出/取消 ✓）
##   只**读**预览网格 ✓；「仅抽稀」把结果换到预览里（再点一次 = 还原 ✓）
##   ⚠ 全部用**命名回调** ✓（GDScript 不支持"嵌套的多行 lambda" ✗ —— 踩过 ✓）
func _show_export_preview(nodes: Array, target: String, single: bool, view: int,
		ratio: float, thin: float) -> void:
	var BE: GDScript = BlendExport
	var est: Dictionary = BE.call("estimate_export", nodes, ratio, thin)
	var body := "面分类（薄片面不参与减面 ✓ 只按抽稀 ✓）\n"
	body += "%-24s %-3s %9s %6s %8s %s\n" % ["节点", "面", "三角", "V/T", "连通块", "判定"]
	for row in est["rows"]:
		body += "%-24s %-3d %9d %6.2f %8d %s\n" % [String(row["node"]).substr(0, 24),
				int(row["surf"]), int(row["tris"]), float(row["vt"]), int(row["comps"]),
				("薄片✓" if bool(row["thin"]) else "实心")]
	body += "\n预计：%d → %d（%.1f%% ✓）\n" % [int(est["before"]), int(est["after"]),
			100.0 * float(est["after"]) / maxf(1.0, float(est["before"]))]
	body += "预估 = 内存计算 ✓ 很快 ✓；真实减面要跑外部工具 ✓（几十秒~几分钟 ✓）"
	var dlg := AcceptDialog.new()
	dlg.title = "导出预览 ✓"
	dlg.ok_button_text = "直接导出 ✓"          # ★ 底栏 OK 改名 ✓（用户找不到"试看"的那一栏 ✓）
	dlg.size = Vector2i(780, 600)
	var vb := VBoxContainer.new()
	var lb := Label.new()
	lb.text = body
	vb.add_child(lb)
	var pb := ProgressBar.new()
	pb.max_value = 100.0
	pb.value = 0.0
	vb.add_child(pb)
	var st := Label.new()
	st.text = "未开始 ✓（「试看完整效果」可看真实结果 ✓）"
	st.clip_text = true
	vb.add_child(st)
	var lg := Label.new()
	lg.clip_text = true
	lg.text = ""
	vb.add_child(lg)
	dlg.add_child(vb)
	# ★★ 三个动作按钮放在**内容区** ✓（原来放在 AcceptDialog 底栏 ✗ → 被窗口宽度挤掉 ✗
	#    用户实测"找不到试看按钮" ✓）→ 现在用普通 Button ✓ 一定可见 ✓
	# ★ 弹窗里**不再放**「试看（仅抽稀）」✓（用户要求 ✓）
	#   —— 试看入口已统一在预览窗口左栏 ✓：[试看抽稀] / [试看减面] / [还原] / [取消] ✓
	#   这里只保留「试看完整效果」（对本弹窗的输入直接跑一次减面 ✓）+「取消」✓
	var hb := HBoxContainer.new()
	var b2 := Button.new()
	b2.text = "试看完整效果 ✓"
	b2.pressed.connect(_on_pv_full)
	hb.add_child(b2)
	var b3 := Button.new()
	b3.text = "取消 ✗"
	b3.pressed.connect(_on_pv_cancel)
	hb.add_child(b3)
	vb.add_child(hb)
	set_meta("blend_pv_nodes", nodes)
	set_meta("blend_pv_target", target)
	set_meta("blend_pv_single", single)
	set_meta("blend_pv_view", view)
	set_meta("blend_pv_ratio", ratio)
	set_meta("blend_pv_thin", thin)
	set_meta("blend_pv_pb", pb)
	set_meta("blend_pv_st", st)
	set_meta("blend_pv_lg", lg)
	set_meta("blend_pv_dlg", dlg)
	dlg.confirmed.connect(_on_pv_export)
	dlg.custom_action.connect(_on_pv_action)
	# 注意：本文件的 `_last_dialog` 是**函数** ✗ → 不能当变量赋值 ✓（弹窗作为子节点随窗口释放 ✓）
	add_child(dlg)
	dlg.popup_centered()


## 「直接导出」✓：打上"跳过预览"标记 → 重入 _run_export ✓
func _on_pv_export() -> void:
	set_meta("blend_skip_preview", true)
	var dlg = get_meta("blend_pv_dlg", null)
	if dlg != null and is_instance_valid(dlg):
		dlg.queue_free()
	_run_export(get_meta("blend_pv_nodes", []), String(get_meta("blend_pv_target", "")),
			bool(get_meta("blend_pv_single", false)), int(get_meta("blend_pv_view", 0)))


func _on_pv_action(action: String) -> void:
	var BE: GDScript = BlendExport
	var nodes: Array = get_meta("blend_pv_nodes", [])
	var dlg = get_meta("blend_pv_dlg", null)
	var st = get_meta("blend_pv_st", null)
	var thin := float(get_meta("blend_pv_thin", 0.0))
	var ratio := float(get_meta("blend_pv_ratio", 1.0))
	if action == "cancel":
		BE.call("trial_cancel")
		if dlg != null and is_instance_valid(dlg):
			dlg.queue_free()
		return
	if action == "thin":
		var originals: Dictionary = get_meta("blend_thin_originals", {})
		for n in nodes:
			if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
				var mi := n as MeshInstance3D
				var id := mi.get_instance_id()
				if originals.has(id):
					mi.mesh = originals[id]
					originals.erase(id)
				else:
					originals[id] = mi.mesh
					mi.mesh = BE.call("_thin_leaf_mesh", mi.mesh, thin if thin > 0.0 else 0.5)
		set_meta("blend_thin_originals", originals)
		if st != null and is_instance_valid(st):
			if originals.is_empty():
				st.text = "已还原 ✓"
			else:
				st.text = "已切换预览 ✓（再点一次 = 还原 ✓）"
		return
	if action == "full":
		var first: MeshInstance3D = null
		for n in nodes:
			if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
				first = n
				break
		if first == null:
			if st != null and is_instance_valid(st):
				st.text = "没有可试看的网格 ✗"
			return
		if BE.call("trial_begin", first.mesh, ratio, first):
			if st != null and is_instance_valid(st):
				st.text = "正在减面… ✓（可点「取消」✓；关掉弹窗不会中断 ✗）"
			set_meta("blend_pv_first", first)
			var tm := Timer.new()
			tm.wait_time = 0.2
			tm.autostart = true
			tm.timeout.connect(_on_pv_tick)
			set_meta("blend_pv_tm", tm)
			if dlg != null and is_instance_valid(dlg):
				dlg.add_child(tm)
		else:
			if st != null and is_instance_valid(st):
				st.text = String(BE.get("trial_log"))


## 内容区按钮 → 转发到 _on_pv_action ✓（避免重复逻辑 ✓）
func _on_pv_thin() -> void:
	_on_pv_action("thin")


func _on_pv_full() -> void:
	_on_pv_action("full")


func _on_pv_cancel() -> void:
	_on_pv_action("cancel")


## ★★ C2 左栏按钮回调 ✓（作用对象 = 左侧勾选的对象 ✓ 与导出一致 ✓）
func _quick_nodes() -> Array:
	var ns := _left_nodes()
	var out: Array = []
	for n in ns:
		if n is MeshInstance3D:
			if (n as MeshInstance3D).mesh != null:
				out.append(n)
			else:
				print("[试看诊断] 勾选项 mesh=null ✗ : ", (n as MeshInstance3D).name)
	print("[试看诊断] 勾选 = %d 个 ｜ 其中可用网格 = %d 个 ｜ 左树根项 = %s" % [
			ns.size(), out.size(),
			(str(_tree.get_root().get_child_count()) if _tree != null and _tree.get_root() != null else "无根")])
	return out


func _quick_ratio() -> float:
	return float(get_meta("blend_dec_ratio", 1.0))


func _quick_thin() -> float:
	return float(get_meta("blend_leaf_thin", 1.0))     # ★ 默认 1.0 = 全保留 ✓（与滑块一致 ✓）


func _quick_status(txt: String) -> void:
	# ★ 状态行**截断 + 不限宽** ✓ —— 否则长文案会把左栏撑宽 ✗ → 3D 视口被挤 ✗（用户实测 ✓）
	var s := txt.replace("\n", " ")
	if s.length() > 26:
		s = s.substr(0, 26) + "…"
	var qst = get_meta("blend_q_st", null)
	if qst != null and is_instance_valid(qst):
		qst.text = s


## [试看抽稀] ✓：瞬间把抽稀结果换到预览 ✓（再点一次 = 还原 ✓）
func _on_quick_thin() -> void:
	var BE: GDScript = BlendExport
	var nodes := _quick_nodes()
	if nodes.is_empty():
		_quick_status("先勾选要试看的对象 ✗")
		return
	# ★ 先写状态栏 ✓ 再 await 一帧让界面**重绘** ✓
	#   （抽稀是同步重计算 ✗：本树 38.7 万三角 / 17.6 万连通块 ≈ 十几秒 ✓
	#     期间编辑器无法重绘 ✗ → 不提示就像"卡死" ✓ 用户反馈过 ✓）
	_quick_status("试看抽稀：正在计算… ✓（大模型十几秒 ✓ 界面会短暂无响应 ✓）")
	await get_tree().process_frame
	var originals: Dictionary = get_meta("blend_q_originals", {})
	var t := _quick_thin()
	# ★ 默认 1.0 = 全保留 ✓ → 点试看前先提示 ✓（否则"点了没变化"会像故障 ✗）
	if t >= 1.0:
		_quick_status("请先把「薄片保留比例」调到小于 1 ✓（1.0 = 全保留 ✗）")
		return
	for n in nodes:
		var mi := n as MeshInstance3D
		var id := mi.get_instance_id()
		if not originals.has(id):
			# ★★ 记"**真·原始**网格" ✓：优先用 blend_orig_mesh 元数据 ✓
			#   （预览会把 mi.mesh 换成替身/抽稀结果 ✗ → 直接记 mi.mesh 会把**处理结果**当原始 ✗
			#     用户实测"试看污染了导出" ✓ —— 这就是污染源头 ✓）
			var om_t = mi.get_meta("blend_orig_mesh", null)
			originals[id] = om_t if om_t is Mesh else mi.mesh
		# ★★ 基底优先用"**试看减面的结果**" ✓ —— 这样抽稀**不会把减面效果还原掉** ✗→✓
		#   （用户实测：先试看减面 ✓ 再试看抽稀 ✗ → 减面白做了 ✓）
		var decimated: Dictionary = get_meta("blend_q_decimated", {})
		var base: Mesh = decimated.get(id, originals[id])
		var thin_mesh = BE.call("_thin_leaf_mesh", base, t if t > 0.0 else 0.5)
		if thin_mesh != null and thin_mesh is Mesh:
			mi.mesh = thin_mesh
		else:
			print("[试看诊断] 抽稀返回空 ✗ → 保持原网格 ✓")
	set_meta("blend_q_originals", originals)
	_quick_status("试看抽稀 ✓ 抽稀 %.2f（点「还原」恢复 ✓）" % (t if t > 0.0 else 0.5))


## [试看减面] ✓：非阻塞跑真实减面 ✓（左栏进度条 + 日志 ✓ 可再点一次取消 ✓）
func _on_quick_full() -> void:
	var BE: GDScript = BlendExport
	var nodes := _quick_nodes()
	if nodes.is_empty():
		_quick_status("先勾选要试看的对象 ✗")
		return
	var first: MeshInstance3D = nodes[0]
	var r := _quick_ratio()
	# ★★ 减面试看也一律以**原始网格**为输入 ✓（若之前抽稀过 ✗ → 先记下原始 ✓ 再用原始跑 ✓）
	var originals: Dictionary = get_meta("blend_q_originals", {})
	var fid := first.get_instance_id()
	if not originals.has(fid):
		# ★★ 同上：必须记"**真·原始**网格" ✓（用 blend_orig_mesh 元数据 ✓）
		#   否则"已抽稀的预览网格"会被当成原始输入 ✗ → 试看污染导出 ✓（用户实测 ✓）
		var om_f = first.get_meta("blend_orig_mesh", null)
		originals[fid] = om_f if om_f is Mesh else first.mesh
		set_meta("blend_q_originals", originals)
	if BE.call("trial_begin", originals[fid], r, first):
		set_meta("blend_q_first", first)
		# ★ 任务开始了才显示进度条 ✓ 并归零 ✓
		var qbar0 = get_meta("blend_q_bar", null)
		if qbar0 != null and is_instance_valid(qbar0):
			qbar0.visible = true
			qbar0.value = 0.0
		var qt = get_meta("blend_q_timer", null)
		if qt != null and is_instance_valid(qt):
			qt.start()
		_quick_status("试看减面：正在跑… ✓（要停就点「取消」✓）")
	else:
		_quick_status("试看减面 ✗：" + String(BE.get("trial_log")))


## 每 0.2s 轮询 ✓（左栏进度条 + 状态 ✓）；完成 → 把低模换到预览 ✓
## [还原] ✓：把预览网格恢复成**原始**网格 ✓（抽稀 / 减面试看的共同出口 ✓）
func _on_quick_restore() -> void:
	var originals: Dictionary = get_meta("blend_q_originals", {})
	var n_restored := 0
	for n in _quick_nodes_all():
		var mi := n as MeshInstance3D
		var id := mi.get_instance_id()
		if originals.has(id):
			mi.mesh = originals[id]
			n_restored += 1
	set_meta("blend_q_originals", {})
	set_meta("blend_q_decimated", {})     # ★ 还原时两份都清空 ✓（否则会留"减面结果"的残留 ✗）
	_quick_status("已还原 ✓（%d 个网格 ✓）" % n_restored)


## 取**所有**预览网格 ✓（还原不受"当前勾选"限制 ✓；从窗口自身遍历 ✓ 不依赖具体成员 ✓）
## ★ 只看勾选 ✓：勾上 = 隐藏所有**未勾选**的网格 ✓（预览 ≈ 导出 ✓）
func _on_only_checked_toggled(v: bool) -> void:
	set_meta("blend_only_checked", v)
	_apply_only_checked()


func _apply_only_checked() -> void:
	var all_nodes := _quick_nodes_all()          # 预览里所有带网格的节点 ✓（不管可见性 ✓）
	if not bool(get_meta("blend_only_checked", false)):
		for n in all_nodes:
			var mi0 := n as MeshInstance3D
			if is_instance_valid(mi0):
				mi0.visible = true
		return
	var keep := {}
	for n in _checked_nodes():
		keep[n.get_instance_id()] = true
	var hidden := 0
	for n in all_nodes:
		var mi := n as MeshInstance3D
		if not is_instance_valid(mi):
			continue
		var on: bool = keep.has(mi.get_instance_id())
		mi.visible = on
		if not on:
			hidden += 1
	_quick_status("只看勾选 ✓（隐藏了 %d 个节点 ✓）" % hidden)


func _quick_nodes_all() -> Array:
	var out: Array = []
	var stack: Array = [self]
	while not stack.is_empty():
		var n = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			out.append(n)
		for c in n.get_children():
			stack.append(c)
	return out


## [取消] ✓：终止正在跑的减面试看 ✓（OS.kill ✓）
func _on_quick_cancel() -> void:
	var BE: GDScript = BlendExport
	var qt = get_meta("blend_q_timer", null)
	if qt != null and is_instance_valid(qt):
		qt.stop()
	BE.call("trial_cancel")
	_quick_status("已取消 ✓（正在跑的减面已终止 ✓）")


func _on_quick_tick() -> void:
	var BE: GDScript = BlendExport
	var s2: int = BE.call("trial_poll")
	var qbar = get_meta("blend_q_bar", null)
	if qbar != null and is_instance_valid(qbar):
		qbar.value = float(BE.get("trial_progress"))
	var qt = get_meta("blend_q_timer", null)
	if s2 == 1:
		_quick_status("试看减面 ✓ %d%%" % int(BE.get("trial_progress")))
		return
	if qt != null and is_instance_valid(qt):
		qt.stop()
	if s2 == 2:
		var first = get_meta("blend_q_first", null)
		if first != null and is_instance_valid(first) and first.mesh != null:
			var low: Mesh = BE.get("trial_mesh")
			# ★★ 记住"减面结果" ✓，并把**当前的抽稀**叠加在它上面 ✓
			#   → 两个试看效果**互不还原** ✓✓（用户要求 ✓）
			var decimated: Dictionary = get_meta("blend_q_decimated", {})
			decimated[first.get_instance_id()] = low
			set_meta("blend_q_decimated", decimated)
			var t := _quick_thin()
			if t > 0.0 and t < 1.0:
				var thin_low = BE.call("_thin_leaf_mesh", low, t)
				if thin_low != null and thin_low is Mesh:
					print("[试看] 已把抽稀 %.2f 叠加到减面结果上 ✓（两个效果共存 ✓）" % t)
					low = thin_low
			first.mesh = low
		_quick_status("试看减面完成 ✓（已换到预览 ✓ 直接导出即可 ✓）")
	elif s2 == 3:
		_quick_status("试看减面失败 ✗：" + String(BE.get("trial_log")))
	elif s2 == 4:
		_quick_status("试看减面：已取消 ✓")


## [详情…] ✓：弹出分类表 + 预估 ✓
##   ★★ 必须用**原始网格**算 ✓ —— 否则"试看抽稀/减面"之后再来算 ✗
##      会把**已经处理过**的网格当成输入 ✓ → 数字完全不对 ✗（用户实测：14 / 142 / 37809 ✗）
##   做法：临时把节点 mesh 换回原始 ✓ → 算完立刻换回当前预览 ✓
func _on_quick_detail() -> void:
	var nodes := _quick_nodes()
	var originals: Dictionary = get_meta("blend_q_originals", {})
	var prev: Array = []
	for n in nodes:
		var mi := n as MeshInstance3D
		var id := mi.get_instance_id()
		if originals.has(id):
			prev.append([mi, mi.mesh])
			mi.mesh = originals[id]
	_show_export_preview(nodes, "", true, 0, _quick_ratio(), _quick_thin())
	for pair in prev:
		var mi2: MeshInstance3D = pair[0]
		if is_instance_valid(mi2):
			mi2.mesh = pair[1]


func _on_pv_tick() -> void:
	var BE: GDScript = BlendExport
	var s2: int = BE.call("trial_poll")
	var pb = get_meta("blend_pv_pb", null)
	var st = get_meta("blend_pv_st", null)
	var lg = get_meta("blend_pv_lg", null)
	var tm = get_meta("blend_pv_tm", null)
	if pb != null and is_instance_valid(pb):
		pb.value = float(BE.get("trial_progress"))
	if lg != null and is_instance_valid(lg):
		lg.text = String(BE.get("trial_log")).replace("\n", " ｜ ")
	if s2 == 2:
		var first = get_meta("blend_pv_first", null)
		if first != null and is_instance_valid(first) and first.mesh != null:
			first.mesh = BE.get("trial_mesh")
		if st != null and is_instance_valid(st):
			st.text = "试看完成 ✓（已换到预览 ✓ 点「直接导出」写文件 ✓）"
		if tm != null and is_instance_valid(tm):
			tm.stop()
	elif s2 == 3:
		if st != null and is_instance_valid(st):
			st.text = "试看失败 ✗（看下方日志 ✓）"
		if tm != null and is_instance_valid(tm):
			tm.stop()
	elif s2 == 4:
		if st != null and is_instance_valid(st):
			st.text = "已取消 ✓"
		if tm != null and is_instance_valid(tm):
			tm.stop()
var _vp: SubViewport = null
var _cam: Camera3D = null
var _split_tree: Tree = null
var _split_box: SubViewportContainer = null
var _split_vp: SubViewport = null
var _split_cam: Camera3D = null
var _split_holder: Node3D = null
var _cuts: Array = []
# 右侧（自动拆分）预览的独立相机状态：和左边互不影响
var _syaw := 0.7
var _spitch := 0.3
var _sdist := 3.0
var _starget := Vector3.ZERO
var _s_dragging := false
var _s_drag_btn := MOUSE_BUTTON_LEFT
var _s_last_mouse := Vector2.ZERO
# WASD 作用于哪一个预览：鼠标停在哪个窗口就动哪个；都不在就用最后停过的那个
var _hover_left := false
var _hover_right := false
var _wasd_view := 0            # 0 = 左边 blend 预览，1 = 右边自动拆分预览
## 自己维护 WASD 按下状态：比 Input.is_key_pressed() 可靠
## （按键可能被编辑器/别处吃掉，而且这样合成事件也能驱动 -> 可测）
var _keys := {}
var _split_status: Label = null     # ★ 右侧自己的状态栏（和左侧互不干扰）
var _split_busy := false            # ★ 右侧自己的忙碌标记
var _tex_check: CheckBox = null     # ★ 左侧：白膜 / 贴图 切换
var _wind_check: CheckBox = null    # ★ 共用导出选项（顶部栏）：是否把风参数写进材质
var _shader_path := BlendExport.SHADER_PATH          # ★ 导出材质用哪个 shader（默认项目里的 grass_wind）
var _shader_btn: Button = null
var _shader_label: Label = null
var _relinked := {}                 # 网格实例 -> 带贴图的**网格副本**
var _orig_mesh := {}                # 网格实例 -> 原始网格（切回白膜时还原）
var _picker_file: EditorFileDialog = null
var _picker_dir: EditorFileDialog = null
var _busy := false

# 轨道相机
var _yaw := 0.7
var _pitch := 0.35
var _dist := 4.0
var _target := Vector3.ZERO
var _dragging := false
var _drag_btn := MOUSE_BUTTON_LEFT
var _last_mouse := Vector2.ZERO


func _init() -> void:
	# 只做窗口自身设置。**不能**在这里读主题/建控件：
	# EditorInterface.get_editor_theme() 只在编辑器里存在，无头环境一调用整个 _init 就中断，
	# 结果 _build_ui() 根本不会执行（这个坑在 GLB 切割工具里也踩过一次）。
	title = "Blender 预览 / 导出 TSCN"
	var screen := DisplayServer.screen_get_size()
	size = Vector2i(int(screen.x * SCREEN_RATIO), int(screen.y * SCREEN_RATIO))
	min_size = Vector2i(900, 600)
	# 不接 hide：由 open_window.gd 接 close_requested 做销毁（否则实例复用 -> 脚本不更新）


func _ready() -> void:
	_apply_theme()
	if get_child_count() == 0:
		_build_ui()
	set_process(true)


func _apply_theme() -> void:
	if not Engine.is_editor_hint():
		return
	var th := EditorInterface.get_editor_theme()
	if th != null:
		theme = th


## 保证界面已经建出来。open_window.gd 是 add_child 之后**立刻**调 open_with 的，
## 而 _ready 要等一帧才跑 -> 那时界面还不存在，会直接崩。这里兜住。
func _ensure_ui() -> void:
	if _status != null:
		return
	_apply_theme()
	_build_ui()


func _build_ui() -> void:
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var sb := StyleBoxFlat.new()
	sb.bg_color = BG_GRAY
	panel.add_theme_stylebox_override("panel", sb)
	add_child(panel)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 8)
	panel.add_child(margin)
	var vb := VBoxContainer.new()
	vb.add_theme_constant_override("separation", 6)
	margin.add_child(vb)

	# 顶栏
	var top := HBoxContainer.new()
	var lab := Label.new()
	lab.text = "文件"
	top.add_child(lab)
	_info = Label.new()
	_info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_info.clip_text = true
	top.add_child(_info)
	# ★ 共用导出选项：两个面板导出时都用这一个（放在顶部栏，一眼能看到）
	_wind_check = CheckBox.new()
	_wind_check.text = "初始化风参数"
	_wind_check.button_pressed = true
	_wind_check.tooltip_text = "勾上：导出的材质写入风向/风力/阵风/频率/湍流（受天气系统驱动）；不勾：不写，这些草无风"
	top.add_child(_wind_check)
	# 导出材质用哪个 shader（默认 = 项目里的 assets/shaders/grass_wind.gdshader）
	# 用「按钮 + 标签」而不是 EditorResourcePicker：后者是编辑器专用控件，
	# 创建不出来时会让整个界面构建中断，不稳。
	var sh_lab := Label.new()
	sh_lab.text = "材质 shader"
	top.add_child(sh_lab)
	_shader_btn = Button.new()
	_shader_btn.text = "选择…"
	_shader_btn.tooltip_text = "点这里挑导出材质用的 shader（默认 assets/shaders/grass_wind.gdshader）"
	_shader_btn.pressed.connect(_on_pick_shader)
	top.add_child(_shader_btn)
	_shader_label = Label.new()
	_shader_label.clip_text = true                                  # 别让长路径撑爆顶部栏
	_shader_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_shader_label.custom_minimum_size = Vector2(200, 0)
	_shader_label.tooltip_text = _shader_path
	_shader_label.text = _shader_path                              # ★ 显示**完整路径**
	top.add_child(_shader_label)
	vb.add_child(top)

	# 主体
	# 外层左右分栏：左 = blend 预览（树 + 3D），右 = 自动拆分结果（列表 + 带贴图模型）
	# 用 HBoxContainer + 明确比例，不用 HSplitContainer 的像素偏移：
	# 子控件的最小尺寸会撑爆窗口，导致右侧被挤出可视区（看得见、点不到）。
	var outer := HBoxContainer.new()
	outer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_theme_constant_override("separation", 8)
	vb.add_child(outer)

	var inner := HBoxContainer.new()
	inner.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	inner.size_flags_stretch_ratio = 1.15
	inner.add_theme_constant_override("separation", 6)
	outer.add_child(inner)

	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(200, 0)
	left.size_flags_stretch_ratio = 0.55
	inner.add_child(left)
	_tree = Tree.new()
	_tree.columns = 2
	_tree.set_column_title(0, "对象")
	_tree.set_column_title(1, "三角")
	_tree.column_titles_visible = true
	_tree.hide_root = true
	_tree.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# 关键：Tree 会按列内容长度算最小宽度，长名字会把窗口撑爆 -> 列设成可扩展 + 很小的最小宽度
	_tree.set_column_expand(0, true)
	_tree.set_column_expand(1, false)
	_tree.set_column_custom_minimum_width(0, 70)
	# ★ 「三角」列宽：原来是 40 ✗ —— 6~7 位数（如 495533 / 2062487）会被截断 ✓
	#   （用户反馈："表头【三角】，数字过大时显示不全" ✓）
	#   该列 `set_column_expand(1, false)` ✓ → 宽度固定，放宽它**不会挤压"对象"列** ✓
	_tree.set_column_custom_minimum_width(1, 96)
	_tree.item_edited.connect(_on_item_edited)
	left.add_child(_tree)
	var ltop := HFlowContainer.new()   # 用可换行容器：否则撑开的提示标签会把勾选框挤出可视区
	var lhint := Label.new()
	lhint.text = "左键转 / 右键平移 / 滚轮缩放 / WASD 移动"
	lhint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ltop.add_child(lhint)
	# 白膜 / 贴图 切换。blend 里的贴图链接是断的 -> 导入材质本来就是白膜，
	# 勾上则用"按名字回链项目贴图"的材质。
	_tex_check = CheckBox.new()
	_tex_check.text = "贴图"
	_tex_check.button_pressed = true
	_tex_check.tooltip_text = "勾上 = 用回链的项目贴图；不勾 = 原始白膜（只看形状时更方便）"
	_tex_check.toggled.connect(_on_tex_toggled)
	ltop.add_child(_tex_check)

	var lrow := HBoxContainer.new()
	var b_all := Button.new()
	b_all.text = "全选"
	b_all.pressed.connect(_on_select_all)
	lrow.add_child(b_all)
	var b_none := Button.new()
	b_none.text = "全不选"
	b_none.pressed.connect(_on_select_none)
	lrow.add_child(b_none)
	left.add_child(lrow)
	# ★★ 只看勾选 ✓（用户要求）：勾上后**隐藏所有未勾选**的网格 ✓
	#   为什么需要：预览会画出文件里**所有**网格 ✗（你的树有 LOD0+LOD1 ✓）
	#   → 只看 LOD1 的试看效果会被 LOD0 盖住 ✗ → 勾上它 = 预览 ≈ 导出 ✓✓
	var chk_only := CheckBox.new()
	chk_only.text = "只看勾选（预览 ≈ 导出 ✓）"
	chk_only.button_pressed = false
	chk_only.toggled.connect(_on_only_checked_toggled)
	left.add_child(chk_only)
	set_meta("blend_only_checked", false)
	# 左侧自己的导出（导出左树里勾选的对象）
	var lexp := HBoxContainer.new()
	var lb1 := Button.new()
	lb1.text = "导出选中 -> 单个 .tscn…"
	lb1.tooltip_text = "把左边勾选的对象放进一个场景文件"
	lb1.pressed.connect(_on_export_single)
	lexp.add_child(lb1)
	var lb2 := Button.new()
	lb2.text = "导出选中 -> 文件夹…"
	lb2.tooltip_text = "每个勾选对象各保存一个 .tscn"
	lb2.pressed.connect(_on_export_dir)
	lexp.add_child(lb2)
	left.add_child(lexp)
	# ★ 导出减面比例（方案 A ✓）：1.0 = 不降面 ✓；<1.0 时导出走
	#   "节点树 → 临时 GLB → npx @gltf-transform/cli weld+simplify --ratio R → 读回" ✓
	#   （工具不可用/失败 → 自动按未减面导出并给出提示 ✓ 不会把导出搞坏 ✓）
	var drow := HBoxContainer.new()
	var dlbl := Label.new()
	# ★ 说明：底层工具（@gltf-transform/cli simplify --ratio R）的 R 是"**保留**面数比例" ✓
	#   —— 0.35 = **只保留 35%** 面（= 减掉 65% ✓）；1.0 = 不降面 ✓
	#   所以标签必须写成"保留"，否则很容易被当成"减掉多少" ✗（用户指出过 ✓）
	dlbl.text = "保留面数比例"
	drow.add_child(dlbl)
	var dr := SpinBox.new()
	dr.min_value = 0.05
	dr.max_value = 1.0
	dr.step = 0.05
	dr.value = 1.0
	# ★ 不要在这里设 tooltip_text ✗：在 Window 里它会弹独立小窗口 ✓
	#   实测会把鼠标指针"盖没" ✗（用户反馈 ✓）→ 语义写在左边的标签上就够了 ✓
	dr.mouse_default_cursor_shape = Control.CURSOR_ARROW   # 明确用普通箭头 ✓
	# 值存在 self 的 meta 上 → _run_export() 直接读 ✓（不必再加成员变量 ✓）
	set_meta("blend_dec_ratio", 1.0)
	dr.value_changed.connect(func(v: float) -> void: set_meta("blend_dec_ratio", v))
	drow.add_child(dr)
	left.add_child(drow)
	# ★★ 叶片抽稀（**独立于减面** ✓）：树叶是"每片 2~3 面的独立薄片" ✗
	#   → 边塌陷减面对它**数学上无效** ✓（块内无共享边 ✗）；只能**整片整片地丢** ✓
	#   实测：LOD1 叶子 = 386,574 三角 / 175,899 片 / 平均 2.20 三角每片 ✓
	#   0 = 不动 ✓（默认，保持原有行为 ✓）；0.5 = 每片叶子只留一半 ✓
	var lrow2 := HBoxContainer.new()
	var llbl2 := Label.new()
	# ★ 名字与「保留面数比例」保持一致 ✓：语义是"**保留**多少叶片" ✓
	#   （原来叫「叶片抽稀」✗ → 会被理解成"去掉多少" ✗ —— 用户问过 ✓）
	#   0 = 不抽稀 ✓（保持原样 ✓）；0.25 = 只留 25% 叶片（去掉 75% ✓）；1.0 = 全留 ✓
	# ★ 名字用「**薄片**」✓（用户要求 ✓）：这条规则对所有薄片面生效 ✓
	#   （树叶 ✓ 草丛 ✓ 花瓣 ✓ 栅栏铁艺 ✓ 布料 ✓ 绳链 ✓ 羽毛卡片 ✓）
	#   ★ 默认 **1.0 = 全保留** ✓（与「保留面数比例」一致 ✓；0.05 = 只留 5% ✓）
	llbl2.text = "薄片保留比例"
	lrow2.add_child(llbl2)
	var lr := SpinBox.new()
	lr.min_value = 0.05
	lr.max_value = 1.0
	lr.step = 0.05
	lr.value = 1.0
	lr.mouse_default_cursor_shape = Control.CURSOR_ARROW
	set_meta("blend_leaf_thin", 1.0)
	lr.value_changed.connect(func(v: float) -> void: set_meta("blend_leaf_thin", v))
	lrow2.add_child(lr)
	left.add_child(lrow2)
	# ★★ C2：试看按钮直接放在**左栏** ✓（用户要求：不要藏在弹窗里 ✗）
	#   作用对象 = 左侧**当前勾选**的对象 ✓（与导出同一套选择 ✓）
	#   [试看抽稀] 瞬间 ✓ ｜ [试看减面] 非阻塞跑外部减面 ✓ ｜ [详情…] 弹出分类表+预估 ✓
	var prow := HBoxContainer.new()
	var q_thin := Button.new()
	q_thin.text = "试看抽稀"
	q_thin.pressed.connect(_on_quick_thin)
	prow.add_child(q_thin)
	var q_full := Button.new()
	q_full.text = "试看减面"
	q_full.pressed.connect(_on_quick_full)
	prow.add_child(q_full)
	left.add_child(prow)
	# ★ 第二排：还原 / 取消 / 详情 ✓（用户要求：还原要有**独立按钮** ✓ 不要靠"再点一次" ✗）
	var prow2 := HBoxContainer.new()
	var q_restore := Button.new()
	q_restore.text = "还原"
	q_restore.pressed.connect(_on_quick_restore)
	prow2.add_child(q_restore)
	var q_cancel := Button.new()
	q_cancel.text = "取消"
	q_cancel.pressed.connect(_on_quick_cancel)
	prow2.add_child(q_cancel)
	var q_info := Button.new()
	q_info.text = "详情…"
	q_info.pressed.connect(_on_quick_detail)
	prow2.add_child(q_info)
	left.add_child(prow2)
	var qbar := ProgressBar.new()
	qbar.max_value = 100.0
	qbar.value = 0.0
	qbar.custom_minimum_size = Vector2(0, 14)
	left.add_child(qbar)
	# ★ 未开始**不显示**进度条 ✓（用户要求：别在没任务时挂着 0% ✗）
	#   只在「试看减面」真正启动时显示 ✓
	qbar.visible = false
	var qst := Label.new()
	qst.clip_text = true
	qst.text = "试看：点上面按钮 ✓"
	left.add_child(qst)
	set_meta("blend_q_bar", qbar)
	set_meta("blend_q_st", qst)
	var qtimer := Timer.new()
	qtimer.wait_time = 0.2
	qtimer.autostart = false
	qtimer.timeout.connect(_on_quick_tick)
	left.add_child(qtimer)
	set_meta("blend_q_timer", qtimer)
	_status = Label.new()
	_status.clip_text = true
	left.add_child(_status)

	_vp_box = SubViewportContainer.new()
	_vp_box.stretch = true
	_vp_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vp_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# 不用 gui_input：stretch 的 SubViewportContainer 会把鼠标事件吞进子视口。统一在 _input 里处理。
	_vp_box.mouse_entered.connect(_on_left_enter)
	_vp_box.mouse_exited.connect(_on_left_exit)
	inner.add_child(_vp_box)

	_vp = SubViewport.new()
	_vp.own_world_3d = true
	_vp.transparent_bg = false
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp_box.add_child(_vp)

	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = PREVIEW_BG
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.85, 0.85, 0.88)
	e.ambient_light_energy = 0.9
	env.environment = e
	_vp.add_child(env)
	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-45, -35, 0)
	sun.light_energy = 1.1
	_vp.add_child(sun)

	_holder = Node3D.new()
	_holder.name = "Holder"
	_vp.add_child(_holder)

	_cam = Camera3D.new()
	_cam.fov = 45.0
	_cam.current = true
	_vp.add_child(_cam)

	# ---------- 右半边：自动拆分 ----------
	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(220, 0)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_stretch_ratio = 1.0
	outer.add_child(right)
	var rrow := HBoxContainer.new()
	var b_split := Button.new()
	b_split.text = "自动拆分（从贴图图集找素材块）"
	b_split.tooltip_text = "扫描贴图，自动找出每个素材块，并配上对应的模型；配不到就显示「模型为空」"
	b_split.pressed.connect(_on_autosplit)
	rrow.add_child(b_split)
	right.add_child(rrow)
	_split_tree = Tree.new()
	_split_tree.columns = 2
	_split_tree.set_column_title(0, "素材块")
	_split_tree.set_column_title(1, "状态")
	_split_tree.column_titles_visible = true
	_split_tree.hide_root = true
	_split_tree.custom_minimum_size = Vector2(0, 160)
	_split_tree.set_column_expand(0, true)
	_split_tree.set_column_expand(1, true)
	_split_tree.set_column_custom_minimum_width(0, 60)
	_split_tree.set_column_custom_minimum_width(1, 60)
	right.add_child(_split_tree)
	var rrow2 := HBoxContainer.new()
	var b_fit := Button.new()
	b_fit.text = "适配视图"
	b_fit.tooltip_text = "把右侧预览的镜头重新框住全部拆分模型"
	b_fit.pressed.connect(_on_split_fit)
	rrow2.add_child(b_fit)
	var hint := Label.new()
	hint.text = "左键转 / 右键平移 / 滚轮缩放 / WASD 移动"
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rrow2.add_child(hint)
	right.add_child(rrow2)
	_split_box = SubViewportContainer.new()
	_split_box.stretch = true
	_split_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	# 同上：统一在 _input 里处理
	_split_box.mouse_entered.connect(_on_right_enter)
	_split_box.mouse_exited.connect(_on_right_exit)
	right.add_child(_split_box)
	_split_vp = SubViewport.new()
	_split_vp.own_world_3d = true
	_split_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_split_box.add_child(_split_vp)
	var env2 := WorldEnvironment.new()
	var e2 := Environment.new()
	e2.background_mode = Environment.BG_COLOR
	e2.background_color = PREVIEW_BG
	e2.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e2.ambient_light_color = Color(0.9, 0.9, 0.92)
	e2.ambient_light_energy = 1.0
	env2.environment = e2
	_split_vp.add_child(env2)
	var sun2 := DirectionalLight3D.new()
	sun2.rotation_degrees = Vector3(-40, -30, 0)
	sun2.light_energy = 1.2
	_split_vp.add_child(sun2)
	_split_holder = Node3D.new()
	_split_holder.name = "SplitHolder"
	_split_vp.add_child(_split_holder)
	_split_cam = Camera3D.new()
	_split_cam.fov = 40.0
	_split_cam.current = true
	_split_vp.add_child(_split_cam)
	# 右侧自己的导出（导出自动拆分出来的模型；跳过"模型为空"）
	var rexp := HBoxContainer.new()
	var rb1 := Button.new()
	rb1.text = "导出拆分 -> 每模型一个…"
	rb1.tooltip_text = "把自动拆分出来的每个模型各存一个 .tscn（跳过模型为空的块）"
	rb1.pressed.connect(_on_split_export_dir)
	rexp.add_child(rb1)
	var rb2 := Button.new()
	rb2.text = "导出拆分 -> 单个 .tscn…"
	rb2.tooltip_text = "把自动拆分出来的模型放进一个场景文件"
	rb2.pressed.connect(_on_split_export_single)
	rexp.add_child(rb2)
	right.add_child(rexp)
	_split_status = Label.new()
	_split_status.clip_text = true
	right.add_child(_split_status)

	# （导出按钮与状态栏已各自放进左右面板，不再共用底栏）


# ------------------------------------------------------------------ 打开

func open_with(path: String) -> void:
	_ensure_ui()          # ★ 界面可能还没建（_ready 要等一帧）
	_path = path
	_info.text = "%s    (%s)" % [path.get_file(), path]
	_clear()
	var ps: PackedScene = ResourceLoader.load(path, "", ResourceLoader.CACHE_MODE_IGNORE)
	if ps == null:
		_status.text = "载入失败（.blend 需要配置 Blender 可执行路径才能导入）"
		if _split_status != null:
			_split_status.text = ""
		return
	var root: Node = ps.instantiate()
	_holder.add_child(root)
	var src_dir := path.get_base_dir()
	_meshes.clear()
	var stack: Array = [root]
	while not stack.is_empty():
		var n: Node = stack.pop_back()
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			# 记下源目录：导出时按名字回链贴图（含 textures/ 子目录）
			(n as MeshInstance3D).set_meta("blend_src", src_dir)
			_meshes.append(n)
		for c in n.get_children():
			stack.append(c)
	_fill_tree(root)
	_frame_preview()
	_status.text = "已载入 %d 个网格对象（勾选后导出）" % _meshes.size()
	_apply_left_materials(_tex_check != null and _tex_check.button_pressed)
	_refresh_highlight()


func _clear() -> void:
	for c in _holder.get_children():
		c.queue_free()
	for h in _highlight:
		if is_instance_valid(h):
			h.queue_free()
	_highlight.clear()
	_tree.clear()
	_meshes.clear()
	_relinked.clear()
	_orig_mesh.clear()


func _fill_tree(root: Node) -> void:
	_tree.clear()
	var troot := _tree.create_item()
	_add_tree_items(troot, root)


func _add_tree_items(parent: TreeItem, node: Node) -> void:
	for c in node.get_children():
		var it := _tree.create_item(parent)
		# 两个坑，别看错：
		#  1) CELL_MODE_CHECK 的单元格**必须**是可编辑的，否则复选框点不动
		#     （Godot 的规则：可编辑时才允许切换勾选）
		#  2) 但**顺序**很关键：先设单元格模式/可编辑，**最后**再写文字。
		#     反过来（先 set_text 再 set_cell_mode）会把文字吃掉，列表就只剩勾选框了。
		if c is MeshInstance3D and (c as MeshInstance3D).mesh != null:
			var m: Mesh = (c as MeshInstance3D).mesh
			var tris := 0
			for s in range(m.get_surface_count()):
				var ar := m.surface_get_arrays(s)
				var idx := ar[Mesh.ARRAY_INDEX] as PackedInt32Array
				tris += (idx.size() if idx != null and idx.size() > 0 else (ar[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()) / 3
			it.set_cell_mode(0, TreeItem.CELL_MODE_CHECK)
			it.set_editable(0, true)          # ★ 必须：否则复选框点不动
			it.set_text(1, str(tris))
			it.set_metadata(0, c)
		it.set_text(0, String(c.name))
		_add_tree_items(it, c)


## 勾选/取消 -> 高亮跟着变（勾选的就是会导出的）
func _on_item_edited() -> void:
	_refresh_highlight()
	_apply_only_checked()          # ★ 勾选一变就同步"只看勾选"的隐藏状态 ✓


func _on_select_all() -> void:
	_set_all_checked(true)


func _on_select_none() -> void:
	_set_all_checked(false)


func _set_all_checked(v: bool) -> void:
	var stack: Array = []
	var r := _tree.get_root()
	if r != null:
		for c in r.get_children():
			stack.append(c)
	while not stack.is_empty():
		var it: TreeItem = stack.pop_back()
		if it.get_cell_mode(0) == TreeItem.CELL_MODE_CHECK:
			it.set_checked(0, v)
		for c2 in it.get_children():
			stack.append(c2)
	_refresh_highlight()


func _checked_nodes() -> Array:
	var out: Array = []
	var stack: Array = []
	var r := _tree.get_root()
	if r != null:
		for c in r.get_children():
			stack.append(c)
	while not stack.is_empty():
		var it: TreeItem = stack.pop_back()
		if it.get_cell_mode(0) == TreeItem.CELL_MODE_CHECK and it.is_checked(0):
			var md = it.get_metadata(0)
			if md is MeshInstance3D:
				out.append(md)
		for c2 in it.get_children():
			stack.append(c2)
	return out


# ------------------------------------------------------------------ 高亮 + 相机

func _refresh_highlight() -> void:
	for h in _highlight:
		if is_instance_valid(h):
			h.queue_free()
	_highlight.clear()
	for n in _checked_nodes():
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		var box := MeshInstance3D.new()
		var im := ImmediateMesh.new()
		var aabb := mi.mesh.get_aabb()
		var xf: Transform3D = mi.global_transform if mi.is_inside_tree() else mi.transform
		im.surface_begin(Mesh.PRIMITIVE_LINES)
		var pts := [
			Vector3(aabb.position.x, aabb.position.y, aabb.position.z),
			Vector3(aabb.end.x, aabb.position.y, aabb.position.z),
			Vector3(aabb.end.x, aabb.position.y, aabb.end.z),
			Vector3(aabb.position.x, aabb.position.y, aabb.end.z),
			Vector3(aabb.position.x, aabb.end.y, aabb.position.z),
			Vector3(aabb.end.x, aabb.end.y, aabb.position.z),
			Vector3(aabb.end.x, aabb.end.y, aabb.end.z),
			Vector3(aabb.position.x, aabb.end.y, aabb.end.z),
		]
		var edges := [[0,1],[1,2],[2,3],[3,0],[4,5],[5,6],[6,7],[7,4],[0,4],[1,5],[2,6],[3,7]]
		for ed in edges:
			im.surface_add_vertex(xf * pts[ed[0]])
			im.surface_add_vertex(xf * pts[ed[1]])
		im.surface_end()
		box.mesh = im
		var m := StandardMaterial3D.new()
		m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		m.albedo_color = CHECK_BLUE
		m.vertex_color_use_as_albedo = false
		box.material_override = m
		_holder.add_child(box)
		_highlight.append(box)


func _model_aabb() -> AABB:
	var out := AABB()
	var first := true
	for n in _meshes:
		var mi := n as MeshInstance3D
		if mi.mesh == null:
			continue
		var aabb := mi.mesh.get_aabb()
		var xf: Transform3D = mi.global_transform if mi.is_inside_tree() else mi.transform
		for i in range(8):
			var corner := aabb.get_endpoint(i)
			var w := xf * corner
			if first:
				out = AABB(w, Vector3.ZERO)
				first = false
			else:
				out = out.expand(w)
	return out


func _frame_preview() -> void:
	var aabb := _model_aabb()
	if aabb.size.length() < 0.0001:
		_target = Vector3.ZERO
		_dist = 4.0
	else:
		_target = aabb.get_center()
		_dist = maxf(0.4, aabb.size.length() * 1.4)
	_apply_orbit()


func _apply_orbit() -> void:
	if _cam == null:
		return
	var dir := Vector3(
		cos(_pitch) * sin(_yaw),
		sin(_pitch),
		cos(_pitch) * cos(_yaw))
	_cam.global_position = _target + dir * _dist
	_cam.look_at(_target, Vector3.UP)


func _process(delta: float) -> void:
	_apply_orbit()
	_apply_split_orbit()
	_handle_wasd(delta)


## 窗口的输入统一在这里处理（鼠标 + WASD）。
## 为什么不用 SubViewportContainer.gui_input：stretch=true 时它会把鼠标事件转发进
## 子视口并吞掉，容器自己的 gui_input 收不到 -> 右边就不响应了。这里自己拿矩形做命中判断。
func _input(ev: InputEvent) -> void:
	if ev is InputEventKey:
		var k := ev as InputEventKey
		if not (k.keycode in [KEY_W, KEY_A, KEY_S, KEY_D]):
			return
		_keys[k.keycode] = k.pressed
		if has_focus() or _hover_left or _hover_right:
			set_input_as_handled()
		return
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		var which := _view_at(mb.position)
		if which == 0:
			_on_view_input(mb)
			set_input_as_handled()
		elif which == 1:
			_on_split_view_input(mb)
			set_input_as_handled()
	elif ev is InputEventMouseMotion:
		var mm := ev as InputEventMouseMotion
		var w := _view_at(mm.position)
		if w == 0:
			_on_view_input(mm)
		elif w == 1:
			_on_split_view_input(mm)


## 鼠标位置在哪个预览里：0=左，1=右，-1=都不是。
## **优先**用 mouse_entered/mouse_exited 记录的悬停状态：那是 Godot 自己做的命中判断，
## 不受容器尺寸/包围盒差异影响，比手算矩形可靠得多（右侧曾经因为矩形判断一直被判成左侧）。
func _view_at(pos: Vector2) -> int:
	if _hover_right and not _hover_left:
		return 1
	if _hover_left and not _hover_right:
		return 0
	if _vp_box != null and _vp_box.is_visible_in_tree() and _vp_box.get_global_rect().has_point(pos):
		return 0
	if _split_box != null and _split_box.is_visible_in_tree() and _split_box.get_global_rect().has_point(pos):
		return 1
	return -1


func _on_left_enter() -> void:
	_hover_left = true
	_hover_right = false          # 互斥：避免两个都算"悬停"
	_wasd_view = 0


func _on_left_exit() -> void:
	_hover_left = false


func _on_right_enter() -> void:
	_hover_right = true
	_hover_left = false
	_wasd_view = 1


func _on_right_exit() -> void:
	_hover_right = false


## WASD：移动"看的中心点"（target），前后沿视线水平方向、左右为屏幕右方向。
## 窗口没有焦点时不动，免得抢编辑器的按键。
func _handle_wasd(delta: float) -> void:
	# 窗口有焦点、或鼠标就停在某个预览上 -> 才响应（否则别抢编辑器的按键）
	if not has_focus() and not (_hover_left or _hover_right):
		return
	var d := Vector2.ZERO
	if bool(_keys.get(KEY_W, false)):
		d.y -= 1.0
	if bool(_keys.get(KEY_S, false)):
		d.y += 1.0
	if bool(_keys.get(KEY_A, false)):
		d.x -= 1.0
	if bool(_keys.get(KEY_D, false)):
		d.x += 1.0
	if d == Vector2.ZERO:
		return
	d = d.normalized()
	if _wasd_view == 0:
		var fwd := Vector3(-sin(_yaw), 0.0, -cos(_yaw))
		var right_v := Vector3(cos(_yaw), 0.0, -sin(_yaw))
		var step := _dist * MOVE_SPEED_RATIO * delta
		_target += fwd * (-d.y) * step
		_target += right_v * d.x * step
	else:
		var fwd2 := Vector3(-sin(_syaw), 0.0, -cos(_syaw))
		var right2 := Vector3(cos(_syaw), 0.0, -sin(_syaw))
		var step2 := _sdist * MOVE_SPEED_RATIO * delta
		_starget += fwd2 * (-d.y) * step2
		_starget += right2 * d.x * step2


func _on_view_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_dist = maxf(0.05, _dist * 0.9)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_dist = minf(1000.0, _dist * 1.1)
		elif mb.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
			_dragging = mb.pressed
			_drag_btn = mb.button_index
			_last_mouse = mb.position
	elif ev is InputEventMouseMotion and _dragging:
		var mm := ev as InputEventMouseMotion
		var d := mm.position - _last_mouse
		_last_mouse = mm.position
		if _drag_btn == MOUSE_BUTTON_LEFT:
			_yaw -= d.x * 0.01
			_pitch = clampf(_pitch + d.y * 0.01, -1.5, 1.5)
		else:
			var right := Vector3(cos(_yaw), 0.0, -sin(_yaw))
			var up := Vector3(0.0, 1.0, 0.0)
			_target -= right * d.x * _dist * 0.002
			_target += up * d.y * _dist * 0.002


# ------------------------------------------------------------------ 左侧 白膜/贴图

func _on_tex_toggled(on: bool) -> void:
	_apply_left_materials(on)


## 左侧预览的材质：on=true 用回链贴图的材质，false 用原始（白膜）
## **逐面**处理：像 geometry_nodes 那种网格有 2 个材质槽（面0 是 Poly Haven 的预览球材质
## grass_bermuda_01_sphere，面1 才是草），整体 override 一个材质会按面0的名字去找贴图 ->
## 找不到 -> 白球。所以用 surface_override_material 逐面来。
func _apply_left_materials(on: bool) -> void:
	for m in _meshes:
		var mi := m as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		mi.material_override = null
		if not _orig_mesh.has(mi):
			_orig_mesh[mi] = mi.mesh          # 记下原网格，切回白膜时还原
			# 同时记到节点元数据上：导出时要按**原网格**的材质回链贴图。
			# 否则导出会读到预览的内存材质（没有 resource_name/贴图路径）-> 导出成灰模型。
			mi.set_meta("blend_orig_mesh", mi.mesh)
		if on:
			if not _relinked.has(mi):
				# 复制一份网格，在副本上**逐面**设材质（surface_set_material 是本会话反复验证过的 API）
				var dup: Mesh = (mi.mesh as Mesh).duplicate(true)
				for s in range(dup.get_surface_count()):
					dup.surface_set_material(s, _preview_material(mi, s))
				_relinked[mi] = dup
			mi.mesh = _relinked[mi]
		else:
			mi.mesh = _orig_mesh[mi]


# ------------------------------------------------------------------ 自动拆分

func _on_autosplit() -> void:
	if _meshes.is_empty():
		_split_status.text = "没有可分析的网格"
		return
	var albedo := _find_albedo()
	if albedo == "":
		_split_status.text = "找不到贴图（无法分析图集）"
		return
	_cuts = BlendAutoSplit.analyze(_meshes, albedo)
	_split_tree.clear()
	var troot := _split_tree.create_item()
	var empty_count := 0
	var used_meshes: Array = []
	for c in _cuts:
		var d: Dictionary = c
		var it := _split_tree.create_item(troot)
		var rc: Rect2 = d["rect"]
		it.set_text(0, "块%02d  (x %.2f-%.2f, y %.2f-%.2f)" % [
				int(d["index"]), rc.position.x, rc.end.x, rc.position.y, rc.end.y])
		if bool(d["empty"]):
			empty_count += 1
			it.set_text(1, "模型为空")
			it.set_custom_color(1, Color(1.0, 0.55, 0.35))
		else:
			it.set_text(1, "%s (%d 三角)" % [String(d["name"]), int(d["tris"])])
			used_meshes.append(d["mesh"])
	# 右边 3D：把配到模型的素材块**并排摆一行**显示（带贴图）
	for ch in _split_holder.get_children():
		ch.queue_free()
	var x := 0.0
	for m in used_meshes:
		var src := m as MeshInstance3D
		if src == null or src.mesh == null:
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = src.mesh
		mi.material_override = _preview_material(src)
		mi.position = Vector3(x, 0.0, 0.0)
		_split_holder.add_child(mi)
		x += maxf(0.25, src.mesh.get_aabb().size.x * 1.6)
	_frame_split()
	_split_status.text = "自动拆分：%d 个素材块 ｜ 有模型 %d ｜ 模型为空 %d" % [
			_cuts.size(), _cuts.size() - empty_count, empty_count]


## 预览用材质：按名字回链项目里的贴图（**只在内存里**，不落盘）
func _preview_material(src: MeshInstance3D, surface: int = 0) -> Material:
	var dir := ""
	if src.has_meta("blend_src"):
		dir = String(src.get_meta("blend_src"))
	var base := ""
	var om: Material = null
	if src.mesh != null and surface < src.mesh.get_surface_count():
		om = src.mesh.surface_get_material(surface)
	if om != null:
		base = String(om.resource_name)
	if base.is_empty():
		base = _base_name()
	var diff := BlendExport._find_tex(dir, base, ["diff", "albedo", "col"])
	var nor := BlendExport._find_tex(dir, base, ["nor", "normal"])
	var rough := BlendExport._find_tex(dir, base, ["rough"])
	var alpha_p := BlendExport._find_tex(dir, base, ["alpha", "mask"])
	if alpha_p != "":
		var sh: Shader = load(BlendExport.SHADER_PATH)
		if sh != null:
			var sm := ShaderMaterial.new()
			sm.shader = sh
			sm.set_shader_parameter("albedo_tex", BlendExport._load_tex(diff))
			sm.set_shader_parameter("alpha_tex", BlendExport._load_tex(alpha_p))
			sm.set_shader_parameter("normal_tex", BlendExport._load_tex(nor))
			sm.set_shader_parameter("rough_tex", BlendExport._load_tex(rough))
			sm.set_shader_parameter("has_normal", nor != "")
			sm.set_shader_parameter("alpha_scissor", 0.5)
			return sm
	var st := StandardMaterial3D.new()
	st.albedo_texture = BlendExport._load_tex(diff)
	if nor != "":
		st.normal_enabled = true
		st.normal_texture = BlendExport._load_tex(nor)
	st.roughness = 1.0
	st.metallic = 0.0
	return st


## 找图集：优先用导入材质上已接的，其次按名字在 .blend 旁边找
## .blend 常带分辨率后缀（grass_bermuda_01_4k.blend），而贴图名是 grass_bermuda_01_diff_4k.jpg
## -> 匹配前先把结尾的 _4k/_2k/_1k 去掉
func _base_name() -> String:
	var base := _path.get_file().get_basename()
	for suf in ["_8k", "_4k", "_2k", "_1k"]:
		if base.to_lower().ends_with(String(suf)):
			return base.substr(0, base.length() - String(suf).length())
	return base


func _find_albedo() -> String:
	var dir := _path.get_base_dir()
	var base := _base_name()
	for m in _meshes:
		var mi := m as MeshInstance3D
		if mi == null or mi.mesh == null or mi.mesh.get_surface_count() == 0:
			continue
		var mat := mi.mesh.surface_get_material(0)
		if mat is StandardMaterial3D and (mat as StandardMaterial3D).albedo_texture != null:
			var ap := (mat as StandardMaterial3D).albedo_texture.resource_path
			if not ap.is_empty():
				return ap
	return BlendExport._find_tex(dir, base, ["diff", "albedo", "col"])


func _frame_split() -> void:
	var first := true
	var aabb := AABB()
	for c in _split_holder.get_children():
		var mi := c as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var b := mi.mesh.get_aabb()
		var local := AABB(b.position + mi.position, b.size)
		if first:
			aabb = local
			first = false
		else:
			aabb = aabb.merge(local)
	if first:
		aabb = AABB(Vector3(-0.5, 0.0, -0.5), Vector3(1, 1, 1))
	_starget = aabb.get_center()
	_sdist = maxf(0.5, aabb.size.length() * 1.25)
	_apply_split_orbit()


func _on_split_fit() -> void:
	_frame_split()


## 右侧预览的轨道相机（和左边那套逻辑一样，状态独立）
func _apply_split_orbit() -> void:
	if _split_cam == null:
		return
	var dir := Vector3(
		cos(_spitch) * sin(_syaw),
		sin(_spitch),
		cos(_spitch) * cos(_syaw))
	_split_cam.global_position = _starget + dir * _sdist
	_split_cam.look_at(_starget, Vector3.UP)


func _on_split_view_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton:
		var mb := ev as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_sdist = maxf(0.02, _sdist * 0.9)
		elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_sdist = minf(1000.0, _sdist * 1.1)
		elif mb.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
			_s_dragging = mb.pressed
			_s_drag_btn = mb.button_index
			_s_last_mouse = mb.position
	elif ev is InputEventMouseMotion and _s_dragging:
		var mm := ev as InputEventMouseMotion
		var d := mm.position - _s_last_mouse
		_s_last_mouse = mm.position
		if _s_drag_btn == MOUSE_BUTTON_LEFT:
			_syaw -= d.x * 0.01
			_spitch = clampf(_spitch + d.y * 0.01, -1.5, 1.5)
		else:
			var right_v := Vector3(cos(_syaw), 0.0, -sin(_syaw))
			var up_v := Vector3(0.0, 1.0, 0.0)
			_starget -= right_v * d.x * _sdist * 0.002
			_starget += up_v * d.y * _sdist * 0.002


# ------------------------------------------------------------------ 导出（左右两套，各用各的数据源/状态/忙碌标记）

const FILE_MODE_SAVE_FILE := 0
const FILE_MODE_OPEN_DIR := 2


# -------- 左侧：导出左树里勾选的对象 --------

func _left_nodes() -> Array:
	return _checked_nodes()


## 挑导出材质用的 shader（只筛 *.gdshader）
func _on_pick_shader() -> void:
	var dlg := EditorFileDialog.new()
	dlg.access = EditorFileDialog.ACCESS_RESOURCES
	dlg.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	dlg.title = "选择导出材质用的 shader"
	dlg.add_filter("*.gdshader", "Shader")
	var cur_dir := _shader_path.get_base_dir()
	if not cur_dir.is_empty():
		dlg.current_dir = cur_dir
	dlg.file_selected.connect(_on_shader_chosen)
	add_child(dlg)
	dlg.popup_centered_ratio(0.6)


func _on_shader_chosen(path: String) -> void:
	if path.is_empty():
		return
	_shader_path = path
	if _shader_label != null:
		_shader_label.text = path          # ★ 完整路径
		_shader_label.tooltip_text = path
	_status.text = "导出材质将使用：" + path.replace("res://", "")


func _on_export_single() -> void:
	_ask_export(FILE_MODE_SAVE_FILE, 0)


func _on_export_dir() -> void:
	_ask_export(FILE_MODE_OPEN_DIR, 0)


# -------- 右侧：导出自动拆分出来的模型（跳过"模型为空"）--------

func _split_nodes() -> Array:
	var out: Array = []
	for c in _cuts:
		var d: Dictionary = c
		if bool(d.get("empty", true)):
			continue
		var m = d.get("mesh")
		if m is MeshInstance3D and (m as MeshInstance3D).mesh != null:
			out.append(m)
	return out


func _on_split_export_single() -> void:
	_ask_export(FILE_MODE_SAVE_FILE, 1)


func _on_split_export_dir() -> void:
	_ask_export(FILE_MODE_OPEN_DIR, 1)


# -------- 通用的选择目标 + 导出 --------

func _ask_export(mode: int, view: int) -> void:
	var nodes := _left_nodes() if view == 0 else _split_nodes()
	var status := _status if view == 0 else _split_status
	if nodes.is_empty():
		status.text = "先勾选要导出的对象" if view == 0 else "先点【自动拆分】拿到结果（没有可用模型）"
		return
	var dlg := EditorFileDialog.new()
	dlg.access = EditorFileDialog.ACCESS_RESOURCES
	dlg.file_mode = FileDialog.FILE_MODE_SAVE_FILE if mode == FILE_MODE_SAVE_FILE else FileDialog.FILE_MODE_OPEN_DIR
	if dlg.file_mode == FileDialog.FILE_MODE_SAVE_FILE:
		dlg.title = "导出为单个 .tscn"
		dlg.current_file = _path.get_file().get_basename() + ".tscn"
	else:
		dlg.title = "选择导出到的文件夹（每个对象一个 .tscn）"
	dlg.set_meta("blend_view", view)
	if dlg.file_mode == FileDialog.FILE_MODE_SAVE_FILE:
		dlg.file_selected.connect(_on_target_file)
	else:
		dlg.dir_selected.connect(_on_target_dir)
	add_child(dlg)
	dlg.popup_centered_ratio(0.6)


func _on_target_file(path: String) -> void:
	var dlg := _last_dialog()
	var view := int(dlg.get_meta("blend_view")) if dlg != null and dlg.has_meta("blend_view") else 0
	_run_export(_left_nodes() if view == 0 else _split_nodes(), path, true, view)


func _on_target_dir(dir: String) -> void:
	var dlg := _last_dialog()
	var view := int(dlg.get_meta("blend_view")) if dlg != null and dlg.has_meta("blend_view") else 0
	_run_export(_left_nodes() if view == 0 else _split_nodes(), dir, false, view)


## 取最近创建的对话框（信号回调里拿不到发起者，靠这个读回它带的 view 标记）
func _last_dialog() -> EditorFileDialog:
	for i in range(get_child_count() - 1, -1, -1):
		var c := get_child(i)
		if c is EditorFileDialog:
			return c
	return null


func _run_export(nodes: Array, target: String, single: bool, view: int) -> void:
	var status := _status if view == 0 else _split_status
	var busy := _busy if view == 0 else _split_busy
	if busy:
		return
	if target.is_empty():
		return
	if view == 0:
		_busy = true
	else:
		_split_busy = true
	status.text = "导出中…（%d 个对象）" % nodes.size()
	# 共用选项：两个面板都用顶部栏那一个勾选框
	var chk := _wind_check
	var init_wind := chk == null or chk.button_pressed
	# ★ 减面比例（来自导出区的 SpinBox ✓，通过 self 的 meta 传递 ✓；1.0 = 不降面 ✓）
	# ★ 叶片抽稀（独立于减面 ✓）：直接设到导出脚本的静态变量上 ✓
	BlendExport.leaf_thin = float(get_meta("blend_leaf_thin", 1.0))   # ★ 默认 1.0 = 不抽稀 ✓
	var dec_ratio := float(get_meta("blend_dec_ratio", 1.0))
	# ★ C2 调整（用户要求）：导出**不再自动弹窗** ✓
	#   试看入口已移到预览窗口**左栏** ✓：[试看抽稀] / [试看减面] / [详情…] ✓
	#   想分类表就点左栏「详情…」✓ —— 导出本身恢复"一步到位" ✓
	var r: Dictionary = BlendExport.export_nodes(nodes, target, single, init_wind, _shader_path, dec_ratio)
	if view == 0:
		_busy = false
	else:
		_split_busy = false
	var prefix := "左侧" if view == 0 else "右侧(拆分)"
	status.text = "%s %s" % [prefix, String(r.get("message", ""))]
	if bool(r.get("ok", false)):
		_refresh_filesystem()


## 刷新文件系统（非编辑器环境没有这个方法，必须先判断，否则整个函数会中断）
func _refresh_filesystem() -> void:
	if not Engine.is_editor_hint():
		return
	if not EditorInterface.has_method("get_resource_filesystem"):
		return
	var fs = EditorInterface.get_resource_filesystem()
	if fs != null and fs.has_method("scan"):
		fs.scan()