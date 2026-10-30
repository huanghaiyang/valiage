// ============================================================================
// blood_flower_sprite.gdshader —— 嗜血狂花的花朵精灵（MeshInstance3D + QuadMesh）
// ============================================================================
// 替代 Sprite3D 的五件事：
//   1) **生长过渡**：两张贴图（flower_a / flower_b）+ sweep 0~1，噪声软边按"根部 -> 顶部"
//      扫过（枯萎时反过来从上往下），换帧不再是硬切图。只有"花苞 -> 盛放"这一对用
//      radial = 1 的**径向揭开**：从花头质心向外接管，花瓣看起来是从中心向外长的，
//      也不会把小花苞的轮廓留在盛开的花头中间（纵向擦除会出那种重影）。
//   2) **摇曳**：顶点沿屏幕水平方向弯，越靠花头幅度越大（pow(bend, 1.7)），像萌发/抽穗；
//      bend 在土壤线处为 0 —— 根部钉死，不会被"摇"出地面。
//   3) **Y 轴广告牌**：自己算 MODELVIEW（只用相机绕 Y 的朝向），不依赖 Sprite3D 的
//      billboard 实现 —— MeshInstance3D + material_override 也照样始终面向相机、永远立着。
//   4) **花球埋地**：ground_cut 以下的像素直接裁掉（噪声软边），配合节点下沉，
//      根茎/种球看起来是从土里长出来的，而不是坐在地表。
//   5) **镜像 / 淡出**：flip_x 左右翻转（同一张贴图不至于整圈重复），fade 用于收尾淡出。
//
// 参数都由 blood_flower.gd 逐朵写入：同种花的不同株靠 sway_phase / sway_amp 区分。
// 注意：render_mode 用 blend_mix + depth_draw_never（花瓣软边），埋地部分靠上面的
//       裁切保证看不见，不依赖地面网格的深度遮挡。
// ============================================================================

shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;

/** 当前阶段贴图 / 下一阶段贴图（sweep = 1 时完全显示 flower_b） */
uniform sampler2D flower_a : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D flower_b : source_color, filter_linear_mipmap, repeat_disable;
/** 换帧进度：0 = 全是 A，1 = 全是 B；噪声软边从下往上扫过整张画布 */
uniform float sweep : hint_range(0.0, 1.0) = 0.0;
/** 0 = 从下往上长（生长），1 = 从上往下枯（枯萎） */
uniform float sweep_from_top : hint_range(0.0, 1.0) = 0.0;
/** 0 = 纵向擦除（整株长高），1 = 径向揭开（以花头质心为圆心的"花瓣向外绽放"） */
uniform float radial : hint_range(0.0, 1.0) = 0.0;
/** 花头质心在贴图里的 UV（实测 bloom 帧红花质心 = (0.534w, 0.274h)；镜像时取 1-x） */
uniform vec2 head_uv = vec2(0.534, 0.274);
/** 贴图画布宽高比（402/658 = 0.611）：径向距离要按真实宽高比量，否则揭开形状是椭圆 */
uniform float head_aspect = 0.611;
/** 底部埋进地下的比例（占画布高度）：blood_flower.gd 写 0.15 ≈ 根须 + 大半个种球 */
uniform float ground_cut : hint_range(0.0, 0.5) = 0.15;
/** 世界尺寸（米）：x = 画布宽度，y = 画布高度（QuadMesh 单位方片由顶点阶段放大） */
uniform vec2 flower_size = vec2(0.92, 1.5);
/** 摇曳：最大横向偏移（米）、角速度（弧度/秒）、相位（每朵随机） */
uniform float sway_amp = 0.06;
uniform float sway_speed = 1.6;
uniform float sway_phase = 0.0;
/** 收尾淡出（1 = 完整，0 = 看不见），由 _update_fade 逐帧压低 */
uniform float fade : hint_range(0.0, 1.0) = 1.0;
/** 水平镜像（0 = 原样，1 = 左右翻转）：让整圈花不是同一张贴图复制出来的 */
uniform float flip_x : hint_range(0.0, 1.0) = 0.0;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash21(i);
	float b = hash21(i + vec2(1.0, 0.0));
	float c = hash21(i + vec2(0.0, 1.0));
	float d = hash21(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

void vertex() {
	// QuadMesh 是单位方片：先按每朵花的世界尺寸放大
	VERTEX.x *= flower_size.x;
	VERTEX.y *= flower_size.y;

	// 摇曳：土壤线（UV.y = 1 - ground_cut）处为 0，越靠花头越大；两个频率叠一起避免机械感
	float ground_v = 1.0 - ground_cut;
	float bend = clamp((ground_v - UV.y) / max(ground_v, 0.001), 0.0, 1.0);
	float wave = sin(TIME * sway_speed + sway_phase + UV.y * 3.2)
			+ 0.35 * sin(TIME * sway_speed * 1.9 + sway_phase * 1.7 + UV.y * 5.1);
	VERTEX.x += sway_amp * pow(bend, 1.7) * wave;

	// Y 轴固定广告牌：保留相机绕 Y 的朝向，去掉俯仰/翻滚（花永远立着）
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		normalize(vec4(INV_VIEW_MATRIX[0].xyz * vec3(1.0, 0.0, 1.0), 0.0)),
		vec4(0.0, 1.0, 0.0, 0.0),
		normalize(vec4(INV_VIEW_MATRIX[2].xyz * vec3(1.0, 0.0, 1.0), 0.0)),
		MODEL_MATRIX[3]);
	MODELVIEW_NORMAL_MATRIX = mat3(MODELVIEW_MATRIX);
}

void fragment() {
	// 花球/根须埋到地下：土壤线以下直接裁掉，边界加一点噪声，避免一条笔直的切口
	float soil = 1.0 - ground_cut + (vnoise(UV * vec2(14.0, 6.0)) - 0.5) * 0.012;
	if (UV.y > soil) {
		discard;
	}
	vec2 uv = vec2(abs(flip_x - UV.x), UV.y);

	vec4 a = texture(flower_a, uv);
	vec4 b = texture(flower_b, uv);

	// 生长过渡：edge 从 -0.16 涨到 1.16，B 从"最靠根部/圆心"的一端开始接管。
	// 注意这里是 1 - smoothstep：coord/rad 越小越先换成 B（从下往上长、从花心向外开）。
	float coord = mix(1.0 - UV.y, UV.y, sweep_from_top);
	float edge = mix(-0.16, 1.16, sweep);
	float n = (vnoise(uv * vec2(6.5, 3.5)) - 0.5) * 0.10;
	float mv = 1.0 - smoothstep(edge - 0.12, edge + 0.12, coord + n);

	// 径向揭开：以花头质心为圆心、按画布宽高比量真实距离（花苞 -> 盛放时花瓣就是
	// 绕花心向外长，所以径向揭开时内外圈自然对上，不会留小花苞的轮廓）
	vec2 hp = vec2((uv.x - head_uv.x) * head_aspect, uv.y - head_uv.y);
	float rad = length(hp) / 0.30;
	float mr = 1.0 - smoothstep(edge - 0.12, edge + 0.12, rad + n);
	float m = mix(mv, mr, radial);

	float alpha = mix(a.a, b.a, m);
	if (alpha < 0.02) {
		discard;
	}
	// 预乘后混合，避免透明区黑边在过渡时被"拖"进来
	vec3 prem = mix(a.rgb * a.a, b.rgb * b.a, m);
	ALBEDO = prem / max(alpha, 0.0001);
	ALPHA = alpha * fade;
}
