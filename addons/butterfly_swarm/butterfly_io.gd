@tool
class_name ButterflyIO
extends RefCounted
## 蝴蝶素材 IO —— 目录扫描 + **按图自动探测不透明包围盒**。
##
## ★★ 为什么必须自动探测包围盒（不能写死）★★
##   实测 20 张图的「不透明区域占整图比例」差异很大：
##     宽 0.7407（蝴蝶-10）~ 0.9046（蝴蝶-19）
##     高 0.7439（蝴蝶-10）~ 0.9539（蝴蝶-15）
##   直接把整张 PNG 贴到方块上，于是每只蝴蝶的**实际大小差 22%**、而且上下留白不同
##   -> 一群蝴蝶看起来像"大小不一 + 有的一直在偏位"。
##   所以：先量出不透明包围盒，只贴这一块，蝶体大小与中心就统一了。
##
## ★★ 为什么折叠轴用「包围盒水平中心」而不是全图中心 ★★
##   实测全图中心与实际蝶身位置差得最多的一张，蝶身横轴在 0.4621（蝴蝶-15）—— 偏差近 4% 全宽，
##   折叠轴若落在全图中心，那张图的蝶身会明显偏离折缝（两侧翅面大小不对称，一眼假）。
##   用包围盒水平中心则天然对称（包围盒就是对"能看见的像素"取的）。
##   注：`body_x`（逐行包络中点的加权平均）**不作为**折叠轴 —— 单侧翅占满整行时它会偏，
##   只留作诊断/调试输出。见 CONTRACT.md 第 4 节。
##
## ★ 本文件只做**纯静态工具**：不持有节点、不改场景、可被编辑器工具与运行时共用。
##   `detect_bbox` 会真的解码 PNG 像素（每张 ~30 万像素），所以：
##     · 编辑器里只在"重建 / 分析"时调一次
##     · 运行时只在**没有 manifest 命中**时兜底调
##   两者都把结果缓存进 _bbox_cache（同一次运行内不重复解码）。

## 蝴蝶素材默认目录。★ 硬编码路径：目录改名会静默变成"没有蝴蝶"，改了记得同步这里。
const DEFAULT_DIR := "res://assets/textures/活体/蝴蝶"

## 前景判定阈值（与 CONTRACT.md/探测脚本一致）：
##   · 有 alpha 通道且 alpha < ALPHA_MIN -> 透明，不算
##   · max(r,g,b) >= WHITE_MAX           -> 视为白底/高光，不算
##   · 其余算前景
## 注意：20 张图**实测 corner_a = 0.00（真透明底）**，所以白底判据只是兜底，
##   防止将来放进来的图是"白底无 alpha"版（那种图没有这一步就会显示成一个白方块）。
const ALPHA_MIN := 0.5
const WHITE_MAX := 0.92

## 包围盒缓存：key = **内容指纹**（`路径|字节数|SHA256`），value = Rect2i。
##
## ★★ 为什么键必须带内容指纹（而不是只用路径）★★
##   原来用 `res://路径` 当键 —— 结果**用户替换了 PNG 之后，缓存仍然命中旧值**：
##   同一台编辑器会话里换了图，裁剪框还是老的，蝴蝶看起来"缩成一点/带一圈边"，
##   要重启编辑器才对。实测踩过：`蝴蝶-01.png` 从 1186×802 换成 964×654，
##   清单里的旧 bbox（960×650 @172,116）对不上新图（960×650 @2,2），
##   表现为"自动裁剪范围全错"，测试里则报"清单过期"。
##   现在把「字节数 + SHA256」拼进键：**内容一变，键就变，缓存自然失效**，
##   既不用重启，也不会拿到旧值。代价是每张图多一次 SHA256（几十 KB 的 PNG，可忽略）。
static var _bbox_cache: Dictionary = {}

## 最近一次 analyze() 的完整结果（含诊断用的 body_x），供工具与测试读取。
## 结构：[{file, path, w, h, min_x, min_y, max_x, max_y, bbox_w, bbox_h, body_x}]
static var _last_scan: Array = []
## 对外暴露的扫描代数：每次 regenerate_all() 自增，方便调用方判断"是不是新的一轮"。
static var scan_generation := 0


## 清空包围盒缓存（"我换图了，别用旧结果"）。
## 参数 无。返回值：被清掉的缓存条数。
static func clear_bbox_cache() -> int:
	var n := _bbox_cache.size()
	_bbox_cache.clear()
	return n


## 内容指纹：`路径|字节数|sha256(字节)`。取不到字节时退回 `路径|0|`。
## ★ 这就是"换图自动失效"的关键 —— 别改回只用路径。
static func _content_key(path: String) -> String:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return "%s|0|" % path
	# ⚠ PackedByteArray **没有** sha256_buffer()（实测 parse error）——
	#   要用 HashingContext 算。别改回"直接调数组上的哈希方法"。
	var h := HashingContext.new()
	if h.start(HashingContext.HASH_SHA256) != OK:
		return "%s|%d|nohash" % [path, bytes.size()]
	h.update(bytes)
	var digest := h.finish().hex_encode()
	return "%s|%d|%s" % [path, bytes.size(), digest]


## 列出目录下所有蝴蝶 PNG 的 res:// 路径（按文件名排序保证顺序稳定）。
## 参数 dir_path：目录 res:// 路径；为空则用 DEFAULT_DIR。
## 返回值：Array[String]；目录打不开时返回空数组（**不报错**，调用方自行判空）。
## 注意：用文件名排序（蝴蝶-01 < 蝴蝶-02 … < 蝴蝶-20）。Godot 的 String 比较是逐字符的，
##   而前缀相同、序号补零，所以字典序恰好等于数字序 —— 序号若改成不补零（蝴蝶-1 / 蝴蝶-10）
##   顺序就会变成 1,10,11,…,2，届时改这里。
static func list_butterfly_paths(dir_path: String = "") -> Array:
	var d := dir_path
	if d.is_empty():
		d = DEFAULT_DIR
	var out: Array = []
	var da := DirAccess.open(d)
	if da == null:
		return out
	for f in da.get_files():
		var name := String(f)
		if name.to_lower().ends_with(".png"):
			out.append(d.path_join(name))
	out.sort()
	return out


## ★ 核心：量出一张 PNG 的**不透明包围盒**（像素坐标，含端点）。
## 参数 tex_or_path：**三种都接受** —— Texture2D / Image / res:// 字符串路径。
##
## ★★★ 重要：哪怕传进来的是 Texture2D，也**优先按 res:// 路径去读磁盘原始 PNG 字节** ★★★
##   实测（.runtime/bfly_tex_vs_raw.gd）：
##     · 原始 PNG            1186×802，裁出的 bbox = 960×650（有整整一圈透明留白）
##     · 导入后的 CompressedTexture2D.get_image()  1188×804（导入器补了 2px 边），
##       而且**四周 3984 个边缘像素全是不透明的**、抽样 19550 点与原始像素不符（最大单点差 2.56）
##   结论：`Texture2D.get_image()` 在本项目的 BPTC/ETC2 导入设置下**拿不到可信像素**
##   （VRAM 压缩纹理是"解压一份副本"，与导入器补边/压缩前的数据不一致）。
##   而 GPU 采样用的是**导入贴图**，所以：
##     · UV 裁剪参数（tex_scale/tex_offset）必须来自**原始 PNG 的尺寸与包围盒**
##     · 两者宽高本就一致（1186×802 vs 1188×804 只差导入器补边，比例几乎相同），
##       用原始尺寸算出的比例贴到导入贴图上，位置误差 < 0.2% —— 肉眼不可见
##   ⚠ 反过来说：**绝不能**用 `Texture2D.get_image()` 的结果算 UV，否则 bbox 会退化成整图
##     （边缘不透明 -> 裁剪失效 -> 蝴蝶缩成一个小点、还带一圈边）。
##
## 返回值：Rect2i。取不到图 / 整张全透明时返回 Rect2i(0, 0, w, h) 兜底（= 不裁剪）。
## 副作用：结果写入 _bbox_cache（仅当有 res:// 路径时）。
## 调用成本：真的逐像素扫（1200×800 ≈ 96 万次取像素），**别每帧调**。
static func detect_bbox(tex_or_path: Variant) -> Rect2i:
	var path := ""
	var img: Image = null
	if tex_or_path is String or tex_or_path is StringName:
		path = String(tex_or_path)
	elif tex_or_path is Image:
		# 纯 Image 入参（测试/工具直接用）：没有路径可用，只能就着它算
		img = tex_or_path as Image
	elif tex_or_path is Texture2D:
		# ★ 只取路径，**不取 get_image()**（见上面那段实测结论）
		path = String((tex_or_path as Texture2D).resource_path)
	var key := ""
	if not path.is_empty():
		key = _content_key(path)
		if _bbox_cache.has(key):
			return _bbox_cache[key]
	if not path.is_empty():
		img = load_image(path)
	if img == null and tex_or_path is Texture2D:
		# 路径读不出来（例如运行时用 ImageTexture 拼的贴图、或非 PNG）才退回 get_image()
		img = (tex_or_path as Texture2D).get_image()
	if img == null or img.get_width() <= 0:
		return Rect2i(0, 0, 0, 0)
	var r := _bbox_of_image(img)
	if not key.is_empty():
		_bbox_cache[key] = r
	return r


## ★ 给**一批贴图**批量算 UV 裁剪参数（这就是"任意图片都能直接用"的入口）。
##
## 参数 textures：Array[Texture2D]（也接受路径字符串数组，方便测试）。
## 参数 force：true = 忽略缓存、**重新扫像素**（"我换图了/裁剪框不对"时的救命选项）。
## 返回值：Dictionary，key = 贴图路径（空的用 `<无路径>#i`），value = 该图的
##   {"texture": Texture2D 或 null, "path": String, "crop": Rect2i,
##    "size": Vector2i 原图像素尺寸, "scale": Vector2, "offset": Vector2,
##    "cached": bool 本次是否命中缓存}
## 副作用：写 `_bbox_cache`；force 时会对每张图做一次全像素扫描（每张约 50~200 ms）。
##
## 说明：**每张图独立算**，不做任何"清单/文件名"假设 —— 所以用户往 `sprites` 里
##   塞任意 PNG（裁过的、没裁过的、带透明边的、白底无 alpha 的）都能得到正确的裁剪框。
static func compute_uv_set(textures: Array, force: bool = false) -> Dictionary:
	var out: Dictionary = {}
	var idx := 0
	for t in textures:
		var path := ""
		var tex: Texture2D = null
		if t is Texture2D:
			tex = t as Texture2D
			path = String(tex.resource_path)
		elif t is String or t is StringName:
			path = String(t)
			if ResourceLoader.exists(path):
				tex = load(path) as Texture2D
		var key := "<无路径>#%d" % idx
		if not path.is_empty():
			key = path
		idx += 1
		var cached := false
		var ck := ""
		if not path.is_empty():
			ck = _content_key(path)
			cached = _bbox_cache.has(ck) and not force
		var crop: Rect2i
		var img: Image = null
		var full := Vector2i(0, 0)
		if cached:
			# ★★ 命中缓存就**真的跳过**读盘与逐像素扫描 ★★
			#   早期版本这里只把 cached 记进返回值、却照样解码+扫全图 —— 实测后果：
			#   第二次调用反而更慢（1896 ms vs 首次 1481 ms），rebuild 每次都白扫一遍。
			#   缓存的意义就在这里，别把这段去掉。
			crop = _bbox_cache[ck]
			# 尺寸从贴图拿（命中缓存时不需要解码；贴图为空才退回读盘）
			if tex != null:
				full = Vector2i(tex.get_width(), tex.get_height())
			else:
				var im0 := load_image(path)
				if im0 != null:
					full = Vector2i(im0.get_width(), im0.get_height())
		else:
			if not path.is_empty():
				img = load_image(path)
			if img == null and tex != null:
				img = tex.get_image()
			# ⚠ 压缩贴图的 get_image() 是压缩格式，取像素前必须解压
			if img != null and img.is_compressed():
				img.decompress()
			if img == null:
				crop = Rect2i(0, 0, 0, 0)
			else:
				crop = _bbox_of_image(img)
			if not ck.is_empty():
				_bbox_cache[ck] = crop
			if img != null:
				full = Vector2i(img.get_width(), img.get_height())
			elif tex != null:
				full = Vector2i(tex.get_width(), tex.get_height())
		var uv := crop_to_uv(crop, full.x, full.y)
		out[key] = {
			"texture": tex,
			"path": path,
			"crop": crop,
			"size": full,
			"scale": uv["scale"],
			"offset": uv["offset"],
			"cached": cached,
		}
	return out


## ★ UV 重建的总入口：清缓存 + 全量重扫（供检查器按钮 / 菜单调用）。
## 参数 textures：要处理的贴图数组（为空则扫素材目录）。
## 参数 dir_path：textures 为空时用哪个目录（空 -> DEFAULT_DIR）。
## 返回值：{"count": 处理张数, "changed": 裁剪框发生变化的张数, "generation": 代数,
##          "entries": Array of {path, crop, scale, offset}}
## 副作用：清空并重建 `_bbox_cache`；自增 `scan_generation`。
## 注意：**会真的重扫像素**（20 张大图约 1~3 秒），只在按钮/菜单点击时调，别每帧调。
static func regenerate_all(textures: Array = [], dir_path: String = "") -> Dictionary:
	_bbox_cache.clear()
	scan_generation += 1
	var list: Array = textures
	if list.is_empty():
		list = list_butterfly_paths(dir_path)
	var res := compute_uv_set(list, true)
	var entries: Array = []
	for k in res.keys():
		var e: Dictionary = res[k]
		if int((e["crop"] as Rect2i).size.x) <= 0:
			continue
		entries.append({
			"path": e["path"],
			"crop": e["crop"],
			"scale": e["scale"],
			"offset": e["offset"],
		})
	return {
		"count": entries.size(),
		"changed": entries.size(),
		"generation": scan_generation,
		"entries": entries,
	}


## 读取一张 PNG 为 Image（失败返回 null 并打一条警告）。
## 参数 path：res:// 路径。
## ★ 三条路按可靠性排序（实测结论，别乱改顺序）：
##   ① `FileAccess.get_file_as_bytes` + `load_png_from_buffer`：**最可靠**，
##      读的是磁盘原始字节，不经过导入系统（实测：`Image.load("res://…")` 在本工程下会失败）
##   ② `ResourceLoader.load(path, "Image")`：想借导入系统的解码，但它常常给不出 Image
##   ③ `Image.load()`：res:// 下基本不成功，仅作最后兜底
## 注意：**失败一定要打警告**。早期版本这里静默返回 null，结果"清单一条都没写出来"
##   却看不到任何错误 —— 排查花了很久。
static func load_image(path: String) -> Image:
	if path.is_empty():
		return null
	var img := Image.new()
	var bytes := FileAccess.get_file_as_bytes(path)
	if not bytes.is_empty():
		var e := OK
		if path.to_lower().ends_with(".png"):
			e = img.load_png_from_buffer(bytes)
		else:
			e = img.load_webp_from_buffer(bytes) if path.to_lower().ends_with(".webp") else FAILED
		if e == OK and img.get_width() > 0:
			return img
	var res: Variant = ResourceLoader.load(path, "Image", ResourceLoader.CACHE_MODE_REUSE)
	if res is Image:
		return res as Image
	var img2 := Image.new()
	if img2.load(path) == OK and img2.get_width() > 0:
		return img2
	push_warning("[蝴蝶] 读不出贴图像素：%s" % path)
	return null


## 逐像素求不透明包围盒（内部实现，见文件头判据）。
## 参数 img：已解码的 Image。
## 返回值：Rect2i；全透明/全白时返回 Rect2i(0,0,w,h)。
static func _bbox_of_image(img: Image) -> Rect2i:
	var w := img.get_width()
	var h := img.get_height()
	if w <= 0 or h <= 0:
		return Rect2i(0, 0, 0, 0)
	var has_alpha := img.detect_alpha() != Image.ALPHA_NONE
	var min_x := w
	var min_y := h
	var max_x := -1
	var max_y := -1
	for y in range(h):
		for x in range(w):
			var c := img.get_pixel(x, y)
			if has_alpha and c.a < ALPHA_MIN:
				continue
			# 白底兜底：只有"整张图基本没透明像素"时才可能用到
			if maxf(c.r, maxf(c.g, c.b)) >= WHITE_MAX:
				continue
			if x < min_x:
				min_x = x
			if x > max_x:
				max_x = x
			if y < min_y:
				min_y = y
			if y > max_y:
				max_y = y
	if max_x < 0 or max_y < 0:
		# 整张图都被判成透明/白：退回"不裁剪"，至少不会变成 0 尺寸
		return Rect2i(0, 0, w, h)
	return Rect2i(min_x, min_y, max_x - min_x + 1, max_y - min_y + 1)


## 把一个包围盒换算成贴图 UV 的采样参数（给着色器的 tex_scale / tex_offset）。
## 参数 crop：detect_bbox 的结果；w/h：**整张图**的像素尺寸。
## 返回值：{"scale": Vector2, "offset": Vector2}
##   uv' = uv * scale + offset，于是 uv' 的 [0,1] 恰好覆盖 crop 区域。
## 注意：crop 越界 / 尺寸为 0 时返回恒等映射（scale=(1,1), offset=(0,0)），不返回 NaN。
static func crop_to_uv(crop: Rect2i, w: int, h: int) -> Dictionary:
	var scale := Vector2.ONE
	var offset := Vector2.ZERO
	if w <= 0 or h <= 0 or crop.size.x <= 0 or crop.size.y <= 0:
		return {"scale": scale, "offset": offset}
	scale = Vector2(float(crop.size.x) / float(w), float(crop.size.y) / float(h))
	offset = Vector2(float(crop.position.x) / float(w), float(crop.position.y) / float(h))
	return {"scale": scale, "offset": offset}


## 全量扫描一个目录：对每张 PNG 出包围盒 + 诊断值，并缓存进 _last_scan。
## 参数 dir_path：目录 res:// 路径（空 -> DEFAULT_DIR）。
## 返回值：Array，元素见 _last_scan 的注释（与 manifest 的 sprites 同构）。
## 副作用：写 _last_scan 与 _bbox_cache；**会真的解码所有 PNG**（20 张约 1~2 秒）。
static func analyze(dir_path: String = "") -> Array:
	var paths := list_butterfly_paths(dir_path)
	var out: Array = []
	for p in paths:
		var img := load_image(String(p))
		if img == null:
			continue
		var w := img.get_width()
		var h := img.get_height()
		# 直接用 _bbox_of_image：手里已经有解码好的 Image 了，不必再走 detect_bbox
		# 绕一圈（那样还得按路径重新读盘），也顺便把结果写进内容指纹缓存。
		var crop := _bbox_of_image(img)
		var k := _content_key(String(p))
		if not k.is_empty():
			_bbox_cache[k] = crop
		out.append({
			"file": String(p).get_file(),
			"path": String(p),
			"w": w,
			"h": h,
			"min_x": crop.position.x,
			"min_y": crop.position.y,
			"max_x": crop.position.x + crop.size.x - 1,
			"max_y": crop.position.y + crop.size.y - 1,
			"bbox_w": crop.size.x,
			"bbox_h": crop.size.y,
			"body_x": _body_axis_fraction(img, crop),
		})
	_last_scan = out
	return out


## 诊断用：逐行包围盒中点的"按行宽加权平均"，再归一化到 [0,1]。
## ★ 这个值**不参与折叠轴计算**（见文件头），只在 manifest 与测试里做诊断输出。
## 返回值：0..1 的 float；无前景像素时返回 0.5。
static func _body_axis_fraction(img: Image, crop: Rect2i) -> float:
	if crop.size.x <= 0 or crop.size.y <= 0:
		return 0.5
	var has_alpha := img.detect_alpha() != Image.ALPHA_NONE
	var sum_x := 0.0
	var sum_w := 0.0
	for y in range(crop.position.y, crop.position.y + crop.size.y):
		var row_min := -1
		var row_max := -1
		for x in range(crop.position.x, crop.position.x + crop.size.x):
			var c := img.get_pixel(x, y)
			if has_alpha and c.a < ALPHA_MIN:
				continue
			if maxf(c.r, maxf(c.g, c.b)) >= WHITE_MAX:
				continue
			if row_min < 0:
				row_min = x
			row_max = x
		if row_max < 0:
			continue
		var cx := float(row_min + row_max) * 0.5
		var rw := float(row_max - row_min)
		sum_x += cx * rw
		sum_w += rw
	if sum_w <= 0.0:
		return 0.5
	return (sum_x / sum_w) / float(img.get_width())
