shader_type spatial;

// ============================================================================
// 蝴蝶双翅（ButterflySwarm 专用）—— 折叠 + 立体感
//
// 素材是「正面展开的蝴蝶」（模型空间 x = 翅展、y = 头尾、初始法线 +Z）。
// 直接贴平面就是一块纸片：没有厚度、没有弯曲、侧视几乎消失。本着色器给三件事：
//   ① 折叠：绕体轴（模型 +Y）各转 ±dihedral，两翅抬成 V（书脊朝下、双翅上举）。
//   ② 弧度 camber：二面角**随翼展位置线性增长**（根部平、翅尖上翘）-> 翅面是曲面。
//      曲面才有明暗渐变，这是"体积感"最大的来源（平板永远是一片均匀色）。
//   ③ 厚度 thickness：沿曲面法线按 FRONT_FACING 向外/向内各推 half_t ->
//      这层壳有真实厚度，边缘环是"侧壁"，侧视不再是一条线。
//   另外还有一个廉价版 AO：厚度侧壁（边缘环）在片元里压暗（v_rim），
//   以及一点镜面高光（配合曲面法线会出现随姿态移动的高光条）。
//
// ★★ 空间归属（必读）★★
//   Godot 4 的 spatial 顶点阶段里 **`VERTEX` 进来就已经是视图空间**，
//   片元的 `NORMAL / VERTEX` 也是视图空间。
//   所以：**所有折叠/弧度/旋转都在"模型空间"用解析式算完**，最后用
//     `p_view = (MODELVIEW_MATRIX * vec4(p_model, 1.0)).xyz`
//   一次性搬进视图空间；法线用 `MODELVIEW_MATRIX` 的线性部分搬。
//   ⚠ 不要对 `VERTEX` 直接写 `vec3(x*c, y, -x*s)` 这类"假设 VERTEX 是模型空间"的式子 ——
//     节点一旦带旋转/缩放，算出来的就不是你要的那个折。
//
// 接口冻结：uniform 名字与折叠数学见 addons/butterfly_swarm/CONTRACT.md §1/§2。
// ============================================================================

// render_mode：cull_disabled（薄翅双面）/ depth_prepass_alpha / blend_mix（ALPHA 才是软边）
//   ✗ 不写 shadows_disabled（4.7 是否支持未核实，写错整份着色器编译失败）
//   ✗ 不写 unshaded（要受光 —— 明暗渐变正是体积感的来源）
render_mode blend_mix, cull_disabled, depth_prepass_alpha;

// ---- uniforms --------------------------------------------------------------
uniform sampler2D albedo_tex : source_color, filter_linear_mipmap, repeat_disable, hint_default_white;
uniform vec2 tex_scale = vec2(1.0, 1.0);
uniform vec2 tex_offset = vec2(0.0, 0.0);
uniform float dihedral : hint_range(0.0, 180.0) = 30.0;  // 二面角（度）：**根部**角度
uniform float camber = 0.0;                 // 弧度：二面角沿翼展的增量系数（0.3 ≈ 翅尖比根部多抬 ~30%）
uniform float fold_dz = 0.0;                // 额外前后折出量（模型单位）
uniform float bend_y = 0.0;                 // 头尾方向弯拱（保留）
uniform float thickness = 0.0;              // 【已弃用】厚度改为 GDScript 侧的闭合外壳；此 uniform 仅为兼容契约保留，着色器不再使用
uniform float flutter_u = 1.0;
uniform float flutter_v = 1.0;
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
uniform float alpha : hint_range(0.0, 1.0) = 1.0;
uniform float iridescence : hint_range(0.0, 1.0) = 0.25;
uniform float backlight : hint_range(0.0, 1.0) = 0.15;
// 面向镜头自适应（抵消"薄片侧对镜头就消失"）
uniform vec3 view_dir = vec3(0.0, 0.0, -1.0);   // 相机->蝴蝶 在**模型本地**空间的单位方向
uniform float min_edge : hint_range(0.0, 1.0) = 0.25;  // 最小正对度
uniform float sprite_rot = 0.0;                 // GDScript 算出的额外面内旋转（弧度）
uniform float rim : hint_range(0.0, 1.0) = 0.55;       // 边缘环压暗强度（廉价 AO）

varying float v_rim;   // 1 = 属于厚度侧壁/边缘环

void vertex() {
	// ============================================================
	// 全部在**模型空间**算完，最后一次性搬进视图空间
	// ============================================================
	float x0 = VERTEX.x;
	float y0 = VERTEX.y;

	// 1) flutter（翼展/头尾形变；UV 在末尾同步）
	float x1 = x0 * flutter_u;
	float y1 = y0 * flutter_v;

	// 2) 自适应面内自转：绕模型 +Z 把翅面转向镜头。
	//    view_dir = 相机-蝴蝶 在模型本地空间的方向；|z| ≈ 1 = 正对/背对镜头（不用转），
	//    ≈ 0 = 侧对镜头（要转到 min_edge 的最小正对度）。
	//    自转不改变飞行朝向，只改变"翅面朝哪边"，所以飞行姿态不受影响。
	float facing = abs(view_dir.z);
	float k = 1.0;
	if (facing < min_edge) {
		float want = sqrt(max(0.0, 1.0 - min_edge * min_edge));
		// max(0.15, ...)：facing→1 时分母趋 0，会算出巨大 k；这里封住上界，
		// 保证"接近正对时不再额外转"（否则会看到蝴蝶突然甩头）
		k = want / max(0.15, sqrt(max(0.0, 1.0 - facing * facing)));
	}
	float srot = sprite_rot * k;
	float cs = cos(srot);
	float ss = sin(srot);
	// 在模型 XY 面内转
	vec2 xy = vec2(x1 * cs - y1 * ss, x1 * ss + y1 * cs);
	float x2 = xy.x;
	float y2 = xy.y;
	// 注：静止法线是 +Z，而"绕 Z 轴旋转"不会改变 +Z 方向，所以这里**不需要**改法线的静止值；
	//     真正的法线由第 4 步按折叠角解析求出。

	// 3) 折叠 + 弧度：绕模型 +Y 转 a；**a 随翼展位置增长**（camber）-> 曲面而不是平板
	//    ★ 符号：`a = -(th + camber·|x|·camber_base) · sign(x)`
	//      代入绕 +Y 的旋转 x' = x·cos a、z' = −x·sin a：
	//        右翅 x>0, a=−θ  ->  z' = +x·sinθ > 0 ✓
	//        左翅 x<0, a=+θ  ->  z' = −(−|x|)·sinθ = +|x|·sinθ > 0 ✓
	//      两翅都朝 **+Z 抬起** -> V 的开口朝向 +Z（额面法线方向，也是相机常在的一侧）。
	//      ⚠ 这个符号曾经写反过（两翅一起折向 −Z，等于从背后看 V）——
	//      这类符号**不要靠脑内推**：tests 里有『折叠离面 + 左右对称 + 折向 +Z』三条断言钉住它。
	//    ★ camber 的基准角用 `max(th, 30°)`：否则张翼角调到 0（完全平飞）时曲率一起归零、翅面变平板。
	float th = radians(dihedral);
	float camber_base = max(th, 0.5235988);   // 30°
	float x_span = x2;                                          // 翼展坐标（中点 0）
	float fold_a = -(th + camber * abs(x_span) * camber_base) * sign(x_span);
	float c = cos(fold_a);
	float s = sin(fold_a);
	// 绕 +Y 的切向；y 方向切向带上 bend_y 的斜率（弯拱）
	vec3 tx = vec3(c, 0.0, -s);
	vec3 ty = vec3(0.0, 1.0, 2.0 * bend_y * y2);
	vec3 pm = vec3(x_span * c, y2, -x_span * s);
	pm.z += fold_dz * x_span + bend_y * y2 * y2;

	// 4) 解析法线（与切向同源）：曲面法线 = 两切向的叉乘
	//    ⚠ 契约 §2 曾把它写成 (sin a, 0, cos a)，那与 (x·c, y, −x·s) 的旋转**不同源**
	//      （差一个 x 分量符号，会让左右两翅的受光不对称）。这里用叉乘并从几何上求出，
	//      再统一朝向 +Z（保证两翅法线一致、双面翻转才有正确的语义）。
	vec3 nm = normalize(cross(tx, ty));
	if (nm.z < 0.0) {
		nm = -nm;
	}

	// 5) 搬进视图空间
	mat4 m = MODELVIEW_MATRIX;
	vec3 p_view = (m * vec4(pm, 1.0)).xyz;
	vec3 n_view = normalize((m * vec4(nm, 0.0)).xyz);

	// 6) 厚度**不在着色器里做**（见文件头：闭合外壳已由 GDScript 生成）。
	//    ⚠ 不要在顶点阶段尝试 `FRONT_FACING`：Godot 的顶点阶段没有这个内建量，
	//      写它会 `Unknown identifier in expression: 'FRONT_FACING'` 并让整份着色器编译失败（实测）。
	VERTEX = p_view;
	NORMAL = n_view;

	// 7) 边缘环（厚度侧壁）标记 —— 用**原始 UV** 判定最稳（网格外围一圈就是侧壁）
	v_rim = (UV.x < 0.02 || UV.x > 0.98 || UV.y < 0.02 || UV.y > 0.98) ? 1.0 : 0.0;

	// 8) UV 裁剪（契约 §2 冻结的那一行；flutter 的 UV 缩放发生在裁剪之前）
	UV = UV * vec2(flutter_u, flutter_v) * tex_scale + tex_offset;
	// ★ 侧壁顶点在裁剪后正好压在 cropped UV 的边界上，浮点误差会让它采到**相邻素材**的像素
	//   （精灵表里旁边就是另一只蝴蝶）。这里把侧壁的采样点往里收 1.5%，
	//   让它采到本只蝴蝶自己的边缘像素 —— 看起来正好像"一圈变暗的厚度边"。
	vec2 inset = vec2(0.015) * tex_scale;
	vec2 lo_uv = tex_offset + inset;
	vec2 hi_uv = tex_offset + tex_scale - inset;
	UV = mix(UV, clamp(UV, lo_uv, hi_uv), v_rim);
}

void fragment() {
	vec4 tex = texture(albedo_tex, UV);

	// ★ 必须用 PNG 的 alpha 裁形（20 张素材本身就是真透明底）
	ALPHA = tex.a * alpha;
	// ✗ 不写 ALPHA_SCISSOR_THRESHOLD：写了材质会走 alpha-scissor（不透明）管线，
	//   alpha 只剩遮罩语义、不再混色（实测亮度比 1.010 vs 真混色 0.570）。

	ALBEDO = tex.rgb * tint.rgb;
	// 边缘环 / 厚度侧壁压暗 —— 廉价版 AO，让"有厚度"在画面上真的看得见
	ALBEDO *= mix(1.0, 0.5, v_rim * rim);

	METALLIC = 0.0;
	// 薄翅带一点光泽：配合曲面法线会出现随姿态移动的高光，进一步坐实"这是立体物"
	ROUGHNESS = 0.55;
	SPECULAR = 0.45;

	// 双面渲染：背面翻转法线（契约硬性要求）
	if (!FRONT_FACING) {
		NORMAL = -NORMAL;
	}

	// 掠射角虹彩：**只进 EMISSION，绝不改写 ALBEDO**（否则大面积掠射会把蓝色染紫红）
	float ndv = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float graze = pow(1.0 - ndv, 3.0);
	vec3 hue = 0.5 + 0.5 * cos(6.2831853 * (vec3(0.0, 0.33, 0.67) + graze * 1.25));

	// 逆光透光：片元拿不到光源方向，用掠射角近似
	EMISSION += ALBEDO * (backlight * 0.30 * (0.25 + 0.75 * graze));
	EMISSION += hue * (iridescence * 0.22 * graze);
}
