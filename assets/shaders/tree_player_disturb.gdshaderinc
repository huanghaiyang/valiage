// ============================================================================
//  ★★★ 树木"角色扰动"：角色站在/走过/跳到**低于头顶**的 L5 枝条、树叶、花朵下面时，
//       把它们顶开（与草的踩踏扰动同一套思路，但方向是"向上顶 + 左右分开"）。
//
//  被两个树着色器共用：
//    · assets/shaders/tree_leaves_burn_ds.gdshader   （树叶 / 花朵）
//    · assets/shaders/tree_burn_keep_ds.gdshader     （树干 / 枝条，L5 枝条 aWind 最大）
//
//  ★ 为什么必须用**世界坐标**判断（旧实现无效的根因）：
//     `VERTEX` 是**模型空间**，而 player_pos 是**世界坐标**。
//     旧写法 `VERTEX.xz - player_pos.xz` 把两个空间相减 ✗ —— 大樱花树在
//     (-13.72, 0.32, -14.54)、缩放 0.3，两者天然差十几米 → 距离权重恒为 0 → 永远没效果。
//     这里统一：顶点先转世界算距离/方向，算完的位移再转回模型空间。
//
//  ★ 高度条件（用户要求"低于角色头顶"）：
//     player_head_y = 脚底 y + 角色身高（跳跃时脚底抬高 → 头顶自动变高 ✓ 不需要单独传状态）
//     头顶以下 = 满权重；头顶以上 player_head_soft 米内平滑衰减到 0 ✓
//
//  ★ 修复记录（2026-10-23）：`表达式中的标识符未知：“MODEL_MATRIX”`
//     ── 原因 ──
//     Godot 的 GDShader 里 MODEL_MATRIX / VERTEX / TIME 这类**内置变量只在
//     vertex() / fragment() 的函数体里可见**；一旦把它们搬进自定义函数（本例是
//     tree_player_displace），编译器就当成未声明的普通标识符直接报错。
//     ── 修法 ──
//     把 MODEL_MATRIX 提升为函数的**第一个参数**（mat4 model_matrix），
//     由调用方在 vertex() 里传进来。函数内部两处用到它的地方全部改用这个参数：
//       1) 顶点转世界：`wp = (model_matrix * vec4(pos_model, 1.0)).xyz`
//       2) 世界位移转回模型：`mat3(model_matrix)` 的三个列向量做投影反解
//     两个调用点（tree_leaves_burn_ds / tree_burn_keep_ds 的 vertex()）也因此
//     必须在实参位置写 `MODEL_MATRIX` —— 这是**唯一**能取到它的位置。
// ============================================================================
uniform vec3 player_pos = vec3(0.0, -100000.0, 0.0);
uniform vec3 player_forward = vec3(0.0, 0.0, -1.0);
uniform float player_radius : hint_range(0.05, 3.0) = 0.55;
uniform float player_bend : hint_range(0.0, 2.0) = 0.55;
uniform float player_spread : hint_range(0.0, 1.5) = 0.30;
uniform float player_move : hint_range(0.0, 1.0) = 0.0;
/// 角色头顶的**世界高度**（米）✓ 由 scripts/wind.gd 每帧写：脚底 y + player_head_height
uniform float player_head_y = -100000.0;
/// 头顶以上的淡出宽度（米 ✓）：0 = 头顶是一条硬线，越大过渡越软
uniform float player_head_soft : hint_range(0.0, 1.5) = 0.35;

/// 该顶点"有多软"（0..1）—— 决定角色能把它顶开多少。
/// · 烘焙过的网格：CUSTOM0.w（= aWind ✓ 实测 树干≈0.01 / L1≈0.35 / L5≈0.75 / 叶花≈0.9）
///   → 树干几乎不动、L5 细枝和叶花动得最明显 ✓ 正好符合"只扰动 L5 与叶花"
/// · 未烘焙的网格（老的小树）：树皮按高度渐入（底部不动 ✓），叶片给固定偏软值
float tree_player_flex(vec4 c0, vec4 c1, float pos_y, bool is_bark) {
	if (c1.w > 0.5) {
		return clamp(c0.w, 0.0, 1.0);
	}
	if (is_bark) {
		return smoothstep(1.2, 3.0, pos_y) * 0.45;
	}
	return 0.70;
}

/// 角色对当前顶点造成的位移（**模型空间** ✓ 可直接 `VERTEX += ...`）。
/// 参数：
///   model_matrix  模型的 MODEL_MATRIX（⚠ Godot 的内置变量只在 vertex()/fragment()
///                 里可见，**自定义函数里取不到** —— 必须由调用方传进来，
///                 否则报 "标识符未知：MODEL_MATRIX"；调用点见两个树着色器的 vertex()）
///   pos_model     顶点位置（**模型空间**：传 VERTEX 即可）
///   c0 / c1       烘焙属性 CUSTOM0 / CUSTOM1（c0.w = aWind 软度；c1.w = 是否烘焙过）
///   is_bark       是否树皮材质（未烘焙网格走高度渐入，叶片走固定软度）
///   amount        材质级幅度（树皮 0.45 / 叶花 1.0 ✓ 与风摆的比例一致）
/// 返回：需要加到模型空间顶点上的位移；无扰动时返回 vec3(0.0)（调用方直接 += 即可，无需分支）。
///
/// ★ 为什么先把顶点转世界再算：
///   player_pos / player_forward 都是**世界坐标**，而 VERTEX 是模型空间。
///   模型带平移（大樱花树在 -13.7, -14.5）和缩放（0.3），直接相减得到的"距离"
///   没有物理意义 —— 所以必须先 `model_matrix * pos_model` 转世界，
///   算完的世界位移再反解回模型空间（见函数末尾）。
vec3 tree_player_displace(mat4 model_matrix, vec3 pos_model, vec4 c0, vec4 c1, bool is_bark, float amount) {
	if (player_move <= 0.001) {
		return vec3(0.0);
	}
	// 哨兵：wind.gd 找不到玩家时写的是 -100000
	if (player_head_y < -90000.0) {
		return vec3(0.0);
	}
	// 模型空间 -> 世界空间：距离、朝向、高度都必须用世界坐标算（见上方函数注释）
	vec3 wp = (model_matrix * vec4(pos_model, 1.0)).xyz;
	// 高度闸门（世界 y）：头顶以下满权重，向上 soft 米内淡出
	float soft = max(player_head_soft, 0.001);
	float cap = 1.0 - smoothstep(player_head_y, player_head_y + soft, wp.y);
	if (cap <= 0.001) {
		return vec3(0.0);
	}
	vec2 rel = wp.xz - player_pos.xz;
	float rad = max(player_radius, 0.01);
	float infl = 1.0 - clamp(length(rel) / rad, 0.0, 1.0);
	infl = infl * infl * (3.0 - 2.0 * infl);                 // 平滑到 0（边缘不硬切）
	infl *= clamp(player_move, 0.0, 1.0) * cap * tree_player_flex(c0, c1, pos_model.y, is_bark);
	if (infl <= 0.002) {
		return vec3(0.0);
	}
	// 角色朝向：forward 与 right 都在水平面内
	vec2 fw = normalize(player_forward.xz + vec2(0.0001, 0.0));
	vec2 rt = vec2(-fw.y, fw.x);
	float along = dot(rel, fw);
	float side = dot(rel, rt);
	float front = smoothstep(-0.35, 0.45, along);            // 角色前方 / 身上的枝被顶得更明显
	float sgn = side < 0.0 ? -1.0 : 1.0;                     // 左右分开
	vec2 push = rt * (sgn * player_spread) - fw * (0.10 * front);
	// 竖直方向：**向上顶**（低垂枝被头/肩抬起 ✓ 而不是草的"倒下去"）
	float lift = player_bend * (0.35 + 0.65 * front);
	vec3 off_world = vec3(push.x, lift, push.y) * (infl * amount);
	// 世界 -> 模型：VERTEX 要按模型空间写回，所以得把世界位移反解过来。
	// 这里假设模型 basis 的三根列向量**两两正交**（只有旋转 + 均匀/非均匀缩放，无斜切），
	// 此时逆矩阵 = 转置 / 列长平方：对每根轴做一次投影再除以该轴长度的平方即可精确还原。
	// ⚠ 大樱花树缩放 0.3：若直接写 off_world 会放大 1/0.3 ≈ 3.33 倍，必须走这一步。
	//    （非正交 basis —— 例如带斜切的网格 —— 这段是近似解，画面上通常看不出来。）
	mat3 m3 = mat3(model_matrix);
	vec3 b0 = m3[0];      // 模型 x 轴在世界里的方向（长度 = x 缩放）
	vec3 b1 = m3[1];      // 模型 y 轴
	vec3 b2 = m3[2];      // 模型 z 轴
	return vec3(
			dot(b0, off_world) / max(dot(b0, b0), 1e-8),   // 1e-8 兜底，避免退化轴除零
			dot(b1, off_world) / max(dot(b1, b1), 1e-8),
			dot(b2, off_world) / max(dot(b2, b2), 1e-8));
}
