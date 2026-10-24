shader_type spatial;
// ★★★ 局部风场（进阶需求）：由 scripts/spells/blue_tornado.gd 每帧广播
global uniform vec3 tornado_pos;
global uniform float tornado_radius;
global uniform float tornado_strength;
global uniform float tornado_swirl;

// ============================================================================
//  ★ 屏幕空间"视觉挖洞"（角色被树挡住时，在角色周围挖一个洞）
//    与 scripts/camera_rig.gd + scripts/shaders/occlusion_hole.gdshader **同一套全局 uniform**：
//      camera_rig 每帧用 RenderingServer.global_shader_parameter_set 广播这 4 个值 ✓
//
//  为什么必须自己做：camera_rig 的挖洞是**替换材质**实现的，
//    而 `_build_hole_materials()` 对 `not (src is StandardMaterial3D)` 直接
//    `out[i] = null` 跳过（自定义 ShaderMaterial 拿不到贴图）✗
//    → 树皮用自定义 shader，**永远拿不到挖洞** ✓ 所以只能在本 shader 里实现。
//
//  ★ 关键：**绝不写 ALPHA**（沿用 occlusion_hole.gdshader 的结论 ✓）
//    写 ALPHA → 材质被判成"有 alpha" → 进透明队列 → 按物体距离排序
//    → 草/花瓣会盖到树干上（"草从树干里透出来"）✗ 这正是之前那个 bug 的根因 ✓
//    这里改用 **Bayer 4x4 抖动 + discard** 出形状：材质仍是不透明队列 ✓ 不会有排序穿透 ✓
// ============================================================================
global uniform vec2 occ_player_uv;      // 角色屏幕 UV（洞中心，取胸口高度）
global uniform float occ_radius;        // 洞半径（UV 单位）
global uniform float occ_softness;      // 洞边缘过渡宽度
global uniform float occ_hole_alpha;    // 洞内"看起来"的不透明度（0=全挖空, 1=不挖）
// ★ 默认值约定（project.godot 的 [shader_globals]）：occ_hole_alpha = 1.0（= 不挖）
//   → 编辑器 / 任何没有 camera_rig 驱动的场景里**不会**出现"固定在屏幕中心的假洞"；
//   运行期由 scripts/camera_rig.gd 每物理帧写真实 uv/半径/透明度（关掉遮挡时会复位成不挖）。

// 4x4 Bayer 抖动矩阵：把"半透明"量化成网格状稀疏像素
// （discard 出形 → 材质保持不透明队列 ✓ 才能继续参与深度/遮挡 ✓）
float bayer4(vec2 p) {
	int x = int(mod(p.x, 4.0));
	int y = int(mod(p.y, 4.0));
	int idx = y * 4 + x;
	float m[16] = float[16](
		0.0,  8.0,  2.0, 10.0,
		12.0, 4.0, 14.0,  6.0,
		3.0, 11.0,  1.0,  9.0,
		15.0, 7.0, 13.0,  5.0);
	return m[idx] / 16.0;
}
// 【树干 / 枝 专用】燃烧但**烧完不消失** ✓ —— 保留焦黑效果 ✓
//
// 与 assets/shaders/burn_foliage.gdshader 的关系：
//   它是给花草树木做的"燃烧 -> 变黑 -> **消失**"（ash 会缩放 + 淡出 ✓）✗
//   本文件是它的**去消失版** ✓：斑点/焦黑/余烬/烧焦后摆动减弱**全部保留** ✓，
//   但 `ash`（灰化消失）**不驱动任何消失** ✗ → 烧完就是一棵**焦黑的树** ✓。
//
// 另外两处适配"实心树干"的差异：
//   ① render_mode 里去掉 `cull_disabled` ✓（树干是实体 ✓ 只画正面 ✓）
//      也去掉 `ambient_light_disabled` / `fog_disabled` / `shadows_disabled` ✓
//      → 未燃烧时应与原来的 StandardMaterial3D **观感一致** ✓（正常受光 ✓）
//   ② 默认值按"替换型材质"设好 ✓：use_albedo = true / overlay_mode = false ✓
//
// 【怎么被驱动】scripts/vfx/foliage_burn.gd 会挑"材质里带 burn 参数的物体" ✓
//   （它检查 uniform 名 == "burn" ✓）→ 这个 shader 有 `burn` ✓ → 会被自动接管 ✓
// ★★★ 测试性改动（验收后按结果定稿 ✓）：**暂时去掉双面** ✗
//   树干是**闭合实体** ✓ → 双面时会画背面 → 与正面**深度冲突（镂空）** + 背面受光异常（发白）✓
//   若这次正常 → 说明"双面"就是根因 ✓ → 我会把它定成：**实体默认单面** ✓（更快 ✓ 也无冲突 ✓）
// ★★★ `depth_draw_always`（原来是 `depth_draw_opaque` ✗）：
//   原写法 = "仅在材质不透明时才写深度" ✓ 一旦材质被判成"有 alpha"（哪怕只是
//   写了 `ALPHA = 1.0`）→ 深度**完全不写** → 枝条被后画的花瓣/枝条盖住 = 透视 ✗✗
//   `depth_draw_always` 无论如何都写深度 ✓ 从机制上堵死这个坑 ✓（用户实测确认 ✓）
render_mode depth_draw_always;

// ★★ fast-tree 风摆移植（逐行对照 materials.js 的 wind 段；见 docs/wind-port-spec.md）
#include "res://assets/shaders/fast_tree_wind.gdshaderinc"


uniform sampler2D noise_tex : hint_default_black;
/// 原贴图（树干用 diff 图 ✓）
// ★★★ 关键修复：**必须加 `source_color`** ✓✓（不加 → sRGB 未转线性 → 采样偏亮 → **发白** ✓）
uniform sampler2D albedo_tex : source_color, hint_default_white;
uniform sampler2D mask_tex : hint_default_white;
uniform bool use_mask = false;
uniform int mask_channel = 3;
uniform float scissor : hint_range(0.0, 1.0) = 0.35;
uniform bool scissor_enabled = true;
uniform bool force_opaque = false;
uniform vec4 base_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);

/// 燃烧进度 0..1（斑点扩大 ✓）—— 由控制器每帧写 ✓
uniform float burn : hint_range(0.0, 1.0) = 0.0;
/// ★ 本 shader **忽略 ash 的消失作用** ✓（仅留作兼容 ✓：控制器仍会写它 ✓）
uniform float ash : hint_range(0.0, 1.0) = 0.0;
/// ★★★ 崩毁（用户需求 ✓）：树木烧透后**碎裂消失** ✓
///   0 = 完好（烧完只是焦黑）✓；1 = 整棵崩解殆尽 ✓
///   驱动：scripts/vfx/foliage_burn.gd 在"烧透 + 焦黑停留"之后按 collapse_time 推进 ✓
///   表现：顶点下沉（见 vertex）+ 分块 discard 抠掉几何（见 fragment ✓ 用 discard 不写 ALPHA ✓）
uniform float crumble : hint_range(0.0, 1.0) = 0.0;
uniform vec3 char_color : source_color = vec3(0.06, 0.05, 0.045);
uniform vec3 ember_color : source_color = vec3(1.0, 0.34, 0.05);
uniform float ember_width : hint_range(0.005, 0.5) = 0.035;
uniform float ember_gain : hint_range(0.0, 4.0) = 0.5;
uniform bool overlay_mode = false;
uniform float noise_scale : hint_range(0.1, 6.0) = 1.4;
/// 摆动幅度（米）——树干建议 0 ✓（想要"燃烧中颤动"就调到 0.02~0.05 ✓）
uniform float sway_amt : hint_range(0.0, 0.5) = 0.0;
uniform float sway_freq : hint_range(0.0, 6.0) = 1.4;
uniform float phase = 0.0;
// ★★ 风场 uniform 全部搬进 assets/shaders/fast_tree_wind.gdshaderinc
//   （fast-tree 移植：wind_direction/wind_gust/wind_turbulence/wind_speed/
//     wind_force/wind_frequency/wind_gust_speed/wind_spatial_scale/wind_bias/
//     wind_flex_falloff/wind_seed + 材质级 wind_sway/wind_is_leaf/
//     wind_leaf_flutter/wind_leaf_twist + 回退路径的 wind_strength/wind_height_*/
//     wind_sway_scale）—— 在这里重复声明会变量重定义编译失败 ✗
// ★★★ 角色扰动（站立 / 走过 / 跳跃）：
//   树干/枝条在**低于角色头顶**时被顶开；实际幅度由 aWind 决定 ✓
//   （树干 aWind≈0.01 ≈ 不动；L5 细枝 aWind≈0.75 动得最明显 ✓）
#include "res://assets/shaders/tree_player_disturb.gdshaderinc"
uniform float height_ref : hint_range(0.05, 20.0) = 6.0;
uniform bool use_albedo = true;
uniform bool use_uv = true;
// ★★ 可选的法线/粗糙度 ✓ —— **有就带、没有就不带** ✓（与 tree_leaves_burn 一致 ✓）
//   默认 false ✓ → 不采样 ✓ 零额外开销 ✓；由插件转换时按源材质自动写入 ✓
uniform sampler2D normal_tex : hint_normal;
uniform bool has_normal = false;
/// ★★ 法线贴图**强度**（= NORMAL_MAP_DEPTH）：1.0 = 原来的全强度 ✓ 默认值不变 ✓
///   为什么要它（2026-10-19 实测反馈 ✓）：
///   · 树皮的**细枝半径只有几毫米** ✓ 而法线贴图是按树干的 UV 密度做的 ✓
///     → 在细枝上逐像素切向法线被放大成**假的明暗折痕/亮脊** ✗
///     → 观感像"枝条被劈开/能看穿"（用户报的"不同视角出现透视"✓）
///   · 给 0.2~0.4 就能保住一点树皮凹凸 ✓ 又不至于在细枝上翻车 ✓
///   · 不想用法线细节就干脆 `has_normal = false` ✓（参考树的树干材质就是这么做的 ✓）
uniform float normal_strength : hint_range(0.0, 2.0) = 1.0;
uniform sampler2D rough_tex : hint_default_white;
uniform bool has_rough = false;
/// ★★ 粗糙度贴图里**哪个通道**是粗糙度：0=r / 1=g / 2=b / 3=a ✓
///   默认 0 = r（灰度粗糙度图 ✓ 与原来行为一致 ✓）
///   ★ 需要 1（g）的场合：**glTF/GLB 的 metallicRoughness 贴图** ✓
///     glTF 规范把它定义成 ORM 打包：**R=遮蔽 / G=粗糙度 / B=金属度** ✓
///     原来固定读 `.r` ✗ → 实际读到的是 **AO（遮蔽）** → 树干粗糙度是错的 ✓
uniform int rough_channel = 0;
/// ★★ 枝条"径向法线压平"强度：0.0 = 完全不动（默认 ✓ 老资产行为不变 ✓）
///   为什么需要：细枝是很细的圆柱 ✓ 用真实法线做**漫反射** → 正对光源的那一条母线
///   N·L≈1 → 出现**一条沿枝条方向的亮带** ✓ 在细枝上看起来就像"枝条被剖开/能看穿"✗
///   （实测：把 SPECULAR 关到 0 这条亮带仍在 ✓ → 不是高光而是漫反射 ✓
///     纯 albedo（unshaded）完全没有这条带 ✓ 所以是光照问题而非贴图问题 ✓
///     GLB 原本的 StandardMaterial3D 也有同样现象 ✓ 不是本项目的回归 ✓）
///   做法：把法线朝"由树干中轴向外的径向"混合 ✓ → 枝条整体受光更均匀 ✓ 亮带消失 ✓
///   注意：树干也会受影响（会变平板 ✗）→ 大樱花树实测取 0.55 观感最好 ✓ 别设 1.0 ✓
uniform float radial_normal : hint_range(0.0, 1.0) = 0.0;

varying vec2 v_uv;
varying float v_hgt;      // ★ 距模型根部的高度（**模型空间** ✓ 稳定 ✓ 不随相机抖动 ✓）
varying vec3 v_radial;    // ★ 由树干中轴指向外的径向（**视空间** ✓ 供 radial_normal 用 ✓）

void vertex() {
	v_uv = UV;
	v_hgt = VERTEX.y;         // ★ 模型空间高度 ✓（插值到像素 ✓ 比逐像素重建世界坐标稳定得多 ✓）
	// ★ 径向 = 从树干中轴（模型空间 y 轴）指向该顶点 ✓ 用**未位移**的 VERTEX 算（风摆不抖法线 ✓）
	//   +1e-5 防止顶点正好落在中轴上时 normalize(0) 出 NaN ✓
	v_radial = normalize((MODELVIEW_MATRIX * vec4(normalize(vec3(VERTEX.x, 0.0, VERTEX.z) + vec3(1e-5, 0.0, 1e-5)), 0.0)).xyz);
	float h = clamp(VERTEX.y / max(height_ref, 0.01), 0.0, 1.5);
	float alive = 1.0 - clamp(burn, 0.0, 1.0) * 0.75;
	// ★★★ 与树叶**同步**（用户要求 ✓）：用**同一套风**（阵风/沿线/湍流/高度加权 ✓）
	//   相位、方向、风速与叶子**完全一致** ✓ → 两者一起摆 ✓（不再各摆各的 ✗）
	//   树枝幅度 ×0.45 ✓（比叶子更硬 ✓ 叶子摆得最凶 ✓）；× alive（烧得越深越不摆 ✓）
	// ★★ fast-tree 风摆移植：烘焙属性（CUSTOM0/CUSTOM1）→ 精确风场；
	//   没有烘焙数据的网格自动走旧的高度权重路径（观感不变）
	vec3 tree_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float tree_base_y = MODEL_MATRIX[3].y;
	float tree_flex = 0.0;
	if (wind_enabled) {
		VERTEX += tree_wind_offset(VERTEX, CUSTOM0, CUSTOM1, CUSTOM2, tree_world_pos, tree_base_y, 0.45, tree_flex) * alive;
		// ★★★ 局部风场（龙卷风）：绕中心的切向环流，越靠中心越强
		if (tornado_strength > 0.001) {
			float t_base = MODEL_MATRIX[3].y;
			float t_h = clamp((VERTEX.y - t_base) / max(0.001, wind_height_ref), 0.0, 1.0);
			vec2 t_rel = VERTEX.xz - tornado_pos.xz;
			float t_d = length(t_rel);
			if (t_d < tornado_radius) {
				float t_k = 1.0 - t_d / max(tornado_radius, 0.001);
				t_k = t_k * t_k;
				vec2 t_out = normalize(t_rel + vec2(0.0001));
				vec2 t_tan = vec2(-t_out.y, t_out.x) * tornado_swirl;
				float t_scale = wind_height_ref * 1.40;  // ★ x2（用户要求 ✓）  // ★ 按真实高度（≈4.5m → 3.1m）✓ 去掉旧上限 ✓
		// ★★★ 物理化（用户要求：实际物理特性 + 查算法）
		//   依据：A Simulation on Grass Swaying with Dynamic Wind Force (ACM)
		//         + 对马岛之魂草地做法（Godot 实现：2Retr0/GodotGrass）
		//   ① 悬臂梁静力偏转 δ ∝ h²（均布载荷）→ 单向 ✓ 不回摆 ✗
		//      风压 = tornado_strength → 衰减时偏转同步减小；
		//      strength = 0（龙卷风停止）→ 自动回位 ✓ 即"除非龙卷风停止"
		//   ② 高频颤动：单峰权重 w(h)=(h/h0)*e^(1-h/h0)，h0=0.3
		//      → h=0.3 峰值（用户要的 30% 最抖）/ h=0 为 0（根部渐弱 ✓）
		float t_w30 = (t_h / 0.3) * exp(1.0 - t_h / 0.3);
		float t_flut = sin(TIME * 24.0 + VERTEX.x * 7.0 + VERTEX.z * 5.0);
		vec2 t_loc = t_tan * 0.9 - t_out * 0.15;
		VERTEX.xz += t_loc * (tornado_strength * t_k * t_scale * t_h * t_h);
		VERTEX.xz += t_tan * (tornado_strength * t_k * t_scale * 0.15 * t_flut * t_w30);
			}
		}
	}
	// ★★★ 角色扰动（站立 / 走过 / 跳跃）：
	//   低于头顶的低垂枝被顶开（向上抬 + 左右分开 ✓ 见 tree_player_disturb.gdshaderinc）
	//   amount=0.45：枝条比叶子硬（与风摆的比例一致 ✓）
	// ⚠ 第一个实参必须是 MODEL_MATRIX：该函数内部取不到内置变量，只能在这里传（否则编译报"标识符未知"）
	VERTEX += tree_player_displace(MODEL_MATRIX, VERTEX, CUSTOM0, CUSTOM1, true, 0.45) * alive;
	// ★★★ 崩毁下沉：**树冠先塌、树干后动**（用户要求 ✓ 从上到下 ✓）
	//   下沉量与高度成正比：高点先没入地面，底部最后才动 ✓
	if (crumble > 0.0) {
		float ch = clamp(VERTEX.y / max(height_ref, 0.01), 0.0, 1.0);
		float ck = crumble * crumble;
		VERTEX.y -= ck * (0.25 + ch * 0.75) * height_ref * 0.05;
		// 上半部轻微向树干轴收拢（塌陷感；底部几乎不动）
		VERTEX.xz -= VERTEX.xz * (ck * 0.05 * ch * ch);
	}
	// ★ 这里**没有** `VERTEX *= 1.0 - ash * 0.35` ✓ —— 烧完不收缩 ✓（与 burn_foliage 的关键区别 ✓）
}

void fragment() {
	// ★ 有法线/粗糙度就采样 ✓（没有就用默认值 ✓ 不白花两次采样 ✓）
	if (has_normal) {
		NORMAL_MAP = texture(normal_tex, v_uv).rgb;
		NORMAL_MAP_DEPTH = normal_strength;
	}
	// ★ 没有粗糙度贴图时用 **1.0（全哑光）** ✓ —— 与原来的 StandardMaterial3D 默认一致 ✓
	//   （原来我写 0.75 ✗ → 更反光 → 树干观感偏亮/发白 ✓ 用户反馈 ✓）
	ROUGHNESS = 1.0;
	if (has_rough) {
		// ★ 粗糙度通道可选 ✓（默认 r = 原行为 ✓；glTF 的 ORM 贴图必须用 g ✓）
		vec4 r = texture(rough_tex, v_uv);
		ROUGHNESS = r.r;
		if (rough_channel == 1) {
			ROUGHNESS = r.g;
		} else if (rough_channel == 2) {
			ROUGHNESS = r.b;
		} else if (rough_channel == 3) {
			ROUGHNESS = r.a;
		}
	}
	METALLIC = 0.0;
	// ★★★ 关键修复：**双面渲染时背面必须翻转法线** ✓✓
	//   本 shader 是 `cull_disabled`（双面 ✓ 因为源材质 cull_mode=2 ✓）→ 背面也被绘制 ✓
	//   若不翻法线 ✗：背面法线朝外 → 被光照打亮成**白色** ✓ + 与正面深度冲突 → **镂空** ✓✓
	//   （原生 StandardMaterial3D 在双面时会自动处理 ✓ 所以它一直正常 ✓；自定义 shader 必须自己做 ✗）
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
	// ★★ 枝条径向压平（见文件头 uniform 处说明 ✓）：默认 0 = 什么都不做 ✓
	//   排在"法线贴图"和"背面翻转"**之后** ✓ → 压平的是最终法线 ✓ 顺序错了会被覆盖 ✗
	if (radial_normal > 0.001) {
		NORMAL = normalize(mix(NORMAL, v_radial, radial_normal));
	}
	vec3 wp = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// ★ 世界坐标哈希噪声 ✓ —— **不依赖噪声贴图** ✗
	//   （材质没设 noise_tex 时它默认全黑 ✗ → thr=1 且 n=0 → burn=0 也全判为"已烧" ✗ → 一进场就焦黑 ✓）
	// ★★★ 噪声改用 **UV** ✓（修复"燃烧时闪烁"✗）：
	//   原来用世界坐标哈希 `fract(sin(dot(wp…))*43758)` ✗ —— 它对坐标的**极小变化**极其敏感 ✓
	//   相机稍微一动 / 浮点误差 → 整片图案**每帧重新随机** → **闪烁** ✓✓（用户实测 ✓）
	//   UV 是模型自带数据 ✓ 不随相机变化 ✓ → 同一位置永远同一个值 ✓ 稳定不闪 ✓✓
	float n = fract(sin(dot(v_uv * noise_scale, vec2(12.9898, 78.233))) * 43758.5453);

	// ★★★ 崩毁：**纯高度序**从上到下逐层消失（用户要求 ✓）
	//   · 不使用块状随机噪声 ✗（那会变成"碎屑颗粒"观感）
	//   · crumble=0 不抠任何像素；crumble=1 时 hk > 0 全部消失（不留残影）
	//   · 用 discard 而不是 ALPHA ✓ 木材质必须留在不透明队列（见文件头说明 ✓）
	if (crumble > 0.001) {
		float hk = clamp(v_hgt / max(height_ref, 0.01), 0.0, 1.0);
		if (hk > 1.0 - crumble) {
			discard;
		}
	}

	// ★★ 关键修复（实测推理 ✓）：**不再看 `use_albedo`** ✓，无条件采样 ✓
	//   证据链：① `base_color=红` → 树干变红 ✓（shader 在跑 ✓）
	//          ② 探针直接 `texture(albedo_tex, v_uv)` → 树干正常树皮 + UV 渐变 ✓（贴图能采 ✓）
	//          ③ 但 `ALBEDO=col` 时**纯白** ✗ ⇒ 说明 `if (use_albedo)` 没进 ✗
	//   ⇒ 运行时 `use_albedo` 实际为 false ✗（材质里写着 true ✗ = 参数被某处覆盖 ✓）
	//   → 无条件采样 ✓ 彻底绕开 ✓（燃烧只影响颜色混合 ✓ 不需要这个开关 ✓）
	vec4 base = base_color * texture(albedo_tex, v_uv);

	// ① ★★★ 从下往上"蔓延"（用户要求 ✓ 慢速 ✓）
	//   前沿高度 = `burn × height_ref` 米 ✓ 从**模型根部**（MODEL_MATRIX 原点 ✓）往上爬 ✓
	//   旧写法是"噪声阈值扫描"✗ → 阈值一越过噪声分布就**整片同时变黑** ✗（用户反馈 ✓）
	//   边缘用 UV 噪声做 ±0.45 米的不规则 ✓（稳定 ✓ 不闪 ✓）
	//   ★ 前沿 ×1.15：保证 `burn = 1` 时前沿**越过树顶** ✓
	//     （否则会停在 height_ref 高度 ✗ → 树冠卡在"半烧"状态 → 余烬最亮 → **整片橙红** ✗✓ 用户实测 ✓）
	float front_h = clamp(burn, 0.0, 1.0) * height_ref * 1.15 + (n - 0.5) * 0.9;
	float hgt = v_hgt;                        // ★ 用模型空间高度 ✓（原来的 wp.y 会随相机抖动 → 闪烁 ✗✓）
	float burned = 0.0;
	if (burn > 0.001) {
		burned = 1.0 - smoothstep(front_h - 0.45, front_h + 0.15, hgt);
		// 已烧区域内部保留一点斑点质感 ✓（用同一低频噪声 ✓ 不抖 ✓）
		burned = clamp(burned * (0.85 + 0.15 * n), 0.0, 1.0);
	}

	// ② 焦黑 + 前沿余烬（一致 ✓）
	vec3 col = mix(base.rgb, char_color, burned);
	// ★★★ 余烬改为**平滑前沿带** ✓（修复"燃烧时闪烁"✗）
	//   旧写法 `exp(-(n-thr)²/w²)` ✗：在**逐像素高频噪声**上开一条**极窄**的亮缝 ✓
	//     → burn 每推进一点就扫过一批像素 → 逐帧乱跳 = **闪烁** ✓✓（实测 ember_gain=0 即不闪 ✓）
	//   新写法 `4·burned·(1-burned)` ✓：纯 `burned` 的平滑函数 ✓ 前沿在哪亮在哪 ✓ 永不抖 ✓✓
	// ★★★ 烧到最后**必须熄灭** ✓（修复"烧完由黑变红"✗）
	//   旧写法余烬峰值在 burned=0.5 的过渡带 ✓ → burn 停在 1 时仍有部位处于过渡带 → **整片橙红** ✓✓
	//   现在乘 `(1 - burn)` ✓：前沿越接近树顶余烬越弱 ✓ `burn = 1` 时**完全熄灭** ✓ → **纯焦黑** ✓✓
	float ember = 4.0 * burned * (1.0 - burned);
	ember *= ember_gain * (1.0 - ash) * 1.5 * (1.0 - clamp(burn, 0.0, 1.0));
	col += ember_color * ember;

	// ③ ★ 烧到底也只是"更黑的焦炭" ✓ —— **不淡出、不消失** ✗（与 burn_foliage 的关键区别 ✓）
	col = mix(col, vec3(0.03, 0.03, 0.03), clamp(ash, 0.0, 1.0) * 0.6);
	float a = base.a;                                  // ★ 不再乘 (1 - ash) ✓

	float shape = 1.0;
	if (use_mask && !force_opaque) {
		vec4 m = texture(mask_tex, v_uv);
		if (mask_channel == 0) {
			shape = m.r;
		} else if (mask_channel == 1) {
			shape = m.g;
		} else if (mask_channel == 2) {
			shape = m.b;
		} else {
			shape = m.a;
		}
		if (scissor_enabled && shape < scissor) {
			discard;
		}
	}

	if (overlay_mode) {
		// ★★★ 本分支**同样不写 ALPHA** ✓✓（2026-10-22 最终定案 ✓）
		//   只要 shader 里**任何一处**写了 `ALPHA`，Godot 就把整份材质判成"有 alpha"✗
		//   → 材质被丢进**透明队列** → 按物体距离排序 ✗
		//   → 草/花瓣这些透明对象会**按排序盖到树干上** ✓
		//   → 观感：草从树干里透出来（细密点阵）✗ 且**随相机视角排序变化**✓（用户实测 ✓）
		//   需要"叠加层半透明"的场合，请另开一份带 blend 的 shader，别污染这一份 ✓
		ALBEDO = mix(char_color, ember_color, clamp(ember, 0.0, 1.0));
	} else {
		ALBEDO = col;
		// ★★★ 这里**绝对不能写 ALPHA** ✓✓（用户亲测确认 ✓）
		//   机制：只要 shader 里出现 `ALPHA = ...`，Godot 就把该材质当成"有 alpha"✗
		//     而本 shader 原 render_mode 是 `depth_draw_opaque`
		//     = **"仅在材质不透明时才写深度"**✗ → 被判成透明后枝条**完全不写深度**✗
		//     → 后画的枝条 / 花瓣（透明通道按物体距离排序）直接盖上来 ✓
		//     → 观感就是"枝条被看穿 / 前后错位"，且**随相机转动不断变**✓（用户描述"眼花"✓）
		//   为什么之前测不出来：静态单机位只渲染树皮、后面没有东西盖上来 → 看不出差异 ✗
		//   ★ 兜底：render_mode 已同时改成 `depth_draw_always` ✓
		//     即使哪天又被判成透明，也强制写深度 → 不会再穿透 ✓
	}

	// ---- 屏幕空间挖洞：角色被树干/枝挡住时，在角色周围挖个洞 ✓ ----
	// 算法与 scripts/shaders/occlusion_hole.gdshader **完全一致**（全项目观感统一 ✓）：
	//   洞内 → occ_hole_alpha，洞外 → 1.0，中间 smoothstep 过渡；
	//   再用 Bayer 抖动 + discard 出形状（**不写 ALPHA** ✓ 材质留在不透明队列 ✓）。
	// occ_hole_alpha >= 1.0 时整段等于空操作 → 完全不挖 ✓
	float occ_d = distance(SCREEN_UV, occ_player_uv);
	float occ_k = smoothstep(occ_radius - occ_softness, occ_radius + occ_softness, occ_d);
	float occ_a = mix(occ_hole_alpha, 1.0, occ_k);
	if (occ_a < 1.0) {
		if (bayer4(FRAGCOORD.xy) > occ_a) {
			discard;
		}
	}
}

