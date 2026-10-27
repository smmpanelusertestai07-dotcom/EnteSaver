class_name CharacterModel
extends Node3D
## Visual character: loads the rigged GLB (Blender/MPFB), drives animation blending,
## outfit bundles, upper-body aim and the held weapon. Falls back to a simple
## procedural mannequin if the GLB is missing.

const GLB := "res://assets/character/character.glb"
const MANIFEST := "res://assets/character/manifest.json"

const BUNDLE_INFO := [
	{"id": "default", "name": "ROOKIE", "rarity": "common", "desc": "The classic starter look."},
	{"id": "desert", "name": "DESERT FOX", "rarity": "rare", "desc": "Sun-baked tactical gear."},
	{"id": "neon", "name": "NEON STRIKER", "rarity": "epic", "desc": "Street style with a cyan edge."},
	{"id": "shadow", "name": "SHADOW OPS", "rarity": "epic", "desc": "Silent black-ops kit."},
	{"id": "royal", "name": "ROYAL GOLD", "rarity": "legendary", "desc": "White and gold. Pure flex."},
]
const LOOP_ANIMS := ["idle", "run_fwd", "run_back", "run_left", "run_right", "crouch_idle", "crouch_fwd", "lobby_idle", "victory"]
const BONE_CANDIDATES := {
	"pelvis": ["pelvis", "Hips", "hips", "mixamorig:Hips", "root_pelvis"],
	"spine1": ["spine_01", "spine", "Spine", "spine01", "mixamorig:Spine"],
	"spine2": ["spine_02", "spine1", "Spine1", "spine02", "chest", "mixamorig:Spine1"],
	"spine3": ["spine_03", "spine2", "Spine2", "spine03", "upper_chest", "mixamorig:Spine2"],
	"neck": ["neck_01", "neck", "Neck", "neck01", "mixamorig:Neck"],
	"head": ["head", "Head", "mixamorig:Head"],
	"upperarm_l": ["upperarm_l", "upper_arm.L", "LeftArm", "mixamorig:LeftArm"],
	"lowerarm_l": ["lowerarm_l", "forearm.L", "LeftForeArm", "mixamorig:LeftForeArm"],
	"hand_l": ["hand_l", "hand.L", "LeftHand", "mixamorig:LeftHand"],
	"upperarm_r": ["upperarm_r", "upper_arm.R", "RightArm", "mixamorig:RightArm"],
	"lowerarm_r": ["lowerarm_r", "forearm.R", "RightForeArm", "mixamorig:RightForeArm"],
	"hand_r": ["hand_r", "hand.R", "RightHand", "mixamorig:RightHand"],
	"thigh_l": ["thigh_l", "thigh.L", "LeftUpLeg", "mixamorig:LeftUpLeg"],
	"calf_l": ["calf_l", "shin.L", "LeftLeg", "mixamorig:LeftLeg"],
	"foot_l": ["foot_l", "foot.L", "LeftFoot", "mixamorig:LeftFoot"],
	"thigh_r": ["thigh_r", "thigh.R", "RightUpLeg", "mixamorig:RightUpLeg"],
	"calf_r": ["calf_r", "shin.R", "RightLeg", "mixamorig:RightLeg"],
	"foot_r": ["foot_r", "foot.R", "RightFoot", "mixamorig:RightFoot"],
}

static var _manifest: Dictionary = {}
static var _manifest_loaded := false
static var _weapon_scenes := {}

var root_scene: Node3D
var skeleton: Skeleton3D
var anim: AnimationPlayer
var tree: AnimationTree
var aim_mod: AimSpineModifier
var weapon_node: Node3D
var weapon_id := ""
var muzzle_local := Vector3(0, 0.04, -0.55)
var meshes := {}
var bone_idx := {}
var fallback := false
var bundle := "default"
var show_weapon := true

var _loco := Vector2.ZERO
var _crouch_amt := 0.0
var _air := 0.0
var _aim_dir := Vector3.FORWARD
var _kick := 0.0
var _dead := false
var _phase := 0.0
var _fb := {}


static func manifest() -> Dictionary:
	if not _manifest_loaded:
		_manifest_loaded = true
		if FileAccess.file_exists(MANIFEST):
			var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(MANIFEST))
			if data is Dictionary:
				_manifest = data
	return _manifest


static func bundle_info(id: String) -> Dictionary:
	for b in BUNDLE_INFO:
		if b.id == id:
			return b
	return BUNDLE_INFO[0]


func setup(bundle_id: String, with_weapon := true) -> void:
	show_weapon = with_weapon
	if ResourceLoader.exists(GLB):
		_load_glb()
	if skeleton == null:
		_build_fallback()
	apply_bundle(bundle_id)


# ---------------------------------------------------------------- GLB character

func _load_glb() -> void:
	var ps: PackedScene = load(GLB)
	if ps == null:
		return
	root_scene = ps.instantiate()
	add_child(root_scene)
	root_scene.rotation.y = PI
	var skels := root_scene.find_children("*", "Skeleton3D", true, false)
	if skels.is_empty():
		root_scene.queue_free()
		root_scene = null
		return
	skeleton = skels[0]
	var players := root_scene.find_children("*", "AnimationPlayer", true, false)
	if not players.is_empty():
		anim = players[0]
	_map_bones()
	for mi in root_scene.find_children("*", "MeshInstance3D", true, false):
		meshes[String(mi.name)] = mi
		_fix_materials(mi)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	if anim:
		for a_name in LOOP_ANIMS:
			if anim.has_animation(a_name):
				anim.get_animation(a_name).loop_mode = Animation.LOOP_LINEAR
		_build_tree()
	aim_mod = AimSpineModifier.new()
	aim_mod.name = "AimSpine"
	var chain: PackedInt32Array = []
	var w: PackedFloat32Array = []
	for role in ["spine1", "spine2", "spine3"]:
		if bone_idx.has(role):
			chain.append(bone_idx[role])
	var share := 1.0 / maxf(chain.size(), 1)
	for i in chain.size():
		w.append(share)
	aim_mod.bones = chain
	aim_mod.weights = w
	skeleton.add_child(aim_mod)
	skeleton.skeleton_updated.connect(_on_skeleton_updated)


func _map_bones() -> void:
	var man := manifest()
	var mapping: Dictionary = man.get("bone_roles", {})
	for role in BONE_CANDIDATES:
		var idx := -1
		if mapping.has(role):
			idx = skeleton.find_bone(String(mapping[role]))
		if idx < 0:
			for cand in BONE_CANDIDATES[role]:
				idx = skeleton.find_bone(cand)
				if idx >= 0:
					break
		if idx >= 0:
			bone_idx[role] = idx


func _fix_materials(mi: MeshInstance3D) -> void:
	var mesh := mi.mesh
	if mesh == null:
		return
	for s in mesh.get_surface_count():
		var m := mi.get_active_material(s)
		if m is StandardMaterial3D:
			var sm := (m as StandardMaterial3D).duplicate() as StandardMaterial3D
			if sm.transparency != BaseMaterial3D.TRANSPARENCY_DISABLED:
				sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
				sm.alpha_scissor_threshold = 0.45
				sm.cull_mode = BaseMaterial3D.CULL_DISABLED
			sm.rim_enabled = true
			sm.rim = 0.22
			sm.rim_tint = 0.6
			if sm.roughness < 0.35:
				sm.roughness = 0.55
			# The fitted ROOKIE tee sits on the shorts' waistband; inflate it a few mm so nothing pokes through.
			if String(mi.name).begins_with("Outfit_default_Top"):
				sm.grow = true
				sm.grow_amount = 0.014
			mi.set_surface_override_material(s, sm)


func _anim_node(a_name: String) -> AnimationNodeAnimation:
	var n := AnimationNodeAnimation.new()
	n.animation = StringName(a_name if anim.has_animation(a_name) else "idle")
	return n


func _build_tree() -> void:
	if not anim.has_animation("idle"):
		return
	tree = AnimationTree.new()
	tree.name = "AnimTree"
	root_scene.add_child(tree)
	tree.anim_player = tree.get_path_to(anim)
	var root := AnimationNodeBlendTree.new()
	var loco := AnimationNodeBlendSpace2D.new()
	loco.add_blend_point(_anim_node("idle"), Vector2.ZERO)
	loco.add_blend_point(_anim_node("run_fwd"), Vector2(0, 1))
	loco.add_blend_point(_anim_node("run_back"), Vector2(0, -1))
	loco.add_blend_point(_anim_node("run_left"), Vector2(-1, 0))
	loco.add_blend_point(_anim_node("run_right"), Vector2(1, 0))
	var crouch := AnimationNodeBlendSpace2D.new()
	crouch.add_blend_point(_anim_node("crouch_idle"), Vector2.ZERO)
	for p in [Vector2(0, 1), Vector2(0, -1), Vector2(-1, 0), Vector2(1, 0)]:
		crouch.add_blend_point(_anim_node("crouch_fwd"), p)
	root.add_node("loco", loco, Vector2(0, 0))
	root.add_node("crouch", crouch, Vector2(0, 200))
	root.add_node("crouch_blend", AnimationNodeBlend2.new(), Vector2(300, 100))
	root.add_node("jump", _anim_node("jump"), Vector2(300, 300))
	root.add_node("jump_seek", AnimationNodeTimeSeek.new(), Vector2(450, 300))
	root.add_node("air_blend", AnimationNodeBlend2.new(), Vector2(600, 150))
	root.connect_node("crouch_blend", 0, "loco")
	root.connect_node("crouch_blend", 1, "crouch")
	root.connect_node("jump_seek", 0, "jump")
	root.connect_node("air_blend", 0, "crouch_blend")
	root.connect_node("air_blend", 1, "jump_seek")
	root.connect_node("output", 0, "air_blend")
	tree.tree_root = root
	tree.active = true


# ---------------------------------------------------------------- bundles

func apply_bundle(bundle_id: String) -> void:
	bundle = bundle_id
	if fallback:
		_fallback_colors(bundle_id)
		return
	var man := manifest()
	var bundles: Array = man.get("bundles", [])
	var def: Dictionary = {}
	for b in bundles:
		if b is Dictionary and String(b.get("id", "")) == bundle_id:
			def = b
	for n in meshes:
		var mi: MeshInstance3D = meshes[n]
		mi.visible = not String(n).begins_with("Outfit_")
	for n in def.get("meshes", []):
		if meshes.has(n):
			meshes[n].visible = true
	for n in def.get("hide", []):
		if meshes.has(n):
			meshes[n].visible = false


# ---------------------------------------------------------------- per-frame API

func update_locomotion(v: Vector2, crouch: bool, on_floor: bool, delta: float) -> void:
	if _dead:
		return
	_loco = _loco.lerp(v.limit_length(1.0), 1.0 - exp(-10.0 * delta))
	_crouch_amt = move_toward(_crouch_amt, 1.0 if crouch else 0.0, delta * 5.0)
	_air = move_toward(_air, 0.0 if on_floor else 1.0, delta * 6.0)
	if tree and tree.active:
		tree.set("parameters/loco/blend_position", _loco)
		tree.set("parameters/crouch/blend_position", _loco)
		tree.set("parameters/crouch_blend/blend_amount", _crouch_amt)
		tree.set("parameters/air_blend/blend_amount", _air)
	elif fallback:
		_animate_fallback(delta)
	_kick = move_toward(_kick, 0.0, delta * 0.6)
	if aim_mod:
		aim_mod.kick = _kick


func set_aim(pitch: float, aim_dir: Vector3) -> void:
	_aim_dir = aim_dir
	if aim_mod:
		aim_mod.pitch = clampf(pitch, -1.1, 1.1)
		aim_mod.axis_world = global_basis.x
	if fallback and _fb.has("arms"):
		_fb.arms.rotation.x = clampf(pitch, -1.1, 1.1)
		_fb.chest.rotation.x = clampf(pitch, -1.1, 1.1) * 0.3


func on_fire() -> void:
	_kick = minf(_kick + 0.035, 0.09)


func on_jump() -> void:
	if tree and tree.active:
		tree.set("parameters/jump_seek/seek_request", 0.0)


func play_death() -> void:
	_dead = true
	if weapon_node:
		weapon_node.visible = false
	if aim_mod:
		aim_mod.pitch = 0.0
		aim_mod.kick = 0.0
	if anim and anim.has_animation("death"):
		if tree:
			tree.active = false
		anim.play("death", 0.15)
	elif fallback:
		var tw := create_tween()
		tw.tween_property(_fb.hips, "rotation:x", -PI * 0.5, 0.6).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tw.parallel().tween_property(_fb.hips, "position:y", 0.25, 0.6)


func play_victory() -> void:
	if weapon_node:
		weapon_node.visible = false
	if aim_mod:
		aim_mod.pitch = 0.0
	if anim and anim.has_animation("victory"):
		if tree:
			tree.active = false
		anim.play("victory", 0.25)


func play_lobby() -> void:
	show_weapon = false
	if weapon_node:
		weapon_node.visible = false
	if anim:
		if tree:
			tree.active = false
		var a := "lobby_idle" if anim.has_animation("lobby_idle") else "idle"
		anim.play(a, 0.2)


# ---------------------------------------------------------------- weapon

func equip_weapon(model_name: String) -> void:
	if weapon_node:
		weapon_node.queue_free()
		weapon_node = null
	weapon_id = model_name
	var path := "res://assets/props/%s.glb" % model_name
	var holder := Node3D.new()
	holder.name = "Weapon"
	holder.top_level = true
	add_child(holder)
	weapon_node = holder
	var inst: Node3D = null
	if ResourceLoader.exists(path):
		if not _weapon_scenes.has(path):
			_weapon_scenes[path] = load(path)
		inst = (_weapon_scenes[path] as PackedScene).instantiate()
		holder.add_child(inst)
		var muzzle := inst.find_child("Muzzle", true, false)
		if muzzle is Node3D:
			muzzle_local = (muzzle as Node3D).position
			var p := muzzle.get_parent()
			while p != null and p != inst:
				if p is Node3D:
					muzzle_local = (p as Node3D).transform * muzzle_local
				p = p.get_parent()
	else:
		inst = _fallback_gun(model_name)
		holder.add_child(inst)
	for mi in holder.find_children("*", "MeshInstance3D", true, false):
		(mi as MeshInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	holder.visible = show_weapon and not _dead
	if fallback:
		holder.top_level = false
		holder.reparent(_fb.gun_socket, false)
		holder.transform = Transform3D.IDENTITY


func _fallback_gun(model_name: String) -> Node3D:
	var g := Node3D.new()
	var length := 0.85
	if model_name == "weapon_sg":
		length = 0.95
	elif model_name == "weapon_pistol":
		length = 0.22
	var body := MeshInstance3D.new()
	var bm := BoxMesh.new()
	bm.size = Vector3(0.06, 0.1, length)
	body.mesh = bm
	body.position = Vector3(0, 0.03, -length * 0.4)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.12, 0.12, 0.14)
	mat.metallic = 0.6
	mat.roughness = 0.4
	body.material_override = mat
	g.add_child(body)
	muzzle_local = Vector3(0, 0.04, -length * 0.9)
	return g


func muzzle_position() -> Vector3:
	if weapon_node and weapon_node.is_inside_tree():
		return weapon_node.global_transform * muzzle_local
	return global_position + Vector3.UP * 1.4


func _on_skeleton_updated() -> void:
	if weapon_node == null or not weapon_node.visible or not weapon_node.top_level:
		return
	if not (bone_idx.has("hand_r") and bone_idx.has("lowerarm_r")):
		return
	var hand := bone_position("hand_r")
	var fore := bone_position("lowerarm_r")
	var grip := hand + (hand - fore).normalized() * 0.055
	var dir := _aim_dir.normalized()
	if dir.length() < 0.5:
		dir = -global_basis.z
	var up := Vector3.UP if absf(dir.y) < 0.97 else global_basis.z
	weapon_node.global_transform = Transform3D(Basis.looking_at(dir, up), grip)


# ---------------------------------------------------------------- anchors (hitboxes, camera)

func bone_position(role: String) -> Vector3:
	if skeleton and bone_idx.has(role):
		return skeleton.global_transform * skeleton.get_bone_global_pose(bone_idx[role]).origin
	if fallback and _fb.has("anchors"):
		var a: Dictionary = _fb.anchors
		if a.has(role):
			return (a[role] as Node3D).global_position
	return global_position + Vector3.UP * 1.0


func has_skeleton() -> bool:
	return skeleton != null


# ---------------------------------------------------------------- procedural fallback

func _build_fallback() -> void:
	fallback = true
	var skin := StandardMaterial3D.new()
	skin.albedo_color = Color(0.67, 0.47, 0.34)
	skin.roughness = 0.6
	var shirt := StandardMaterial3D.new()
	shirt.albedo_color = Color(0.92, 0.92, 0.9)
	var pants := StandardMaterial3D.new()
	pants.albedo_color = Color(0.2, 0.21, 0.24)
	var hair := StandardMaterial3D.new()
	hair.albedo_color = Color(0.06, 0.05, 0.05)
	_fb.mats = {"skin": skin, "shirt": shirt, "pants": pants, "hair": hair}
	var hips := Node3D.new()
	hips.position.y = 0.95
	add_child(hips)
	_fb.hips = hips
	var chest := Node3D.new()
	hips.add_child(chest)
	_fb.chest = chest
	_add_part(chest, _capsule(0.19, 0.62), Vector3(0, 0.33, 0), shirt)
	var head := _add_part(chest, _sphere(0.12), Vector3(0, 0.78, 0), skin)
	_add_part(head, _sphere(0.125), Vector3(0, 0.03, 0.01), hair).scale = Vector3(1, 0.75, 1)
	var arms := Node3D.new()
	arms.position = Vector3(0, 0.55, 0)
	chest.add_child(arms)
	_fb.arms = arms
	var arm_r := _add_part(arms, _capsule(0.055, 0.6), Vector3(0.17, -0.08, -0.22), skin)
	arm_r.rotation = Vector3(deg_to_rad(80), 0, deg_to_rad(10))
	var arm_l := _add_part(arms, _capsule(0.055, 0.66), Vector3(-0.02, -0.04, -0.3), skin)
	arm_l.rotation = Vector3(deg_to_rad(80), deg_to_rad(-35), 0)
	var gun_socket := Node3D.new()
	gun_socket.position = Vector3(0.12, -0.08, -0.32)
	arms.add_child(gun_socket)
	_fb.gun_socket = gun_socket
	var legs := {}
	for side in [-1, 1]:
		var pivot := Node3D.new()
		pivot.position = Vector3(0.1 * side, 0.0, 0)
		hips.add_child(pivot)
		_add_part(pivot, _capsule(0.08, 0.9), Vector3(0, -0.45, 0), pants)
		legs[side] = pivot
	_fb.legs = legs
	var anchors := {}
	for role in ["head", "neck", "spine1", "spine2", "spine3", "pelvis", "hand_r", "hand_l", "lowerarm_r", "thigh_l", "thigh_r", "calf_l", "calf_r", "foot_l", "foot_r", "upperarm_l", "upperarm_r", "lowerarm_l"]:
		var n := Node3D.new()
		anchors[role] = n
	anchors.head.position = Vector3(0, 0.78, 0)
	chest.add_child(anchors.head)
	anchors.neck.position = Vector3(0, 0.66, 0)
	chest.add_child(anchors.neck)
	anchors.spine1.position = Vector3(0, 0.12, 0)
	chest.add_child(anchors.spine1)
	anchors.spine2.position = Vector3(0, 0.3, 0)
	chest.add_child(anchors.spine2)
	anchors.spine3.position = Vector3(0, 0.45, 0)
	chest.add_child(anchors.spine3)
	hips.add_child(anchors.pelvis)
	for side in [-1, 1]:
		var s := "l" if side < 0 else "r"
		anchors["thigh_" + s].position = Vector3(0, -0.2, 0)
		legs[side].add_child(anchors["thigh_" + s])
		anchors["calf_" + s].position = Vector3(0, -0.6, 0)
		legs[side].add_child(anchors["calf_" + s])
		anchors["foot_" + s].position = Vector3(0, -0.9, 0)
		legs[side].add_child(anchors["foot_" + s])
	anchors.hand_r.position = Vector3(0.12, -0.08, -0.3)
	arms.add_child(anchors.hand_r)
	anchors.hand_l.position = Vector3(0.0, -0.05, -0.55)
	arms.add_child(anchors.hand_l)
	anchors.lowerarm_r.position = Vector3(0.16, -0.1, -0.1)
	arms.add_child(anchors.lowerarm_r)
	anchors.lowerarm_l.position = Vector3(-0.05, -0.1, -0.3)
	arms.add_child(anchors.lowerarm_l)
	anchors.upperarm_l.position = Vector3(-0.2, 0.0, 0)
	arms.add_child(anchors.upperarm_l)
	anchors.upperarm_r.position = Vector3(0.2, 0.0, 0)
	arms.add_child(anchors.upperarm_r)
	_fb.anchors = anchors


func _capsule(r: float, h: float) -> CapsuleMesh:
	var c := CapsuleMesh.new()
	c.radius = r
	c.height = h
	c.radial_segments = 12
	c.rings = 4
	return c


func _sphere(r: float) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = r
	s.height = r * 2.0
	s.radial_segments = 14
	s.rings = 8
	return s


func _add_part(parent: Node3D, mesh: Mesh, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.material_override = mat
	parent.add_child(mi)
	return mi


func _fallback_colors(bundle_id: String) -> void:
	var cols := {
		"default": [Color(0.92, 0.92, 0.9), Color(0.2, 0.21, 0.24)],
		"desert": [Color(0.76, 0.65, 0.45), Color(0.36, 0.38, 0.24)],
		"neon": [Color(0.08, 0.08, 0.1), Color(0.1, 0.55, 0.6)],
		"shadow": [Color(0.07, 0.07, 0.08), Color(0.1, 0.1, 0.12)],
		"royal": [Color(0.96, 0.95, 0.9), Color(0.85, 0.66, 0.2)],
	}
	var c: Array = cols.get(bundle_id, cols["default"])
	(_fb.mats.shirt as StandardMaterial3D).albedo_color = c[0]
	(_fb.mats.pants as StandardMaterial3D).albedo_color = c[1]


func _animate_fallback(delta: float) -> void:
	var speed := _loco.length()
	_phase += delta * (4.0 + 6.0 * speed)
	var swing := sin(_phase) * 0.6 * speed
	_fb.legs[-1].rotation.x = swing
	_fb.legs[1].rotation.x = -swing
	_fb.hips.position.y = lerpf(0.95, 0.62, _crouch_amt) + absf(cos(_phase)) * 0.03 * speed
	for side in [-1, 1]:
		_fb.legs[side].rotation.z = 0.0
	if _crouch_amt > 0.5:
		_fb.legs[-1].rotation.x += -0.9 * _crouch_amt
		_fb.legs[1].rotation.x += -0.9 * _crouch_amt
