extends Node3D
## Procedural cartoon character with an articulated face and a springy swim cycle.

@export_enum("olly", "gizmo") var speaker := "olly"

const EXPRESSIONS := {
	"neutral":       Vector4(1.00,  0.00, 0.03, 1.00),
	"excited":       Vector4(1.18,  0.03, 0.30, 1.15),
	"happy":         Vector4(0.88,  0.04, 0.17, 1.19),
	"surprised":     Vector4(1.28,  0.07, 0.44, 0.70),
	"afraid":        Vector4(1.17,  0.06, 0.33, 0.78),
	"competitive":   Vector4(0.86, -0.02, 0.10, 1.04),
	"laughing":      Vector4(0.66,  0.03, 0.52, 1.25),
	"celebrating":   Vector4(1.15,  0.07, 0.45, 1.15),
	"frustrated":    Vector4(0.72, -0.05, 0.11, 0.86),
	"confident":     Vector4(0.90,  0.01, 0.08, 1.12),
	"playful":       Vector4(1.04,  0.03, 0.15, 1.10),
}
const BROWS := {
	"neutral": 0.06, "excited": 0.16, "happy": 0.12, "surprised": 0.08,
	"afraid": 0.29, "competitive": -0.29, "laughing": 0.23,
	"celebrating": 0.17, "frustrated": -0.42, "confident": -0.14, "playful": 0.17,
}

var _visual: Node3D
var _eyes: Array[Node3D] = []
var _brows: Array[Node3D] = []
var _pupils: Array[Node3D] = []
var _hands: Array[Node3D] = []
var _bubblelets: Array[Node3D] = []
var _mouth: Node3D
var _smile: MeshInstance3D
var _tongue: MeshInstance3D
var _teeth: MeshInstance3D
var _sphere: SphereMesh
var _gizmo := false
var _target_mouth := 0.0
var _openness := 0.0
var _expression := Vector4(1.0, 0.0, 0.03, 1.0)
var _target_expression := _expression
var _brow_tilt := 0.06
var _target_brow_tilt := 0.06
var _target_smile_rotation := 0.0
var _speed := 0.0
var _target_speed := 0.0
var _lean := 0.0
var _direction := 0.0
var _hop_time := 1.0
var _hop_strength := 0.0
var _time := 0.0
var _blink_clock := 2.0
var _blink_phase := -1.0
var _eyes_height := 0.12


func _ready() -> void:
	_gizmo = speaker == "gizmo"
	_blink_clock = 2.7 if _gizmo else 1.9
	_sphere = SphereMesh.new()
	_sphere.radius = 1.0
	_sphere.height = 2.0
	_sphere.radial_segments = 28
	_sphere.rings = 14
	_visual = Node3D.new()
	add_child(_visual)
	_eyes_height = 0.10 if _gizmo else 0.02
	if _gizmo:
		_build_bubble()
	else:
		_build_drop()
	_build_face()


func set_mouth(openness: float) -> void:
	_target_mouth = clampf(openness, 0.0, 1.0)


func set_emotion(emotion: String) -> void:
	_target_expression = EXPRESSIONS.get(emotion, EXPRESSIONS["neutral"])
	_target_brow_tilt = BROWS.get(emotion, BROWS["neutral"])
	_target_smile_rotation = PI if emotion == "frustrated" else 0.0


func set_motion(intensity: float, direction: float = 0.0) -> void:
	_target_speed = clampf(intensity, 0.0, 1.0)
	_direction = clampf(direction, -1.0, 1.0)


func hop(strength: float = 1.0) -> void:
	_hop_time = 0.0
	_hop_strength = clampf(strength, 0.0, 1.0)


func _process(delta: float) -> void:
	_time += delta
	_hop_time = minf(1.0, _hop_time + delta * 2.65)
	_speed = lerpf(_speed, _target_speed, 1.0 - exp(-5.0 * delta))
	_lean = lerpf(_lean, _direction, 1.0 - exp(-7.0 * delta))
	_openness = lerpf(_openness, _target_mouth, 1.0 - exp(-26.0 * delta))
	var pose_blend := 1.0 - exp(-12.0 * delta)
	_expression = _expression.lerp(_target_expression, pose_blend)
	_brow_tilt = lerpf(_brow_tilt, _target_brow_tilt, pose_blend)
	var blink := _blink_amount(delta)
	var phase := _time * (4.6 if _gizmo else 3.5) + (1.1 if _gizmo else 0.0)
	var flutter := sin(phase)
	var bounce := sin(_hop_time * PI) * _hop_strength
	_visual.position.y = flutter * (0.046 + _speed * 0.027) + bounce * 0.32
	_visual.rotation.z = sin(phase * 0.55) * 0.06 - _lean * _speed * 0.16
	_visual.rotation.y = sin(phase * 0.36) * 0.10 + _lean * 0.24
	_visual.scale = Vector3(1.0 + flutter * 0.012, 1.0 - flutter * 0.028 + bounce * 0.13, 1.0)
	for index in range(_eyes.size()):
		var sign_x := -1.0 if index == 0 else 1.0
		_eyes[index].scale.y = maxf(0.10, (1.0 - blink * 0.91) * _expression.x)
		_brows[index].position.y = _eyes_height + 0.22 + _expression.y + sign_x * _lean * 0.009
		_brows[index].rotation.z = sign_x * _brow_tilt
		_pupils[index].position.x = _lean * 0.037 + sin(phase * 0.28) * 0.018
		_pupils[index].position.y = 0.006 + _speed * 0.011 + bounce * 0.020
		_hands[index].rotation.z = sign_x * (flutter * (0.12 + _speed * 0.12) + bounce * 0.65)
	_mouth.scale.x = _expression.w * (1.0 - _openness * 0.10)
	_mouth.scale.y = maxf(_expression.z, _openness * 0.95) + 0.20
	_mouth.visible = _mouth.scale.y > 0.33
	_smile.visible = not _mouth.visible
	_smile.rotation.z = lerpf(_smile.rotation.z, _target_smile_rotation, pose_blend)
	_tongue.visible = _mouth.scale.y > 0.46
	_teeth.visible = _mouth.scale.y > 0.52
	for index in range(_bubblelets.size()):
		var bubbles_phase := _time * (1.8 + index * 0.38) + index * 1.8
		var side := -1.0 if index == 0 else 1.0
		_bubblelets[index].position = Vector3(
			side * (0.53 + index * 0.027 + sin(bubbles_phase) * 0.055),
			0.24 + index * 0.13 + cos(bubbles_phase) * 0.090, -0.07
		)


func _blink_amount(delta: float) -> float:
	if _blink_phase < 0.0:
		_blink_clock -= delta
		if _blink_clock > 0.0:
			return 0.0
		_blink_phase = 0.0
	_blink_phase += delta * 6.0
	if _blink_phase >= 1.0:
		_blink_phase = -1.0
		_blink_clock = 2.4 + (sin(_time * 1.78) + 1.0) * 0.65
		return 0.0
	return sin(_blink_phase * PI)


func _build_drop() -> void:
	var body_material := _surface(Color(1.0, 0.77, 0.36), 0.23, 0.08, 0.25)
	body_material.vertex_color_use_as_albedo = true
	_mesh(_visual, _drop_mesh(), Vector3.ZERO, Vector3.ONE, body_material)
	var glint := _surface(Color(1.0, 0.79, 0.42), 0.26, 0.0, 0.40)
	var big_glint := _ball(_visual, Vector3(-0.194, 0.32, 0.265), Vector3(0.057, 0.108, 0.032), glint)
	big_glint.rotation.z = deg_to_rad(-26.0)
	_ball(_visual, Vector3(-0.105, 0.455, 0.247), Vector3(0.026, 0.035, 0.021), glint)
	_build_limbs(
		_surface(Color("#b95915"), 0.32, 0.07, 0.10),
		_surface(Color("#ffbe4c"), 0.28, 0.03, 0.24)
	)


func _build_bubble() -> void:
	var shell := _surface(Color(0.19, 0.84, 1.0, 0.35), 0.21, 0.06, 0.32)
	shell.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_ball(_visual, Vector3.ZERO, Vector3(0.54, 0.56, 0.51), shell)
	_ball(
		_visual, Vector3(0.0, -0.022, 0.0), Vector3(0.453, 0.472, 0.417),
		_surface(Color("#176bac"), 0.36, 0.15, 0.55)
	)
	var accent := _surface(Color("#a7f3ff"), 0.23, 0.03, 0.65)
	_mesh(
		_visual,
		_arc_mesh(Vector3(0.0, -0.01, 0.205), Vector2(0.45, 0.45), PI * 0.57, PI * 0.91, 0.017),
		Vector3.ZERO, Vector3.ONE, accent
	)
	_ball(_visual, Vector3(-0.397, 0.181, 0.222), Vector3(0.029, 0.042, 0.026), accent)
	var decoration := _surface(Color("#54dffc"), 0.28, 0.10, 0.58)
	for index in range(3):
		var radius := 0.062 - index * 0.011
		_bubblelets.append(_ball(_visual, Vector3.ZERO, Vector3.ONE * radius, decoration))
	_build_limbs(
		_surface(Color("#207db8"), 0.30, 0.05, 0.25),
		_surface(Color("#76d9f6"), 0.27, 0.03, 0.42)
	)


func _build_limbs(arm_material: StandardMaterial3D, hand_material: StandardMaterial3D) -> void:
	for side in [-1.0, 1.0]:
		var arm := Node3D.new()
		arm.position = Vector3(side * 0.39, -0.155, 0.04)
		_visual.add_child(arm)
		_hands.append(arm)
		var forearm := _ball(arm, Vector3(side * 0.09, -0.035, 0.025), Vector3(0.14, 0.055, 0.052), arm_material)
		forearm.rotation.z = -side * 0.36
		_ball(arm, Vector3(side * 0.20, -0.052, 0.042), Vector3(0.073, 0.069, 0.059), hand_material)
		_ball(arm, Vector3(side * 0.206, 0.009, 0.074), Vector3(0.034, 0.039, 0.038), hand_material)
		if not _gizmo:
			_ball(_visual, Vector3(side * 0.205, -0.477, 0.072), Vector3(0.066, 0.132, 0.067), arm_material)
			var foot := _ball(_visual, Vector3(side * 0.211, -0.555, 0.152), Vector3(0.121, 0.062, 0.134), hand_material)
			foot.rotation.y = side * 0.23


func _build_face() -> void:
	var z_base := 0.427 if _gizmo else 0.388
	var edge_z := z_base + (0.002 if _gizmo else 0.02)
	var white := _surface(Color("#fff6db"), 0.25, 0.00, 0.52)
	var glint := _surface(Color("#fbfeff"), 0.18, 0.0, 0.75)
	var dark_color := Color("#061d33") if _gizmo else Color("#35200e")
	var ink := _surface(dark_color, 0.34, 0.0, 0.35)
	var iris := _surface(Color("#3cb5e6") if _gizmo else Color("#aa591b"), 0.30, 0.0, 0.52)
	var accent := _surface(Color("#80eff8") if _gizmo else Color("#ff9d42"), 0.31, 0.0, 0.52)
	for side in [-1.0, 1.0]:
		var eye := Node3D.new()
		eye.position = Vector3(side * 0.169, _eyes_height, z_base)
		_visual.add_child(eye)
		_eyes.append(eye)
		_ball(eye, Vector3.ZERO, Vector3(0.142, 0.162, 0.070), ink)
		_ball(eye, Vector3(0.0, 0.007, 0.021), Vector3(0.128, 0.151, 0.064), white)
		var pupil := Node3D.new()
		pupil.position = Vector3(0.0, 0.0, 0.074)
		eye.add_child(pupil)
		_pupils.append(pupil)
		_ball(pupil, Vector3.ZERO, Vector3(0.079, 0.096, 0.045), iris)
		_ball(pupil, Vector3(0.003, 0.0, 0.028), Vector3(0.062, 0.077, 0.029), ink)
		_ball(pupil, Vector3(-0.026, 0.034, 0.055), Vector3(0.022, 0.026, 0.015), glint)
		_ball(pupil, Vector3(0.031, -0.021, 0.053), Vector3(0.010, 0.013, 0.010), glint)
		var brow := Node3D.new()
		brow.position = Vector3(side * 0.174, _eyes_height + 0.22, edge_z)
		_visual.add_child(brow)
		_brows.append(brow)
		_mesh(
			brow,
			_arc_mesh(Vector3.ZERO, Vector2(0.107, 0.055), 0.32, PI - 0.32, 0.025),
			Vector3.ZERO, Vector3.ONE, ink
		)
		_ball(_visual, Vector3(side * 0.298, _eyes_height - 0.179, z_base - 0.011), Vector3(0.061, 0.03, 0.028), accent)
	_mouth = Node3D.new()
	_mouth.position = Vector3(0.0, _eyes_height - 0.205, z_base + 0.065)
	_visual.add_child(_mouth)
	_smile = _mesh(
		_visual,
		_arc_mesh(Vector3.ZERO, Vector2(0.158, 0.074), PI * 1.13, PI * 1.87, 0.024),
		_mouth.position + Vector3(0.0, 0.033, 0.052), Vector3.ONE, ink
	)
	_ball(_mouth, Vector3.ZERO, Vector3(0.169, 0.126, 0.047), accent)
	_ball(_mouth, Vector3(0.0, 0.0, 0.026), Vector3(0.150, 0.113, 0.032), ink)
	var tongue_material := _surface(Color("#ff8571") if not _gizmo else Color("#fb8cca"), 0.31, 0.0, 0.40)
	_tongue = _ball(_mouth, Vector3(0.0, -0.056, 0.055), Vector3(0.076, 0.038, 0.015), tongue_material)
	_teeth = _ball(_mouth, Vector3(0.0, 0.073, 0.051), Vector3(0.090, 0.023, 0.013), white)


func _surface(color: Color, roughness: float, metallic: float, emissive: float) -> StandardMaterial3D:
	var material := StandardMaterial3D.new()
	material.albedo_color = color
	material.roughness = roughness
	material.metallic = metallic
	material.emission_enabled = emissive > 0.0
	material.emission = color
	material.emission_energy_multiplier = emissive
	return material


func _ball(parent: Node3D, center: Vector3, extent: Vector3, material: Material) -> MeshInstance3D:
	return _mesh(parent, _sphere, center, extent, material)


func _mesh(parent: Node3D, geometry: Mesh, center: Vector3, extent: Vector3, material: Material) -> MeshInstance3D:
	var part := MeshInstance3D.new()
	part.mesh = geometry
	part.material_override = material
	part.position = center
	part.scale = extent
	part.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(part)
	return part


func _drop_mesh() -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var low := Color("#a84f1a")
	var middle := Color("#f4a630")
	var high := Color("#ffe282")
	var sectors := 44
	var rings := 25
	for row in range(rings + 1):
		var u := float(row) / rings
		var y := lerpf(-0.515, 0.80, u)
		var phi := u * PI
		var radius := maxf(0.001, pow(sin(phi), 0.66) * lerpf(0.74, 0.23, u))
		var offset := pow(u, 2.7) * 0.20
		var color := low.lerp(middle, clampf(u * 2.0, 0.0, 1.0)).lerp(high, clampf(u * 1.9 - 0.9, 0.0, 1.0))
		for sector in range(sectors):
			var theta := float(sector) / sectors * TAU
			surface.set_color(color)
			surface.add_vertex(Vector3(offset + radius * cos(theta), y, radius * sin(theta) * 0.91))
	_add_ring_indices(surface, rings, sectors)
	surface.generate_normals()
	return surface.commit()


func _arc_mesh(center: Vector3, extent: Vector2, from: float, to: float, thickness: float) -> ArrayMesh:
	var surface := SurfaceTool.new()
	surface.begin(Mesh.PRIMITIVE_TRIANGLES)
	var sectors := 8
	var rings := 14
	for row in range(rings + 1):
		var angle := lerpf(from, to, float(row) / rings)
		var outward := Vector3(cos(angle), sin(angle), 0.0)
		var line := center + Vector3(outward.x * extent.x, outward.y * extent.y, 0.0)
		var taper := maxf(0.32, sin(PI * float(row) / rings))
		for sector in range(sectors):
			var theta := float(sector) / sectors * TAU
			var normal := outward * cos(theta) + Vector3.BACK * sin(theta)
			surface.set_normal(normal)
			surface.add_vertex(line + normal * thickness * taper)
	_add_ring_indices(surface, rings, sectors)
	return surface.commit()


func _add_ring_indices(surface: SurfaceTool, rings: int, sectors: int) -> void:
	for row in range(rings):
		for sector in range(sectors):
			var a := row * sectors + sector
			var b := row * sectors + (sector + 1) % sectors
			var c := a + sectors
			var d := b + sectors
			for index in [a, b, c, b, d, c]:
				surface.add_index(index)
