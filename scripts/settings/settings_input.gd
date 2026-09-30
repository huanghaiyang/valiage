@tool
class_name SettingsInput
extends RefCounted
## 按键改绑（操作 InputMap ✓ 逻辑可单测 ✓）
##
## 关键难点 ✓：**InputMap 的改动不会自动持久化** ✗ ——
## 所以绑定的存档由我们自己负责：存进设置 store 的 "input/bindings" ✓，
## 启动时由 GameSettings 调 load_bindings() 还原 ✓。

const STORE_KEY := "input/bindings"

## 不参与改键的动作：引擎内置的 ui_* 与编辑器专用动作 ✓
static func is_rebindable(action: String) -> bool:
	if action.begins_with("ui_"):
		return false
	if action.begins_with("spatial_editor/") or action.begins_with("editor/"):
		return false
	return true


## 游戏自己的动作（按键表就显示这些 ✓）
static func game_actions() -> Array:
	var out: Array = []
	for a in InputMap.get_actions():
		var action := String(a)
		if is_rebindable(action):
			out.append(action)
	out.sort()
	return out


## 一个事件的可读名字："W" / "空格" / "Ctrl+Shift+K" / "鼠标左键"
static func event_text(ev: InputEvent) -> String:
	if ev is InputEventKey:
		var k := ev as InputEventKey
		var mods := ""
		if k.ctrl_pressed: mods += "Ctrl+"
		if k.shift_pressed: mods += "Shift+"
		if k.alt_pressed: mods += "Alt+"
		if k.meta_pressed: mods += "Meta+"
		var code: int = k.physical_keycode if k.physical_keycode != 0 else k.keycode
		return mods + OS.get_keycode_string(code)
	if ev is InputEventMouseButton:
		match (ev as InputEventMouseButton).button_index:
			MOUSE_BUTTON_LEFT: return "鼠标左键"
			MOUSE_BUTTON_RIGHT: return "鼠标右键"
			MOUSE_BUTTON_MIDDLE: return "鼠标中键"
			_: return "鼠标键 %d" % int((ev as InputEventMouseButton).button_index)
	if ev is InputEventJoypadButton:
		return "手柄键 %d" % int((ev as InputEventJoypadButton).button_index)
	if ev is InputEventJoypadMotion:
		return "手柄轴 %d" % int((ev as InputEventJoypadMotion).axis)
	return ev.as_text()


## 某动作当前的按键文字（多个就顿号连起来 ✓）
static func current_text(action: String) -> String:
	var names := PackedStringArray()
	for ev in InputMap.action_get_events(action):
		names.append(event_text(ev))
	if names.is_empty():
		return "（未绑定）"
	return "、".join(names)


## 改绑：先清掉旧绑定再写新的（单一绑定便于玩家理解 ✓）
static func rebind(store, action: String, ev: InputEvent) -> Dictionary:
	if not is_rebindable(action):
		return {"ok": false, "message": "该动作不允许改键：%s" % action}
	InputMap.action_erase_events(action)
	InputMap.action_add_event(action, ev)
	var saved := save_bindings(store)
	return {"ok": true, "action": action, "text": event_text(ev), "saved": saved}


## 单个动作恢复项目默认 ✓（从 project.godot 的 input/<action> 读回来 ✓）
static func reset_action(store, action: String) -> bool:
	if not InputMap.has_action(action):
		return false
	InputMap.action_erase_events(action)
	var defs: Array = ProjectSettings.get_setting("input/" + action, [])
	if defs.is_empty():
		return false
	for e in defs:
		if e is InputEvent:
			InputMap.action_add_event(action, e)
	save_bindings(store)
	return true


static func reset_all(store) -> int:
	var n := 0
	for a in game_actions():
		if reset_action(store, String(a)):
			n += 1
	return n


## 把所有动作的按键写进设置 ✓（只存改过的更省事，这里全存便于跨版本稳定 ✓）
static func save_bindings(store) -> int:
	var data := {}
	for a in InputMap.get_actions():
		var action := String(a)
		if not is_rebindable(action):
			continue
		var codes: Array = []
		for ev in InputMap.action_get_events(action):
			if ev is InputEventKey:
				var k := ev as InputEventKey
				codes.append({
					"code": int(k.physical_keycode if k.physical_keycode != 0 else k.keycode),
					"ctrl": k.ctrl_pressed, "shift": k.shift_pressed,
					"alt": k.alt_pressed, "meta": k.meta_pressed,
				})
		data[action] = codes
	store.set_value(STORE_KEY, data)
	return data.size()


## 启动时还原 ✓ 返回还原了几个动作。
## 逐个键与当前 InputMap 比对，**一样就不动** ✓ —— 避免把项目默认意外覆盖掉。
static func load_bindings(store) -> int:
	var data: Variant = store.get_value(STORE_KEY)
	if not (data is Dictionary):
		return 0
	var applied := 0
	for action in (data as Dictionary).keys():
		var name := String(action)
		if not InputMap.has_action(name):
			continue
		var codes: Array = (data as Dictionary)[action]
		if codes.is_empty():
			continue
		var events: Array = []
		for c in codes:
			var d: Dictionary = c
			var ev := InputEventKey.new()
			ev.physical_keycode = int(d.get("code", 0))
			ev.ctrl_pressed = bool(d.get("ctrl", false))
			ev.shift_pressed = bool(d.get("shift", false))
			ev.alt_pressed = bool(d.get("alt", false))
			ev.meta_pressed = bool(d.get("meta", false))
			events.append(ev)
		# 直接应用 ✓（保存下来的绑定就是权威；重复应用是幂等的 ✓）
		# 早期版本写了"与当前相同就跳过"的优化 ✗ —— 那个分支很脆（events 类型/顺序稍有差异判断就错 ✗），去掉。
		InputMap.action_erase_events(name)
		for ev in events:
			InputMap.action_add_event(name, ev)
		applied += 1
	return applied