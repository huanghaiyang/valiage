extends RefCounted
## 【性能 · 视距剔除】给"远处小件聚集区"（墓园/遗迹等）的静态网格设置可见距离，
## 让它们离开视野后**不再提交绘制**（省 draw call / 图元）。
##
## 为什么用 visibility_range，而不是 LOD 或画质档：
##   · 墓园部件多为 1~3m 的小件、都在相机近处 —— 引擎的自动 LOD
##     （Settings.mesh_lod_threshold）几乎不会触发；
##   · 画质档（QualityManager / QualityTiers）只作用于**地形（地表贴图/地形 LOD）与阴影**，
##     不碰模型；
##   · 而 visibility_range 是**引擎级**的距离剔除（含平滑淡出），**零每帧脚本开销**。
##
## 参数刻意保守：默认 80m 才完全淡出（20m 淡出带 + FADE_SELF 平滑过渡），
## 正常游玩几乎看不到它的存在；只有跑远之后才真正省下这部分绘制。
##   想更激进（省更多）：把 DEFAULT_END 调小，例如 45m / margin 12m。
##   想更安全（更不易察觉）：调大，例如 120m。
const DEFAULT_END := 80.0
const DEFAULT_MARGIN := 20.0
## 处理的子树关键词（节点名包含即整棵处理）
const NAME_HINTS := ["墓地", "遗迹"]


static func apply(root: Node, end_m := DEFAULT_END, margin_m := DEFAULT_MARGIN) -> Dictionary:
	var done := 0
	var st: Array = [root]
	while not st.is_empty():
		var n = st.pop_back() as Node
		if n == null:
			continue
		var nm := String(n.name)
		var hit := false
		for h in NAME_HINTS:
			if nm.contains(h):
				hit = true
		if hit:
			# 命中的子树：给下面所有 MeshInstance3D 设可见距离
			var sub: Array = [n]
			while not sub.is_empty():
				var m = sub.pop_back()
				if m is MeshInstance3D:
					var mi := m as MeshInstance3D
					mi.visibility_range_end = end_m
					mi.visibility_range_end_margin = margin_m
					mi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
					done += 1
				for c in m.get_children():
					sub.append(c)
			continue          # 整棵已处理，不再往里递归
		for c in n.get_children():
			st.append(c)
	print("PropVisibility | 视距剔除 %d 个网格（end=%.0fm margin=%.0fm）" % [done, end_m, margin_m])
	return {"meshes": done, "end": end_m, "margin": margin_m}
