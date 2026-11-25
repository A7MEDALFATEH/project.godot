extends Node
## Mixes continuous flow from the simulation state and plays discrete effects.

const LOOP_IDS := ["oil_flow", "gas_bubbles", "bubble_flow", "slug_flow"]
const EFFECTS := {
	"pressure_drop": [0.72, 1.0],
	"gas_appeared": [0.73, 0.7],
	"gas_expand": [0.57, 0.6],
	"choke_valve": [0.51, 0.18],
	"jump": [0.58, 0.09],
	"collision": [0.65, 0.11],
	"victory": [0.80, 1.5],
}
const EVENT_ALIASES := {
	"gas_expansion": "gas_expand",
	"choke_changed": "choke_valve",
	"character_jumped": "jump",
	"character_collision": "collision",
}

@export var audio_root := "res://audio"
@export var flow_bus := &"Flow"
@export var sfx_bus := &"SFX"

var _loop_players: Dictionary = {}
var _effect_players: Dictionary = {}
var _loop_volumes: Dictionary = {}
var _loop_targets: Dictionary = {}
var _available_at: Dictionary = {}
var _flow_pitch := 1.0
var _gain := 1.0


func _ready() -> void:
	for bus_name in [flow_bus, sfx_bus]:
		if AudioServer.get_bus_index(bus_name) < 0:
			AudioServer.add_bus()
			AudioServer.set_bus_name(AudioServer.bus_count - 1, bus_name)
	for loop_id in LOOP_IDS:
		var player := _create_player(loop_id, flow_bus, true)
		if player != null:
			_loop_players[loop_id] = player
			_loop_volumes[loop_id] = 0.0
	for effect_id: String in EFFECTS:
		var player := _create_player(effect_id, sfx_bus, false)
		if player != null:
			player.volume_db = _effect_volume_db(effect_id)
			_effect_players[effect_id] = player


## Pass the game's actual regime and normalized intensity and gas fraction (0–1).
## Passing zero intensity fades all flow out.
func apply_flow(regime: String, flow_intensity: float, gas_fraction: float) -> bool:
	if regime not in ["single_phase", "bubble_flow", "slug_flow"]:
		return false
	var intensity := clampf(flow_intensity, 0.0, 1.0)
	var gas := clampf(gas_fraction, 0.0, 1.0)
	_flow_pitch = lerpf(0.83, 1.26, intensity)
	_loop_targets = {
		"oil_flow": intensity * (0.23 - 0.10 * gas),
		"gas_bubbles": intensity * gas * 0.15 if regime != "single_phase" else 0.0,
		"bubble_flow": intensity * (0.10 + 0.18 * gas) if regime == "bubble_flow" else 0.0,
		"slug_flow": intensity * (0.16 + 0.17 * gas) if regime == "slug_flow" else 0.0,
	}
	return true


func trigger_event(event_id: String) -> bool:
	var effect_id: String = EVENT_ALIASES.get(event_id, event_id)
	var player: AudioStreamPlayer = _effect_players.get(effect_id)
	var now := Time.get_ticks_msec() / 1000.0
	if player == null or now < float(_available_at.get(effect_id, 0.0)):
		return false
	_available_at[effect_id] = now + float(EFFECTS[effect_id][1])
	player.play()
	return true


func set_sfx_volume_linear(gain: float) -> void:
	_gain = clampf(gain, 0.0, 1.0)
	for effect_id: String in _effect_players:
		_effect_players[effect_id].volume_db = _effect_volume_db(effect_id)


func reset() -> void:
	_apply_silence()
	for player: AudioStreamPlayer in _effect_players.values():
		player.stop()
	_available_at.clear()


func _process(delta: float) -> void:
	for loop_id: String in _loop_players:
		var player: AudioStreamPlayer = _loop_players[loop_id]
		var target := float(_loop_targets.get(loop_id, 0.0)) * _gain
		var volume := move_toward(float(_loop_volumes[loop_id]), target, delta * 0.72)
		if is_zero_approx(volume) and is_zero_approx(target):
			if player.playing:
				player.stop()
			_loop_volumes[loop_id] = 0.0
			continue
		player.volume_db = linear_to_db(maxf(volume, 0.0001))
		player.pitch_scale = move_toward(player.pitch_scale, _flow_pitch, delta * 0.65)
		if not player.playing:
			player.play()
		_loop_volumes[loop_id] = volume


func _create_player(effect_id: String, bus_name: StringName, looping: bool) -> AudioStreamPlayer:
	var path := audio_root.path_join("sfx/%s.wav" % effect_id)
	var stream: AudioStreamWAV
	if ResourceLoader.exists(path, "AudioStream"):
		stream = ResourceLoader.load(path, "AudioStream") as AudioStreamWAV
	elif FileAccess.file_exists(path):
		stream = AudioStreamWAV.load_from_file(path)
	if stream == null:
		push_warning("Missing or invalid sound effect: %s" % path)
		return null
	if looping:
		stream = stream.duplicate() as AudioStreamWAV
		stream.loop_begin = 0
		stream.loop_end = roundi(stream.get_length() * stream.mix_rate)
		stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
	var player := AudioStreamPlayer.new()
	player.name = effect_id.to_pascal_case()
	player.bus = bus_name
	player.stream = stream
	player.volume_db = -80.0
	if not looping:
		player.max_polyphony = 2
	add_child(player)
	return player


func _effect_volume_db(effect_id: String) -> float:
	return linear_to_db(maxf(float(EFFECTS[effect_id][0]) * _gain, 0.0001))


func _apply_silence() -> void:
	_loop_targets.clear()
	for loop_id: String in _loop_players:
		_loop_players[loop_id].stop()
		_loop_players[loop_id].pitch_scale = 1.0
		_loop_volumes[loop_id] = 0.0
