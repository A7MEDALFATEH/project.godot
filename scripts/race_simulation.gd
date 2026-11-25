extends Node
## A qualitative, fixed-deliverability example for the exhibition.
## Pressure readings are in psi and superficial velocity indicators are in m/s.

signal event_occurred(event_id: String)

const INITIAL_PRESSURE := 2850.0
const MIN_PRESSURE := 900.0
const BUBBLE_POINT := 2300.0
const INITIAL_CHOKE := 0.55
const PRESSURE_STEP := 700.0
const GUIDED_CUES := [
	[3.0, "welcome"],
	[12.0, "single_phase"],
	[17.0, "single_phase_banter"],
	[38.0, "gas_challenge"],
	[67.0, "slug_narration"],
]

var running := false
var finished := false
var automatic := false
var state: String:
	get:
		if running:
			return "running"
		return "finished" if finished else "idle"
var elapsed := 0.0
var pressure := INITIAL_PRESSURE
var bubble_point := BUBBLE_POINT
var choke := INITIAL_CHOKE
var regime := "single_phase"
var gas_visible := false
var gas_fraction := 0.0
var flow_intensity := 0.0
var gas_expansion := 0.0
var liquid_rate := 0.0
var gas_rate := 0.0
var olly_progress := 0.0
var gizmo_progress := 0.0
var winner := ""

var _pressure_command := INITIAL_PRESSURE
var _choke_response := INITIAL_CHOKE
var _choke_anchor := INITIAL_CHOKE
var _choke_event_at := -10.0
var _last_flow_change_at := -10.0
var _flow_change_reference := -1.0
var _gas_live_time := 0.0
var _gas_intro_sent := false
var _expanded := false
var _collided := false
var _finale_sent := false
var _guide_cue := 0


func _ready() -> void:
	reset()


func reset() -> void:
	running = false
	finished = false
	automatic = false
	elapsed = 0.0
	choke = INITIAL_CHOKE
	pressure = INITIAL_PRESSURE
	regime = "single_phase"
	gas_visible = false
	olly_progress = 0.0
	gizmo_progress = 0.0
	winner = ""
	_pressure_command = INITIAL_PRESSURE
	_choke_response = INITIAL_CHOKE
	_choke_anchor = INITIAL_CHOKE
	_choke_event_at = -10.0
	_last_flow_change_at = -10.0
	_flow_change_reference = -1.0
	_gas_live_time = 0.0
	_gas_intro_sent = false
	_expanded = false
	_collided = false
	_finale_sent = false
	_guide_cue = 0
	_update_rates()


func start(guided: bool = false) -> void:
	var starting_opening := choke if not guided and not running and not finished else INITIAL_CHOKE
	reset()
	choke = starting_opening
	automatic = guided
	running = true
	event_occurred.emit("race_start")


func set_choke(value: float) -> void:
	choke = clampf(value, 0.0, 1.0)
	if not running or absf(choke - _choke_anchor) < 0.07 or elapsed - _choke_event_at < 0.8:
		return
	_choke_anchor = choke
	_choke_event_at = elapsed
	_flow_change_reference = liquid_rate + gas_rate
	event_occurred.emit("choke_changed")


func drop_pressure() -> void:
	var next_pressure := maxf(MIN_PRESSURE, _pressure_command - PRESSURE_STEP)
	if is_equal_approx(next_pressure, _pressure_command):
		return
	_pressure_command = next_pressure
	if running:
		event_occurred.emit("pressure_drop")


func reset_pressure() -> void:
	if is_equal_approx(_pressure_command, INITIAL_PRESSURE):
		return
	_pressure_command = INITIAL_PRESSURE
	if running:
		event_occurred.emit("pressure_restored")


func step(delta: float) -> void:
	if delta <= 0.0:
		return
	if running:
		var previous_elapsed := elapsed
		elapsed += delta
		if automatic:
			_advance_guide(previous_elapsed)
	# This scenario couples liquid velocity to choke restriction, with a smaller
	# effect on the local pressure reading. Neither relationship is universal.
	_choke_response = lerpf(_choke_response, choke, 1.0 - exp(-delta * 2.6))
	var pressure_target := maxf(MIN_PRESSURE, _pressure_command + (INITIAL_CHOKE - _choke_response) * 250.0)
	pressure = move_toward(pressure, pressure_target, delta * 345.0)
	_update_rates()
	_update_regime()
	if not running:
		return
	_update_reactions(delta)
	_advance_race(delta)


func _update_rates() -> void:
	liquid_rate = 1.55 * pow(_choke_response, 0.83)
	var liberated := clampf((BUBBLE_POINT - pressure) / (BUBBLE_POINT - MIN_PRESSURE), 0.0, 1.0)
	var volume_ratio := BUBBLE_POINT / minf(BUBBLE_POINT, pressure)
	gas_expansion = clampf((volume_ratio - 1.0) / (BUBBLE_POINT / MIN_PRESSURE - 1.0), 0.0, 1.0)
	gas_rate = liquid_rate * 0.88 * liberated * volume_ratio
	var total_rate := liquid_rate + gas_rate
	gas_fraction = gas_rate / total_rate if total_rate > 0.005 else 0.0
	flow_intensity = clampf(total_rate / 3.7, 0.0, 1.0)


func _update_regime() -> void:
	var old_gas := gas_visible
	var old_regime := regime
	gas_visible = pressure < BUBBLE_POINT
	if not gas_visible:
		regime = "single_phase"
	elif regime == "slug_flow":
		if gas_rate < 0.29 or liquid_rate < 0.21 or gas_fraction < 0.29:
			regime = "bubble_flow"
	elif gas_rate > 0.38 and liquid_rate > 0.29 and gas_fraction > 0.34:
		regime = "slug_flow"
	else:
		regime = "bubble_flow"

	if not running:
		return
	if not old_gas and gas_visible:
		gizmo_progress = maxf(0.0, olly_progress - (0.046 if automatic else 0.074))
		_gas_live_time = 0.0
		_gas_intro_sent = false
		event_occurred.emit("bubble_point_crossed")
		event_occurred.emit("gas_appeared")
	elif old_gas and not gas_visible:
		_expanded = false

	if old_regime != regime and regime != "single_phase":
		event_occurred.emit(regime)


func _update_reactions(delta: float) -> void:
	if gas_visible:
		_gas_live_time += delta
		if not _gas_intro_sent and _gas_live_time >= 5.5 and gas_rate > 0.025:
			_gas_intro_sent = true
			event_occurred.emit("gas_accelerated")
			event_occurred.emit("character_jumped")
		if not _expanded and gas_expansion >= 0.22:
			_expanded = true
			event_occurred.emit("gas_expansion")
	if _flow_change_reference >= 0.0 and elapsed - _choke_event_at >= 0.9:
		var rate_change := liquid_rate + gas_rate - _flow_change_reference
		_flow_change_reference = -1.0
		if absf(rate_change) >= 0.08 and elapsed - _last_flow_change_at >= 3.5:
			_last_flow_change_at = elapsed
			event_occurred.emit("flow_accelerated" if rate_change > 0.0 else "flow_decelerated")


func _advance_guide(previous_elapsed: float) -> void:
	while _guide_cue < GUIDED_CUES.size() and elapsed >= GUIDED_CUES[_guide_cue][0]:
		event_occurred.emit(GUIDED_CUES[_guide_cue][1])
		_guide_cue += 1
	if previous_elapsed < 25.0 and elapsed >= 25.0:
		drop_pressure()
	if previous_elapsed < 59.0 and elapsed >= 59.0:
		drop_pressure()
	if previous_elapsed < 83.0 and elapsed >= 83.0:
		set_choke(0.22)
	if previous_elapsed < 91.0 and elapsed >= 91.0:
		set_choke(0.78)


func _advance_race(delta: float) -> void:
	var olly_speed := 0.028 * liquid_rate + 0.012 * gas_rate
	var gizmo_speed := 0.033 * liquid_rate + 0.021 * gas_rate
	if not _gas_intro_sent:
		gizmo_speed *= 0.77
	if regime == "slug_flow":
		var surge := sin(elapsed * 3.2)
		olly_speed *= 1.0 + 0.16 * surge
		gizmo_speed *= 1.0 + 0.24 * surge
	var pace := 1.0
	if automatic:
		pace = lerpf(0.29, 0.93, smoothstep(95.0, 103.0, elapsed))

	var old_gap := gizmo_progress - olly_progress
	var new_olly := olly_progress + olly_speed * pace * delta
	var new_gizmo := gizmo_progress + gizmo_speed * pace * delta if gas_visible else gizmo_progress
	olly_progress = minf(1.0, new_olly)
	gizmo_progress = minf(1.0, new_gizmo)
	if not _collided and gas_visible and old_gap < 0.0 and new_gizmo >= new_olly and olly_progress > 0.18:
		_collided = true
		event_occurred.emit("character_collision")

	var lead_progress := maxf(olly_progress, gizmo_progress)
	if not _finale_sent and (lead_progress >= 0.82 or (automatic and elapsed >= 100.0)):
		_finale_sent = true
		event_occurred.emit("finale")
	if lead_progress >= 1.0:
		winner = "gizmo" if gas_visible and new_gizmo > new_olly else "olly"
		finished = true
		running = false
		event_occurred.emit("victory")
		event_occurred.emit("celebration")
		event_occurred.emit("conclusion")
