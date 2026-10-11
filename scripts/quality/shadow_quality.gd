extends Node
## 【画质分级 · 阴影】按档位调整平行光的**阴影绘制距离**。
##
## 为什么用"阴影距离"这个旋钮：
##   `directional_shadow_max_distance` 决定**多远的物体要进阴影贴图**。
##   距离越小 → 阴影 pass 需要渲染的物体越少 → GPU 省一大截 ✓
##   （同族杠杆的实测参考：隐藏 Terrain3D → fps 28→39，+39% ✓）
##
## 与项目现有分级的关系：
##   `QualityTiers` 的预设里**本来就有 `shadow_quality` 字段（0~3）**，
##   但之前**没有任何脚本读它** ✗ —— 本脚本把它接上 ✓：
##     0 低 → 40m ｜ 1 中 → 70m ｜ 2 高 → 110m ｜ 3 极高 → 160m
##   只改**距离**，不动阴影贴图分辨率/位深（避免画质突变与额外风险 ✗）。
##   想更激进/更保守：改下面的 `distances` ✓。
##
## ———————————————— 本文件职责 / 运行方式 / 依赖 ————————————————
## 职责：把「画质档位」翻译成**平行光的阴影绘制距离**，在运行时逐个写进
##   `DirectionalLight3D.directional_shadow_max_distance`。
## 所属系统：画质分级（scripts/quality/ 一组脚本 + QualityTiers 数据表 + Quality autoload）。
## 关键依赖（全部做了空判断：缺一个只是降级，不会崩）：
##   · autoload `Quality`（project.godot 第 70 行 → scripts/quality/quality_manager.gd）
##       读它的 `tier: int`（0=低 1=中 2=高 3=极高，默认 HIGH=2）；
##       订阅它的信号 `tier_changed(tier: int)`；
##   · 全局类 `QualityTiers`（scripts/quality/quality_tiers.gd 的 class_name，**不是** autoload），
##       只调用它的纯函数 `tier_name()` 取中文档位名。
## 装配方式：main.gd 里 `preload("res://scripts/quality/shadow_quality.gd").new()` 后 add_child，
##   且**实例化了两次**（ShadowQualityEarly / ShadowQuality）→ 两次 apply 是**幂等**的，
##   重复执行不会叠加效果，代价只是多一趟节点遍历与一行日志。
## 主要对外接口：`apply_current()` / `apply_tier(tier: int)`
##   → Dictionary {tier, tier_name, distance, lights}（字段含义见各函数注释）。
## 已知的坑与注意事项：
##   · 只扫 `get_tree().current_scene` 这一棵子树 —— 平行光若挂在 autoload、独立
##     CanvasLayer 或别的 World3D 上，本脚本**扫不到**，会被静默漏掉；
##   · 只动 `directional_shadow_max_distance` 一个属性，**不碰**阴影贴图分辨率 / 位深 /
##     级联数（有意保守：避免画质突变与额外风险）；
##   · 本脚本**不写文件、不改 .tscn/.tres**，改的全是运行时内存属性 ✓；
##   · `distances` 若被清成空数组，`apply_tier` 里的下标会算成 -1 并越界（推测）。
# ==================== 档位参数：阴影绘制距离 ====================
## 四档阴影绘制距离；**下标 = 档位号**（0 低 / 1 中 / 2 高 / 3 极高），与 QualityTiers.Tier 对齐。
## 单位：米（Godot 世界单位，1 单位 ≈ 1m）。
## 40 / 70 / 110 / 160 是"够用但不刺眼"的保守取值：
##   · 调小（例如 20 / 35 / 55 / 80）→ 进阴影贴图的物体更少 → GPU 的阴影 pass 更省，
##     但远处阴影会在画面里"突然消失/抖动"（阴影边界随相机移动被裁切）；
##   · 调大（例如 80 / 140 / 220 / 320）→ 远处阴影完整，但同样分辨率下每米采样更少
##     → 近处阴影变糊、边缘锯齿更明显，且阴影 pass 的 draw call 上升。
## 长度约束：至少要 ≥ 档位数；档位超出数组长度时 `clampi` 会夹到最后一档
##   （不会崩，但会出现"多档同值"）。想整体更激进/更保守，只改这个数组即可 ✓。
@export var distances: PackedFloat32Array = PackedFloat32Array([40.0, 70.0, 110.0, 160.0])
## 编辑器里不动手（切档若改到场景资源引用，保存后档位会被"烤"进场景 ✗ —— 与地表贴图一致）


# ==================== 生命周期与信号接线 ====================
## 节点就绪回调：订阅画质档位信号，并立刻把**当前**档位应用一次。
## 参数：无。
## 返回：无。
## 触发时机：main.gd 里 `add_child()` 之后同一帧内执行；越早越好 ——
##   这样在首帧渲染前就改好距离，避免"先按场景里的旧值渲染一帧再被改掉"的闪烁。
## 副作用：连接 `/root/Quality` 的 `tier_changed` 信号；遍历当前场景树修改平行光属性；
##   由 apply_* 内部打印一行 `[画质]` 日志。
## 注意事项：编辑器进程里直接返回，不在编辑器内改运行时属性。
func _ready() -> void:
	# 编辑器里不跑：编辑器没有 current_scene（可能为 null），也不该把档位"烤"进场景。
	if Engine.is_editor_hint():
		return
	# 三重保险，缺一个就会出问题：
	#   ① autoload 可能根本没挂（单独跑场景 / 单测）→ 空引用；
	#   ② 信号名可能被改 → connect 直接报错；
	#   ③ 本脚本被实例化两次（main.gd 就是这样）→ 不加 is_connected 会重复回调两遍。
	var qm := get_node_or_null("/root/Quality")
	if qm != null and qm.has_signal("tier_changed") and not qm.tier_changed.is_connected(_on_tier_changed):
		qm.tier_changed.connect(_on_tier_changed)
	# 不等信号：启动就先应用一次，否则要等玩家手动切档才生效（首帧就是错的 ✗）。
	apply_current()


## 档位信号回调：档位一变就重新应用一次阴影距离。
## 参数 `_t`：信号带过来的新档位号；**有意不使用**（下划线前缀就是"故意未使用"的约定）。
##   原因：统一以 autoload 里的 `Quality.tier` 为唯一数据源，避免"信号参数"与"当前值"
##   不一致时用错档位（推测：也为兼容将来信号参数语义的变化）。
## 返回：无。
## 副作用：等价于调用 apply_current() —— 改平行光属性 + 打印日志。
func _on_tier_changed(_t: int) -> void:
	apply_current()


# ==================== 对外应用接口 ====================
## 读取"当前档位"并应用（外部 / 测试 / _ready 都从这里进入）。
## 参数：无。
## 返回：Dictionary —— {"tier": int 实际传入 apply_tier 的档位,
##   "tier_name": String 中文档位名（如"高"）,
##   "distance": float 本次生效的距离（米）,
##   "lights": int 被改到的平行光数量（0 = 场景里没扫到平行光，见 _lights 的注意事项）}。
## 副作用：改场景里平行光的 `directional_shadow_max_distance`；打印一行 `[画质]` 日志。
## 调用时机：节点 _ready 时、以及每次 `tier_changed` 信号。
## 注意事项：拿不到 `/root/Quality`（autoload 未挂）时按"高"(2) 兜底 —— 与
##   QualityManager 的默认档位 Tier.HIGH 保持一致，避免无 autoload 时走最低档画质骤降。
func apply_current() -> Dictionary:
	var tier := 2                       # 默认按"高"
	var qm := get_node_or_null("/root/Quality")
	if qm != null:
		tier = int(qm.tier)
	return apply_tier(tier)


## 按指定档位应用阴影绘制距离（不读 autoload 的入口，便于单测/手动指定档位）。
## 参数 `tier`：档位号 int，约定 0=低 1=中 2=高 3=极高。
##   取值范围：超出 `[0, distances.size()-1]` 会被夹取（越界不崩，但会落到最近的一档）。
## 返回：Dictionary，字段见 apply_current()。注意 `tier` 是**传入的原值**而不是夹取后的
##   `idx`：若真传了越界值，`tier` 会保留越界数、`tier_name` 会变成"未知"（推测：
##   QualityTiers.tier_name 对表外档位返回"未知"），而 `distance` 才是真正生效的距离。
## 副作用：① 写 `DirectionalLight3D.directional_shadow_max_distance`；
##   ② 打印一行 `[画质]` 日志。不写文件、不改场景资源。
## 调用时机：_ready / tier_changed 信号 / 外部手动调用（可重复调用，幂等）。
## 注意事项：只影响**调用这一刻**已经存在于 `get_tree().current_scene` 子树里的平行光；
##   之后动态 add_child 进来的灯不会被自动补上（要等下一次 apply 或切档）。
func apply_tier(tier: int) -> Dictionary:
	# 夹取：tier 来自 user://quality.cfg（可被手改）或外部调用，必须防越界；
	# 同时兜住"档位号比 distances 数组更长"的情况（夹到最后一档，而不是崩 ✗）。
	var idx := clampi(tier, 0, distances.size() - 1)
	# 单位：米；float() 是显式转换（PackedFloat32Array 取出的元素本身就是 float）。
	var d := float(distances[idx])
	# 返回值契约：字段名给日志与排查用，保持稳定、不要随意改名。
	var out := {"tier": tier, "tier_name": QualityTiers.tier_name(tier), "distance": d, "lights": 0}
	# 每次 apply 都重新扫一遍场景树、**不缓存节点列表**：
	# 本脚本可能在世界构建完成之前就被调用（main.gd 就是这么装配的），
	# 缓存会把之后才生成的灯漏掉（推测）。
	for n in _lights(get_tree().current_scene):
		# 只改"阴影绘制距离"这一个属性；同族的阴影贴图分辨率/位深/级联数保持场景原值不动 ✓。
		(n as DirectionalLight3D).directional_shadow_max_distance = d
		# 统计实际改到的灯数：为 0 一般意味着场景里没有 DirectionalLight3D，
		# 或者灯不在 current_scene 这棵子树里（排查档位"没生效"时的第一现场 ✓）。
		out["lights"] = int(out["lights"]) + 1
	# 副作用：控制台日志，用来确认档位到底有没有真的应用上。
	print("[画质] 阴影距离已按「%s」应用：%s" % [out["tier_name"], out])
	return out


# ==================== 内部工具：场景树遍历 ====================
## 深度优先收集 `root` 子树里所有的 `DirectionalLight3D`。
## 参数 `root`：遍历起点，调用方传的是 `get_tree().current_scene`；传 null 时返回空数组。
## 返回：Array，元素类型都是 DirectionalLight3D（调用方因此可以安全地 `as DirectionalLight3D`）。
## 副作用：无 —— 只读遍历，不修改任何节点、不发信号。
## 注意事项：
##   · 用显式数组当栈而不是递归：场景树很深时递归易栈溢出、开销也更大（推测），
##     显式栈没有这个上限；
##   · `pop_back()` 取值 → 实际是"逆序 DFS"，顺序无关紧要（每个灯都被设成同一个距离）；
##   · 不做可见性/隐藏过滤：隐藏的平行光也会被改（对它无害，省一次判断）。
func _lights(root: Node) -> Array:
	# 显式标注 `: Array`：只声明"是数组"，不约束元素类型（元素就是场景树节点）。
	var out: Array = []
	# 兜底：编辑器或切换场景的瞬间 current_scene 可能是 null，直接返回空数组而不是报错。
	if root == null:
		return out
	# 数组尾部当栈：append 入栈、pop_back 出栈 → 免递归的深度优先遍历。
	var st: Array = [root]
	while not st.is_empty():
		# 这里刻意不写 `: Node`：pop_back() 返回 Variant，保持动态类型即可（下面用 is 判断）。
		var n = st.pop_back()
		# 用 `is` 判断而不是 `as`：树上绝大多数节点都不是灯，`is` 一步到位且对任意类型都安全；
		# 用 `as` 虽然也不崩，但还要再判一次 null 才知道有没有转换成功，更啰嗦。
		if n is DirectionalLight3D:
			out.append(n)
		# 子节点全部入栈；访问顺序与业务无关（最终都会遍历到）。
		for c in n.get_children():
			st.append(c)
	return out
