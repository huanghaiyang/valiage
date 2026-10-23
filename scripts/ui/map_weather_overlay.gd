extends PanelContainer
## 地图上的「天气 / 风向」信息块 —— 小地图与大地图共用，**行列对齐**。
##
## 【布局】两列网格（GridContainer, columns=2），左列文字、右列图标：
##     天气 | [太阳/云/雨/雷/风]
##     风向 | [风向标]
##   用 GridContainer 而不是自绘，就是为了"行列对齐"：行高、列宽由容器算，
##   换字体/换尺寸都不会错位。图标统一尺寸，文字统一字号。
##
## 【风向的屏幕角度】
##   沿用 LandmarkOverlay 的"北向标记"约定（minimap.gd _place_north）：
##     screen = R(yaw) · (x, z)，  R(yaw) = [[cos, -sin], [sin, cos]]
##   验证：世界"北" = (0, -1) -> screen = (sin yaw, -cos yaw)，与北向标记逐字一致。
##
## 【尺寸】compact = 小地图用（图标 18 / 字号 10），否则大地图用（图标 28 / 字号 14）。
##   图标刻意做小：贴在地图角上是"信息"，不该抢地图的视觉。

# ======================================================================
# 文件职责 / 所属系统
# ======================================================================
# · 本文件是**纯展示**控件：把「当前天气 + 风向风力」画成一个 2 行 × 2 列的信息块，
#   小地图与大地图共用同一个类，靠 compact 开关切换大小。
# · 所属系统：UI 地图叠加层（挂在 minimap.gd 这个 CanvasLayer 之下）。
# · 它自己**不读天气、不推进时间、不发信号、不写文件**：所有数据都由外部定时调用
#   update_weather() 推入，控件只负责画。
#
# 【关键依赖】
# · 调用方 scripts/ui/minimap.gd 用 preload 拿到本脚本，new() 出两个实例：
#     weather_overlay —— 小地图右上角（compact = true），随小地图一起旋转（传 cam_yaw）；
#     big_weather     —— 大地图右上角（compact = false），正北朝上（传 0.0）。
#   刷新被节流到 MAP_UPDATE_INTERVAL（约 15Hz），数据由调用方从场景里的天气节点
#   （main.tscn 的 "Weather"，分组 weather_system）读出后推入：current / wind_dir / wind。
# · **不依赖任何 autoload**：本文件里没有对天气节点的直接访问，中文天气名自带一份
#   （常量 KIND_NAMES），因此脱离天气系统也能单独实例化 —— 自检脚本正是这样跑的。
# · **不依赖任何资源文件**：没有 .tscn / .tres / 贴图 / 字体，UI 全部在 _init 里用代码搭出来。
# · 相关自检：tools/verify_minimap_weather.gd（校验角度换算、天气名、图标分支、网格列数）；
#   解析检查：tools/check_parse.gd 的清单里包含本文件。
#
# 【主要对外接口】
# · update_weather(k, dir, power, yaw, kind_name := "", icon_kind := -1) -> void
#   —— 唯一的数据入口，后两个可选参数用于自定义天气的名称与图标。
# · weather_label() -> String —— 当前天气的中文名（自定义天气用调用方给的 kind_name；
#   内置编号越界时返回"未知"）。
# · vane_angle() -> float —— 风向在屏幕上的弧度角（0 = 屏幕右，PI/2 = 屏幕下）。
# · apply_size() -> void —— 按 compact 重算图标边长、字号、描边粗细与行列间距。
# · 属性：kind / wind_dir / wind_power / map_yaw / compact，外部可直接读写，含义见各自注释。
# · 内部类 WeatherIcon / WindVane 只为本文件服务，但 new() 时**必须传入外层控件引用**。
#
# 【已知的坑与注意事项】
# 1. compact 只在 _build() 里被 apply_size() 消费一次。构造之后再改 compact，必须**手动
#    再调一次 apply_size()** 才会真正换尺寸。当前 minimap.gd 对大地图实例只改了 compact
#    而没有补调，所以那个实例实际仍是紧凑尺寸（这是本文件之外的现状，注释只记录不改代码）。
#    注意例外：风向标的"尾羽"是每帧现读 compact / wind_power 的，所以它会跟着变。
# 2. 内部类访问外层状态用的是动态写法（panel.kind / panel.call(...)），因为成员 panel 的
#    静态类型是 PanelContainer，静态检查看不到外层脚本的成员；改成静态类型反而编译不过。
# 3. 坐标约定：wind_dir 是**世界**空间的 (x, z)，不是屏幕坐标；map_yaw 是弧度。
#    小地图必须传相机 yaw（minimap.gd 里由相机 iso_yaw_deg 转弧度而来），大地图传 0；
#    正负号写反的表现是"地图转了但风向标不跟着转/反向转"。
# 4. 全链路 mouse_filter = IGNORE：本控件覆盖在地图之上，绝不能让鼠标事件被它吃掉，
#    否则会挡住小地图/大地图的点击与拖拽。
# 5. 所有文字都带黑色描边：叠加层压在浅色地形上时，没有描边几乎看不清字。
#
# ==================== 常量：天气种类（数值 = Weather.Kind） ====================
# 这组数值**必须与 weather.gd 的 Kind 一一对应**（0..5 是内置天气，自定义从 6 开始）：
# 0 晴 / 1 多云 / 2 阴 / 3 雨 / 4 雷雨 / 5 大风。错位不会报错，只会"图标画的是雨、
# 文字写的是晴"，非常难查；改天气枚举时这两个文件必须一起改。
## 0 = CLEAR 晴朗（画一轮带 8 道光芒的太阳）
## Weather.Kind：CLEAR, CLOUDY, OVERCAST, RAIN, STORM, WINDY
const KIND_CLEAR := 0
## 1 = CLOUDY 多云（左上露出太阳，右下压一朵云）
const KIND_CLOUDY := 1
## 2 = OVERCAST 阴天（上层亮云 + 下层暗云，两层叠出"压下来"的观感）
const KIND_OVERCAST := 2
## 3 = RAIN 下雨（暗云 + 三道斜向雨丝）
const KIND_RAIN := 3
## 4 = STORM 雷雨（暗云 + 黄色闪电多边形，闪电是手写的 7 点折线）
const KIND_STORM := 4
## 5 = WINDY 大风（三道长短不一的风线 + 末端小卷）
const KIND_WINDY := 5

## 与 Weather.KIND_NAMES 一致（自带一份，不依赖自动加载也能画）
# 索引即天气编号（0..5），**顺序不能重排**：weather_label() 直接按索引取名字。
# 做成定长数组而不是字典，是为了能在无 autoload 的环境里独立实例化并自检。
const KIND_NAMES := ["晴朗", "多云", "阴天", "下雨", "雷雨", "大风"]

# ==================== 常量：图标边长与字号（单位：像素 / pt） ====================
# 图标一律按正方形画（_draw 里取 minf(size.x, size.y) 当边长），所以这两个尺寸值
# 同时决定 custom_minimum_size（参与布局）与绘制半径（决定观感），改一处两处一起变。
## 紧凑版图标边长 18px：小地图角上的地盘只有约 96×38，图标刻意做小，不抢地图的视觉
const ICON_SMALL := 18
## 大地图版图标边长 28px：大地图面积大、观看距离远，用 18px 会看不清；再往上调会开始压住地图内容
const ICON_BIG := 28
## 紧凑版字号 10：与 18px 图标同一量级，两行文本加上行距正好塞进小地图角上的高度框
const FONT_SMALL := 10
## 大地图字号 14：与 28px 图标成比例；字号变大时 apply_size() 会把描边加粗，否则笔画会糊在一起
const FONT_BIG := 14


# ==================== 对外状态（由调用方写入 / 本控件读取） ====================
## 当前天气编号。内置 0..5，自定义天气从 6 开始（由 weather.gd 给出名称与图标种类）。
## 默认 0 = 晴朗：构造完成但 update_weather() 还没被调用时先按晴天画，避免出现空白框。
## 注意：update_weather() 只夹紧下界（负值 -> 0），上界不再夹到 5 —— 否则自定义天气会被
##   当成大风显示。图标 match 用 icon_kind（0..5），文字用 kind_name（可为空则查内置表）。
var kind := KIND_CLEAR
## ★ 本项目改动：调用方给出的天气中文名（自定义天气用）。空串 = 按内置 KIND_NAMES 查表。
var kind_name := ""
## ★ 本项目改动：图标种类（0..5）。-1 = 直接用 kind（内置天气的默认行为）。
var icon_kind := -1
## 世界风向 (x, z)：x 对应世界 +X、z 对应世界 +Z，**不是屏幕坐标**。
## 只取方向、长度不参与运算，所以传单位向量即可。
## 默认 (1, 0) 表示东风（吹向 +X），与 Weather.wind_dir 的默认值保持一致。
## 注意：零向量会被 update_weather() 兜底成 (1, 0)，因为 atan2(0, 0) 的角度不稳定，
## 会让风向标在无风时乱指；外部绕过 setter 直接赋零向量同样要注意这一点。
var wind_dir := Vector2(1.0, 0.0)      ## 世界风向 (x, z)
## 风力大小，直接取自 Weather.wind（weather.gd 的天气参数表里约为 0.18..1.10，上限约 1.5）。
## 本文件只在两处消费它：① 决定风向标尾羽是否出现（> 0.01 才画）；
## ② 决定尾羽长度（以 0.6 作为"满格"参考值归一化，≥ 0.6 之后不再变长）。
## 默认 0.0 表示"无风"，此时不画尾羽；改小它只会让尾羽更早出现、更长。
var wind_power := 0.0                  ## 风力（Weather.wind）
## 地图的旋转角，单位**弧度**（不是角度），由调用方决定：
## · 小地图传 cam_yaw（minimap.gd 里等于 deg_to_rad(camera_rig.iso_yaw_deg)），因为它随相机转；
## · 大地图传 0.0，因为大地图恒为正北朝上。
## 默认 0.0 表示"地图未旋转"，此时风向标直接按世界风向绘制。
## 它只参与 vane_angle() 的换算式，不参与天气图标的绘制。
var map_yaw := 0.0                     ## 地图旋转角（小地图传 cam_yaw；大地图传 0）
## 是否为紧凑版（小地图用）。默认 true，与"先创建小地图实例"的调用顺序一致。
## 影响范围：图标边长 18 vs 28、字号 10 vs 14、描边粗细、网格行列间距，
## 以及风向标尾羽是否绘制（尾羽只在非紧凑版画，且每帧现读这个值）。
## ⚠ 它只在 _build() 里被 apply_size() 读取一次：构造之后再改这个值，必须**再手动调用一次
##   apply_size()** 才会真正换尺寸，否则只有依赖它的实时读取项（尾羽）会变。
##   细节与现状见文件头"已知的坑与注意事项"第 1 条。
var compact := true

# ==================== 内部节点引用（全部在 _build() 里创建） ====================
# 下面这几个成员在 _build() 返回之后必然非 null；update_weather() 里仍然逐个判空，
# 是为了让"尚未构建完成 / 引用已失效时被调用"不至于直接崩（防御式写法，不要当成冗余删掉）。
## 两列网格容器：左列文字、右列图标。行列对齐完全靠它，不要换成手写绝对定位
var _grid: GridContainer
## 左列第一行文字：天气名（内容由 update_weather() 刷新）
var _lbl_kind: Label
## 左列第二行文字：固定显示"风向"（update_weather() 会把它赋成同一个字符串，幂等操作）
var _lbl_vane: Label
## 右列第一行：天气图标（内部类 WeatherIcon，自绘，无贴图）
var _icon: Control
## 右列第二行：风向标（内部类 WindVane，自绘，无贴图）
var _vane: Control


# ==================== 构造与布局 ====================
# 本控件没有 .tscn：所有子节点都在 _init() 里同步搭好。所以 new() 一返回就可以
# add_child / 调 update_weather()，不需要等 _ready()，也不存在"半成品"状态。
## 构造函数：设置鼠标穿透，并一次性搭好整个 UI（底面板 + 两行两列网格）。
## 参数：无。返回值：无。
## 副作用：给自身 add_theme_stylebox_override("panel", ...)；向自身 add_child 一个
##   GridContainer 及其 4 个子控件（2 个 Label + 2 个自绘 Control）。
## 时机：调用方执行 new() 时立即执行，此时节点**尚未进入场景树**。
## 注意：_init 阶段不要访问 get_tree() / 父节点 / autoload 的运行时状态（都还不成立）；
##   需要那些东西的初始化应放到 _ready() 或由外部驱动。
## 注意：new() 返回之后外部才能设置属性，所以 _build() 里那次 apply_size() 用的必然是
##   默认的 compact = true（紧凑尺寸）；调用方若改成大地图尺寸，必须补调一次 apply_size()。
func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_build()


## 搭建整套 UI：底面板样式 + 两列网格 + 两行内容（天气行 / 风向行）。
## 参数：无。返回值：无。
## 副作用：写本节点的 "panel" 主题覆盖；创建 _grid / _lbl_kind / _icon / _lbl_vane / _vane
##   并挂到网格下；函数末尾调用一次 apply_size() 落定尺寸。
## 时机：只由 _init() 调用一次。**不要**在运行中重复调用 —— 会重复 add_child，
##   出现两套叠加显示的 UI（而且 _grid 等引用会被后一套覆盖，前一套再也管不到）。
## 注意：子节点的加入顺序就是网格顺序：先 _lbl_kind 再 _icon（第一行），
##   再 _lbl_vane 再 _vane（第二行）；改动顺序会直接改变行列布局。
func _build() -> void:
	# 底面板用代码现做一个 StyleBoxFlat，而不是外挂 .tres：本控件要求"零资源依赖"，
	# 这样才能在无资源的 headless 环境里被自检脚本直接实例化。
	# 半透明深绿底 + 土金描边是刻意的地图配色：信息块要"看得见但不抢眼"。
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.12, 0.10, 0.72)
	sb.border_color = Color(0.72, 0.62, 0.38, 0.85)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	sb.content_margin_left = 6.0
	sb.content_margin_right = 6.0
	sb.content_margin_top = 4.0
	sb.content_margin_bottom = 4.0
	add_theme_stylebox_override("panel", sb)

	# 用 GridContainer 而不是手写 position/offset：行高列宽由容器算，换字号、改图标尺寸、
	# 换字体都不会错位 —— 这正是"行列对齐"的实现方式，也是自检脚本要断言 columns == 2 的原因。
	_grid = GridContainer.new()
	_grid.name = "WeatherGrid"
	_grid.columns = 2                    # ★ 两列：左文字、右图标 -> 行列自然对齐
	_grid.add_theme_constant_override("h_separation", 6)
	_grid.add_theme_constant_override("v_separation", 2)
	add_child(_grid)

	_lbl_kind = _make_label("天气")
	_grid.add_child(_lbl_kind)
	# 把 self 传进去：图标不自己存一份状态，而是每次重绘时回读外层的 kind，
	# 这样永远只有一份"当前天气"，不会出现两边不同步。传引用的必要性见内部类注释。
	_icon = WeatherIcon.new(self)
	_grid.add_child(_icon)

	_lbl_vane = _make_label("风向")
	_grid.add_child(_lbl_vane)
	# 同理传 self：风向标靠这个引用调用外层的 vane_angle() 取当前屏幕角（动态调用）。
	_vane = WindVane.new(self)
	_grid.add_child(_vane)

	# 放在最后统一刷新：此刻 4 个子节点都已就位，一次把两个 Label 的字号/描边和两个图标的
	# 边长全部落定。外部改 compact 之后也必须再调一次这个函数（本控件唯一需要手动重跑的地方）。
	apply_size()


## 造一个左列用的文字 Label（统一右对齐、垂直居中、鼠标穿透）。
## 参数 t：Label 的初始文本。本文件传的是两个固定标题"天气" / "风向"：
##   其中 _lbl_vane 之后一直保持"风向"；_lbl_kind 的文本会被 update_weather() 换成天气名。
## 返回值：新建的 Label（**尚未**加入场景树，由 _build() 负责 add_child 到网格里）。
## 副作用：无（只创建对象并设属性，不改本节点状态、不发信号）。
## 注意：右对齐是必须的 —— 左列文字要靠向右侧的图标列，居中/左对齐会让"文字 | 图标"
##   的视觉轴线散开；鼠标穿透也不可省，否则 Label 会截获地图上的鼠标事件。
func _make_label(t: String) -> Label:
	var l := Label.new()
	l.text = t
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	# 右对齐：让两行文字都紧贴右侧的图标列，形成"文字 | 图标"的整齐竖线；
	# 若改成居中，两行文字宽度不同时会左右错开，看起来像没对齐。
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


# ==================== 尺寸应用 ====================
## compact 决定图标尺寸与字号（小地图紧凑、大地图放大）
## 按当前 compact 值重算整套尺寸：图标边长、字号、文字描边粗细、网格行列间距。
## 参数：无（直接读成员 compact）。返回值：无。
## 副作用：写两个 Label 的 font_size / font_color / font_outline_color / outline_size 覆盖；
##   写两个图标的 custom_minimum_size 与 size；写 _grid 的 h_separation / v_separation；
##   对两个图标各 queue_redraw() 一次（自绘内容依赖尺寸，必须重画）。
## 时机：_build() 末尾调一次；外部修改 compact 之后**必须手动再调一次**才生效。
## 注意：只有本函数会改尺寸，update_weather() 不会 —— 数据刷新与尺寸刷新是两条独立路径，
##   别指望刷天气会顺带把大小修正过来。
func apply_size() -> void:
	var px := ICON_SMALL if compact else ICON_BIG
	var fs := FONT_SMALL if compact else FONT_BIG
	for l in [_lbl_kind, _lbl_vane]:
		l.add_theme_font_size_override("font_size", fs)
		l.add_theme_color_override("font_color", Color(0.96, 0.96, 0.94, 0.96))
		l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
		# 描边粗细跟字号一起放大：紧凑版固定 2px，大地图 2 + 2 = 4px；
		# 不这么做的话字变大而描边不变宽，压在浅色地图上会糊成一团。
		l.add_theme_constant_override("outline_size", 2 + (0 if compact else 2))
	for c in [_icon, _vane]:
		# 两个尺寸都要写：custom_minimum_size 交给 GridContainer 参与布局（决定格子最小边长），
		# size 用于本帧立即生效 —— 否则 _draw 里读到的 size 还是旧值，会先按旧尺寸画一帧再跳变。
		c.custom_minimum_size = Vector2(px, px)
		c.size = Vector2(px, px)
		c.queue_redraw()
	# 行列间距也随版本变：紧凑版收紧（4 / 1），大地图放宽（8 / 3），
	# 否则放大后的图标会彼此贴住、文字与图标挤在一起。
	_grid.add_theme_constant_override("h_separation", 4 if compact else 8)
	_grid.add_theme_constant_override("v_separation", 1 if compact else 3)


# ==================== 数据刷新与查询 ====================
## 唯一的数据入口：把外部的天气/风状态推进控件并立即刷新显示。
## 参数 k：天气编号，期望 0..5（对应 Weather.Kind）；越界会被夹紧到 0..5。
## 参数 dir：世界风向 (x, z)，只取方向、长度不参与运算；零向量会被兜底成 (1, 0)。
## 参数 power：风力大小（Weather.wind），只用于风向标尾羽长度，可以传 0 表示无风。
## 参数 yaw：地图旋转角（弧度）。小地图传相机 yaw，大地图传 0。
## 返回值：无。
## 副作用：写 kind / wind_dir / wind_power / map_yaw 四个成员；改左列文字内容；
##   对天气图标与风向标各 queue_redraw() 一次。**不发信号、不写文件、不改场景树结构**。
## 时机：由 minimap.gd 的 _process 节流后调用（约 15Hz），小地图/大地图两个实例各自调用；
##   构造完成到首次调用之间，控件按默认值（晴朗 + 东风）显示。
## 注意：这里只刷新"数据 + 重绘"，不重建节点也不改主题，所以开销很小；
##   但也**不会**重新应用尺寸 —— compact 变了仍需单独调用 apply_size()。
## 参数 kind_name_override：天气中文名（自定义天气由 weather.gd 提供）；空串 = 查内置表。
## 参数 icon_kind_override：图标种类 0..5；-1 = 直接用 kind（内置天气的默认行为）。
func update_weather(k: int, dir: Vector2, power: float, yaw: float,
		kind_name_override := "", icon_kind_override := -1) -> void:
	# 只夹下界：内置 0..5 不变，自定义编号（>= 6）要原样保留，
	# 名称与图标分别由 kind_name_override / icon_kind_override 决定，不再依赖 0..5 的定长表。
	kind = maxi(k, 0)
	kind_name = kind_name_override
	icon_kind = icon_kind_override
	# 零向量兜底：Weather 未绑定时 wind_dir 可能是 (0, 0)，那时 atan2(0, 0) 的角度不稳定，
	# 风向标会平白指向屏幕右侧。阈值 0.0001 是向量**长度**（不是长度平方），
	# 远小于任何合法风速，只用来识别这种退化输入。
	wind_dir = dir if dir.length() > 0.0001 else Vector2(1.0, 0.0)
	wind_power = power
	map_yaw = yaw
	# 下面四处判空是防御式的：_build() 之后这些成员必然存在，但本函数可能被外部在极早期
	# 调用、或对象正在被释放；判空后最坏情况只是"这一帧没刷新"，不会崩。
	if _lbl_kind != null:
		# 用 weather_label() 而不是在这里直接查表：它自带越界兜底（返回"未知"），
		# 也保证"文字"与"图标 match 分支"用的是同一套编号解释，不会各说各话。
		_lbl_kind.text = weather_label()
	if _lbl_vane != null:
		# 第二行标题恒为"风向"（风的方向是用箭头画的，不是文字），这里重复赋同一个字符串，
		# 是为了让"刷新一次就两行文字都对齐状态"这条不变量成立，代价可忽略。
		_lbl_vane.text = "风向"
	if _icon != null:
		# Control 不是每帧自动重绘：自绘内容依赖的数据变了必须显式标脏，
		# 否则要等其它原因触发重绘才会更新（表现就是图标/箭头"卡住"不动）。
		_icon.queue_redraw()
	if _vane != null:
		# 风向标同理：风向、风力或地图朝向变了都要重画（它读 wind_dir / map_yaw / wind_power / compact）。
		_vane.queue_redraw()


## 当前天气的中文名
## 当前天气的中文名。
## 参数：无（读成员 kind）。返回值：对应的中文名；kind 越界时返回"未知"。
## 副作用：无 —— 纯查询，不发信号、不改状态、不碰节点。
## 调用时机：update_weather() 每次刷新文字时调用；外部 UI 想复用同一套中文名也可以调。
## 注意：kind 在 update_weather() 里已经夹紧过一次，这里再判一次范围是双保险，
##   因为 kind 是公开成员，外部可以绕过 update_weather() 直接赋值。
func weather_label() -> String:
	if not kind_name.is_empty():
		return kind_name
	# 双保险：kind 可能被外部直接赋成越界值，这里用"未知"兜底，避免数组索引越界。
	return KIND_NAMES[kind] if kind >= 0 and kind < KIND_NAMES.size() else "未知"


## 风向在**屏幕**上的角度（弧度）：0 = 屏幕右，PI/2 = 屏幕下
## 风向在**屏幕**上的弧度角：0 = 屏幕右，PI/2 = 屏幕下（与 Godot 里 y 轴向下的约定一致）。
## 参数：无（读成员 wind_dir 与 map_yaw）。返回值：弧度角，范围 -PI..PI。
## 副作用：无 —— 纯计算。但内部类 WindVane 每次 _draw 都会调用它。
## 调用时机：主要给风向标绘制用；headless 自检脚本也直接调它来断言角度换算。
## 实现：先把世界风向 (x, z) 按 map_yaw 旋转到屏幕系，再取 atan2；
##   角度在**数据层**算好而不是用绘图变换，好处是它成了纯函数，不进渲染也能被验证。
## 注意：必须与 minimap.gd 的 LandmarkOverlay._place_north() 保持同一约定 ——
##   世界正北 (0, -1) 在这个旋转下应得到 (sin yaw, -cos yaw)，与北向标记逐字一致。
func vane_angle() -> float:
	# 旋转矩阵 R(yaw) = [[cos, -sin], [sin, cos]]，把它作用在世界 (x, z) 上就是下面两行。
	# 先把 cos / sin 取出来复用，省掉四次重复的三角函数调用（本函数每帧被调用）。
	var c := cos(map_yaw)
	var s := sin(map_yaw)
	# 屏幕 x 分量 = cos·世界x - sin·世界z（世界 z 增大是"往屏幕下方"，见 vane_angle 文档）
	var sx := c * wind_dir.x - s * wind_dir.y
	var sy := s * wind_dir.x + c * wind_dir.y
	# 参数顺序是 atan2(y, x)，写反会让箭头整体偏转 90°；这里 sy 在前、sx 在后。
	return atan2(sy, sx)


# ======================================================================
# 天气图标（自绘，不依赖贴图资源）
# ======================================================================
## 天气图标：按外层的 kind 自绘 6 种图形，**不使用任何贴图/图标资源**。
## 为什么自绘：本控件要求"零资源依赖"（headless 自检也能跑，且不会因缺图标资源而空白），
##   同时 18px / 28px 两个尺寸下矢量绘制比缩放贴图清晰。
## 注意：它不是通用控件，只为 MapWeatherOverlay 服务；new() 时**必须**传入外层引用。
class WeatherIcon extends Control:
	## 外层 MapWeatherOverlay 的引用。类型只能写成基类 PanelContainer（内部类无法直接引用
	## 外层脚本类型），所以下面访问 panel.kind 等成员都是动态的 —— 这是必要的写法，别"修正"。
	var panel: PanelContainer

	## 构造函数。参数 p：外层控件（本文件在 _build() 里传 self）。
	## 副作用：保存引用；设置鼠标穿透。
	## 注意：必须传参 —— 没有无参构造可用（否则下面读 panel.kind 会直接空指针崩）。
	func _init(p: PanelContainer) -> void:
		panel = p
		# 自绘控件也是 Control，不清空 mouse_filter 就会截获地图上的点击/拖拽。
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	## Godot 的即时模式绘制回调：需要重绘时由引擎调用，**不要手动调用**（要重绘请用 queue_redraw）。
	## 参数：无（读本控件的 size 与外层 panel.kind）。返回值：无。
	## 副作用：只向本控件的绘制指令列表写图形，不改任何成员、不碰场景树。
	## 时机：首次显示、尺寸变化、以及外部 queue_redraw() 之后的那一帧（update_weather() 每次都会标脏）。
	## 注意：所有坐标都按 size 的比例算，所以 18px 与 28px 共用同一段代码；
	##   另外 _draw 里绝对不能 add_child / 改状态，否则会引发重绘风暴。
	func _draw() -> void:
		# 取 minf 而不是直接 size.x：控件被布局拉成非正方形时也要保证图形不被裁切。
		# s 是"基本单元长度"，后面所有偏移与半径都是它的倍数，所以缩放图标只需改 r。
		var r := minf(size.x, size.y)
		var c := size * 0.5
		var s := r * 0.26
		var sun := Color(1.0, 0.86, 0.35, 1.0)
		var cloud := Color(0.88, 0.92, 0.96, 1.0)
		var dark := Color(0.58, 0.63, 0.69, 1.0)
		var rain := Color(0.55, 0.75, 1.0, 1.0)
		# int() + 动态属性 panel.kind：panel 的静态类型是 PanelContainer，静态检查看不到外层
		# 的 kind，所以只能动态读；外面套 int() 是为了让 match 的键值类型稳定（避免 float 混入）。
		# ★ 自定义天气（kind >= 6）由 icon_kind 指定一个 0..5 的内置图标，避免落到兜底分支。
		var draw_kind := int(panel.icon_kind) if int(panel.icon_kind) >= 0 else int(panel.kind)
		match int(draw_kind):
			KIND_CLEAR:
				draw_circle(c, s, sun)
				# 八等分画光芒：角度 a 从 0 均匀铺满一圈，(cos, sin) 得到单位方向 d，
				# 再从 1.35s 画到 1.75s —— 留出 0.35s 的空隙，光芒才不会糊在太阳圆面上。
				for i in range(8):
					var a := TAU * float(i) / 8.0
					var d := Vector2(cos(a), sin(a))
					# 线宽随图标尺寸缩放，但用 maxf 兜底到 1px：不足 1 像素的线在抗锯齿下会淡到看不见。
					draw_line(c + d * s * 1.35, c + d * s * 1.75, sun, maxf(1.0, r * 0.06))
			# 先画太阳、后画云：云是后画的，自然遮住太阳一角，形成"多云"的观感。
			# 顺序反过来（先云后太阳）太阳会整个盖在云上，看起来就成晴天了。
			KIND_CLOUDY:
				draw_circle(c + Vector2(-s * 0.65, -s * 0.6), s * 0.6, sun)
				_cloud(c + Vector2(s * 0.15, s * 0.15), s * 0.9, cloud, r)
			# 两层云：先画上面偏亮的云，再画下面偏暗的云。后画的暗云压住亮云的下缘，
			# 于是有了"厚云压顶"的层次；两层中心偏移不同，所以不会完全重合。
			KIND_OVERCAST:
				_cloud(c + Vector2(0.0, -s * 0.15), s * 1.0, cloud, r)
				_cloud(c + Vector2(0.0, s * 0.55), s * 0.95, dark, r)
			KIND_RAIN:
				_cloud(c + Vector2(0.0, -s * 0.35), s, dark, r)
				# 三道雨丝按 (i-1)*0.6s 均匀排在云下，整体再左偏 0.15s 画出斜度，
				# 这样看起来像被风吹斜的雨，而不是三根垂直的竖线。
				for i in range(3):
					var x := c.x + (float(i) - 1.0) * s * 0.6
					draw_line(Vector2(x, c.y + s * 0.5), Vector2(x - s * 0.15, c.y + s * 1.1),
							rain, maxf(1.0, r * 0.055))
			KIND_STORM:
				_cloud(c + Vector2(0.0, -s * 0.4), s, dark, r)
				# 闪电是手写的 7 点折线多边形（不是三角形扇形），先画云再画它，
				# 让它从云的下缘"劈"出来；点数顺序就是轮廓顺序，改动时要保持不自交。
				draw_colored_polygon(PackedVector2Array([
					c + Vector2(s * 0.12, s * 0.42), c + Vector2(-s * 0.35, s * 0.42),
					c + Vector2(-s * 0.02, s * 0.80), c + Vector2(-s * 0.28, s * 0.80),
					c + Vector2(s * 0.30, s * 1.45), c + Vector2(s * 0.06, s * 0.86),
					c + Vector2(s * 0.34, s * 0.86),
				]), Color(1.0, 0.90, 0.40, 1.0))
			KIND_WINDY:
				for i in range(3):
					# 左端长度 w = s*(0.85 + 0.22i) 随 i 递增，右端只画到 0.65w ——
					# 故意不对称、长短不一才像"风"；右端再补一小段圆弧当卷曲，避免三条死板的横杠。
					var y := c.y + (float(i) - 1.0) * s * 0.62
					var w := s * (0.85 + 0.22 * float(i))
					draw_line(Vector2(c.x - w, y), Vector2(c.x + w * 0.65, y),
							Color(0.86, 0.93, 1.0, 0.96), maxf(1.0, r * 0.055))
					draw_arc(Vector2(c.x + w * 0.65, y - s * 0.2), s * 0.2,
							PI * 0.5, PI * 1.5, 8, Color(0.86, 0.93, 1.0, 0.96),
							maxf(1.0, r * 0.055))
			# 兜底分支：kind 万一不是 0..5（例如外部绕过 update_weather() 直接赋了越界值），
			# 也画个太阳而不是什么都不画 —— 至少能看出"这里有控件"，不会误以为 UI 挂了。
			_:
				draw_circle(c, s, sun)

	## 画一朵"三个圆 + 一个矩形"拼出来的云（不依赖任何贴图）。
	## 参数 c：云的中心（本控件局部坐标，调用处传入的是已加过偏移的位置）。
	## 参数 s：云的基本尺寸（约等于云的半宽，调用处传 r*0.9、s 这类值）。
	## 参数 col：填充色（亮云画浅灰白，暗云画深灰，同一段代码复用两种云）。
	## 参数 r：整个图标的边长。注意：当前函数体里**并没有用到**它，几何完全由 c 与 s 决定
	##   （推测是为将来按图标尺寸调整线宽/描边预留的形参，删掉也可以编译）。
	## 返回值：无。副作用：只往绘制指令列表写图形。
	## 为什么这么拼：三个大小不等的圆做出蓬松的上沿，最后用矩形补齐平整的云底 ——
	##   这是"零资源"约束下最省事又足够像云的画法。
	func _cloud(c: Vector2, s: float, col: Color, r: float) -> void:
		draw_circle(c + Vector2(-s * 0.5, s * 0.10), s * 0.40, col)
		draw_circle(c + Vector2(0.0, -s * 0.18), s * 0.52, col)
		draw_circle(c + Vector2(s * 0.5, s * 0.12), s * 0.38, col)
		# 最后补一条长方形把云底压平：这一步必须在三个圆之后，
		# 否则圆的下缘会把矩形盖住，整朵云就退化成三个球。
		draw_rect(Rect2(c + Vector2(-s * 0.88, s * 0.06), Vector2(s * 1.8, s * 0.40)), col, true)


# ======================================================================
# 风向标（自绘）：箭头指向"风**吹向**的方向"
# ======================================================================
## 风向标：自绘一个圆盘 + 一根箭头，箭头指向"风**吹向**"的方向（下游方向，不是来向）。
## 角度完全由外层的 vane_angle() 给出，本类不做任何坐标换算，只负责画。
## 注意：非紧凑版会按风力额外画一条尾羽（风越大越长）；紧凑版不画，因为 18px 里塞不下。
class WindVane extends Control:
	## 外层 MapWeatherOverlay 的引用（静态类型只能写成基类 PanelContainer，故访问是动态的）。
	var panel: PanelContainer

	## 构造函数。参数 p：外层控件（本文件在 _build() 里传 self）。
	## 副作用：保存引用；设置鼠标穿透。
	## 注意：必须传参，本类没有可用的无参构造。
	func _init(p: PanelContainer) -> void:
		panel = p
		# 与天气图标同理：叠加层绝不能截获地图上的鼠标事件。
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	## 即时模式绘制回调：需要重绘时由引擎调用，**不要手动调用**（要重绘请用 queue_redraw）。
	## 参数：无（读 size、外层的 vane_angle()、compact 与 wind_power）。返回值：无。
	## 副作用：只写绘制指令，不改成员状态、不碰场景树。
	## 时机：首次显示、尺寸变化，以及 update_weather() 里 queue_redraw() 之后的那一帧。
	## 注意：箭头方向来自外层算好的屏幕角；尾羽只在非紧凑版画且每帧现读 compact，
	##   所以小地图/大地图两个实例在这一项上的表现天然不同。
	func _draw() -> void:
		var r := minf(size.x, size.y)
		var c := size * 0.5
		var vr := r * 0.36
		# 外圈圆只当"罗盘盘面"的参照，用半透明浅色，不能抢箭头的视觉。
		# vr = 0.36r 是刻意留出余量：箭头要画到 1.05vr，盘面太大会顶到图标边缘被裁。
		draw_arc(c, vr, 0.0, TAU, 20, Color(0.85, 0.85, 0.8, 0.5), maxf(1.0, r * 0.05))
		# 必须用 call()：panel 的静态类型是 PanelContainer，它没有 vane_angle 这个方法，
		# 直接写 panel.vane_angle() 编译不过。float() 再把 Variant 结果收成 float 供三角函数用。
		var ang := float(panel.call("vane_angle"))
		var d := Vector2(cos(ang), sin(ang))
		var col := Color(1.0, 0.92, 0.55, 0.98)
		draw_line(c - d * vr * 0.45, c + d * vr * 0.95, col, maxf(1.0, r * 0.11))
		# 箭头三角形的尺寸随图标缩放，但兜底不小于 1.5px —— 紧凑版 18px 下
		# 若不做这个下限，箭头会缩成一个看不出方向的点。
		var head := maxf(1.5, r * 0.22)
		draw_colored_polygon(PackedVector2Array([
			c + d * vr * 1.05,
			c + d * vr * 1.05 - Vector2(cos(ang - 0.55), sin(ang - 0.55)) * head,
			c + d * vr * 1.05 - Vector2(cos(ang + 0.55), sin(ang + 0.55)) * head,
		]), col)
		# 风力：非紧凑版加尾羽（越强越长）
		# 两个条件缺一不可：紧凑版不画（18px 里尾羽会和箭头糊成一团）；风力近似 0 也不画
		# （否则无风时仍挂一条尾羽，看起来像坏了）。bool()/float() 转换同样源于动态读取。
		if not bool(panel.compact) and float(panel.wind_power) > 0.01:
			# 以 0.6 为"满格"参考值做归一化：Weather 里大风约 0.95、雷雨约 1.10，都会到满格，
			# 因此强风之间的尾羽看起来一样长。想让更强风继续变长，就调大这个除数。
			var p := clampf(float(panel.wind_power) / 0.6, 0.0, 1.0)
			var t0 := c - d * vr * (0.25 + 0.55 * p)
			var t1 := c - d * vr * (0.05 + 0.2 * p)
			# 尾羽画在箭头的**反向**（-d）一侧：箭头表示"吹向"，尾羽留作"从哪来"的参照。
			# t0/t1 都含 p 项，所以风越大尾羽越长、离箭杆起点越远。
			draw_line(t0, t1, Color(0.75, 0.85, 1.0, 0.85), maxf(1.0, r * 0.07))
