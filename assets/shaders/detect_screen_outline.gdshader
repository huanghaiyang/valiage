shader_type spatial;
// 物体探测的**屏幕空间描边** —— 全屏后处理，靠深度突变找轮廓。
//
// 【为什么放弃几何描边（material_overlay + 外扩壳）】
//   它只渲染外扩壳的**背面**（cull_front），再查深度去掉内部。对方箱来说
//   "背面" = 远侧面 + 底面：
//     · 远侧面的外扩壳 -> 只在**远侧**露出来
//     · 底面的外扩壳 -> 本该在近侧/四周露出来，却被**地面深度**挡掉了
//   于是边线只出现在背向镜头的一侧 —— 用户报的就是这个。它是几何决定的，调参无解。
//
// 【屏幕空间的做法】
//   取深度纹理拿到每个像素的**视深度**，和上下左右四个邻居比：
//   梯度大 => 这里是某个物体的轮廓 => 画线。
//   好处：与相机角度完全无关、**四周都有线**、线宽是**固定像素**（远近一致）。
//
// 【逐步揭示】wave_center / wave_radius 做门控：只有被波纹扫过的屏幕区域才画线，
//   所以观感仍然是"波纹推过去、轮廓逐步长出来"。
//
// 【实现方式】相机下挂一个覆盖视野的四边形（depth_test_disabled，画在最上层），
//   ALPHA=0 的地方完全透明。
//
// 注意：fragment 里**不能写 `return`**（Godot 会直接编译失败），只能 if/else。
render_mode unshaded, depth_test_disabled, cull_disabled, shadows_disabled,
		ambient_light_disabled, fog_disabled;

uniform sampler2D depth_tex : hint_depth_texture;
uniform vec3 line_color : source_color = vec3(0.30, 0.95, 1.0);
uniform float line_alpha : hint_range(0.0, 1.0) = 0.9;

/// 视口尺寸（像素），由脚本每帧写入 —— 用来把"像素偏移"换算成 UV 偏移
uniform vec2 screen_size = vec2(1280.0, 720.0);
/// 邻域采样偏移（像素）：越大线越粗
uniform float sample_px : hint_range(0.5, 6.0) = 1.6;
/// 视深度梯度阈值（米）：越小线越多（噪声也多）
uniform float depth_threshold : hint_range(0.02, 8.0) = 0.6;

uniform vec3 wave_center = vec3(0.0);
uniform float wave_radius = 0.0;
uniform float reveal_soft : hint_range(0.0, 3.0) = 0.35;

// ---- 物体遮罩：只画"本帧被探测到的物体"真实覆盖到的像素 ----
// 【为什么要遮罩】这是纯深度边缘检测，被波扫过的屏幕区域里**所有**深度突变都会出线，
//   包括**没有碰撞体的花草**（用户报过"草也被探测到了"）。
// 【为什么不用矩形】一开始传的是物体的屏幕 AABB 矩形，但大件物体的矩形覆盖范围很大，
//   落在矩形里的草照样被描出来 —— 近似不够用。改成真正的遮罩图：
//   脚本把被探测到的物体渲进一张 SubViewport 纹理，这里按像素判定。
// 【为什么要采样邻居】轮廓线正好压在物体边缘，**有一半落在物体之外**，
//   只查当前像素会把线裁掉一半，所以连同深度采样用的四个邻居一起查。
uniform sampler2D mask_tex : hint_default_black;
uniform bool mask_enabled = false;
/// mask 图里"算作在物体内"的阈值。透明背景处 RGB 恰好为 0，
/// 物体即使很暗也远大于 0，所以取个极小值最稳。
/// ★ 别用 0.5 之类的高阈值：物体是受光后的暗色，会被判成"不在遮罩里"→ 一条线都没有。
uniform float mask_threshold : hint_range(0.0, 0.5) = 0.005;

// ---- 被探测物体的**世界 AABB**：只画"这个像素真的落在某个物体体积内"的线 ----
// 【为什么光有遮罩图不够】遮罩是**二维屏幕区域**：围栏/遗迹这类大件在屏幕上占很大面积，
//   而**落在物体正前方或正后方的草，在同一块屏幕区域里** —— 它的深度突变照样会被画成线。
//   实测遮罩覆盖率 34%，草依然被描，就是这个原因。
// 【这里怎么做】用深度纹理反推每个像素的**世界坐标**，看它是否落在某个被探测物体的
//   世界 AABB 内（外扩 box_pad 吸收抗锯齿边缘）。草在物体前后 -> 世界坐标不在体积内 -> 排除。
//   轮廓线跨在物体边缘上，所以当前像素和四个邻居里**任一**落在体积内就保留。
uniform int box_count = 0;
uniform vec4 box_min[16];
uniform vec4 box_max[16];
uniform float box_pad : hint_range(0.0, 1.0) = 0.15;

float mask_at(vec2 uv) {
	vec4 c = texture(mask_tex, uv);
	return max(max(c.r, c.g), max(c.b, c.a));
}

void fragment() {
	vec2 off = vec2(sample_px) / max(screen_size, vec2(1.0));

	// ★ 这几行**必须内联在 fragment() 里**，不能抽成用户函数：
	//   实测把 INV_PROJECTION_MATRIX 放进 helper 函数会报
	//   "Unknown identifier in expression: 'INV_PROJECTION_MATRIX'"（Godot 的着色器
	//   内置量只在阶段入口函数的作用域里可见）。
	vec4 upc = INV_PROJECTION_MATRIX * vec4(SCREEN_UV * 2.0 - 1.0,
			textureLod(depth_tex, SCREEN_UV, 0.0).r, 1.0);
	float zc = -(upc.xyz / upc.w).z;
	vec2 uvl = SCREEN_UV - vec2(off.x, 0.0);
	vec4 upl = INV_PROJECTION_MATRIX * vec4(uvl * 2.0 - 1.0,
			textureLod(depth_tex, uvl, 0.0).r, 1.0);
	float zl = -(upl.xyz / upl.w).z;
	vec2 uvr = SCREEN_UV + vec2(off.x, 0.0);
	vec4 upr = INV_PROJECTION_MATRIX * vec4(uvr * 2.0 - 1.0,
			textureLod(depth_tex, uvr, 0.0).r, 1.0);
	float zr = -(upr.xyz / upr.w).z;
	vec2 uvu = SCREEN_UV - vec2(0.0, off.y);
	vec4 upu = INV_PROJECTION_MATRIX * vec4(uvu * 2.0 - 1.0,
			textureLod(depth_tex, uvu, 0.0).r, 1.0);
	float zu = -(upu.xyz / upu.w).z;
	vec2 uvd = SCREEN_UV + vec2(0.0, off.y);
	vec4 upd = INV_PROJECTION_MATRIX * vec4(uvd * 2.0 - 1.0,
			textureLod(depth_tex, uvd, 0.0).r, 1.0);
	float zd = -(upd.xyz / upd.w).z;

	float g = max(max(abs(zc - zl), abs(zc - zr)),
			max(abs(zc - zu), abs(zc - zd)));

	// ---- 画线：UE "Custom Depth + Stencil" 后处理的 Godot 等价实现 ----
	//
	// UE 里的做法（公开资料）：把要描边的物体勾上 Render CustomDepth Pass，
	// 它们被单独渲进 Custom Depth/Stencil 缓冲；后处理材质用
	// SceneTexture:CustomDepth 在**四/八邻域**取样，中心与邻居不同 -> 就是轮廓，
	// 再靠 stencil 值把"只要这一类物体"筛出来，最后做一次 dilation 让线有厚度。
	//
	// Godot 没有 Custom Depth/Stencil，等价物就是：
	//   layers(位) + SubViewport + 一台 cull_mask 只开该位的相机 = 专用的 mask 通道。
	//   然后对**这张 mask 图**做邻域边缘检测 —— 它里面只有被探测到的物体，
	//   屏幕上的草/地形根本不在其中，所以一个像素都不会被描（结构性排除）。
	//
	// ★ mask 图必须只在 GPU 端采样，**不要用 get_image() 判断它对不对**：
	//   Godot 未修复的 #91828：transparent_bg 打开时 Viewport.get_texture() 的
	//   CPU 回读数据不可信（会全 0），而着色器里采样是正常的。我上一轮就是被这个
	//   回读骗了，误判成"遮罩没渲染"，然后把好端端的方案关掉了。
	float edge_depth = smoothstep(depth_threshold * 0.55, depth_threshold, g);
	float a = edge_depth;
	float mc = mask_at(SCREEN_UV);
	if (mask_enabled) {
		// 八邻域：比四邻域更容易得到连续的线（UE 里也是 4/8 邻域取 max）
		float mn = 0.0;
		mn = max(mn, mask_at(SCREEN_UV + vec2(off.x, 0.0)));
		mn = max(mn, mask_at(SCREEN_UV - vec2(off.x, 0.0)));
		mn = max(mn, mask_at(SCREEN_UV + vec2(0.0, off.y)));
		mn = max(mn, mask_at(SCREEN_UV - vec2(0.0, off.y)));
		mn = max(mn, mask_at(SCREEN_UV + off));
		mn = max(mn, mask_at(SCREEN_UV - off));
		mn = max(mn, mask_at(SCREEN_UV + vec2(off.x, -off.y)));
		mn = max(mn, mask_at(SCREEN_UV + vec2(-off.x, off.y)));
		// 中心在物体内、八邻域里至少一个在外面 -> 轮廓（线贴在物体外缘，约 1px）
		float mask_edge = step(mask_threshold, mc) * (1.0 - step(mask_threshold, mn));
		// ★ 用 max 而不是替换：mask 通道是**主路径**（草结构性排除）；
		//   深度边缘是**托底** —— 万一 mask 通道在某个平台/引擎版本上失效，
		//   也不至于"一条轮廓线都画不出来"（这个坑我踩过）。
		a = max(mask_edge, edge_depth);
	} else {
		// 没有 mask 通道时才纯靠深度突变（会把草、地形一起描出来）
		a = edge_depth;
	}

	// 波面揭示：只有被扫过的屏幕区域才有线
	vec3 wp = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float dist = distance(wp.xz, wave_center.xz);
	a *= 1.0 - smoothstep(wave_radius - reveal_soft, wave_radius + reveal_soft, dist);

	// 物体遮罩与 AABB 过滤都已不再需要：上面直接用遮罩边界画线，
	// 草与地形压根不在遮罩里，无需再"过滤掉它们"。
	// （下面这段三维判定在**没有遮罩**时才是主力，见 box_count 的注释。）
	if (box_count > 0) {
		float inside = 0.0;
		for (int s = 0; s < 5; s++) {
			vec2 uv = SCREEN_UV;
			if (s == 1) {
				uv -= vec2(off.x, 0.0);
			} else if (s == 2) {
				uv += vec2(off.x, 0.0);
			} else if (s == 3) {
				uv -= vec2(0.0, off.y);
			} else if (s == 4) {
				uv += vec2(0.0, off.y);
			}
			float sd = textureLod(depth_tex, uv, 0.0).r;
			// 注意：INV_PROJECTION_MATRIX / INV_VIEW_MATRIX 只能内联在 fragment 里用
			// （Godot 限制：放进用户函数会报 Unknown identifier）
			vec4 vpos = INV_PROJECTION_MATRIX * vec4(uv * 2.0 - 1.0, sd, 1.0);
			vec3 wp = (INV_VIEW_MATRIX * vec4(vpos.xyz / vpos.w, 1.0)).xyz;
			for (int i = 0; i < 16; i++) {
				if (i >= box_count) {
					break;
				}
				vec3 lo = box_min[i].xyz - vec3(box_pad);
				vec3 hi = box_max[i].xyz + vec3(box_pad);
				if (wp.x >= lo.x && wp.x <= hi.x && wp.y >= lo.y && wp.y <= hi.y
						&& wp.z >= lo.z && wp.z <= hi.z) {
					inside = 1.0;
					break;
				}
			}
			if (inside > 0.5) {
				break;
			}
		}
		a *= inside;
	}

	ALBEDO = line_color;
	ALPHA = clamp(a * line_alpha, 0.0, 1.0);
}
