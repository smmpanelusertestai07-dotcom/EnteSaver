extends Node
## Animation integration check (runs inside the game, headless is fine):
##   godot --headless --path . -- --autotest=script:res://tests/anim_check.gd
## - every extra clip is merged into the character's player
## - the base-clip toe fix holds and is applied once (clips are shared by all characters)
## - weapon swap changes the model at the lowest point of the clip, not at once
## - hit flinches are rate limited
## - a thrown grenade leaves the hand at the release frame, not on the input
## Prints "ANIM CHECK DONE bad=N" and exits with N.

var bad := 0
var at: Node


func run(autotest: Node) -> int:
	at = autotest
	await at.wait(0.5)
	_check_clips_and_toes()
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


func _walls() -> int:
	return get_tree().get_nodes_in_group("shield_walls").size()


func _grenades() -> int:
	var n := 0
	for c in get_tree().current_scene.get_children():
		if c is Grenade:
			n += 1
	return n
