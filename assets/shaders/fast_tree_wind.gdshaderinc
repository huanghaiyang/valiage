// ============================================================================
//  fast-tree 风摆 · 逐行移植（Godot 4 spatial shader 版）
// ============================================================================
//  来源：D:\sgames\fast-tree\src\core\materials.js  L29-135
//        （VERTEX_HEADER + vertexBody 里的 wind 段与 treeRotate）
//  自检模型：D:\sgames\fast-tree\src\core\windModel.js（叶尖轨迹指标）
//
//  这份 include 被两个树着色器使用：
//    · assets/shaders/tree_leaves_burn_ds.gdshader   （树叶 / 花朵）
//    · assets/shaders/tree_burn_keep_ds.gdshader     （树干 / 枝条 / 果实）
//
//  ★ 顶点数据来自烘焙（tools/bake_tree_wind.gd）：
//      CUSTOM0 = vec4(aOrigin.xyz, aWind)
//      CUSTOM1 = vec4(aPhase, isLeaf, nodeId, baked)   // baked=1 表示有真实烘焙数据
//    没有烘焙数据的网格（CUSTOM1.w == 0）→ 走"旧的高度权重"回退路径，
//    保证其它树 / 灌木的观感与移植前**完全一致**。
//
//  ★ 物理约定（与 fast-tree 一致，改之前先读 windModel.js 的注释）：
//    1) 顺风位移恒沿 windDir，只有幅度随时间变化；bias 只抬高摆动低谷（风只推不拉）
//    2) 叶柄固定不动；叶片只做「固定方向弯曲」+「绕固定水平轴的铰链俯仰」
//       —— 全程没有绕垂直轴的自转，这是"不绕圈"的结构性保证
//    3) 垂直于风向的位移只来自 turbulence
//
//  ★ 相对源实现的一处**刻意增强**（可用参数关掉）：
//    源实现里所有元素共用一个抖动频率，只有相位随机；在几千片叶/花的规模下会呈现
//    "整片同频振动"。因此这里给每个元素加了由 aPhase/nodeId 派生的频率/幅度微差：
//    · wind_variation（默认 0.45）：叶片/花朵的局部抖动频率与幅度微差
//    · wind_sway_variation（默认 0.15）：刚性主波**次级项**的频率微差（主项保持同频，避免漂移）
//    两个都给 0 时，计算与 fast-tree 源实现逐位等价。
// ============================================================================

// ---- 全局风场（由 scripts/wind.gd 每帧写入；实例化节点后参数可在 Inspector 调）----
uniform vec2 wind_direction = vec2(1.0, 0.0);   // 水平风向（未归一化也可以，内部会归一化）
uniform float wind_gust = 0.15;                 // 阵风 0..1
uniform float wind_turbulence = 0.30;           // 湍流 0..1
uniform float wind_speed = 1.4;                 // 相位推进速度
uniform bool wind_enabled = false;              // 总开关（材质级）
// ★ 移植新增：fast-tree 的量（单位：米）
uniform float wind_force = 0.06;                // 树梢顺风偏移量级（= weather.wind × 每单位米数）
uniform float wind_frequency = 1.0;             // 次波频率倍率（fast-tree uWindFrequency）
uniform float wind_gust_speed = 0.16;           // 阵风脉动速度（fast-tree uGustSpeed）
uniform float wind_spatial_scale = 0.22;        // 世界 xz 相位错开（fast-tree uSpatialScale）
uniform float wind_bias = 0.30;                 // 顺风静态偏置（fast-tree uWindBias）
uniform float wind_flex_falloff = 1.5;          // flex 指数（fast-tree uFlexFalloff）
uniform float wind_seed = 0.0;                  // 每棵树随机种子（fast-tree uSeed）
// ★★ 频率去同步化（本次新增；0 = 完全等于 fast-tree 源实现）
uniform float wind_freq_scale = 1.0;            // 全局频率倍率（wind.gd 写；材质 wind_frequency 是基础倍率）
uniform float wind_variation = 0.45;             // 每元素（每叶/每花）抖动频率与幅度的微差
uniform float wind_sway_variation = 0.15;        // 每元素"刚性主波次级项"的频率微差（不产生漂移）
// ---- 材质级（在 .tres 里写，Inspector 可调）----
uniform float wind_sway = 1.0;                  // 摆幅倍率（fast-tree uSway，树皮 < 1）
uniform bool wind_is_leaf = false;              // 该材质是否做叶片弯曲/俯仰（fast-tree uIsLeaf）
uniform float wind_leaf_flutter = 0.6;          // 叶片抖动（fast-tree uLeafFlutter）
uniform float wind_leaf_twist = 0.5;            // 叶片俯仰（fast-tree uLeafTwist）
uniform float wind_flutter_rate = 1.0;           // 该材质的抖动频率倍率（花比叶慢，避免同频）

// ---- 旧回退路径用（未烘焙网格；语义与移植前一致）----
uniform float wind_strength = 0.18;             // 相对强度 0..1.5（不是米）
uniform float wind_height_ref : hint_range(0.01, 30.0) = 8.0;
uniform float wind_height_power : hint_range(0.5, 4.0) = 1.8;
uniform float wind_sway_scale : hint_range(0.0, 2.0) = 0.22;


// 罗德里格旋转：绕任意轴旋转（叶片用固定水平轴做铰链式俯仰，不做绕垂直轴自转）
vec3 treeRotate(vec3 v, vec3 axis, float angle) {
	float c = cos(angle);
	float s = sin(angle);
	float d = dot(axis, v);
	return v * c + cross(axis, v) * s + axis * d * (1.0 - c);
}


// ---------------------------------------------------------------------------
//  回退路径：移植前两个树着色器用的"高度权重"风场（逐字保留，勿改观感）
//    pos          模型空间顶点
//    legacy_scale 枝条用 0.45（比叶子硬），叶子用 1.0
//    out_flex     输出高度权重（0..1），供片元使用
// ---------------------------------------------------------------------------
vec3 tree_wind_legacy(vec3 pos, float base_y, float legacy_scale, out float out_flex) {
	float hw = clamp((pos.y - base_y) / max(0.001, wind_height_ref), 0.0, 1.0);
	out_flex = pow(hw, wind_height_power);
	float gust = 1.0 + wind_gust * 2.2
			* (0.5 + 0.5 * sin(TIME * wind_speed * 0.37 + pos.x * 0.013 + pos.z * 0.011));
	float amp = wind_strength * gust;
	vec2 dir = normalize(wind_direction + vec2(0.0001));
	float along = sin(TIME * wind_speed + pos.x * 0.35 + pos.z * 0.28) * 0.35 + 0.65;
	float across = cos(TIME * wind_speed * 0.83 + pos.x * 0.23 - pos.z * 0.31) * wind_turbulence;
	vec2 sway = dir * along + vec2(-dir.y, dir.x) * (across * 0.25);
	float dist = (pos.y - base_y) * wind_sway_scale * amp;
	return vec3(sway.x, 0.0, sway.y) * (dist * out_flex) * legacy_scale;
}


// ---------------------------------------------------------------------------
//  主函数：返回模型空间位移（加到 VERTEX 上即可）。
//    c0 = CUSTOM0（aOrigin.xyz, aWind），c1 = CUSTOM1（aPhase, isLeaf, nodeId, baked）
//    legacy_scale 仅回退路径用（枝条 0.45 / 叶子 1.0）
//    out_flex     输出柔软度 0..1（片元可用于透光/高光）
// ---------------------------------------------------------------------------
vec3 tree_wind_offset(vec3 pos, vec4 c0, vec4 c1, vec3 world_pos, float base_y, float legacy_scale, out float out_flex) {
	if (!wind_enabled) {
		out_flex = 0.0;
		return vec3(0.0);
	}
	// 没有烘焙数据 -> 旧路径（其它树 / 灌木保持原样）
	if (c1.w < 0.5) {
		return tree_wind_legacy(pos, base_y, legacy_scale, out_flex);
	}

	// ---------------- fast-tree 精确移植 ----------------
	float a_wind = clamp(c0.w, 0.0, 1.0);
	float flex = pow(a_wind, wind_flex_falloff);
	out_flex = flex;
	vec3 a_origin = c0.xyz;
	float a_phase = c1.x;

	vec2 windDir = normalize(wind_direction + vec2(1e-5, 1e-6));
	vec2 windPerp = vec2(-windDir.y, windDir.x);
	float phase = a_phase + dot(world_pos.xz, windDir) * wind_spatial_scale + wind_seed * 0.017;
	float tw = TIME * wind_speed;
	// ★★ 频率去同步化（核心）：
	//   fast-tree 源实现里所有元素共用一个频率（只靠 aPhase 错开**相位**），
	//   落到几千片叶/花 + 枝条果实上就是"整片同频振动"，观感机械。
	//   这里让每个元素（每叶/每花/每枝，由烘焙 aPhase + nodeId 唯一决定）拿到一个
	//   稳定的频率/幅度微差。wind_variation = wind_sway_variation = 0 时逐位等于源实现。
	float h1 = fract(sin(a_phase * 12.9898 + c1.z * 78.233 + 0.13) * 43758.5453);
	float h2 = fract(sin(a_phase * 39.3467 + c1.z * 11.1357 + 0.71) * 24634.6345);
	float freq = max(0.05, wind_frequency * wind_freq_scale);
	// 刚性主波：只让**次级项**（0.28 权重那一条）的频率随元素变化。
	//   主项保持全局同频 -> 叶片不会相对枝条缓慢漂移（drift），但每根枝/每片叶的节奏不同。
	float sway_rate = 1.0 + wind_sway_variation * (h1 * 2.0 - 1.0);
	// 局部抖动（叶片弯曲/俯仰）：绕 aOrigin 的局部运动，频率和幅度都可以大胆变化，
	//   不会造成叶片相对枝条的位移漂移。
	float flutter_rate = max(0.2, 1.0 + wind_variation * (h1 * 2.0 - 1.0));
	float flutter_amp = 1.0 + wind_variation * (h2 * 2.0 - 1.0) * 0.8;

	// 顺风主波 + 高频次波
	float wave = sin(tw + phase) * 0.72 + sin(tw * 2.17 * freq * sway_rate + phase * 1.7) * 0.28;
	float osc = wave * 0.5 + 0.5;                       // 0..1
	// 阵风：压低摆动区间的低谷（wind_gust 越大，起伏越强）
	float gust = 1.0 - wind_gust * 0.6 *
			(1.0 - (sin(tw * wind_gust_speed + phase * 0.21) * 0.5 + 0.5));
	// 风只"推"不"拉"：位移恒偏下风向；bias 只抬低谷，不削峰值
	float along = osc * gust + wind_bias * 0.35;
	float turb = sin(tw * 3.1 * freq + phase * 4.3);
	vec2 sway = windDir * along + windPerp * turb * wind_turbulence;

	vec3 treePos = pos;
	float amount = wind_force * wind_sway * flex;
	treePos.xz += sway * amount;

	if (wind_is_leaf) {
		// 叶片：叶柄固定不动，只做"弯曲 + 铰链式俯仰"
		//  1) 弯曲方向固定且以水平分量为主（下风向占绝对主导）-> 方向一眼可辨
		//  2) 俯仰绕固定的水平轴（垂直于风向），小角度来回 -> 物理上就是叶片迎风翻动
		//  + 每片叶自己的频率/幅度微差（flutter_rate / flutter_amp），避免整片同频抖动
		vec3 rel = treePos - a_origin;
		float stemDist = length(rel);
		float fr = max(0.2, wind_flutter_rate * flutter_rate);
		float flap = sin(tw * 4.1 * freq * fr + phase * 6.3);
		float surge = sin(tw * 1.35 * fr * (0.9 + 0.2 * h2) + phase * 2.1);
		float leafAmp = wind_leaf_flutter * wind_force * 1.8 * (0.35 + a_wind) * flutter_amp;
		vec3 bendDir = normalize(vec3(windDir.x, -0.3, windDir.y));
		rel += bendDir * stemDist * leafAmp * (0.5 + 0.35 * flap + 0.15 * surge);
		float pitch = flap * wind_leaf_twist * 0.5 * (0.35 + wind_force * 2.0);
		rel = treeRotate(rel, vec3(windPerp.x, 0.0, windPerp.y), pitch);
		treePos = a_origin + rel;
	}
	return treePos - pos;
}
