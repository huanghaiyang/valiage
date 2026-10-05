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
	float lev = pow(abs((VERTEX.y - NODE_POSITION_WORLD.y) / grass_size_y), 1.7 + sgt_wind_strength);
	float rand = wrap(dot(NODE_POSITION_WORLD, NODE_POSITION_WORLD * 10.0), 0.0, 256.0);
	float randf = fract(rand);
	int randi = int(randf * 10.0);

	uv_align = vec2(float(randi % int(texture_frames.x)), float(int(randf * 100.0) % int(texture_frames.y)));
	uv_align /= texture_frames;
	uv_scale = vec2(1.0 / texture_frames.x, 1.0 / texture_frames.y);

	float text_wind = texture(sgt_wind_pattern, (vec2(NODE_POSITION_WORLD.x, NODE_POSITION_WORLD.z) * 0.005) - sgt_wind_movement.xz).r;
	VERTEX.x += text_wind * lev * sgt_wind_strength * sgt_wind_direction.x * (1.0 - grass_strength);
	VERTEX.z += text_wind * lev * sgt_wind_strength * sgt_wind_direction.z * (1.0 - grass_strength);
	VERTEX.x += sin(rand + sgt_wind_movement.y) * lev * ((1.0 - grass_strength) / 10.0);
	VERTEX.x += sgt_wind_direction.x * lev * (sgt_wind_strength + (sin(TIME + rand) * 0.2 * (1.0 - grass_strength) * min(1.0, sgt_wind_turbulence))) * (1.0 - grass_strength);
	VERTEX.y += sin(rand + sgt_wind_movement.y) * lev * ((1.0 - grass_strength) / 10.0) * sgt_wind_direction.y;
	VERTEX.y += sgt_wind_direction.y * lev * (sgt_wind_strength + (sin(TIME + rand) * 0.2 * (1.0 - grass_strength) * min(1.0, sgt_wind_turbulence))) * (1.0 - grass_strength);
	VERTEX.z += cos(rand + sgt_wind_movement.y) * lev * ((1.0 - grass_strength) / 10.0);
	VERTEX.z += sgt_wind_direction.z * lev * (sgt_wind_strength + (sin(TIME + rand) * 0.2 * (1.0 - grass_strength) * min(1.0, sgt_wind_turbulence))) * (1.0 - grass_strength);

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

	if(dist > 0.0 && interactive_mode) {
		float node_x = NODE_POSITION_WORLD.x / 50.0;
		float node_z = NODE_POSITION_WORLD.z / 50.0;
		vec2 uv_disp = vec2(clamp((node_x - (sgt_player_position.x - 0.5)), 0.0, 1.0), clamp((node_z - (sgt_player_position.z - 0.5)), 0.0, 1.0));
		vec3 norm_mov = textureLod(sgt_normal_displacement, uv_disp - sgt_player_mov.xz, 0).rgb;
		float time = get_value(sgt_motion_texture, uv_disp) / 65535.0;
		norm_mov.xy = (norm_mov.xy * 2.0 - 1.0) * interactive_level_xz * lev;
		VERTEX.xz += norm_mov.xy * (sin(time * time * 15.0) / 2.0) * (1.0 - time);
		VERTEX.xz += norm_mov.xy * 0.5;
		VERTEX.y -= (VERTEX.y - NODE_POSITION_WORLD.y) * norm_mov.b * interactive_level_y;
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
