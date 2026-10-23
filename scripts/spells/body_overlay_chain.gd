extends RefCounted
## 角色体表 material_overlay 的**分层链**：把 MeshInstance3D 上唯一的 overlay 槽位
## 扩展成"多层叠加"，让多个长时法术（金色守护 / 流水治疗 …）能同时贴在同一个网格上。
##
## 【为什么需要它】
##   Godot 每个 GeometryInstance3D 只有**一个** material_overlay。原先各法术各自
##   备份 `prev` 再 `mi.material_overlay = 自己的膜`，于是：
##     · 后贴的覆盖先贴的（水膜一发动，金膜就看不见了）；
##     · 先结束的把槽位写回**自己发动时**的 prev（= null），顺手把对方还活着的膜抹掉。
##   本工具用 Material.next_pass 把这些"膜"串成有序链：
##     mi.material_overlay = 第 0 层，第 i 层的 next_pass = 第 i+1 层
##   两个法术的着色器都是 blend_add / unshaded / depth_draw_never，天然可叠加。
##
## 【用法】
##   贴膜：CHAIN.attach(mi, key, 自己的材质)
##   摘膜：CHAIN.detach(mi, key, 自己的材质)   ← 只摘自己那层，其它层自动重连
##   key 按**法术种类**取（本仓库用 "gold_body" / "water_heal"）：同一种法术的新一发会
##   替换旧那层（不会叠成两层），旧实例随后 detach 时会因材质对不上而自动忽略。
##
## 【不变量】
##   · 每个网格的原 overlay 只在**建链那一刻**快照一次（chain.orig），之后的 attach/detach
##     都只改层链，不会再用"后来者"的快照覆盖它 → 全部层摘完后精确还原原值；
##   · 材质对象是共享的（同一法术的所有网格用同一份膜），因此 _apply 每次都先清掉
##     各层的 next_pass 再按当前顺序重连，避免残留上一轮/上一个网格的串联；
##   · 网格已被释放时静默跳过（场景切换的常态），不崩溃。

## mesh 实例 id -> { "mesh": MeshInstance3D, "orig": 原 overlay, "layers": [{key, mat}, ...] }
static var _chains: Dictionary = {}


## 把 mat 作为一层贴到 mi 上（同一 key 重复调用 = 替换材质，不会重复叠层）。
static func attach(mi: MeshInstance3D, key: String, mat: Material) -> void:
	if mi == null or not is_instance_valid(mi) or mat == null:
		return
	var id := mi.get_instance_id()
	var chain: Dictionary = _chains.get(id, {})
	if chain.is_empty():
		# ★ 只在建链这一刻快照原值：此后无论谁先谁后 attach，orig 都代表"施法前"
		chain = {"mesh": mi, "orig": mi.material_overlay, "layers": []}
		_chains[id] = chain
	var layers: Array = chain["layers"]
	for e in layers:
		if String(e.get("key", "")) == key:
			e["mat"] = mat
			_apply(chain)
			return
	layers.append({"key": key, "mat": mat})
	_apply(chain)


## 摘掉 mi 上属于 key 的那一层；层全部摘完时把 overlay 还原成建链前的原值。
## 参数 mat：只有该层的材质**仍是这一份**时才摘（防止旧法术实例把同种类新法术贴的膜摘掉）。
##   传 null = 不校验材质（仅用于调试）。
static func detach(mi: MeshInstance3D, key: String, mat: Material = null) -> void:
	if mi == null or not is_instance_valid(mi):
		return
	var id := mi.get_instance_id()
	if not _chains.has(id):
		return
	var chain: Dictionary = _chains[id]
	var layers: Array = chain["layers"]
	for i in range(layers.size()):
		var e: Dictionary = layers[i]
		if String(e.get("key", "")) != key:
			continue
		# ★ 同种类法术的新一发已经替换了材质 → 旧实例无权摘掉它
		if mat != null and e.get("mat") != mat:
			return
		layers.remove_at(i)
		break
	if layers.is_empty():
		mi.material_overlay = chain.get("orig", null)
		_chains.erase(id)
	else:
		_apply(chain)


## 按当前层序重建 mi 的 overlay 链。
static func _apply(chain: Dictionary) -> void:
	var mi := chain.get("mesh") as MeshInstance3D
	if mi == null or not is_instance_valid(mi):
		return
	var layers: Array = chain["layers"]
	if layers.is_empty():
		return
	# 先断开所有旧串联（材质是共享的，可能还留着上一个网格/上一轮的 next_pass）
	for e in layers:
		var m := e.get("mat") as Material
		if m != null:
			m.next_pass = null
	# 再按顺序串起来：第 0 层进 overlay 槽位，其余走 next_pass
	for i in range(layers.size() - 1):
		var cur := layers[i].get("mat") as Material
		var nxt := layers[i + 1].get("mat") as Material
		if cur != null and nxt != null:
			cur.next_pass = nxt
	mi.material_overlay = layers[0].get("mat") as Material
