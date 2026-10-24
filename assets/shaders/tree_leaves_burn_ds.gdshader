shader_type spatial;
// ★★★ 局部风场（进阶需求 ✓）：由 `scripts/spells/blue_tornado.gd` 每帧广播 ✓
//   机制与 camera_rig 的 occ_player_uv 相同：RenderingServer.global_shader_parameter_set ✓
//   strength = 0 时完全无影响 ✓（龙卷风结束/不存在时它是 0 ✓）
global uniform vec3 tornado_pos;         // 龙卷风中心（世界坐标 ✓）
global uniform float tornado_radius;     // 影响半径（米 ✓）
global uniform float tornado_strength;   // 局部风速强度（0 = 无 ✓）
global uniform float tornado_swirl;      // 环流方向：+1 逆时针 / -1 顺时针 ✓

// ============================================================================
//  ★ 屏幕空间"视觉挖洞"（角色被树叶/花挡住时，在角色周围挖个洞）✓
//    与 scripts/camera_rig.gd + scripts/shaders/occlusion_hole.gdshader **同一套全局 uniform**：
//      camera_rig 每帧用 RenderingServer.global_shader_parameter_set 广播这 4 个值 ✓
//    与木质 shader(tree_burn_keep_ds) 的实现**逐字一致** ✓ 观感统一 ✓
//
//  ★ 为什么不用 ALPHA 做洞：本 shader 的 ALPHA 已被"烧尽淡出"占用 ✓
//    而且写 ALPHA 的材质会进透明队列（本 shader 本来就是 blend_mix ✓ 无妨），
//    但洞用 **Bayer 抖动 + discard** 出形更省、且能正确参与 depth_prepass_alpha 的深度 ✓
// ============================================================================
global uniform vec2 occ_player_uv;      // 角色屏幕 UV（洞中心，取胸口高度）
global uniform float occ_radius;        // 洞半径（UV 单位）
global uniform float occ_softness;      // 洞边缘过渡宽度
global uniform float occ_hole_alpha;    // 洞内"看起来"的不透明度（0=全挖空, 1=不挖）
// ★ 默认值约定（project.godot 的 [shader_globals]）：occ_hole_alpha = 1.0（= 不挖）
//   → 编辑器 / 任何没有 camera_rig 驱动的场景里**不会**出现"固定在屏幕中心的假洞"；
//   运行期由 scripts/camera_rig.gd 每物理帧写真实 uv/半径/透明度（关掉遮挡时会复位成不挖）。

// 4x4 Bayer 抖动矩阵：把"半透明"量化成网格状稀疏像素
// （与 occlusion_hole.gdshader / tree_burn_keep_ds.gdshader 完全相同 ✓）
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
// 【树叶专用】从下往上烧 ✓ → 烧到就消失 ✓
//
// ★ 与花草用的 burn_foliage.gdshader **完全独立** ✓（花草逻辑一行未改 ✓）
//
// 与花草版的三处差别（都是树需要的 ✓）：
//   ① 燃烧前沿 = **高度**（从下往上 ✓），不是"整片同时冒斑点" ✗
//      —— 因为树是"火从根部烧上去" ✓，而原来的噪声阈值会让树冠先冒斑 ✗
//   ② 烧完**消失** ✓（ash 缩放 + 淡出 + 裁剪 ✓）—— 叶子要烧没 ✓
//   ③ 带叶片的 **颜色图 + 独立 alpha 遮罩**（草的逻辑保留 ✓）
//
// 控制方式与花草一致 ✓：scripts/vfx/foliage_burn.gd 只会写
//   burn（0..1 斑点/前沿进度）与 ash（0..1 消失进度）✓ —— 本 shader 两个都支持 ✓
render_mode blend_mix, cull_disabled, depth_draw_opaque,
		depth_prepass_alpha, ambient_light_disabled, fog_disabled;

// ★★ fast-tree 风摆移植（逐行对照 materials.js 的 wind 段；见 docs/wind-port-spec.md）
#include "res://assets/shaders/fast_tree_wind.gdshaderinc"
// ★★★ `depth_prepass_alpha` 是**必须的** ✓（2026-10-19 实测反馈 ✓）
//   本 shader 走 blend_mix（= **透明队列** ✓ 因为 "烧完靠 alpha 淡出" 要用到混合 ✓）
//   但透明队列**默认不写深度** ✗ → 后果两条：
//     ① 「相机某些角度整棵树看起来是透明的」✗ —— 叶卡彼此不做遮挡 ✓
//        能一路看到后面的天空/背景 ✓（树冠像一层薄纸 ✓）
//     ② 「燃烧时花朵树叶闪烁」✗ —— 大量互相重叠的叶卡在透明队列里**按网格顺序画** ✓
//        顺序不随相机更新 → 颜色一变（燃烧）就出现忽明忽暗的跳变 ✓
//   加上 `depth_prepass_alpha` → 先用 alpha 裁一刀写一遍深度 ✓ 再正常混合颜色 ✓
//   → 叶卡之间**正确遮挡** ✓ 顺序不再影响画面 ✓（这是植被卡片的标配做法 ✓）

uniform sampler2D albedo_tex : source_color, hint_default_white;
/// 叶片的独立 alpha 遮罩（**默认**取红通道 ✓ 与草一致：形状在 r 通道 ✓）
uniform sampler2D alpha_tex : hint_default_white;
/// ★★ 遮罩在哪个通道：0=r / 1=g / 2=b / 3=a ✓
///   · 默认 0 = **原来的行为，一模一样** ✓（树 _small_02 用独立灰度遮罩图，形状在 r ✓）
///   · 需要 3 的场合：**glTF/GLB 导入的树**（如 樱花树.glb）把 MASK 的形状烘在
///     **baseColorTexture 的 a 通道** ✓（没有单独的遮罩图 ✗）→ 同一张 RGBA 图
///     既当 albedo_tex 又当 alpha_tex 时，只有读 .a 才是真轮廓 ✓
///     （读 .r 会拿到**颜色亮度** ✗ → 深色叶脉被判成透明 → 叶子被啃出洞 ✓）
uniform int alpha_channel = 0;
// ★★ 可选的法线/粗糙度 ✓ —— **有就带、没有就不带** ✓（用户要求 ✓）
//   默认 has_* = false ✓ → 不采样 ✓ 零额外开销 ✓（叶片 overdraw 大 ✓ 这点很重要 ✓）
uniform sampler2D normal_tex : hint_normal;
uniform bool has_normal = false;
uniform sampler2D rough_tex : hint_default_white;
uniform bool has_rough = false;
/// ★★ 粗糙度贴图里**哪个通道**是粗糙度：0=r / 1=g / 2=b / 3=a ✓
///   默认 0 = r（本项目的灰度粗糙度图 ✓ 行为与其他 tree shader 一致 ✓）
///   ★ 需要 1（g）的场合：**glTF/GLB 的 metallicRoughness 贴图** ✓
///     glTF 规范把它定义成 ORM 打包：**R=遮蔽 / G=粗糙度 / B=金属度** ✓
///     而本 shader 原来固定读 `.r` ✗ → 实际读到的是 **AO（遮蔽）** →
///     粗糙度是错的（叶面反光不对/发亮）✓
uniform int rough_channel = 0;
uniform float alpha_scissor : hint_range(0.0, 1.0) = 0.5;
uniform vec4 base_color : source_color = vec4(1.0, 1.0, 1.0, 1.0);
/// ★★ 叶片法线「树冠外扩」混合量：0 = **关闭**（默认 = 原来的行为 ✓ 一模一样 ✓）
///   为什么要它：本 shader 有 `ambient_light_disabled` ✗ → 只吃**直接光** ✓
///   · 树 _small_02 的叶卡法线是建模时**按朝上烘好**的 → 整片树冠受光均匀 ✓
///   · 而 **glTF/GLB 导入的树**（如 樱花树.glb）叶卡法线是**每个面片自己的原始朝向** ✗
///     → 一半叶子背对太阳 → 没有环境光兜底 → **整片发黑** ✗（实测 ✓）
///   把这里调到 0.6~0.9 → 法线改成"从树干轴线朝外"（+ 少量朝上）✓
///     → 树冠有体积感 ✓ 且正常响应光照方向 ✓（不会变成和相机一起转的平光片 ✓）
uniform float normal_up_blend : hint_range(0.0, 1.0) = 0.0;
/// ★★ 环境光补偿（自发光式补光）：0 = **关闭**（默认 = 原来的行为 ✓）
///   本 shader 有 `ambient_light_disabled` ✗ → 背光的叶卡**纯黑** ✓
///   参考树的叶卡法线全朝上 → 永远吃得到太阳光 → 看不出来 ✓
///   GLB 树一旦把法线掰回"正常朝向"（为了有体积感 ✓ 见 normal_up_blend ✓），
///   背光面就真的黑了 ✗ → 用一点**自发光补光**把它们抬成"暗粉"而不是纯黑 ✓
///   ★ 这是植被/树的常规做法（环境光缺失时用 albedo 自补）✓ 不影响直接光的层次 ✓
uniform float ambient_fill : hint_range(0.0, 1.0) = 0.0;

/// 燃烧进度 0..1（= 燃烧前沿高度比例 ✓ 从下往上 ✓）
uniform float burn : hint_range(0.0, 1.0) = 0.0;
/// 消失进度 0..1（前沿到顶后开始 ✓ 叶子缩小淡出 ✓）
uniform float ash : hint_range(0.0, 1.0) = 0.0;
/// ★ 崩毁（与 tree_burn_keep_ds 同名同义 ✓）：树烧透后叶子提前散尽 + 纯高度序 discard ✓
uniform float crumble : hint_range(0.0, 1.0) = 0.0;
uniform vec3 char_color : source_color = vec3(0.06, 0.05, 0.045);
uniform vec3 ember_color : source_color = vec3(1.0, 0.34, 0.05);
uniform float ember_width : hint_range(0.005, 0.5) = 0.045;
uniform float ember_gain : hint_range(0.0, 4.0) = 0.7;
/// 这株树的**总高度**（米 ✓）：前沿 = burn * height_ref ✓
/// ★ 必须设成实际树高 ✓，否则前沿会被压缩（默认先给 8 ✓）
uniform float height_ref : hint_range(0.05, 30.0) = 8.0;
/// 边缘不规则程度（米 ✓）：用世界噪声轻微扰动前沿 ✓ 避免"一条直边" ✗
uniform float edge_jitter : hint_range(0.0, 1.0) = 0.25;
/// 叶片的风摆（沿用 grass 的简单两频摆动 ✓ 燃烧越深摆得越小 ✓）
uniform float sway_amt : hint_range(0.0, 0.5) = 0.06;
uniform float sway_freq : hint_range(0.0, 6.0) = 1.4;
uniform float phase = 0.0;
// ★★ 风场 uniform 全部搬进 assets/shaders/fast_tree_wind.gdshaderinc
//   （fast-tree 移植：wind_direction/wind_gust/wind_turbulence/wind_speed/
//     wind_force/wind_frequency/wind_gust_speed/wind_spatial_scale/wind_bias/
//     wind_flex_falloff/wind_seed + 材质级 wind_sway/wind_is_leaf/
//     wind_leaf_flutter/wind_leaf_twist + 回退路径的 wind_strength/wind_height_*/
//     wind_sway_scale）—— 在这里重复声明会变量重定义编译失败 ✗
// ★★★ 角色扰动（站立 / 走过 / 跳跃）：
//   叶子与花朵在**低于角色头顶**时被顶开 ✓ 与树皮共用同一份实现 ✓
//   （世界坐标 + 头顶高度闸门 + 按 aWind 揉软度 —— 见 include 里的说明）
#include "res://assets/shaders/tree_player_disturb.gdshaderinc"

uniform sampler2D noise_tex : hint_default_black;

varying vec2 v_uv;
varying float v_y;          // 局部高度 ✓（树的根 = 0）
varying float v_hnorm;      // 归一化高度 0..1 ✓
/// 视空间的"树冠外扩法线"（= 从树干轴线指向该顶点，见 normal_up_blend ✓）
varying vec3 v_sph_normal;

void vertex() {
	v_uv = UV;
	// ★★ 先算"树冠外扩法线"（用**未受风偏移**的原始顶点 ✓ 稳定不抖 ✓）
	//   模型空间：水平方向朝外 + 只是轻微朝上 → 像一个扁的球壳 ✓
	//   （max(y-1.5,0)：树根附近不朝上，避免树干底部出现"平顶光" ✓）
	vec3 sph_m = normalize(vec3(VERTEX.x, max(VERTEX.y - 1.5, 0.0) * 0.45, VERTEX.z)
			+ vec3(1e-5, 1e-5, 1e-5));
	v_sph_normal = normalize((MODELVIEW_MATRIX * vec4(sph_m, 0.0)).xyz);
	v_y = VERTEX.y;
	v_hnorm = clamp(VERTEX.y / max(height_ref, 0.01), 0.0, 1.0);
	float alive = 1.0 - clamp(burn, 0.0, 1.0) * 0.8;      // 烧得越深越不摆 ✓
	float hw = clamp(VERTEX.y / max(height_ref, 0.01), 0.0, 1.0);
	// ★★ 从零生长（fast-tree uGrowth 移植）：按顶点高度把未长出的部分收缩到枝条基点 ✓
	//   必须放在风摆**之前** → 风场作用在"已经长出来的位置"上 ✓
	//   growth_enabled = false（默认）时该函数直接返回 0，行为与移植前完全一致 ✓
	VERTEX += tree_growth_offset(VERTEX, CUSTOM0.xyz);
	// ★★★ 参照"风对草的影响"（与 grass_wind 同一套算法 ✓ 用户要求 ✓）
	//   阵风 gust ✓ 沿线 along ✓ 侧向湍流 across ✓ 高度加权（wind_height_ref/power ✓）
	//   × alive（烧得越深摆得越小 ✓）
	// ★★ fast-tree 风摆移植：烘焙属性（CUSTOM0/CUSTOM1）→ 精确风场；
	//   没有烘焙数据的网格自动走旧的高度权重路径（观感不变）
	vec3 tree_world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float tree_base_y = MODEL_MATRIX[3].y;
	float tree_flex = 0.0;
	if (wind_enabled) {
		VERTEX += tree_wind_offset(VERTEX, CUSTOM0, CUSTOM1, CUSTOM2, tree_world_pos, tree_base_y, 1.0, tree_flex) * alive;
		// ★★★ 局部风场（龙卷风 ✓ 进阶需求）：把风改成**绕中心的切向环流** ✓
		//   越靠中心越强（k² 衰减 ✓）、带一点向内吸（0.25 ✓）、方向由 tornado_swirl 决定 ✓
		if (tornado_strength > 0.001) {
			vec2 rel = VERTEX.xz - tornado_pos.xz;
			float d = length(rel);
			if (d < tornado_radius) {
				float k = 1.0 - d / max(tornado_radius, 0.001);
				k = k * k;                                   // 中心更强 ✓
				vec2 outw = normalize(rel + vec2(0.0001));
				vec2 tang = vec2(-outw.y, outw.x) * tornado_swirl;
				float t_scale2 = wind_height_ref * 1.40; // ★ x2（用户要求 ✓） // ★ 按真实高度 ✓ 去掉旧上限 ✓
			float t_swing2 = sin(TIME * 3.0);
			// ★★★ 物理化（用户要求）：悬臂梁单向偏转 δ∝h² + 30% 高度峰值颤动
			float t_w30 = (hw / 0.3) * exp(1.0 - hw / 0.3);
			float t_flut = sin(TIME * 24.0 + VERTEX.x * 7.0 + VERTEX.z * 5.0);
			vec2 local = tang * 0.9 - outw * 0.15;
			VERTEX.xz += local * (tornado_strength * k * t_scale2 * hw * hw) * alive;
			VERTEX.xz += tang * (tornado_strength * k * t_scale2 * 0.15 * t_flut * t_w30) * alive;
			}
		}
	}
	// ★★★ 角色扰动（站立 / 走过 / 跳跃）：
	//   低于头顶的叶/花被顶开（向上抬 + 左右分开 ✓ 见 tree_player_disturb.gdshaderinc）
	//   amount=1.0：叶子/花朵与风摆同幅度（枝条是 0.45 ✓ 更硬）
	// ⚠ 第一个实参必须是 MODEL_MATRIX：该函数内部取不到内置变量，只能在这里传（否则编译报"标识符未知"）
	VERTEX += tree_player_displace(MODEL_MATRIX, VERTEX, CUSTOM0, CUSTOM1, false, 1.0) * alive;
	// ★ 消失**只用材质透明**（用户要求 ✓）：不再缩放几何 ✗
	//   —— 原来看起来会"整株缩没" ✗；现在叶子保持原尺寸、只靠 alpha 淡出 ✓✓
}

void fragment() {
	vec4 base = base_color * texture(albedo_tex, v_uv);
	// ★ 叶片的独立遮罩（默认取 r 通道 ✓ 与 grass_wind 的做法一致 ✓）
	//   alpha_channel 决定取哪个通道 ✓（GLB 的 MASK 在 a 通道 → 需要 3 ✓）
	vec4 am = texture(alpha_tex, v_uv);
	float shape = am.r;
	if (alpha_channel == 1) {
		shape = am.g;
	} else if (alpha_channel == 2) {
		shape = am.b;
	} else if (alpha_channel == 3) {
		shape = am.a;
	}
	if (shape < alpha_scissor) {
		discard;
	}

	// ★★★ 燃烧边缘噪声改用 **UV** ✓（修复「燃烧时花朵树叶闪烁」✓ 用户反馈 ✓）
	//   旧写法用**世界坐标**哈希 ✗：
	//     `wp = INV_VIEW_MATRIX * VERTEX` ✓ —— 但片元里的 VERTEX 是**已经被风偏移过**的 ✓
	//     → 风每帧都在动 ✓ → wp 每帧都变 ✓ → 噪声 nz 每帧重抽 ✓
	//     → `jitter` → `burned` → 焦黑/余烬的边界**逐帧乱跳** ✓✓（= 闪烁 ✓）
	//   这和 tree_burn_keep_ds 当年踩的是**同一个坑** ✓（那边已改成 UV ✓ 见其注释 ✓）
	//   UV 是模型自带的静态数据 ✓ 不随风/相机变化 ✓ → 火焰前沿牢牢"长"在叶子上 ✓
	float nz = fract(sin(dot(v_uv * 37.0, vec2(12.9898, 78.233))) * 43758.5453);

	// ★ 崩毁：与 tree_burn_keep_ds 同一套**纯高度序** discard ✓（从上到下消失 ✓）
	//   叶子通常已由 ash 淡尽 ✓ 这里只兜底 ✓；不用随机块状噪声 ✗（避免颗粒感）
	if (crumble > 0.001) {
		if (v_hnorm > 1.0 - crumble) {
			discard;
		}
	}

	// ★★ 从下往上烧 ✓：前沿高度比例 = burn ✓（+ 噪声扰动 → 边缘不规则 ✓）
	float front = clamp(burn, 0.0, 1.0);
	// ★★ burn=0（未烧）时**强制不焦黑** ✓ —— 无论噪声/高度如何 ✓（杜绝"未烧先黑"✗）
	float burned = 0.0;
	if (burn > 0.001) {
		float jitter = (nz - 0.5) * edge_jitter * 0.35;
		float f2 = front + jitter;
		burned = 1.0 - smoothstep(f2 - 0.06, f2 + 0.06, v_hnorm);
	}

	vec3 col = mix(base.rgb, char_color, burned);
	float d = abs(v_hnorm - front);
	float ember = exp(-(d * d) / max(ember_width * ember_width, 1e-6));
	ember *= ember_gain * (1.0 - clamp(ash, 0.0, 1.0)) * (1.0 - burned * 0.5);
	col += ember_color * ember;

	// ★★ 消失 = **材质透明** ✓，并且**末端缓慢** ✓（用户要求 ✓）
	float fade = 1.0 - smoothstep(0.2, 1.0, clamp(ash, 0.0, 1.0));
	// ★★ 关键修复：ALPHA **只用于"烧尽淡出"** ✓ —— 不再乘 mask / 贴图 alpha ✗
	//   之前 `ALPHA = base.a * shape * fade` ✗ → 半透明混合 → 整棵树**发白** ✓ 叶子变稀 ✓（用户实测 ✓）
	//   叶子的真实轮廓已由上面的 `if (shape < alpha_scissor) discard;` **硬裁** ✓ → 叶子是实心 ✓
	float a = fade;
	col = mix(col, vec3(0.03, 0.03, 0.03), clamp(ash, 0.0, 1.0) * 0.4);
	if (a < 0.02) {
		discard;
	}
	// ★ 有法线/粗糙度就采样 ✓（没有就用默认 ✓ 不白花两次采样 ✓）
	if (has_normal) {
		NORMAL_MAP = texture(normal_tex, v_uv).rgb;
		NORMAL_MAP_DEPTH = 1.0;
	}
	// ★★★ 双面渲染（cull_disabled）时**必须翻背面法线** ✓ —— 与 tree_burn_keep_ds 同一处处理 ✓
	//   本 shader 是双面 ✓（叶子两面都要看到 ✓）。不翻的后果：
	//   背面法线朝外 → 吃不到正面光 → 整片叶卡**发黑** ✓
	//   （原生 StandardMaterial3D / glTF 双面会自动翻 ✓ 所以原模型不黑 ✓；
	//    自定义 shader 必须自己做 ✗ —— 这是「换成燃烧材质后树冠一半变黑」的根因 ✓）
	//   ★ 位置很关键：要放在 NORMAL_MAP 之后 ✓（与 tree_burn_keep_ds 保持一致 ✓）
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}
	// ★★★ 叶片法线重定向（可选 ✓ 默认 0 = 关闭 ✓ 不影响参考树 ✓）
	//   要同时解决两个症状 ✓（都是"法线只往正上方掰"造成的 ✓）：
	//     ① 树冠一半叶卡背对太阳 → 没有环境光兜底 → **发黑** ✓
	//     ② 掰成"纯朝上"后，法线与太阳的夹角**恒定** ✗ →
	//        从任何角度转相机，树冠平均亮度几乎不变（实测 0.805 → 0.862 ✗）
	//        → 观感就是"树冠像一张贴在相机上的平光片 / 跟着相机一起转"✓ 用户反馈 ✓
	//   改法：主体用**树冠外扩法线**（spherical normal）+ 少量往上 ✓
	//     · 外扩法线在树冠上**有方向变化** ✓ → 明暗有体积感 ✓ 且随光照/视角正常变化 ✓
	//     · 往上那一小份只用来抬亮叶卡背面 ✓ 不再主导法线方向 ✓
	//   ★ 位置：放在 NORMAL_MAP 之后 ✓（法线贴图的基（TBN）由 NORMAL 建 ✓）
	if (normal_up_blend > 0.001) {
		vec3 up_view = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
		vec3 n = normalize(mix(NORMAL, v_sph_normal, normal_up_blend));
		NORMAL = normalize(mix(n, up_view, normal_up_blend * 0.35));
	}
	ROUGHNESS = 0.75;
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
	// ★ 环境光补偿（可选 ✓ 默认 0 = 关闭 ✓）：把背光叶卡抬成"暗色"而不是纯黑 ✓
	if (ambient_fill > 0.001) {
		EMISSION = col * ambient_fill;
	}
	ALBEDO = col;
	ALPHA = a;

	// ---- 屏幕空间挖洞：角色被树叶/花挡住时，在角色周围挖个洞 ✓ ----
	// 算法与 scripts/shaders/occlusion_hole.gdshader、tree_burn_keep_ds.gdshader 完全一致 ✓
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

