# ==========================================================================================
# minimap.gd —— 小地图 / 大地图（UI 层：左下角常驻小地图 + M 键居中大地图）
# ==========================================================================================
## 【所属系统】UI 层（CanvasLayer）。本脚本挂在 scenes/main.tscn 的 Minimap 节点上，
##   由 main.gd 在 _setup_ui() 里调用 setup(self) 注入主场景引用（main.gd:74 / main.gd:1011）。
##   本文件不依赖任何自动加载即可完成装配；缺依赖时只是少画内容，不会报错。
##
## 【职责】
##   1) 左下角常驻"圆形小地图"：SubViewport + 正交俯视相机，**以玩家为中心的局部视图**
##      （玩家恒在正中、动的是地图内容），上面叠加玩家箭头 / 地标 / 北向 N / 坐标 / 天气风向。
##   2) M 键开关的 600×600 居中"大地图"：一屏装下整张世界的俯视图，正北朝上、不随相机旋转。
##   两套视图彼此独立（各自的 SubViewport / Camera3D / overlay 实例），只在刷新逻辑里共用代码。
##
## 【关键依赖】
##   * main（Node3D，scripts/main.gd 的 Main）
##       - main.player      : Player（scripts/player.gd），本文件只读它的 global_position
##       - main.player.body : 玩家可视根节点（player.gd:81 `var body: Node3D`），读 rotation.y 当朝向
##       - main.camera_rig  : CameraRig，读 @export iso_yaw_deg（场景方位角，单位：度）
##   * /root/Weather（自动加载，scripts/world/weather.gd）
##       - current（天气枚举 Kind，0=CLEAR…5=WINDY）、wind_dir（世界风向 Vector2(x, z)）、wind（风力）
##       - 用 get_node_or_null + get() 弱耦合读取：自动加载缺失时静默跳过天气块，不影响地图本体
##   * scripts/ui/map_weather_overlay.gd（preload 为 MapWeatherOverlay）
##       - 小地图实例 compact=true、大地图实例 compact=false，尺寸由本文件负责摆位
##   * 本文件内嵌类 ArrowOverlay（玩家箭头）、LandmarkOverlay（地标 + 北向），都是自绘 Control
##
## 【主要对外接口】
##   * setup(main_node: Node3D) -> void —— 唯一入口，main.gd 调用一次，之后靠 _process 自驱动
##   * _process(delta) / _unhandled_input(event) —— Godot 回调，不需要外部调用
##   * 常量 MAP_SIZE / MARGIN 被 scripts/ui/vitals_hud.gd 直接引用（MinimapScript.MAP_SIZE），
##     用于把血量 / 魔法等量表贴在小地图右侧 —— 改这两个常量会牵动量表位置，别只改一边
##
## 【已知的坑 / 不变量】
##   * 小地图跟着相机转（cam.rotation.z = +cam_yaw），大地图正北朝上（不转）。
##     符号必须是 +cam_yaw（历史实现写成 -cam_yaw 是反的，推导见 _process 内注释）。
##   * 箭头是**屏幕空间自绘**的：小地图上要传 yaw - cam_yaw 抵消地图旋转，位置传 (0,0) 表示钉在正中。
##   * 中文 Label 每帧赋 text 会触发 TextServer shaping（实测该块 ~2.2ms/帧），
##     故坐标 / 地标 / 天气节流到 MAP_UPDATE_INTERVAL(≈15Hz)，只有箭头保持每帧更新。
##   * 两个 SubViewport 都设 UPDATE_ALWAYS（地图内容持续滚动，必须每帧重渲染），相机都要 make_current()。
##   * 每个俯视相机单独挂一个 Environment 关掉雾 / 体积雾：俯视时视线穿过整片雾体，会糊成白雾。
##   * LANDMARKS 现为空数组（村庄/哨站已随场景清空）：地标层与北向标记仍会创建，但当前不画任何地标点。
extends CanvasLayer
## 左下角小地图（常驻，缩小版）：SubViewport 正交俯视渲染整张地图 + 玩家箭头 + 地标 + 坐标
## 快捷键 M 开启/关闭大地图（大地图居中大窗，小地图保持常驻）

# ==========================================================================================
# 常量与配置
# ==========================================================================================
## 小地图视口边长（像素，正方形）。120 = 原 240 "缩小一半"后的值。
## 它同时是：SubViewportContainer 的尺寸、圆形背景圆角半径的基数（MAP_SIZE * 0.5 → 正圆）、
## 以及地标 / 箭头 overlay 的坐标基准。
## 调大：地形更清楚，但每帧渲染面积按平方增长；调小：省性能，但地形与地标都看不清。
const MAP_SIZE := 120          # 小地图尺寸（缩小一半）
const MAP_BIG_SIZE := 600      # 大地图尺寸
## 世界半尺寸（米）——"世界坐标 → 地图像素"换算的统一分母。
## overlay 里的像素映射一律写作：half + world / WORLD_HALF * half，
## 即约定"地图半宽 = WORLD_HALF 米；世界在 X/Z 上按 ±450m 计"。
## 与 scripts/world/terrain.gd 的 const SIZE := 900.0（地形 box 900×900，即 ±450m）吻合。
## 大地图相机 big_cam.size 也直接取了这个值。
## 调它等于移动地标 / 箭头相对地形的落点，必须与地形实际范围一致，否则标记会整体偏移。
## 注意（推测）：小地图处 cam.size 是按"半径 × 2 = 完整视野宽高"用的（见 cam.size 赋值），
##   而这里是"半宽"口径；两者在 big_cam 上同时出现（size 与映射分母同为 WORLD_HALF），
##   若大地图上玩家箭头与地形对不上，优先怀疑这个口径差异。本次只加注释，未改代码。
const WORLD_HALF := 450.0
## 小地图距屏幕左边缘 / 下边缘的留白（像素）。
## 容器锚点固定 PRESET_BOTTOM_LEFT，故：offset_left = +MARGIN，offset_top = -MAP_SIZE - MARGIN。
## vitals_hud.gd 也用这个值反推量表位置（紧贴小地图右侧），改动要连带确认那边。
const MARGIN := 14.0
## 小地图视野半径（米）：以玩家为中心，屏幕边到中心的实际距离
## 取值理由（36）：既能看清相邻建筑与道路走向，又不至于把地形细节压成一团。
## 调大：看得更远，但地形细节变小、容易看错位置；调小：局部更清楚，但稍远的目标就跑出视野。
@export var minimap_radius := 36.0

## 地图上的"天气 / 风向"信息块脚本（PanelContainer）。preload 成常量：
## 小地图与大地图各 new 一个实例（compact 分别为 true / false，由该脚本决定图标与字号）。
## 用 preload 而非 load，避免运行时首次加载卡顿（该脚本只自绘图形，不依赖额外资源）。
const MapWeatherOverlay := preload("res://scripts/ui/map_weather_overlay.gd")

## 玩家箭头半径相对地图边长的比例：r = min(size.x, size.y) * ARROW_RATIO。
## 0.08 时小地图半径 ≈ 9.6px、大地图半径 ≈ 48px —— 两个尺寸下都清晰，又不至于压住地形中心。
## 调大：箭头明显变大、遮住中心地形（小地图里玩家恒在正中）；调小：小地图上小到难以看清朝向。
const ARROW_RATIO := 0.08      # 玩家箭头半径相对地图尺寸比例（缩小）

## 坐标文本/地标的重绘间隔（秒）。0.066 ≈ 15Hz。
## 每帧给中文 Label 赋文本要 TextServer 重新 shaping，地标 overlay 每帧重绘，
## 实测这块每帧值 ~2.2ms；小地图不需要 60Hz。
const MAP_UPDATE_INTERVAL := 0.066
## 节流计时器（秒，递减到 <= 0 才刷新一次坐标 / 地标 / 天气）。
## 初值 0.0 = 开局第一帧立刻刷新一次，避免角落先显示占位文本"X 0 · Z 0 · 海拔 0.0"。
var _map_timer := 0.0

## 地标：村庄/哨站已随场景清空，这里留空（原来写死三个坐标）
## 元素格式：[名称 String, 世界坐标 Vector2(x, z)] —— LandmarkOverlay.setup_marks 按 m[0] / m[1] 读取，
## 第二分量是**世界 Z**（不是海拔 / 高度）。
## 坑：地标位置在 setup_marks 里一次性算成**静态像素**（按整张世界映射），而小地图是"以玩家为中心滚动"
##   的视图 —— 将来往这里加坐标前，必须先改成"相对玩家"的映射，否则小地图上的地标位置是错的。
const LANDMARKS: Array = []

# ==========================================================================================
# 运行时装配的节点引用（全部由 setup() -> _build_ui() / _build_big_map() 创建并赋值）
# ==========================================================================================
## 主场景根节点（scripts/main.gd 的 Main）。本文件只读它的 player / camera_rig，从不写回。
## 为 null 时 _process 直接 return —— main.tscn 先实例化节点、稍后才调用 setup()。
var main: Node3D
## 小地图渲染视口（SubViewport，MAP_SIZE × MAP_SIZE，透明背景，每帧更新）。
## 由外层的 SubViewportContainer "MinimapView" 承载 —— 容器负责摆位、圆角裁剪与边框。
## 小地图俯视正交相机。每帧只跟随玩家的 XZ（y 恒为 350），于是玩家永远在正中、动的是地图内容。
var viewport: SubViewport
var cam: Camera3D
## 小地图玩家箭头层（自绘 Control，屏幕空间，恒在正中、只转角度）。
## 小地图地标层（自绘圆点 + 名称 Label + 北向 "N"；"N" 随 cam_yaw 绕地图转）。
var arrow: ArrowOverlay
var landmarks: LandmarkOverlay
## 小地图上方的坐标文本（中文 Label，形如 "X 12 · Z -34 · 海拔 3.2"）。
## 赋值代价高（TextServer 需重新 shaping），只在节流后的刷新点写入。
## 小地图右上角的天气块（MapWeatherOverlay 实例，compact = true）。
## 风向标按 cam_yaw 旋转，与地标层的"北"共用同一套屏幕角度约定。
var coord_label: Label
var weather_overlay: Control          ## 小地图右上角：天气图标 + 风向标

# ------------------------------------------------------------------------------------------
# 大地图（M 键开关的 600×600 居中窗口）—— 与上面的小地图成员一一对应
# ------------------------------------------------------------------------------------------
## 大地图根容器（Control，PRESET_CENTER，默认 visible = false）。M 键切换的就是它的 visible；
## 它同时是下面所有 big_* 节点的父节点（一次隐藏整窗）。
## 隐藏时 _process 会跳过大地图的箭头 / 坐标刷新，省掉无谓开销。
var big_root: Control
## 大地图渲染容器（SubViewportContainer，PRESET_FULL_RECT 填满根容器；clip_contents 裁掉圆角外的画面）。
## 大地图渲染视口（SubViewport，MAP_BIG_SIZE × MAP_BIG_SIZE，透明背景，每帧更新）。
## 大地图俯视正交相机：钉在世界原点、**不跟随玩家**，size = WORLD_HALF 一屏装下整张地图；
## 也不随相机 yaw 旋转（正北朝上）——这是与小地图最本质的区别。
var big_view: Control
var big_viewport: SubViewport
var big_cam: Camera3D
## 大地图玩家箭头层。与小地图不同：这里要传**世界坐标**，箭头才能落在图上对应的位置。
## 大地图地标层（圆点 / 字号 / 名称宽度都比小地图大一档）。
## 大地图标题 + 坐标文本（"大地图 · X … · Z … · 海拔 …"），摆在地图窗口正上方。
## 大地图右上角的天气块（MapWeatherOverlay 实例，compact = false 大号）。
## 大地图不旋转，所以 update_weather 的 yaw 传 0，风向标始终按"正北朝上"画。
var big_arrow: ArrowOverlay
var big_landmarks: LandmarkOverlay
var big_coord: Label
var big_weather: Control               ## 大地图右上角：天气图标 + 风向标（大号）

# ==========================================================================================
# 初始化与装配
# ==========================================================================================
## 唯一对外入口：由 main.gd 的 _setup_ui() 调用，注入主场景根节点并一次性建出两套地图 UI。
## 参数 main_node：主场景根（scripts/main.gd 的 Main）；之后 _process 全靠它的 player / camera_rig。
## 返回值：无。
## 副作用：设本 CanvasLayer 的 layer = 2（CanvasLayer 层级，数值越大越靠前绘制）；
##   往自身追加两个地图的全部子节点（SubViewportContainer / SubViewport / Camera3D / overlay / Label），
##   并通过 _build_ui / _build_big_map 调 cam.make_current() 与 big_cam.make_current()，
##   把各自的 3D 渲染切进对应 SubViewport。
## 调用时机：main.tscn 实例化后只调一次；重复调用会叠出第二套 UI，不要再调。
func setup(main_node: Node3D) -> void:
	main = main_node
	layer = 2
	_build_ui()
	_build_big_map()

# ==========================================================================================
# 装配：小地图（左下角常驻，圆形，玩家居中）
# ==========================================================================================
## 建出小地图的全部节点：圆形底 + 金边的渲染容器 → SubViewport → 正交俯视相机 →
## 地标层 / 箭头层 / 天气块 / 坐标文本。
## 参数：无（只读常量 MAP_SIZE、MARGIN）。
## 返回值：无。
## 副作用：向本 CanvasLayer 追加 4 个子节点，并把结果写进成员 viewport / cam / landmarks /
##   arrow / weather_overlay / coord_label（_process 之后全靠它们）。
## 注意：所有位置都用"锚点 + offset"表达，锚点固定 BOTTOM_LEFT / BOTTOM_RIGHT，
##   因此朝屏幕下边缘的 offset 是负数（-MARGIN = 距下边缘 MARGIN 像素）。
func _build_ui() -> void:
	# ---- 渲染容器：圆形小地图 ----
	# 用 SubViewportContainer 而不是裸 SubViewport：容器以"一张贴图"的方式把 3D 渲染结果显示在 UI 里，
	# 并负责裁剪；配合 clip_contents=true 与 MAP_SIZE*0.5 的圆角，才得到圆形小地图。
	var svc := SubViewportContainer.new()
	svc.name = "MinimapView"
	svc.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	svc.offset_left = MARGIN
	svc.offset_top = -MAP_SIZE - MARGIN
	svc.offset_right = MARGIN + MAP_SIZE
	svc.offset_bottom = -MARGIN
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.13, 0.11, 0.78)
	sb.border_color = Color(0.68, 0.58, 0.34, 0.95)
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(int(MAP_SIZE * 0.5))
	svc.add_theme_stylebox_override("panel", sb)
	svc.clip_contents = true
	add_child(svc)

	# ---- 俯视相机（正交，显示整张 900m 地图） ----
	# 说明：上面那句"显示整张 900m 地图"是**旧实现**的遗留描述（那时相机钉在世界原点、size = WORLD_HALF）；
	# 现在小地图是"玩家居中"的局部视图，实际覆盖范围 = minimap_radius * 2（见下面的 cam.size）。
	viewport = SubViewport.new()
	viewport.name = "MinimapViewport"
	viewport.size = Vector2i(MAP_SIZE, MAP_SIZE)
	viewport.transparent_bg = true
	# 必须每帧更新：相机跟着玩家动、地图内容一直在滚；默认的 UPDATE_WHEN_VISIBLE
	# 在这种"内容持续变化"的视图里会滞帧 / 留残影。
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.msaa_3d = Viewport.MSAA_DISABLED
	svc.add_child(viewport)

	cam = Camera3D.new()
	cam.name = "MinimapCamera"
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	# **以玩家为中心的局部视图**：玩家永远在小地图正中，地图内容滚动
	# （原来是 cam.size = WORLD_HALF 一屏装下整个世界、相机钉在世界原点）
	# 正交相机的 size 是视野的**完整**宽 / 高（不是半径），所以这里是"半径 × 2"：直径 72m 的正方形视野。
	cam.size = minimap_radius * 2.0
	cam.position = Vector3(0.0, 350.0, 0.0)
	cam.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	# near/far 要包住"相机 y=350 → 地面"这段距离：far 若小于 350 就会整个画面空白；
	# 620 对最低地形（含坑洼）留了余量，再大没有收益。
	cam.near = 1.0
	cam.far = 620.0
	# 环境覆盖：关闭体积雾（HIGH 画质默认开启，俯视远距离会积成白雾）
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0, 0)
	env.fog_enabled = false
	env.volumetric_fog_enabled = false
	cam.environment = env
	viewport.add_child(cam)
	cam.make_current()

	# ---- 地标与北向叠加层（小图：点/字缩小） ----
	landmarks = LandmarkOverlay.new()
	landmarks.name = "Landmarks"
	landmarks.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	landmarks.offset_left = MARGIN
	landmarks.offset_top = -MAP_SIZE - MARGIN
	landmarks.offset_right = MARGIN + MAP_SIZE
	landmarks.offset_bottom = -MARGIN
	landmarks.dot_r1 = 3.0
	landmarks.dot_r2 = 1.8
	landmarks.font_size = 8
	landmarks.font_n = 9
	landmarks.lbl_w = 56.0
	landmarks.setup_marks(LANDMARKS, MAP_SIZE)
	add_child(landmarks)

	# ---- 玩家箭头叠加层（小图） ----
	arrow = ArrowOverlay.new()
	arrow.name = "PlayerArrow"
	arrow.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	arrow.offset_left = MARGIN
	arrow.offset_top = -MAP_SIZE - MARGIN
	arrow.offset_right = MARGIN + MAP_SIZE
	arrow.offset_bottom = -MARGIN
	add_child(arrow)

	# ---- 天气图标 + 风向标（小地图内右上角） ----
	weather_overlay = MapWeatherOverlay.new()
	weather_overlay.name = "MapWeather"
	weather_overlay.compact = true
	weather_overlay.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	weather_overlay.offset_right = -MARGIN - 6.0
	weather_overlay.offset_top = -MAP_SIZE - MARGIN + 6.0
	weather_overlay.offset_bottom = -MAP_SIZE - MARGIN + 44.0
	weather_overlay.offset_left = weather_overlay.offset_right - 96.0
	add_child(weather_overlay)

	# ---- 坐标显示（小地图上方） ----
	coord_label = Label.new()
	coord_label.name = "Coords"
	coord_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	coord_label.offset_left = MARGIN - 8
	coord_label.offset_right = MARGIN + MAP_SIZE + 8
	coord_label.offset_bottom = -MARGIN - MAP_SIZE - 4
	coord_label.offset_top = coord_label.offset_bottom - 22
	coord_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	coord_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	coord_label.text = "X 0 · Z 0 · 海拔 0.0"
	coord_label.add_theme_font_size_override("font_size", 10)
	coord_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	coord_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	coord_label.add_theme_constant_override("outline_size", 3)
	var csb := StyleBoxFlat.new()
	csb.bg_color = Color(0.08, 0.12, 0.10, 0.62)
	csb.set_corner_radius_all(7)
	coord_label.add_theme_stylebox_override("normal", csb)
	add_child(coord_label)

# ==========================================================================================
# 装配：大地图（居中 600×600 窗口，默认隐藏，M 键开关）
# ==========================================================================================
## 建出大地图的全部节点：根容器（负责整体显隐）→ 渲染容器 → SubViewport → 正交俯视相机 →
## 地标层 / 箭头层 / 天气块（大号）/ 标题坐标文本。
## 参数：无（只读常量 MAP_BIG_SIZE、MARGIN）。
## 返回值：无。
## 副作用：向本 CanvasLayer 追加一个默认隐藏的根节点 big_root，并写成员 big_view / big_viewport /
##   big_cam / big_landmarks / big_arrow / big_weather / big_coord。
## 注意：根容器用 PRESET_CENTER + ±MAP_BIG_SIZE*0.5 的 offset 做居中，子节点再相对它摆位，
##   所以将来要挪动整窗位置，只需改 big_root 的 offset。
func _build_big_map() -> void:
	# ---- 大地图根容器：居中大窗，默认隐藏，M 键开关（控制整体可见性） ----
	big_root = Control.new()
	big_root.name = "BigMapRoot"
	big_root.set_anchors_preset(Control.PRESET_CENTER)
	big_root.offset_left = -MAP_BIG_SIZE * 0.5
	big_root.offset_top = -MAP_BIG_SIZE * 0.5
	big_root.offset_right = MAP_BIG_SIZE * 0.5
	big_root.offset_bottom = MAP_BIG_SIZE * 0.5
	big_root.visible = false
	add_child(big_root)

	# ---- 大地图渲染容器（填满根容器） ----
	big_view = SubViewportContainer.new()
	big_view.name = "BigMapView"
	big_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.09, 0.13, 0.11, 0.82)
	sb.border_color = Color(0.72, 0.62, 0.38, 0.98)
	sb.set_border_width_all(4)
	sb.set_corner_radius_all(14)
	big_view.add_theme_stylebox_override("panel", sb)
	big_view.clip_contents = true
	big_root.add_child(big_view)

	# ---- 大地图俯视相机 ----
	big_viewport = SubViewport.new()
	big_viewport.name = "BigMapViewport"
	big_viewport.size = Vector2i(MAP_BIG_SIZE, MAP_BIG_SIZE)
	big_viewport.transparent_bg = true
	big_viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	big_viewport.msaa_3d = Viewport.MSAA_DISABLED
	big_view.add_child(big_viewport)

	big_cam = Camera3D.new()
	big_cam.name = "BigMapCamera"
	big_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	# 大地图要"一屏装下整张世界"，所以尺寸取 WORLD_HALF（世界 ±450m，见 terrain.gd 的 SIZE = 900.0）。
	# 注意（推测）：正交 size 是完整视野宽高（依据是本文件小地图处"radius × 2"的用法），
	# 而 overlay 的像素映射又除以 WORLD_HALF；两者口径可能不一致，详见文件头 WORLD_HALF 的说明。
	# 本次只加注释，未改动这一行。
	big_cam.size = WORLD_HALF
	big_cam.position = Vector3(0.0, 350.0, 0.0)
	big_cam.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	big_cam.near = 1.0
	big_cam.far = 620.0
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0, 0, 0, 0)
	env.fog_enabled = false
	env.volumetric_fog_enabled = false
	big_cam.environment = env
	big_viewport.add_child(big_cam)
	big_cam.make_current()

	# ---- 大地图地标叠加层 ----
	big_landmarks = LandmarkOverlay.new()
	big_landmarks.name = "BigLandmarks"
	big_landmarks.set_anchors_preset(Control.PRESET_CENTER)
	big_landmarks.offset_left = -MAP_BIG_SIZE * 0.5
	big_landmarks.offset_top = -MAP_BIG_SIZE * 0.5
	big_landmarks.offset_right = MAP_BIG_SIZE * 0.5
	big_landmarks.offset_bottom = MAP_BIG_SIZE * 0.5
	big_landmarks.dot_r1 = 6.0
	big_landmarks.dot_r2 = 3.5
	big_landmarks.font_size = 13
	big_landmarks.font_n = 15
	big_landmarks.lbl_w = 130.0
	big_landmarks.setup_marks(LANDMARKS, MAP_BIG_SIZE)
	big_root.add_child(big_landmarks)

	# ---- 大地图玩家箭头 ----
	big_arrow = ArrowOverlay.new()
	big_arrow.name = "BigPlayerArrow"
	big_arrow.set_anchors_preset(Control.PRESET_CENTER)
	big_arrow.offset_left = -MAP_BIG_SIZE * 0.5
	big_arrow.offset_top = -MAP_BIG_SIZE * 0.5
	big_arrow.offset_right = MAP_BIG_SIZE * 0.5
	big_arrow.offset_bottom = MAP_BIG_SIZE * 0.5
	big_root.add_child(big_arrow)

	# ---- 大地图天气图标 + 风向标（右上角，大号） ----
	big_weather = MapWeatherOverlay.new()
	big_weather.name = "BigMapWeather"
	big_weather.compact = false
	big_weather.set_anchors_preset(Control.PRESET_CENTER)
	big_weather.offset_right = MAP_BIG_SIZE * 0.5 - 14.0
	big_weather.offset_left = big_weather.offset_right - 150.0
	big_weather.offset_top = -MAP_BIG_SIZE * 0.5 + 14.0
	big_weather.offset_bottom = big_weather.offset_top + 76.0
	big_root.add_child(big_weather)

	# ---- 大地图坐标（地图上方） ----
	big_coord = Label.new()
	big_coord.name = "BigCoords"
	big_coord.set_anchors_preset(Control.PRESET_CENTER)
	big_coord.offset_left = -MAP_BIG_SIZE * 0.5
	big_coord.offset_right = MAP_BIG_SIZE * 0.5
	big_coord.offset_bottom = -MAP_BIG_SIZE * 0.5 - 6
	big_coord.offset_top = big_coord.offset_bottom - 28
	big_coord.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	big_coord.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	big_coord.text = "大地图 · X 0 · Z 0"
	big_coord.add_theme_font_size_override("font_size", 15)
	big_coord.add_theme_color_override("font_color", Color(1, 1, 1, 0.98))
	big_coord.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	big_coord.add_theme_constant_override("outline_size", 4)
	var csb := StyleBoxFlat.new()
	csb.bg_color = Color(0.08, 0.12, 0.10, 0.72)
	csb.set_corner_radius_all(10)
	big_coord.add_theme_stylebox_override("normal", csb)
	big_root.add_child(big_coord)

# ==========================================================================================
# 每帧刷新与输入
# ==========================================================================================
## 每帧驱动两张地图：小地图相机跟着相机 yaw 旋转并跟随玩家，玩家箭头每帧更新；
## 坐标 / 地标 / 天气按 MAP_UPDATE_INTERVAL 节流（≈15Hz）。
## 参数 delta：距上一帧的秒数（引擎传入，用于递减节流计时器 _map_timer）。
## 返回值：无。
## 副作用：改小地图相机的 position / rotation，改 arrow / landmarks / 天气块 / 坐标 Label，
##   并可能（大地图可见时）刷新 big_arrow 与 big_coord。不写文件、不发信号。
## 调用时机：引擎每帧调用；早于 _unhandled_input。
## 注意事项：main 或 main.player 尚未就绪时直接 return —— 这是 setup() 之前的空转守卫。
func _process(delta: float) -> void:
	if main == null or main.player == null:
		return
	var p: Vector3 = main.player.global_position
	var yaw := 0.0
	# 玩家朝向取自 body（player.gd 里的可视根节点，模型绕 Y 旋转即朝向）；body 可能尚未就绪，故判空。
	if main.player.body != null:
		yaw = main.player.body.rotation.y
	var cam_yaw := 0.0
	if main.camera_rig != null:
		cam_yaw = deg_to_rad(main.camera_rig.iso_yaw_deg)
	# ---- 小地图跟着相机转（已解除锁定）----
	# 方向修正：原来写的是 `-cam_yaw`，符号反了 —— 表现为"转场景时地图朝反方向转"。
	# 推导（Godot rotation 是 YXZ 序，Z 先作用）：俯视机位 rotation=(-90°,0,θ) 时
	#   屏幕上方 = 相机局部 +Y = (-sinθ, 0, -cosθ)
	#   而相机视线方向 = (-sinθ, 0, -cosθ)   <- 两者相同 ✓
	# 也就是说 θ 取 **正** 号时，"镜头看向的方向"正好朝屏幕上方，这才是正确朝向。
	cam.rotation = Vector3(-PI * 0.5, 0.0, cam_yaw)
	# 相机跟随玩家（保持原高度），于是玩家恒在正中、动的是地图
	cam.position = Vector3(p.x, cam.position.y, p.z)
	# 箭头是屏幕空间自绘的，要抵消地图的旋转 -> 减 cam_yaw（这一项原代码就是对的，别动）
	# 箭头钉在正中（传 0,0）；转的只是地图，玩家不动
	arrow.update_arrow(0.0, 0.0, yaw - cam_yaw)
	# ---- 以下节流到 ~15Hz ----
	# 中文 Label 赋文本要 TextServer 重新 shaping、地标 overlay 每帧重绘，
	# 实测这块每帧值 ~2.2ms；小地图没必要跟满帧率（箭头仍在上面每帧更新）。
	_map_timer -= delta
	if _map_timer > 0.0:
		return
	_map_timer = MAP_UPDATE_INTERVAL
	# 北向标记跟着地图转（大地图是正北，传 0）
	if landmarks != null:
		landmarks.set_map_yaw(cam_yaw)
	coord_label.text = "X %d · Z %d · 海拔 %.1f" % [int(p.x), int(p.z), p.y]
	# ---- 天气图标 + 风向标（小图跟随地图旋转，大地图正北朝上）----
	# 天气是自动加载节点，用 get_node_or_null + get() 弱耦合读取：
	# 拿不到（测试场景 / 自动加载被裁）就整块跳过，不影响地图本体。
	var w := get_node_or_null("/root/Weather")
	if w != null:
		var k: int = int(w.get("current"))
		var dir: Vector2 = w.get("wind_dir") if w.get("wind_dir") is Vector2 else Vector2(1.0, 0.0)
		var power := float(w.get("wind"))
		if weather_overlay != null:
			weather_overlay.update_weather(k, dir, power, cam_yaw)
		if big_weather != null and big_weather.visible:
			big_weather.update_weather(k, dir, power, 0.0)
	# 大地图隐藏时不做任何 big_* 的刷新：省掉一次坐标字符串 shaping 与一次箭头重绘。
	if big_root.visible:
		big_arrow.update_arrow(p.x, p.z, yaw)
		big_coord.text = "大地图 · X %d · Z %d · 海拔 %.1f" % [int(p.x), int(p.z), p.y]

## 按键处理：M 键开 / 关大地图（小地图不受影响，始终常驻）。
## 参数 event：输入事件；只认"按下且不是按键重复(echo)"的键盘事件，避免长按连切。
## 返回值：无。
## 副作用：切换 big_root.visible；命中后调 set_input_as_handled()，防止同一个 M 被其它系统再处理一遍。
## 调用时机：Godot 在常规输入处理链未被消费后调用（所以不会抢走 UI 已经吃掉的按键）。
## 注意：这里不判断输入焦点 / 是否在打字，只要游戏窗口收到 M 就切换；若以后给 M 派别的用途要先在这里拦。
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_M:
			big_root.visible = not big_root.visible
			get_viewport().set_input_as_handled()

# ==========================================================================================
# 内嵌类 1：玩家方向箭头 ArrowOverlay
# ==========================================================================================
## 自绘的玩家朝向箭头（默认朝上，按传入的 yaw 旋转）。
## 它是**屏幕空间**的 Control：不对应任何 3D 物体，只把"玩家在哪、朝哪"折算成像素。
## 两种用法：小地图传位置 (0,0) 让箭头钉在正中（地图在动），大地图传玩家真实世界坐标。
## 玩家方向箭头（自绘）：默认朝上，按玩家 yaw 旋转
class ArrowOverlay extends Control:
	## yaw：箭头朝向（弧度）。由 update_arrow 写入；小地图传 yaw - cam_yaw（已抵消地图旋转）。
	## world_x / world_z：箭头所在**世界坐标**（米）。小地图固定 0,0（玩家恒在正中）；
	##   大地图传玩家真实位置，_draw 里按 /WORLD_HALF 折算成像素。
	var yaw := 0.0
	var world_x := 0.0
	var world_z := 0.0

	## 构造函数：鼠标事件一律忽略 —— 覆盖在地图上的自绘层绝不能截走点击。
	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	## 更新箭头状态并请求重绘（唯一的数据入口，_process 每帧调一次）。
	## 参数 wx / wz：世界坐标（米），小地图传 0,0；参数 y：朝向（弧度，小地图传 yaw - cam_yaw）。
	## 返回值：无。副作用：写 world_x / world_z / yaw，并 queue_redraw()（不立即绘制，下一帧才画）。
	func update_arrow(wx: float, wz: float, y: float) -> void:
		world_x = wx
		world_z = wz
		yaw = y
		queue_redraw()

	## 自绘：一个半透明描边底盘 + 金色三角箭头。
	## 返回值：无。副作用：只往画布写绘制指令（draw_* 在一次绘制结束后由引擎清空）。
	## 注意：这里用的是本 Control 的局部坐标，中心 = size * 0.5。
	func _draw() -> void:
		var half := size.x * 0.5
		# 世界坐标 → 本层像素：以地图中心为原点，按 WORLD_HALF 归一化后乘半宽。
		# 世界 Z 映射到屏幕 Y（俯视图里 +Z 朝屏幕下方），与地标层同一套约定。
		var c := Vector2(half + world_x / WORLD_HALF * half, half + world_z / WORLD_HALF * half)
		var r := minf(size.x, size.y) * ARROW_RATIO
		draw_circle(c, r + r * 0.18, Color(0, 0, 0, 0.5))
		# 三角顶点在局部坐标里朝 -Y（屏幕上方），而 yaw 是绕世界 Y 轴的朝向角；
		# 两个基准不同（-Y 与 +X 差 90°，且屏幕 Y 轴向下），所以先用 atan2(cos, sin) 把朝向
		# 折成屏幕角，再 +PI*0.5 补这个 90° 差。直接写 rot = yaw 会明显偏转。
		var rot := atan2(cos(yaw), sin(yaw)) + PI * 0.5
		draw_set_transform(c, rot, Vector2.ONE)
		var pts := PackedVector2Array([
			Vector2(0.0, -r),
			Vector2(r * 0.62, r * 0.8),
			Vector2(-r * 0.62, r * 0.8),
		])
		draw_colored_polygon(pts, Color(1.0, 0.88, 0.3, 1.0))
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)

# ==========================================================================================
# 内嵌类 2：地标叠加层 LandmarkOverlay
# ==========================================================================================
## 自绘的地标层：圆点标记 + 名称 Label + 动态"北向 N"。
## 大地图与小地图各一个实例，差别只在尺寸参数（dot_r1/dot_r2、font_size/font_n、lbl_w）。
## 坑：地标点是在 setup_marks 里一次性算成**静态像素**的（按整张世界映射）；
##   小地图是"以玩家为中心滚动"的视图，若以后 LANDMARKS 非空，必须先改映射，否则位置是错的。
## 地标叠加层：圆点标记 + 名称（Label）+ 北向
class LandmarkOverlay extends Control:
	## marks：地标数组，元素 [名称 String, 世界坐标 Vector2(x, z)]；setup_marks 时一次性建成 Label。
	## north_lbl：北向 "N" 标签，跟着地图朝向摆放（_place_north）。
	## map_yaw：当前地图旋转角（弧度）。小地图实例由 set_map_yaw(cam_yaw) 更新；
	##   大地图实例从不调用，恒为 0 = 正北朝上。
	## dot_r1 / dot_r2：地标圆点的外圈（深色描边）/ 内圈（金色）半径，像素：小图 3.0 / 1.8、大图 6.0 / 3.5。
	## font_size / font_n：地标名称 / "N" 的字号（像素）；lbl_w：名称 Label 的宽度（像素），用于文字居中。
	var marks: Array = []
	var north_lbl: Label = null
	var map_yaw := 0.0
	var dot_r1 := 4.5
	var dot_r2 := 2.8
	var font_size := 11
	var font_n := 13
	var lbl_w := 90.0

	## 构造函数：忽略鼠标 —— 叠加层不能截走地图上的点击。
	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	## 装配地标：把 list 里的世界坐标折算成像素、为每个地标建一个居中 Label，并建出北向 "N"。
	## 参数 list：元素 [名称 String, 世界坐标 Vector2(x, z)]（本文件里恒为常量 LANDMARKS，当前为空）。
	## 参数 map_size：本叠加层边长（小图 MAP_SIZE / 大图 MAP_BIG_SIZE），坐标与留白都按它算。
	## 返回值：无（结果写进成员 marks / north_lbl）。
	## 副作用：向本 Control 追加若干 Label 子节点；只应调用一次，重复调用会叠出多份。
	## 注意：像素位置是**静态**的（按整张世界映射），与"小地图跟随玩家滚动"不匹配，详见文件头 LANDMARKS 说明。
	func setup_marks(list: Array, map_size: float) -> void:
		marks = list
		for m in marks:
			var wpos: Vector2 = m[1]
			var px := map_size * 0.5 + wpos.x / WORLD_HALF * (map_size * 0.5)
			var py := map_size * 0.5 + wpos.y / WORLD_HALF * (map_size * 0.5)
			var lbl := Label.new()
			lbl.text = m[0]
			lbl.custom_minimum_size = Vector2(lbl_w, 16)
			lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			lbl.add_theme_font_size_override("font_size", font_size)
			lbl.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
			lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
			lbl.add_theme_constant_override("outline_size", 2)
			lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
			lbl.position = Vector2(px - lbl_w * 0.5, py - 20.0)
			add_child(lbl)
		# 北向标记：**跟着地图一起转**（原来固定贴在屏幕顶部，地图一转就不对了）
		# 世界正北 = -Z。地图绕相机 yaw 转 θ 后，北在屏幕上的方向是
		# (sinθ, -cosθ)（相对地图中心的单位向量），所以把它摆到那个角度上。
		north_lbl = Label.new()
		north_lbl.text = "N"
		north_lbl.custom_minimum_size = Vector2(24, 18)
		north_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		north_lbl.add_theme_font_size_override("font_size", font_n)
		north_lbl.add_theme_color_override("font_color", Color(0.95, 0.95, 0.95, 0.95))
		north_lbl.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
		north_lbl.add_theme_constant_override("outline_size", 2)
		north_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		add_child(north_lbl)
		_place_north()

	## 让北向标记落在"当前地图朝向"对应的角度上
	## 参数 y：地图旋转角（弧度）——本文件只有**小地图**那个实例被调用（_process 传 cam_yaw）；
	##   大地图实例从不调用它，保持默认 0 = 正北朝上。
	## 返回值：无。副作用：更新 map_yaw 并立刻重摆 "N"；标签是子 Control，不需要手动重绘本层。
	## 调用时机：_process 的节流刷新点，每 MAP_UPDATE_INTERVAL 秒一次。
	func set_map_yaw(y: float) -> void:
		map_yaw = y
		_place_north()

	## 把 "N" 标签摆到"当前地图朝向下的正北"位置。
	## 参数：无（读成员 map_yaw 与本 Control 的 size）。返回值：无。
	## 副作用：只改 north_lbl.position（子 Control 移动后由 Godot 自行重排 / 重绘），不重绘本层。
	func _place_north() -> void:
		if north_lbl == null:
			return
		# r：把 "N" 摆在地图半径内缩 14px 的圆上（贴边会被圆角裁掉）；
		# 后面 -12 / -9 是 "N" 自身的半个尺寸（custom_minimum_size 24×18），用于把标签中心对准该点。
		var r := size.x * 0.5 - 14.0
		var dir := Vector2(sin(map_yaw), -cos(map_yaw))   # 屏幕上"北"的方向
		north_lbl.position = Vector2(size.x * 0.5 + dir.x * r - 12.0,
				size.y * 0.5 + dir.y * r - 9.0)

	## 自绘地标圆点（外圈深色描边 + 内圈金色）；文字由 setup_marks 建的 Label 负责。
	## 返回值：无。副作用：只写绘制指令。
	## 注意：世界坐标 → 像素的换算必须与 setup_marks 保持一致（两处都用 /WORLD_HALF * half），
	##   改映射口径时要一起改，否则圆点与文字会错位。
	func _draw() -> void:
		var half := size.x * 0.5
		for m in marks:
			var wpos: Vector2 = m[1]
			var p := Vector2(half + wpos.x / WORLD_HALF * half, half + wpos.y / WORLD_HALF * half)
			draw_circle(p, dot_r1, Color(0.12, 0.08, 0.04, 0.8))
			draw_circle(p, dot_r2, Color(0.95, 0.78, 0.32, 0.98))
