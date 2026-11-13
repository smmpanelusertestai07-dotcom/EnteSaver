class_name CharacterModel
extends Node3D
## Visual character: loads the rigged GLB (Blender/MPFB), merges the extra animation GLBs
## (anims_extra: reload, pump, heal, throw, prone, fists, long-stride run; anims_extra2, made by
## tools/anim/anim_extra2.py: the gun carried low at the hip, the sprint), drives an AnimationTree
## (locomotion scaled to the real speed, the carry and sprint layers, crouch and prone layers,
## jump, upper-body actions), outfit bundles, upper-body aim and the held weapon. Falls back to a
## simple procedural mannequin if the GLB is missing.

const GLB := "res://assets/character/character.glb"
const EXTRA_GLBS := ["res://assets/character/anims_extra.glb", "res://assets/character/anims_extra2.glb"]
const MANIFEST := "res://assets/character/manifest.json"

const BUNDLE_INFO := [
	{"id": "default", "name": "ROOKIE", "rarity": "common", "desc": "The classic starter look."},
	{"id": "desert", "name": "DESERT FOX", "rarity": "rare", "desc": "Sun-baked tactical gear."},
	{"id": "neon", "name": "NEON STRIKER", "rarity": "epic", "desc": "Street style with a cyan edge."},
	{"id": "shadow", "name": "SHADOW OPS", "rarity": "epic", "desc": "Silent black-ops kit."},
	{"id": "royal", "name": "ROYAL GOLD", "rarity": "legendary", "desc": "White and gold. Pure flex."},
]
const LOOP_ANIMS := ["idle", "run_fwd", "run_back", "run_left", "run_right", "crouch_idle", "crouch_fwd", "lobby_idle",
	"victory", "heal", "prone_idle", "prone_fwd", "runx_fwd", "runx_back", "runx_left", "runx_right", "carry_idle",
	"sprint_fwd", "victory_pose"]
## Speeds (m/s) at which the in-place cycles were authored; playback is scaled to the real speed.
## The long-stride runx_* cycles (anims_extra) replace the base run_* jog when present.
const RUN_AUTHORED := 2.0
const RUNX_AUTHORED := 5.0
const CROUCH_AUTHORED := 1.0
const PRONE_AUTHORED := 0.30
## sprint_fwd (anims_extra2): long strides, a strong forward lean, the arms pumping with the gun low.
const SPRINT_AUTHORED := 5.5
## The reference's hip carry: standing (idle, walk, run) the gun hangs low in the right hand
## (carry_idle at rest, carry_run_a/b on the arms while moving) until the fighter fires or aims
## (raise_gun / aiming); it goes back down READY_HOLD s after the last shot.
const READY_HOLD := 2.0
## jump_air (anims_extra2): a jump seeks it to 0 (take-off, tuck, legs reaching down, then held);
## leaving the ground without a jump (a ledge) seeks it to JUMP_FALL. jump_land plays on a
## touch-down from a real fall while (nearly) standing still; moving, the knees give through the
## crouch dip (land_dip), which keeps the legs in step.
const JUMP_FALL := 0.55
const LAND_CLIP_MAX_SPEED := 1.5
## prone_up (1 s): standing up from prone while not moving; moving or a shot cuts it short.
const PRONE_UP_MAX_SPEED := 0.8
const LOBBY_GESTURES := ["lobby_hip", "lobby_shift", "lobby_look"]
const CARRY_BONES := ["clavicle_l", "clavicle_r", "upperarm_l", "upperarm_r", "lowerarm_l", "lowerarm_r", "hand_l", "hand_r"]
## The moving cycle has the full blend weight from this share of the stance's base speed; below it
## it is mixed with the idle, which shortens the stride by the same factor.
const FULL_BLEND := 0.6
## After a fall the knees give: a short dip toward the crouch pose; hops shorter than LAND_MIN_AIR
## (a stair edge, a slope's flicker) land without one.
const LAND_TIME := 0.34
const LAND_MIN_AIR := 0.22
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
const FIST_BONES := ["upperarm_l", "upperarm_r", "lowerarm_l", "lowerarm_r", "hand_l", "hand_r"]
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
	"ball_l": ["ball_l", "toe.L", "LeftToeBase", "mixamorig:LeftToeBase"],
	"ball_r": ["ball_r", "toe.R", "RightToeBase", "mixamorig:RightToeBase"],
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
var _run_authored := RUN_AUTHORED      # speed the run cycles in the blend were authored at
var _crouch_amt := 0.0
var _prone_amt := 0.0
var _air := 0.0
var _heal_amt := 0.0
var _fists_amt := 0.0
var _fwd_sign := 1.0                    # -1: crouch-walk / crawl play backwards (backing up)
var _air_time := 0.0
var _land_left := 0.0
var _land_peak := 0.0
var _holster: Node3D           # the gun on the back while the fists (or the sidearm) are out
var _holster_model := ""
## The round's gun's model (Fighter.set_loadout): on the back whenever another weapon (the sidearm,
## the fists) is in hand. "" (a model with no kit: the lobby, the results): the gun last in hand
## goes on the back while the hands are empty.
var back_model := ""
var _healing := false
var _aim_dir := Vector3.FORWARD
var _kick := 0.0
var _punch_left := true                 # the last jab was with the left hand (the next one is the right)
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
## The lobby's idle (play_lobby): lobby_idle at a pace that varies a little, and every few seconds
## a gesture: the head looks round to one side and back, or (cheer) the arms go up once.
var _lobby := false
var _lobby_cheer := false
var _gesture_in := 0.0
var _cheer_left := 0.0
var _look := 0.0
var _look_to := 0.0
var _look_hold := 0.0
## In a match, on top of the clips: the body leans into a turn while it runs (a roll about the feet,
## from the change of facing) and forward while it sprints (sprint: set by the fighter each tick).
const LEAN_PER_TURN := 0.045     # rad of roll per rad/s of turn at a full run
const LEAN_MAX := 0.12
const SPRINT_LEAN := 0.14        # rad the chest bends forward at a sprint
var sprint := false
var _lean := 0.0
var _sprint_lean := 0.0
var _last_yaw := INF
var _next_flinch := 0.0
## Set by the fighter each tick (Fighter.ads): scoped in, the gun stays up.
var aiming := false
var _ready_until := 0.0      # the gun is up (aim pose) until then
var _carry := 0.0            # 0 = aim pose, 1 = the gun carried low (arms layer and idle)
var _carry_gun := 0.0        # how far the gun follows the hand instead of the aim (carry, sprint)
var _sprint_amt := 0.0
## The aim pose's muzzle, from spine_03 in the aim's frame (looking along _aim_dir), learnt standing
## with the arms really up: muzzle_position while the arms are not, so it follows stance and pitch.
var _aim_muzzle := Vector3.ZERO
var _aim_muzzle_ok := false
var _jumped := false              # on_jump since the last time on the floor
var _was_floor := true
var _land_clip := false           # this touch-down plays jump_land (no crouch dip)
var _last_stance := -1
var _prone_up_until := 0.0
var _gesture_n := 0               # the lobby's gestures alternate: a look round, then a clip


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


## Animations from the EXTRA_GLBS (loaded once, shared by every character).
static func extra_animations() -> Dictionary:
	if not _extra_loaded:
		_extra_loaded = true
		for path: String in EXTRA_GLBS:
			if not ResourceLoader.exists(path):
				continue
			var ps: PackedScene = load(path)
			if ps == null:
				continue
			var inst := ps.instantiate()
			for ap: AnimationPlayer in inst.find_children("*", "AnimationPlayer", true, false):
				for a_name in ap.get_animation_list():
					var a := ap.get_animation(a_name)
					# (the long-stride runs were made with the base clips' toe slip: fixed like them)
					if not String(a_name).begins_with("runx_"):
						a.set_meta("toes_fixed", true)
					_extra_anims[String(a_name)] = a
			inst.free()
	return _extra_anims


func setup(bundle_id: String, with_weapon := true) -> void:
	show_weapon = with_weapon
	_ready_until = Time.get_ticks_msec() / 1000.0 + 0.5     # (the first frames learn the aim pose's grip)
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
	set_process(false)                  # (only the lobby's idle has per-frame work of its own)
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
	# The look round: a little in the chest, most in the neck and the head.
	for pair in [["spine2", 0.15], ["spine3", 0.15], ["neck", 0.3], ["head", 0.4]]:
		if bone_idx.has(pair[0]):
			aim_mod.twist_bones.append(bone_idx[pair[0]])
			aim_mod.twist_weights.append(float(pair[1]))
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
## every character). Clips from the extra GLBs are authored right and carry the same mark, except
## anims_extra's runx_* cycles, made with the same slip (their toe tips went 6 cm into the floor).
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


## ENEMY OUTLINE (round 8): an inverted hull drawn after each outer body surface (next_pass) in
## red: unshaded, front faces culled, pushed out along the normals a few mm and at least about
## 1 px on screen, so a dark outfit on a dark container still reads. Only the skin (Body_*) and
## outfit (Outfit_*) meshes get it, never the eyes, brows, lashes, hair or any alpha-cut surface
## (OUTLINE_SKIP). Its depth is pushed back depth_back_m (screen position unchanged), so the
## hull shows only against what lies well behind the fighter: never through its own face, fingers
## or clothes. The arena turns it on for the other side's fighters only (never teammates, never
## the lobby or the results).
const OUTLINE_SHADER := """
shader_type spatial;
render_mode unshaded, cull_front, shadows_disabled, depth_draw_opaque, fog_disabled;
uniform vec4 color : source_color = vec4(0.95, 0.12, 0.1, 1.0);
uniform float grow_m = 0.0025;
uniform float min_px = 1.0;
uniform float depth_back_m = 0.035;
void vertex() {
	VERTEX += NORMAL * grow_m;
	vec4 view = MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	vec4 clip = PROJECTION_MATRIX * view;
	vec3 n = mat3(MODELVIEW_MATRIX) * NORMAL;
	vec2 dir = (PROJECTION_MATRIX * vec4(n, 0.0)).xy;
	if (length(dir) > 0.0001) {
		clip.xy += normalize(dir) * min_px * (VIEWPORT_SIZE.y / 720.0) * 2.0 / VIEWPORT_SIZE * clip.w;
	}
	// Depth as if the hull sat depth_back_m further away (x/y unchanged): it loses to the
	// fighter's own nearby surfaces and wins only against the background.
	vec4 back = PROJECTION_MATRIX * vec4(view.xy, view.z - depth_back_m, 1.0);
	clip.z = back.z / back.w * clip.w;
	POSITION = clip;
}
void fragment() {
	ALBEDO = color.rgb;
}
"""
static var _outline_mat: ShaderMaterial
var outlined := false


static func outline_material() -> ShaderMaterial:
	if _outline_mat == null:
		var sh := Shader.new()
		sh.code = OUTLINE_SHADER
		_outline_mat = ShaderMaterial.new()
		_outline_mat.shader = sh
		_outline_mat.render_priority = -1
	return _outline_mat


## Meshes that never carry the outline (small inner parts and alpha-cut cards: a hull round them
## would ring the eyes or paint the brows red).
const OUTLINE_SKIP := ["Eyes", "Eyebrows", "Eyelashes", "Hair", "Teeth", "Tongue"]


## True for a mesh that forms the fighter's outer silhouette (skin or outfit) and may be outlined.
static func outline_mesh_ok(mesh_name: String) -> bool:
	for k: String in OUTLINE_SKIP:
		if mesh_name.begins_with(k):
			return false
	return mesh_name.begins_with("Body_") or mesh_name.begins_with("Outfit_")


## Turns the enemy outline on or off on the outer body surfaces (weapons, kit, eyes, brows, lashes,
## hair and alpha-cut surfaces stay plain).
func set_outline(on: bool) -> void:
	if on == outlined:
		return
	outlined = on
	var mat: Material = outline_material() if on else null
	for n in meshes:
		var mi: MeshInstance3D = meshes[n]
		if mi == null or mi.mesh == null:
			continue
		var ok := outline_mesh_ok(String(n))
		for i in mi.mesh.get_surface_count():
			var m := mi.get_surface_override_material(i)
			if m is BaseMaterial3D:
				var bm := m as BaseMaterial3D
				bm.next_pass = mat if ok and bm.transparency == BaseMaterial3D.TRANSPARENCY_DISABLED else null
	if fallback:
		for c in find_children("*", "MeshInstance3D", true, false):
			var fm := (c as MeshInstance3D).material_override
			if fm is BaseMaterial3D and c != weapon_node and not (weapon_node != null and weapon_node.is_ancestor_of(c)):
				(fm as BaseMaterial3D).next_pass = mat


func _anim_node(a_name: String) -> AnimationNodeAnimation:
	var n := AnimationNodeAnimation.new()
	n.animation = StringName(a_name if anim.has_animation(a_name) else "idle")
	return n


## The locomotion's rest point: the rifle-ready idle, or (carry, see READY_HOLD) the relaxed
## carry_idle with the gun low; parameters/loco/idle/carry/blend_amount.
func _idle_mix() -> AnimationRootNode:
	if not anim.has_animation("carry_idle"):
		return _anim_node("idle")
	var bt := AnimationNodeBlendTree.new()
	bt.add_node("ready", _anim_node("idle"), Vector2(0, 0))
	bt.add_node("relaxed", _anim_node("carry_idle"), Vector2(0, 150))
	bt.add_node("carry", AnimationNodeBlend2.new(), Vector2(200, 50))
	bt.connect_node("carry", 0, "ready")
	bt.connect_node("carry", 1, "relaxed")
	bt.connect_node("output", 0, "carry")
	return bt


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
	var run := "runx" if anim.has_animation("runx_fwd") else "run"
	_run_authored = RUNX_AUTHORED if run == "runx" else RUN_AUTHORED
	loco.add_blend_point(_idle_mix(), Vector2.ZERO, -1, &"idle")
	loco.add_blend_point(_anim_node(run + "_fwd"), Vector2(0, 1), -1, &"fwd")
	loco.add_blend_point(_anim_node(run + "_back"), Vector2(0, -1), -1, &"back")
	loco.add_blend_point(_anim_node(run + "_left"), Vector2(-1, 0), -1, &"left")
	loco.add_blend_point(_anim_node(run + "_right"), Vector2(1, 0), -1, &"right")
	var crouch := AnimationNodeBlendSpace2D.new()
	crouch.add_blend_point(_anim_node("crouch_idle"), Vector2.ZERO, -1, &"idle")
	var k := 0
	for p in [Vector2(0, 1), Vector2(0, -1), Vector2(-1, 0), Vector2(1, 0)]:
		crouch.add_blend_point(_anim_node("crouch_fwd"), p, -1, StringName("move%d" % k))
		k += 1
	var prone := AnimationNodeBlendSpace1D.new()
	# Every cycle keeps running at weight 0, so a change of direction blends legs in step (no pop).
	loco.sync = true
	crouch.sync = true
	prone.sync = true
	prone.add_blend_point(_anim_node("prone_idle" if anim.has_animation("prone_idle") else "crouch_idle"), 0.0, -1, &"idle")
	prone.add_blend_point(_anim_node("prone_fwd" if anim.has_animation("prone_fwd") else "crouch_fwd"), 1.0, -1, &"move")
	root.add_node("loco", loco, Vector2(0, 0))
	root.add_node("loco_ts", AnimationNodeTimeScale.new(), Vector2(150, 0))
	root.add_node("crouch", crouch, Vector2(0, 200))
	root.add_node("crouch_ts", AnimationNodeTimeScale.new(), Vector2(150, 200))
	root.add_node("crouch_blend", AnimationNodeBlend2.new(), Vector2(300, 100))
	# The sprint: its own full-body cycle over the run, time-scaled to the speed like the run.
	var stand := "loco_ts"
	if anim.has_animation("sprint_fwd"):
		root.add_node("sprint", _anim_node("sprint_fwd"), Vector2(0, -200))
		root.add_node("sprint_ts", AnimationNodeTimeScale.new(), Vector2(150, -200))
		root.add_node("sprint_blend", AnimationNodeBlend2.new(), Vector2(250, -100))
		root.connect_node("sprint_ts", 0, "sprint")
		root.connect_node("sprint_blend", 0, "loco_ts")
		root.connect_node("sprint_blend", 1, "sprint_ts")
		stand = "sprint_blend"
	root.add_node("prone", prone, Vector2(0, 400))
	root.add_node("prone_ts", AnimationNodeTimeScale.new(), Vector2(150, 400))
	root.add_node("prone_blend", AnimationNodeBlend2.new(), Vector2(450, 200))
	root.add_node("jump", _anim_node("jump_air" if anim.has_animation("jump_air") else "jump"), Vector2(300, 550))
	root.add_node("jump_seek", AnimationNodeTimeSeek.new(), Vector2(450, 550))
	root.add_node("air_blend", AnimationNodeBlend2.new(), Vector2(600, 300))
	root.connect_node("loco_ts", 0, "loco")
	root.connect_node("crouch_ts", 0, "crouch")
	root.connect_node("prone_ts", 0, "prone")
	root.connect_node("crouch_blend", 0, stand)
	root.connect_node("crouch_blend", 1, "crouch_ts")
	root.connect_node("prone_blend", 0, "crouch_blend")
	root.connect_node("prone_blend", 1, "prone_ts")
	root.connect_node("jump_seek", 0, "jump")
	root.connect_node("air_blend", 0, "prone_blend")
	root.connect_node("air_blend", 1, "jump_seek")
	var last := "air_blend"
	# Full-body one-shots over the stance layers: the landing and the stand-up from prone.
	for clip in ["jump_land", "prone_up"]:
		if not anim.has_animation(clip):
			continue
		var fs := AnimationNodeOneShot.new()
		fs.fadein_time = 0.05 if clip == "jump_land" else 0.12
		fs.fadeout_time = 0.15 if clip == "jump_land" else 0.25
		root.add_node(clip, _anim_node(clip), Vector2(600, 1200))
		root.add_node(clip + "_shot", fs, Vector2(650, 300))
		root.connect_node(clip + "_shot", 0, last)
		root.connect_node(clip + "_shot", 1, clip)
		last = clip + "_shot"
	# The gun carried low while moving: carry_run_a <-> b on the arms with the stride (like the fists).
	if anim.has_animation("carry_run_a"):
		var cb := AnimationNodeBlend2.new()
		_filter(cb, CARRY_BONES)
		root.add_node("carry_a", _anim_node("carry_run_a"), Vector2(450, 1000))
		root.add_node("carry_b", _anim_node("carry_run_b"), Vector2(450, 1100))
		root.add_node("carry_swing", AnimationNodeBlend2.new(), Vector2(600, 1050))
		root.add_node("carry_blend", cb, Vector2(700, 300))
		root.connect_node("carry_swing", 0, "carry_a")
		root.connect_node("carry_swing", 1, "carry_b")
		root.connect_node("carry_blend", 0, last)
		root.connect_node("carry_blend", 1, "carry_swing")
		last = "carry_blend"
	# Fists out: the arms move like a runner's, swinging against the legs (fists_run_a <-> b with the
	# stride, see _stride_phase), or hang relaxed at rest; the gun rides on the back.
	if anim.has_animation("fists_run_a"):
		var fb := AnimationNodeBlend2.new()
		_filter(fb, FIST_BONES)
		root.add_node("fists_a", _anim_node("fists_run_a"), Vector2(450, 700))
		root.add_node("fists_b", _anim_node("fists_run_b"), Vector2(450, 800))
		root.add_node("fists_rest", _anim_node("fists_idle"), Vector2(450, 900))
		root.add_node("fists_swing", AnimationNodeBlend2.new(), Vector2(600, 750))
		root.add_node("fists_move", AnimationNodeBlend2.new(), Vector2(700, 850))
		root.add_node("fists_blend", fb, Vector2(750, 300))
		root.connect_node("fists_swing", 0, "fists_a")
		root.connect_node("fists_swing", 1, "fists_b")
		root.connect_node("fists_move", 0, "fists_rest")
		root.connect_node("fists_move", 1, "fists_swing")
		root.connect_node("fists_blend", 0, last)
		root.connect_node("fists_blend", 1, "fists_move")
		last = "fists_blend"
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
	for action in ["reload", "throw", "pump", "swap", "punch_r", "punch_l", "hit_react"]:
		var a_name := String(action)
		if not anim.has_animation(a_name):
			continue
		var os := AnimationNodeOneShot.new()
		var quick := a_name == "hit_react" or a_name.begins_with("punch")
		os.fadein_time = 0.04 if quick else 0.12
		os.fadeout_time = 0.12 if quick else 0.18
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
	for ts in ["loco_ts", "crouch_ts", "prone_ts", "sprint_ts", "reload_ts", "throw_ts", "pump_ts", "swap_ts", "punch_r_ts", "punch_l_ts", "hit_react_ts"]:
		if anim.has_animation(ts.trim_suffix("_ts")) or ts in ["loco_ts", "crouch_ts", "prone_ts"] or (ts == "sprint_ts" and anim.has_animation("sprint_fwd")):
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
	_loco = _loco.lerp(dir * gait_weight(speed, stance, _run_authored), 1.0 - exp(-10.0 * delta))
	# Crouch-walk and crawl only have a forward cycle: backing up plays it backwards (no moonwalk);
	# the sign eases through 0, so a reversal slows the legs down instead of popping them.
	if speed > 0.15:
		_fwd_sign = move_toward(_fwd_sign, -1.0 if v.y < -0.3 * speed else 1.0, delta * 6.0)
	_track_landing(on_floor, delta)
	_stance_clips(stance, on_floor)
	_crouch_amt = move_toward(_crouch_amt, 1.0 if stance == Fighter.Stance.CROUCH else 0.0, delta * 5.0)
	_prone_amt = move_toward(_prone_amt, 1.0 if stance == Fighter.Stance.PRONE else 0.0, delta * 2.6)
	_air = move_toward(_air, 0.0 if on_floor else 1.0, delta * 6.0)
	_heal_amt = move_toward(_heal_amt, 1.0 if _healing else 0.0, delta * 4.0)
	_update_carry(stance, on_floor, delta)
	if tree and tree.active:
		tree.set("parameters/loco/blend_position", _loco)
		# (standing, the crouch space only shows through a landing dip: its idle, bent knees)
		tree.set("parameters/crouch/blend_position", _loco if _crouch_amt > 0.02 else Vector2.ZERO)
		tree.set("parameters/prone/blend_position", gait_weight(_speed, Fighter.Stance.PRONE, _run_authored))
		tree.set("parameters/crouch_blend/blend_amount", maxf(_crouch_amt, 0.0 if _land_clip else land_dip()))
		tree.set("parameters/prone_blend/blend_amount", _prone_amt)
		tree.set("parameters/air_blend/blend_amount", _air)
		# The feet cover the real speed (any weapon class, the fists, walk to sprint).
		tree.set("parameters/loco_ts/scale", gait_scale(_speed, Fighter.Stance.STAND, _run_authored))
		tree.set("parameters/crouch_ts/scale", gait_scale(_speed, Fighter.Stance.CROUCH, _run_authored) * _fwd_sign)
		tree.set("parameters/prone_ts/scale", gait_scale(_speed, Fighter.Stance.PRONE, _run_authored) * _fwd_sign)
		if anim.has_animation("carry_idle"):
			tree.set("parameters/loco/idle/carry/blend_amount", _carry)
		if anim.has_animation("sprint_fwd"):
			tree.set("parameters/sprint_blend/blend_amount", _sprint_amt)
			tree.set("parameters/sprint_ts/scale", clampf(_speed / SPRINT_AUTHORED, 0.5, 1.6))
		if anim.has_animation("carry_run_a"):
			tree.set("parameters/carry_blend/blend_amount", _carry * maxf(gait_weight(_speed, Fighter.Stance.STAND, _run_authored), _air) * (1.0 - _sprint_amt))
			tree.set("parameters/carry_swing/blend_amount", _stride_phase())
		if anim.has_animation("heal"):
			tree.set("parameters/heal_blend/blend_amount", _heal_amt)
		if anim.has_animation("fists_run_a"):
			_fists_amt = move_toward(_fists_amt, (1.0 if weapon_id == "" else 0.0) * (1.0 - _prone_amt), delta * 6.0)
			tree.set("parameters/fists_blend/blend_amount", _fists_amt)
			tree.set("parameters/fists_move/blend_amount", clampf(_speed / 1.5, 0.0, 1.0))
			tree.set("parameters/fists_swing/blend_amount", _stride_phase())
		_place_holster()
	elif fallback:
		_animate_fallback(delta)
	_kick = move_toward(_kick, 0.0, delta * 0.6)
	_update_lean(delta, on_floor)
	if aim_mod:
		aim_mod.kick = _kick - _sprint_lean
		# (the gun low or pumping in a sprint: the chest hardly follows the camera's pitch)
		aim_mod.pitch_scale = (1.0 - 0.7 * _prone_amt) * (1.0 - 0.8 * maxf(_carry, _sprint_amt))
	var now := Time.get_ticks_msec() / 1000.0
	var want_follow := 1.0 if (now < _follow_until or _healing) else 0.0
	_hand_follow = move_toward(_hand_follow, want_follow, delta * 6.0)
	if weapon_node and weapon_id != "":
		weapon_node.visible = show_weapon and not _dead and now >= _hide_gun_until


## The hip carry and the sprint layer (READY_HOLD, sprint_fwd): the arms ease down to the carry
## (about 0.35 s) and snap up to the aim (about 0.1 s); the gun follows the hand while carried.
func _update_carry(stance: int, on_floor: bool, delta: float) -> void:
	var up := gun_up()
	var standing := stance == Fighter.Stance.STAND and weapon_id != "" and not _healing and not standing_up()
	var want := 0.0 if up or not standing else 1.0
	_carry = move_toward(_carry, want, delta * (3.0 if want > _carry else 10.0))
	var sprint_on := sprint and standing and on_floor and _speed > Fighter.RUN_SPEED * 0.8 and anim != null and anim.has_animation("sprint_fwd")
	_sprint_amt = move_toward(_sprint_amt, 1.0 if sprint_on else 0.0, delta * (4.0 if sprint_on else 6.0))
	_carry_gun = 0.0 if up else maxf(_carry, _sprint_amt)


## The gun is up in the aim pose (a shot within READY_HOLD s, scoped in), not carried low.
func gun_up() -> bool:
	return aiming or Time.get_ticks_msec() / 1000.0 < _ready_until


## Up with the gun now (a shot, FIRE): the gun points along the aim at once and the arms follow it
## up in about 0.1 s; it stays up READY_HOLD s.
func raise_gun() -> void:
	_ready_until = Time.get_ticks_msec() / 1000.0 + READY_HOLD
	_carry_gun = 0.0


## The lean into turns and the sprint's forward bend (see LEAN_PER_TURN).
func _update_lean(delta: float, on_floor: bool) -> void:
	var yaw := global_rotation.y
	var rate := 0.0 if _last_yaw == INF or delta <= 0.0 else wrapf(yaw - _last_yaw, -PI, PI) / delta
	_last_yaw = yaw
	var run := clampf((_speed - 2.0) / 2.6, 0.0, 1.0) * (1.0 - _crouch_amt) * (1.0 - _prone_amt) * (1.0 if on_floor else 0.4)
	var want := clampf(-rate * LEAN_PER_TURN * run, -LEAN_MAX, LEAN_MAX)
	_lean = lerpf(_lean, want, 1.0 - exp(-8.0 * delta))
	_sprint_lean = move_toward(_sprint_lean, SPRINT_LEAN * run if sprint else 0.0, delta * 0.8)
	if root_scene:
		root_scene.rotation.z = _lean


## Speed (m/s) at which a stance's moving cycle was authored (x), and the speed from which it has
## the full blend weight (y).
static func gait_speeds(stance: int, run_authored: float) -> Vector2:
	match stance:
		Fighter.Stance.CROUCH:
			return Vector2(CROUCH_AUTHORED, Fighter.CROUCH_SPEED * FULL_BLEND)
		Fighter.Stance.PRONE:
			return Vector2(PRONE_AUTHORED, PRONE_AUTHORED)
	return Vector2(run_authored, Fighter.RUN_SPEED * FULL_BLEND)


## Share of the moving cycle in the blend at a speed (the rest is the idle).
static func gait_weight(speed: float, stance: int, run_authored: float) -> float:
	return clampf(speed / gait_speeds(stance, run_authored).y, 0.0, 1.0)


## Time scale of the moving cycle: weight x scale x authored speed = speed, so the feet neither
## slide nor skate at any speed; close to standstill it eases back to 1 (the idle's own pace).
static func gait_scale(speed: float, stance: int, run_authored: float) -> float:
	var g := gait_speeds(stance, run_authored)
	return lerpf(1.0, minf(maxf(speed, g.y) / g.x, 3.5), clampf(speed / 0.4, 0.0, 1.0))


## Counts the time off the floor; touching down after a real fall starts the landing dip.
func _track_landing(on_floor: bool, delta: float) -> void:
	if not on_floor:
		_air_time += delta
		return
	if _air_time >= LAND_MIN_AIR:
		_land_left = LAND_TIME
		_land_peak = clampf(0.2 + _air_time * 0.45, 0.25, 0.6)
		_land_clip = _speed < LAND_CLIP_MAX_SPEED and tree != null and tree.active and anim.has_animation("jump_land")
		if _land_clip:
			tree.set("parameters/jump_land_shot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	_air_time = 0.0
	_land_left = maxf(_land_left - delta, 0.0)
	if _land_left <= 0.0:
		_land_clip = false


## The jump's fall part when the body leaves the ground without a jump; the stand-up from prone.
func _stance_clips(stance: int, on_floor: bool) -> void:
	if tree == null or not tree.active:
		return
	if _was_floor and not on_floor and not _jumped and anim.has_animation("jump_air"):
		tree.set("parameters/jump_seek/seek_request", JUMP_FALL)
	if on_floor:
		_jumped = false
	_was_floor = on_floor
	var now := Time.get_ticks_msec() / 1000.0
	if anim.has_animation("prone_up"):
		if _last_stance == Fighter.Stance.PRONE and stance == Fighter.Stance.STAND and _speed < PRONE_UP_MAX_SPEED:
			tree.set("parameters/prone_up_shot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
			_prone_up_until = now + anim.get_animation("prone_up").length
		elif now < _prone_up_until and (_speed > PRONE_UP_MAX_SPEED or stance != Fighter.Stance.STAND or gun_up()):
			tree.set("parameters/prone_up_shot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FADE_OUT)
			_prone_up_until = 0.0
	_last_stance = stance


## Getting up from prone (prone_up playing).
func standing_up() -> bool:
	return Time.get_ticks_msec() / 1000.0 < _prone_up_until


## 0..~0.6: how far the knees give right now (a smooth bump over LAND_TIME, no pop in or out).
func land_dip() -> float:
	if _land_left <= 0.0:
		return 0.0
	return _land_peak * sin(PI * (1.0 - _land_left / LAND_TIME))


## 0..1: which fist leads (0 = the left one). Read from the feet, so the arms swing against
## whatever the legs do (forward, back, sideways, any speed).
func _stride_phase() -> float:
	if skeleton == null or not (bone_idx.has("foot_l") and bone_idx.has("foot_r")):
		return 0.5
	var d := (bone_position("foot_l") - bone_position("foot_r")).dot(-global_basis.z)
	return clampf(0.5 + d / 1.1, 0.0, 1.0)       # the long run stride spreads the feet up to ~0.55 m


## The gun of the round on the back while the fists are out (the reference look), diagonal
## across it with the muzzle up over the left shoulder.
func _set_holster(model_name: String) -> void:
	if _holster != null and model_name == _holster_model:
		return
	_holster_model = model_name
	if _holster:
		_holster.queue_free()
		_holster = null
	var path := "res://assets/props/%s.glb" % model_name
	if model_name == "" or fallback or not ResourceLoader.exists(path):
		return
	if not _weapon_scenes.has(path):
		_weapon_scenes[path] = load(path)
	_holster = Node3D.new()
	_holster.name = "Holster"
	_holster.top_level = true
	add_child(_holster)
	_holster.add_child((_weapon_scenes[path] as PackedScene).instantiate())
	_set_layers(_holster)
	for mi in _holster.find_children("*", "GeometryInstance3D", true, false):
		(mi as GeometryInstance3D).cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _place_holster() -> void:
	if _holster == null or skeleton == null:
		return
	_holster.visible = not _dead and weapon_id != _holster_model and show_weapon
	var fwd := -global_basis.z
	var right := fwd.cross(Vector3.UP).normalized()
	var z := -(Vector3.UP * 0.75 - right * 0.66).normalized()     # gun models point their muzzle along -z
	var x := (-fwd).cross(z).normalized()                          # the gun's top faces away from the back
	_holster.global_transform = Transform3D(Basis(x, z.cross(x), z), bone_position("spine3") - fwd * 0.2 - Vector3.UP * 0.05)


func set_aim(pitch: float, aim_dir: Vector3) -> void:
	_aim_dir = aim_dir
	if aim_mod:
		aim_mod.pitch = clampf(pitch, -1.1, 1.1)
		aim_mod.axis_world = global_basis.x
	if fallback and _fb.has("arms"):
		_fb.arms.rotation.x = clampf(pitch, -1.1, 1.1)
		_fb.chest.rotation.x = clampf(pitch, -1.1, 1.1) * 0.3


func on_fire() -> void:
	raise_gun()
	_kick = minf(_kick + 0.035, 0.09)
	if weapon_id == "weapon_sg" and tree and anim.has_animation("pump"):
		tree.set("parameters/pump_shot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)


## A jab, the right and left hand in turn (from a guard before the chin).
func on_punch() -> void:
	raise_gun()
	_kick = minf(_kick + 0.08, 0.14)
	_punch_left = not _punch_left
	var clip := "punch_l" if _punch_left else "punch_r"
	if tree and tree.active and anim.has_animation(clip):
		tree.set("parameters/%s_shot/request" % clip, AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)


func on_jump() -> void:
	_jumped = true
	if tree and tree.active:
		tree.set("parameters/jump_seek/seek_request", 0.0)
		_air = maxf(_air, 0.5)            # (the take-off is short: no slow fade into it)


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
	var speed := clampf(length / maxf(seconds, 0.15), 0.8, 3.0)
	tree.set("parameters/swap_ts/scale", speed)
	tree.set("parameters/swap_shot/request", AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE)
	var now := Time.get_ticks_msec() / 1000.0
	_follow_until = maxf(_follow_until, now + length / speed)
	if weapon_id == "":
		_pending_equip = []
		equip_weapon(model_name, tint)    # coming from fists: the gun rises from low
	else:
		_pending_equip = [model_name, tint]
		_equip_at = now + 0.5 * length / speed


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
	_end_lobby()
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


## On its feet again for the next round (undoes play_death and play_victory).
func revive() -> void:
	_end_lobby()
	_dead = false
	show_weapon = true
	_ready_until = Time.get_ticks_msec() / 1000.0 + 0.5
	if anim:
		anim.stop()
	if tree:
		tree.active = true
	if fallback and _fb.has("hips"):
		(_fb.hips as Node3D).rotation.x = 0.0


## clip: "victory" (the cheer, the match's end) or "victory_pose" (the results: fist up, hand on hip).
func play_victory(clip := "victory") -> void:
	_end_lobby()
	if weapon_node:
		weapon_node.visible = false
	show_weapon = false
	if aim_mod:
		aim_mod.pitch = 0.0
	if anim and not anim.has_animation(clip):
		clip = "victory"
	if anim and anim.has_animation(clip):
		if tree:
			tree.active = false
		anim.play(clip, 0.25)


func play_lobby(cheer := false) -> void:
	_lobby = true
	_lobby_cheer = cheer
	_gesture_in = randf_range(3.0, 5.5)
	_gesture_n = 0
	_cheer_left = 0.0
	_look_to = 0.0
	set_process(true)
	show_weapon = false
	if weapon_node:
		weapon_node.visible = false
	if anim:
		if tree:
			tree.active = false
		var a := "lobby_idle" if anim.has_animation("lobby_idle") else "idle"
		anim.play(a, 0.2)


func _end_lobby() -> void:
	if not _lobby:
		return
	_lobby = false
	set_process(false)
	_look = 0.0
	if aim_mod:
		aim_mod.twist = 0.0
	if anim:
		anim.speed_scale = 1.0


func _process(delta: float) -> void:
	if not _lobby or anim == null:
		set_process(false)
		return
	var base := "lobby_idle" if anim.has_animation("lobby_idle") else "idle"
	if _cheer_left > 0.0:
		_cheer_left -= delta
		if _cheer_left <= 0.0:
			anim.play(base, 0.5)
	_gesture_in -= delta
	if _gesture_in <= 0.0 and _cheer_left <= 0.0 and absf(_look) < 0.02:
		_gesture_in = randf_range(5.0, 9.0)
		anim.speed_scale = randf_range(0.88, 1.1)     # the weight shifts at a pace of their own
		_gesture_n += 1
		var clips: Array = LOBBY_GESTURES.filter(func(c: String) -> bool: return anim.has_animation(c))
		if _lobby_cheer and anim.has_animation("victory") and randf() < 0.3:
			anim.play("victory", 0.4)
			_cheer_left = anim.get_animation("victory").length / anim.speed_scale - 0.2
		elif _gesture_n % 2 == 0 and not clips.is_empty():
			# a gesture clip (the hand on the hip, the weight over, a look round), then the idle again
			var g: String = clips[randi() % clips.size()]
			anim.play(g, 0.4)
			_cheer_left = anim.get_animation(g).length / anim.speed_scale - 0.35
		else:
			_look_to = randf_range(0.45, 0.75) * (1.0 if randf() < 0.5 else -1.0)
			_look_hold = randf_range(1.2, 2.0)
	if _look_to != 0.0 and absf(_look - _look_to) < 0.02:
		_look_hold -= delta
		if _look_hold <= 0.0:
			_look_to = 0.0
	_look = lerpf(_look, _look_to, 1.0 - exp(-3.0 * delta))
	if aim_mod:
		aim_mod.twist = _look


## Direction the top of the head points (used to place the head hitbox; matters when prone).
func head_up() -> Vector3:
	if skeleton and bone_idx.has("head"):
		var b := (skeleton.global_transform.basis * skeleton.get_bone_global_pose(bone_idx["head"]).basis)
		var up := b.y.normalized()
		return up if up.length() > 0.5 else Vector3.UP
	return Vector3.UP


# ---------------------------------------------------------------- weapon

## Nothing in the hands and nothing on the back (a pick round before its pick, Fighter.await_pick).
func empty_hands() -> void:
	_pending_equip = []
	equip_weapon("")
	_set_holster("")


func equip_weapon(model_name: String, tint := Color.WHITE) -> void:
	if weapon_node:
		weapon_node.queue_free()
		weapon_node = null
	if back_model != "":
		_set_holster(back_model if model_name != back_model else "")
	else:
		_set_holster(weapon_id if model_name == "" else "")
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


## Where shots leave from. While the gun is carried low (or pumping in a sprint) a shot leaves
## from where the muzzle is in the aim pose (the model raises the gun with it), not from the hip.
func muzzle_position() -> Vector3:
	if not arms_up() and _aim_muzzle_ok and is_inside_tree():
		return bone_position("spine3") + _aim_basis() * _aim_muzzle
	if weapon_node and weapon_node.is_inside_tree():
		return weapon_node.global_transform * muzzle_local
	if bone_idx.has("hand_r"):
		return bone_position("hand_r") + _aim_dir * 0.3
	return global_position + Vector3.UP * 1.4


## The arms are in the aim pose (not carried, not pumping in a sprint, not on the way up).
func arms_up() -> bool:
	return _carry < 0.01 and _sprint_amt < 0.01 and _carry_gun < 0.001


## The aim's frame: looking along _aim_dir (forward if it has none yet).
func _aim_basis() -> Basis:
	var dir := _aim_dir.normalized()
	if dir.length() < 0.5:
		dir = -global_basis.z
	return Basis.looking_at(dir, Vector3.UP if absf(dir.y) < 0.97 else global_basis.z)


func _hand_xf() -> Transform3D:
	return skeleton.global_transform * skeleton.get_bone_global_pose(bone_idx["hand_r"])


## Puts the gun at the hand along the aim now (not at the next skeleton update), e.g. after the
## body turned to the crosshair in this frame.
func place_gun() -> void:
	raise_gun()
	_on_skeleton_updated()


func _on_skeleton_updated() -> void:
	if not is_inside_tree() or weapon_node == null or not weapon_node.top_level:
		return
	if not (bone_idx.has("hand_r") and bone_idx.has("lowerarm_r")):
		return
	var hand := bone_position("hand_r")
	var fore := bone_position("lowerarm_r")
	var grip := hand + (hand - fore).normalized() * 0.055
	var aimed := Transform3D(_aim_basis(), grip)
	var hand_xf := _hand_xf()
	var follow := maxf(_hand_follow, _carry_gun)
	if follow < 0.001:
		weapon_node.global_transform = aimed
		if arms_up():
			# Remember how the gun sits in the hand while aiming, for reload/heal/carry hand-following,
			# and (standing) where its muzzle is (muzzle_position while the arms are not up).
			_hand_to_gun = hand_xf.affine_inverse() * aimed
			_hand_to_gun_ready = true
			if bone_idx.has("spine3") and ((_crouch_amt < 0.01 and _prone_amt < 0.01) or not _aim_muzzle_ok):
				_aim_muzzle = aimed.basis.inverse() * (aimed * muzzle_local - bone_position("spine3"))
				_aim_muzzle_ok = true
		return
	var followed := hand_xf * _hand_to_gun if _hand_to_gun_ready else aimed
	weapon_node.global_transform = aimed.interpolate_with(followed, clampf(follow, 0.0, 1.0))


# ---------------------------------------------------------------- anchors (hitboxes, camera)

func bone_position(role: String) -> Vector3:
	if skeleton and bone_idx.has(role):
		return skeleton.global_transform * skeleton.get_bone_global_pose(bone_idx[role]).origin
	if fallback and _fb.has("anchors"):
		var a: Dictionary = _fb.anchors
		if a.has(role):
			return (a[role] as Node3D).global_position
	return global_position + Vector3.UP * 1.0


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
