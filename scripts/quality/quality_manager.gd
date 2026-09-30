@tool
class_name QualityManager
extends Node
## 画质档位管理器。建议在 项目设置 → 全局 → 自动加载 里加为 autoload（名字建议 Quality）。
## 用法：QualityManager.instance.set_tier(QualityTiers.Tier.LOW)
## 会持久化到 user://quality.cfg，并在启动时自动加载。

signal tier_changed(tier: int)

const CFG_PATH := "user://quality.cfg"

static var instance: QualityManager = null

var tier: int = QualityTiers.Tier.HIGH


func _ready() -> void:
	instance = self
	load_tier()
	emit_signal("tier_changed", tier)


func _exit_tree() -> void:
	if instance == self:
		instance = null


func set_tier(t: int) -> void:
	t = clampi(t, QualityTiers.Tier.LOW, QualityTiers.Tier.ULTRA)
	if t == tier:
		return
	tier = t
	save_tier()
	emit_signal("tier_changed", tier)
	print("[画质] 档位切换为 %s（%s）" % [QualityTiers.tier_name(tier), QualityTiers.get_preset(tier)])


func get_preset() -> Dictionary:
	return QualityTiers.get_preset(tier)


func save_tier() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("quality", "tier", tier)
	cfg.save(CFG_PATH)


func load_tier() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CFG_PATH) != OK:
		return
	tier = clampi(int(cfg.get_value("quality", "tier", tier)), QualityTiers.Tier.LOW, QualityTiers.Tier.ULTRA)