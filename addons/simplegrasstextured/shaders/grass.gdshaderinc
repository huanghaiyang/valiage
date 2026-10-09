/* grass.gdshaderinc
This file is part of: SimpleGrassTextured
Copyright (c) 2023 IcterusGames

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.*/

#ifndef FILTER_TYPE
#define FILTER_TYPE filter_linear_mipmap
#endif

uniform vec4 albedo : source_color = vec4(1.0);
uniform sampler2D texture_albedo : source_color,FILTER_TYPE,repeat_disable;
uniform sampler2D texture_normal : hint_roughness_normal,FILTER_TYPE,repeat_enable;
uniform sampler2D texture_metallic : hint_default_white,FILTER_TYPE,repeat_enable;
uniform sampler2D texture_roughness : hint_roughness_r,FILTER_TYPE,repeat_enable;
uniform vec2 texture_frames = vec2(1.0,1.0);
uniform int light_mode = 0;
uniform float alpha_scissor_threshold = 0.5;
uniform float normal_scale : hint_range(-16,16) = 1.0;
uniform float metallic : hint_range(0,1) = 0.0;
uniform vec4 metallic_texture_channel = vec4(1.0, 0.0, 0.0, 0.0);
uniform float roughness : hint_range(0,1) = 1.0;
uniform vec4 roughness_texture_channel = vec4(1.0, 0.0, 0.0, 0.0);
uniform float specular : hint_range(0,1) = 0.0;
uniform float scale_h = 1.0;
uniform float scale_w = 1.0;
uniform float scale_var : hint_range(-1.0, 1.0) = -0.25;
uniform float grass_strength : hint_range(0.0, 1.0) = 0.55;
uniform bool optimization_by_distance = false;
uniform float optimization_level = 7.0;
uniform float optimization_dist_min = 10.0;
uniform float optimization_dist_max = 50.0;
uniform float grass_size_y = 1.0;
uniform bool interactive_mode = true;
uniform float interactive_level_xz = 3.0;
uniform float interactive_level_y = 0.3;

global uniform vec3 sgt_player_position = vec3(100000.0);
global uniform vec3 sgt_player_mov = vec3(0.0);
// ★ 2026-10-08：玩家倒伏/分开改用**逐材质 uniform**（同 sgt_wind_* 的原因与做法）
//   原来 `sgt_player_position` 声明成 global uniform，而 scripts/wind.gd 写的是逐材质同名参数
//   → 两个不同 uniform，写了没用；加上全局参数在 4.7 运行时本就是坏的（见文件顶部注释）
uniform vec3 sgt_player_pos = vec3(1.0e9);      // 玩家世界坐标
uniform float sgt_player_bend_radius = 1.4;     // 影响半径（米）
uniform float sgt_player_bend = 1.0;            // 沿移动方向倒伏（米级手柄）
uniform float sgt_player_radial = 1.2;          // 径向分开（米级手柄）
uniform float sgt_player_gain = 0.10;           // 位移总增益（收敛量级，见 wind.gd 的写入值）
// ★★ 本项目改动：角色被草遮挡时的 1px 褐色轮廓
//   判定 = 草片在角色屏幕圆内 ∩ 草片在角色前面 ∩ 靠近圆的轮廓边缘 → 画褐色
//   屏幕量由 scripts/wind.gd 每帧算好，走**逐材质**通道（global uniform 在 4.7 运行时失效，本项目踩过）
uniform vec2 sgt_player_screen = vec2(-100000.0, -100000.0);  // 角色屏幕坐标（**视口逻辑坐标**，同 unproject_position）
uniform float sgt_player_screen_r = 0.0;        // 角色屏幕半径（**视口逻辑坐标单位**）
uniform float sgt_player_depth = 0.0;           // 角色视空间深度
uniform float sgt_occl_on = 0.0;                // 1 = 启用遮挡轮廓
uniform float sgt_occl_px = 1.0;                // 轮廓宽度（帧缓冲像素；<0 = 诊断涂满整圆）
uniform vec4 sgt_occl_color = vec4(0.30, 0.17, 0.09, 1.0);   // 褐色
uniform vec2 sgt_occl_vp_logical = vec2(1280.0, 720.0);       // 视口逻辑尺寸（unproject 所在空间）
uniform vec2 sgt_occl_vp_pixel = vec2(1280.0, 720.0);         // 帧缓冲像素尺寸（FRAGCOORD 所在空间）
global uniform sampler2D sgt_normal_displacement : repeat_disable, filter_nearest, hint_normal;
global uniform sampler2D sgt_motion_texture : repeat_disable, filter_nearest, hint_default_black;
uniform vec3 sgt_wind_direction = vec3(1.0, 0.0, 0.0);   // 改逐材质：Godot 4.7 运行时 global uniform 顶点阶段失效
uniform float sgt_wind_strength = 0.15;
uniform float sgt_wind_turbulence = 1.0;
uniform vec3 sgt_wind_movement = vec3(0.0, 0.0, 0.0);
uniform sampler2D sgt_wind_pattern : source_color, repeat_enable, filter_linear, hint_default_white;

varying vec2 uv_align;
varying vec2 uv_scale;
varying flat vec3 v_normal_grass;

// ---- 本项目新增：逐实例燃烧（读 MultiMesh 的 INSTANCE_CUSTOM）----
// 为什么加在这里：这个 include 被 8 个 grass 变体共用，改一处即可全覆盖。
// 逐实例进度由 scripts/vfx/foliage_burn.gd 用 set_instance_custom_data 写入：
//   x = burn 进度, y = ash 进度, z = 每实例随机相位
// 默认全 0 -> 不烧的草输出与改动前完全一致。
uniform vec3 burn_char_color : source_color = vec3(0.06, 0.05, 0.045);
uniform vec3 burn_ember_color : source_color = vec3(1.0, 0.32, 0.05);
uniform float burn_ember_gain : hint_range(0.0, 2.0) = 0.5;

varying float v_burn_amt;
varying float v_burn_ember;
varying float v_burn_kill;
/// ★ 消失/长回都用**缩放**：1 = 正常大小，0 = 缩到 0（贴着火根消失）
varying float v_burn_scale;
varying float v_sgt_player_w;

const highp float EPSILON = 0.0001;


float get_value(sampler2D tex, vec2 uv) {
	vec4 color = textureLod(tex, uv, 0);
	float value = round(color.r * 65280.0) + round(color.g * 255.0);
	return value;
}


float wrap(float value, float min, float max) {
	float range = max - min;
	if (range < EPSILON) {
		return min;
	}
	float result = value - (range * floor((value - min) / range));
	if (result >= max - EPSILON && result <= max + EPSILON) {
		return min;
	}
	return result;
}


void vertex() {
	v_sgt_player_w = 0.0;
	float lev = pow(abs((VERTEX.y - NODE_POSITION_WORLD.y) / grass_size_y), 1.7 + sgt_wind_strength);
	float rand = wrap(dot(NODE_POSITION_WORLD, NODE_POSITION_WORLD * 10.0), 0.0, 256.0);
	float randf = fract(rand);
	int randi = int(randf * 10.0);

	uv_align = vec2(float(randi % int(texture_frames.x)), float(int(randf * 100.0) % int(texture_frames.y)));
	uv_align /= texture_frames;
	uv_scale = vec2(1.0 / texture_frames.x, 1.0 / texture_frames.y);

	float text_wind = texture(sgt_wind_pattern, (vec2(NODE_POSITION_WORLD.x, NODE_POSITION_WORLD.z) * 0.005) - sgt_wind_movement.xz).r;
	// ★★ 2026-10-08 重写风位移，对齐本项目的 assets/shaders/grass_wind.gdshader（已验证可用）
	//   原公式的问题：静态推力占大头（约 lev×0.04），随时间变化的摆动项只有 sin×0.01
	//   → 表现同时是「倒伏过狠」+「摆动看不出来」✗
	//   新公式（与原版同一个设计）：
	//     along 恒为正（0.3~1.0，均值≈0.65）→ 位移始终沿风向"呼吸"，不会左右抽动；
	//     摆动来自 (1) lev 的高度权重 (2) gust 阵风包络 (3) 频率里的位置相位，每株不同步。
	//   幅度基准：高度 × 0.22 × 风强（风强 0.18 的小风 ≈ 每米高 4 厘米）。
	float w_turb = clamp(sgt_wind_turbulence, 0.0, 1.0);
	vec3 w_dir3 = normalize(sgt_wind_direction + vec3(0.0001, 0.0, 0.0001));
	vec2 w_dir = w_dir3.xz;
	float w_speed = 1.4;
	// ★ 沿风向的相位梯度：让风"一阵一阵扫过"整片草（相邻草叶不同步 → 看得见波动）。
	//   只跟风向上的投影有关：垂直风向的草叶同步 ✓ 沿风向的草叶依次错开 ✓
	float w_row = dot(NODE_POSITION_WORLD.xz, w_dir) * 0.16;
	// 阵风：幅度在 0.55..1.45 之间起伏，叠加位置相位 → 波纹从草场一侧推向另一侧
	float w_gust = 1.0 + 0.9 * (0.5 + 0.5 * sin(TIME * w_speed * 0.55 - w_row + sgt_wind_movement.y * 0.8));
	// 草越"硬"（grass_strength 越大）越不易被吹动：0.55 时约打八折
	float w_stiff = clamp(1.0 - grass_strength * 0.35, 0.3, 1.0);
	float w_amp = sgt_wind_strength * w_gust * w_stiff;
	// 沿风向：呼吸项带位置相位（可见的"推—回"），静态 0.65 保证不会反向
	float w_along = sin(TIME * w_speed - w_row * 0.8) * 0.55 + 0.65;
	// 垂直风向：小幅左右晃，幅度由 turbulence 决定
	float w_across = cos(TIME * w_speed * 0.83 - w_row * 0.6) * w_turb;
	vec2 w_sway = w_dir * w_along + vec2(-w_dir.y, w_dir.x) * (w_across * 0.25);
	// 地形起伏用原本的风图案叠一点，让整片草有"波浪"感（可关：系数 0.3 很小）
	// ★ 想整体调幅度就改下面这个 0.22（≈每米高出多少米的位移；原版 grass_wind 用同一个值）
	float w_sway_scale = 0.22 * (1.0 + (text_wind - 0.5) * 0.3);
	float w_dist = (VERTEX.y - NODE_POSITION_WORLD.y) * w_sway_scale * w_amp;
	VERTEX.x += w_sway.x * w_dist * lev;
	VERTEX.z += w_sway.y * w_dist * lev;

	vec3 align = VERTEX - NODE_POSITION_WORLD;
	float scale_rand = ((float(randi % 5) / 5.0) * scale_var);
	float dist = 1.0;
	if(optimization_by_distance) {
		float node_dist = distance(NODE_POSITION_WORLD, MAIN_CAM_INV_VIEW_MATRIX[3].xyz);
		dist = 1.0 - clamp(float(randi % int(max(1.0, node_dist / optimization_level))), 0.0, 1.0);
		dist *= smoothstep(optimization_dist_max, optimization_dist_min, node_dist);
	}

	vec3 scale = vec3(scale_w, scale_h, scale_w) * (1.0 + scale_rand);
	VERTEX = NODE_POSITION_WORLD + (align * dist * scale);

	if(dist > 0.0) {
		// ★★ 2026-10-08 角色倒伏/分开（最终版）
		//   ① 用世界坐标直接算到玩家的水平距离（这一步 VERTEX 已是世界坐标）
		//   ② 权重 w = (1 - 距离/半径)² 并 clamp 0..1 —— 不用 smoothstep，也不拿 dist/lev 当门限
		//      （前两版就是被 smoothstep 区间 + w*lev*dist 那套门限吃成了 0，所以完全没效果）
		//   ③ 位移 = 径向分开 + 沿移动方向倒伏，统一乘 sgt_player_gain 收敛量级
		float pr = max(0.05, sgt_player_bend_radius);
		vec3 dp = VERTEX - sgt_player_pos;
		dp.y = 0.0;
		float pd = length(dp);
		float w = clamp(1.0 - pd / pr, 0.0, 1.0);
		w = w * w;
		if(w > 0.0005) {
			float p_gain = clamp(sgt_player_gain, 0.0, 2.0);
			vec2 push = (pd > 0.0001) ? (dp.xz / pd) : vec2(0.0);
			// ① 径向分开：以玩家为圆心往外推
			VERTEX.xz += push * (w * sgt_player_radial * p_gain);
			// ② 沿移动方向倒伏（站着不动 → 位移为 0，自动回弹）
			vec2 mv = sgt_player_mov.xz;
			float mlen = length(mv);
			if(mlen > 0.0001) {
				VERTEX.xz += (mv / mlen) * (w * sgt_player_bend * p_gain * min(mlen * 8.0, 1.0));
			}
			// 贴着身体的一圈压低一点，视觉上像被拨开
			VERTEX.y -= (VERTEX.y - NODE_POSITION_WORLD.y) * w * 0.10 * p_gain;
			v_sgt_player_w = w;
		}
	}
	v_normal_grass = (MODELVIEW_MATRIX * vec4(0.0, 1.0, 0.0, 1.0)).xyz - NODE_POSITION_VIEW;

	// ★ 逐实例燃烧：INSTANCE_CUSTOM 只在**顶点阶段**可用，所以在这里算好、用 varying 传下去。
	//   噪声取实例的世界位置 -> 每个实例的斑点位置不同且固定（不会游走）。
	{
		float b = clamp(INSTANCE_CUSTOM.x, 0.0, 1.0);
		float a = clamp(INSTANCE_CUSTOM.y, 0.0, 1.0);
		float ph = INSTANCE_CUSTOM.z;
		float bn = fract(sin(dot(NODE_POSITION_WORLD.xz + vec2(NODE_POSITION_WORLD.y),
				vec2(12.9898, 78.233)) + ph) * 43758.5453);
		if (b > 0.001 || a > 0.001) {
			// ★ 焦黑与余烬**只在"正在烧"（b>0）时出现**：
			//   长回阶段是 b=0、a 从 1 递减 —— 那时草应该是正常的绿色在长大，
			//   不能还带着焦黑/火光（用户明确要求）。
			if (b > 0.001) {
				// ★ 阈值**就是 b**：bn < b 的区域被烧掉 —— b 从 0 长到 1，焦黑面积随之扩大。
				//   之前写成 thr = 1-b 且方向也反了：b=0 时几乎整株全黑、b=1 时又变回绿色
				//   （用户实测："草变黑之后又变绿了"）。焦黑必须随 b **单调增加**。
				v_burn_amt = 1.0 - smoothstep(b - 0.02, b + 0.02, bn);
				v_burn_ember = exp(-pow((bn - b) / 0.05, 2.0)) * burn_ember_gain * (1.0 - a);
			} else {
				v_burn_amt = 0.0;
				v_burn_ember = 0.0;
			}
			v_burn_kill = (a > 0.999) ? 1.0 : 0.0;
			// ★ 消失/长回都用**缩放**：ash=0 -> 1.0 正常大小，ash=1 -> 0.0 缩到根
			v_burn_scale = clamp(1.0 - a, 0.0, 1.0);
		} else {
			v_burn_amt = 0.0;
			v_burn_ember = 0.0;
			v_burn_kill = 0.0;
			v_burn_scale = 1.0;
		}
		// ★ 缩放要绕**该实例的根**做。这里的 VERTEX **已经是世界坐标**
		//   （addon 在本函数前面写了 VERTEX = NODE_POSITION_WORLD + offset），
		//   所以直接 *= s 会绕**世界原点**缩 = 向整片草地中心缩（实测踩过）。
		//   实例的根就是 NODE_POSITION_WORLD（addon 也用它当枢轴），绕它缩才对。
		vec3 burn_root = NODE_POSITION_WORLD;
		VERTEX.xz = burn_root.xz + (VERTEX.xz - burn_root.xz) * v_burn_scale;
		VERTEX.y = burn_root.y + (VERTEX.y - burn_root.y) * v_burn_scale;
	}
}


void light() {
	switch(light_mode) {
	case 0: // Lambert
		DIFFUSE_LIGHT += clamp(dot(NORMAL, LIGHT), 0.0, 1.0) * ATTENUATION * 0.3 * LIGHT_COLOR;
		break;
	case 1: // Normal grass
		DIFFUSE_LIGHT += clamp(dot(v_normal_grass, LIGHT), 0.0, 1.0) * ATTENUATION * 0.3 * LIGHT_COLOR;
		break;
	case 2: // Unshaded
		DIFFUSE_LIGHT = vec3(1.0);
		break;
	}
}


void fragment() {
	vec2 uv = (UV * uv_scale) + uv_align;
	vec4 albedo_tex = texture(texture_albedo, uv);
	ALBEDO = albedo.rgb * albedo_tex.rgb;
	// ★★ 本项目改动：角色被草遮挡时的 1px 褐色轮廓
	//   条件：① 这一像素落在角色的屏幕圆内
	//         ② 草片比角色**更靠近相机**（真的挡住了）
	//         ③ 处在圆的"边缘一圈"（宽度 = sgt_occl_px 像素）→ 只描边、不糊满
	//   这样草盖住角色的地方会出现一圈褐色，玩家能看清角色在哪。
	if (sgt_occl_on > 0.5) {
		// ⚠ 两套坐标系必须换算：
		//   · sgt_player_screen / _screen_r 来自 unproject_position() -> **视口逻辑坐标**（如 1280x720）
		//   · 这里的 FRAGCOORD 是**帧缓冲真实像素**（高 DPI 下如 3824x1982）
		//   实测二者的比例 ≈ 2.99，不做换算圆就会画到错误位置（表现为"完全看不到"）。
		vec2 oratio = sgt_occl_vp_pixel / max(sgt_occl_vp_logical, vec2(1.0, 1.0));
		vec2 ocenter_px = sgt_player_screen * oratio;
		float orad_px = sgt_player_screen_r * oratio.y;
		float od = length(FRAGCOORD.xy - ocenter_px);        // 到角色中心的像素距离
		float oedge = max(1.0, abs(sgt_occl_px));            // 轮廓宽度（像素）
		// ★ 诊断模式（sgt_occl_px < 0）：忽略深度与边缘判定，把整个圆涂色
		bool force_disk = sgt_occl_px < 0.0;
		// ⚠ render_mode 有 world_vertex_coords，fragment 里的 VERTEX 是世界坐标，
		//   不能当视空间深度；这里只用它做一个保守的"不画在角色身后"的判断。
		float ofrag = -VERTEX.z;
		if (od < orad_px && (force_disk || (ofrag < sgt_player_depth && od > orad_px - oedge))) {
			ALBEDO = sgt_occl_color.rgb;
			METALLIC = 0.0;
			ROUGHNESS = 1.0;
		}
	}
	NORMAL_MAP = texture(texture_normal, uv).rgb;
	NORMAL_MAP_DEPTH = normal_scale;
	METALLIC = metallic;
	ROUGHNESS = roughness;
	SPECULAR = specular;
	float metallic_tex = dot(texture(texture_metallic, uv), metallic_texture_channel);
	METALLIC = metallic_tex * metallic;
	float roughness_tex = dot(texture(texture_roughness, uv), roughness_texture_channel);
	ROUGHNESS = roughness_tex * roughness;
	ALPHA *= albedo.a * albedo_tex.a;
	ALPHA_SCISSOR_THRESHOLD = alpha_scissor_threshold;

	// ★ 逐实例燃烧：烧焦变黑 + 余烬。
	//   消失/长回走**缩放**（见 vertex 里的 v_burn_scale），不再是噪声溶解，
	//   所以缩小过程中一直是焦黑的（用户要求：消失时保持焦黑）。
	if (v_burn_kill > 0.5) {
		discard;                       // 完全缩没了才丢弃，避免留下一个点
	}
	if (v_burn_amt > 0.001) {
		ALBEDO = mix(ALBEDO, burn_char_color, v_burn_amt);
		ALBEDO += burn_ember_color * v_burn_ember;
	}
}
