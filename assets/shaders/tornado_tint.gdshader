shader_type spatial;
// 龙卷风（可调色版）—— 依据 scenes/法术特效/蓝色龙卷风.tscn 的 VisualShader 反推重写。
// 原图生成的 GLSL 是：
//     mask    = clamp(base_texture.r(UV + speed*TIME) - sub_texture.r(UV), 0, 1)
//     ALBEDO  = curve_1d.rgb @ mask
//     ALPHA   = curve_1d.R * opacity        ← ★ 问题就在这里
// 本版保留同样的掩码算法，但修掉下面两点（原文件一个字都没动）：
//
// 【问题 1：颜色和透明度被绑死 -> 换红色就发黑】
//   原版 ALPHA 取的是**颜色贴图的红通道**，颜色贴图自己的 alpha（渐变里写的 1 / 0）
//   完全被忽略。于是"改颜色"必然连带"改透明度"：蓝色之所以正常，只是因为那个青色
//   (0.0002, 4.39, 4.18) 在中段恰好有足够大的 R；一旦按常规思路把它改成红色，
//   R 的分布变了，整片就会变透明（屏幕上看起来就是黑的/没了）。
//   本版把两者彻底解耦：
//       颜色 -> tint_outer / tint_core（HDR 参数，随便调，不影响透明度）
//       透明度 -> mask × 高度淡出 × opacity
//
// 【问题 2：顶部硬边】
//   原版形状掩码里，顶部那段过渡在 UV 上只占约 2% 高度（梯度 stop 在 0 与 0.0199），
//   所以淡出被压成一条硬边。本版额外用**高度**做上下柔化。
//   UV.y 与模型 Y 的相关系数实测 0.9995（V=0 底部、V=1 顶部），所以可以直接当高度用。
//
// 用法：MeshInstance3D.material_override 指向本着色器的 ShaderMaterial。

// ---------------------------------------------------------------- 滚动噪声
uniform vec2 speed = vec2(1.0, 1.5);                             // 噪声滚动速度（与原版一致）
uniform sampler2D base_texture : source_color, repeat_enable;    // 风噪声（原版同贴图）
uniform sampler2D sub_texture : source_color, repeat_enable;     // 形状掩码（原版同贴图）

// ---------------------------------------------------------------- 颜色（与透明度无关）
uniform vec4 tint_outer : source_color = vec4(1.50, 0.16, 0.03, 1.0);  // 掩码弱处（外缘）深红
uniform vec4 tint_core : source_color = vec4(4.20, 0.85, 0.22, 1.0);   // 掩码强处（核心）亮橙红
uniform float opacity : hint_range(0.0, 1.0) = 0.65;

// ---------------------------------------------------------------- 上下柔化（修顶边）
uniform float top_fade : hint_range(0.0, 0.6) = 0.22;      // 顶部淡出占高度比例
uniform float bottom_fade : hint_range(0.0, 0.6) = 0.10;   // 底部淡出占高度比例

void fragment() {
	// 形状掩码：滚动噪声 - 形状贴图（与原版一致，都取 R 通道）
	float noise = texture(base_texture, UV + speed * TIME).r;
	float shape = texture(sub_texture, UV).r;
	float mask = clamp(noise - shape, 0.0, 1.0);

	// 颜色随掩码变化：外缘深红 -> 核心亮橙红（都是 HDR，可 >1）
	ALBEDO = mix(tint_outer.rgb, tint_core.rgb, mask);

	// 高度柔化：max(...,0.001) 是为了避免 fade 为 0 时 smoothstep 出现零宽区间
	float h = UV.y;
	float f_top = 1.0 - smoothstep(1.0 - max(top_fade, 0.001), 1.0, h);
	float f_bot = smoothstep(0.0, max(bottom_fade, 0.001), h);

	// ★ 透明度只由 掩码 × 高度淡出 × opacity 决定，与颜色通道无关
	ALPHA = mask * f_top * f_bot * opacity;
}
