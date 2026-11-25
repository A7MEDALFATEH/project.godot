extends Node
## Attach to a rig and assign its existing mouth and optional facial pose animations.

@export var dialogue_manager: Node
@export_enum("olly", "gizmo") var speaker := "olly"
@export var mouth_mesh: MeshInstance3D
@export var mouth_blend_shape: StringName = &"MouthOpen"
@export var mouth_node: Node3D
@export var open_mouth_scale_multiplier := Vector3(1.0, 2.3, 1.0)
@export var face_animations: AnimationPlayer
@export var emotion_animations: Dictionary = {}

var _mouth_shape_index := -1
var _closed_mouth_scale := Vector3.ONE


func _ready() -> void:
	if mouth_mesh != null and mouth_mesh.mesh != null and not mouth_blend_shape.is_empty():
		_mouth_shape_index = mouth_mesh.find_blend_shape_by_name(mouth_blend_shape)
		if _mouth_shape_index < 0:
			push_warning("Mouth blend shape '%s' is missing on %s" % [mouth_blend_shape, mouth_mesh.name])
	if mouth_node != null:
		_closed_mouth_scale = mouth_node.scale
	if dialogue_manager == null or not dialogue_manager.has_signal("mouth_changed"):
		push_warning("Assign the scene's dialogue manager to %s" % name)
		return
	dialogue_manager.connect("mouth_changed", _apply_mouth)
	dialogue_manager.connect("emotion_changed", _apply_emotion)


func _apply_mouth(active_speaker: String, openness: float) -> void:
	if active_speaker != speaker:
		return
	if _mouth_shape_index >= 0 and is_instance_valid(mouth_mesh):
		mouth_mesh.set_blend_shape_value(_mouth_shape_index, openness)
	elif is_instance_valid(mouth_node):
		var open_scale := _closed_mouth_scale * open_mouth_scale_multiplier
		mouth_node.scale = _closed_mouth_scale.lerp(open_scale, openness)


func _apply_emotion(active_speaker: String, emotion: String) -> void:
	if active_speaker != speaker or not is_instance_valid(face_animations):
		return
	var animation: StringName = StringName(emotion_animations.get(emotion, emotion))
	if face_animations.has_animation(animation):
		face_animations.play(animation, 0.12)
