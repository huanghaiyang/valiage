@tool
class_name TextureTierRules
extends RefCounted
## 本插件自带的"贴图分档命名/尺寸"规则（**完全自包含**，不依赖 addons 目录以外的任何脚本）。
##
## 命名与 CozyVale 项目的 scripts/quality/quality_tiers.gd 保持一致：
##   xxx_diff_4k.jpg   ->   xxx_diff_2k.jpg / xxx_diff_1k.jpg
## 若将来项目改了命名规则，只需同步修改本文件。

## 档位 -> 目标宽度（像素）
const SIZE_OF := {"4k": 4096, "2k": 2048, "1k": 1024, "512": 512, "256": 256}
## 识别/去除的分辨率后缀（`_4k` 与 `-4k` 两种写法都认）
const SUFFIXES := ["4k", "2k", "1k", "512", "256"]


## 把路径里的分辨率后缀换成 suffix；没有后缀时追加。
## `res://assets/x/rock_diff_4k.jpg` + "2k" -> `res://assets/x/rock_diff_2k.jpg`
static func swap_resolution_suffix(path: String, suffix: String) -> String:
	var dir := path.get_base_dir()
	var file := path.get_file()
	var ext := file.get_extension()
	var stem := file
	if ext != "":
		stem = file.substr(0, file.length() - ext.length() - 1)
	# 去掉末尾已有的分辨率后缀（任一档位，_ 或 - 分隔）
	for s in SUFFIXES:
		for sep in ["_", "-"]:
			var tail: String = String(sep) + String(s)
			if stem.to_lower().ends_with(tail):
				stem = stem.substr(0, stem.length() - tail.length())
				break
	var out_name := stem + "_" + suffix
	if ext != "":
		out_name += "." + ext
	if dir == "":
		return out_name
	return dir.path_join(out_name)
