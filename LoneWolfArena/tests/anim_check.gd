extends Node
## Animation integration check (runs inside the game, headless is fine):
##   godot --headless --path . -- --autotest=script:res://tests/anim_check.gd
## - every extra clip is merged into the character's player
## - the hip carry: standing without a shot for Character.READY_HOLD s the gun hangs low in the
##   right hand (carry_idle, carry_run_a/b on the arms while moving), a shot or the aim puts it on
##   the crosshair at once and shots leave from the aim pose's muzzle (also the first one on the
##   way up, after a crouch or prone, at any pitch); the sprint plays sprint_fwd
##   at the speed it was made for (no foot sliding) and stops with the sprint
## - an online opponent's jump plays the take-off, a step off a ledge the fall
## - the base-clip toe fix holds and is applied once (clips are shared by all characters)
## - procedural layers: the lean into a running turn, the sprint's forward bend, the lobby's look
##   round (and none of it after the lobby)
## - weapon swap changes the model at the lowest point of the clip, not at once
## - hit flinches are rate limited
## - a thrown grenade leaves the hand at the release frame, not on the input
## - at more frames than physics ticks the camera and the own model move between ticks
## - free look with no button: standing still a drag takes the camera round to the character's
##   face and the body stays; firing turns the body to the crosshair at once; moving turns it back
##   and a drag while running turns the run; the eye button (when on) still turns only the camera;
##   at 120 FPS with fewer physics ticks the held body's drawn yaw stays fixed while the camera turns
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
	_check_procedural_layers()
	await _check_carry_and_sprint()
	await _check_carry_muzzle()
	_check_remote_jump()
	_check_stance_clips()
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
	for clip in ["reload", "pump", "heal", "throw", "swap", "hit_react", "prone_idle", "prone_fwd", "punch_r", "punch_l",
			"carry_idle", "carry_run_a", "carry_run_b", "sprint_fwd", "jump_air", "jump_land", "victory_pose", "prone_up",
			"lobby_hip", "lobby_shift", "lobby_look"]:
		_expect(m1.anim.has_animation(clip), "clip merged: " + clip)
	var toe1 := _lowest_toe(m1, "run_fwd")
	var m2 := _model()      # second character: must not flip the shared clips back
	var toe2 := _lowest_toe(m2, "run_fwd")
	_expect(toe1 > -0.035, "run_fwd toes stay above the floor (lowest tip %.3f m)" % toe1)
	_expect(absf(toe1 - toe2) < 0.002, "toe fix applied once (second model %.3f m)" % toe2)
	for clip in ["crouch_fwd", "prone_fwd", "reload", "sprint_fwd", "carry_idle", "runx_fwd", "runx_left", "runx_right", "runx_back",
			"jump_land", "prone_up", "victory_pose", "lobby_hip", "lobby_shift", "lobby_look"]:
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


## On top of the clips: a running body leans into its turn (a roll about the feet toward the inside,
## none standing or crouched), a sprint bends the chest forward, the lobby's idle looks round
## with the head and leaves no twist behind once the model leaves the lobby.
func _check_procedural_layers() -> void:
	var m := _model()
	var dt := 1.0 / 60.0
	for _i in 40:
		m.rotation.y += 2.0 * dt                    # turning left at 2 rad/s
		m.update_locomotion(Vector2(0, Fighter.RUN_SPEED), Fighter.Stance.STAND, true, dt)
	var lean_left := m.root_scene.rotation.z
	for _i in 60:
		m.rotation.y -= 2.0 * dt
		m.update_locomotion(Vector2(0, Fighter.RUN_SPEED), Fighter.Stance.STAND, true, dt)
	var lean_right := m.root_scene.rotation.z
	for _i in 60:
		m.rotation.y += 2.0 * dt
		m.update_locomotion(Vector2.ZERO, Fighter.Stance.STAND, true, dt)
	var still := m.root_scene.rotation.z
	_expect(lean_left < -0.05 and lean_right > 0.05 and absf(still) < 0.01,
		"a running turn leans into it (left %.2f, right %.2f), turning on the spot does not (%.2f)" % [lean_left, lean_right, still])
	m.sprint = true
	for _i in 60:
		m.update_locomotion(Vector2(0, Fighter.SPRINT_SPEED), Fighter.Stance.STAND, true, dt)
	var bend := m.aim_mod.kick
	m.sprint = false
	for _i in 60:
		m.update_locomotion(Vector2(0, Fighter.RUN_SPEED), Fighter.Stance.STAND, true, dt)
	_expect(bend < -0.1 and absf(m.aim_mod.kick) < 0.01, "a sprint bends the chest forward (%.2f), a run does not (%.2f)" % [bend, m.aim_mod.kick])
	m.play_lobby(true)
	m._gesture_in = 0.0
	m._lobby_cheer = false
	for _i in 90:
		m._process(dt)
	_expect(absf(m.aim_mod.twist) > 0.3, "the lobby idle looks round (%.2f rad)" % m.aim_mod.twist)
	m.revive()
	_expect(m.aim_mod.twist == 0.0 and m.anim.speed_scale == 1.0, "no look round or pace change after the lobby")
	m.queue_free()


## anims_extra2's one-shots: a jump plays jump_air from its take-off, walking off a ledge from its
## fall; a touch-down standing still plays jump_land (no crouch dip), running it is the dip; standing
## up from prone plays prone_up (about 1 s), which moving cuts short; the results' victory pose
## and the lobby's gesture clips.
func _check_stance_clips() -> void:
	var m := _model()
	m.equip_weapon("weapon_ar")
	var dt := 1.0 / 60.0
	for _i in 30:
		m.update_locomotion(Vector2.ZERO, Fighter.Stance.STAND, true, dt)
	_expect(String((m.tree.tree_root as AnimationNodeBlendTree).get_node("jump").get("animation")) == "jump_air", "the air layer plays jump_air")
	m.on_jump()
	_expect(m._jumped and m._air >= 0.5, "a jump goes straight into the take-off")
	for _i in 40:
		m.update_locomotion(Vector2.ZERO, Fighter.Stance.STAND, false, dt)
	m.update_locomotion(Vector2.ZERO, Fighter.Stance.STAND, true, dt)
	_expect(m._land_clip and int(m.tree.get("parameters/jump_land_shot/request")) == AnimationNodeOneShot.ONE_SHOT_REQUEST_FIRE,
		"a touch-down standing still plays jump_land")
	var dip := 0.0
	for _i in 30:
		m.update_locomotion(Vector2.ZERO, Fighter.Stance.STAND, true, dt)
		dip = maxf(dip, float(m.tree.get("parameters/crouch_blend/blend_amount")))
	_expect(dip < 0.01, "and no crouch dip on top of it (%.2f)" % dip)
	for _i in 40:
		m.update_locomotion(Vector2(0, Fighter.RUN_SPEED), Fighter.Stance.STAND, false, dt)
	m.update_locomotion(Vector2(0, Fighter.RUN_SPEED), Fighter.Stance.STAND, true, dt)
	dip = 0.0
	for _i in 20:
		m.update_locomotion(Vector2(0, Fighter.RUN_SPEED), Fighter.Stance.STAND, true, dt)
		dip = maxf(dip, float(m.tree.get("parameters/crouch_blend/blend_amount")))
	_expect(not m._land_clip and dip > 0.2, "a touch-down running bends the knees in step (dip %.2f), no landing clip" % dip)
	for _i in 60:
		m.update_locomotion(Vector2.ZERO, Fighter.Stance.PRONE, true, dt)
	m.update_locomotion(Vector2.ZERO, Fighter.Stance.STAND, true, dt)
	var up_len := m.anim.get_animation("prone_up").length
	_expect(m.standing_up() and up_len > 0.8 and up_len < 1.2, "prone -> stand plays prone_up (%.2f s)" % up_len)
	for _i in 10:
		m.update_locomotion(Vector2(0, Fighter.RUN_SPEED), Fighter.Stance.STAND, true, dt)
	_expect(not m.standing_up(), "moving cuts the stand-up short")
	m.play_victory("victory_pose")
	_expect(m.anim.current_animation == "victory_pose" and not m.tree.active, "the results' victory pose plays")
	m.revive()
	m.play_lobby()
	m._gesture_in = 0.0
	m._process(dt)                  # first gesture: the look round
	m._look_to = 0.0
	m._look = 0.0
	m._gesture_in = 0.0
	m._process(dt)                  # second: a gesture clip
	_expect(String(m.anim.current_animation) in CharacterModel.LOBBY_GESTURES, "the lobby plays a gesture clip (%s)" % m.anim.current_animation)
	m.revive()
	m.queue_free()


## The reference's hip carry and sprint (anims_extra2).
func _check_carry_and_sprint() -> void:
	var m := _model()
	m.equip_weapon("weapon_ar")
	var dt := 1.0 / 60.0
	for _i in 10:
		m.update_locomotion(Vector2.ZERO, Fighter.Stance.STAND, true, dt)
		await get_tree().process_frame
	_expect(m.gun_up() and m._carry < 0.05, "a new model starts with the gun up (it learns the grip)")
	var aimed_muzzle := m.muzzle_position()
	var aimed_y := m.weapon_node.global_position.y
	m._ready_until = 0.0
	for _i in 40:
		m.update_locomotion(Vector2.ZERO, Fighter.Stance.STAND, true, dt)
		await get_tree().process_frame
	var idle_mix := float(m.tree.get("parameters/loco/idle/carry/blend_amount"))
	var gun := m.weapon_node
	var barrel := -gun.global_basis.z
	var fwd := -m.global_basis.z
	_expect(m._carry > 0.99 and idle_mix > 0.99, "no shot for a while: the relaxed carry_idle plays (%.2f)" % idle_mix)
	_expect(gun.global_position.y < aimed_y - 0.25 and barrel.y < -0.4 and Vector3(barrel.x, 0, barrel.z).normalized().dot(fwd) > 0.95,
		"the gun hangs low by the hip, muzzle down-forward (%.2f m lower, barrel %s)" % [aimed_y - gun.global_position.y, barrel])
	var hand := m.bone_position("hand_r")
	_expect(gun.global_position.distance_to(hand) < 0.12, "the carried gun stays in the right hand (%.3f m)" % gun.global_position.distance_to(hand))
	_expect(m.muzzle_position().distance_to(aimed_muzzle) < 0.05, "a shot from the carry leaves from the aim pose's muzzle")
	m.set_aim(0.0, -m.global_basis.z)
	m.place_gun()
	_expect((-gun.global_basis.z).dot(-m.global_basis.z) > 0.99 and m.gun_up(), "FIRE: the gun points along the aim at once")
	_expect(m.muzzle_position().distance_to(aimed_muzzle) < 0.05,
		"and that first shot leaves from the aim pose's muzzle, not the hip (%.3f m off)" % m.muzzle_position().distance_to(aimed_muzzle))
	for _i in 12:
		m.update_locomotion(Vector2.ZERO, Fighter.Stance.STAND, true, dt)
		await get_tree().process_frame
	_expect(m._carry < 0.01 and gun.global_position.y > aimed_y - 0.05, "and the arms are up in the aim pose 0.2 s later")
	m.aiming = true
	m._ready_until = 0.0
	for _i in 30:
		m.update_locomotion(Vector2.ZERO, Fighter.Stance.STAND, true, dt)
	_expect(m._carry < 0.01, "scoped in, the gun stays up")
	m.aiming = false
	# Moving relaxed: the arms layer carries the gun and swings the free arm with the stride.
	for _i in 60:
		m.update_locomotion(Vector2(0, Fighter.RUN_SPEED), Fighter.Stance.STAND, true, dt)
	_expect(float(m.tree.get("parameters/carry_blend/blend_amount")) > 0.95, "running relaxed: the carry arms are on")
	# The sprint: sprint_fwd at the speed it was made for, its feet as fast as the body.
	m.sprint = true
	for _i in 60:
		m.update_locomotion(Vector2(0, Fighter.SPRINT_SPEED), Fighter.Stance.STAND, true, dt)
	var sb := float(m.tree.get("parameters/sprint_blend/blend_amount"))
	var feet := float(m.tree.get("parameters/sprint_ts/scale")) * CharacterModel.SPRINT_AUTHORED
	_expect(sb > 0.99 and absf(feet - m._speed) / m._speed < 0.03,
		"sprinting: sprint_fwd plays (%.2f), its feet at %.2f m/s for a body at %.2f m/s" % [sb, feet, m._speed])
	_expect(float(m.tree.get("parameters/carry_blend/blend_amount")) < 0.01 and m._carry_gun > 0.99,
		"the sprint's own arms pump (no carry layer), the gun in the hand")
	m.sprint = false
	for _i in 30:
		m.update_locomotion(Vector2(0, Fighter.RUN_SPEED), Fighter.Stance.STAND, true, dt)
	_expect(float(m.tree.get("parameters/sprint_blend/blend_amount")) < 0.01, "the sprint cycle stops with the sprint")
	m.queue_free()


## Carried after a crouch or prone, or at another pitch, a shot still leaves from where the aim
## pose's muzzle is now (bots and online opponents read muzzle_position before raising the gun).
func _check_carry_muzzle() -> void:
	var m := _model()
	m.equip_weapon("weapon_ar")
	var dt := 1.0 / 60.0
	var steps := func(n: int, v: Vector2, stance: int) -> void:
		for _i in n:
			m.update_locomotion(v, stance, true, dt)
			await get_tree().process_frame
	var fresh := func(pitch: float) -> Vector3:
		m.aiming = true
		m.set_aim(pitch, (-m.global_basis.z).rotated(m.global_basis.x, pitch))
		await steps.call(40, Vector2.ZERO, Fighter.Stance.STAND)
		m.aiming = false
		return m.muzzle_position()
	var level: Vector3 = await fresh.call(0.0)
	var up: Vector3 = await fresh.call(0.5)
	var cases := [["crouch", Fighter.Stance.CROUCH, Vector2.ZERO], ["prone", Fighter.Stance.PRONE, Vector2(0, Fighter.RUN_SPEED)]]
	for c: Array in cases:
		m.set_aim(0.0, -m.global_basis.z)
		m._ready_until = Time.get_ticks_msec() / 1000.0 + 5.0
		await steps.call(90, Vector2.ZERO, c[1])          # the gun up in that stance
		m._ready_until = 0.0
		await steps.call(90, c[2], Fighter.Stance.STAND)   # standing (running) and carried a while
		var dy := absf(m.muzzle_position().y - level.y)
		_expect(m._carry > 0.5 and dy < 0.15, "carried after %s: the shot's muzzle is at the standing aim's height (%.3f m off)" % [c[0], dy])
		await steps.call(30, Vector2.ZERO, Fighter.Stance.STAND)
		var off := m.muzzle_position().distance_to(level)
		_expect(m._carry > 0.9 and off < 0.05, "and standing still carried, at the standing aim muzzle (%.3f m off)" % off)
	m.set_aim(0.5, (-m.global_basis.z).rotated(m.global_basis.x, 0.5))
	await steps.call(5, Vector2.ZERO, Fighter.Stance.STAND)
	var off_up := m.muzzle_position().distance_to(up)
	_expect(m._carry > 0.9 and off_up < 0.08, "carried, aiming up: the muzzle follows the pitch (%.3f m off)" % off_up)
	m.queue_free()


## An online opponent's jump plays the take-off (a rise off the floor), a step off a ledge the fall.
func _check_remote_jump() -> void:
	var r := RemoteFighter.new()
	r.process_mode = Node.PROCESS_MODE_DISABLED
	add_child(r)
	r.setup_fighter("default", "ar")
	var st := RemoteFighter.pack(r)
	st[0] = 0.0
	st[1] = 1.0
	st[2] = 0.0
	st[6] = 8.0
	r.apply_state(st)
	st[1] = 1.15
	st[6] = 0.0
	r.apply_state(st)
	_expect(r.model._jumped, "an online opponent rising off the floor: its jump plays the take-off")
	r.model._jumped = false
	st[6] = 8.0
	r.apply_state(st)
	st[1] = 1.1
	st[6] = 0.0
	r.apply_state(st)
	_expect(not r.model._jumped, "stepping off a ledge (no rise): the fall pose, no take-off")
	r.free()


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
	await _check_free_look(arena, p as Player)
	_check_pick_keeps_governor(arena)
	_check_bullet_holes(arena, p)
	_check_frag_feed(arena, p)
	await _check_dummy_gun_change()


## The wall and grenade buttons only take the item in hand; FIRE uses it when let go, the same
## button again or a weapon puts it away, and a hand with an item never shoots.
func _check_items_in_hand(p: Player) -> void:
	# QUICK WALL (the default since round 8): one tap places the wall at once, the gun stays.
	p.shields = 1
	var walls0 := _walls()
	var gun := p.current
	p.use_shield()
	await get_tree().process_frame
	_expect(p.ready_item == "" and p.shields == 0 and _walls() == walls0 + 1 and p.current == gun, "QUICK WALL: one tap places the wall, the gun stays in hand")
	# QUICK WALL off: the wall button takes the wall in hand, FIRE places it.
	var quick: Variant = Game.settings.get("wall_quick", true)
	Game.settings.wall_quick = false
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
	Game.settings.wall_quick = quick
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


## The reference's default camera (no eye button): standing still a look drag turns the camera
## and the aim round the character, which keeps its facing (its face can be seen) and does not turn
## back; FIRE turns the body to the crosshair at once and the shots leave along it; the stick turns
## it back and runs away from the camera; a drag while running turns the run, not only the camera.
## The eye button (setting Free look button) still turns only the camera and snaps back on FIRE.
func _check_free_look(arena: Node, p: Player) -> void:
	var hud: Node = arena.get("hud")
	hud.process_mode = Node.PROCESS_MODE_DISABLED      # (its stick would reset move_dir)
	var others: Array = []
	for f: Fighter in arena.get("fighters"):
		if f != p:
			others.append([f, f.frozen])
			f.frozen = true
	p.assist_on = false
	p.move_dir = Vector2.ZERO
	p.global_position = arena.call("closest_nav_point", arena.get("zone_center"))
	await at.wait(0.5)
	var vh := get_viewport().get_visible_rect().size.y
	var px_per_deg := vh / 130.0 / (maxf(float(Game.settings.sens_general), 1.0) / 100.0)
	await _check_free_look_frames(arena, p, px_per_deg)
	p.face_aim()
	await get_tree().process_frame
	var body0 := _model_fwd(p)
	var aim0 := p.aim_yaw
	for i in 12:                                    # 180 degrees in a dozen drag events
		p.add_look(Vector2(-15.0 * px_per_deg, 0.0))
		await get_tree().process_frame
	await get_tree().process_frame
	var cam_fwd := -p.camera.global_basis.z
	_expect(absf(wrapf(p.aim_yaw - aim0 - PI, -PI, PI)) < 0.05, "standing: the drag turned the camera and aim 180 degrees")
	_expect(_model_fwd(p).dot(body0) > 0.99, "standing: the body kept its facing (%.2f)" % _model_fwd(p).dot(body0))
	_expect(_flat(cam_fwd).dot(_model_fwd(p)) < -0.95, "standing: the camera looks at the character's face")
	var gun: Node3D = p.model.weapon_node
	var has_gun := gun != null and gun.top_level
	_expect(not has_gun or _flat(-gun.global_basis.z).dot(_model_fwd(p)) > 0.95,
		"standing: the held body's gun points where the body faces, not along the camera")
	await at.wait(1.5)
	_expect(_model_fwd(p).dot(body0) > 0.99, "standing: the body does not turn back by itself")
	var ammo := p.weapon().ammo
	p.set_firing(true)
	_expect(absf(p.body_turn) < 0.001 and _model_fwd(p).dot(_flat(p.aim_forward())) > 0.99, "FIRE turns the body to the crosshair at once")
	_expect(not has_gun or (-gun.global_basis.z).dot(p.aim_forward()) > 0.99, "and its gun along the crosshair at once")
	_expect(_flat(-p.camera.global_basis.z).dot(_flat(cam_fwd)) > 0.99, "FIRE keeps the camera where it was")
	await at.wait(0.3)
	p.set_firing(false)
	_expect(p.weapon().ammo < ammo and (-p.camera.global_basis.z).dot(p.aim_forward()) > 0.97, "the shots leave along the crosshair")
	await at.wait(0.4)
	for i in 6:                                     # 90 degrees round again, then the stick
		p.add_look(Vector2(-15.0 * px_per_deg, 0.0))
		await get_tree().process_frame
	_expect(absf(p.body_turn) > 1.4, "standing: turned away again (%.2f rad)" % p.body_turn)
	var start := p.global_position
	for i in 30:
		p.move_dir = Vector2(0, 1)
		await get_tree().physics_frame
	await get_tree().process_frame
	var ran := _flat(p.global_position - start)
	_expect(absf(p.body_turn) < 0.05, "the stick turns the body back to the aim (%.2f rad)" % p.body_turn)
	_expect(ran.length() > 0.5 and ran.normalized().dot(_flat(-p.camera.global_basis.z)) > 0.9, "and it runs away from the camera")
	var run_yaw := p.aim_yaw
	for i in 4:                                     # 60 degrees while running
		p.move_dir = Vector2(0, 1)
		p.add_look(Vector2(-15.0 * px_per_deg, 0.0))
		await get_tree().physics_frame
	for i in 20:
		p.move_dir = Vector2(0, 1)
		await get_tree().physics_frame
	await get_tree().process_frame
	var v := _flat(p.velocity)
	_expect(absf(wrapf(p.aim_yaw - run_yaw - deg_to_rad(60.0), -PI, PI)) < 0.05 and absf(p.body_turn) < 0.05,
		"running: a drag turns the run with the camera (the back stays to it)")
	_expect(v.length() > 0.3 and v.normalized().dot(_flat(p.aim_forward())) > 0.9, "running: the run follows the new direction (%.1f m/s, %.2f)" % [v.length(), v.normalized().dot(_flat(p.aim_forward()))])
	# The eye button (an option): only the camera turns, the run and the aim stay; FIRE snaps it back.
	var was_btn: Variant = Game.settings.get("freelook_button", false)
	Game.settings["freelook_button"] = true
	_expect(hud.call("_button_visible", "freelook"), "the eye button shows when the setting is on")
	var keep := p.aim_yaw
	p.start_free_look()
	for i in 6:
		p.move_dir = Vector2(0, 1)
		p.add_free_look(Vector2(-20.0 * px_per_deg, 0.0))
		await get_tree().physics_frame
	await get_tree().process_frame
	_expect(p.aim_yaw == keep and p.is_free_looking() and absf(wrapf(p.yaw_node.rotation.y - keep, -PI, PI)) > 0.5,
		"eye button: the camera turns, the aim and the run stay")
	p.set_firing(true)
	await get_tree().process_frame
	_expect(not p.is_free_looking() and absf(wrapf(p.yaw_node.rotation.y - p.aim_yaw, -PI, PI)) < 0.05, "eye button: FIRE snaps the camera back")
	p.set_firing(false)
	p.end_free_look()
	Game.settings["freelook_button"] = was_btn
	_expect(not hud.call("_button_visible", "freelook") or bool(was_btn), "the eye button is off again by default")
	p.move_dir = Vector2.ZERO
	p.assist_on = true
	for pair in others:
		(pair[0] as Fighter).frozen = bool(pair[1])
	hud.process_mode = Node.PROCESS_MODE_INHERIT


## At more frames than physics ticks a second (90 / 120 FPS) a drag on every frame turns the
## camera round the held body on every frame, and the body's drawn world yaw does not move at all
## (it used to step back by a frame's drag on the frames without a tick and forward at the tick).
func _check_free_look_frames(arena: Node, p: Player, px_per_deg: float) -> void:
	var fps := Engine.max_fps
	var ticks := Engine.physics_ticks_per_second
	Engine.max_fps = 120
	Engine.physics_ticks_per_second = 20        # several frames to each tick, even on a slow machine
	await get_tree().physics_frame
	await get_tree().process_frame
	var frames: Array = []                      # [physics frames, body yaw, camera yaw] as drawn
	var sampler := Sampler.new()
	sampler.on_frame = func() -> void:
		var fwd := _model_fwd(p)
		var cam := _flat(-p.camera.global_basis.z)
		frames.append([Engine.get_physics_frames(), atan2(-fwd.x, -fwd.z), atan2(-cam.x, -cam.z), p.body_holds()])
	arena.add_child(sampler)
	await get_tree().process_frame
	for i in 36:                                # 3 degrees a frame: 108 degrees round
		p.add_look(Vector2(-3.0 * px_per_deg, 0.0))
		await get_tree().process_frame
	sampler.queue_free()
	Engine.physics_ticks_per_second = ticks
	Engine.max_fps = fps
	var no_tick := 0
	var cam_moved := 0
	var wobble := 0.0
	var held := true
	for i in range(1, frames.size()):
		held = held and bool(frames[i][3])
		wobble = maxf(wobble, absf(wrapf(float(frames[i][1]) - float(frames[0][1]), -PI, PI)))
		if int(frames[i][0]) == int(frames[i - 1][0]):
			no_tick += 1
			cam_moved += 1 if absf(wrapf(float(frames[i][2]) - float(frames[i - 1][2]), -PI, PI)) > deg_to_rad(1.0) else 0
	var turned := absf(wrapf(float(frames[-1][2]) - float(frames[0][2]), -PI, PI))
	_expect(held and no_tick > 0 and cam_moved >= no_tick * 0.8 and turned > deg_to_rad(90.0) and wobble < deg_to_rad(0.3),
		"free look at 120 FPS: the camera turns on frames between ticks (%d of %d, %.0f deg) and the held body stays (%.2f deg off)" % [cam_moved, no_tick, rad_to_deg(turned), rad_to_deg(wobble)])


## Where the drawn character faces (flat, world).
func _model_fwd(p: Player) -> Vector3:
	return _flat(-p.model.global_basis.z)


func _flat(v: Vector3) -> Vector3:
	return Vector3(v.x, 0.0, v.z).normalized()


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
