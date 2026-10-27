class_name AimSpineModifier
extends SkeletonModifier3D
## Bends the spine chain so the upper body (and the rifle) follows the aim pitch.
## Runs after the AnimationTree, on top of whatever locomotion clip is playing.

var bones: PackedInt32Array = []
var weights: PackedFloat32Array = []
var pitch := 0.0
var kick := 0.0
var axis_world := Vector3.RIGHT


func _process_modification_with_delta(_delta: float) -> void:
	var skel := get_skeleton()
	if skel == null or bones.is_empty():
		return
	var total := pitch + kick
	if absf(total) < 0.0001:
		return
	var axis_skel := (skel.global_basis.inverse() * axis_world).normalized()
	for i in bones.size():
		var b := bones[i]
		var parent := skel.get_bone_parent(b)
		var parent_basis := Basis.IDENTITY
		if parent >= 0:
			parent_basis = skel.get_bone_global_pose(parent).basis
		var axis_parent := (parent_basis.inverse() * axis_skel).normalized()
		if not axis_parent.is_normalized():
			continue
		var local_q := skel.get_bone_pose_rotation(b)
		var q := Quaternion(axis_parent, total * weights[i]) * local_q
		skel.set_bone_pose_rotation(b, q.normalized())
