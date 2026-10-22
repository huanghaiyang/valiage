@tool
extends RefCounted
## 类型专属统计：网格 / 纹理 / 动画 / 音频 / 渐变。
## 这些数据来自**已载入的资源对象**（不是字节解析），供「摘要」与「预览」两页共用。
## 全部做防御式取值：属性缺失或资源为空都不报错，只少几行。

const MAX_ANIM_TRACKS := 400


## 网格：表面数 / 顶点 / 三角形 / AABB / 混合形状
static func mesh_stats(mesh: Mesh) -> Dictionary:
	var d := {
		"surfaces": 0,
		"vertices": 0,
		"triangles": 0,
		"aabb": AABB(),
		"blend_shapes": 0,
		"primitive": "",
	}
	if mesh == null:
		return d
	var surfaces: int = mesh.get_surface_count()
	d["surfaces"] = surfaces
	var verts := 0
	var tris := 0
	for i in surfaces:
		var vcount: int = mesh.surface_get_array_len(i)
		verts += vcount
		var icount: int = mesh.surface_get_array_index_len(i)
		if icount > 0:
			tris += icount / 3
		else:
			tris += vcount / 3
	d["vertices"] = verts
	d["triangles"] = tris
	d["aabb"] = mesh.get_aabb()
	# Mesh 基类在 4.7.2 没有 get_blend_shape_count（只有部分子类有），动态探测
	if mesh.has_method("get_blend_shape_count"):
		d["blend_shapes"] = int(mesh.call("get_blend_shape_count"))
	if surfaces > 0:
		d["primitive"] = primitive_name(mesh.surface_get_primitive_type(0))
	return d


## 纹理：尺寸 / mipmap / 显存估算（按 RGBA8 粗算，仅供量级参考）
static func texture_stats(tex: Texture2D) -> Dictionary:
	var d := {
		"width": 0,
		"height": 0,
		"mipmaps": false,
		"vram_bytes": 0,
	}
	if tex == null:
		return d
	d["width"] = tex.get_width()
	d["height"] = tex.get_height()
	d["mipmaps"] = tex.has_mipmaps()
	d["vram_bytes"] = estimate_vram_bytes(tex.get_width(), tex.get_height(), tex.has_mipmaps())
	return d


## 图像：同纹理（Image 与 Texture2D 都能用）
static func image_stats(img: Image) -> Dictionary:
	var d := {
		"width": 0,
		"height": 0,
		"mipmaps": false,
		"vram_bytes": 0,
		"format": "",
		"format_id": -1,
	}
	if img == null:
		return d
	d["width"] = img.get_width()
	d["height"] = img.get_height()
	d["mipmaps"] = img.has_mipmaps()
	d["vram_bytes"] = estimate_vram_bytes(img.get_width(), img.get_height(), img.has_mipmaps())
	d["format_id"] = img.get_format()
	d["format"] = image_format_name(img.get_format())
	return d


static func estimate_vram_bytes(w: int, h: int, mipmaps: bool) -> int:
	if w <= 0 or h <= 0:
		return 0
	var base := w * h * 4  # 按 RGBA8 粗算
	if mipmaps:
		base = int(base * 4.0 / 3.0)
	return base


## 动画：时长 / 循环模式 / 轨道表（轨道数有上限，避免大动画卡界面）
static func animation_stats(anim: Animation) -> Dictionary:
	var d := {
		"length": 0.0,
		"loop": "",
		"tracks": 0,
		"track_rows": [],
	}
	if anim == null:
		return d
	d["length"] = anim.get_length()
	d["loop"] = loop_mode_name(anim.loop_mode)
	var n: int = anim.get_track_count()
	d["tracks"] = n
	var rows: Array = []
	var limit: int = mini(n, MAX_ANIM_TRACKS)
	for i in limit:
		rows.append({
			"index": i,
			"path": str(anim.track_get_path(i)),
			"type": track_type_name(anim.track_get_type(i)),
			"keys": anim.track_get_key_count(i),
		})
	d["track_rows"] = rows
	return d


## 音频：时长 / 采样率 / 声道 / 编码
static func audio_stats(stream: AudioStream) -> Dictionary:
	var d := {
		"length": 0.0,
		"mix_rate": -1,
		"channels": -1,
		"format": "",
	}
	if stream == null:
		return d
	d["length"] = stream.get_length()
	if stream is AudioStreamWAV:
		var wav: AudioStreamWAV = stream
		d["mix_rate"] = wav.mix_rate
		d["channels"] = 2 if wav.stereo else 1
		d["format"] = wav_format_name(wav.format)
	elif stream is AudioStreamOggVorbis:
		# AudioStreamOggVorbis 在 4.7.2 没有 channels / mix_rate 属性，只给编码名
		d["format"] = "Ogg Vorbis"
	elif stream is AudioStreamMP3:
		d["format"] = "MP3"
	return d


## 渐变：颜色数 / 插值模式 / 前几个颜色
static func gradient_stats(g: Gradient) -> Dictionary:
	var d := {
		"colors": 0,
		"interpolation": "",
		"preview": [],
	}
	if g == null:
		return d
	d["colors"] = g.get_point_count()
	match g.get_interpolation_mode():
		Gradient.GRADIENT_INTERPOLATE_LINEAR:
			d["interpolation"] = "线性"
		Gradient.GRADIENT_INTERPOLATE_CONSTANT:
			d["interpolation"] = "阶梯（常量）"
		Gradient.GRADIENT_INTERPOLATE_CUBIC:
			d["interpolation"] = "三次曲线"
		_:
			d["interpolation"] = "未知"
	var preview: Array = []
	var limit: int = mini(g.get_point_count(), 64)
	for i in limit:
		var c := g.get_color(i)
		preview.append("#%s" % c.to_html(true))
	d["preview"] = preview
	return d


## 曲面图元名
static func primitive_name(p: int) -> String:
	match p:
		Mesh.PRIMITIVE_POINTS:
			return "点"
		Mesh.PRIMITIVE_LINES:
			return "线"
		Mesh.PRIMITIVE_LINE_STRIP:
			return "线段条带"
		Mesh.PRIMITIVE_TRIANGLES:
			return "三角形"
		Mesh.PRIMITIVE_TRIANGLE_STRIP:
			return "三角形条带"
		_:
			return "图元 #%d" % p


static func loop_mode_name(m: int) -> String:
	match m:
		Animation.LOOP_NONE:
			return "不循环"
		Animation.LOOP_LINEAR:
			return "线性循环"
		Animation.LOOP_PINGPONG:
			return "往返循环"
		_:
			return "模式 #%d" % m


static func track_type_name(t: int) -> String:
	match t:
		Animation.TYPE_VALUE:
			return "值"
		Animation.TYPE_POSITION_3D:
			return "位置 3D"
		Animation.TYPE_ROTATION_3D:
			return "旋转 3D"
		Animation.TYPE_SCALE_3D:
			return "缩放 3D"
		Animation.TYPE_BLEND_SHAPE:
			return "混合形状"
		Animation.TYPE_METHOD:
			return "方法调用"
		Animation.TYPE_BEZIER:
			return "贝塞尔"
		Animation.TYPE_AUDIO:
			return "音频"
		Animation.TYPE_ANIMATION:
			return "子动画"
		_:
			return "轨道 #%d" % t


static func wav_format_name(f: int) -> String:
	match f:
		AudioStreamWAV.FORMAT_8_BITS:
			return "8 位 PCM"
		AudioStreamWAV.FORMAT_16_BITS:
			return "16 位 PCM"
		AudioStreamWAV.FORMAT_IMA_ADPCM:
			return "IMA ADPCM"
		AudioStreamWAV.FORMAT_QOA:
			return "QOA"
		_:
			return "编码 #%d" % f


## Image.Format 不是可枚举的全局枚举（4.7.2 实测），只能逐个常量比对
static func image_format_name(f: int) -> String:
	match f:
		Image.FORMAT_L8:
			return "L8（灰度）"
		Image.FORMAT_LA8:
			return "LA8（灰度+Alpha）"
		Image.FORMAT_R8:
			return "R8"
		Image.FORMAT_RG8:
			return "RG8"
		Image.FORMAT_RGB8:
			return "RGB8"
		Image.FORMAT_RGBA8:
			return "RGBA8"
		Image.FORMAT_RGBA4444:
			return "RGBA4444"
		Image.FORMAT_RGB565:
			return "RGB565"
		Image.FORMAT_RF:
			return "RF（浮点）"
		Image.FORMAT_RGF:
			return "RGF（浮点）"
		Image.FORMAT_RGBF:
			return "RGBF（浮点）"
		Image.FORMAT_RGBAF:
			return "RGBAF（浮点）"
		Image.FORMAT_RH:
			return "RH（半浮点）"
		Image.FORMAT_RGH:
			return "RGH（半浮点）"
		Image.FORMAT_RGBH:
			return "RGBH（半浮点）"
		Image.FORMAT_RGBAH:
			return "RGBAH（半浮点）"
		Image.FORMAT_RGBE9995:
			return "RGBE9995"
		Image.FORMAT_DXT1:
			return "DXT1（BC1）"
		Image.FORMAT_DXT3:
			return "DXT3（BC2）"
		Image.FORMAT_DXT5:
			return "DXT5（BC3）"
		Image.FORMAT_RGTC_R:
			return "RGTC R"
		Image.FORMAT_RGTC_RG:
			return "RGTC RG"
		Image.FORMAT_BPTC_RGBA:
			return "BPTC RGBA"
		Image.FORMAT_BPTC_RGBF:
			return "BPTC RGBF"
		Image.FORMAT_BPTC_RGBFU:
			return "BPTC RGBFU"
		Image.FORMAT_ETC2_RGB8:
			return "ETC2 RGB8"
		Image.FORMAT_ETC2_RGBA8:
			return "ETC2 RGBA8"
		Image.FORMAT_ETC2_RGB8A1:
			return "ETC2 RGB8A1"
		_:
			return "格式 #%d" % f

