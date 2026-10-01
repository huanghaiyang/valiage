extends Node
## 魔法值系统（自动加载为 Mana）。
##
## 规则（按需求）：
##   · 有魔法就能一直喷，耗尽就暂停（喷不出来，但不会"扣成负数"）
##   · 缓慢自动恢复
##   · 魔法瓶预留占位接口（add_mana / refill，具体物品以后接）
##
## 别的系统只读这几个值：current / max_mana / ratio / empty

signal changed(current: float, maximum: float)
signal emptied()
signal refilled()

@export var max_mana := 100.0
@export var start_full := true
@export var regen_per_sec := 6.0          ## 每秒恢复
@export var regen_delay := 1.2            ## 停止消耗后多久才开始恢复（秒）
@export var spend_per_sec := 22.0         ## 火焰喷射每秒消耗

var current := 100.0
var _since_spend := 999.0


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	current = max_mana if start_full else 0.0


func _process(delta: float) -> void:
	_since_spend += delta
	# 刚消耗过 -> 延迟一会儿再恢复（避免"边喷边回"的假象）
	if _since_spend < regen_delay:
		return
	if current >= max_mana:
		return
	current = minf(max_mana, current + regen_per_sec * delta)
	changed.emit(current, max_mana)


## 这帧想消耗 amount；够就扣掉返回 true，不够返回 false（并标记耗尽）
func try_spend(amount: float) -> bool:
	if amount <= 0.0:
		return true
	if current < amount:
		current = 0.0
		changed.emit(current, max_mana)
		emptied.emit()
		return false
	current -= amount
	_since_spend = 0.0
	changed.emit(current, max_mana)
	return true


## 按"每秒消耗 × delta"扣（喷射每帧调用）
func spend_rate(delta: float, per_sec: float = -1.0) -> bool:
	var rate := spend_per_sec if per_sec < 0.0 else per_sec
	return try_spend(rate * delta)


func has_mana(amount: float = 0.0) -> bool:
	return current > 0.0 and current >= amount


func ratio() -> float:
	return 0.0 if max_mana <= 0.0 else clampf(current / max_mana, 0.0, 1.0)


func is_empty() -> bool:
	return current <= 0.0


# ---------------------------------------------------------------- 占位：魔法瓶
## 以后接物品时调它；现在没有任何东西调用（按需求"暂时不实现，占位"）
func add_mana(amount: float) -> void:
	if amount <= 0.0:
		return
	var was_empty := current <= 0.0
	current = minf(max_mana, current + amount)
	changed.emit(current, max_mana)
	if was_empty and current > 0.0:
		refilled.emit()


func refill() -> void:
	current = max_mana
	changed.emit(current, max_mana)
	refilled.emit()