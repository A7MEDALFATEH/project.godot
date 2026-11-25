extends Control
## Exhibition HUD. The simulation remains the source of truth for live readings.

signal race_requested(automatic: bool)
signal pressure_requested
signal reset_pressure_requested
signal choke_changed(value: float)
signal camera_reset_requested
signal language_changed(language: String)
signal voice_volume_changed(volume: float)
signal restart_requested
signal pause_requested
signal fullscreen_requested
signal mute_requested

const LATIN := preload("res://assets/fonts/NotoSans-Regular.ttf")
const LATIN_BOLD := preload("res://assets/fonts/NotoSans-Bold.ttf")
const ARABIC := preload("res://assets/fonts/NotoSansArabic-Regular.ttf")
const ARABIC_BOLD := preload("res://assets/fonts/NotoSansArabic-Bold.ttf")

const PANEL := Color("#101c2c")
const DEEP := Color("#0a1422")
const LINE := Color("#2b435b")
const TEXT := Color("#edf7ff")
const MUTED := Color("#adbed1")
const CYAN := Color("#83eafa")
const AMBER := Color("#ffc474")
const WARNING := Color("#ffa280")

const REGIME_LABELS := {
	"single_phase": ["Single-phase liquid", "سائل أحادي الطور"],
	"bubble_flow": ["Bubble flow", "جريان فقاعي"],
	"slug_flow": ["Slug flow", "جريان سدادي"],
}
const REGIME_COLORS := {
	"single_phase": AMBER,
	"bubble_flow": CYAN,
	"slug_flow": Color("#c4adff"),
}
const LESSONS := {
	"idle": ["Start a race to see how pressure changes the way oil and gas move.",
		"ابدأ السباق لتشاهد كيف يؤثر الضغط على حركة النفط والغاز."],
	"race_start": ["At high pressure, gas stays dissolved in the oil while Olly rises.",
		"عند الضغط العالي يبقى الغاز مذاباً في النفط بينما يصعد أولي."],
	"pressure_drop": ["Watch the pressure fall toward the bubble point.",
		"راقب انخفاض الضغط نحو نقطة الفقاعات."],
	"bubble_point_crossed": ["Below the bubble point, dissolved gas comes out of the oil.",
		"تحت ضغط نقطة الفقاعات يتحرر الغاز المذاب من النفط."],
	"gas_appeared": ["Gizmo is free gas. Bubbles can move upward faster than the oil.",
		"غيزمو يمثل الغاز الحر. يمكن للفقاعات الصعود أسرع من النفط."],
	"bubble_flow": ["Small gas bubbles travel through a continuous liquid phase.",
		"تتحرك فقاعات الغاز الصغيرة عبر طور سائل متصل."],
	"gas_accelerated": ["Gas slips upward through the liquid and gains ground on Olly.",
		"ينزلق الغاز صعوداً خلال السائل ويقترب من أولي."],
	"slug_flow": ["Large gas pockets alternate with liquid slugs, making the flow pulse.",
		"تتناوب جيوب الغاز الكبيرة مع سدادات سائلة، فيصبح الجريان نابضاً."],
	"choke_changed": ["Changing the choke opening changes resistance and flow.",
		"تغيير فتحة صمام الخنق يغيّر مقاومة الجريان ومعدله."],
	"flow_accelerated": ["A wider choke opening can lower upstream pressure in this model.",
		"قد تؤدي زيادة فتحة صمام الخنق إلى خفض ضغط المنبع في هذا النموذج."],
	"flow_decelerated": ["A smaller opening reduces flow in this model.",
		"تؤدي الفتحة الأصغر إلى تقليل الجريان في هذا النموذج."],
	"gas_expansion": ["The freed gas expands as the pressure drops further.",
		"يتمدد الغاز المتحرر مع استمرار هبوط الضغط."],
	"pressure_restored": ["As pressure rises, less gas remains free in this model.",
		"مع ارتفاع الضغط تقل كمية الغاز الحر في هذا النموذج."],
	"single_phase": ["At this pressure the model keeps gas dissolved in liquid oil.",
		"عند هذا الضغط يبقى الغاز مذاباً في النفط السائل في هذا النموذج."],
	"finale": ["Both fluids are approaching the surface outlet.",
		"يقترب المائعان من مخرج الأنبوب عند السطح."],
	"victory": ["Pressure and flow both affect which fluid reaches the surface first.",
		"يؤثر كل من الضغط والجريان على المائع الذي يبلغ السطح أولاً."],
}

var subtitle_label: Label
var _language := "en"
var _arabic_regular: FontVariation
var _arabic_bold: FontVariation
var _local_strings: Array[Dictionary] = []
var _lesson_id := "idle"
var _lesson: Label
var _race_status: Label
var _regime_label: Label
var _clock: Label
var _timer_caption: Label
var _pressure_value: Label
var _pressure_bar: ProgressBar
var _bubble_tick: ColorRect
var _telemetry: Dictionary = {}
var _olly_value: Label
var _gizmo_value: Label
var _olly_bar: ProgressBar
var _gizmo_bar: ProgressBar
var _choke_slider: HSlider
var _choke_value: Label
var _manual: Button
var _guided: Button
var _drop: Button
var _restore: Button
var _pause: Button
var _locale: Button
var _mute: Button
var _muted := false
var _paused := false
var _last_tick := -100
var _last_simulation: Node


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_arabic_regular = _compact_arabic(ARABIC)
	_arabic_bold = _compact_arabic(ARABIC_BOLD)
	_theme_setup()
	_build_header()
	_build_left()
	_build_telemetry()
	_build_controls()
	_build_subtitles()
	set_paused(false)
	set_muted(false)
	_apply_language()


func sync_state(simulation: Node) -> void:
	_last_simulation = simulation
	var now := Time.get_ticks_msec()
	if now - _last_tick < 65:
		return
	_last_tick = now

	var running: bool = simulation.running
	var automatic: bool = simulation.automatic
	var finished: bool = simulation.finished
	_manual.disabled = running
	_guided.disabled = running
	_drop.disabled = not running or automatic
	_restore.disabled = not running or automatic
	_choke_slider.editable = not automatic and not finished
	_pause.disabled = not running
	_choke_slider.set_value_no_signal(simulation.choke)

	_choke_value.text = _percent(simulation.choke)
	var total_seconds := int(simulation.elapsed)
	_clock.text = "%02d:%02d" % [floori(float(total_seconds) / 60.0), total_seconds % 60]
	_timer_caption.text = _tr("GUIDED RACE", "سباق موجّه") if running and automatic else _tr("RACE TIME", "وقت السباق")

	var regime: String = simulation.regime
	var regime_words: Array = REGIME_LABELS.get(regime, REGIME_LABELS["single_phase"])
	var regime_color: Color = REGIME_COLORS.get(regime, AMBER)
	_regime_label.text = "●  " + _tr(regime_words[0], regime_words[1])
	_regime_label.add_theme_color_override("font_color", regime_color)
	_pressure_value.text = "%d %s" % [roundi(simulation.pressure), _tr("psi", "psi")]
	_pressure_value.add_theme_color_override(
		"font_color", WARNING if simulation.pressure < simulation.bubble_point else TEXT
	)
	_pressure_bar.value = simulation.pressure
	var bubble_ratio := inverse_lerp(_pressure_bar.min_value, _pressure_bar.max_value, simulation.bubble_point)
	_bubble_tick.position.x = clampf(bubble_ratio, 0.0, 1.0) * (_pressure_bar.size.x - _bubble_tick.size.x)
	_telemetry["bubble"].text = "%d psi" % roundi(simulation.bubble_point)
	_telemetry["liquid"].text = "%.2f %s" % [simulation.liquid_rate, _tr("m/s", "م/ث")]
	_telemetry["gas"].text = "%.2f %s" % [simulation.gas_rate, _tr("m/s", "م/ث")]
	_telemetry["fraction"].text = _percent(simulation.gas_fraction)
	_telemetry["choke"].text = _percent(simulation.choke)
	_olly_bar.value = 100.0 * simulation.olly_progress
	_gizmo_bar.value = 100.0 * simulation.gizmo_progress
	_olly_value.text = _percent(simulation.olly_progress)
	_gizmo_value.text = _percent(simulation.gizmo_progress) if simulation.gas_visible or simulation.gizmo_progress > 0.0 else _tr("Dissolved", "مذاب")

	if finished:
		var olly_wins: bool = simulation.winner == "olly"
		_race_status.text = _tr("Olly wins!", "أولي يفوز!") if olly_wins else _tr("Gizmo wins!", "غيزمو يفوز!")
		_race_status.add_theme_color_override("font_color", AMBER if olly_wins else CYAN)
	elif running:
		_race_status.text = _tr("Paused", "متوقف مؤقتاً") if _paused else _tr("Race in progress", "السباق جارٍ")
		_race_status.add_theme_color_override("font_color", TEXT)
	else:
		_race_status.text = _tr("Ready to race", "جاهز للسباق")
		_race_status.add_theme_color_override("font_color", TEXT)


func show_event(event_id: String) -> void:
	if event_id == "reset":
		event_id = "idle"
	if LESSONS.has(event_id):
		_lesson_id = event_id
		_refresh_lesson()
	_last_tick = -100


func set_paused(paused: bool) -> void:
	_paused = paused
	if is_instance_valid(_pause):
		_pause.text = _tr("Resume", "متابعة") if paused else _tr("Pause", "إيقاف مؤقت")


func set_muted(muted: bool) -> void:
	_muted = muted
	if is_instance_valid(_mute):
		_mute.text = _tr("Unmute", "تشغيل الصوت") if muted else _tr("Mute", "كتم الصوت")


func _compact_arabic(base: FontFile) -> FontVariation:
	var font := FontVariation.new()
	font.base_font = base
	font.set_fallbacks([LATIN])
	font.spacing_top = -7
	font.spacing_bottom = -7
	return font


func _theme_setup() -> void:
	var ui_theme := Theme.new()
	ui_theme.default_font = LATIN
	ui_theme.default_font_size = 17
	var tooltip_font := FontVariation.new()
	tooltip_font.base_font = LATIN
	tooltip_font.set_fallbacks([_arabic_regular])
	ui_theme.set_font("font", "TooltipLabel", tooltip_font)
	ui_theme.set_constant("separation", "VBoxContainer", 8)
	ui_theme.set_constant("separation", "HBoxContainer", 8)
	ui_theme.set_stylebox("normal", "Button", _box(DEEP, LINE, 9, 11, 5))
	ui_theme.set_stylebox("hover", "Button", _box(Color("#22394e"), Color("#587889"), 9, 11, 5))
	ui_theme.set_stylebox("pressed", "Button", _box(Color("#254658"), CYAN, 9, 11, 5))
	ui_theme.set_stylebox("disabled", "Button", _box(Color("#112030"), Color("#203247"), 9, 11, 5))
	ui_theme.set_stylebox("focus", "Button", _box(Color.TRANSPARENT, CYAN, 9))
	ui_theme.set_color("font_color", "Button", TEXT)
	ui_theme.set_color("font_disabled_color", "Button", Color("#6c8197"))
	ui_theme.set_stylebox("slider", "HSlider", _box(Color("#20364d"), Color.TRANSPARENT, 4, 0, 4))
	ui_theme.set_stylebox("grabber_area", "HSlider", _box(Color("#4e97ad"), Color.TRANSPARENT, 4, 0, 4))
	ui_theme.set_stylebox("grabber_area_highlight", "HSlider", _box(CYAN, Color.TRANSPARENT, 4, 0, 4))
	theme = ui_theme


func _box(fill: Color, border: Color, radius: int, horizontal: int = 0, vertical: int = 0) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(radius)
	style.content_margin_left = horizontal
	style.content_margin_right = horizontal
	style.content_margin_top = vertical
	style.content_margin_bottom = vertical
	return style


func _panel(anchor: Vector4, offset: Vector4, margin_h: int = 20, margin_v: int = 14) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.add_theme_stylebox_override("panel", _box(Color(PANEL, 0.97), LINE, 16, margin_h, margin_v))
	add_child(panel)
	panel.anchor_left = anchor.x
	panel.anchor_top = anchor.y
	panel.anchor_right = anchor.z
	panel.anchor_bottom = anchor.w
	panel.offset_left = offset.x
	panel.offset_top = offset.y
	panel.offset_right = offset.z
	panel.offset_bottom = offset.w
	return panel


func _vertical(parent: Control, spacing: int = 8) -> VBoxContainer:
	var row := VBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", spacing)
	parent.add_child(row)
	return row


func _horizontal(parent: Control, spacing: int = 8) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", spacing)
	parent.add_child(row)
	return row


func _label(parent: Control, text_value: String, size_px: int, color: Color, bold := false, wrap := false) -> Label:
	var label := Label.new()
	label.text = text_value
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_color_override("font_color", color)
	label.add_theme_font_size_override("font_size", size_px)
	label.add_theme_font_override("font", LATIN_BOLD if bold else LATIN)
	if wrap:
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(label)
	return label


func _caption(parent: Control, english: String, arabic: String, size_px: int, color: Color, bold := false, wrap := false) -> Label:
	var label := _label(parent, english, size_px, color, bold, wrap)
	_local_strings.append({"node": label, "en": english, "ar": arabic, "bold": bold})
	return label


func _button(parent: Control, english: String, arabic: String, action: Callable, tooltip_english := "", tooltip_arabic := "") -> Button:
	var button := Button.new()
	button.text = english
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.focus_mode = Control.FOCUS_NONE
	button.custom_minimum_size.y = 35.0
	button.add_theme_font_size_override("font_size", 16)
	button.pressed.connect(action)
	parent.add_child(button)
	_local_strings.append({
		"node": button, "en": english, "ar": arabic, "bold": true,
		"tip_en": tooltip_english, "tip_ar": tooltip_arabic,
	})
	return button


func _spacer(parent: Control) -> void:
	var gap := Control.new()
	gap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gap.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(gap)


func _line(parent: Control) -> void:
	var divider := ColorRect.new()
	divider.color = LINE
	divider.custom_minimum_size.y = 1
	divider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(divider)


func _progress(parent: Control, fill: Color, thickness: int = 7) -> ProgressBar:
	var meter := ProgressBar.new()
	meter.show_percentage = false
	meter.mouse_filter = Control.MOUSE_FILTER_IGNORE
	meter.custom_minimum_size.y = thickness
	meter.add_theme_stylebox_override("background", _box(Color("#1c3045"), Color.TRANSPARENT, 3))
	meter.add_theme_stylebox_override("fill", _box(fill, Color.TRANSPARENT, 3))
	parent.add_child(meter)
	return meter


func _build_header() -> void:
	var panel := _panel(Vector4(0, 0, 1, 0), Vector4(26, 22, -26, 105), 24, 10)
	var row := _horizontal(panel, 18)
	var identity := _vertical(row, 0)
	_caption(identity, "THE WELLBORE FLUID RACE", "سباق الموائع في البئر", 28, TEXT, true)
	_caption(identity, "Oil and gas in production tubing", "النفط والغاز داخل أنبوب الإنتاج", 15, MUTED)
	_spacer(row)
	var flow := _vertical(row, 0)
	var flow_caption := _caption(flow, "FLOW REGIME", "نمط الجريان", 13, MUTED, true)
	flow_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_regime_label = _label(flow, "●  Single-phase liquid", 19, AMBER, true)
	_regime_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	var time := _vertical(row, 0)
	time.custom_minimum_size.x = 102.0
	_timer_caption = _label(time, "RACE TIME", 13, MUTED, true)
	_timer_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_clock = _label(time, "00:00", 20, TEXT, true)
	_clock.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT


func _build_left() -> void:
	var panel := _panel(Vector4(0, 0, 0, 0), Vector4(26, 119, 305, 508))
	var stack := _vertical(panel, 11)
	_caption(stack, "RACE TO THE SURFACE", "سباق نحو السطح", 14, MUTED, true)
	_race_status = _label(stack, "Ready to race", 24, TEXT, true, true)
	var progress := _add_racer(stack, "Olly · Oil", "أولي · النفط", AMBER)
	_olly_value = progress[0]
	_olly_bar = progress[1]
	progress = _add_racer(stack, "Gizmo · Gas", "غيزمو · الغاز", CYAN)
	_gizmo_value = progress[0]
	_gizmo_bar = progress[1]
	_line(stack)
	_caption(stack, "WHAT'S HAPPENING", "ماذا يحدث؟", 13, CYAN, true)
	_lesson = _label(stack, "", 18, TEXT, false, true)
	_lesson.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_refresh_lesson()


func _add_racer(parent: Control, english: String, arabic: String, color: Color) -> Array:
	var group := _vertical(parent, 5)
	var row := _horizontal(group, 4)
	_caption(row, english, arabic, 16, color, true)
	_spacer(row)
	var value := _label(row, "0%", 15, MUTED, true)
	var progress := _progress(group, color)
	return [value, progress]


func _build_telemetry() -> void:
	var panel := _panel(Vector4(1, 0, 1, 0), Vector4(-305, 119, -26, 523))
	var stack := _vertical(panel, 10)
	_caption(stack, "WELL CONDITIONS", "ظروف البئر", 14, MUTED, true)
	_caption(stack, "Flowing pressure", "ضغط الجريان", 16, TEXT)
	_pressure_value = _label(stack, "2850 psi", 32, TEXT, true)
	_pressure_bar = _progress(stack, Color("#66c2e3"), 10)
	_pressure_bar.min_value = 900
	_pressure_bar.max_value = 3100
	_pressure_bar.value = 2850
	_pressure_bar.tooltip_text = "The thin marker is the bubble point."
	_bubble_tick = ColorRect.new()
	_bubble_tick.color = Color("#fff1c9")
	_bubble_tick.size = Vector2(3, 13)
	_bubble_tick.position.y = -1.5
	_bubble_tick.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pressure_bar.add_child(_bubble_tick)
	_telemetry["bubble"] = _reading(stack, "Bubble point", "نقطة الفقاعات", "2300 psi")
	_line(stack)
	_telemetry["liquid"] = _reading(stack, "Oil velocity", "سرعة النفط", "0.00 m/s", AMBER)
	_telemetry["gas"] = _reading(stack, "Gas velocity", "سرعة الغاز", "0.00 m/s", CYAN)
	_telemetry["fraction"] = _reading(stack, "Free gas fraction", "نسبة الغاز الحر", "0%")
	_telemetry["choke"] = _reading(stack, "Choke opening", "فتحة صمام الخنق", "0%")
	_caption(stack, "Illustrative simulation values", "قيم محاكاة توضيحية", 13, MUTED, false, true)


func _reading(parent: Control, english: String, arabic: String, default_value: String, color := TEXT) -> Label:
	var row := _horizontal(parent, 6)
	_caption(row, english, arabic, 15, MUTED)
	_spacer(row)
	return _label(row, default_value, 16, color, true)


func _build_controls() -> void:
	var panel := _panel(Vector4(0, 1, 1, 1), Vector4(26, -141, -26, -20), 19, 11)
	var controls := _horizontal(panel, 16)
	var session := _vertical(controls, 6)
	_caption(session, "RACE MODE", "نمط السباق", 13, MUTED, true)
	var start_group := _horizontal(session, 6)
	_manual = _button(start_group, "Manual race", "سباق يدوي", func() -> void: race_requested.emit(false), "Start and control the well · Space", "ابدأ وتحكم بالبئر · Space")
	_guided = _button(start_group, "Guided race", "سباق موجّه", func() -> void: race_requested.emit(true), "Watch an automatic starting sequence", "شاهد تسلسل التشغيل التلقائي")
	var race_group := _horizontal(session, 6)
	_button(race_group, "Reset race", "إعادة السباق", func() -> void: restart_requested.emit(), "Reset to the start · R", "العودة إلى البداية · R")
	_pause = _button(race_group, "Pause", "إيقاف مؤقت", func() -> void: pause_requested.emit(), "Pause or resume · P", "إيقاف أو متابعة · P")

	var pressure_controls := _vertical(controls, 6)
	_caption(pressure_controls, "PRESSURE", "الضغط", 13, MUTED, true)
	_drop = _button(pressure_controls, "Drop pressure", "خفض الضغط", func() -> void: pressure_requested.emit(), "Lower pressure below the bubble point · D", "اخفض الضغط دون نقطة الفقاعات · D")
	_drop.add_theme_stylebox_override("normal", _box(Color("#3a2b24"), Color("#896647"), 9, 11, 5))
	_restore = _button(pressure_controls, "Restore pressure", "استعادة الضغط", func() -> void: reset_pressure_requested.emit(), "Raise the pressure again", "ارفع الضغط من جديد")

	var valve := _vertical(controls, 6)
	valve.custom_minimum_size.x = 164.0
	valve.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var valve_heading := _horizontal(valve, 5)
	_caption(valve_heading, "CHOKE OPENING", "فتحة صمام الخنق", 13, MUTED, true)
	_spacer(valve_heading)
	_choke_value = _label(valve_heading, "0%", 14, CYAN, true)
	_choke_slider = _slider(valve, 0.0)
	_choke_slider.value_changed.connect(func(value: float) -> void: choke_changed.emit(value))
	_caption(valve, "Adjusts flow resistance", "تغيّر مقاومة الجريان", 14, MUTED, false, true)

	var sound := _vertical(controls, 6)
	sound.custom_minimum_size.x = 132.0
	_caption(sound, "VOICE VOLUME", "مستوى صوت الحوار", 13, MUTED, true)
	var volume := _slider(sound, 1.0)
	volume.value_changed.connect(func(value: float) -> void: voice_volume_changed.emit(value))
	_mute = _button(sound, "Mute", "كتم الصوت", func() -> void: mute_requested.emit())

	var view := _vertical(controls, 6)
	_caption(view, "CAMERA & DISPLAY", "الكاميرا والشاشة", 13, MUTED, true)
	var view_group := _horizontal(view, 6)
	_button(view_group, "Reset view", "إعادة المنظر", func() -> void: camera_reset_requested.emit(), "Reset camera · C", "إعادة ضبط الكاميرا · C")
	_button(view_group, "Fullscreen", "ملء الشاشة", func() -> void: fullscreen_requested.emit(), "Toggle fullscreen · F11", "ملء الشاشة أو الخروج منها · F11")
	_caption(view, "←  →   Orbit camera", "←  →   تدوير الكاميرا", 14, MUTED)

	var language_group := _vertical(controls, 6)
	_caption(language_group, "LANGUAGE", "اللغة", 13, MUTED, true)
	_locale = _button(language_group, "العربية", "English", _toggle_language)
	_locale.custom_minimum_size.x = 100.0


func _slider(parent: Control, initial: float) -> HSlider:
	var slider := HSlider.new()
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.01
	slider.value = initial
	slider.custom_minimum_size.y = 33.0
	slider.focus_mode = Control.FOCUS_NONE
	parent.add_child(slider)
	return slider


func _build_subtitles() -> void:
	subtitle_label = _label(self, "", 22, TEXT, true, true)
	subtitle_label.name = "RaceSubtitle"
	subtitle_label.anchor_left = 0.0
	subtitle_label.offset_left = 26
	subtitle_label.anchor_right = 0.39
	subtitle_label.anchor_top = 1.0
	subtitle_label.anchor_bottom = 1.0
	subtitle_label.offset_top = -266
	subtitle_label.offset_bottom = -153
	subtitle_label.grow_vertical = Control.GROW_DIRECTION_BEGIN
	subtitle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	subtitle_label.add_theme_stylebox_override("normal", _box(Color(DEEP, 0.96), LINE, 13, 20, 11))
	subtitle_label.hide()


func _toggle_language() -> void:
	_language = "ar" if _language == "en" else "en"
	_apply_language()
	language_changed.emit(_language)


func _apply_language() -> void:
	var is_arabic := _language == "ar"
	var direction := Control.TEXT_DIRECTION_RTL if is_arabic else Control.TEXT_DIRECTION_LTR
	var regular: Font = _arabic_regular if is_arabic else LATIN
	var bold: Font = _arabic_bold if is_arabic else LATIN_BOLD
	for item in _local_strings:
		var control: Control = item["node"]
		control.text = item[_language]
		control.add_theme_font_override("font", bold if item["bold"] else regular)
		control.text_direction = direction
		control.language = _language
		if control is Button:
			control.tooltip_text = item["tip_ar"] if is_arabic else item["tip_en"]
	for label: Label in [_regime_label, _race_status, _gizmo_value, _timer_caption, _lesson]:
		label.add_theme_font_override("font", regular if label == _lesson else bold)
		label.text_direction = direction
		label.language = _language
	for metric: String in ["liquid", "gas"]:
		_telemetry[metric].add_theme_font_override("font", bold)
	subtitle_label.add_theme_font_override("font", bold)
	_locale.add_theme_font_override("font", LATIN_BOLD if is_arabic else _arabic_bold)
	_locale.text_direction = Control.TEXT_DIRECTION_LTR if is_arabic else Control.TEXT_DIRECTION_RTL
	_locale.language = "en" if is_arabic else "ar"
	_refresh_lesson()
	set_paused(_paused)
	set_muted(_muted)
	if is_instance_valid(_last_simulation):
		_last_tick = -100
		sync_state(_last_simulation)


func _refresh_lesson() -> void:
	var translation: Array = LESSONS[_lesson_id]
	_lesson.text = _tr(translation[0], translation[1])


func _tr(english: String, arabic: String) -> String:
	return arabic if _language == "ar" else english


func _percent(value: float) -> String:
	return "%d%%" % roundi(value * 100.0)
