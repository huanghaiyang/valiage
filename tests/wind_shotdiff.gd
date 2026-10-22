extends SceneTree
## 图片差分：比较两张 PNG（用于"新旧着色器静态画面一致"与"两帧之间是否在动"）。

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		print("usage: -- a.png b.png [region:canopy|trunk|full]")
		quit(1)
		return
	var a := Image.load_from_file(args[0])
	var b := Image.load_from_file(args[1])
	if a == null or b == null or a.get_size() != b.get_size():
		print("DIFF FAIL load/size")
		quit(1)
		return
	var w := a.get_width()
	var h := a.get_height()
	# 区域：树冠 = 图像上 2/3；树干底部 = 中下方一条窄带
	var region := "full"
	if args.size() > 2:
		region = args[2]
	var x0 := 0
	var y0 := 0
	var x1 := w
	var y1 := h
	if region == "canopy":
		x0 = int(w * 0.15); x1 = int(w * 0.85); y0 = int(h * 0.05); y1 = int(h * 0.62)
	elif region == "trunk":
		x0 = int(w * 0.42); x1 = int(w * 0.58); y0 = int(h * 0.62); y1 = int(h * 0.82)
	var differs := 0
	var sum := 0.0
	var n := 0
	var maxd := 0.0
	# bands：按 10 条横带分别统计"变化像素占比"，用来证明"树冠在动、树干底部不动"
	if region == "bands":
		var bands := 10
		for bi in range(bands):
			var by0 := int(h * bi / float(bands))
			var by1 := int(h * (bi + 1) / float(bands))
			var bd := 0
			var bn := 0
			for y in range(by0, by1, 2):
				for x in range(0, w, 4):
					var ca := a.get_pixel(x, y)
					var cb := b.get_pixel(x, y)
					var d := absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)
					bn += 1
					if d > 0.02:
						bd += 1
			print("BAND %d y=[%d..%d] change_ratio=%.4f" % [bi, by0, by1, float(bd) / float(maxi(1, bn))])
		quit(0)
		return
	for y in range(y0, y1, 2):
		for x in range(x0, x1, 2):
			var ca := a.get_pixel(x, y)
			var cb := b.get_pixel(x, y)
			var d := absf(ca.r - cb.r) + absf(ca.g - cb.g) + absf(ca.b - cb.b)
			sum += d
			n += 1
			if d > maxd:
				maxd = d
			if d > 0.02:
				differs += 1
	print("DIFF region=%s samples=%d mean=%.5f max=%.4f differ_ratio=%.5f" % [
			region, n, sum / float(maxi(1, n)), maxd, float(differs) / float(maxi(1, n))])
	quit(0)
