@tool
extends VBoxContainer


enum HeightOffsetMode {
	WORLD_Y,
	SURFACE_NORMAL,
}


signal selected_scene_changed(scene: PackedScene)
signal scene_palette_changed(scenes: Array)

signal brush_enabled_changed(enabled: bool)
signal brush_radius_changed(radius: float)
signal instances_per_click_changed(count: int)
signal minimum_spacing_changed(spacing: float)
signal random_y_rotation_changed(enabled: bool)
signal align_to_surface_changed(enabled: bool)

signal maximum_slope_changed(value: float)

signal random_scale_enabled_changed(enabled: bool)
signal minimum_scale_changed(value: float)
signal maximum_scale_changed(value: float)

signal height_offset_changed(value: float)
signal height_offset_mode_changed(mode: int)

signal lod_settings_changed(
	enabled: bool,
	lod1_scene: PackedScene,
	lod2_scene: PackedScene,
	lod1_distance: float,
	lod2_distance: float,
	cull_distance: float
)

signal auto_lod_settings_changed(
	enabled: bool,
	lod_bias: float,
	cull_distance: float
)
signal auto_lod_import_requested(
	scene_path: String,
	enabled: bool
)


const PALETTE_CONFIG_PATH := "user://world_brush_palette.cfg"

const PALETTE_SECTION := "scene_palette"
const CONFIG_SCENE_PATHS := "scene_paths"
const CONFIG_ACTIVE_SCENE_PATH := "active_scene_path"

const SETTINGS_SECTION := "brush_settings"

const SCENE_SETTINGS_SECTION := "scene_brush_settings"
const CONFIG_SCENE_SETTINGS := "profiles"

const CONFIG_BRUSH_RADIUS := "brush_radius"
const CONFIG_INSTANCES_PER_STAMP := "instances_per_stamp"
const CONFIG_MINIMUM_SPACING := "minimum_spacing"

const CONFIG_RANDOM_Y_ROTATION := "random_y_rotation"
const CONFIG_ALIGN_TO_SURFACE := "align_to_surface"
const CONFIG_MAXIMUM_SLOPE := "maximum_slope"

const CONFIG_RANDOM_SCALE_ENABLED := "random_scale_enabled"
const CONFIG_MINIMUM_SCALE := "minimum_scale"
const CONFIG_MAXIMUM_SCALE := "maximum_scale"

const CONFIG_HEIGHT_OFFSET := "height_offset"
const CONFIG_HEIGHT_OFFSET_MODE := "height_offset_mode"

const CONFIG_LOD_ENABLED := "lod_enabled"
const CONFIG_LOD1_SCENE_PATH := "lod1_scene_path"
const CONFIG_LOD2_SCENE_PATH := "lod2_scene_path"
const CONFIG_LOD1_DISTANCE := "lod1_distance"
const CONFIG_LOD2_DISTANCE := "lod2_distance"
const CONFIG_LOD_CULL_DISTANCE := "lod_cull_distance"
const CONFIG_AUTO_LOD_ENABLED := "auto_lod_enabled"
const CONFIG_AUTO_LOD_BIAS := "auto_lod_bias"
const CONFIG_AUTO_LOD_CULL_DISTANCE := "auto_lod_cull_distance"

const INTERFACE_SECTION := "interface"
const CONFIG_INTERFACE_LANGUAGE := "language"

const LANGUAGE_ENGLISH := "en"
const LANGUAGE_ARABIC := "ar"


@onready var title_label: Label = $TitleLabel
@onready var status_label: Label = $StatusLabel


var settings_scroll: ScrollContainer
var controls_container: VBoxContainer
var language_button: Button

var scenes_list: VBoxContainer
var palette_title_label: Label
var active_scene_label: Label

var previous_scene_button: Button
var next_scene_button: Button
var add_scene_button: Button

var brush_toggle: CheckButton

var brush_radius_label: Label
var radius_spin_box: SpinBox

var instances_label: Label
var instances_spin_box: SpinBox

var spacing_label: Label
var spacing_spin_box: SpinBox

var random_rotation_toggle: CheckButton
var align_surface_toggle: CheckButton

var maximum_slope_label: Label
var maximum_slope_spin_box: SpinBox

var height_offset_label: Label
var height_offset_spin_box: SpinBox

var height_offset_mode_label: Label
var height_offset_mode_option: OptionButton
var height_offset_help_label: Label

var random_scale_toggle: CheckButton

var minimum_scale_label: Label
var minimum_scale_spin_box: SpinBox

var maximum_scale_label: Label
var maximum_scale_spin_box: SpinBox

var lod_toggle: CheckButton
var lod_controls_container: VBoxContainer
var lod1_scene_label: Label
var lod1_picker: EditorResourcePicker
var lod2_scene_label: Label
var lod2_picker: EditorResourcePicker
var lod1_distance_label: Label
var lod1_distance_spin_box: SpinBox
var lod2_distance_label: Label
var lod2_distance_spin_box: SpinBox
var lod_cull_distance_label: Label
var lod_cull_distance_spin_box: SpinBox
var lod_help_label: Label
var auto_lod_toggle: CheckButton
var auto_lod_controls_container: VBoxContainer
var auto_lod_bias_label: Label
var auto_lod_bias_spin_box: SpinBox
var auto_lod_cull_label: Label
var auto_lod_cull_spin_box: SpinBox
var auto_lod_reimport_button: Button
var auto_lod_help_label: Label


var scene_rows: Array[Dictionary] = []

var active_picker: EditorResourcePicker
var selected_scene: PackedScene


var brush_enabled: bool = false

var brush_radius: float = 5.0
var instances_per_click: int = 5
var minimum_spacing: float = 1.0

var random_y_rotation: bool = true
var align_to_surface: bool = false

var maximum_slope_degrees: float = 85.0

var height_offset: float = 0.0
var height_offset_mode: int = HeightOffsetMode.SURFACE_NORMAL

var random_scale_enabled: bool = true
var minimum_scale: float = 0.8
var maximum_scale: float = 1.3

var lod_enabled: bool = false
var lod1_scene: PackedScene
var lod2_scene: PackedScene
var lod1_distance: float = 25.0
var lod2_distance: float = 60.0
var lod_cull_distance: float = 0.0
var auto_lod_enabled: bool = false
var auto_lod_bias: float = 1.0
var auto_lod_cull_distance: float = 0.0


var current_language: String = LANGUAGE_ENGLISH
var is_loading_configuration: bool = false
var is_applying_scene_settings: bool = false

var scene_brush_settings: Dictionary = {}

var last_status_source: String = ""
var last_status_display: String = ""
var is_applying_status_translation: bool = false


func _ready() -> void:
	set_process(true)

	_create_interface()
	_load_saved_configuration()

	_apply_language()
	_update_scene_interface()
	_update_controls()

	call_deferred(
		"_emit_loaded_state"
	)


func _process(
	_delta: float
) -> void:
	_watch_external_status_message()


# =========================================================
# إنشاء الواجهة
# =========================================================

func _create_interface() -> void:
	if is_instance_valid(
		settings_scroll
	):
		return

	settings_scroll = ScrollContainer.new()
	settings_scroll.name = "BrushSettingsScroll"

	settings_scroll.size_flags_horizontal = (
		Control.SIZE_EXPAND_FILL
	)

	settings_scroll.size_flags_vertical = (
		Control.SIZE_EXPAND_FILL
	)

	settings_scroll.horizontal_scroll_mode = (
		ScrollContainer.SCROLL_MODE_DISABLED
	)

	settings_scroll.vertical_scroll_mode = (
		ScrollContainer.SCROLL_MODE_AUTO
	)

	settings_scroll.follow_focus = true
	settings_scroll.clip_contents = true

	_insert_before_status(
		settings_scroll
	)

	controls_container = VBoxContainer.new()
	controls_container.name = "BrushControls"

	controls_container.size_flags_horizontal = (
		Control.SIZE_EXPAND_FILL
	)

	controls_container.size_flags_vertical = (
		Control.SIZE_SHRINK_BEGIN
	)

	settings_scroll.add_child(
		controls_container
	)

	_create_language_selector()
	_create_scene_palette()
	_create_auto_lod_controls()
	_create_lod_controls()
	_create_brush_toggle()
	_create_radius_control()
	_create_instances_control()
	_create_spacing_control()
	_create_random_rotation_control()
	_create_align_surface_control()
	_create_maximum_slope_control()
	_create_height_offset_controls()
	_create_random_scale_controls()


func _insert_before_status(
	control: Control
) -> void:
	var status_index := status_label.get_index()

	add_child(
		control
	)

	move_child(
		control,
		status_index
	)


# =========================================================
# اللغة
# =========================================================

func _create_language_selector() -> void:
	language_button = Button.new()
	language_button.name = "LanguageButton"

	language_button.size_flags_horizontal = (
		Control.SIZE_EXPAND_FILL
	)

	language_button.pressed.connect(
		_on_language_button_pressed
	)

	controls_container.add_child(
		language_button
	)

	var separator := HSeparator.new()
	separator.name = "LanguageSeparator"

	controls_container.add_child(
		separator
	)


func _on_language_button_pressed() -> void:
	if current_language == LANGUAGE_ENGLISH:
		current_language = LANGUAGE_ARABIC
	else:
		current_language = LANGUAGE_ENGLISH

	_apply_language()
	_save_configuration()

	if current_language == LANGUAGE_ARABIC:
		_set_status(
			"Interface language changed to Arabic."
		)
	else:
		_set_status(
			"Interface language changed to English."
		)


func _apply_language() -> void:
	var using_arabic := (
		current_language == LANGUAGE_ARABIC
	)

	if using_arabic:
		layout_direction = (
			Control.LAYOUT_DIRECTION_RTL
		)

		status_label.horizontal_alignment = (
			HORIZONTAL_ALIGNMENT_RIGHT
		)
	else:
		layout_direction = (
			Control.LAYOUT_DIRECTION_LTR
		)

		status_label.horizontal_alignment = (
			HORIZONTAL_ALIGNMENT_LEFT
		)

	if is_instance_valid(title_label):
		title_label.text = _tr(
			"title"
		)

	if is_instance_valid(language_button):
		if using_arabic:
			language_button.text = "English"

			language_button.tooltip_text = (
				"Switch the World Brush interface to English."
			)
		else:
			language_button.text = "العربية"

			language_button.tooltip_text = (
				"تغيير واجهة فرشاة العالم إلى العربية."
			)

	if is_instance_valid(palette_title_label):
		palette_title_label.text = _tr(
			"scene_palette"
		)

	if is_instance_valid(previous_scene_button):
		previous_scene_button.text = _tr(
			"previous"
		)

		previous_scene_button.tooltip_text = _tr(
			"previous_tooltip"
		)

	if is_instance_valid(next_scene_button):
		next_scene_button.text = _tr(
			"next"
		)

		next_scene_button.tooltip_text = _tr(
			"next_tooltip"
		)

	if is_instance_valid(add_scene_button):
		add_scene_button.text = _tr(
			"add_scene"
		)

	if is_instance_valid(lod_toggle):
		lod_toggle.text = _tr("add_distant_scene")

	if is_instance_valid(lod1_scene_label):
		lod1_scene_label.text = _tr("medium_scene")

	if is_instance_valid(lod2_scene_label):
		lod2_scene_label.text = _tr("distant_scene")

	if is_instance_valid(lod1_distance_label):
		lod1_distance_label.text = _tr("medium_starts")

	if is_instance_valid(lod2_distance_label):
		lod2_distance_label.text = _tr("distant_starts")

	if is_instance_valid(lod_cull_distance_label):
		lod_cull_distance_label.text = _tr("hide_after")

	if is_instance_valid(lod_help_label):
		lod_help_label.text = _tr("lod_help")

	if is_instance_valid(auto_lod_toggle):
		auto_lod_toggle.text = _tr("auto_lod")

	if is_instance_valid(auto_lod_bias_label):
		auto_lod_bias_label.text = _tr("auto_lod_bias")

	if is_instance_valid(auto_lod_cull_label):
		auto_lod_cull_label.text = _tr("auto_lod_hide_after")

	if is_instance_valid(auto_lod_reimport_button):
		auto_lod_reimport_button.text = _tr("auto_lod_reimport")

	if is_instance_valid(auto_lod_help_label):
		auto_lod_help_label.text = _tr("auto_lod_help")

	if is_instance_valid(brush_toggle):
		brush_toggle.text = _tr(
			"enable_brush"
		)

	if is_instance_valid(brush_radius_label):
		brush_radius_label.text = _tr(
			"brush_radius"
		)

	if is_instance_valid(instances_label):
		instances_label.text = _tr(
			"instances_per_stamp"
		)

	if is_instance_valid(spacing_label):
		spacing_label.text = _tr(
			"minimum_spacing"
		)

	if is_instance_valid(random_rotation_toggle):
		random_rotation_toggle.text = _tr(
			"random_y_rotation"
		)

	if is_instance_valid(align_surface_toggle):
		align_surface_toggle.text = _tr(
			"align_to_surface"
		)

	if is_instance_valid(maximum_slope_label):
		maximum_slope_label.text = _tr(
			"maximum_slope"
		)

	if is_instance_valid(height_offset_label):
		height_offset_label.text = _tr(
			"height_offset"
		)

	if is_instance_valid(height_offset_mode_label):
		height_offset_mode_label.text = _tr(
			"offset_direction"
		)

	if is_instance_valid(height_offset_mode_option):
		height_offset_mode_option.set_item_text(
			HeightOffsetMode.WORLD_Y,
			_tr("world_y")
		)

		height_offset_mode_option.set_item_text(
			HeightOffsetMode.SURFACE_NORMAL,
			_tr("surface_normal")
		)

		height_offset_mode_option.tooltip_text = _tr(
			"offset_mode_tooltip"
		)

		height_offset_mode_option.set_item_tooltip(
			HeightOffsetMode.WORLD_Y,
			_tr("world_y_tooltip")
		)

		height_offset_mode_option.set_item_tooltip(
			HeightOffsetMode.SURFACE_NORMAL,
			_tr("surface_normal_tooltip")
		)

	if is_instance_valid(height_offset_help_label):
		height_offset_help_label.text = _tr(
			"offset_help"
		)

	if is_instance_valid(align_surface_toggle):
		align_surface_toggle.tooltip_text = _tr(
			"align_surface_tooltip"
		)

	if is_instance_valid(random_scale_toggle):
		random_scale_toggle.text = _tr(
			"random_scale"
		)

	if is_instance_valid(minimum_scale_label):
		minimum_scale_label.text = _tr(
			"minimum_scale"
		)

	if is_instance_valid(maximum_scale_label):
		maximum_scale_label.text = _tr(
			"maximum_scale"
		)

	_update_scene_interface()
	_refresh_status_language()


func _tr(
	key: String
) -> String:
	if current_language == LANGUAGE_ARABIC:
		match key:
			"title":
				return "فرشاة العالم"

			"scene_palette":
				return "مكتبة المشاهد"

			"active_scene_none":
				return "المشهد النشط: لا يوجد"

			"previous":
				return "◀ السابق"

			"next":
				return "التالي ▶"

			"previous_tooltip":
				return "اختيار المشهد السابق."

			"next_tooltip":
				return "اختيار المشهد التالي."

			"add_scene":
				return "+ إضافة مشهد"

			"add_distant_scene":
				return "إضافة مشهد بعيد"

			"medium_scene":
				return "المشهد المتوسط"

			"distant_scene":
				return "المشهد البعيد"

			"medium_starts":
				return "بداية المتوسط"

			"distant_starts":
				return "بداية البعيد"

			"hide_after":
				return "الإخفاء بعد"

			"lod_help":
				return "يُستخدم المشهد الأصلي عند القرب، ثم يبدّل Godot تلقائيًا إلى المتوسط والبعيد حسب مسافة الكاميرا. القيمة 0 لمسافة الإخفاء تعني عدم الإخفاء."

			"auto_lod":
				return "Godot Auto LOD — نموذج واحد"

			"auto_lod_bias":
				return "دقة الانتقال"

			"auto_lod_hide_after":
				return "الإخفاء بعد"

			"auto_lod_reimport":
				return "تطبيق وإعادة استيراد هذا المجسم"

			"auto_lod_help":
				return "خاص بالمجسم النشط فقط. يولّد Godot مستويات أخف من النموذج الواحد عند الاستيراد. دقة 0 تفرض أخف مستوى للاختبار، والقيمة الأكبر تحفظ التفاصيل لمسافة أطول. الإخفاء 0 يعني عدم الإخفاء."

			"use":
				return "استخدام"

			"active":
				return "نشط"

			"select_scene_tooltip":
				return "جعل هذا المشهد هو المستخدم في الرسم."

			"remove_scene_tooltip":
				return "حذف المشهد من المكتبة."

			"enable_brush":
				return "تفعيل الفرشاة"

			"brush_radius":
				return "حجم الفرشاة"

			"instances_per_stamp":
				return "عدد العناصر في الضربة"

			"minimum_spacing":
				return "أقل مسافة"

			"random_y_rotation":
				return "دوران عشوائي حول Y"

			"align_to_surface":
				return "تدوير المجسم مع السطح"

			"align_surface_tooltip":
				return "يدير المجسم ليتبع ميل السطح. هذا الخيار مستقل عن اتجاه إزاحة الموضع."

			"maximum_slope":
				return "أقصى ميل مسموح"

			"height_offset":
				return "إزاحة الارتفاع"

			"offset_direction":
				return "اتجاه تحريك الموضع"

			"world_y":
				return "على محور Y"

			"surface_normal":
				return "بعيدًا عن السطح"

			"offset_help":
				return "اتجاه الإزاحة يحرك موضع المجسم فقط. لتغيير ميلانه فعّل خيار تدوير المجسم مع السطح."

			"offset_mode_tooltip":
				return "يحدد اتجاه تحريك موضع المجسم، ولا يغير دورانه."

			"world_y_tooltip":
				return "يحرك المجسم للأعلى أو الأسفل على محور Y العالمي."

			"surface_normal_tooltip":
				return "يحرك المجسم بعيدًا عن السطح أو داخله باتجاه Normal السطح."

			"random_scale":
				return "حجم عشوائي"

			"minimum_scale":
				return "أقل حجم"

			"maximum_scale":
				return "أكبر حجم"

			"unsaved_scene":
				return "مشهد غير محفوظ"

			_:
				return key

	match key:
		"title":
			return "World Brush"

		"scene_palette":
			return "Scene Palette"

		"active_scene_none":
			return "Active Scene: None"

		"previous":
			return "◀ Previous"

		"next":
			return "Next ▶"

		"previous_tooltip":
			return "Select the previous scene."

		"next_tooltip":
			return "Select the next scene."

		"add_scene":
			return "+ Add Scene"

		"add_distant_scene":
			return "Add Distant Scene"

		"medium_scene":
			return "Medium Scene"

		"distant_scene":
			return "Distant Scene"

		"medium_starts":
			return "Medium Starts"

		"distant_starts":
			return "Distant Starts"

		"hide_after":
			return "Hide After"

		"lod_help":
			return "The original scene is used nearby. Godot switches to the medium and distant scenes using camera distance. A hide distance of 0 disables distance culling."

		"auto_lod":
			return "Godot Auto LOD — Single Model"

		"auto_lod_bias":
			return "Transition Detail"

		"auto_lod_hide_after":
			return "Hide After"

		"auto_lod_reimport":
			return "Apply & Reimport This Model"

		"auto_lod_help":
			return "Applies only to the active model. Detail 0 forces the lightest generated LOD for testing; higher values preserve detail farther away. Hide distance 0 disables culling."

		"use":
			return "Use"

		"active":
			return "Active"

		"select_scene_tooltip":
			return "Make this the active painting scene."

		"remove_scene_tooltip":
			return "Remove Scene"

		"enable_brush":
			return "Enable Brush"

		"brush_radius":
			return "Brush Radius"

		"instances_per_stamp":
			return "Instances Per Stamp"

		"minimum_spacing":
			return "Minimum Spacing"

		"random_y_rotation":
			return "Random Y Rotation"

		"align_to_surface":
			return "Rotate With Surface"

		"align_surface_tooltip":
			return "Rotates the instance to follow the surface slope. This is independent from the position offset direction."

		"maximum_slope":
			return "Maximum Slope"

		"height_offset":
			return "Height Offset"

		"offset_direction":
			return "Position Offset Direction"

		"world_y":
			return "Along World Y"

		"surface_normal":
			return "Away From Surface"

		"offset_help":
			return "The offset direction moves the instance position only. Enable Rotate With Surface to change its tilt."

		"offset_mode_tooltip":
			return "Controls the direction used to move the instance position. It does not change rotation."

		"world_y_tooltip":
			return "Moves the instance up or down along the global Y axis."

		"surface_normal_tooltip":
			return "Moves the instance away from or into the surface along its normal."

		"random_scale":
			return "Random Scale"

		"minimum_scale":
			return "Minimum Scale"

		"maximum_scale":
			return "Maximum Scale"

		"unsaved_scene":
			return "Unsaved PackedScene"

		_:
			return key


# =========================================================
# رسائل الحالة
# =========================================================

func _set_status(
	source_message: String
) -> void:
	last_status_source = source_message

	var translated_message := (
		_translate_status_message(
			source_message
		)
	)

	is_applying_status_translation = true
	status_label.text = translated_message
	is_applying_status_translation = false

	last_status_display = translated_message


func _refresh_status_language() -> void:
	if last_status_source.is_empty():
		last_status_source = status_label.text

	_set_status(
		last_status_source
	)


func _watch_external_status_message() -> void:
	if not is_instance_valid(
		status_label
	):
		return

	if is_applying_status_translation:
		return

	var current_text := status_label.text

	if current_text == last_status_display:
		return

	last_status_source = current_text

	var translated_text := (
		_translate_status_message(
			last_status_source
		)
	)

	is_applying_status_translation = true
	status_label.text = translated_text
	is_applying_status_translation = false

	last_status_display = translated_text


func _translate_status_message(
	message: String
) -> String:
	if current_language != LANGUAGE_ARABIC:
		return message

	var exact_translations := {
		"No Scenes Selected":
			"لم يتم اختيار أي مشهد",

		"New Scene Slot Added":
			"تمت إضافة خانة مشهد جديدة",

		"Choose A Scene In This Slot":
			"اختر مشهدًا في هذه الخانة",

		"At Least One Scene Slot Must Remain":
			"يجب أن تبقى خانة مشهد واحدة على الأقل",

		"Select An Active Scene First":
			"اختر مشهدًا نشطًا أولًا",

		"Select A Saved Scene First":
			"اختر مشهدًا محفوظًا أولًا",

		"Auto LOD: Active scene is missing or unsaved":
			"LOD التلقائي: المشهد النشط مفقود أو غير محفوظ",

		"Auto LOD: No supported imported model found in active scene":
			"LOD التلقائي: لم يُعثر على نموذج مستورد مدعوم داخل المشهد النشط",

		"Auto LOD: Import settings could not be updated":
			"LOD التلقائي: تعذر تحديث إعدادات الاستيراد",

		"Auto LOD: Reimporting active model only...":
			"LOD التلقائي: جارٍ إعادة استيراد المجسم النشط فقط...",

		"Auto LOD enabled for active model":
			"تم تفعيل LOD التلقائي للمجسم النشط",

		"Auto LOD disabled for active model":
			"تم تعطيل LOD التلقائي للمجسم النشط",

		"Brush Disabled":
			"الفرشاة متوقفة",

		"No Valid Surface":
			"لا يوجد سطح صالح",

		"Selected Scene Cannot Be Instantiated":
			"لا يمكن إنشاء نسخة من المشهد المختار",

		"Scene Root Must Be Node3D":
			"يجب أن يكون جذر المشهد من نوع Node3D",

		"3D World Not Available":
			"العالم ثلاثي الأبعاد غير متاح",

		"Edited Scene Changed During Stroke":
			"تم تغيير المشهد أثناء استخدام الفرشاة",

		"Failed To Create Container":
			"تعذر إنشاء حاوية عناصر الفرشاة",

		"No Valid Space Inside Brush":
			"لا توجد مساحة صالحة داخل الفرشاة",

		"Selected Scene Root Must Inherit Node3D":
			"يجب أن يرث جذر المشهد المختار من Node3D",

		"No World Brush Instances":
			"لا توجد عناصر منشورة بواسطة الفرشاة",

		"Open A 3D Scene First":
			"افتح مشهدًا ثلاثي الأبعاد أولًا",

		"No Surface Under Cursor":
			"لا يوجد سطح أسفل المؤشر",

		"Invalid Surface Position":
			"موضع السطح غير صالح",

		"Erase Brush — No Instances Here":
			"فرشاة الحذف — لا توجد عناصر هنا",

		"Interface language changed to Arabic.":
			"تم تغيير لغة واجهة الفرشاة إلى العربية.",

		"Interface language changed to English.":
			"تم تغيير لغة واجهة الفرشاة إلى الإنجليزية.",
	}

	if exact_translations.has(
		message
	):
		return str(
			exact_translations[message]
		)

	var prefix_translations := {
		"Active: ":
			"المشهد النشط: ",

		"Brush Enabled — ":
			"الفرشاة مفعّلة — ",

		"Palette Restored: ":
			"تمت استعادة المكتبة: ",

		"Painted In Stroke: ":
			"العناصر المرسومة في السحبة: ",

		"Erased In Stroke: ":
			"العناصر المحذوفة في السحبة: ",

		"Paint Stroke Saved: ":
			"تم حفظ سحبة الرسم: ",

		"Erase Stroke Saved: ":
			"تم حفظ سحبة الحذف: ",
	}

	for english_prefix in prefix_translations:
		if not message.begins_with(
			english_prefix
		):
			continue

		return (
			str(
				prefix_translations[
					english_prefix
				]
			)
			+ message.substr(
				english_prefix.length()
			)
		)

	if message.begins_with(
		"Physics | "
	):
		return (
			"سطح فيزيائي | "
			+ message.substr(
				"Physics | ".length()
			)
		)

	if message.begins_with(
		"Surface | "
	):
		return (
			"سطح | "
			+ message.substr(
				"Surface | ".length()
			)
		)

	return message


# =========================================================
# مكتبة المشاهد
# =========================================================

func _create_scene_palette() -> void:
	palette_title_label = Label.new()
	palette_title_label.name = "ScenePaletteTitle"
	palette_title_label.text = "Scene Palette"

	controls_container.add_child(
		palette_title_label
	)

	active_scene_label = Label.new()
	active_scene_label.name = "ActiveSceneLabel"
	active_scene_label.text = "Active Scene: None"

	controls_container.add_child(
		active_scene_label
	)

	_create_scene_navigation()

	var separator := HSeparator.new()
	separator.name = "PaletteSeparator"

	controls_container.add_child(
		separator
	)

	scenes_list = VBoxContainer.new()
	scenes_list.name = "ScenesList"

	scenes_list.size_flags_horizontal = (
		Control.SIZE_EXPAND_FILL
	)

	controls_container.add_child(
		scenes_list
	)

	add_scene_button = Button.new()
	add_scene_button.name = "AddSceneButton"
	add_scene_button.text = "+ Add Scene"

	add_scene_button.size_flags_horizontal = (
		Control.SIZE_EXPAND_FILL
	)

	add_scene_button.pressed.connect(
		_on_add_scene_pressed
	)

	controls_container.add_child(
		add_scene_button
	)


func _create_scene_navigation() -> void:
	var navigation_row := HBoxContainer.new()
	navigation_row.name = "SceneNavigation"

	navigation_row.size_flags_horizontal = (
		Control.SIZE_EXPAND_FILL
	)

	previous_scene_button = Button.new()
	previous_scene_button.name = (
		"PreviousSceneButton"
	)

	previous_scene_button.text = "◀ Previous"

	previous_scene_button.size_flags_horizontal = (
		Control.SIZE_EXPAND_FILL
	)

	previous_scene_button.pressed.connect(
		_on_previous_scene_pressed
	)

	next_scene_button = Button.new()
	next_scene_button.name = "NextSceneButton"
	next_scene_button.text = "Next ▶"

	next_scene_button.size_flags_horizontal = (
		Control.SIZE_EXPAND_FILL
	)

	next_scene_button.pressed.connect(
		_on_next_scene_pressed
	)

	navigation_row.add_child(
		previous_scene_button
	)

	navigation_row.add_child(
		next_scene_button
	)

	controls_container.add_child(
		navigation_row
	)


func _create_auto_lod_controls() -> void:
	var separator := HSeparator.new()
	separator.name = "AutoLODSeparator"
	controls_container.add_child(separator)

	auto_lod_toggle = CheckButton.new()
	auto_lod_toggle.name = "AutoLODToggle"
	auto_lod_toggle.text = "Godot Auto LOD — Single Model"
	auto_lod_toggle.button_pressed = auto_lod_enabled
	auto_lod_toggle.tooltip_text = "Independent setting for the active palette model only."
	auto_lod_toggle.toggled.connect(_on_auto_lod_toggled)
	controls_container.add_child(auto_lod_toggle)

	auto_lod_controls_container = VBoxContainer.new()
	auto_lod_controls_container.name = "AutoLODControls"
	auto_lod_controls_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	controls_container.add_child(auto_lod_controls_container)

	var bias_row := HBoxContainer.new()
	auto_lod_bias_label = Label.new()
	auto_lod_bias_label.text = "Transition Detail"
	auto_lod_bias_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	auto_lod_bias_spin_box = SpinBox.new()
	auto_lod_bias_spin_box.name = "AutoLODBiasSpinBox"
	auto_lod_bias_spin_box.min_value = 0.0
	auto_lod_bias_spin_box.max_value = 4.0
	auto_lod_bias_spin_box.step = 0.05
	auto_lod_bias_spin_box.value = auto_lod_bias
	auto_lod_bias_spin_box.suffix = " ×"
	auto_lod_bias_spin_box.custom_minimum_size.x = 105.0
	auto_lod_bias_spin_box.value_changed.connect(_on_auto_lod_bias_changed)
	bias_row.add_child(auto_lod_bias_label)
	bias_row.add_child(auto_lod_bias_spin_box)
	auto_lod_controls_container.add_child(bias_row)

	var cull_row := HBoxContainer.new()
	auto_lod_cull_label = Label.new()
	auto_lod_cull_label.text = "Hide After"
	auto_lod_cull_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	auto_lod_cull_spin_box = _create_lod_distance_spin_box(
		"AutoLODCullDistanceSpinBox",
		auto_lod_cull_distance
	)
	auto_lod_cull_spin_box.min_value = 0.0
	auto_lod_cull_spin_box.value_changed.connect(_on_auto_lod_cull_changed)
	cull_row.add_child(auto_lod_cull_label)
	cull_row.add_child(auto_lod_cull_spin_box)
	auto_lod_controls_container.add_child(cull_row)

	auto_lod_reimport_button = Button.new()
	auto_lod_reimport_button.name = "AutoLODReimportButton"
	auto_lod_reimport_button.text = "Apply & Reimport This Model"
	auto_lod_reimport_button.tooltip_text = "Changes Generate LODs only for the active model source, then reimports it."
	auto_lod_reimport_button.pressed.connect(_on_auto_lod_reimport_pressed)
	auto_lod_controls_container.add_child(auto_lod_reimport_button)

	auto_lod_help_label = Label.new()
	auto_lod_help_label.name = "AutoLODHelpLabel"
	auto_lod_help_label.text = "Godot generates lighter mesh levels from the active single model during import."
	auto_lod_help_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	auto_lod_help_label.modulate = Color(0.82, 0.90, 1.0, 0.78)
	auto_lod_controls_container.add_child(auto_lod_help_label)
	_update_auto_lod_controls()


func _create_lod_controls() -> void:
	var separator := HSeparator.new()
	separator.name = "DistanceLODSeparator"
	controls_container.add_child(separator)

	lod_toggle = CheckButton.new()
	lod_toggle.name = "DistanceLODToggle"
	lod_toggle.text = "Add Distant Scene"
	lod_toggle.button_pressed = lod_enabled
	lod_toggle.toggled.connect(_on_lod_toggled)
	controls_container.add_child(lod_toggle)

	lod_controls_container = VBoxContainer.new()
	lod_controls_container.name = "DistanceLODControls"
	lod_controls_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	controls_container.add_child(lod_controls_container)

	var lod1_row := HBoxContainer.new()
	lod1_row.name = "LOD1SceneContainer"
	lod1_scene_label = Label.new()
	lod1_scene_label.text = "Medium Scene"
	lod1_scene_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lod1_picker = EditorResourcePicker.new()
	lod1_picker.name = "LOD1ScenePicker"
	lod1_picker.base_type = "PackedScene"
	lod1_picker.editable = true
	lod1_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lod1_picker.resource_changed.connect(_on_lod1_scene_changed)
	lod1_row.add_child(lod1_scene_label)
	lod1_row.add_child(lod1_picker)
	lod_controls_container.add_child(lod1_row)

	var lod2_row := HBoxContainer.new()
	lod2_row.name = "LOD2SceneContainer"
	lod2_scene_label = Label.new()
	lod2_scene_label.text = "Distant Scene"
	lod2_scene_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lod2_picker = EditorResourcePicker.new()
	lod2_picker.name = "LOD2ScenePicker"
	lod2_picker.base_type = "PackedScene"
	lod2_picker.editable = true
	lod2_picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lod2_picker.resource_changed.connect(_on_lod2_scene_changed)
	lod2_row.add_child(lod2_scene_label)
	lod2_row.add_child(lod2_picker)
	lod_controls_container.add_child(lod2_row)

	var lod1_distance_row := HBoxContainer.new()
	lod1_distance_row.name = "LOD1DistanceContainer"
	lod1_distance_label = Label.new()
	lod1_distance_label.text = "Medium Starts"
	lod1_distance_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lod1_distance_spin_box = _create_lod_distance_spin_box(
		"LOD1DistanceSpinBox",
		lod1_distance
	)
	lod1_distance_spin_box.value_changed.connect(_on_lod1_distance_changed)
	lod1_distance_row.add_child(lod1_distance_label)
	lod1_distance_row.add_child(lod1_distance_spin_box)
	lod_controls_container.add_child(lod1_distance_row)

	var lod2_distance_row := HBoxContainer.new()
	lod2_distance_row.name = "LOD2DistanceContainer"
	lod2_distance_label = Label.new()
	lod2_distance_label.text = "Distant Starts"
	lod2_distance_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lod2_distance_spin_box = _create_lod_distance_spin_box(
		"LOD2DistanceSpinBox",
		lod2_distance
	)
	lod2_distance_spin_box.value_changed.connect(_on_lod2_distance_changed)
	lod2_distance_row.add_child(lod2_distance_label)
	lod2_distance_row.add_child(lod2_distance_spin_box)
	lod_controls_container.add_child(lod2_distance_row)

	var cull_row := HBoxContainer.new()
	cull_row.name = "LODCullDistanceContainer"
	lod_cull_distance_label = Label.new()
	lod_cull_distance_label.text = "Hide After"
	lod_cull_distance_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lod_cull_distance_spin_box = _create_lod_distance_spin_box(
		"LODCullDistanceSpinBox",
		lod_cull_distance
	)
	lod_cull_distance_spin_box.min_value = 0.0
	lod_cull_distance_spin_box.tooltip_text = "0 keeps the distant scene visible without a maximum distance."
	lod_cull_distance_spin_box.value_changed.connect(_on_lod_cull_distance_changed)
	cull_row.add_child(lod_cull_distance_label)
	cull_row.add_child(lod_cull_distance_spin_box)
	lod_controls_container.add_child(cull_row)

	lod_help_label = Label.new()
	lod_help_label.name = "DistanceLODHelpLabel"
	lod_help_label.text = "The original scene is used nearby. Godot switches to the medium and distant scenes using camera distance."
	lod_help_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lod_help_label.modulate = Color(1.0, 1.0, 1.0, 0.72)
	lod_controls_container.add_child(lod_help_label)

	_update_lod_controls()


func _create_lod_distance_spin_box(
	control_name: String,
	value: float
) -> SpinBox:
	var spin_box := SpinBox.new()
	spin_box.name = control_name
	spin_box.min_value = 1.0
	spin_box.max_value = 100000.0
	spin_box.step = 1.0
	spin_box.value = value
	spin_box.allow_greater = true
	spin_box.suffix = " m"
	spin_box.custom_minimum_size.x = 105.0
	return spin_box


func _on_lod_toggled(enabled: bool) -> void:
	lod_enabled = enabled
	_update_lod_controls()
	_emit_lod_settings_changed()
	_save_configuration()


func _on_auto_lod_toggled(enabled: bool) -> void:
	auto_lod_enabled = enabled
	_update_auto_lod_controls()
	_emit_auto_lod_settings_changed()
	_save_configuration()
	_request_auto_lod_reimport()


func _on_auto_lod_bias_changed(value: float) -> void:
	auto_lod_bias = clampf(value, 0.0, 4.0)
	auto_lod_bias_spin_box.set_value_no_signal(auto_lod_bias)
	_emit_auto_lod_settings_changed()
	_save_configuration()


func _on_auto_lod_cull_changed(value: float) -> void:
	auto_lod_cull_distance = maxf(value, 0.0)
	auto_lod_cull_spin_box.set_value_no_signal(auto_lod_cull_distance)
	_emit_auto_lod_settings_changed()
	_save_configuration()


func _on_auto_lod_reimport_pressed() -> void:
	_request_auto_lod_reimport()


func _request_auto_lod_reimport() -> void:
	if selected_scene == null or selected_scene.resource_path.is_empty():
		_set_status("Select A Saved Scene First")
		return
	auto_lod_import_requested.emit(
		selected_scene.resource_path,
		auto_lod_enabled
	)


func _emit_auto_lod_settings_changed() -> void:
	auto_lod_settings_changed.emit(
		auto_lod_enabled,
		auto_lod_bias,
		auto_lod_cull_distance
	)


func _update_auto_lod_controls() -> void:
	var has_active_scene := selected_scene != null
	if is_instance_valid(auto_lod_toggle):
		auto_lod_toggle.visible = has_active_scene
		auto_lod_toggle.disabled = not has_active_scene
	if is_instance_valid(auto_lod_controls_container):
		auto_lod_controls_container.visible = has_active_scene and auto_lod_enabled
	var details_enabled := has_active_scene and auto_lod_enabled
	if is_instance_valid(auto_lod_bias_spin_box):
		auto_lod_bias_spin_box.editable = details_enabled
	if is_instance_valid(auto_lod_cull_spin_box):
		auto_lod_cull_spin_box.editable = details_enabled
	if is_instance_valid(auto_lod_reimport_button):
		auto_lod_reimport_button.disabled = not details_enabled


func _on_lod1_scene_changed(resource: Resource) -> void:
	lod1_scene = resource as PackedScene
	_emit_lod_settings_changed()
	_save_configuration()


func _on_lod2_scene_changed(resource: Resource) -> void:
	lod2_scene = resource as PackedScene
	_emit_lod_settings_changed()
	_save_configuration()


func _on_lod1_distance_changed(value: float) -> void:
	lod1_distance = maxf(value, 1.0)
	if lod2_distance <= lod1_distance:
		lod2_distance = lod1_distance + 1.0
		lod2_distance_spin_box.set_value_no_signal(lod2_distance)
	_validate_lod_cull_distance()
	_emit_lod_settings_changed()
	_save_configuration()


func _on_lod2_distance_changed(value: float) -> void:
	lod2_distance = maxf(value, lod1_distance + 1.0)
	lod2_distance_spin_box.set_value_no_signal(lod2_distance)
	_validate_lod_cull_distance()
	_emit_lod_settings_changed()
	_save_configuration()


func _on_lod_cull_distance_changed(value: float) -> void:
	lod_cull_distance = maxf(value, 0.0)
	_validate_lod_cull_distance()
	_emit_lod_settings_changed()
	_save_configuration()


func _validate_lod_cull_distance() -> void:
	lod_cull_distance = maxf(lod_cull_distance, 0.0)
	if is_instance_valid(lod_cull_distance_spin_box):
		lod_cull_distance_spin_box.set_value_no_signal(lod_cull_distance)


func _emit_lod_settings_changed() -> void:
	lod_settings_changed.emit(
		lod_enabled,
		lod1_scene,
		lod2_scene,
		lod1_distance,
		lod2_distance,
		lod_cull_distance
	)


func _update_lod_controls() -> void:
	var has_active_scene := selected_scene != null
	if is_instance_valid(lod_toggle):
		lod_toggle.visible = has_active_scene
		lod_toggle.disabled = not has_active_scene
	if is_instance_valid(lod_controls_container):
		lod_controls_container.visible = has_active_scene and lod_enabled
	var details_enabled := has_active_scene and lod_enabled
	if is_instance_valid(lod1_picker):
		lod1_picker.editable = details_enabled
	if is_instance_valid(lod2_picker):
		lod2_picker.editable = details_enabled
	if is_instance_valid(lod1_distance_spin_box):
		lod1_distance_spin_box.editable = details_enabled
	if is_instance_valid(lod2_distance_spin_box):
		lod2_distance_spin_box.editable = details_enabled
	if is_instance_valid(lod_cull_distance_spin_box):
		lod_cull_distance_spin_box.editable = details_enabled


func _add_scene_row(
	initial_scene: PackedScene = null,
	update_after_creation: bool = true
) -> EditorResourcePicker:
	var row := HBoxContainer.new()

	row.name = "SceneRow_%d" % (
		scene_rows.size() + 1
	)

	row.size_flags_horizontal = (
		Control.SIZE_EXPAND_FILL
	)

	var picker := EditorResourcePicker.new()
	picker.name = "ScenePicker"
	picker.base_type = "PackedScene"
	picker.editable = true

	picker.size_flags_horizontal = (
		Control.SIZE_EXPAND_FILL
	)

	if initial_scene != null:
		picker.edited_resource = initial_scene

	var select_button := Button.new()
	select_button.name = "SelectSceneButton"
	select_button.text = "Use"

	select_button.custom_minimum_size = Vector2(
		62.0,
		0.0
	)

	var remove_button := Button.new()
	remove_button.name = "RemoveSceneButton"
	remove_button.text = "×"

	remove_button.custom_minimum_size = Vector2(
		38.0,
		0.0
	)

	row.add_child(
		picker
	)

	row.add_child(
		select_button
	)

	row.add_child(
		remove_button
	)

	scenes_list.add_child(
		row
	)

	scene_rows.append(
		{
			"row": row,
			"picker": picker,
			"select_button": select_button,
			"remove_button": remove_button,
		}
	)

	picker.resource_changed.connect(
		_on_scene_resource_changed.bind(
			picker
		)
	)

	select_button.pressed.connect(
		_on_select_scene_pressed.bind(
			picker
		)
	)

	remove_button.pressed.connect(
		_on_remove_scene_pressed.bind(
			picker
		)
	)

	if update_after_creation:
		_update_scene_interface()

	return picker


func _on_add_scene_pressed() -> void:
	_add_scene_row()

	_set_status(
		"New Scene Slot Added"
	)


func _on_scene_resource_changed(
	resource: Resource,
	picker: EditorResourcePicker
) -> void:
	var packed_scene := (
		resource as PackedScene
	)

	var picker_was_active := (
		picker == active_picker
	)

	if picker_was_active:
		_store_current_scene_settings()

	if (
		packed_scene != null
		and not is_instance_valid(
			active_picker
		)
	):
		active_picker = picker
		selected_scene = packed_scene

	elif picker_was_active:
		if packed_scene == null:
			active_picker = null
			selected_scene = null

			_select_first_available_scene()
		else:
			selected_scene = packed_scene

	if (
		picker == active_picker
		and selected_scene != null
	):
		_load_active_scene_settings(
			false
		)

	_update_scene_interface()
	_emit_palette_changed()
	_emit_active_scene_changed()
	_emit_all_brush_settings_changed()
	_save_configuration()


func _on_select_scene_pressed(
	picker: EditorResourcePicker
) -> void:
	if not is_instance_valid(
		picker
	):
		return

	var packed_scene := (
		picker.edited_resource
		as PackedScene
	)

	if packed_scene == null:
		_set_status(
			"Choose A Scene In This Slot"
		)

		return

	_set_active_picker(
		picker
	)


func _on_remove_scene_pressed(
	picker: EditorResourcePicker
) -> void:
	if scene_rows.size() <= 1:
		_set_status(
			"At Least One Scene Slot Must Remain"
		)

		return

	var row_to_remove: Control = null
	var index_to_remove: int = -1

	var removed_active_scene := (
		picker == active_picker
	)

	if removed_active_scene:
		_store_current_scene_settings()

	for index in range(
		scene_rows.size()
	):
		var entry_picker := (
			scene_rows[index].get(
				"picker"
			)
			as EditorResourcePicker
		)

		if entry_picker != picker:
			continue

		row_to_remove = (
			scene_rows[index].get(
				"row"
			)
			as Control
		)

		index_to_remove = index
		break

	if index_to_remove < 0:
		return

	scene_rows.remove_at(
		index_to_remove
	)

	if removed_active_scene:
		active_picker = null
		selected_scene = null

	if is_instance_valid(
		row_to_remove
	):
		row_to_remove.queue_free()

	if removed_active_scene:
		_select_available_scene_near_index(
			index_to_remove
		)

		_load_active_scene_settings(
			false
		)

	_update_scene_interface()
	_emit_palette_changed()
	_emit_active_scene_changed()

	if removed_active_scene:
		_emit_all_brush_settings_changed()

	_save_configuration()


func _on_previous_scene_pressed() -> void:
	_change_active_scene(
		-1
	)


func _on_next_scene_pressed() -> void:
	_change_active_scene(
		1
	)


func _change_active_scene(
	direction: int
) -> void:
	var valid_pickers := (
		_get_valid_scene_pickers()
	)

	if valid_pickers.is_empty():
		active_picker = null
		selected_scene = null

		_update_scene_interface()
		_emit_active_scene_changed()
		_save_configuration()

		return

	var current_index := valid_pickers.find(
		active_picker
	)

	if current_index < 0:
		current_index = 0
	else:
		current_index = posmod(
			current_index + direction,
			valid_pickers.size()
		)

	_set_active_picker(
		valid_pickers[current_index]
	)


func _set_active_picker(
	picker: EditorResourcePicker
) -> void:
	if not is_instance_valid(
		picker
	):
		return

	var packed_scene := (
		picker.edited_resource
		as PackedScene
	)

	if packed_scene == null:
		return

	_store_current_scene_settings()

	active_picker = picker
	selected_scene = packed_scene

	_load_active_scene_settings(
		false
	)

	_update_scene_interface()
	_emit_active_scene_changed()
	_emit_all_brush_settings_changed()
	_save_configuration()

	_set_status(
		"Active: %s"
		% _get_scene_display_name(
			selected_scene
		)
	)


func _select_first_available_scene() -> void:
	var valid_pickers := (
		_get_valid_scene_pickers()
	)

	if valid_pickers.is_empty():
		active_picker = null
		selected_scene = null

		return

	active_picker = valid_pickers[0]

	selected_scene = (
		active_picker.edited_resource
		as PackedScene
	)


func _select_available_scene_near_index(
	preferred_index: int
) -> void:
	if scene_rows.is_empty():
		active_picker = null
		selected_scene = null

		return

	var clamped_index := clampi(
		preferred_index,
		0,
		scene_rows.size() - 1
	)

	for index in range(
		clamped_index,
		scene_rows.size()
	):
		var picker := _get_picker_from_row(
			scene_rows[index]
		)

		if not _picker_has_scene(
			picker
		):
			continue

		active_picker = picker

		selected_scene = (
			picker.edited_resource
			as PackedScene
		)

		return

	for index in range(
		clamped_index - 1,
		-1,
		-1
	):
		var picker := _get_picker_from_row(
			scene_rows[index]
		)

		if not _picker_has_scene(
			picker
		):
			continue

		active_picker = picker

		selected_scene = (
			picker.edited_resource
			as PackedScene
		)

		return

	active_picker = null
	selected_scene = null


# =========================================================
# حفظ وتحميل الإعدادات
# =========================================================

func _save_configuration() -> void:
	if is_loading_configuration:
		return

	_store_current_scene_settings()

	var scene_paths := PackedStringArray()

	for picker in _get_valid_scene_pickers():
		var packed_scene := (
			picker.edited_resource
			as PackedScene
		)

		if packed_scene == null:
			continue

		if packed_scene.resource_path.is_empty():
			continue

		scene_paths.append(
			packed_scene.resource_path
		)

	var active_scene_path := ""

	if is_instance_valid(
		active_picker
	):
		var active_scene := (
			active_picker.edited_resource
			as PackedScene
		)

		if active_scene != null:
			active_scene_path = (
				active_scene.resource_path
			)

	var config := ConfigFile.new()

	config.set_value(
		PALETTE_SECTION,
		CONFIG_SCENE_PATHS,
		scene_paths
	)

	config.set_value(
		PALETTE_SECTION,
		CONFIG_ACTIVE_SCENE_PATH,
		active_scene_path
	)

	config.set_value(
		SETTINGS_SECTION,
		CONFIG_BRUSH_RADIUS,
		brush_radius
	)

	config.set_value(
		SETTINGS_SECTION,
		CONFIG_INSTANCES_PER_STAMP,
		instances_per_click
	)

	config.set_value(
		SETTINGS_SECTION,
		CONFIG_MINIMUM_SPACING,
		minimum_spacing
	)

	config.set_value(
		SETTINGS_SECTION,
		CONFIG_RANDOM_Y_ROTATION,
		random_y_rotation
	)

	config.set_value(
		SETTINGS_SECTION,
		CONFIG_ALIGN_TO_SURFACE,
		align_to_surface
	)

	config.set_value(
		SETTINGS_SECTION,
		CONFIG_MAXIMUM_SLOPE,
		maximum_slope_degrees
	)

	config.set_value(
		SETTINGS_SECTION,
		CONFIG_HEIGHT_OFFSET,
		height_offset
	)

	config.set_value(
		SETTINGS_SECTION,
		CONFIG_HEIGHT_OFFSET_MODE,
		height_offset_mode
	)

	config.set_value(
		SETTINGS_SECTION,
		CONFIG_RANDOM_SCALE_ENABLED,
		random_scale_enabled
	)

	config.set_value(
		SETTINGS_SECTION,
		CONFIG_MINIMUM_SCALE,
		minimum_scale
	)

	config.set_value(
		SETTINGS_SECTION,
		CONFIG_MAXIMUM_SCALE,
		maximum_scale
	)

	config.set_value(
		SETTINGS_SECTION,
		CONFIG_LOD_ENABLED,
		lod_enabled
	)

	config.set_value(
		SETTINGS_SECTION,
		CONFIG_LOD1_SCENE_PATH,
		_get_packed_scene_path(lod1_scene)
	)

	config.set_value(
		SETTINGS_SECTION,
		CONFIG_LOD2_SCENE_PATH,
		_get_packed_scene_path(lod2_scene)
	)

	config.set_value(
		SETTINGS_SECTION,
		CONFIG_LOD1_DISTANCE,
		lod1_distance
	)

	config.set_value(
		SETTINGS_SECTION,
		CONFIG_LOD2_DISTANCE,
		lod2_distance
	)

	config.set_value(
		SETTINGS_SECTION,
		CONFIG_LOD_CULL_DISTANCE,
		lod_cull_distance
	)

	config.set_value(
		SETTINGS_SECTION,
		CONFIG_AUTO_LOD_ENABLED,
		auto_lod_enabled
	)

	config.set_value(
		SETTINGS_SECTION,
		CONFIG_AUTO_LOD_BIAS,
		auto_lod_bias
	)

	config.set_value(
		SETTINGS_SECTION,
		CONFIG_AUTO_LOD_CULL_DISTANCE,
		auto_lod_cull_distance
	)

	config.set_value(
		INTERFACE_SECTION,
		CONFIG_INTERFACE_LANGUAGE,
		current_language
	)

	config.set_value(
		SCENE_SETTINGS_SECTION,
		CONFIG_SCENE_SETTINGS,
		scene_brush_settings
	)

	var save_error := config.save(
		PALETTE_CONFIG_PATH
	)

	if save_error != OK:
		push_warning(
			"World Brush: Failed to save configuration. Error: %s"
			% error_string(save_error)
		)


func _load_saved_configuration() -> void:
	is_loading_configuration = true

	var config := ConfigFile.new()

	var load_error := config.load(
		PALETTE_CONFIG_PATH
	)

	if load_error != OK:
		_add_scene_row(
			null,
			false
		)

		is_loading_configuration = false
		return

	_load_interface_settings(
		config
	)

	_load_brush_settings(
		config
	)

	_load_scene_brush_settings(
		config
	)

	var stored_paths: Variant = config.get_value(
		PALETTE_SECTION,
		CONFIG_SCENE_PATHS,
		PackedStringArray()
	)

	var active_scene_path := str(
		config.get_value(
			PALETTE_SECTION,
			CONFIG_ACTIVE_SCENE_PATH,
			""
		)
	)

	var scene_paths: Array[String] = []

	if typeof(
		stored_paths
	) == TYPE_PACKED_STRING_ARRAY:
		for path_value in stored_paths:
			scene_paths.append(
				str(path_value)
			)

	elif typeof(
		stored_paths
	) == TYPE_ARRAY:
		for path_value in stored_paths:
			scene_paths.append(
				str(path_value)
			)

	for scene_path in scene_paths:
		if scene_path.is_empty():
			continue

		if not ResourceLoader.exists(
			scene_path,
			"PackedScene"
		):
			push_warning(
				"World Brush: Saved scene no longer exists -> %s"
				% scene_path
			)

			continue

		var loaded_scene := (
			ResourceLoader.load(
				scene_path,
				"PackedScene"
			)
			as PackedScene
		)

		if loaded_scene == null:
			continue

		var picker := _add_scene_row(
			loaded_scene,
			false
		)

		if scene_path == active_scene_path:
			active_picker = picker
			selected_scene = loaded_scene

	if scene_rows.is_empty():
		_add_scene_row(
			null,
			false
		)

	if not is_instance_valid(
		active_picker
	):
		_select_first_available_scene()

	_load_active_scene_settings(
		false
	)

	is_loading_configuration = false


func _load_interface_settings(
	config: ConfigFile
) -> void:
	var stored_language := str(
		config.get_value(
			INTERFACE_SECTION,
			CONFIG_INTERFACE_LANGUAGE,
			LANGUAGE_ENGLISH
		)
	)

	if (
		stored_language != LANGUAGE_ENGLISH
		and stored_language != LANGUAGE_ARABIC
	):
		stored_language = LANGUAGE_ENGLISH

	current_language = stored_language


func _get_packed_scene_path(scene: PackedScene) -> String:
	if scene == null:
		return ""
	return scene.resource_path


func _load_packed_scene(scene_path: String) -> PackedScene:
	if scene_path.is_empty():
		return null
	if not ResourceLoader.exists(scene_path, "PackedScene"):
		return null
	return ResourceLoader.load(scene_path, "PackedScene") as PackedScene


func _load_brush_settings(
	config: ConfigFile
) -> void:
	brush_radius = maxf(
		float(
			config.get_value(
				SETTINGS_SECTION,
				CONFIG_BRUSH_RADIUS,
				brush_radius
			)
		),
		0.5
	)

	instances_per_click = maxi(
		int(
			config.get_value(
				SETTINGS_SECTION,
				CONFIG_INSTANCES_PER_STAMP,
				instances_per_click
			)
		),
		1
	)

	minimum_spacing = maxf(
		float(
			config.get_value(
				SETTINGS_SECTION,
				CONFIG_MINIMUM_SPACING,
				minimum_spacing
			)
		),
		0.0
	)

	random_y_rotation = bool(
		config.get_value(
			SETTINGS_SECTION,
			CONFIG_RANDOM_Y_ROTATION,
			random_y_rotation
		)
	)

	align_to_surface = bool(
		config.get_value(
			SETTINGS_SECTION,
			CONFIG_ALIGN_TO_SURFACE,
			align_to_surface
		)
	)

	maximum_slope_degrees = clampf(
		float(
			config.get_value(
				SETTINGS_SECTION,
				CONFIG_MAXIMUM_SLOPE,
				maximum_slope_degrees
			)
		),
		0.0,
		90.0
	)

	height_offset = float(
		config.get_value(
			SETTINGS_SECTION,
			CONFIG_HEIGHT_OFFSET,
			height_offset
		)
	)

	height_offset_mode = int(
		config.get_value(
			SETTINGS_SECTION,
			CONFIG_HEIGHT_OFFSET_MODE,
			HeightOffsetMode.SURFACE_NORMAL
		)
	)

	height_offset_mode = clampi(
		height_offset_mode,
		HeightOffsetMode.WORLD_Y,
		HeightOffsetMode.SURFACE_NORMAL
	)

	random_scale_enabled = bool(
		config.get_value(
			SETTINGS_SECTION,
			CONFIG_RANDOM_SCALE_ENABLED,
			random_scale_enabled
		)
	)

	minimum_scale = maxf(
		float(
			config.get_value(
				SETTINGS_SECTION,
				CONFIG_MINIMUM_SCALE,
				minimum_scale
			)
		),
		0.01
	)

	maximum_scale = maxf(
		float(
			config.get_value(
				SETTINGS_SECTION,
				CONFIG_MAXIMUM_SCALE,
				maximum_scale
			)
		),
		0.01
	)

	if minimum_scale > maximum_scale:
		maximum_scale = minimum_scale

	lod_enabled = bool(
		config.get_value(
			SETTINGS_SECTION,
			CONFIG_LOD_ENABLED,
			lod_enabled
		)
	)

	lod1_scene = _load_packed_scene(
		str(config.get_value(
			SETTINGS_SECTION,
			CONFIG_LOD1_SCENE_PATH,
			""
		))
	)

	lod2_scene = _load_packed_scene(
		str(config.get_value(
			SETTINGS_SECTION,
			CONFIG_LOD2_SCENE_PATH,
			""
		))
	)

	lod1_distance = maxf(
		float(config.get_value(
			SETTINGS_SECTION,
			CONFIG_LOD1_DISTANCE,
			lod1_distance
		)),
		1.0
	)

	lod2_distance = maxf(
		float(config.get_value(
			SETTINGS_SECTION,
			CONFIG_LOD2_DISTANCE,
			lod2_distance
		)),
		lod1_distance + 1.0
	)

	lod_cull_distance = maxf(
		float(config.get_value(
			SETTINGS_SECTION,
			CONFIG_LOD_CULL_DISTANCE,
			lod_cull_distance
		)),
		0.0
	)
	_validate_lod_cull_distance()

	auto_lod_enabled = bool(
		config.get_value(
			SETTINGS_SECTION,
			CONFIG_AUTO_LOD_ENABLED,
			auto_lod_enabled
		)
	)
	auto_lod_bias = clampf(
		float(config.get_value(
			SETTINGS_SECTION,
			CONFIG_AUTO_LOD_BIAS,
			auto_lod_bias
		)),
		0.0,
		4.0
	)
	auto_lod_cull_distance = maxf(
		float(config.get_value(
			SETTINGS_SECTION,
			CONFIG_AUTO_LOD_CULL_DISTANCE,
			auto_lod_cull_distance
		)),
		0.0
	)

	_apply_settings_to_controls()


func _load_scene_brush_settings(
	config: ConfigFile
) -> void:
	scene_brush_settings.clear()

	var stored_profiles: Variant = config.get_value(
		SCENE_SETTINGS_SECTION,
		CONFIG_SCENE_SETTINGS,
		{}
	)

	if typeof(
		stored_profiles
	) != TYPE_DICTIONARY:
		return

	var profiles_dictionary: Dictionary = (
		stored_profiles
	)

	for stored_scene_path in profiles_dictionary:
		var scene_path := str(
			stored_scene_path
		)

		var stored_profile: Variant = (
			profiles_dictionary[
				stored_scene_path
			]
		)

		if typeof(
			stored_profile
		) != TYPE_DICTIONARY:
			continue

		var profile_dictionary: Dictionary = (
			stored_profile
		)

		scene_brush_settings[
			scene_path
		] = profile_dictionary.duplicate(
			true
		)


func _get_active_scene_settings_key() -> String:
	if selected_scene == null:
		return ""

	return selected_scene.resource_path


func _capture_current_brush_settings() -> Dictionary:
	return {
		CONFIG_BRUSH_RADIUS:
			brush_radius,

		CONFIG_INSTANCES_PER_STAMP:
			instances_per_click,

		CONFIG_MINIMUM_SPACING:
			minimum_spacing,

		CONFIG_RANDOM_Y_ROTATION:
			random_y_rotation,

		CONFIG_ALIGN_TO_SURFACE:
			align_to_surface,

		CONFIG_MAXIMUM_SLOPE:
			maximum_slope_degrees,

		CONFIG_HEIGHT_OFFSET:
			height_offset,

		CONFIG_HEIGHT_OFFSET_MODE:
			height_offset_mode,

		CONFIG_RANDOM_SCALE_ENABLED:
			random_scale_enabled,

		CONFIG_MINIMUM_SCALE:
			minimum_scale,

		CONFIG_MAXIMUM_SCALE:
			maximum_scale,

		CONFIG_LOD_ENABLED:
			lod_enabled,

		CONFIG_LOD1_SCENE_PATH:
			_get_packed_scene_path(lod1_scene),

		CONFIG_LOD2_SCENE_PATH:
			_get_packed_scene_path(lod2_scene),

		CONFIG_LOD1_DISTANCE:
			lod1_distance,

		CONFIG_LOD2_DISTANCE:
			lod2_distance,

		CONFIG_LOD_CULL_DISTANCE:
			lod_cull_distance,

		CONFIG_AUTO_LOD_ENABLED:
			auto_lod_enabled,

		CONFIG_AUTO_LOD_BIAS:
			auto_lod_bias,

		CONFIG_AUTO_LOD_CULL_DISTANCE:
			auto_lod_cull_distance,
	}


func _create_default_scene_settings() -> Dictionary:
	return {
		CONFIG_BRUSH_RADIUS: 5.0,
		CONFIG_INSTANCES_PER_STAMP: 5,
		CONFIG_MINIMUM_SPACING: 1.0,
		CONFIG_RANDOM_Y_ROTATION: true,
		CONFIG_ALIGN_TO_SURFACE: false,
		CONFIG_MAXIMUM_SLOPE: 85.0,
		CONFIG_HEIGHT_OFFSET: 0.0,
		CONFIG_HEIGHT_OFFSET_MODE:
			HeightOffsetMode.SURFACE_NORMAL,
		CONFIG_RANDOM_SCALE_ENABLED: true,
		CONFIG_MINIMUM_SCALE: 0.8,
		CONFIG_MAXIMUM_SCALE: 1.3,
		CONFIG_LOD_ENABLED: false,
		CONFIG_LOD1_SCENE_PATH: "",
		CONFIG_LOD2_SCENE_PATH: "",
		CONFIG_LOD1_DISTANCE: 25.0,
		CONFIG_LOD2_DISTANCE: 60.0,
		CONFIG_LOD_CULL_DISTANCE: 0.0,
		CONFIG_AUTO_LOD_ENABLED: false,
		CONFIG_AUTO_LOD_BIAS: 1.0,
		CONFIG_AUTO_LOD_CULL_DISTANCE: 0.0,
	}


func _store_current_scene_settings() -> void:
	if (
		is_loading_configuration
		or is_applying_scene_settings
	):
		return

	var scene_key := (
		_get_active_scene_settings_key()
	)

	if scene_key.is_empty():
		return

	scene_brush_settings[
		scene_key
	] = _capture_current_brush_settings()


func _load_active_scene_settings(
	emit_changes: bool = true
) -> void:
	var scene_key := (
		_get_active_scene_settings_key()
	)

	if scene_key.is_empty():
		return

	if not scene_brush_settings.has(
		scene_key
	):
		scene_brush_settings[
			scene_key
		] = _create_default_scene_settings()
		_apply_brush_settings_profile(
			scene_brush_settings[scene_key]
		)

		if emit_changes:
			_emit_all_brush_settings_changed()

		return

	var stored_profile: Variant = (
		scene_brush_settings[
			scene_key
		]
	)

	if typeof(
		stored_profile
	) != TYPE_DICTIONARY:
		scene_brush_settings[
			scene_key
		] = _create_default_scene_settings()
		_apply_brush_settings_profile(
			scene_brush_settings[scene_key]
		)

		if emit_changes:
			_emit_all_brush_settings_changed()

		return

	var profile: Dictionary = stored_profile

	_apply_brush_settings_profile(
		profile
	)

	if emit_changes:
		_emit_all_brush_settings_changed()


func _apply_brush_settings_profile(
	profile: Dictionary
) -> void:
	is_applying_scene_settings = true

	brush_radius = maxf(
		float(
			profile.get(
				CONFIG_BRUSH_RADIUS,
				brush_radius
			)
		),
		0.5
	)

	instances_per_click = maxi(
		int(
			profile.get(
				CONFIG_INSTANCES_PER_STAMP,
				instances_per_click
			)
		),
		1
	)

	minimum_spacing = maxf(
		float(
			profile.get(
				CONFIG_MINIMUM_SPACING,
				minimum_spacing
			)
		),
		0.0
	)

	random_y_rotation = bool(
		profile.get(
			CONFIG_RANDOM_Y_ROTATION,
			random_y_rotation
		)
	)

	align_to_surface = bool(
		profile.get(
			CONFIG_ALIGN_TO_SURFACE,
			align_to_surface
		)
	)

	maximum_slope_degrees = clampf(
		float(
			profile.get(
				CONFIG_MAXIMUM_SLOPE,
				maximum_slope_degrees
			)
		),
		0.0,
		90.0
	)

	height_offset = float(
		profile.get(
			CONFIG_HEIGHT_OFFSET,
			height_offset
		)
	)

	height_offset_mode = clampi(
		int(
			profile.get(
				CONFIG_HEIGHT_OFFSET_MODE,
				height_offset_mode
			)
		),
		HeightOffsetMode.WORLD_Y,
		HeightOffsetMode.SURFACE_NORMAL
	)

	random_scale_enabled = bool(
		profile.get(
			CONFIG_RANDOM_SCALE_ENABLED,
			random_scale_enabled
		)
	)

	minimum_scale = maxf(
		float(
			profile.get(
				CONFIG_MINIMUM_SCALE,
				minimum_scale
			)
		),
		0.01
	)

	maximum_scale = maxf(
		float(
			profile.get(
				CONFIG_MAXIMUM_SCALE,
				maximum_scale
			)
		),
		0.01
	)

	lod_enabled = bool(
		profile.get(
			CONFIG_LOD_ENABLED,
			lod_enabled
		)
	)

	lod1_scene = _load_packed_scene(
		str(profile.get(
			CONFIG_LOD1_SCENE_PATH,
			_get_packed_scene_path(lod1_scene)
		))
	)

	lod2_scene = _load_packed_scene(
		str(profile.get(
			CONFIG_LOD2_SCENE_PATH,
			_get_packed_scene_path(lod2_scene)
		))
	)

	lod1_distance = maxf(
		float(profile.get(
			CONFIG_LOD1_DISTANCE,
			lod1_distance
		)),
		1.0
	)

	lod2_distance = maxf(
		float(profile.get(
			CONFIG_LOD2_DISTANCE,
			lod2_distance
		)),
		lod1_distance + 1.0
	)

	lod_cull_distance = maxf(
		float(profile.get(
			CONFIG_LOD_CULL_DISTANCE,
			lod_cull_distance
		)),
		0.0
	)
	_validate_lod_cull_distance()

	auto_lod_enabled = bool(
		profile.get(
			CONFIG_AUTO_LOD_ENABLED,
			false
		)
	)
	auto_lod_bias = clampf(
		float(profile.get(
			CONFIG_AUTO_LOD_BIAS,
			1.0
		)),
		0.0,
		4.0
	)
	auto_lod_cull_distance = maxf(
		float(profile.get(
			CONFIG_AUTO_LOD_CULL_DISTANCE,
			0.0
		)),
		0.0
	)

	if minimum_scale > maximum_scale:
		maximum_scale = minimum_scale

	_apply_settings_to_controls()
	_update_controls()

	is_applying_scene_settings = false


func _emit_all_brush_settings_changed() -> void:
	brush_radius_changed.emit(
		brush_radius
	)

	instances_per_click_changed.emit(
		instances_per_click
	)

	minimum_spacing_changed.emit(
		minimum_spacing
	)

	random_y_rotation_changed.emit(
		random_y_rotation
	)

	align_to_surface_changed.emit(
		align_to_surface
	)

	maximum_slope_changed.emit(
		maximum_slope_degrees
	)

	height_offset_changed.emit(
		height_offset
	)

	height_offset_mode_changed.emit(
		height_offset_mode
	)

	random_scale_enabled_changed.emit(
		random_scale_enabled
	)

	minimum_scale_changed.emit(
		minimum_scale
	)

	maximum_scale_changed.emit(
		maximum_scale
	)

	_emit_lod_settings_changed()
	_emit_auto_lod_settings_changed()


func _apply_settings_to_controls() -> void:
	if is_instance_valid(radius_spin_box):
		radius_spin_box.set_value_no_signal(
			brush_radius
		)

	if is_instance_valid(instances_spin_box):
		instances_spin_box.set_value_no_signal(
			float(instances_per_click)
		)

	if is_instance_valid(spacing_spin_box):
		spacing_spin_box.set_value_no_signal(
			minimum_spacing
		)

	if is_instance_valid(random_rotation_toggle):
		random_rotation_toggle.set_pressed_no_signal(
			random_y_rotation
		)

	if is_instance_valid(align_surface_toggle):
		align_surface_toggle.set_pressed_no_signal(
			align_to_surface
		)

	if is_instance_valid(maximum_slope_spin_box):
		maximum_slope_spin_box.set_value_no_signal(
			maximum_slope_degrees
		)

	if is_instance_valid(height_offset_spin_box):
		height_offset_spin_box.set_value_no_signal(
			height_offset
		)

	if is_instance_valid(height_offset_mode_option):
		height_offset_mode_option.select(
			height_offset_mode
		)

	if is_instance_valid(random_scale_toggle):
		random_scale_toggle.set_pressed_no_signal(
			random_scale_enabled
		)

	if is_instance_valid(minimum_scale_spin_box):
		minimum_scale_spin_box.set_value_no_signal(
			minimum_scale
		)

	if is_instance_valid(maximum_scale_spin_box):
		maximum_scale_spin_box.set_value_no_signal(
			maximum_scale
		)

	if is_instance_valid(lod_toggle):
		lod_toggle.set_pressed_no_signal(lod_enabled)

	if is_instance_valid(lod1_picker):
		lod1_picker.edited_resource = lod1_scene

	if is_instance_valid(lod2_picker):
		lod2_picker.edited_resource = lod2_scene

	if is_instance_valid(lod1_distance_spin_box):
		lod1_distance_spin_box.set_value_no_signal(lod1_distance)

	if is_instance_valid(lod2_distance_spin_box):
		lod2_distance_spin_box.set_value_no_signal(lod2_distance)

	if is_instance_valid(lod_cull_distance_spin_box):
		lod_cull_distance_spin_box.set_value_no_signal(lod_cull_distance)

	if is_instance_valid(auto_lod_toggle):
		auto_lod_toggle.set_pressed_no_signal(auto_lod_enabled)

	if is_instance_valid(auto_lod_bias_spin_box):
		auto_lod_bias_spin_box.set_value_no_signal(auto_lod_bias)

	if is_instance_valid(auto_lod_cull_spin_box):
		auto_lod_cull_spin_box.set_value_no_signal(auto_lod_cull_distance)

	_update_lod_controls()
	_update_auto_lod_controls()


func _emit_loaded_state() -> void:
	_apply_language()
	_update_scene_interface()

	_emit_palette_changed()
	_emit_active_scene_changed()

	_emit_all_brush_settings_changed()

	var valid_scene_count := (
		_get_valid_scene_pickers().size()
	)

	if valid_scene_count <= 0:
		_set_status(
			"No Scenes Selected"
		)

		return

	_set_status(
		"Palette Restored: %d Scene(s)"
		% valid_scene_count
	)


# =========================================================
# تحديث قائمة المشاهد
# =========================================================

func _update_scene_interface() -> void:
	_validate_active_picker()

	var valid_pickers := (
		_get_valid_scene_pickers()
	)

	var valid_scene_count := (
		valid_pickers.size()
	)

	var active_valid_index := valid_pickers.find(
		active_picker
	)

	for entry in scene_rows:
		var picker := _get_picker_from_row(
			entry
		)

		var select_button := (
			entry.get(
				"select_button"
			)
			as Button
		)

		var remove_button := (
			entry.get(
				"remove_button"
			)
			as Button
		)

		var has_scene := _picker_has_scene(
			picker
		)

		var is_active := (
			has_scene
			and picker == active_picker
		)

		if is_instance_valid(
			select_button
		):
			select_button.disabled = (
				not has_scene
				or is_active
			)

			select_button.tooltip_text = _tr(
				"select_scene_tooltip"
			)

			if is_active:
				select_button.text = _tr(
					"active"
				)
			else:
				select_button.text = _tr(
					"use"
				)

		if is_instance_valid(
			remove_button
		):
			remove_button.disabled = (
				scene_rows.size() <= 1
			)

			remove_button.tooltip_text = _tr(
				"remove_scene_tooltip"
			)

	if is_instance_valid(
		previous_scene_button
	):
		previous_scene_button.disabled = (
			valid_scene_count <= 1
		)

	if is_instance_valid(
		next_scene_button
	):
		next_scene_button.disabled = (
			valid_scene_count <= 1
		)

	if (
		is_instance_valid(active_picker)
		and active_valid_index >= 0
	):
		selected_scene = (
			active_picker.edited_resource
			as PackedScene
		)

		if current_language == LANGUAGE_ARABIC:
			active_scene_label.text = (
				"المشهد النشط: %d/%d — %s"
				% [
					active_valid_index + 1,
					valid_scene_count,
					_get_scene_display_name(
						selected_scene
					),
				]
			)
		else:
			active_scene_label.text = (
				"Active Scene: %d/%d — %s"
				% [
					active_valid_index + 1,
					valid_scene_count,
					_get_scene_display_name(
						selected_scene
					),
				]
			)

		active_scene_label.tooltip_text = (
			selected_scene.resource_path
		)

	else:
		selected_scene = null

		active_scene_label.text = _tr(
			"active_scene_none"
		)

		active_scene_label.tooltip_text = ""

	_update_controls()


func _validate_active_picker() -> void:
	if (
		is_instance_valid(active_picker)
		and _picker_belongs_to_palette(
			active_picker
		)
		and _picker_has_scene(
			active_picker
		)
	):
		return

	active_picker = null
	selected_scene = null

	_select_first_available_scene()


func _picker_belongs_to_palette(
	picker: EditorResourcePicker
) -> bool:
	for entry in scene_rows:
		if _get_picker_from_row(
			entry
		) == picker:
			return true

	return false


func _get_valid_scene_pickers() -> Array[EditorResourcePicker]:
	var result: Array[EditorResourcePicker] = []

	for entry in scene_rows:
		var picker := _get_picker_from_row(
			entry
		)

		if _picker_has_scene(
			picker
		):
			result.append(
				picker
			)

	return result


func _get_picker_from_row(
	entry: Dictionary
) -> EditorResourcePicker:
	return (
		entry.get("picker")
		as EditorResourcePicker
	)


func _picker_has_scene(
	picker: EditorResourcePicker
) -> bool:
	return (
		is_instance_valid(picker)
		and picker.edited_resource is PackedScene
	)


func _get_scene_display_name(
	scene: PackedScene
) -> String:
	if scene == null:
		return "None"

	if scene.resource_path.is_empty():
		return _tr(
			"unsaved_scene"
		)

	return scene.resource_path.get_file()


func _emit_active_scene_changed() -> void:
	_validate_active_picker()

	if not is_instance_valid(
		active_picker
	):
		selected_scene = null

		selected_scene_changed.emit(
			null
		)

		_disable_brush_if_no_scene()
		return

	selected_scene = (
		active_picker.edited_resource
		as PackedScene
	)

	selected_scene_changed.emit(
		selected_scene
	)

	_disable_brush_if_no_scene()


func _emit_palette_changed() -> void:
	scene_palette_changed.emit(
		get_scene_palette()
	)


func get_scene_palette() -> Array:
	var scenes: Array = []

	for picker in _get_valid_scene_pickers():
		var packed_scene := (
			picker.edited_resource
			as PackedScene
		)

		if packed_scene != null:
			scenes.append(
				packed_scene
			)

	return scenes


# =========================================================
# إعدادات الفرشاة
# =========================================================

func _create_brush_toggle() -> void:
	var separator := HSeparator.new()
	separator.name = "BrushSeparator"

	controls_container.add_child(
		separator
	)

	brush_toggle = CheckButton.new()
	brush_toggle.name = "BrushToggle"
	brush_toggle.text = "Enable Brush"
	brush_toggle.button_pressed = false

	brush_toggle.toggled.connect(
		_on_brush_toggled
	)

	controls_container.add_child(
		brush_toggle
	)


func _on_brush_toggled(
	enabled: bool
) -> void:
	if enabled and selected_scene == null:
		_disable_brush()

		_set_status(
			"Select An Active Scene First"
		)

		return

	brush_enabled = enabled

	if brush_enabled:
		_set_status(
			"Brush Enabled — %s"
			% _get_scene_display_name(
				selected_scene
			)
		)
	else:
		_set_status(
			"Brush Disabled"
		)

	brush_enabled_changed.emit(
		brush_enabled
	)


func _disable_brush_if_no_scene() -> void:
	if selected_scene == null:
		_disable_brush()


func _disable_brush() -> void:
	brush_enabled = false

	if is_instance_valid(
		brush_toggle
	):
		brush_toggle.set_pressed_no_signal(
			false
		)

	brush_enabled_changed.emit(
		false
	)


func _create_radius_control() -> void:
	var row := _create_setting_row(
		"RadiusContainer",
		"Brush Radius"
	)

	brush_radius_label = (
		row.get_child(0)
		as Label
	)

	radius_spin_box = SpinBox.new()
	radius_spin_box.name = "RadiusSpinBox"
	radius_spin_box.min_value = 0.5
	radius_spin_box.max_value = 100.0
	radius_spin_box.step = 0.5
	radius_spin_box.value = brush_radius
	radius_spin_box.allow_greater = true
	radius_spin_box.suffix = " m"

	radius_spin_box.custom_minimum_size.x = (
		105.0
	)

	radius_spin_box.value_changed.connect(
		_on_radius_changed
	)

	row.add_child(
		radius_spin_box
	)


func _on_radius_changed(
	value: float
) -> void:
	brush_radius = maxf(
		value,
		0.5
	)

	brush_radius_changed.emit(
		brush_radius
	)

	_save_configuration()


func _create_instances_control() -> void:
	var row := _create_setting_row(
		"InstancesContainer",
		"Instances Per Stamp"
	)

	instances_label = (
		row.get_child(0)
		as Label
	)

	instances_spin_box = SpinBox.new()
	instances_spin_box.name = "InstancesSpinBox"
	instances_spin_box.min_value = 1.0
	instances_spin_box.max_value = 100.0
	instances_spin_box.step = 1.0
	instances_spin_box.value = instances_per_click
	instances_spin_box.rounded = true
	instances_spin_box.allow_greater = true

	instances_spin_box.custom_minimum_size.x = (
		105.0
	)

	instances_spin_box.value_changed.connect(
		_on_instances_changed
	)

	row.add_child(
		instances_spin_box
	)


func _on_instances_changed(
	value: float
) -> void:
	instances_per_click = maxi(
		roundi(value),
		1
	)

	instances_per_click_changed.emit(
		instances_per_click
	)

	_save_configuration()


func _create_spacing_control() -> void:
	var row := _create_setting_row(
		"SpacingContainer",
		"Minimum Spacing"
	)

	spacing_label = (
		row.get_child(0)
		as Label
	)

	spacing_spin_box = SpinBox.new()
	spacing_spin_box.name = "SpacingSpinBox"
	spacing_spin_box.min_value = 0.0
	spacing_spin_box.max_value = 100.0
	spacing_spin_box.step = 0.25
	spacing_spin_box.value = minimum_spacing
	spacing_spin_box.allow_greater = true
	spacing_spin_box.suffix = " m"

	spacing_spin_box.custom_minimum_size.x = (
		105.0
	)

	spacing_spin_box.value_changed.connect(
		_on_spacing_changed
	)

	row.add_child(
		spacing_spin_box
	)


func _on_spacing_changed(
	value: float
) -> void:
	minimum_spacing = maxf(
		value,
		0.0
	)

	minimum_spacing_changed.emit(
		minimum_spacing
	)

	_save_configuration()


func _create_random_rotation_control() -> void:
	random_rotation_toggle = CheckButton.new()
	random_rotation_toggle.name = "RandomRotationToggle"
	random_rotation_toggle.text = "Random Y Rotation"

	random_rotation_toggle.button_pressed = (
		random_y_rotation
	)

	random_rotation_toggle.toggled.connect(
		_on_random_rotation_toggled
	)

	controls_container.add_child(
		random_rotation_toggle
	)


func _on_random_rotation_toggled(
	enabled: bool
) -> void:
	random_y_rotation = enabled

	random_y_rotation_changed.emit(
		random_y_rotation
	)

	_save_configuration()


func _create_align_surface_control() -> void:
	align_surface_toggle = CheckButton.new()
	align_surface_toggle.name = "AlignSurfaceToggle"
	align_surface_toggle.text = "Rotate With Surface"
	align_surface_toggle.tooltip_text = (
		"Rotates the instance to follow the surface slope."
	)

	align_surface_toggle.button_pressed = (
		align_to_surface
	)

	align_surface_toggle.toggled.connect(
		_on_align_surface_toggled
	)

	controls_container.add_child(
		align_surface_toggle
	)


func _on_align_surface_toggled(
	enabled: bool
) -> void:
	align_to_surface = enabled

	align_to_surface_changed.emit(
		align_to_surface
	)

	_save_configuration()


# =========================================================
# أقصى ميل مسموح
# =========================================================

func _create_maximum_slope_control() -> void:
	var separator := HSeparator.new()
	separator.name = "MaximumSlopeSeparator"

	controls_container.add_child(
		separator
	)

	var row := _create_setting_row(
		"MaximumSlopeContainer",
		"Maximum Slope"
	)

	maximum_slope_label = (
		row.get_child(0)
		as Label
	)

	maximum_slope_spin_box = SpinBox.new()
	maximum_slope_spin_box.name = "MaximumSlopeSpinBox"

	maximum_slope_spin_box.min_value = 0.0
	maximum_slope_spin_box.max_value = 90.0
	maximum_slope_spin_box.step = 1.0

	maximum_slope_spin_box.value = (
		maximum_slope_degrees
	)

	maximum_slope_spin_box.suffix = "°"

	maximum_slope_spin_box.custom_minimum_size.x = (
		105.0
	)

	maximum_slope_spin_box.tooltip_text = (
		"0° allows flat surfaces only. "
		+ "90° allows nearly all surface slopes."
	)

	maximum_slope_spin_box.value_changed.connect(
		_on_maximum_slope_changed
	)

	row.add_child(
		maximum_slope_spin_box
	)


func _on_maximum_slope_changed(
	value: float
) -> void:
	maximum_slope_degrees = clampf(
		value,
		0.0,
		90.0
	)

	maximum_slope_changed.emit(
		maximum_slope_degrees
	)

	_save_configuration()


# =========================================================
# إزاحة الارتفاع
# =========================================================

func _create_height_offset_controls() -> void:
	var separator := HSeparator.new()
	separator.name = "HeightOffsetSeparator"

	controls_container.add_child(
		separator
	)

	var offset_row := _create_setting_row(
		"HeightOffsetContainer",
		"Height Offset"
	)

	height_offset_label = (
		offset_row.get_child(0)
		as Label
	)

	height_offset_spin_box = SpinBox.new()
	height_offset_spin_box.name = "HeightOffsetSpinBox"

	height_offset_spin_box.min_value = -100.0
	height_offset_spin_box.max_value = 100.0
	height_offset_spin_box.step = 0.05
	height_offset_spin_box.value = height_offset

	height_offset_spin_box.allow_lesser = true
	height_offset_spin_box.allow_greater = true
	height_offset_spin_box.suffix = " m"

	height_offset_spin_box.custom_minimum_size.x = (
		105.0
	)

	height_offset_spin_box.value_changed.connect(
		_on_height_offset_changed
	)

	offset_row.add_child(
		height_offset_spin_box
	)

	var direction_row := _create_setting_row(
		"HeightOffsetModeContainer",
		"Offset Direction"
	)

	height_offset_mode_label = (
		direction_row.get_child(0)
		as Label
	)

	height_offset_mode_option = OptionButton.new()

	height_offset_mode_option.name = (
		"HeightOffsetModeOption"
	)

	height_offset_mode_option.custom_minimum_size.x = (
		150.0
	)

	height_offset_mode_option.add_item(
		"World Y",
		HeightOffsetMode.WORLD_Y
	)

	height_offset_mode_option.add_item(
		"Surface Normal",
		HeightOffsetMode.SURFACE_NORMAL
	)

	height_offset_mode_option.select(
		height_offset_mode
	)

	height_offset_mode_option.item_selected.connect(
		_on_height_offset_mode_selected
	)

	direction_row.add_child(
		height_offset_mode_option
	)

	height_offset_help_label = Label.new()
	height_offset_help_label.name = "HeightOffsetHelpLabel"
	height_offset_help_label.text = (
		"The offset direction moves the instance position only. "
		+ "Enable Rotate With Surface to change its tilt."
	)

	height_offset_help_label.autowrap_mode = (
		TextServer.AUTOWRAP_WORD_SMART
	)

	height_offset_help_label.size_flags_horizontal = (
		Control.SIZE_EXPAND_FILL
	)

	height_offset_help_label.modulate = Color(
		1.0,
		1.0,
		1.0,
		0.72
	)

	controls_container.add_child(
		height_offset_help_label
	)


func _on_height_offset_changed(
	value: float
) -> void:
	height_offset = value

	height_offset_changed.emit(
		height_offset
	)

	_save_configuration()


func _on_height_offset_mode_selected(
	index: int
) -> void:
	height_offset_mode = clampi(
		index,
		HeightOffsetMode.WORLD_Y,
		HeightOffsetMode.SURFACE_NORMAL
	)

	height_offset_mode_changed.emit(
		height_offset_mode
	)

	_save_configuration()


# =========================================================
# الحجم العشوائي
# =========================================================

func _create_random_scale_controls() -> void:
	var separator := HSeparator.new()
	separator.name = "RandomScaleSeparator"

	controls_container.add_child(
		separator
	)

	random_scale_toggle = CheckButton.new()
	random_scale_toggle.name = "RandomScaleToggle"
	random_scale_toggle.text = "Random Scale"

	random_scale_toggle.button_pressed = (
		random_scale_enabled
	)

	random_scale_toggle.toggled.connect(
		_on_random_scale_toggled
	)

	controls_container.add_child(
		random_scale_toggle
	)

	var minimum_row := _create_setting_row(
		"MinimumScaleContainer",
		"Minimum Scale"
	)

	minimum_scale_label = (
		minimum_row.get_child(0)
		as Label
	)

	minimum_scale_spin_box = SpinBox.new()

	minimum_scale_spin_box.name = (
		"MinimumScaleSpinBox"
	)

	minimum_scale_spin_box.min_value = 0.01
	minimum_scale_spin_box.max_value = 100.0
	minimum_scale_spin_box.step = 0.05
	minimum_scale_spin_box.value = minimum_scale
	minimum_scale_spin_box.allow_greater = true

	minimum_scale_spin_box.custom_minimum_size.x = (
		105.0
	)

	minimum_scale_spin_box.value_changed.connect(
		_on_minimum_scale_changed
	)

	minimum_row.add_child(
		minimum_scale_spin_box
	)

	var maximum_row := _create_setting_row(
		"MaximumScaleContainer",
		"Maximum Scale"
	)

	maximum_scale_label = (
		maximum_row.get_child(0)
		as Label
	)

	maximum_scale_spin_box = SpinBox.new()

	maximum_scale_spin_box.name = (
		"MaximumScaleSpinBox"
	)

	maximum_scale_spin_box.min_value = 0.01
	maximum_scale_spin_box.max_value = 100.0
	maximum_scale_spin_box.step = 0.05
	maximum_scale_spin_box.value = maximum_scale
	maximum_scale_spin_box.allow_greater = true

	maximum_scale_spin_box.custom_minimum_size.x = (
		105.0
	)

	maximum_scale_spin_box.value_changed.connect(
		_on_maximum_scale_changed
	)

	maximum_row.add_child(
		maximum_scale_spin_box
	)


func _on_random_scale_toggled(
	enabled: bool
) -> void:
	random_scale_enabled = enabled

	random_scale_enabled_changed.emit(
		random_scale_enabled
	)

	_update_controls()
	_save_configuration()


func _on_minimum_scale_changed(
	value: float
) -> void:
	minimum_scale = maxf(
		value,
		0.01
	)

	if minimum_scale > maximum_scale:
		maximum_scale = minimum_scale

		if is_instance_valid(
			maximum_scale_spin_box
		):
			maximum_scale_spin_box.set_value_no_signal(
				maximum_scale
			)

		maximum_scale_changed.emit(
			maximum_scale
		)

	minimum_scale_changed.emit(
		minimum_scale
	)

	_save_configuration()


func _on_maximum_scale_changed(
	value: float
) -> void:
	maximum_scale = maxf(
		value,
		0.01
	)

	if maximum_scale < minimum_scale:
		minimum_scale = maximum_scale

		if is_instance_valid(
			minimum_scale_spin_box
		):
			minimum_scale_spin_box.set_value_no_signal(
				minimum_scale
			)

		minimum_scale_changed.emit(
			minimum_scale
		)

	maximum_scale_changed.emit(
		maximum_scale
	)

	_save_configuration()


func _create_setting_row(
	row_name: String,
	label_text: String
) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = row_name

	row.size_flags_horizontal = (
		Control.SIZE_EXPAND_FILL
	)

	var label := Label.new()
	label.name = "%sLabel" % row_name
	label.text = label_text

	label.size_flags_horizontal = (
		Control.SIZE_EXPAND_FILL
	)

	row.add_child(
		label
	)

	controls_container.add_child(
		row
	)

	return row


func _update_controls() -> void:
	var has_active_scene := (
		selected_scene != null
	)

	_update_lod_controls()
	_update_auto_lod_controls()

	if is_instance_valid(
		brush_toggle
	):
		brush_toggle.disabled = (
			not has_active_scene
		)

	if is_instance_valid(
		radius_spin_box
	):
		radius_spin_box.editable = (
			has_active_scene
		)

	if is_instance_valid(
		instances_spin_box
	):
		instances_spin_box.editable = (
			has_active_scene
		)

	if is_instance_valid(
		spacing_spin_box
	):
		spacing_spin_box.editable = (
			has_active_scene
		)

	if is_instance_valid(
		random_rotation_toggle
	):
		random_rotation_toggle.disabled = (
			not has_active_scene
		)

	if is_instance_valid(
		align_surface_toggle
	):
		align_surface_toggle.disabled = (
			not has_active_scene
		)

	if is_instance_valid(
		maximum_slope_spin_box
	):
		maximum_slope_spin_box.editable = (
			has_active_scene
		)

	if is_instance_valid(
		height_offset_spin_box
	):
		height_offset_spin_box.editable = (
			has_active_scene
		)

	if is_instance_valid(
		height_offset_mode_option
	):
		height_offset_mode_option.disabled = (
			not has_active_scene
		)

	if is_instance_valid(
		random_scale_toggle
	):
		random_scale_toggle.disabled = (
			not has_active_scene
		)

	var scale_controls_enabled := (
		has_active_scene
		and random_scale_enabled
	)

	if is_instance_valid(
		minimum_scale_spin_box
	):
		minimum_scale_spin_box.editable = (
			scale_controls_enabled
		)

	if is_instance_valid(
		maximum_scale_spin_box
	):
		maximum_scale_spin_box.editable = (
			scale_controls_enabled
		)


# =========================================================
# دوال القراءة
# =========================================================

func get_selected_scene() -> PackedScene:
	return selected_scene


func get_active_scene_index() -> int:
	return (
		_get_valid_scene_pickers().find(
			active_picker
		)
	)


func is_brush_enabled() -> bool:
	return brush_enabled


func get_brush_radius() -> float:
	return brush_radius


func get_instances_per_click() -> int:
	return instances_per_click


func get_minimum_spacing() -> float:
	return minimum_spacing


func is_random_y_rotation_enabled() -> bool:
	return random_y_rotation


func is_align_to_surface_enabled() -> bool:
	return align_to_surface


func get_maximum_slope() -> float:
	return maximum_slope_degrees


func get_height_offset() -> float:
	return height_offset


func get_height_offset_mode() -> int:
	return height_offset_mode


func is_random_scale_enabled() -> bool:
	return random_scale_enabled


func get_minimum_scale() -> float:
	return minimum_scale


func get_maximum_scale() -> float:
	return maximum_scale


func get_interface_language() -> String:
	return current_language
