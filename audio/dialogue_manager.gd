extends Node
## Plays queued dialogue, displays subtitles, and emits playback-driven rig signals.

signal speech_started(line_id: String, speakers: Array[String], emotion: String)
signal speech_ended(line_id: String, speakers: Array[String])
signal mouth_changed(speaker: String, openness: float)
signal emotion_changed(speaker: String, emotion: String)

const DEFAULT_PRIORITY := 50
const AMBIENT_PRIORITY := 10
const EVENT_POLICIES := {
	"race_start": [90, 0.0],
	"welcome": [60, 0.0],
	"single_phase": [40, 5.0],
	"single_phase_banter": [35, 7.0],
	"pressure_drop": [85, 4.0],
	"bubble_point_crossed": [85, 5.0],
	"gas_appeared": [95, 5.0],
	"gas_challenge": [55, 6.0],
	"bubble_flow": [75, 7.0],
	"bubble_flow_banter": [40, 7.0],
	"gas_accelerated": [75, 5.0],
	"slug_flow": [85, 7.0],
	"slug_narration": [75, 5.0],
	"choke_changed": [45, 5.0],
	"flow_accelerated": [45, 5.0],
	"flow_decelerated": [45, 5.0],
	"gas_expansion": [70, 6.0],
	"finale": [90, 0.0],
	"victory": [100, 0.0],
	"celebration": [65, 0.0],
	"conclusion": [60, 0.0],
	"ambient_conversation": [AMBIENT_PRIORITY, 10.0],
	"demo": [40, 0.0],
	"demo_olly": [40, 0.0],
	"demo_gizmo": [40, 0.0],
}
const SUBTITLE_COLORS := {
	"olly": Color("#ffcb72"),
	"gizmo": Color("#83eeff"),
	"narrator": Color.WHITE,
	"both": Color.WHITE,
}
const ENGLISH_NAMES := {
	"olly": "Olly", "gizmo": "Gizmo", "narrator": "Narrator", "both": "Olly and Gizmo",
}
const ARABIC_NAMES := {
	"olly": "أولي", "gizmo": "غيزمو", "narrator": "الراوي", "both": "أولي وغيزمو",
}

@export var audio_root := "res://audio"
@export var voice_bus := &"Voice"
@export var duck_buses: Array[StringName] = [&"Music", &"Flow"]
@export_range(0.0, 24.0) var duck_amount_db := 8.0
@export var subtitle_label: Label
@export_enum("en", "ar") var subtitle_language := "en"

var _lines: Dictionary = {}
var _events: Dictionary = {}
var _envelopes: Dictionary = {}
var _envelope_rate := 50.0
var _players: Dictionary = {}
var _spatial_players: Dictionary = {}
var _streams: Dictionary = {}
var _available_at: Dictionary = {}
var _last_variation: Dictionary = {}
var _queue: Array[Dictionary] = []
var _group: Dictionary = {}
var _active_line_id := ""
var _active_tracks: Array[Dictionary] = []
var _active_speakers: Array[String] = []
var _output_latency := 0.0
var _voice_gain := 1.0
var _duck_effects: Dictionary = {}
var _duck_gain_db := 0.0
var _subtitle_holder: Control
var _subtitle_tween: Tween
var _ambient_enabled := false
var _next_ambient_at := 0.0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	var manifest := _read_json(audio_root.path_join("dialogue.json"))
	_lines = manifest.get("lines", {})
	_events = manifest.get("events", {})
	var envelopes := _read_json(audio_root.path_join("voices/envelopes.json"))
	_envelopes = envelopes.get("tracks", {})
	_envelope_rate = maxf(float(envelopes.get("sample_rate", 50.0)), 1.0)
	if AudioServer.get_bus_index(voice_bus) < 0:
		AudioServer.add_bus()
		AudioServer.set_bus_name(AudioServer.bus_count - 1, voice_bus)
	for speaker in ["olly", "gizmo", "narrator"]:
		var player := AudioStreamPlayer.new()
		player.name = "%sVoice" % String(speaker).capitalize()
		player.bus = voice_bus
		add_child(player)
		_players[speaker] = player
	if is_instance_valid(subtitle_label):
		_subtitle_holder = subtitle_label
	else:
		_create_subtitle()
	_subtitle_holder.hide()


func _exit_tree() -> void:
	_finish_line()
	for bus_name: StringName in _duck_effects:
		var bus_index := AudioServer.get_bus_index(bus_name)
		if bus_index == -1:
			continue
		for effect_index in range(AudioServer.get_bus_effect_count(bus_index) - 1, -1, -1):
			if AudioServer.get_bus_effect(bus_index, effect_index) == _duck_effects[bus_name]:
				AudioServer.remove_bus_effect(bus_index, effect_index)
	_duck_effects.clear()


## Use a dedicated player on the character rig for optional spatial dialogue.
## Passing null restores the manager's non-spatial player for that speaker.
func bind_voice_player(speaker: String, player: AudioStreamPlayer3D) -> void:
	if player == null:
		_spatial_players.erase(speaker)
		return
	player.bus = voice_bus
	_spatial_players[speaker] = player


func set_voice_volume_linear(gain: float) -> void:
	_voice_gain = clampf(gain, 0.0, 1.0)
	for track in _active_tracks:
		var player: Node = track["player"]
		if is_instance_valid(player):
			player.volume_db = _voice_gain_db()


func set_subtitle_language(language: String) -> void:
	subtitle_language = "ar" if language.begins_with("ar") else "en"
	if not _active_line_id.is_empty():
		_update_subtitle()


func set_ambient_conversations_enabled(enabled: bool) -> void:
	if _ambient_enabled == enabled:
		return
	_ambient_enabled = enabled
	if enabled:
		_schedule_ambient()
		return
	for index in range(_queue.size() - 1, -1, -1):
		if _queue[index]["event"] == "ambient_conversation":
			_queue.remove_at(index)
	if _group.get("event", "") == "ambient_conversation":
		_group.clear()
		_finish_line()


## A negative priority or cooldown uses the dialogue event's default.
func trigger_event(event_id: String, priority: int = -1, cooldown: float = -1.0) -> bool:
	var variants: Array = _events.get(event_id, [])
	var now := _clock()
	if variants.is_empty() or now < float(_available_at.get(event_id, 0.0)):
		return false
	if _group.get("event", "") == event_id:
		return false
	for entry in _queue:
		if entry["event"] == event_id:
			return false
	var policy: Array = EVENT_POLICIES.get(event_id, [DEFAULT_PRIORITY, 3.0])
	if priority < 0:
		priority = int(policy[0])
	if cooldown < 0.0:
		cooldown = float(policy[1])
	if priority <= AMBIENT_PRIORITY and (not _group.is_empty() or not _queue.is_empty()):
		return false
	var previous := int(_last_variation.get(event_id, -1))
	var choice := 0
	if previous >= 0 and variants.size() > 1:
		choice = _rng.randi_range(0, variants.size() - 2)
		if choice >= previous:
			choice += 1
	elif variants.size() > 1:
		choice = _rng.randi_range(0, variants.size() - 1)
	var sequence: Array = variants[choice]
	if sequence.is_empty():
		return false
	_last_variation[event_id] = choice
	_available_at[event_id] = now + cooldown
	_enqueue(event_id, sequence, priority)
	return true


func speak(line_id: String, priority: int = DEFAULT_PRIORITY) -> bool:
	if not _lines.has(line_id):
		return false
	_enqueue("", [line_id], priority)
	return true


func reset() -> void:
	_queue.clear()
	_group.clear()
	_available_at.clear()
	_last_variation.clear()
	_ambient_enabled = false
	_finish_line()
	if _subtitle_tween:
		_subtitle_tween.kill()
	if is_instance_valid(_subtitle_holder):
		_subtitle_holder.hide()


func _process(delta: float) -> void:
	if not _active_line_id.is_empty():
		var interrupted := (
			int(_group.get("priority", DEFAULT_PRIORITY)) <= AMBIENT_PRIORITY
			and not _queue.is_empty()
			and int(_queue[0]["priority"]) > AMBIENT_PRIORITY
		)
		if interrupted or not _update_playback():
			if interrupted:
				_group.clear()
			_finish_line()
	if _active_line_id.is_empty():
		_play_next()
	_update_ducking(delta)


func _enqueue(event_id: String, sequence: Array, priority: int) -> void:
	var entry := {"event": event_id, "lines": sequence.duplicate(), "priority": priority}
	if priority > AMBIENT_PRIORITY:
		for index in range(_queue.size() - 1, -1, -1):
			if int(_queue[index]["priority"]) <= AMBIENT_PRIORITY:
				_queue.remove_at(index)
	for index in range(_queue.size()):
		if priority > int(_queue[index]["priority"]):
			_queue.insert(index, entry)
			return
	_queue.push_back(entry)


func _play_next() -> void:
	while true:
		if not _group.is_empty() and _group["lines"].is_empty():
			_group.clear()
		if (
			not _group.is_empty()
			and not _queue.is_empty()
			and int(_queue[0]["priority"]) > int(_group["priority"])
		):
			# Leave completed speech intact and resume the remaining sequence later.
			_enqueue(_group["event"], _group["lines"], _group["priority"])
			_group = {}
		if _group.is_empty():
			if _queue.is_empty() and _ambient_enabled and _clock() >= _next_ambient_at:
				_schedule_ambient()
				trigger_event("ambient_conversation")
			if _queue.is_empty():
				return
			_group = _queue.pop_front()
		var line_id: String = _group["lines"].pop_front()
		if _start_line(line_id):
			return


func _start_line(line_id: String) -> bool:
	var line: Dictionary = _lines.get(line_id, {})
	if line.is_empty():
		push_warning("Unknown dialogue line: %s" % line_id)
		return false
	var clip_ids: Array = line.get("tracks", [line_id])
	for clip_id: String in clip_ids:
		var clip: Dictionary = _lines.get(clip_id, {})
		var speaker: String = clip.get("speaker", "")
		var player: Node = _spatial_players.get(speaker)
		if not is_instance_valid(player) or not player.is_inside_tree():
			player = _players.get(speaker)
		if not is_instance_valid(player):
			push_warning("Unknown speaker for dialogue clip: %s" % clip_id)
			continue
		if _active_speakers.has(speaker):
			push_warning("Dialogue clip uses the same speaker more than once: %s" % line_id)
			continue
		var stream := _load_voice(speaker, clip_id)
		if stream == null:
			continue
		player.stream = stream
		player.volume_db = _voice_gain_db()
		_active_tracks.append({
			"speaker": speaker,
			"player": player,
			"envelope": _envelopes.get(clip_id, []),
			"mouth": 0.0,
		})
		_active_speakers.append(speaker)
	if _active_tracks.is_empty():
		return false
	if _active_tracks.size() > 1:
		for track in _active_tracks:
			track["player"].volume_db -= 3.5
	_active_line_id = line_id
	_output_latency = AudioServer.get_output_latency()
	for track in _active_tracks:
		track["player"].play()
	_schedule_ambient()
	_update_subtitle()
	_fade_subtitle(true)
	var emotion: String = line.get("emotion", "neutral")
	for speaker in _active_speakers:
		emotion_changed.emit(speaker, emotion)
	speech_started.emit(line_id, _active_speakers.duplicate(), emotion)
	return true


func _update_playback() -> bool:
	var playing := false
	for track in _active_tracks:
		var player: Node = track["player"]
		var mouth := 0.0
		if is_instance_valid(player) and player.playing:
			playing = true
			var position: float = player.get_playback_position()
			position += AudioServer.get_time_since_last_mix() - _output_latency
			var envelope: Array = track["envelope"]
			var sample := maxf(0.0, position) * _envelope_rate
			var frame := int(sample)
			if frame < envelope.size():
				var next := mini(frame + 1, envelope.size() - 1)
				mouth = clampf(lerpf(envelope[frame], envelope[next], sample - frame), 0.0, 1.0)
		if not is_equal_approx(mouth, float(track["mouth"])):
			track["mouth"] = mouth
			mouth_changed.emit(track["speaker"], mouth)
	return playing


func _finish_line() -> void:
	if _active_line_id.is_empty():
		return
	var line_id := _active_line_id
	var speakers := _active_speakers.duplicate()
	_active_line_id = ""
	for track in _active_tracks:
		var player: Node = track["player"]
		if is_instance_valid(player):
			player.stop()
			player.stream = null
	_active_tracks.clear()
	_active_speakers.clear()
	_schedule_ambient()
	_fade_subtitle(false)
	for speaker: String in speakers:
		mouth_changed.emit(speaker, 0.0)
		emotion_changed.emit(speaker, "neutral")
	speech_ended.emit(line_id, speakers)


func _load_voice(speaker: String, clip_id: String) -> AudioStream:
	if not _streams.has(clip_id):
		var path := audio_root.path_join("voices/%s/%s.ogg" % [speaker, clip_id.to_lower()])
		if ResourceLoader.exists(path, "AudioStream"):
			_streams[clip_id] = ResourceLoader.load(path, "AudioStream")
		elif FileAccess.file_exists(path):
			_streams[clip_id] = AudioStreamOggVorbis.load_from_file(path)
		else:
			push_warning("Missing dialogue audio: %s" % path)
			_streams[clip_id] = null
	return _streams[clip_id]


func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		push_warning("Dialogue data is missing: %s" % path)
		return {}
	var contents: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if not contents is Dictionary:
		push_warning("Dialogue data is invalid: %s" % path)
		return {}
	return contents


func _voice_gain_db() -> float:
	var group_gain := -3.5 if _active_tracks.size() > 1 else 0.0
	return linear_to_db(maxf(_voice_gain, 0.0001)) + group_gain


func _clock() -> float:
	return Time.get_ticks_msec() / 1000.0


func _schedule_ambient() -> void:
	_next_ambient_at = _clock() + _rng.randf_range(6.0, 10.0)


func _update_ducking(delta: float) -> void:
	var is_speaking := not _active_line_id.is_empty() and _voice_gain > 0.0
	if is_speaking:
		for bus_name in duck_buses:
			var bus_index := AudioServer.get_bus_index(bus_name)
			if bus_index >= 0 and bus_name != &"Master" and bus_name != voice_bus:
				if not _duck_effects.has(bus_name):
					var effect := AudioEffectAmplify.new()
					AudioServer.add_bus_effect(bus_index, effect)
					_duck_effects[bus_name] = effect
	var target := -duck_amount_db if is_speaking else 0.0
	_duck_gain_db = move_toward(_duck_gain_db, target, delta * (65.0 if is_speaking else 24.0))
	for effect: AudioEffectAmplify in _duck_effects.values():
		effect.volume_db = _duck_gain_db


func _create_subtitle() -> void:
	var layer := CanvasLayer.new()
	layer.name = "DialogueSubtitles"
	layer.layer = 20
	add_child(layer)
	var panel := PanelContainer.new()
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(panel)
	panel.anchor_left = 0.12
	panel.anchor_right = 0.88
	panel.anchor_top = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_top = -110.0
	panel.offset_bottom = -28.0
	panel.grow_vertical = Control.GROW_DIRECTION_BEGIN
	var background := StyleBoxFlat.new()
	background.bg_color = Color(0.02, 0.05, 0.08, 0.89)
	background.set_corner_radius_all(12)
	background.content_margin_left = 18
	background.content_margin_right = 18
	background.content_margin_top = 8
	background.content_margin_bottom = 8
	panel.add_theme_stylebox_override("panel", background)
	subtitle_label = Label.new()
	subtitle_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	subtitle_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	subtitle_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	subtitle_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	subtitle_label.add_theme_font_size_override("font_size", 24)
	panel.add_child(subtitle_label)
	_subtitle_holder = panel


func _update_subtitle() -> void:
	if not is_instance_valid(subtitle_label):
		return
	var line: Dictionary = _lines[_active_line_id]
	var speaker: String = line["speaker"]
	var show_arabic := subtitle_language == "ar" and not String(line.get("arabic", "")).is_empty()
	var names := ARABIC_NAMES if show_arabic else ENGLISH_NAMES
	var name_text: String = names.get(speaker, speaker)
	var spoken_text: String = line["arabic"] if show_arabic else line["text"]
	subtitle_label.text_direction = (
		Control.TEXT_DIRECTION_RTL if show_arabic else Control.TEXT_DIRECTION_LTR
	)
	subtitle_label.language = "ar" if show_arabic else "en"
	subtitle_label.text = "%s: %s" % [name_text, spoken_text]
	subtitle_label.add_theme_color_override("font_color", SUBTITLE_COLORS.get(speaker, Color.WHITE))


func _fade_subtitle(show_subtitle: bool) -> void:
	if not is_instance_valid(_subtitle_holder) or not is_inside_tree():
		return
	if _subtitle_tween:
		_subtitle_tween.kill()
	if show_subtitle:
		if not _subtitle_holder.visible:
			_subtitle_holder.modulate.a = 0.0
		_subtitle_holder.show()
	_subtitle_tween = create_tween()
	var alpha := 1.0 if show_subtitle else 0.0
	_subtitle_tween.tween_property(_subtitle_holder, "modulate:a", alpha, 0.10)
	if not show_subtitle:
		_subtitle_tween.tween_callback(_subtitle_holder.hide)
