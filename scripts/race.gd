extends Node

const Simulation = preload("res://scripts/race_simulation.gd")
const Stage = preload("res://scripts/race_stage.gd")
const Character = preload("res://scripts/race_character.gd")
const Hud = preload("res://scripts/race_hud.gd")
const Dialogue = preload("res://audio/dialogue_manager.gd")
const Effects = preload("res://audio/simulation_audio.gd")

var simulation: Simulation
var stage: Stage
var hud: Hud
var dialogue: Dialogue
var effects: Effects
var olly: Character
var gizmo: Character
var music: AudioStreamPlayer
var _orbiting := false
var _muted := false
var _closing := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_tree().auto_accept_quit = false
	simulation = Simulation.new()
	simulation.name = "RaceSimulation"
	_add_pausable(simulation)
	stage = Stage.new()
	stage.name = "TubingStage"
	_add_pausable(stage)
	olly = _add_character("olly", stage.olly_mount)
	gizmo = _add_character("gizmo", stage.gizmo_mount)
	var overlay := CanvasLayer.new()
	overlay.name = "RaceOverlay"
	overlay.layer = 10
	add_child(overlay)
	hud = Hud.new()
	hud.name = "RaceHUD"
	overlay.add_child(hud)
	hud.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	effects = Effects.new()
	effects.name = "SimulationAudio"
	_add_pausable(effects)
	_create_music()

	dialogue = Dialogue.new()
	dialogue.name = "DialogueManager"
	dialogue.subtitle_label = hud.subtitle_label
	_add_pausable(dialogue)
	dialogue.set_voice_volume_linear(0.82)

	simulation.event_occurred.connect(_on_simulation_event)
	dialogue.mouth_changed.connect(_on_mouth_changed)
	dialogue.emotion_changed.connect(_on_emotion_changed)
	hud.race_requested.connect(_start_race)
	hud.pressure_requested.connect(_drop_pressure)
	hud.reset_pressure_requested.connect(_restore_pressure)
	hud.choke_changed.connect(_set_choke)
	hud.restart_requested.connect(_reset_race)
	hud.camera_reset_requested.connect(stage.reset_camera)
	hud.language_changed.connect(dialogue.set_subtitle_language)
	hud.voice_volume_changed.connect(dialogue.set_voice_volume_linear)
	hud.pause_requested.connect(_toggle_pause)
	hud.fullscreen_requested.connect(_toggle_fullscreen)
	hud.mute_requested.connect(_toggle_mute)
	_update_visuals(0.0)


func _process(delta: float) -> void:
	if _closing or get_tree().paused:
		return
	simulation.step(delta)
	var active_intensity := simulation.flow_intensity if simulation.running else 0.0
	effects.apply_flow(simulation.regime, active_intensity, simulation.gas_fraction)
	dialogue.set_ambient_conversations_enabled(simulation.running and simulation.gas_visible)
	_update_visuals(delta)


func _update_visuals(delta: float) -> void:
	stage.update_race(
		simulation.olly_progress, simulation.gizmo_progress,
		simulation.gas_visible, simulation.regime,
		simulation.flow_intensity if simulation.running else 0.0,
		simulation.gas_fraction, simulation.pressure
	)
	olly.set_motion(simulation.flow_intensity if simulation.running else 0.0)
	gizmo.set_motion(simulation.flow_intensity if simulation.running else 0.0)
	var camera := get_viewport().get_camera_3d()
	if camera != null:
		_face_camera(olly, camera, delta)
		_face_camera(gizmo, camera, delta)
	hud.sync_state(simulation)


func _face_camera(character: Character, camera: Camera3D, delta: float) -> void:
	var to_camera := camera.global_position - character.global_position
	var angle := atan2(to_camera.x, to_camera.z)
	character.rotation.y = lerp_angle(character.rotation.y, angle, minf(delta * 7.0, 1.0))


func _add_pausable(node: Node) -> void:
	node.process_mode = Node.PROCESS_MODE_PAUSABLE
	add_child(node)


func _add_character(speaker: String, mount: Node3D) -> Character:
	var character := Character.new()
	character.name = speaker.capitalize()
	character.speaker = speaker
	mount.add_child(character)
	return character


func _create_music() -> void:
	const MUSIC_FILE := "res://audio/music/laboratory.ogg"
	if not ResourceLoader.exists(MUSIC_FILE, "AudioStreamOggVorbis"):
		return
	if AudioServer.get_bus_index(&"Music") < 0:
		AudioServer.add_bus()
		AudioServer.set_bus_name(AudioServer.bus_count - 1, &"Music")
	var track := load(MUSIC_FILE) as AudioStreamOggVorbis
	track.loop = true
	music = AudioStreamPlayer.new()
	music.name = "LabMusic"
	music.bus = &"Music"
	music.volume_db = -14.0
	music.stream = track
	_add_pausable(music)
	music.play()


func _start_race(automatic: bool) -> void:
	dialogue.reset()
	effects.reset()
	get_tree().paused = false
	hud.set_paused(false)
	simulation.start(automatic)
	_update_visuals(0.0)


func _reset_race() -> void:
	get_tree().paused = false
	hud.set_paused(false)
	dialogue.reset()
	effects.reset()
	simulation.reset()
	stage.reset_camera()
	hud.show_event("idle")
	_update_visuals(0.0)


func _on_simulation_event(event_id: String) -> void:
	hud.show_event(event_id)
	_queue_dialogue(event_id)
	effects.trigger_event(event_id)
	match event_id:
		"pressure_drop":
			stage.shake(0.12)
		"gas_appeared":
			gizmo.hop(1.0)
		"slug_flow", "character_collision":
			stage.shake(0.21)
			olly.hop(0.55)
		"character_jumped":
			gizmo.hop(0.75)
		"victory":
			stage.celebrate(simulation.winner)
			olly.hop(1.0)
			if simulation.gas_visible:
				gizmo.hop(1.0)


func _queue_dialogue(event_id: String) -> void:
	const SINGLE_PHASE_EVENTS := {
		"choke_changed": [45, 5.0],
		"flow_accelerated": [45, 5.0],
		"flow_decelerated": [45, 5.0],
		"finale": [90, 0.0],
		"victory": [100, 0.0],
		"celebration": [65, 0.0],
	}
	if event_id == "race_start":
		dialogue.trigger_event(event_id, 110)
	elif not simulation.gas_visible and SINGLE_PHASE_EVENTS.has(event_id):
		var policy: Array = SINGLE_PHASE_EVENTS[event_id]
		dialogue.trigger_event(event_id + "_olly", int(policy[0]), float(policy[1]))
	else:
		dialogue.trigger_event(event_id)


func _drop_pressure() -> void:
	if simulation.running and not simulation.automatic and not get_tree().paused:
		simulation.drop_pressure()


func _restore_pressure() -> void:
	if simulation.running and not simulation.automatic and not get_tree().paused:
		simulation.reset_pressure()


func _set_choke(opening: float) -> void:
	if not simulation.automatic and not simulation.finished and not get_tree().paused:
		simulation.set_choke(opening)


func _on_mouth_changed(speaker: String, openness: float) -> void:
	match speaker:
		"olly": olly.set_mouth(openness)
		"gizmo": gizmo.set_mouth(openness)


func _on_emotion_changed(speaker: String, emotion: String) -> void:
	match speaker:
		"olly": olly.set_emotion(emotion)
		"gizmo": gizmo.set_emotion(emotion)


func _toggle_pause() -> void:
	if simulation.running or get_tree().paused:
		get_tree().paused = not get_tree().paused
		hud.set_paused(get_tree().paused)


func _toggle_fullscreen() -> void:
	var mode := DisplayServer.window_get_mode()
	if mode == DisplayServer.WINDOW_MODE_FULLSCREEN:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)


func _toggle_mute() -> void:
	_muted = not _muted
	AudioServer.set_bus_mute(0, _muted)
	hud.set_muted(_muted)


func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	match event.keycode:
		KEY_SPACE:
			if not simulation.running:
				_start_race(false)
		KEY_D: _drop_pressure()
		KEY_P: _toggle_pause()
		KEY_R: _reset_race()
		KEY_C: stage.reset_camera()
		KEY_LEFT: stage.orbit(-1.0)
		KEY_RIGHT: stage.orbit(1.0)
		KEY_F11: _toggle_fullscreen()
		_: return
	get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_RIGHT:
		_orbiting = event.pressed
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _orbiting:
		if event.button_mask & MOUSE_BUTTON_MASK_RIGHT:
			stage.orbit(event.relative.x * 0.035)
		else:
			_orbiting = false


func _notification(what: int) -> void:
	if what != NOTIFICATION_WM_CLOSE_REQUEST or _closing:
		return
	_closing = true
	set_process_input(false)
	set_process_unhandled_input(false)
	set_process_unhandled_key_input(false)
	get_tree().paused = false
	dialogue.reset()
	effects.reset()
	if is_instance_valid(music):
		music.stop()
		music.stream = null
	# Allow the audio server to release the active Vorbis playbacks.
	await get_tree().create_timer(0.09).timeout
	get_tree().quit()
