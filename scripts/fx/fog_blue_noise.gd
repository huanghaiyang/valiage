class_name FogBlueNoise
extends RefCounted

## ============================================================================
## 生成一张 **低差异（rank-1 lattice / R2）掩膜**，用于光线步进的**抖动相位**。
## ----------------------------------------------------------------------------
## 【为什么不是白噪声】
##   抖动相位若用白噪声，低频会成团 ⇒ 屏幕上残留一块块的斑；蓝噪声能量集中在高频，
##   肉眼（以及未来的时间累积）收敛得更好。
## 【为什么不是严格的 void-and-cluster 蓝噪声】
##   那套算法在 GDScript 里是 O(N²) 级：64×64 = 4096 点会卡住启动秒级。
##   这里用 R2 低差异序列（黄金比）把点按序铺进网格，再线性探测补齐空位 ——
##   O(N)、启动即完成，频谱显著优于白噪声，工程上是标准的"抖动掩膜"做法。
## 【用法】
##   var tex := FogBlueNoise.build()      # 64×64，FORMAT_R8，值 = 排序后的 0..1
##   着色器侧：phase = fract(tex.r + 帧偏移)；偏移用黄金比，逐帧不重复。
## ============================================================================

const SIZE := 64
## R2 序列的两个无理步长（1/φ² 与 1/φ³ 的经典取值）
const R2_A1 := 0.7548776662466927
const R2_A2 := 0.5698402909980532

## 生成掩膜纹理。失败返回 null（调用方应保持 jitter 关闭）。
static func build(size: int = SIZE) -> ImageTexture:
	if size <= 0:
		return null
	var total := size * size
	var filled := PackedByteArray()
	filled.resize(total)
	var ranks := PackedFloat32Array()
	ranks.resize(total)
	var placed := 0
	for i in range(total):
		# 低差异序列给出的位置 → 落到网格；被占则线性探测下一个空格
		var x := int(fposmod(0.5 + R2_A1 * float(i), 1.0) * float(size))
		var y := int(fposmod(0.5 + R2_A2 * float(i), 1.0) * float(size))
		x = clampi(x, 0, size - 1)
		y = clampi(y, 0, size - 1)
		var index := y * size + x
		var probes := 0
		while filled[index] == 1 and probes < total:
			index = (index + 1) % total
			probes += 1
		filled[index] = 1
		# 排序归一化到 0..1：越早填的格子值越小
		ranks[index] = float(placed) / float(maxi(total - 1, 1))
		placed += 1
	var image := Image.create_empty(size, size, false, Image.FORMAT_R8)
	for y in range(size):
		for x in range(size):
			var value := ranks[y * size + x]
			image.set_pixel(x, y, Color(value, value, value, 1.0))
	return ImageTexture.create_from_image(image)


## 逐帧相位偏移：黄金比序列 ⇒ 每一帧的偏移都不重复，且相邻帧之间差异最大。
static func frame_offset(frame_index: int) -> float:
	return fposmod(0.6180339887498949 * float(frame_index), 1.0)
