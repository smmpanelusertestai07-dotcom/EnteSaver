class_name CharacterModel
extends Node3D
## Visual character: loads the rigged GLB (Blender/MPFB), merges the extra animation GLB
## (reload, pump, heal, throw, prone), drives an AnimationTree (locomotion scaled to the real
## speed, crouch and prone layers, jump, upper-body actions), outfit bundles, upper-body aim
## and the held weapon. Falls back to a simple procedural mannequin if the GLB is missing.

const GLB := "res://assets/character/character.glb"
const EXTRA_GLB := "res://assets/character/anims_extra.glb"
const MANIFEST := "res://assets/character/manifest.json"

const BUNDLE_INFO := [
	{"id": "default", "name": "ROOKIE", "rarity": "common", "desc": "The classic starter look."},
	{"id": "desert", "name": "DESERT FOX", "rarity": "rare", "desc": "Sun-baked tactical gear."},
	{"id": "neon", "name": "NEON STRIKER", "rarity": "epic", "desc": "Street style with a cyan edge."},
	{"id": "shadow", "name": "SHADOW OPS", "rarity": "epic", "desc": "Silent black-ops kit."},
	{"id": "royal", "name": "ROYAL GOLD", "rarity": "legendary", "desc": "White and gold. Pure flex."},
]
const LOOP_ANIMS := ["idle", "run_fwd", "run_back", "run_left", "run_right", "crouch_idle", "crouch_fwd", "lobby_idle",
	"victory", "heal", "prone_idle", "prone_fwd"]
## Speeds (m/s) at which the in-place cycles were authored; playback is scaled to the real speed.
const RUN_AUTHORED := 2.0
const CROUCH_AUTHORED := 1.0
const PRONE_AUTHORED := 0.30
## Minimum time between two hit flinches, so automatic fire does not lock the upper body.
const FLINCH_GAP := 0.6
## Medkit pack held in the left hand while healing (the clip presses it to the belly): offset in
## hand_l bone space (6 cm toward the fingers, 2.5 cm off the palm toward the body), flat side
## against the palm with the cross facing out; scale of the medkit model along its long / thin /
## wide sides.
const KIT_OFFSET := Vector3(0.025, 0.06, 0.0)
const KIT_SCALE := Vector3(0.42, 0.22, 0.42)
## Visual layer of characters and held weapons (the top-down minimap render skips it).
const LAYER_ACTORS := 4
const UPPER_BONES := ["spine_01", "spine_02", "spine_03", "neck_01", "head", "clavicle_l", "clavicle_r",
	"upperarm_l", "upperarm_r", "lowerarm_l", "lowerarm_r", "hand_l", "hand_r"]
const ARM_ONLY_BONES := ["clavicle_l", "upperarm_l", "lowerarm_l", "hand_l"]
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
static var _extra_anims: Dictionary = {}
static var _extra_loaded := false

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
var _speed := 0.0
var _crouch_amt := 0.0
var _prone_amt := 0.0
var _air := 0.0
var _heal_amt := 0.0
var _healing := false
var _aim_dir := Vector3.FORWARD
var _kick := 0.0
var _dead := false
var _phase := 0.0
var _fb := {}
var _track_prefix := "Armature/Skeleton3D:"
var _hand_follow := 0.0           # 0 = gun along the aim, 1 = gun follows the right hand
var _follow_until := 0.0
var _hide_gun_until := 0.0
var _hand_to_gun := Transform3D.IDENTITY
var _hand_to_gun_ready := false
var _pending_equip: Array = []    # [model, tint]: swapped in at the lowest point of the swap clip
var _kit: Node3D                  # medkit in the left hand while healing (built on first heal)
var _equip_at := 0.0
var _next_flinch := 0.0


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


## Animations from anims_extra.glb (loaded once, shared by every character).
static func extra_animations() -> Dictionary:
	if not _extra_loaded:
		_extra_loaded = true
		if ResourceLoader.exists(EXTRA_GLB):
			var ps: PackedScene = load(EXTRA_GLB)
			if ps:
				var inst := ps.instantiate()
				for ap: AnimationPlayer in inst.find_children("*", "AnimationPlayer", true, false):
					for a_name in ap.get_animation_list():
						var a := ap.get_animation(a_name)
						a.set_meta("toes_fixed", true)
						_extra_anims[String(a_name)] = a
				inst.free()
	return _extra_anims


func setup(bundle_id: String, with_weapon := true) -> void:
	show_weapon = with_weapon
	if ResourceLoader.exists(GLB):
		_load_glb()
	if skeleton == null:
		_build_fallback()
	apply_bundle(bundle_id)
	_set_layers(self)


func _set_layers(node: Node) -> void:
	for mi in node.find_children("*", "VisualInstance3D", true, false):
		(mi as VisualInstance3D).layers = LAYER_ACTORS


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
		_detect_track_prefix()
		_fix_base_toes()
		_merge_extra_animations()
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


func _detect_track_prefix() -> void:
	var idle := anim.get_animation("idle") if anim.has_animation("idle") else null
	if idle and idle.get_track_count() > 0:
		var p := String(idle.track_get_path(0))
		var colon := p.find(":")
		if colon > 0:
			_track_prefix = p.substr(0, colon + 1)


## The base clips in character.glb bend the toes the wrong way in heel-up frames (a sign slip in
## tools/character/animate.py legs(); the toe tips went up to 12 cm into the floor while running).
## Flips each ball bone's rotation about its own X axis, once per clip (the clips are shared by
## every character). Clips from anims_extra.glb are authored right and carry the same mark.
func _fix_base_toes() -> void:
	var balls := {}
	for b in ["ball_l", "ball_r"]:
		var i := skeleton.find_bone(b)
		if i >= 0:
			balls[_track_prefix + b] = skeleton.get_bone_rest(i).basis.get_rotation_quaternion()
	if balls.is_empty():
		return
	for a_name in anim.get_animation_list():
		var a := anim.get_animation(a_name)
		if a.has_meta("toes_fixed"):
			continue
		a.set_meta("toes_fixed", true)
		for t in a.get_track_count():
			var path := String(a.track_get_path(t))
			if a.track_get_type(t) != Animation.TYPE_ROTATION_3D or not balls.has(path):
				continue
			var rest: Quaternion = balls[path]
			for k in a.track_get_key_count(t):
				var d: Quaternion = rest.inverse() * (a.track_get_key_value(t, k) as Quaternion)
				a.track_set_key_value(t, k, rest * Quaternion(-d.x, d.y, d.z, d.w))


func _merge_extra_animations() -> void:
	var lib := anim.get_animation_library("")
	if lib == null:
		return
	for a_name: String in extra_animations():
		if not lib.has_animation(a_name):
			lib.add_animation(a_name, _extra_anims[a_name])


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
			sm.rim = 0.25
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


func _filter(node: AnimationNode, bones: Array) -> void:
	node.filter_enabled = true
	for b: String in bones:
		node.set_filter_path(NodePath(_track_prefix + b), true)
	# fingers follow their hand
	if "hand_l" in bones or "hand_r" in bones:
		for s in ["l", "r"]:
			if not ("hand_" + s) in bones:
				continue
			for f in ["thumb", "index", "middle", "ring", "pinky"]:
				for k in 3:
					node.set_filter_path(NodePath("%s%s_0%d_%s" % [_track_prefix, f, k + 1, s]), true)


func _build_tree() -> void:
	if not anim.has_animation("idle"):
		return
	tree = AnimationTree.new()
	tree.name = "AnimTree"
	root_scene.add_child(tree)
	tree.anim_player = tree.get_path_to(anim)
	var root := AnimationNodeBlendTree.new()
	var loco := AnimationNodeBlendSpace2D.new()
	loco.add_blend_point(_anim_node("idle"), Vector2.ZERO, -1, &"idle")
	loco.add_blend_point(_anim_node("run_fwd"), Vector2(0, 1), -1, &"fwd")
	loco.add_blend_point(_anim_node("run_back"), Vector2(0, -1), -1, &"back")
	loco.add_blend_point(_anim_node("run_left"), Vector2(-1, 0), -1, &"left")
	loco.add_blend_point(_anim_node("run_right"), Vector2(1, 0), -1, &"right")
	var crouch := AnimationNodeBlendSpace2D.new()
	crouch.add_blend_point(_anim_node("crouch_idle"), Vector2.ZERO, -1, &"idle")
	var k := 0
	for p in [Vector2(0, 1), Vector2(0, -1), Vector2(-1, 0), Vector2(1, 0)]:
		crouch.add_blend_point(_anim_node("crouch_fwd"), p, -1, StringName("move%d" % k))
		k += 1
	var prone := AnimationNodeBlendSpace1D.new()
	prone.add_blend_point(_anim_node("prone_idle" if anim.has_animation("prone_idle") else "crouch_idle"), 0.0, -1, &"idle")
	prone.add_blend_point(_anim_node("prone_fwd" if anim.has_animation("prone_fwd") else "crouch_fwd"), 1.0, -1, &"move")
	root.add_node("loco", loco, Vector2(0, 0))
	root.add_node("loco_ts", AnimationNodeTimeScale.new(), Vector2(150, 0))
	root.add_node("crouch", crouch, Vector2(0, 200))
	root.add_node("crouch_ts", AnimationNodeTimeScale.new(), Vector2(150, 200))
	root.add_node("crouch_blend", AnimationNodeBlend2.new(), Vector2(300, 100))
	root.add_node("prone", prone, Vector2(0, 400))
	root.add_node("prone_ts", AnimationNodeTimeScale.new(), Vector2(150, 400))
	root.add_node("prone_blend", AnimationNodeBlend2.new(), Vector2(450, 200))
	root.add_node("jump", _anim_node("jump"), Vector2(300, 550))
	root.add_node("jump_seek", AnimationNodeTimeSeek.new(), Vector2(450, 550))
	root.add_node("air_blend", AnimationNodeBlend2.new(), Vector2(600, 300))
	root.connect_node("loco_ts", 0, "loco")
	root.connect_node("crouch_ts", 0, "crouch")
	root.connect_node("prone_ts", 0, "prone")
	root.connect_node("crouch_blend", 0, "loco_ts")
	root.connect_node("crouch_blend", 1, "crouch_ts")
	root.connect_node("prone_blend", 0, "crouch_blend")
	root.connect_node("prone_blend", 1, "prone_ts")
	root.connect_node("jump_seek", 0, "jump")
	root.connect_node("air_blend", 0, "prone_blend")
	root.connect_node("air_blend", 1, "jump_seek")
	var last := "air_blend"
	# Healing loop on the upper body (blend amount follows the heal state).
	if anim.has_animation("heal"):
		var hb := AnimationNodeBlend2.new()
		_filter(hb, UPPER_BONES)
		root.add_node("heal", _anim_node("heal"), Vector2(600, 500))
		root.add_node("heal_blend", hb, Vector2(750, 350))
		root.connect_node("heal_blend", 0, last)
		root.connect_node("heal_blend", 1, "heal")
		last = "heal_blend"
	# One-shot upper-body actions (later ones override earlier ones while they play); reload and
	# swap are time-scaled to the weapon's reload / equip time.
	for action in ["reload", "throw", "pump", "swap", "hit_react"]:
		var a_name := String(action)
		if not anim.has_animation(a_name):
			continue
		var os := AnimationNodeOneShot.new()
		os.fadein_time = 0.05 if a_name == "hit_react" else 0.12
		os.fadeout_time = 0.12 if a_name == "hit_react" else 0.18
		_filter(os, ARM_ONLY_BONES if a_name == "pump" else UPPER_BONES)
		root.add_node(a_name, _anim_node(a_name), Vector2(750, 600))
		root.add_node(a_name + "_ts", AnimationNodeTimeScale.new(), Vector2(850, 600))
		root.add_node(a_name + "_shot", os, Vector2(950, 400))
		root.connect_node(a_name + "_ts", 0, a_name)
		root.connect_node(a_name + "_shot", 0, last)
		root.connect_node(a_name + "_shot", 1, a_name + "_ts")
		last = a_name + "_shot"
	root.connect_node("output", 0, last)
	tree.tree_root = root
	tree.active = true
	for ts in ["loco_ts", "crouch_ts", "prone_ts", "reload_ts", "throw_ts", "pump_ts", "swap_ts", "hit_react_ts"]:
		if anim.has_animation(ts.trim_suffix("_ts")) or ts in ["loco_ts", "crouch_ts", "prone_ts"]:
			tree.set("parameters/%s/scale" % ts, 1.0)


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

## v = local velocity in m/s (x right, y forward); stance = Fighter.Stance.
func update_locomotion(v: Vector2, stance: int, on_floor: bool, delta: float) -> void:
	if _dead:
		return
	if not _pending_equip.is_empty() and Time.get_ticks_msec() / 1000.0 >= _equip_at:
		equip_weapon(String(_pending_equip[0]), _pending_equip[1])
		_pending_equip = []
	var speed := v.length()
	_speed = lerpf(_speed, speed, 1.0 - exp(-10.0 * delta))
	var dir := v / speed if speed > 0.05 else Vector2.ZERO
	var ref := Fighter.RUN_SPEED
	if stance == Fighter.Stance.CROUCH:
		ref = Fighter.CROUCH_SPEED
	elif stance == Fighter.Stance.PRONE:
		ref = Fighter.PRONE_SPEED
	_loco = _loco.lerp(dir * clampf(speed / (ref * 0.6), 0.0, 1.0), 1.0 - exp(-10.0 * delta))
	_crouch_amt = move_toward(_crouch_amt, 1.0 if stance == Fighter.Stance.CROUCH else 0.0, delta * 5.0)
	_prone_amt = move_toward(_prone_amt, 1.0 if stance == Fighter.Stance.PRONE else 0.0, delta * 2.6)
	_air = move_toward(_air, 0.0 if on_floor else 1.0, delta * 6.0)
	_heal_amt = move_toward(_heal_amt, 1.0 if _healing else 0.0, delta * 4.0)
	if tree and tree.active:
		tree.set("parameters/loco/blend_position", _loco)
		tree.set("parameters/crouch/blend_position", _loco)
		tree.set("parameters/prone/blend_position", clampf(_speed / PRONE_AUTHORED, 0.0, 1.0))
		tree.set("parameters/crouch_blend/blend_amount", _crouch_amt)
		tree.set("parameters/prone_blend/blend_amount", _prone_amt)
		tree.set("parameters/air_blend/blend_amount", _air)
		tree.set("parameters/loco_ts/scale", clampf(_speed / RUN_AUTHORED, 1.0, 3.2) if _speed > 0.3 else 1.0)
		tree.set("parameters/crouch_ts/scale", clampf(_speed / CROUCH_AUTHORED, 1.0, 2.4) if _speed > 0.2 else 1.0)
		tree.set("parameters/prone_ts/scale", clampf(_speed / PRONE_AUTHORED, 0.6, 2.6) if _speed > 0.08 else 1.0)
		if anim.has_animation("heal"):
			tree.set("parameters/heal_blend/blend_amount", _heal_amt)
	elif fallback:
		_animate_fallback(delta)
	_kick = move_toward(_kick, 0.0, delta * 0.6)
	if aim_mod:
		aim_mod.kick = _kick
		aim_mod.pitch_scale = 1.0 - 0.7 * _prone_amt
	var now := Time.get_ticks_msec() / 1000.0
	var want_follow := 1.0 if (now < _follow_until or _healing) else 0.0
	_hand_follow = move_toward(_hand_follow, want_follow, delta * 6.0)
	if weapon_node and weapon_id != "":
		weapon_node.visible = show_weapon and not _dead and now >= _hide_gun_until


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
	if weapon_id == "weapon_sg" and tree and anim.has_animation("pump"):
		tree.set("parameters/pump_shot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)


func on_punch() -> void:
	_kick = minf(_kick + 0.08, 0.14)


func on_jump() -> void:
	if tree and tree.active:
		tree.set("parameters/jump_seek/seek_request", 0.0)


## Upper-body reload, stretched to the weapon's reload time; the gun follows the hand.
func play_reload(seconds: float) -> void:
	if tree and tree.active and anim.has_animation("reload"):
		var length := anim.get_animation("reload").length
		tree.set("parameters/reload_ts/scale", clampf(length / maxf(seconds, 0.3), 0.4, 3.0))
		tree.set("parameters/reload_shot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
		_follow_until = Time.get_ticks_msec() / 1000.0 + seconds


func play_heal(on: bool) -> void:
	_healing = on
	if on and _kit == null and skeleton and anim.has_animation("heal"):
		_build_kit()
	if _kit:
		_kit.visible = on and not _dead


func _build_kit() -> void:
	var path := "res://assets/props/medkit.glb"
	if not (ResourceLoader.exists(path) and skeleton.find_bone("hand_l") >= 0):
		return
	var att := BoneAttachment3D.new()
	att.name = "KitHand"
	att.bone_name = "hand_l"
	skeleton.add_child(att)
	var kit: Node3D = (load(path) as PackedScene).instantiate()
	# Kit axes in bone space: its long side along the fingers (bone Y), its thin side (model Y,
	# the face with the cross) out of the palm's back (bone -X).
	kit.transform = Transform3D(Basis(Vector3(0, 1, 0), Vector3(-1, 0, 0), Vector3(0, 0, 1)) * Basis.from_scale(KIT_SCALE), KIT_OFFSET)
	att.add_child(kit)
	_kit = att
	_set_layers(att)
	for mi in att.find_children("*", "GeometryInstance3D", true, false):
		(mi as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## Weapon swap: the gun dips and the new model appears at the lowest point of the clip.
## seconds = the weapon's equip time; "" = fists (the gun goes away at the lowest point).
func play_swap(model_name: String, tint: Color, seconds: float) -> void:
	if not (tree and tree.active and anim.has_animation("swap")) or (weapon_id == "" and model_name == ""):
		_pending_equip = []
		equip_weapon(model_name, tint)
		return
	var length := anim.get_animation("swap").length
	var scale := clampf(length / maxf(seconds, 0.15), 0.8, 3.0)
	tree.set("parameters/swap_ts/scale", scale)
	tree.set("parameters/swap_shot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	var now := Time.get_ticks_msec() / 1000.0
	_follow_until = maxf(_follow_until, now + length / scale)
	if weapon_id == "":
		_pending_equip = []
		equip_weapon(model_name, tint)    # coming from fists: the gun rises from low
	else:
		_pending_equip = [model_name, tint]
		_equip_at = now + 0.5 * length / scale


## Short upper-body flinch when hit; the gun follows the hands while it plays.
func play_hit() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if _dead or now < _next_flinch or not (tree and tree.active and anim.has_animation("hit_react")):
		return
	_next_flinch = now + FLINCH_GAP
	tree.set("parameters/hit_react_shot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	_follow_until = maxf(_follow_until, now + anim.get_animation("hit_react").length)


func play_throw() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if tree and tree.active and anim.has_animation("throw"):
		tree.set("parameters/throw_shot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
		var length := anim.get_animation("throw").length
		_hide_gun_until = now + length * 0.85
	else:
		_hide_gun_until = now + 0.5


func play_death() -> void:
	_dead = true
	if weapon_node:
		weapon_node.visible = false
	if _kit:
		_kit.visible = false
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
	show_weapon = false
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


## Direction the top of the head points (used to place the head hitbox; matters when prone).
func head_up() -> Vector3:
	if skeleton and bone_idx.has("head"):
		var b := (skeleton.global_transform.basis * skeleton.get_bone_global_pose(bone_idx["head"]).basis)
		var up := b.y.normalized()
		return up if up.length() > 0.5 else Vector3.UP
	return Vector3.UP


# ---------------------------------------------------------------- weapon

func equip_weapon(model_name: String, tint := Color.WHITE) -> void:
	if weapon_node:
		weapon_node.queue_free()
		weapon_node = null
	weapon_id = model_name
	# _hand_to_gun stays valid: every gun model's origin is its grip point.
	if model_name == "":
		return
	var path := "res://assets/props/%s.glb" % model_name
	if not ResourceLoader.exists(path):
		path = "res://assets/props/weapon_ar.glb"   # models still being made fall back to the AR
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
		var m := mi as MeshInstance3D
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		if tint != Color.WHITE and m.mesh:
			for s in m.mesh.get_surface_count():
				var src := m.get_active_material(s)
				if src is StandardMaterial3D and not String(src.resource_name).to_lower().contains("metal"):
					var dup := (src as StandardMaterial3D).duplicate() as StandardMaterial3D
					dup.albedo_color = dup.albedo_color * tint
					m.set_surface_override_material(s, dup)
	holder.visible = show_weapon and not _dead
	_set_layers(holder)
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
	if bone_idx.has("hand_r"):
		return bone_position("hand_r") + _aim_dir * 0.3
	return global_position + Vector3.UP * 1.4


func _hand_xf() -> Transform3D:
	return skeleton.global_transform * skeleton.get_bone_global_pose(bone_idx["hand_r"])


func _on_skeleton_updated() -> void:
	if not is_inside_tree() or weapon_node == null or not weapon_node.top_level:
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
	var aimed := Transform3D(Basis.looking_at(dir, up), grip)
	var hand_xf := _hand_xf()
	if _hand_follow < 0.001:
		# Remember how the gun sits in the hand while aiming, for reload/heal hand-following.
		_hand_to_gun = hand_xf.affine_inverse() * aimed
		_hand_to_gun_ready = true
		weapon_node.global_transform = aimed
		return
	var followed := hand_xf * _hand_to_gun if _hand_to_gun_ready else aimed
	weapon_node.global_transform = aimed.interpolate_with(followed, clampf(_hand_follow, 0.0, 1.0))


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
