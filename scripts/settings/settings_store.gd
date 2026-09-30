@tool
class_name SettingsStore
extends RefCounted
## 设置值的持有与持久化（纯逻辑 ✓ 可单测）
## 存到 user://settings.cfg ✓；每次改动即时落盘 ✓ 并发出 changed 信号 ✓

signal changed(key: String, value: Variant)

const CFG_PATH := "user://settings.cfg"

## 实际使用的路径。可替换 ✓（测试必须指向别处，否则会把玩家真实设置覆盖掉 ✗）
var cfg_path := CFG_PATH

var _values := {}


func _init() -> void:
	reset_all()


## 全部恢复默认（内存里 ✓ 不落盘）
func reset_all() -> void:
	_values = SettingsSchema.defaults()


## 取"非 schema 键"（如 input/bindings）时，若从未存过会返回 null ✓（不会冒充默认值 ✗）
func get_value(key: String) -> Variant:
	if _values.has(key):
		return _values[key]
	var d := SettingsSchema.find(key)
	return d.get("default", null)


func set_value(key: String, value: Variant) -> void:
	if _values.has(key) and _values[key] == value:
		return
	_values[key] = value
	save()
	changed.emit(key, value)


func has(key: String) -> bool:
	return _values.has(key)


## 只写文件，不发信号（启动加载或整批应用时用 ✓）
func save() -> bool:
	var cfg := ConfigFile.new()
	for key in _values.keys():
		var parts := String(key).split("/")
		if parts.size() < 2:
			continue
		cfg.set_value(parts[0], "/".join(parts.slice(1)), _values[key])
	return cfg.save(cfg_path) == OK


## 读文件；缺的键保留默认 ✓ 返回读到了几项
func load_from_disk() -> int:
	var cfg := ConfigFile.new()
	if cfg.load(cfg_path) != OK:
		return 0
	# ★ 必须遍历**文件里实际有的键**，而不是只遍历默认表 ✗ ——
	#   "input/bindings"（按键绑定）不在 schema 里，早期版本因此**永远读不回来** ✗，
	#   等于游戏里改的键重开就失效 ✗（这个 bug 是被单元测试逮住的 ✓）。
	var n := 0
	var allowed_extra := ["input/bindings"]
	for section in cfg.get_sections():
		for name in cfg.get_section_keys(section):
			var key := String(section) + "/" + String(name)
			if SettingsSchema.find(key).is_empty() and not allowed_extra.has(key):
				continue                     # 只接受 schema 里的键 + 明确允许的额外键 ✓
			_values[key] = cfg.get_value(section, name)
			n += 1
	return n


## 与默认值不同的项（便于"是否有改动"判断 ✓）
func modified_keys() -> Array:
	var out: Array = []
	var defs := SettingsSchema.defaults()
	for key in defs.keys():
		if _values.get(key, null) != defs[key]:
			out.append(key)
	return out