extends Node
## HUD screenshot tour:
##   tools/qa/capture.sh <out_dir> 1560x720 script:res://tests/shots_hud.gd
## Prep with the weapon pick panel (pick + SELECT by touch), PREPARE countdown, round banner,
## the bot in view (red crosshair), firing (damage numbers, hit marker), red-dot ADS, reload ring,
## fists, sniper scope, sprint (stick past the ring and the button), the settings gear,
## scoreboard, healing, low HP with damage arcs, the elimination (red X, badge, kill feed) and
## the HUD editor (select + drag). Returns 0, or 1 if a check failed.

var _fails := 0


func run(at: Node) -> int:
	Game.settings.difficulty = 0
	Game.settings.damage_numbers = true
	Game.settings.reload_on_crosshair = true
	Game.settings.left_fire = 0
	await at.wait(1.5)            # let the lobby finish starting before switching scenes
	Game.goto_arena()
	await at.wait(1.0)
	var arena: Node = at.get_tree().current_scene
	var hud: HUD = arena.get("hud")
	var p: Player = arena.get("player")
	var b: Bot = arena.get("bot")
	var vs: Vector2 = hud.size
	# Hold the prep while the pick panel is looked at.
	arena.set("prep_left", 40.0)
	hud.panels.pick_left = 30.0
	await at.wait(0.5)
	await at.shot("hud_01_pick")
	_check(hud.panels.pick_open, "pick panel open in prep", at)
	await _tap(at, hud.panels.card_rect(1).get_center())
	await at.wait(0.3)
	await at.shot("hud_02_pick_smg")
	_check(hud.panels.pick_choice == "smg", "card tap selects the SMG", at)
	await _tap(at, hud.panels.select_rect().get_center())
	await at.wait(0.4)
	_check(String(arena.get("picked_weapon")) == "smg" and not hud.panels.pick_open, "SELECT applies the pick", at)
	arena.set("prep_left", 4.6)
	await at.wait(0.7)
	await at.shot("hud_03_prepare")
	await at.wait_for_phase(arena, 1)
	await at.wait(0.45)
	await at.shot("hud_04_round_banner")
	# Bot in clear view ahead, standing still (the capture box runs slowly: wait for the banner).
	b.frozen = true
	var t := 0.0
	while float(hud._round_banner.t) > 0.0 and t < 10.0:
		await at.wait(0.2)
		t += 0.2
	if not await _place_bot(at, arena, p, b):
		_check(false, "found a spot with the bot in sight", at)
	for i in 4:
		_aim_at(p, b.chest_position())
		await at.wait(0.1)
	await at.shot("hud_05_on_target")
	_check(p.crosshair_on_target, "crosshair turns red on the bot", at)
	# Fire with the right fire button (drag-aim keeps it on the bot).
	var fire_c := HudLayout.center(hud.layout.fire_r, vs)
	_touch(at, 5, fire_c, true)
	for i in 9:
		b.hp = maxf(b.hp, 150.0)      # keep the bot standing for the rest of the tour
		_aim_at(p, b.chest_position() + Vector3(0, 0.05 * sin(i), 0))
		_drag(at, 5, fire_c + Vector2(1, 0), Vector2(1, 0))
		await at.wait(0.06)
	await at.shot("hud_06_firing")
	_touch(at, 5, fire_c, false)
	await at.wait(0.3)
	b.hp = maxf(b.hp, 150.0)
	_check(int(p.stats.hits) > 0, "shots hit the bot", at)
	# Red-dot ADS.
	p.toggle_ads()
	for i in 5:
		_aim_at(p, b.chest_position())
		await at.wait(0.1)
	await at.shot("hud_07_ads_reddot")
	p.toggle_ads()
	# Reload ring on the crosshair.
	p.weapons[0].ammo = 2
	p.do_reload()
	await at.wait(0.7)
	await at.shot("hud_08_reload")
	await at.wait(2.0)
	# Fists.
	await _tap(at, HudLayout.weapon_slots(hud.layout.weapons, vs)[2].get_center())
	await at.wait(0.4)
	await at.shot("hud_09_fists")
	_check(p.current == 1, "fist slot selects the fists", at)
	await _tap(at, HudLayout.weapon_main(hud.layout.weapons, vs).get_center())
	await at.wait(0.3)
	# Sniper scope.
	p.set_loadout("sniper")
	await at.wait(0.8)
	# The first-person scope camera still sees the player's own head (integrator note), so the
	# tour hides the model to show the scope overlay over the hall.
	p.model.visible = false
	p.toggle_ads()
	for i in 6:
		_aim_at(p, b.chest_position())
		await at.wait(0.1)
	await at.shot("hud_10_sniper_scope")
	_check(p.is_scoped(), "sniper is scoped", at)
	p.toggle_ads()
	p.model.visible = true
	await at.wait(0.3)
	# Sprint: push the floating stick up past its ring (run mode drag / mixed), then the button.
	Game.settings.run_mode = 2
	var home := p.global_position
	var jc := Vector2(vs.x * 0.16, vs.y * 0.72)
	var jr := HudLayout.radius(hud.layout.joystick, vs)
	_touch(at, 2, jc, true)
	await at.wait(0.05)
	for i in 8:
		_drag(at, 2, jc + Vector2(0, -jr * 1.4 * minf(1.0, (i + 1) / 3.0)), Vector2(0, -jr * 0.45))
		await at.wait(0.08)
	await _until(at, func() -> bool: return p.sprinting, 3.0)
	await at.shot("hud_11_sprint_drag")
	_check(p.sprinting, "pushing the stick past the ring sprints", at)
	_touch(at, 2, jc + Vector2(0, -jr * 1.4), false)
	await at.wait(0.25)
	_check(not p.sprinting, "letting go of the stick stops the sprint", at)
	await _tap(at, HudLayout.center(hud.layout.sprint, vs))
	await _until(at, func() -> bool: return p.sprinting, 3.0)
	_check(p.sprinting and p.move_dir.y > 0.5, "sprint button runs forward", at)
	await _tap(at, HudLayout.center(hud.layout.sprint, vs))
	await at.wait(0.25)
	_check(not p.sprinting, "second tap on sprint stops it", at)
	p.global_position = home
	# Settings gear opens the pause menu (closed again right away).
	await _tap(at, HudLayout.center(hud.layout.settings, vs))
	await at.wait(0.3)
	_check(at.get_tree().paused, "settings button opens the pause menu", at)
	for n in (arena.get("pause_layer") as Node).get_children():
		n.queue_free()
	at.get_tree().paused = false
	hud.reload_layout()
	await at.wait(0.3)
	# Scoreboard (button), then close it.
	await _tap(at, HudLayout.center(hud.layout.scoreboard, vs))
	await at.wait(0.5)
	await at.shot("hud_12_scoreboard")
	_check(hud.panels.board_open, "scoreboard opens", at)
	await _tap(at, hud.panels.board_close_rect().get_center())
	await at.wait(0.2)
	_check(not hud.panels.board_open, "scoreboard closes", at)
	# Healing.
	p.hp = 110.0
	p.use_medkit()
	await at.wait(1.5)
	await at.shot("hud_13_heal")
	p.cancel_heal()
	# Low HP with damage from two sides.
	p.hp = 46.0
	p.damaged.emit(14.0, b.global_position, false, b)
	p.damaged.emit(9.0, p.global_position + p.global_basis.x * 6.0, false, b)
	await at.wait(0.25)
	await at.shot("hud_14_low_hp")
	# Elimination: sniper headshot (hold fire = scope in, release = shot).
	p.hp = 150.0
	b.hp = 120.0
	_touch(at, 6, fire_c, true)
	for i in 6:
		_aim_at(p, b.head_position())
		await at.wait(0.08)
	_touch(at, 6, fire_c, false)
	await at.wait(0.35)
	await at.shot("hud_15_kill")
	_check(not b.alive, "the bot is eliminated", at)
	await at.wait(1.0)
	await at.shot("hud_16_kill_late")
	# HUD editor.
	Game.goto_hud_editor()
	await at.wait(1.2)
	await at.shot("hud_17_editor")
	var ed := at.get_tree().current_scene
	var eh: HUD = ed.get("hud")
	var c := HudLayout.center(eh.layout.jump, eh.size)
	_touch(at, 3, c, true)
	await at.wait(0.1)
	for i in 6:
		_drag(at, 3, c + Vector2(-14.0 * (i + 1), -10.0 * (i + 1)), Vector2(-14, -10))
		await at.wait(0.05)
	_touch(at, 3, c + Vector2(-84, -60), false)
	await at.wait(0.3)
	await at.shot("hud_18_editor_drag")
	_check(eh.selected_id == "jump", "editor selects the dragged control", at)
	at.log_line("HUD TOUR fails=%d" % _fails)
	return 1 if _fails > 0 else 0


## Moves the player to the mouth of the spawn alcove and the bot to a nav point in plain sight.
func _place_bot(at: Node, arena: Node, p: Player, b: Bot) -> bool:
	var fwd := -p.global_basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	p.global_position = arena.call("closest_nav_point", p.global_position + fwd * 4.0)
	await at.wait(0.2)
	for dist in [10.0, 8.0, 12.0, 7.0, 14.0]:
		for ang in [0.0, 0.2, -0.2, 0.4, -0.4]:
			b.global_position = arena.call("closest_nav_point", p.global_position + fwd.rotated(Vector3.UP, ang) * dist)
			await at.wait(0.12)
			if p.can_see(b.chest_position()) and p.can_see(b.head_position()) and p.global_position.distance_to(b.global_position) > 5.0:
				return true
	return false


## Waits until cond() is true (the capture box can run far below real time).
func _until(at: Node, cond: Callable, timeout: float) -> void:
	var t := 0.0
	while not cond.call() and t < timeout:
		await at.wait(0.1)
		t += 0.1


## The autotest helpers take window pixels; HUD rects are in the (stretched) viewport.
func _touch(at: Node, index: int, pos: Vector2, pressed: bool) -> void:
	at.touch(index, at.get_tree().root.get_final_transform() * pos, pressed)


func _drag(at: Node, index: int, pos: Vector2, rel: Vector2) -> void:
	var xf: Transform2D = at.get_tree().root.get_final_transform()
	at.drag(index, xf * pos, xf.basis_xform(rel))


func _tap(at: Node, pos: Vector2) -> void:
	_touch(at, 7, pos, true)
	await at.wait(0.05)
	_touch(at, 7, pos, false)
	await at.wait(0.05)


func _aim_at(p: Player, target: Vector3) -> void:
	var dir := (target - p.camera.global_position).normalized()
	p.aim_yaw = atan2(-dir.x, -dir.z) - deg_to_rad(p.recoil_yaw)
	p.aim_pitch = asin(clampf(dir.y, -1.0, 1.0)) - deg_to_rad(p.recoil_pitch)


func _check(ok: bool, what: String, at: Node) -> void:
	if not ok:
		_fails += 1
	at.log_line(("ok: " if ok else "FAIL: ") + what)
