@tool
extends McpTestSuite
## ============================================================================
## test_fog_brush_field.gd —— 雾气笔刷的**笔刷数学 + 接线**自检
## ============================================================================
## 被测对象：
##   · scripts/fx/fog_brush_field.gd         落笔衰减/描边插值/平滑/存取（纯函数）
##   · addons/fog_brush/fog_brush_plugin.gd  编辑器插件（只做结构 + 接线断言）
##   · addons/fog_brush/ui/fog_brush_dock.gd 面板（同上）
##
## 【为什么插件本体只做结构断言】EditorPlugin 需要编辑接口（EditorInterface）才能跑，
##   在测试里实例化它没有意义。所以这里守两件事：
##     ① 纯笔刷数学（能在测试里跑的那部分）行为正确；
##     ② 插件**确实把关键步骤串起来了**（源码级哨兵：没有 _forward_3d_gui_input 就
##        根本刷不了雾；没有 add_undo_method 就没有撤销）。这类"接线漏了"的 bug
##        在编辑器里表现为"点了没反应"，靠人工点很难回归，只能靠结构断言兜住。
##
## 【覆盖】
##   · 衰减函数：中心=1、边缘=0、半径外=0、单调、硬度影响形状
##   · 落笔：加雾/擦雾/平滑三种模式的方向与钳位（浓度永远留在 0..1）
##   · 描边：从 A 到 B 连续插值（快速拖动不留断点）、半径外不动
##   · 数据：ensure_data 尺寸修复、clear/fill、采样双线性、越界钳边
##   · PNG 往返：to_image/apply_image 保真（8 位量化容差内）
##   · 插件/面板接线哨兵（含"必须有 PNG 落盘 + 撤销 + 视口输入"）
## ============================================================================

const FIELD_SCRIPT := preload("res://scripts/fx/fog_brush_field.gd")
const PLUGIN_PATH := "res://addons/fog_brush/fog_brush_plugin.gd"
const DOCK_PATH := "res://addons/fog_brush/ui/fog_brush_dock.gd"
const FOG_FIELD_PATH := "res://scripts/fx/fog_field.gd"

const MODE_PAINT := 0
const MODE_ERASE := 1
const MODE_SMOOTH := 2


func suite_name() -> String:
	return "fog_brush_field"


func _make_field(size: int = 32) -> FogBrushField:
	var field := FIELD_SCRIPT.new() as FogBrushField
	field.grid_size = Vector2i(size, size)
	field.ensure_data()
	return field


# =========================================================
# ① 衰减函数
# =========================================================

func test_falloff_shape() -> void:
	assert_eq(FIELD_SCRIPT.falloff(0.0, 10.0, 0.5), 1.0, "中心应为满强度")
	assert_eq(FIELD_SCRIPT.falloff(10.0, 10.0, 0.5), 0.0, "半径边界应为 0")
	assert_eq(FIELD_SCRIPT.falloff(50.0, 10.0, 0.5), 0.0, "半径外必须为 0")

	# 单调递减
	var previous := 1.1
	for k in range(1, 11):
		var value: float = FIELD_SCRIPT.falloff(float(k), 10.0, 0.5)
		assert_true(value < previous, "衰减必须随距离单调递减（d=%d 处 %.4f）" % [k, value])
		previous = value

	# 半径为 0 时不能除零、不能给出非零强度
	assert_eq(FIELD_SCRIPT.falloff(0.0, 0.0, 0.5), 0.0, "半径 0 应返回 0 而不是崩溃")


func test_hardness_changes_profile() -> void:
	# 硬边在 80% 半径处应比软边更"满"
	var soft: float = FIELD_SCRIPT.falloff(8.0, 10.0, 0.0)
	var hard: float = FIELD_SCRIPT.falloff(8.0, 10.0, 1.0)
	assert_true(hard > soft, "硬度越高，同样距离处强度越大（soft=%.4f hard=%.4f）" % [soft, hard])


# =========================================================
# ② 落笔
# =========================================================

func test_paint_stamp_center_stronger_than_edge() -> void:
	var field := _make_field(48)
	var changed := FIELD_SCRIPT.apply_stamp(field, Vector2(24.0, 24.0), 10.0, 0.8, 0.5, MODE_PAINT)
	assert_gt(changed, 0, "落笔应当改动若干单元")
	var center := field.sample_uv(Vector2(0.5, 0.5))
	var edge := field.sample_uv(Vector2(0.5 + 8.0 / 48.0, 0.5))
	assert_gt(center, edge, "中心浓度应高于边缘（%.3f vs %.3f）" % [center, edge])
	assert_true(center <= 1.0, "浓度不得越过 1（实际 %.3f）" % center)


func test_paint_clamps_and_is_symmetric() -> void:
	var field := _make_field(48)
	# 反复刷同一处也不能越界
	for _i in range(20):
		FIELD_SCRIPT.apply_stamp(field, Vector2(24.0, 24.0), 8.0, 1.0, 0.5, MODE_PAINT)
	var center := field.sample_uv(Vector2(0.5, 0.5))
	assert_true(center <= 1.0 + 1.0e-5, "反复落笔后浓度必须仍被钳在 1（实际 %.4f）" % center)

	var left := field.sample_uv(Vector2(0.5 - 4.0 / 48.0, 0.5))
	var right := field.sample_uv(Vector2(0.5 + 4.0 / 48.0, 0.5))
	assert_true(absf(left - right) < 0.02, "笔刷应当左右对称（%.4f vs %.4f）" % [left, right])


func test_erase_reduces_density() -> void:
	var field := _make_field(48)
	field.fill(1.0)
	var before := field.sample_uv(Vector2(0.5, 0.5))
	FIELD_SCRIPT.apply_stamp(field, Vector2(24.0, 24.0), 10.0, 0.6, 0.5, MODE_ERASE)
	var after := field.sample_uv(Vector2(0.5, 0.5))
	assert_true(after < before, "擦除后浓度应下降（%.3f -> %.3f）" % [before, after])
	assert_true(after >= 0.0, "擦除不得产生负浓度（实际 %.4f）" % after)


func test_smooth_reduces_gradient() -> void:
	# 造一个硬台阶（左半 1、右半 0）。平滑要做的是"把台阶抹平"：
	#   台阶两侧互相靠近 —— 左侧（原本 1）下降、右侧（原本 0）上升、跨台阶的落差变小。
	# ★ 一开始我把断言写成"台阶处不该升高"，方向是反的：平滑的本质就是让空的一侧被填上。
	var field := _make_field(48)
	for j in range(48):
		for i in range(24):
			field.data[j * 48 + i] = 1.0
	field.mark_texture_dirty()

	var left_uv := Vector2(23.5 / 48.0, 0.5)
	var right_uv := Vector2(24.5 / 48.0, 0.5)
	var left_before := field.sample_uv(left_uv)
	var right_before := field.sample_uv(right_uv)
	var step_before := left_before - right_before

	for _i in range(8):
		FIELD_SCRIPT.apply_stamp(field, Vector2(24.0, 24.0), 8.0, 0.9, 0.5, MODE_SMOOTH)

	var left_after := field.sample_uv(left_uv)
	var right_after := field.sample_uv(right_uv)
	var step_after := left_after - right_after

	assert_gt(step_before, 0.5, "构造的台阶应当很明显（落差 %.3f）" % step_before)
	assert_true(step_after < step_before,
			"平滑后跨台阶的落差必须变小（%.3f -> %.3f）" % [step_before, step_after])
	assert_true(left_after <= left_before + 1.0e-4,
			"原本满浓度的一侧不该升高（%.3f -> %.3f）" % [left_before, left_after])
	assert_gt(right_after, right_before, "原本为空的一侧应被扩散填上（%.3f -> %.3f）" % [right_before, right_after])
	assert_true(left_after <= 1.0 and right_after >= 0.0, "平滑结果必须留在 0..1 内")


func test_stamp_outside_grid_does_nothing() -> void:
	var field := _make_field(32)
	var changed := FIELD_SCRIPT.apply_stamp(field, Vector2(-40.0, -40.0), 4.0, 1.0, 0.5, MODE_PAINT)
	assert_eq(changed, 0, "完全在网格外的落笔不该改动任何单元")
	assert_eq(field.total(), 0.0, "完全在网格外的落笔不该产生浓度")


# =========================================================
# ③ 描边插值
# =========================================================

func test_stroke_interpolates_between_points() -> void:
	var field := _make_field(64)
	# 从 (4,32) 拉到 (60,32)：中途每隔一段都该有雾（否则快速拖动会留下断点）
	FIELD_SCRIPT.apply_stroke(field, Vector2(4.0, 32.0), Vector2(60.0, 32.0), 3.0, 0.6, 0.5, MODE_PAINT, 0.3)
	var holes := 0
	for i in range(4, 61, 4):
		if field.sample_uv(Vector2((float(i) + 0.5) / 64.0, 0.5)) < 0.05:
			holes += 1
	assert_eq(holes, 0, "整条笔画上不该出现空档（空档处数 %d）" % holes)
	assert_gt(field.total(), 0.0, "描边后总浓度应大于 0")


# =========================================================
# ④ 数据管理
# =========================================================

func test_ensure_data_fixes_size() -> void:
	var field := FIELD_SCRIPT.new() as FogBrushField
	field.grid_size = Vector2i(20, 12)
	assert_true(field.data.is_empty(), "新建资源不该有数据")
	field.ensure_data()
	assert_eq(field.data.size(), 20 * 12, "ensure_data 应按 grid_size 建数组")
	assert_eq(field.total(), 0.0, "新数组应全 0")

	# 尺寸变化后重建（旧数据不再匹配 -> 重新分配）
	field.grid_size = Vector2i(8, 8)
	field.ensure_data()
	assert_eq(field.data.size(), 64, "改尺寸后 ensure_data 应重新分配")


func test_clear_and_fill() -> void:
	var field := _make_field(16)
	field.fill(0.75)
	assert_true(absf(field.sample_uv(Vector2(0.5, 0.5)) - 0.75) < 0.02, "填充后应到处是 0.75")
	field.clear()
	assert_eq(field.total(), 0.0, "清空后总浓度应为 0")


func test_sample_uv_clamps_at_edges() -> void:
	var field := _make_field(16)
	field.fill(0.5)
	# 域外采样按 clamp-to-edge，不该越界崩溃
	assert_true(absf(field.sample_uv(Vector2(-5.0, -5.0)) - 0.5) < 0.02, "越界采样应钳到边缘值")
	assert_true(absf(field.sample_uv(Vector2(9.0, 9.0)) - 0.5) < 0.02, "越界采样应钳到边缘值")


func test_png_roundtrip_preserves_density() -> void:
	var field := _make_field(32)
	FIELD_SCRIPT.apply_stamp(field, Vector2(10.0, 10.0), 6.0, 0.8, 0.5, MODE_PAINT)
	var path := "user://fog_brush_test_roundtrip.png"
	assert_eq(field.save_to_png(path), OK, "写 PNG 应成功")

	var loaded := FIELD_SCRIPT.new() as FogBrushField
	assert_true(loaded.load_from_png(path), "读回 PNG 应成功")
	assert_eq(loaded.grid_size, Vector2i(32, 32), "读回的尺寸应一致")
	# 8 位量化：容差 1/255 略放宽
	var original := field.sample_uv(Vector2(10.5 / 32.0, 10.5 / 32.0))
	var restored := loaded.sample_uv(Vector2(10.5 / 32.0, 10.5 / 32.0))
	assert_true(absf(original - restored) < 0.02,
			"PNG 往返后浓度应基本一致（%.4f vs %.4f）" % [original, restored])

	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


# =========================================================
# ⑤ 插件 / 面板接线哨兵
# =========================================================

func test_plugin_is_wired_for_painting() -> void:
	var source := FileAccess.get_file_as_string(PLUGIN_PATH)
	assert_false(source.is_empty(), "读不到 %s" % PLUGIN_PATH)

	# 视口输入：没有它根本刷不了
	assert_contains(source, "_forward_3d_gui_input", "插件必须实现视口输入转发")
	assert_contains(source, "set_input_event_forwarding_always_enabled", "必须开启输入常转发")
	assert_contains(source, "AFTER_GUI_INPUT_STOP", "刷的时候必须吃掉鼠标事件（否则会同时转镜头）")
	# 笔刷数学只能来自字段模块，不能自己再写一份
	assert_contains(source, "BRUSH_FIELD_SCRIPT.apply_stamp(", "落笔必须调用字段模块的纯函数")
	assert_contains(source, "BRUSH_FIELD_SCRIPT.apply_stroke(", "拖动必须做笔画插值")
	# 撤销与落盘
	assert_contains(source, "add_undo_method", "必须把笔画记进撤销栈")
	assert_contains(source, "save_to_png", "落笔结束必须把底图落盘成 PNG")
	# 与运行时的连接点：必须把底图推给 FogField
	assert_contains(source, "refresh_brush_texture", "必须把底图推给 FogField（否则运行时不生效）")


func test_dock_exposes_required_controls() -> void:
	var source := FileAccess.get_file_as_string(DOCK_PATH)
	assert_false(source.is_empty(), "读不到 %s" % DOCK_PATH)

	# 关键参数必须能调
	for token in ["radius_m", "strength", "hardness", "grid_size", "mode"]:
		assert_contains(source, token, "面板必须暴露 %s" % token)
	# 雾气参数（离地高度 / 整体高度等）必须在面板上，且经"参数名"契约透传给 FogField
	for token in ["base_height", "box_height", "fog_opacity", "particle_count",
			"local_scatter_strength", "particle_light_response", "wind_scale",
			"particle_flow_follow", "particle_flow_warp"]:
		assert_contains(source, token, "面板必须暴露雾气参数 %s" % token)
	assert_contains(source, "fog_param_changed", "面板必须用 fog_param_changed 透传参数名")
	assert_contains(source, "sync_fog_params", "面板必须支持从目标回填参数值")
	# 关键操作必须有入口
	for signal_name in ["clear_requested", "fill_requested", "export_requested",
			"import_requested", "rebuild_requested"]:
		assert_contains(source, signal_name, "面板必须提供 %s 入口" % signal_name)
	# 面板必须只发信号、不自己碰雾气场（分层的关键）。
	# ★ 只查"真正的耦合点"（预加载字段脚本 / 调用雾气场方法 / 读写域尺寸），
	#   不查注释里出现的名词 —— 否则一句解释性注释就会让哨兵误报。
	assert_false(source.contains("fog_field.gd"), "面板不该预加载 FogField 脚本（分层要求）")
	assert_false(source.contains("refresh_brush_texture"), "面板不该直接操作雾气场")
	assert_false(source.contains("domain_size"), "面板不该自己算域尺寸（换算归插件）")


func test_fog_field_consumes_brush_field() -> void:
	# 雾气场必须真的把画笔底图喂进求解器，否则"刷了但运行时没有"是必然的
	var source := FileAccess.get_file_as_string(FOG_FIELD_PATH)
	assert_false(source.is_empty(), "读不到 %s" % FOG_FIELD_PATH)
	assert_contains(source, "set_base_density_image", "FogField 必须把底图上传给求解器")
	# ★ "浓度增益"必须是活的：FogField 每帧把它转发给求解器的画笔吸引增益 base_gain。
	#   回归点：density_gain 曾经在 FogField 里声明了却从未被读取（死旋钮）。
	assert_contains(source, "set_base_gain", "浓度增益必须转发给求解器（否则又是死旋钮）")
	assert_contains(source, "brush_field", "FogField 必须持有画笔底图字段")


func test_plugin_registered_in_project_settings() -> void:
	var config := FileAccess.get_file_as_string("res://project.godot")
	assert_contains(config, "res://addons/fog_brush/plugin.cfg",
			"project.godot 必须启用 fog_brush 插件（否则编辑器里根本不会加载）")


# =========================================================
# ⑥ 编辑器路径回归（用户在编辑器里实际踩到的两个报错）
# =========================================================

## 回归用例：`Invalid access to property 'solver'` + `Attempt to call a method on a
## placeholder instance`。
##
## 起因：FogField 原来不是 @tool，于是**编辑器里它只是占位实例**（placeholder
## instance）：脚本成员一概不可访问，插件调 `target.solver` / `target.refresh_brush_texture()`
## 直接报错。修法有两条，缺一不可：
##   ① `scripts/fx/fog_field.gd` 加 @tool（让脚本在编辑器里真的活着）；
##   ② 编辑器里**不建求解器**（不跑 13 个 SubViewport 的 GPU 链），改走"画笔预览"路径；
##      所有公开方法都要容忍 `solver == null`。
## 本用例就在编辑器进程里实例化一个 FogField，直接覆盖这条路径。
func test_fog_field_editor_path_is_safe() -> void:
	var fog_field_script := load(FOG_FIELD_PATH) as GDScript
	assert_true(fog_field_script != null and fog_field_script.can_instantiate(),
			"FogField 脚本必须可实例化")

	assert_true(Engine.is_editor_hint(),
			"本测试应在编辑器进程里运行（否则测的是运行期路径，覆盖不到这个 bug）")

	var field: Node3D = fog_field_script.new() as Node3D
	assert_true(field != null, "FogField 应能实例化")

	# ★ 不能 `add_child(field)`：McpTestSuite 不是 Node（没有 add_child）。
	#   改为**手工走一遍编辑器分支** —— 这正是 @tool 脚本在编辑器里跑的那条路径：
	#   只建体积雾、不建求解器。solver 保持 null 就是插件当初报错的那个状态。
	field.set("_editor_preview", true)
	field.call("_create_volume")
	assert_true(field.get("solver") == null,
			"编辑器路径不该建求解器（solver 必须为 null —— 插件要容忍的正是这个状态）")
	assert_true(field.get("_volume_material") != null,
			"编辑器路径必须建出体积雾材质（画笔预览的载体）")

	# 编辑器预览必须建粒子：否则面板上的风系数/粒子数量/尺寸/强度**没有作用对象**，
	# 拖动滑块看不出任何变化（用户反馈"设置跟不设置没区别"）。
	field.call("_create_particles")
	var particles: GPUParticles3D = field.get("_particles") as GPUParticles3D
	assert_true(particles != null, "编辑器路径必须建出粒子节点（预览才有东西可调）")
	var process_material := particles.process_material as ShaderMaterial
	assert_eq(int(process_material.get_shader_parameter("flow_enabled")), 0,
			"编辑器预览必须关闭流场采样（否则空 sampler 绑成白图，粒子会飞出画面）")

	# ★ 风参数必须**真的改变**着色器里的合成风：这正是"风系数设置没区别"的回归点
	field.set("wind_speed_mps", 4.0)
	field.set("wind_scale", 0.0)
	field.call("_apply_particle_params")
	var calm: Vector2 = process_material.get_shader_parameter("synthetic_wind")
	field.set("wind_scale", 1.0)
	field.call("_apply_particle_params")
	var windy: Vector2 = process_material.get_shader_parameter("synthetic_wind")
	assert_eq(calm.length(), 0.0, "风系数 = 0 时合成风必须为 0（肉眼应看到烟几乎静止）")
	assert_true(windy.length() > 3.0, "风系数 = 1 时合成风应约为风速（实测 %.2f m/s）" % windy.length())
	assert_true(windy.length() > calm.length(), "风系数必须真的改变风（%.2f -> %.2f）"
			% [calm.length(), windy.length()])

	# ★ 用户实测的关键回归点：把风关到 0 后雾仍然飞快抖动 —— 因为粒子被**流场**搬运，
	#   而流场里还有涡量约束/源注入。必须有一个"让粒子彻底无视流场"的开关。
	field.set("particle_flow_scale", 0.0)
	field.call("_apply_particle_params")
	assert_eq(float(process_material.get_shader_parameter("flow_scale")), 0.0,
			"流场强度 = 0 时必须真的把着色器的 flow_scale 归零（粒子无视流场）")
	field.set("particle_flow_scale", 1.0)
	field.call("_apply_particle_params")
	assert_eq(float(process_material.get_shader_parameter("flow_scale")), 1.0,
			"流场强度恢复后 flow_scale 必须跟着回到 1")

	# 粒子数量/尺寸也必须能被面板实时改到（不是只在 _ready 生效一次）
	field.set("particle_count", 1234)
	field.set("particle_size", 7.5)
	field.call("_apply_particle_params")
	assert_eq(particles.amount, 1234, "粒子数量必须跟着属性实时更新")
	var quad := particles.draw_pass_1 as QuadMesh
	assert_true(absf(quad.size.x - 7.5) < 0.01, "粒子尺寸必须跟着属性实时更新")

	# 插件在编辑器里会调这两个方法：都不能炸，而且要让预览拿到画笔纹理
	var brush := _make_field(24)
	FIELD_SCRIPT.apply_stamp(brush, Vector2(12.0, 12.0), 5.0, 0.9, 0.5, MODE_PAINT)
	field.call("set_brush_field", brush)
	assert_true(field.get("brush_texture") != null,
			"编辑器里 set_brush_field 应生成预览纹理（画笔才看得见）")

	var material: ShaderMaterial = field.get("_volume_material") as ShaderMaterial
	# ★ 回归点：外观类参数必须在**每帧**路径里重传，否则建场之后改属性不生效
	#   （用户实测："亮部/暗部颜色在编辑器里改没有实时预览"）。
	#   这里改属性 → 手动跑一次每帧同步 → 断言材质里的值跟着变。
	field.set("mist_color_lit", Color(0.11, 0.22, 0.33))
	field.set("mist_color_shadow", Color(0.44, 0.55, 0.66))
	field.set("height_power", 2.75)
	field.call("_apply_volume_params")
	var lit: Variant = material.get_shader_parameter("mist_color_lit")
	var shadow: Variant = material.get_shader_parameter("mist_color_shadow")
	assert_true(lit is Color and absf((lit as Color).r - 0.11) < 0.01,
			"亮部颜色必须在每帧同步到材质（实测 %s）" % str(lit))
	assert_true(shadow is Color and absf((shadow as Color).r - 0.44) < 0.01,
			"暗部颜色必须在每帧同步到材质（实测 %s）" % str(shadow))
	assert_true(absf(float(material.get_shader_parameter("height_power")) - 2.75) < 0.01,
			"竖向衰减必须在每帧同步到材质")
	assert_true(material.get_shader_parameter("density_tex") != null,
			"预览材质必须绑上画笔底图")
	assert_gt(float(material.get_shader_parameter("density_gain")), 0.0,
			"有底图时浓度增益应恢复（否则预览永远看不见雾）")

	# 空底图：不能让 sampler 落在默认白图上（会被渲染成一整块实心雾）
	field.call("set_brush_field", null)
	assert_eq(float(material.get_shader_parameter("density_gain")), 0.0,
			"空底图时浓度增益必须归零（否则预览是一块实心雾）")

	# 笔刷"吹风"在编辑器里必须静默跳过（solver 为 null）
	field.call("add_brush_velocity", Vector2(0.5, 0.5), 0.1, Vector2(0.2, 0.0))

	# 其余运行期接口在编辑器里也必须安全（刷新/清空/再推底图）
	field.call("refresh_brush_texture")
	field.call("clear_simulated")
	field.call("set_brush_field", brush)
	assert_true(field.get("solver") == null, "整个过程都不该冒出求解器")
	assert_true(field.get("brush_texture") != null, "再推一次底图后预览纹理仍在")

	field.free()


## 预滤波（D）里"步内闭式平均"的**符号**必须正确 —— 写反会让整个雾不可见。
## 用 p=1 的解析特例钉死：p=1 时 (1−h) 是直线，它在 [h0,h1] 上的平均 = 区间中点处的值。
## 同式抄自 fog_mist_volume.gdshader（那边改了务必同步改这里）。
func test_prefilter_profile_average_sign() -> void:
	var h0 := 0.2
	var h1 := 0.4
	var p1 := 2.0
	var dh := h0 - h1
	var avg := (pow(1.0 - h1, p1) - pow(1.0 - h0, p1)) / (p1 * dh)
	assert_true(avg > 0.0, "步内平均必须为正（实测 %.4f）—— 负号写反会让雾直接不可见" % avg)
	assert_true(absf(avg - 0.7) < 0.0001, "p=1 时区间平均应等于中点值 0.7（实测 %.4f）" % avg)


## 插件源码不得再直接摸求解器（那正是编辑器里报错的写法）。
## ★ 只查**代码行**：注释里当然可以提到 `target.solver`（本次就是被自己的注释误报了一次），
##   所以以 `#` 开头的行直接跳过。
func test_plugin_never_touches_solver_directly() -> void:
	var source := FileAccess.get_file_as_string(PLUGIN_PATH)
	var offenders: Array[String] = []
	for line in source.split("\n"):
		var trimmed := line.strip_edges()
		if trimmed.begins_with("#") or trimmed.is_empty():
			continue
		if trimmed.contains("target.solver") or trimmed.contains(".solver.add_splat"):
			offenders.append(trimmed)
	assert_eq(offenders.size(), 0,
			"插件不该直接访问求解器（编辑器里会报 Invalid access），应走 FogField.add_brush_velocity()：%s"
			% str(offenders))
