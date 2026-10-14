#[compute]
#version 450

// ============================================================================
// probe_write.glsl —— 环境自检用的一次性计算着色器（不是雾气算法的一部分）
// ============================================================================
// 目的：证实"Godot 4.7 本地 RenderingDevice + compute + Texture2DRD 显示 + 回读"
// 这条链路在本机真的能跑通（Vulkan / Forward+）。若这一环不成立，整个 GPU 版
// 纳维-斯托克斯求解器都要改用 CPU 参考实现，所以必须先用最小样例验证。
//
// 写入内容：R = x 归一化坐标，G = y 归一化坐标，B = push constant 里的相位，A = 1。
// 这样一个已知图案既能验证"写入成功"，也能验证"回读数值正确"（不是写进去就完事）。
// ============================================================================

layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;

layout(set = 0, binding = 0, rgba16f) uniform restrict writeonly image2D dest_tex;

layout(push_constant, std430) uniform Params {
	// x = 相位（原样写进 B 通道，用来验证 push constant 真的到了 GPU）
	// yzw = 保留
	vec4 meta;
} p;

void main() {
	ivec2 gid = ivec2(gl_GlobalInvocationID.xy);
	ivec2 tex_size = imageSize(dest_tex);
	if (gid.x >= tex_size.x || gid.y >= tex_size.y) {
		return;
	}
	float fx = float(gid.x) / float(max(tex_size.x - 1, 1));
	float fy = float(gid.y) / float(max(tex_size.y - 1, 1));
	imageStore(dest_tex, gid, vec4(fx, fy, p.meta.x, 1.0));
}
