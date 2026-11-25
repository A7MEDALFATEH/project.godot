extends Node3D
## A compatibility-renderer exhibition set. Animation inputs come from the race model.

const TUBE_RADIUS := 1.76
const TUBE_BASE := 0.8
const TUBE_TOP := 11.6
const START_HEIGHT := 1.37
const FINISH_HEIGHT := 10.52
const CAMERA_HEIGHT := 7.7
const CAMERA_TARGET := Vector3(0.0, 5.95, 0.0)
const BUBBLE_COUNT := 54

var olly_mount: Node3D
var gizmo_mount: Node3D

var _camera: Camera3D
var _fluid: MeshInstance3D
var _fluid_material: StandardMaterial3D
var _bubble_material: StandardMaterial3D
var _slug_material: StandardMaterial3D
var _blue_light: StandardMaterial3D
var _amber_light: StandardMaterial3D
var _race_status: Label3D
var _bubble_nodes: Array[MeshInstance3D] = []
var _bubble_phases := PackedFloat32Array()
var _bubble_angles := PackedFloat32Array()
var _bubble_radii := PackedFloat32Array()
var _bubble_speeds := PackedFloat32Array()
var _bubble_sizes := PackedFloat32Array()
var _slugs: Array[MeshInstance3D] = []
var _streams: Array[MeshInstance3D] = []
var _confetti: Array[MeshInstance3D] = []
var _confetti_motion := PackedVector3Array()
var _pressure_lights: Array[MeshInstance3D] = []
var _pressure_on: StandardMaterial3D
var _pressure_off: StandardMaterial3D
var _rng := RandomNumberGenerator.new()

var _olly_target := 0.0
var _gizmo_target := 0.0
var _elapsed := 0.0
var _flow_clock := 0.0
var _orbit_now := 0.02
var _orbit_target := 0.02
var _shake := 0.0
var _flow := 0.0
var _gas := 0.0
var _pressure := 3200.0
var _lit_pressure_segments := -1
var _regime := "single_phase"
var _winner := ""
var _celebration_time := 0.0


func _ready() -> void:
	_rng.seed = 5926047
	_build_environment()
	_build_laboratory()
	_build_tube()
	_build_fluid_motion()
	_build_mounts()
	_build_camera()


func update_race(
		olly_progress: float, gizmo_progress: float, gas_visible: bool, regime: String,
		intensity: float, gas_fraction: float, pressure: float
) -> void:
	_olly_target = clampf(olly_progress, 0.0, 1.0)
	_gizmo_target = clampf(gizmo_progress, 0.0, 1.0)
	_flow = clampf(intensity, 0.0, 1.0)
	_gas = clampf(gas_fraction, 0.0, 1.0)
	_pressure = pressure
	if regime != _regime:
		_regime = regime
		if _winner.is_empty():
			_set_regime_display()
	gizmo_mount.visible = gas_visible
	if _olly_target == 0.0 and _gizmo_target == 0.0:
		if not _winner.is_empty():
			_winner = ""
			_celebration_time = 0.0
			for piece in _confetti:
				piece.hide()
			_set_regime_display()
		olly_mount.position.y = START_HEIGHT
		gizmo_mount.position.y = START_HEIGHT


func orbit(direction: float) -> void:
	_orbit_target = clampf(_orbit_target + direction * 0.17, -0.44, 0.44)


func reset_camera() -> void:
	_orbit_target = 0.02


func shake(strength: float = 0.22) -> void:
	_shake = maxf(_shake, strength)


func celebrate(winner: String) -> void:
	_winner = winner
	_celebration_time = 3.0
	var gizmo_wins := winner == "gizmo"
	_race_status.text = "GIZMO WINS" if gizmo_wins else "OLLY WINS"
	_race_status.modulate = Color("#82e8ff") if gizmo_wins else Color("#ffce88")
	for index in range(_confetti.size()):
		var piece := _confetti[index]
		piece.position = Vector3(_rng.randf_range(-1.2, 1.2), 11.75, _rng.randf_range(-0.6, 0.6))
		piece.rotation = Vector3(_rng.randf(), _rng.randf(), _rng.randf())
		_confetti_motion[index] = Vector3(
			_rng.randf_range(-2.7, 2.7), _rng.randf_range(0.2, 3.0), _rng.randf_range(-2.2, 2.2)
		)
		piece.show()


func _process(delta: float) -> void:
	_elapsed += delta
	_flow_clock += delta * lerpf(0.13, 1.25, _flow)
	_shake = move_toward(_shake, 0.0, delta * 0.6)
	_orbit_now = lerpf(_orbit_now, _orbit_target, 1.0 - exp(-delta * 7.0))
	_move_camera()
	_animate_mount(olly_mount, _olly_target, -0.70, delta, 0.0)
	_animate_mount(gizmo_mount, _gizmo_target, 0.73, delta, 1.4)
	var gas_size := lerpf(1.02, 1.34, _gas)
	gizmo_mount.scale = gizmo_mount.scale.lerp(Vector3.ONE * gas_size, 1.0 - exp(-delta * 4.5))
	_animate_fluids()
	_animate_confetti(delta)
	_animate_pressure_lights()


func _animate_mount(mount: Node3D, progress: float, lane: float, delta: float, phase: float) -> void:
	var lean := sin(_flow_clock * 4.2 + phase)
	var y := lerpf(START_HEIGHT, FINISH_HEIGHT, progress)
	var bob := sin(_elapsed * lerpf(1.8, 4.7, _flow) + phase) * (0.045 + _gas * 0.1)
	mount.position.y = lerpf(mount.position.y, y + bob, 1.0 - exp(-delta * 12.0))
	mount.position.x = lane + lean * (0.025 + _gas * 0.09)
	mount.rotation.z = lean * (0.035 + _gas * 0.12)


func _animate_fluids() -> void:
	var bubble_flow := _regime == "bubble_flow"
	var slug_flow := _regime == "slug_flow"
	var fraction := clampf(_gas * 1.25, 0.0, 1.0)
	var bubble_limit := int(lerpf(12.0, BUBBLE_COUNT, fraction))
	var fluid_color := Color("#e39443")
	if bubble_flow:
		fluid_color = Color("#cd9655")
	elif slug_flow:
		fluid_color = Color("#7e9bb4")
	fluid_color.a = 0.075 + _flow * 0.045
	_fluid_material.albedo_color = fluid_color
	for index in range(_bubble_nodes.size()):
		var bubble := _bubble_nodes[index]
		bubble.visible = (bubble_flow and index < bubble_limit) or (slug_flow and index < bubble_limit / 2)
		if not bubble.visible:
			continue
		var phase := fposmod(_bubble_phases[index] + _flow_clock * _bubble_speeds[index], 1.0)
		var angle := _bubble_angles[index] + sin(phase * TAU * 1.8) * 0.35
		var radius := _bubble_radii[index]
		var s := _bubble_sizes[index] * lerpf(0.66, 1.6, fraction) * lerpf(0.7, 1.12, phase)
		bubble.position = Vector3(cos(angle) * radius, lerpf(1.12, 11.3, phase), sin(angle) * radius)
		bubble.scale = Vector3(s, s * 1.12, s)
	for index in range(_slugs.size()):
		var slug := _slugs[index]
		slug.visible = slug_flow
		if not slug_flow:
			continue
		var phase := fposmod(_flow_clock * 0.175 + float(index) / _slugs.size(), 1.0)
		var soft_end := smoothstep(0.02, 0.15, phase) * (1.0 - smoothstep(0.85, 0.98, phase))
		slug.position = Vector3(0.02, lerpf(0.85, 11.6, phase), -0.32)
		slug.scale = Vector3(0.74 + fraction * 0.30, (0.36 + fraction * 0.39) * soft_end + 0.02, 0.72)
	for index in range(_streams.size()):
		var stream := _streams[index]
		var phase := fposmod(_flow_clock * (0.14 + (index % 3) * 0.043) + index * 0.252, 1.0)
		stream.position.y = lerpf(1.0, 11.45, phase)
		stream.scale.y = (0.55 + _flow * 1.1) * (0.3 + 0.7 * sin(phase * PI))


func _animate_pressure_lights() -> void:
	var lit := clampi(roundi(inverse_lerp(700.0, 3300.0, _pressure) * _pressure_lights.size()), 0, _pressure_lights.size())
	if lit != _lit_pressure_segments:
		_lit_pressure_segments = lit
		for index in range(_pressure_lights.size()):
			_pressure_lights[index].material_override = _pressure_on if index < lit else _pressure_off


func _animate_confetti(delta: float) -> void:
	if _celebration_time <= 0.0:
		return
	_celebration_time -= delta
	for index in range(_confetti.size()):
		var piece := _confetti[index]
		_confetti_motion[index].y -= delta * 4.4
		piece.position += _confetti_motion[index] * delta
		piece.rotate_x(delta * (2.0 + index % 5))
		piece.rotate_z(delta * (1.0 + index % 7))
		piece.visible = _celebration_time > 0.0 and piece.position.y > 0.5


func _set_regime_display() -> void:
	match _regime:
		"bubble_flow":
			_race_status.text = "BUBBLE FLOW"
			_race_status.modulate = Color("#a2edfc")
		"slug_flow":
			_race_status.text = "SLUG FLOW"
			_race_status.modulate = Color("#c7c1ff")
		_:
			_race_status.text = "SINGLE-PHASE FLOW"
			_race_status.modulate = Color("#efbf84")


func _build_camera() -> void:
	_camera = Camera3D.new()
	_camera.name = "LaboratoryCamera"
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.size = 18.0
	_camera.near = 0.2
	_camera.far = 70.0
	add_child(_camera)
	_camera.make_current()
	_move_camera()


func _move_camera() -> void:
	var distance := 21.0
	var shift_x := sin(_elapsed * 88.0) * _shake
	var shift_y := cos(_elapsed * 71.0) * _shake * 0.58
	_camera.position = Vector3(sin(_orbit_now) * distance + shift_x, CAMERA_HEIGHT + shift_y, cos(_orbit_now) * distance)
	_camera.look_at(CAMERA_TARGET + Vector3(shift_x * 0.5, shift_y * 0.4, 0.0))


func _build_environment() -> void:
	var world := WorldEnvironment.new()
	var atmosphere := Environment.new()
	atmosphere.background_mode = Environment.BG_COLOR
	atmosphere.background_color = Color("#07101e")
	atmosphere.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	atmosphere.ambient_light_color = Color("#899ec1")
	atmosphere.ambient_light_energy = 0.59
	world.environment = atmosphere
	add_child(world)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-36.0, -32.0, 8.0)
	key.light_color = Color("#d7eaff")
	key.light_energy = 1.3
	key.shadow_enabled = true
	key.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	key.shadow_opacity = 0.31
	add_child(key)
	_add_fill(Vector3(-4.2, 6.1, 4.1), Color("#ffc985"), 4.0, 10.0)
	_add_fill(Vector3(4.6, 7.5, 3.8), Color("#61bdff"), 4.5, 11.5)
	_add_fill(Vector3(0.0, 9.5, -2.9), Color("#43e6ff"), 2.4, 9.0)


func _build_laboratory() -> void:
	var floor := _material(Color("#172a41"), 0.47, 0.52)
	var wall := _material(Color("#111d2e"), 0.32, 0.80)
	var structure := _material(Color("#212f42"), 0.61, 0.58)
	var dark := _material(Color("#101828"), 0.4, 0.64)
	var seam := _material(Color("#253a51"), 0.4, 0.72)
	var pin := _material(Color("#4a6282"), 0.55, 0.43)
	_blue_light = _luminous(Color("#57e0f3"))
	_amber_light = _luminous(Color("#ffc176"))
	var dim_blue := _luminous(Color("#2c6c86"))
	var dim_amber := _luminous(Color("#83552f"))
	_box(Vector3(34.0, 0.35, 24.0), Vector3(0.0, -0.32, -1.5), floor)
	_box(Vector3(42.0, 16.0, 0.4), Vector3(0.0, 7.0, -6.8), wall)
	_box(Vector3(40.0, 0.75, 0.62), Vector3(0.0, 12.15, -6.42), structure)
	_box(Vector3(40.0, 0.08, 0.05), Vector3(0.0, 11.85, -6.07), dim_blue)
	_box(Vector3(40.0, 0.05, 0.05), Vector3(0.0, 2.45, -6.4), seam)
	_box(Vector3(40.0, 0.03, 0.05), Vector3(0.0, 9.92, -6.4), seam)
	for i in range(-14, 15):
		var x := float(i) * 1.27
		_box(Vector3(0.025, 0.018, 23.0), Vector3(x, -0.139, -1.5), seam)
	for i in range(-7, 7):
		var z := float(i) * 1.55
		_box(Vector3(35.0, 0.019, 0.025), Vector3(0.0, -0.137, z), seam)
	for side in [-1.0, 1.0]:
		var sign_x := float(side)
		_box(Vector3(1.1, 12.5, 0.7), Vector3(sign_x * 5.85, 5.9, -6.2), dark)
		_box(Vector3(0.27, 12.0, 0.54), Vector3(sign_x * 5.52, 5.85, -5.8), pin)
		_box(Vector3(0.095, 8.8, 0.06), Vector3(sign_x * 5.52, 6.1, -5.51), dim_blue)
		_box(Vector3(1.4, 0.15, 0.15), Vector3(sign_x * 5.85, 10.9, -5.81), dim_blue)
		_box(Vector3(4.9, 3.55, 0.34), Vector3(sign_x * 8.2, 1.9, -6.1), structure)
		for k in range(5):
			_box(Vector3(3.7, 0.075, 0.08), Vector3(sign_x * 8.2, 1.02 + k * 0.29, -5.88), seam)
		_box(Vector3(6.0, 0.055, 0.13), Vector3(sign_x * 6.56, -0.125, 1.18), dim_blue)
		_box(Vector3(6.0, 0.055, 0.13), Vector3(sign_x * 6.56, -0.124, -1.18), dim_amber)
		_box(Vector3(0.72, 0.18, 7.6), Vector3(sign_x * 5.95, -0.093, -1.0), dark)
		for k in range(15):
			var stripe := _box(Vector3(0.55, 0.013, 0.09), Vector3(sign_x * 5.95, 0.001, -4.59 + k * 0.48), dim_amber)
			stripe.rotation.y = sign_x * 0.46
	_build_catwalk(structure, seam, dim_blue, dark)


func _build_catwalk(
		structure: StandardMaterial3D, rail: StandardMaterial3D, light: StandardMaterial3D,
		dark: StandardMaterial3D
) -> void:
	_box(Vector3(26.0, 0.35, 3.2), Vector3(0.0, 9.9, -4.9), structure)
	_box(Vector3(26.0, 0.11, 0.11), Vector3(0.0, 10.01, -3.28), light)
	for side in [-1.0, 1.0]:
		var sign_x := float(side)
		_box(Vector3(9.3, 0.09, 0.1), Vector3(sign_x * 7.19, 10.93, -3.34), rail)
		_box(Vector3(9.3, 0.045, 0.06), Vector3(sign_x * 7.19, 10.55, -3.34), rail)
		for k in range(8):
			var x := sign_x * (2.53 + k * 1.26)
			_box(Vector3(0.085, 0.98, 0.085), Vector3(x, 10.43, -3.34), structure)
			var brace := _box(Vector3(0.22, 1.5, 0.19), Vector3(x, 9.16, -3.64), dark)
			brace.rotation.x = -0.47


func _build_tube() -> void:
	var steel := _material(Color("#526278"), 0.55, 0.46)
	var plate := _material(Color("#26354c"), 0.64, 0.45)
	var dark := _material(Color("#1b273b"), 0.53, 0.58)
	var bolt := _material(Color("#8295a0"), 0.47, 0.39)
	var brass := _material(Color("#ae8255"), 0.47, 0.40)
	var platform := _cylinder(2.66, 0.38, Vector3(0.0, 0.10, 0.0), dark)
	platform.name = "PressureVesselPlinth"
	_cylinder(2.44, 0.33, Vector3(0.0, 0.35, 0.0), plate)
	_cylinder(2.17, 0.34, Vector3(0.0, 0.60, 0.0), steel)
	_ring(2.43, 0.047, 0.36, _blue_light)
	_ring(2.12, 0.035, 0.76, brass)
	_cylinder(2.14, 0.36, Vector3(0.0, 11.53, 0.0), steel)
	_cylinder(1.94, 0.28, Vector3(0.0, 11.81, 0.0), plate)
	_cylinder(1.46, 0.21, Vector3(0.0, 12.02, 0.0), dark)
	_ring(2.16, 0.04, 11.52, _blue_light)
	_ring(1.45, 0.031, 12.12, _amber_light)
	for y in [0.65, 11.58]:
		for index in range(16):
			var angle := float(index) * TAU / 16.0
			var screw := _cylinder(0.072, 0.09, Vector3(cos(angle) * 1.93, float(y) + 0.155, sin(angle) * 1.93), bolt, 6)
			screw.rotation.y = angle
	for y in [3.03, 5.49, 7.95, 10.41]:
		_ring(TUBE_RADIUS + 0.017, 0.023, float(y), plate)
		_ring(TUBE_RADIUS + 0.044, 0.011, float(y) + 0.034, _luminous(Color("#346778")))
	for side in [-1.0, 1.0]:
		var sign_x := float(side)
		_cylinder(0.11, 10.8, Vector3(sign_x * 1.82, 6.13, -0.74), plate)
		_cylinder(0.022, 10.18, Vector3(sign_x * 1.83, 6.18, -0.625), _blue_light)
		_cylinder(0.19, 0.38, Vector3(sign_x * 1.82, 11.37, -0.74), bolt)
		_cylinder(0.19, 0.38, Vector3(sign_x * 1.82, 0.9, -0.74), bolt)

	var glass := _cylinder(
		TUBE_RADIUS, TUBE_TOP - TUBE_BASE, Vector3(0.0, (TUBE_TOP + TUBE_BASE) * 0.5, 0.0),
		_glass_material(), 96, false
	)
	glass.name = "TransparentPressureVessel"
	glass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	_fluid_material = _material(Color("#e39443"), 0.0, 0.4)
	_fluid_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_fluid_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_fluid_material.render_priority = -2
	_fluid = _cylinder(1.69, 10.61, Vector3(0.0, 6.18, 0.0), _fluid_material, 80, false)
	_fluid.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_box(Vector3(2.2, 0.27, 0.12), Vector3(0.0, 0.37, 2.51), dark)
	_race_status = _label("SINGLE-PHASE FLOW", Vector3(0.0, 0.37, 2.582), Color("#efbf84"), 0.008)
	_race_status.outline_size = 5
	_label("OUTLET", Vector3(0.0, 11.69, 2.23), Color("#edf8ff"), 0.007)
	_build_tube_gauges(steel, plate)
	_build_feeds(steel, brass, plate, dark)


func _build_tube_gauges(steel: StandardMaterial3D, plate: StandardMaterial3D) -> void:
	var marker_x := 2.01
	_box(Vector3(0.07, 9.7, 0.1), Vector3(marker_x, 6.13, 0.52), steel)
	var start := 1.35
	var end := 10.87
	for index in range(21):
		var t := float(index) / 20.0
		var major := index % 5 == 0
		var width := 0.29 if major else 0.13
		var y := lerpf(start, end, t)
		_box(Vector3(width, 0.025, 0.057), Vector3(marker_x + width * 0.52, y, 0.59), _blue_light if major else plate)
		if major:
			_label("%d m" % roundi(2400.0 * (1.0 - t)), Vector3(marker_x + 0.74, y, 0.66), Color("#afcfe0"), 0.0059)
	_box(Vector3(0.32, 1.98, 0.28), Vector3(-2.06, 2.08, 0.6), plate)
	_pressure_on = _luminous(Color("#ffb574"))
	_pressure_off = _luminous(Color("#433943"))
	for index in range(9):
		_pressure_lights.append(
			_box(Vector3(0.19, 0.12, 0.046), Vector3(-2.06, 1.29 + index * 0.195, 0.767), _pressure_off)
		)
	_label("PSI", Vector3(-2.06, 3.18, 0.77), Color("#ffc78e"), 0.006)


func _build_feeds(
		steel: StandardMaterial3D, brass: StandardMaterial3D, plate: StandardMaterial3D,
		dark: StandardMaterial3D
) -> void:
	for side in [-1.0, 1.0]:
		var sign_x := float(side)
		var feed := _cylinder(0.29, 3.43, Vector3(sign_x * 3.32, 0.37, 0.0), steel)
		feed.rotation.z = PI / 2.0
		_cylinder(0.4, 0.62, Vector3(sign_x * 4.95, 0.3, 0.0), plate)
		_cylinder(0.58, 0.14, Vector3(sign_x * 4.95, 0.055, 0.0), dark)
		for index in range(4):
			var x := sign_x * (2.53 + index * 0.58)
			var clamp_collar := _cylinder(0.36, 0.13, Vector3(x, 0.37, 0.0), brass)
			clamp_collar.rotation.z = PI / 2.0
		var connector := _cylinder(0.21, 2.36, Vector3(sign_x * 2.77, 11.76, -0.56), steel)
		connector.rotation.z = PI / 2.0
		_cylinder(0.31, 0.53, Vector3(sign_x * 3.93, 11.67, -0.56), plate)
		var down := _cylinder(0.16, 2.48, Vector3(sign_x * 3.93, 10.23, -0.56), steel)
		down.name = "OutletSupport"


func _build_fluid_motion() -> void:
	_bubble_material = _material(Color(0.36, 0.79, 0.95, 0.66), 0.12, 0.37)
	_bubble_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_bubble_material.emission_enabled = true
	_bubble_material.emission = Color("#2586a6")
	_bubble_material.emission_energy_multiplier = 0.23
	_bubble_material.render_priority = -1
	var bubble_mesh := SphereMesh.new()
	bubble_mesh.radial_segments = 14
	bubble_mesh.rings = 8
	bubble_mesh.radius = 1.0
	bubble_mesh.height = 2.0
	for index in range(BUBBLE_COUNT):
		var bubble := _put_mesh(bubble_mesh, Vector3.ZERO, _bubble_material)
		bubble.visible = false
		bubble.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_bubble_nodes.append(bubble)
		_bubble_phases.append(_rng.randf())
		_bubble_angles.append(_rng.randf_range(0.0, TAU))
		_bubble_speeds.append(_rng.randf_range(0.045, 0.19))
		_bubble_radii.append(_rng.randf_range(0.72, 1.52))
		_bubble_sizes.append(_rng.randf_range(0.036, 0.127))

	_slug_material = _material(Color(0.43, 0.70, 0.95, 0.20), 0.06, 0.25)
	_slug_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_slug_material.render_priority = -1
	_slug_material.emission_enabled = true
	_slug_material.emission = Color("#416e9c")
	_slug_material.emission_energy_multiplier = 0.35
	var pocket := CapsuleMesh.new()
	pocket.radius = 1.18
	pocket.height = 4.42
	pocket.radial_segments = 38
	pocket.rings = 16
	for index in range(3):
		var slug := _put_mesh(pocket, Vector3.ZERO, _slug_material)
		slug.visible = false
		slug.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_slugs.append(slug)

	var streak_material := _material(Color(1.0, 0.64, 0.26, 0.26), 0.0, 0.7)
	streak_material.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	streak_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	streak_material.render_priority = -1
	for index in range(24):
		var angle := _rng.randf_range(0.0, TAU)
		var radius := _rng.randf_range(1.17, 1.59)
		var width := _rng.randf_range(0.017, 0.044)
		var stream := _box(
			Vector3(width, _rng.randf_range(0.12, 0.51), width),
			Vector3(cos(angle) * radius, 1.0, sin(angle) * radius), streak_material
		)
		stream.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_streams.append(stream)
	var confetti_materials := [_blue_light, _amber_light, _luminous(Color("#fff2d8")), _luminous(Color("#9987ed"))]
	for index in range(45):
		var piece := _box(Vector3(0.08, 0.2, 0.026), Vector3.ZERO, confetti_materials[index % confetti_materials.size()])
		piece.hide()
		piece.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_confetti.append(piece)
		_confetti_motion.append(Vector3.ZERO)


func _build_mounts() -> void:
	olly_mount = Node3D.new()
	olly_mount.name = "OllyMount"
	olly_mount.position = Vector3(-0.70, START_HEIGHT, 0.1)
	add_child(olly_mount)
	gizmo_mount = Node3D.new()
	gizmo_mount.name = "GizmoMount"
	gizmo_mount.position = Vector3(0.73, START_HEIGHT, 0.1)
	gizmo_mount.hide()
	add_child(gizmo_mount)


func _glass_material() -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, shadows_disabled, cull_back;

varying vec3 cylinder_position;

void vertex() {
	cylinder_position = VERTEX;
}

void fragment() {
	float normal_view = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float rim = pow(1.0 - normal_view, 2.4);
	float radial_side = abs(normalize(cylinder_position.xz).x);
	float stripe = (smoothstep(0.79, 0.82, radial_side) - smoothstep(0.855, 0.91, radial_side)) * 0.105;
	float fine_reflection = (sin(cylinder_position.y * 1.9 + 0.5) * 0.5 + 0.5) * 0.014;
	ALBEDO = mix(vec3(0.29, 0.58, 0.73), vec3(0.53, 0.88, 0.96), rim);
	ALPHA = clamp(0.034 + rim * 0.29 + stripe + fine_reflection, 0.0, 0.48);
}
"""
	var result := ShaderMaterial.new()
	result.shader = shader
	result.render_priority = 1
	return result


func _material(color: Color, metallic: float, roughness: float) -> StandardMaterial3D:
	var result := StandardMaterial3D.new()
	result.albedo_color = color
	result.metallic = metallic
	result.roughness = roughness
	return result


func _luminous(color: Color) -> StandardMaterial3D:
	var result := _material(color, 0.0, 1.0)
	result.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	return result


func _put_mesh(geometry: Mesh, at: Vector3, material: Material) -> MeshInstance3D:
	var item := MeshInstance3D.new()
	item.mesh = geometry
	item.position = at
	item.material_override = material
	add_child(item)
	return item


func _box(size: Vector3, at: Vector3, material: Material) -> MeshInstance3D:
	var geometry := BoxMesh.new()
	geometry.size = size
	var item := _put_mesh(geometry, at, material)
	if minf(size.x, minf(size.y, size.z)) <= 0.10:
		item.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return item


func _cylinder(
		radius: float, height: float, at: Vector3, material: Material, sides: int = 48,
		capped: bool = true
) -> MeshInstance3D:
	var geometry := CylinderMesh.new()
	geometry.top_radius = radius
	geometry.bottom_radius = radius
	geometry.height = height
	geometry.radial_segments = sides
	geometry.rings = 1
	geometry.cap_top = capped
	geometry.cap_bottom = capped
	return _put_mesh(geometry, at, material)


func _ring(radius: float, thickness: float, y: float, material: Material) -> void:
	var geometry := TorusMesh.new()
	geometry.inner_radius = radius - thickness
	geometry.outer_radius = radius + thickness
	geometry.rings = 64
	geometry.ring_segments = 9
	var item := _put_mesh(geometry, Vector3(0.0, y, 0.0), material)
	item.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _label(content: String, at: Vector3, color: Color, unit_size: float) -> Label3D:
	var label := Label3D.new()
	label.text = content
	label.modulate = color
	label.outline_modulate = Color("#121b2a")
	label.outline_size = 4
	label.font_size = 41
	label.pixel_size = unit_size
	label.position = at
	add_child(label)
	return label


func _add_fill(at: Vector3, color: Color, energy: float, reach: float) -> void:
	var light := OmniLight3D.new()
	light.position = at
	light.light_color = color
	light.light_energy = energy
	light.omni_range = reach
	light.omni_attenuation = 1.2
	add_child(light)
