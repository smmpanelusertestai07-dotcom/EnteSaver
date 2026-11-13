class_name AimSpineModifier
extends SkeletonModifier3D
## Bends the spine chain so the upper body (and the rifle) follows the aim pitch.
## Runs after the AnimationTree, on top of whatever locomotion clip is playing.
## twist turns the chest, neck and head about the world's up axis (twist_bones / twist_weights):
## the head looking round (the lobby's idle, a body held still by the free look looking where the
## camera looks), on top of the pitch.

var bones: PackedInt32Array = []
var weights: PackedFloat32Array = []
var pitch := 0.0
var pitch_scale := 1.0     # less bend when prone (the body already lies on the ground)
var kick := 0.0
var axis_world := Vector3.RIGHT
var twist := 0.0           # radians about the world's up axis (+ = to the character's left)
var twist_bones: PackedInt32Array = []
var twist_weights: PackedFloat32Array = []


func _process_modification_with_delta(_delta: float) -> void:
	var skel := get_skeleton()
	if skel == null or bones.is_empty():
		return
	var total := pitch * pitch_scale + kick
	if absf(total) >= 0.0001:
		_turn(skel, bones, weights, axis_world, total)
	if absf(twist) >= 0.0001 and not twist_bones.is_empty():
		_turn(skel, twist_bones, twist_weights, Vector3.UP, twist)


## Turns each bone by angle x its weight about axis (world), in parent-first order.
func _turn(skel: Skeleton3D, chain: PackedInt32Array, w: PackedFloat32Array, axis: Vector3, angle: float) -> void:
	var axis_skel := (skel.global_basis.inverse() * axis).normalized()
	for i in chain.size():
		var b := chain[i]
		var parent := skel.get_bone_parent(b)
		var parent_basis := Basis.IDENTITY
		if parent >= 0:
			parent_basis = skel.get_bone_global_pose(parent).basis
		var axis_parent := (parent_basis.inverse() * axis_skel).normalized()
		if not axis_parent.is_normalized():
			continue
		var local_q := skel.get_bone_pose_rotation(b)
		var q := Quaternion(axis_parent, angle * w[i]) * local_q
		skel.set_bone_pose_rotation(b, q.normalized())
