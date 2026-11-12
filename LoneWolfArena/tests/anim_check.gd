extends Node
## Animation integration check (runs inside the game, headless is fine):
##   godot --headless --path . -- --autotest=script:res://tests/anim_check.gd
## - every extra clip is merged into the character's player
## - the base-clip toe fix holds and is applied once (clips are shared by all characters)
## - weapon swap changes the model at the lowest point of the clip, not at once
## - hit flinches are rate limited
## - a thrown grenade leaves the hand at the release frame, not on the input
## - at more frames than physics ticks the camera and the own model move between ticks
## - a gun pick keeps the frame-rate governor's resolution; bullet holes share one MultiMesh;
##   a frag kill reads FRAG; the target dummy's CHANGE GUN slot reopens the weapon pick
## Prints "ANIM CHECK DONE bad=N" and exits with N.

var bad := 0
var at: Node


func run(autotest: Node) -> int:
	at = autotest
	await at.wait(0.5)
	_check_clips_and_toes()
	_check_gait_playback()
	await _check_swap_and_flinch()
	await _check_throw()
	at.log_line("ANIM CHECK DONE bad=%d" % bad)
	return bad


func _expect(ok: bool, what: String) -> void:
	if not ok:
		bad += 1
	at.log_line(("ok   " if ok else "FAIL ") + what)


func _model() -> CharacterModel:
	var m := CharacterModel.new()
	add_child(m)
	m.setup("default", true)
	return m


func _lowest_toe(m: CharacterModel, clip: String) -> float:
	var ap := m.anim
	var sk := m.skeleton
	m.tree.active = false
	ap.play(clip)
	var a := ap.get_animation(clip)
	var lowest := 9.0
	var t := 0.0
	while t <= a.length:
		ap.seek(t, true)
		for b in ["ball_l", "ball_r"]:
			var g := sk.global_transform * sk.get_bone_global_pose(sk.find_bone(b))
			lowest = minf(lowest, (g.origin + g.basis.y.normalized() * 0.07).y)
		t += 1.0 / 30.0
	ap.stop()
	m.tree.active = true
	return lowest


func _check_clips_and_toes() -> void:
	var m1 := _model()
	for clip in ["reload", "pump", "heal", "throw", "swap", "hit_react", "prone_idle", "prone_fwd", "punch_r", "punch_l"]:
		_expect(m1.anim.has_animation(clip), "clip merged: " + clip)
	var toe1 := _lowest_toe(m1, "run_fwd")
	var m2 := _model()      # second character: must not flip the shared clips back
	var toe2 := _lowest_toe(m2, "run_fwd")
	_expect(toe1 > -0.035, "run_fwd toes stay above the floor (lowest tip %.3f m)" % toe1)
	_expect(absf(toe1 - toe2) < 0.002, "toe fix applied once (second model %.3f m)" % toe2)
	for clip in ["crouch_fwd", "prone_fwd", "reload"]:
		var lo := _lowest_toe(m1, clip)
		_expect(lo > -0.035, "%s toes stay above the floor (lowest tip %.3f m)" % [clip, lo])
	m1.queue_free()
	m2.queue_free()


## The feet keep up with the body: for every weapon class (the fists too) and every gait, the moving
## cycle's blend share x time scale x authored speed is the real speed (no foot sliding). Backing
## up crouched plays the crouch-walk backwards (no moonwalk); a fall ends in a short knee dip that
## eases in and out, a stair-edge hop in none.
func _check_gait_playback() -> void:
	var m := _model()
	var ra := CharacterModel.RUNX_AUTHORED if m.anim.has_animation("runx_fwd") else CharacterModel.RUN_AUTHORED
	var gaits := [["walk", Fighter.Stance.STAND, Fighter.WALK_SPEED], ["slow walk", Fighter.Stance.STAND, Fighter.WALK_SPEED * 0.5],
		["run", Fighter.Stance.STAND, Fighter.RUN_SPEED], ["sprint", Fighter.Stance.STAND, Fighter.SPRINT_SPEED],
		["crouch-walk", Fighter.Stance.CROUCH, Fighter.CROUCH_SPEED], ["slow crouch-walk", Fighter.Stance.CROUCH, Fighter.CROUCH_SPEED * 0.4],
		["crawl", Fighter.Stance.PRONE, Fighter.PRONE_SPEED]]
	var worst := 0.0
	for cls in Weapons.CLASS_MOVE:
		for g in gaits:
			var st := int(g[1])
			var speed := float(g[2]) * float(Weapons.CLASS_MOVE[cls])
			var feet := CharacterModel.gait_weight(speed, st, ra) * CharacterModel.gait_scale(speed, st, ra) * CharacterModel.gait_speeds(st, ra).x
			var err := absf(feet - speed) / speed
			worst = maxf(worst, err)
			if err > 0.04:
				_expect(false, "%s %s: feet %.2f m/s, body %.2f m/s" % [cls, g[0], feet, speed])
	_expect(worst <= 0.04, "feet follow the body for every class and gait (worst off by %.1f %%)" % (worst * 100.0))
	var dt := 1.0 / 60.0
	for _i in 60:
		m.update_locomotion(Vector2(0, Fighter.RUN_SPEED * float(Weapons.CLASS_MOVE["MELEE"])), Fighter.Stance.STAND, true, dt)
	var fast := float(m.tree.get("parameters/loco_ts/scale"))
	for _i in 60:
		m.update_locomotion(Vector2(0, Fighter.RUN_SPEED * float(Weapons.CLASS_MOVE["SNIPER"])), Fighter.Stance.STAND, true, dt)
	var slow := float(m.tree.get("parameters/loco_ts/scale"))
	_expect(fast > slow * 1.2, "the fists' run cycle plays faster than the sniper rifle's (%.2f vs %.2f)" % [fast, slow])
	for _i in 60:
		m.update_locomotion(Vector2(0, -1.4), Fighter.Stance.CROUCH, true, dt)
	var back := float(m.tree.get("parameters/crouch_ts/scale"))
	for _i in 60:
		m.update_locomotion(Vector2(0, 1.4), Fighter.Stance.CROUCH, true, dt)
	var fwd := float(m.tree.get("parameters/crouch_ts/scale"))
	_expect(back < -0.9 and fwd > 0.9, "the crouch-walk plays backwards backing up (%.2f), forwards again after (%.2f)" % [back, fwd])
	for _i in 60:
		m.update_locomotion(Vector2.ZERO, Fighter.Stance.STAND, true, dt)
	for _i in 3:
		m.update_locomotion(Vector2.ZERO, Fighter.Stance.STAND, false, dt)
	var hop := 0.0
	for _i in 30:
		m.update_locomotion(Vector2.ZERO, Fighter.Stance.STAND, true, dt)
		hop = maxf(hop, m.land_dip())
	_expect(hop == 0.0, "a stair-edge hop lands without a dip")
	for _i in 40:
		m.update_locomotion(Vector2.ZERO, Fighter.Stance.STAND, false, dt)
	var dip := 0.0
	var first := -1.0
	for _i in 40:
		m.update_locomotion(Vector2.ZERO, Fighter.Stance.STAND, true, dt)
		if first < 0.0:
			first = m.land_dip()
		dip = maxf(dip, m.land_dip())
	_expect(dip > 0.3 and first < 0.15 and m.land_dip() == 0.0,
		"a fall ends in a short knee dip (peak %.2f, eases in from %.2f, over in 0.67 s)" % [dip, first])
	_expect(float(m.tree.get("parameters/crouch_blend/blend_amount")) < 0.01, "standing straight again after the dip")
	m.queue_free()


func _check_swap_and_flinch() -> void:
	var m := _model()
	m.equip_weapon("weapon_ar")
	await at.wait(0.2)
	m.play_swap("weapon_smg", Color.WHITE, 0.3)
	m.update_locomotion(Vector2.ZERO, 0, true, 0.016)
	_expect(m.weapon_id == "weapon_ar", "swap keeps the old gun at the start of the clip")
	var t := 0.0
	while m.weapon_id != "weapon_smg" and t < 1.0:
		await get_tree().process_frame
		m.update_locomotion(Vector2.ZERO, 0, true, get_process_delta_time())
		t += get_process_delta_time()
	_expect(m.weapon_id == "weapon_smg" and t > 0.08 and t < 0.3, "new gun appears mid-swap (after %.2f s)" % t)
	m.play_hit()
	var first: float = m._next_flinch
	m.play_hit()
	_expect(is_equal_approx(first, m._next_flinch), "second flinch inside %.1f s is ignored" % CharacterModel.FLINCH_GAP)
	m.queue_free()


func _check_throw() -> void:
	Game.goto_arena()
	await at.wait(1.0)
	var arena: Node = get_tree().current_scene
	await at.wait_for_phase(arena, 1, 40.0)
	var p: Fighter = arena.get("player")
	_expect(p != null and arena.get("phase") == 1, "arena reached FIGHT")
	if p == null:
		return
	var before := _grenades()
	_expect(p.throw_grenade(), "throw accepted")
	await get_tree().process_frame
	_expect(_grenades() == before, "no grenade on the input frame")
	await at.wait(Fighter.THROW_RELEASE + 0.15)
	_expect(_grenades() == before + 1, "grenade released after %.2f s" % Fighter.THROW_RELEASE)
	await _check_items_in_hand(p as Player)
	await _check_smooth_camera(arena, p as Player)
	_check_pick_keeps_governor(arena)
	_check_bullet_holes(arena, p)
	_check_frag_feed(arena, p)
	await _check_dummy_gun_change()


## The wall and grenade buttons only take the item in hand; FIRE uses it when let go, the same
## button again or a weapon puts it away, and a hand with an item never shoots.
func _check_items_in_hand(p: Player) -> void:
	p.shields = 2
	p.grenades = 1
	var walls := get_tree().get_nodes_in_group("shield_walls").size()
	p.use_shield()
	await get_tree().process_frame
	_expect(p.ready_item == "wall" and p.shields == 2 and _walls() == walls, "wall button: wall in hand, nothing placed")
	var ammo := p.weapon().ammo
	p.set_firing(true)
	await at.wait(0.2)
	_expect(_walls() == walls and p.weapon().ammo == ammo and not p.firing, "FIRE held with the wall: no shot, no wall yet")
	p.set_firing(false)
	await get_tree().process_frame
	_expect(p.ready_item == "" and p.shields == 1 and _walls() == walls + 1, "FIRE let go: the wall stands")
	p.use_shield()
	p.use_shield()
	_expect(p.ready_item == "" and p.shields == 1, "the wall button again puts it away")
	p.use_grenade()
	p.select_weapon(p.current)
	_expect(p.ready_item == "" and p.grenades == 1, "a weapon puts the grenade away")
	var before := _grenades()
	p.use_grenade()
	p.set_firing(true)
	p.set_firing(false)
	await at.wait(Fighter.THROW_RELEASE + 0.15)
	_expect(p.grenades == 0 and _grenades() == before + 1, "grenade in hand: FIRE throws it")
	p.use_grenade()
	_expect(p.ready_item == "", "no grenade left: nothing in hand")


## At more frames than physics ticks a second (90 / 120 FPS) the camera follows the running body on
## every frame, also the frames without a tick (it used to repeat them), and the own model with it.
func _check_smooth_camera(arena: Node, p: Player) -> void:
	var hud: Node = arena.get("hud")
	var fps := Engine.max_fps
	var ticks := Engine.physics_ticks_per_second
	Engine.max_fps = 120
	Engine.physics_ticks_per_second = 20        # several frames to each tick, even on a slow machine
	hud.process_mode = Node.PROCESS_MODE_DISABLED   # (its joystick would stop the run)
	for w in get_tree().get_nodes_in_group("shield_walls"):
		w.queue_free()
	p.global_position = arena.call("closest_nav_point", arena.get("zone_center"))    # the open centre bay
	await get_tree().process_frame
	# Each frame as it is drawn (Sampler runs after every other _process): its physics tick count,
	# the camera's place and how far the model is from the body's drawn place under the camera.
	var frames: Array = []
	var sampler := Sampler.new()
	sampler.on_frame = func() -> void:
		frames.append([Engine.get_physics_frames(), p.rig.global_position,
			p.model.global_position.distance_to(p.rig.global_position - Vector3.UP * p._cam_y)])
	arena.add_child(sampler)
	for i in 40:
		p.move_dir = Vector2(0, 1)
		await get_tree().process_frame
	sampler.queue_free()
	p.move_dir = Vector2.ZERO
	var no_tick := 0
	var moved := 0
	var off_model := 0.0
	for i in range(1, frames.size()):
		off_model = maxf(off_model, float(frames[i][2]))
		if int(frames[i][0]) == int(frames[i - 1][0]):
			no_tick += 1
			moved += 1 if (frames[i][1] as Vector3).distance_to(frames[i - 1][1]) > 0.0005 else 0
	hud.process_mode = Node.PROCESS_MODE_INHERIT
	Engine.physics_ticks_per_second = ticks
	Engine.max_fps = fps
	_expect(no_tick > 0 and moved >= no_tick * 0.8 and off_model < 0.01,
		"the camera moves on frames between physics ticks (%d of %d) and the model with it (%.3f m)" % [moved, no_tick, off_model])


## The player's own gun pick saves the settings (last_pick): it must not set the graphics up again,
## which reset the frame-rate governor's lowered resolution in the middle of a match.
func _check_pick_keeps_governor(arena: Node) -> void:
	var vp := arena.get_viewport()
	var scale := vp.scaling_3d_scale
	vp.scaling_3d_scale = 0.6                   # as the governor lowers it on a slow phone
	arena.call("_on_weapon_picked", "smg")
	var after := vp.scaling_3d_scale
	vp.scaling_3d_scale = scale
	_expect(is_equal_approx(after, 0.6), "a gun pick keeps the governor's lowered resolution (0.60, got %.2f)" % after)


## Bullet holes are one MultiMesh (one draw call): a ring of Effects.MAX_HOLES, nothing else.
func _check_bullet_holes(arena: Node, p: Fighter) -> void:
	for i in Effects.MAX_HOLES + 15:
		Effects.impact(arena, p.global_position + Vector3(0.1 * i, 1.0, -3.0), Vector3.BACK)
	var layers := 0
	var single := 0
	for c in arena.get_children():
		layers += 1 if c is MultiMeshInstance3D and c.name.begins_with("BulletHoles") else 0
		single += 1 if c is MeshInstance3D and (c as MeshInstance3D).material_override == Effects._hole_material() else 0
	_expect(layers == 1 and single == 0 and Effects.hole_count() == Effects.MAX_HOLES,
		"bullet holes share one MultiMesh, the newest %d kept (%d layers, %d alone, %d holes)" % [Effects.MAX_HOLES, layers, single, Effects.hole_count()])


## A frag kill reads FRAG in the kill feed, not the thrower's gun.
func _check_frag_feed(arena: Node, p: Fighter) -> void:
	var b: Fighter = arena.get("bot")
	b.take_damage(9999.0, "body", p, b.global_position + Vector3(3, 0, 0), "frag")
	var feed: Array = (arena.get("hud") as Node).get("_kill_feed")
	_expect(not b.alive and not feed.is_empty() and String(feed[0].weapon) == "FRAG", "a frag kill reads FRAG in the kill feed (%s)" % [str(feed[0]) if not feed.is_empty() else "empty"])


## TARGET DUMMY: CHANGE GUN (the plate left of the weapon panel's small slots; the middle slot is
## the sidearm's) opens the weapon pick in the fight, and the pick gives both fighters the new gun.
func _check_dummy_gun_change() -> void:
	Game.practice = true
	Game.goto_arena()
	await at.wait(1.0)
	var arena: Node = get_tree().current_scene
	await at.wait_for_phase(arena, 1, 40.0)
	var hud: HUD = arena.get("hud")
	var p: Fighter = arena.get("player")
	var plate := HudLayout.weapon_repick(hud.layout.weapons, hud.size)
	var tapped := hud._widget_at(plate.get_center(), hud.size)
	var middle := hud._widget_at(HudLayout.weapon_slots(hud.layout.weapons, hud.size)[1].get_center(), hud.size)
	arena.call("repick")
	var opened := hud.panels.pick_open
	hud.panels.select("sg")
	hud.panels.finish_pick()
	var b: Fighter = arena.get("bot")
	_expect(tapped == "weapons:repick" and middle == "weapons:1" and opened and p.gun().id == "sg" and b.gun().id == "sg"
			and p.sidearm() != null and p.sidearm().id == Weapons.SIDEARM,
		"the dummy's CHANGE GUN plate reopens the pick in the fight, the sidearm kept (%s, %s, %s, %s)" % [tapped, middle, opened, p.gun().id])
	Game.practice = false


## Calls on_frame once a frame after every other node's _process (what that frame draws).
class Sampler extends Node:
	var on_frame: Callable

	func _ready() -> void:
		process_priority = 1000

	func _process(_delta: float) -> void:
		on_frame.call()


func _walls() -> int:
	return get_tree().get_nodes_in_group("shield_walls").size()


func _grenades() -> int:
	var n := 0
	for c in get_tree().current_scene.get_children():
		if c is Grenade:
			n += 1
	return n
