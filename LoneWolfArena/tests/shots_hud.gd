extends Node
## HUD screenshot tour:
##   tools/qa/capture.sh <out_dir> 1560x720 script:res://tests/shots_hud.gd
## Prep with the weapon pick panel (pick + SELECT by touch, the fists only until then; a later pick
## with guns on cooldown and the ROUNDS strip; the waiting side's read-only panel), PREPARE
## countdown, round banner,
## the bot in view (red crosshair; on the minimap its arrowhead, and the fading marks of shots fired
## out of sight), the quiet stage change of the 1 vs 1 (no band, no ZONE SHRINKING, no zone strip),
## the minimap turned with the view and NORTH UP, firing (each shot its own damage number, hit marker),
## separate damage numbers in a row (never on top of each other), red-dot ADS, the RELOAD button
## (grey on a full magazine) and the reload ring, the kit's three small slots with each one held
## (the gun, the WREN 9 sidearm with its rounds, the fists) and SWITCH's cycle through them, the
## sidearm's reload, the lever shotgun's
## own silhouette, sniper scope, sprint (stick past the ring and the
## button), the settings gear (over the weapon panel's corner; QUIT MATCH's question as online, back
## closing it), scoreboard (tap on the score bar,
## clear of the weapon panel), healing, low HP with
## damage arcs, the elimination (red X, badge, the 1 vs 1's one kill feed line with the gun), the ELIMINATED BY card (by the bot, by
## the zone), the break between rounds step by step (result band, score plates before and after
## the tick, the next round's band, then round 2's prep and fight with nothing over them) and the
## HUD editor (its minimap stand-in turned and north up; select + drag).
## Then DUO / SQUAD in TRAINING GROUND (team_tour, alone with LW_TOUR=team): the BLUE vs ORANGE prep
## line, the teammates panel and ally tags, a knocked teammate (marker on them and pinned to the
## edge), REVIVE (a real tap) and reviving, the player knocked (BLEEDING OUT, BEING REVIVED),
## spectating a teammate with NEXT, the scoreboard by team, the host's QUIT question and the team
## results of a SQUAD and a DUO; every team widget clear of the 1 vs 1 buttons, touch targets
## >= 56 px.
## Returns 0, or 1 if a check failed.

var _fails := 0


func run(at: Node) -> int:
	if OS.get_environment("LW_TOUR") == "team":
		Game.settings.difficulty = 0
		await at.wait(1.5)
		await team_tour(at)
		at.log_line("HUD TOUR fails=%d" % _fails)
		return 1 if _fails > 0 else 0
	Game.settings.difficulty = 0
	Game.settings.damage_numbers = true
	Game.settings.reload_on_crosshair = true
	Game.settings.show_fps = true           # the FPS counter under the minimap is part of the tour
	await at.wait(1.5)            # let the lobby finish starting before switching scenes
	Game.goto_arena()
	await at.wait(1.0)
	var arena: Node = at.get_tree().current_scene
	var hud: HUD = arena.get("hud")
	var p: Player = arena.get("player")
	var b: Bot = arena.get("bot")
	var vs: Vector2 = hud.size
	_check(hud.team == null and hud.get_node_or_null("HudTeam") == null, "a 1 vs 1 HUD has no team layer", at)
	# Hold the prep while the pick panel is looked at.
	arena.set("prep_left", 40.0)
	hud.panels.pick_left = 30.0
	await at.wait(0.5)
	await at.shot("hud_01_pick")
	_check(hud.panels.pick_open, "pick panel open in prep", at)
	_check(p.awaiting_pick and b.awaiting_pick and p.weapon().id == "fists" and b.weapon().id == "fists",
		"before the pick both fighters hold the fists only (not the last match's gun)", at)
	_check(hud.weapon_picking() == hud.panels.pick_choice, "the weapon panel shows the chosen gun dimmed while picking", at)
	_check(HudDraw.weapon_tex(Weapons.DEFS.lever) != HudDraw.weapon_tex(Weapons.DEFS.sg), "lever and pump shotguns have different silhouettes", at)
	var main0 := HudLayout.weapon_main(hud.layout.weapons, vs)
	_check(absf(main0.position.y / vs.y - 0.042) < 0.012 and absf(main0.end.y / vs.y - 0.147) < 0.012,
		"weapon panel main slot at y 0.042 .. 0.147 like the reference (%.3f .. %.3f)" % [main0.position.y / vs.y, main0.end.y / vs.y], at)
	await _tap(at, hud.panels.card_rect(1).get_center())
	await at.wait(0.3)
	await at.shot("hud_02_pick_smg")
	_check(hud.panels.pick_choice == "smg", "card tap selects the SMG", at)
	await _tap(at, hud.panels.select_rect().get_center())
	await at.wait(0.4)
	_check(String(arena.get("picked_weapon")) == "smg" and not hud.panels.pick_open, "SELECT applies the pick", at)
	# A later pick of the 1 vs 1: guns on cooldown greyed with the clock and "n ROUNDS", the ROUNDS
	# strip (blue: this player's picks); the preselection skips a resting gun, a tap on one does nothing.
	hud.open_weapon_pick(Weapons.PICKABLE, "ar", 30.0, func(_id: String) -> void: pass, {"ar": 2, "sniper": 4},
		RoundRules.picker_rows(9, true))
	hud.panels.pick_round = 5
	await at.wait(0.4)
	await at.shot("hud_02b_pick_cooldown")
	_check(hud.panels.pick_choice != "ar", "the preselection skips a gun on cooldown", at)
	var before := hud.panels.pick_choice
	await _tap(at, hud.panels.card_rect(0).get_center())
	_check(hud.panels.pick_choice == before, "a tap on a resting gun does not pick it", at)
	_check(hud.panels.card_rect(0).position.y > hud.panels.strip_disc(1).y, "the ROUNDS strip sits above the cards", at)
	hud.close_weapon_pick()
	# The side that does not pick (here staged: rounds 3-4 are the bot's): the same panel read-only,
	# the weapon panel PICKING... with the fists, until the pick lands.
	arena.set("picked_weapon", "")
	p.await_pick()
	b.await_pick()
	hud.watch_weapon_pick(Weapons.PICKABLE, 12.0, b.display_name, {"ar": 4, "sniper": 2}, RoundRules.picker_rows(9, true))
	hud.panels.pick_round = 3
	await at.wait(0.4)
	await at.shot("hud_02c_pick_watch")
	_check(hud.panels.watching() and hud.panels.pick_choice == "" and hud.weapon_picking() == "picking",
		"the waiting side watches the pick read-only, its weapon panel PICKING", at)
	await _tap(at, hud.panels.card_rect(2).get_center())
	_check(hud.panels.pick_choice == "" and hud.panels.watching(), "a tap on the watched panel picks nothing", at)
	arena.call("_apply_pick", "smg")
	await at.wait(0.3)
	_check(not hud.panels.pick_open and p.gun().id == "smg" and p.current == 0 and b.gun().id == "smg",
		"the watched panel closes once the pick lands, which equips its gun", at)
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
	# MINIMAP: the bot in sight is a red arrowhead pointing where it faces; shots fired out of sight
	# leave fading red marks where they were (never its live position).
	var mm_k := hud.minimap.size.x / HudMinimap.VIEW_M
	var marks := HudMinimap.enemy_marks(arena.get("fighters"), p, null, hud.seen, Transform2D(0.0, Vector2(mm_k, mm_k), 0.0, Vector2.ZERO))
	_check(marks.size() == 1 and (marks[0].dir as Vector2).is_equal_approx(Vector2(-sin(b.aim_yaw), -cos(b.aim_yaw))),
		"the minimap draws the bot in sight as an arrowhead facing its way", at)
	_check(HudMinimap.enemy_marks(arena.get("fighters"), p, null, {b: false}, Transform2D(0.0, Vector2(mm_k, mm_k), 0.0, Vector2.ZERO)).is_empty(),
		"out of sight the minimap shows no live position", at)
	hud.shot_heard(b)
	_check(hud.shots_heard.is_empty(), "a shot fired in sight leaves no mark (its arrowhead shows)", at)
	var seen_was := bool(hud.seen.get(b, false))
	hud.seen[b] = false
	var b_home := b.global_position
	for off: Vector3 in [Vector3(-3.5, 0, 2.0), Vector3(-2.0, 0, 4.0), Vector3(1.5, 0, 5.0)]:
		b.global_position = p.global_position + off
		hud.shot_heard(b)
	b.global_position = b_home
	hud.seen[b] = seen_was
	_check(hud.shots_heard.size() == 3 and is_equal_approx(float(hud.shots_heard[0].t), HUD.SHOT_SHOW),
		"shots fired out of sight leave marks for %.1f s" % HUD.SHOT_SHOW, at)
	await at.wait(0.5)
	await at.shot("hud_05b_minimap_marks")
	await _until(at, func() -> bool: return hud.shots_heard.is_empty(), 10.0)     # (game time: the capture box runs slowly)
	_check(hud.shots_heard.is_empty(), "the shot marks fade out after about 2 s", at)
	# A quiet stage change in the 1 vs 1: no SAFE ZONE SHRINKS IN band in stage 1's last seconds, no
	# ZONE SHRINKING line at the change; the clock just starts stage 2 and the zone closes in.
	var clock0 := [float(arena.get("elapsed")), float(arena.get("time_left")), float(arena.get("zone_radius")), arena.get("zone_center")]
	arena.set("zone_state", "stationary")
	arena.set("elapsed", RoundRules.STAGE1_S - 4.0)
	arena.set("time_left", float(arena.call("round_time")) - (RoundRules.STAGE1_S - 4.0))
	await at.wait(0.3)
	_check(String(arena.get("zone_warning")) == "" and String(arena.zone_state) == "stationary",
		"the 1 vs 1 shows no SAFE ZONE SHRINKS IN band before the stage change", at)
	await _until(at, func() -> bool: return String(arena.zone_state) != "stationary", 10.0)
	await at.wait(0.3)
	_check(String(arena.zone_state) == "shrinking" and String(hud._center.text) != "ZONE SHRINKING" and String(arena.get("zone_warning")) == "",
		"the 1 vs 1's stage change is quiet: no ZONE SHRINKING line, no band", at)
	_check(bool(arena.call("quiet_stage_change")), "the 1 vs 1 arena changes stage quietly", at)
	await at.shot("hud_05c_stage_change")
	# The minimap turns with the view by default (the bot's arrowhead turned with it, N on the edge);
	# NORTH UP keeps north up.
	b.hp = maxf(b.hp, 150.0)
	p.hp = maxf(p.hp, 150.0)
	_check(HudMinimap.turns(), "the minimap turns with the view by default", at)
	await at.shot("hud_05d_minimap_turned")
	Game.settings.minimap_turns = false
	await at.wait(0.3)
	await at.shot("hud_05e_minimap_north_up")
	Game.settings.minimap_turns = true
	b.hp = maxf(b.hp, 150.0)
	p.hp = maxf(p.hp, 150.0)
	# (back to the clock the tour had: the rest of it needs the round's time)
	arena.set("elapsed", minf(float(clock0[0]), RoundRules.STAGE1_S - 12.0))
	arena.set("time_left", float(arena.call("round_time")) - float(arena.get("elapsed")))
	arena.set("zone_state", "stationary")
	arena.set("zone_radius", clock0[2])
	arena.set("zone_center", clock0[3])
	arena.call("_update_zone_mesh")
	# Fire with the right fire button (drag-aim keeps it on the bot).
	var fire_c := HudLayout.center(hud.layout.fire_r, vs)
	var hits0 := int(p.stats.hits)
	var gd: Dictionary = p.gun().def
	var one_shot := b.hit_points(float(gd.damage) * Weapons.zone_mult(gd, "head") * Weapons.pen_mult(gd, "head"), "head") * int(gd.pellets)
	var most := 0
	_touch(at, 5, fire_c, true)
	for i in 9:
		b.hp = maxf(b.hp, 150.0)      # keep the bot standing for the rest of the tour
		_aim_at(p, b.chest_position() + Vector3(0, 0.05 * sin(i), 0))
		_drag(at, 5, fire_c + Vector2(1, 0), Vector2(1, 0))
		await at.wait(0.06)
		most = maxi(most, hud._dmg_numbers.size())
	await at.shot("hud_06_firing")
	var burst_hits := int(p.stats.hits) - hits0
	# A spray adds its hits up into one number per burst (round 8, like the reference: what each
	# hit really takes is the unit tests' check, Fighter.land_hits), hung up-left of the head.
	_check(burst_hits <= 1 or most <= 3, "a burst of %d hits shows at most 3 numbers (got %d; one shot %d)" % [burst_hits, most, roundi(one_shot)], at)
	_check(_numbers_near_head(hud, p, vs), "damage numbers hang by the target's head", at)
	_touch(at, 5, fire_c, false)
	await at.wait(0.3)
	b.hp = maxf(b.hp, 150.0)
	_check(int(p.stats.hits) > 0, "shots hit the bot", at)
	# Three hits that cannot merge (body, head, another source) at one point: a row, not a pile.
	# The HUD is held still for the picture (at 1-3 FPS a frame can outlast a number's life).
	hud.process_mode = Node.PROCESS_MODE_DISABLED
	hud._dmg_numbers.clear()
	# Quick hits on one target add up into one number (a headshot among them turns it warm).
	for hit: Array in [[b, 22.0, false], [b, 22.0, false], [b, 41.0, true]]:
		hud._add_damage_number(hit[0], hit[1], hit[2], b.chest_position())
	var nums: Array = hud._dmg_numbers
	_check(nums.size() == 1 and is_equal_approx(float(nums[0].amount), 85.0) and bool(nums[0].head),
		"three quick hits on one target read as one number 85, marked head", at)
	hud._dmg_numbers.clear()
	for hit: Array in [[b, 22.0, false], [b, 41.0, true], [null, 22.0, false]]:
		hud._add_damage_number(hit[0], hit[1], hit[2], b.chest_position())
	_check(hud._dmg_numbers.size() == 2 and _numbers_near_head(hud, p, vs), "a hit with no target keeps its own number", at)
	hud.queue_redraw()
	await at.get_tree().process_frame
	hud.queue_redraw()
	await at.shot("hud_06b_number_row")
	# The staged row is not part of the next shots (the slow software clock would keep it up).
	hud._dmg_numbers.clear()
	hud.process_mode = Node.PROCESS_MODE_INHERIT
	# Red-dot ADS.
	p.toggle_ads()
	for i in 5:
		_aim_at(p, b.chest_position())
		await at.wait(0.1)
	await at.shot("hud_07_ads_reddot")
	p.toggle_ads()
	# RELOAD: nothing to do on a full magazine, then the reload and its ring on the crosshair.
	var reload_c := HudLayout.center(hud.layout.reload, vs)
	p.weapons[0].ammo = int(p.weapons[0].def.mag)
	await _tap(at, reload_c)
	var full_ignored := not p.weapons[0].reloading
	p.weapons[0].ammo = 2
	await _tap(at, reload_c)
	_check(full_ignored and p.weapons[0].reloading, "RELOAD does nothing on a full magazine, reloads a short one", at)
	await at.wait(0.6)
	await at.shot("hud_08_reload")
	await at.wait(2.0)
	# The kit: the gun held (its slot lit), the sidearm from its small slot (its rounds shown), the
	# fists from theirs, then SWITCH round the cycle gun -> sidearm -> fists -> gun.
	var slots := HudLayout.weapon_slots(hud.layout.weapons, vs)
	_check(p.current == Weapons.GUN and p.weapons.size() == 3 and p.sidearm().id == Weapons.SIDEARM, "the kit: gun, fists, sidearm", at)
	await at.shot("hud_08b_gun_held")
	await _tap(at, slots[1].get_center())
	await at.wait(0.4)
	_check(p.current == Weapons.SIDE and p.weapon().id == Weapons.SIDEARM, "the middle slot draws the sidearm", at)
	_check(hud._panel_weapon() == p.sidearm(), "the main slot shows the sidearm's magazine", at)
	p.sidearm().ammo = 5
	await _tap(at, HudLayout.center(hud.layout.reload, vs))
	_check(p.sidearm().reloading, "RELOAD reloads the sidearm in hand", at)
	await at.wait(0.3)
	await at.shot("hud_08c_sidearm_reload")
	var rt := 0.0
	while p.sidearm().reloading and rt < 12.0:      # (the capture box runs the game slower than the clock)
		await at.wait(0.25)
		rt += 0.25
	_check(p.sidearm().ammo == 12 and p.sidearm().reserve == int(Weapons.DEFS[Weapons.SIDEARM].reserve) - 7,
		"the sidearm's reload takes from its spare rounds (%d / %d)" % [p.sidearm().ammo, p.sidearm().reserve], at)
	await at.shot("hud_08d_sidearm_held")
	await _tap(at, slots[2].get_center())
	await at.wait(0.4)
	await at.shot("hud_09_fists")
	_check(p.current == Weapons.FISTS, "fist slot selects the fists", at)
	var swap_c := HudLayout.center(hud.layout.swap, vs)
	var cycle: Array[int] = []
	for i in 3:
		await _tap(at, swap_c)
		cycle.append(p.current)
		await at.wait(0.3)
	_check(cycle == [Weapons.GUN, Weapons.SIDE, Weapons.FISTS], "SWITCH cycles gun -> sidearm -> fists (%s)" % [cycle], at)
	await _tap(at, HudLayout.weapon_main(hud.layout.weapons, vs).get_center())
	await at.wait(0.3)
	_check(p.current == Weapons.GUN, "the main slot draws the gun with the fists out", at)
	# The lever shotgun in the weapon panel (its own silhouette, not the pump gun's).
	p.set_loadout("lever")
	await at.wait(0.6)
	await at.shot("hud_09b_lever")
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
	# PRONE: a tap where it is drawn lies down (on any screen width: no other control takes it).
	var prone_c := HudLayout.center(hud.layout.prone, vs)
	_check(hud._widget_at(prone_c, vs) == "prone", "a tap on PRONE goes to PRONE (got %s)" % hud._widget_at(prone_c, vs), at)
	await _tap(at, prone_c)
	await at.wait(0.6)
	_check(p.stance == Fighter.Stance.PRONE, "the PRONE button lies down", at)
	await _tap(at, prone_c)
	await at.wait(0.6)
	_check(p.stance == Fighter.Stance.STAND, "a second tap on PRONE stands up", at)
	# The gear opens the in-match settings (closed again right away).
	await _tap(at, HudLayout.center(hud.layout.settings, vs))
	await at.wait(0.3)
	var menu := (arena.get("pause_layer") as Node).find_child("PauseMenu", false, false)
	_check(at.get_tree().paused and menu != null and menu.get("settings") is SettingsPanel, "the gear opens the in-match settings", at)
	# QUIT MATCH as in a counted online match: a question of our own (CANCEL / QUIT); back closes it.
	arena.set("online", true)
	arena.set("_counted", true)
	var quit_b := menu.find_child("Quit", true, false) as Button if menu else null
	if quit_b:
		await _tap(at, quit_b.get_global_rect().get_center())
		await at.wait(0.3)
	var ask := menu.find_child("Confirm", true, false) as Control if menu else null
	var ask_ok := ask.find_child("ConfirmOk", true, false) as Button if ask else null
	var ask_txt := ""
	for l in (ask.find_children("*", "Label", true, false) if ask else []):
		ask_txt += (l as Label).text + " "
	_check(ask != null and ask_ok != null and ask_ok.text == "QUIT" and ask.find_child("ConfirmCancel", true, false) != null
		and ask_txt.contains("defeat") and ask_txt.contains("LEFT in HISTORY") and ask.find_child("QuitWarning", true, false) == null
		and arena == at.get_tree().current_scene, "QUIT MATCH online asks first: a defeat, LEFT in HISTORY, CANCEL / QUIT (%s)" % ask_txt, at)
	await at.shot("hud_11b_quit_confirm")
	var sp := menu.get("settings") as Node if menu else null
	if sp:
		sp.propagate_notification(NOTIFICATION_WM_GO_BACK_REQUEST)
		await at.wait(0.2)
	_check(menu.find_child("Confirm", true, false) == null and is_instance_valid(menu) and menu.get("settings") is SettingsPanel,
		"back closes the question first, the settings stay", at)
	arena.set("online", false)
	arena.set("_counted", false)
	for n in (arena.get("pause_layer") as Node).get_children():
		n.queue_free()
	at.get_tree().paused = false
	hud.reload_layout()
	await at.wait(0.3)
	# Scoreboard (a tap on the score bar), then close it.
	await _tap(at, hud.score_rect().get_center())
	await at.wait(0.5)
	await at.shot("hud_12_scoreboard")
	_check(hud.panels.board_open, "scoreboard opens", at)
	var panel_r := HudLayout.weapon_main(hud.layout.weapons, vs).merge(HudLayout.weapon_slots(hud.layout.weapons, vs)[2])
	_check(not hud.panels.board_rect().intersects(panel_r), "scoreboard keeps clear of the weapon panel", at)
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
	_check(Engine.time_scale >= 1.0, "the kill plays at normal speed (no slow motion, as the reference)", at)
	_check(hud.banner_kind() == "kill" and hud.result_title() == "", "the kill shows the small badge, no result band yet", at)
	_check(arena.find_children("EliminatedTag*", "Label3D", true, false).size() >= 1, "ELIMINATED floats over the bot's body", at)
	_check(hud.feed_lines == 1 and hud._kill_feed.size() == 1 and String(hud._kill_feed[0].icon) != "",
		"the 1 vs 1 kill feed is one line with the gun's silhouette", at)
	hud.add_kill_feed("ZONE", "BOT", "", "", false, false)
	_check(hud._kill_feed.size() == 1 and String(hud._kill_feed[0].killer) == "ZONE", "a new kill feed line replaces the old one", at)
	hud._kill_feed.pop_front()
	hud.add_kill_feed(p.display_name, b.display_name, String(p.weapon().def.name), String(p.weapon().def.icon), true, true)
	_check(int(arena.get("phase")) == 3 and hud.break_step() != "", "the round's end starts the break between rounds", at)
	arena.set("_break_t", -1000.0)          # (the break is held while its steps are looked at)
	await at.wait(1.0)
	await at.shot("hud_16_kill_late")
	# A camera cutout on the left side: the edge-anchored widgets move off it.
	UI.margins_for_test = Vector2(64, 0)
	hud._update_safe_area()
	await at.wait(0.3)
	await at.shot("hud_16b_cutout")
	_check(HudLayout.minimap_rect(hud.layout.minimap, vs).position.x >= 64.0
		and HudLayout.hit_rect("medkit", hud.layout.medkit, vs).position.x >= 64.0
		and HudLayout.hit_rect("settings", hud.layout.settings, vs).position.x >= 64.0,
		"a camera cutout on the left moves the minimap, the gear and the MEDKIT off it", at)
	UI.margins_for_test = Vector2(-1, -1)
	hud._update_safe_area()
	# The ELIMINATED BY card at the bottom left while the player spectates (held up for the picture).
	arena.set("eliminated_by", {"cause": "gun", "name": b.display_name, "gun": String(b.gun().def.name), "gun_id": String(b.gun().id), "damage": 187})
	p.alive = false
	hud.queue_redraw()
	await at.wait(0.3)
	await at.shot("hud_16c_eliminated_by")
	arena.set("eliminated_by", {"cause": "zone"})
	await at.wait(0.2)
	await at.shot("hud_16d_eliminated_by_zone")
	# The SPECTATING card (staged, the arena held): the kit the player still carried and, against
	# another player online, ADD FRIEND for the one watched.
	b.alive = true
	p.spectating = b
	p.set("_spectate_wait", 0.0)
	p.kit_at_death = {"walls": 2, "frags": 1, "medkits": 0}
	arena.process_mode = Node.PROCESS_MODE_DISABLED
	arena.set("online", true)
	arena.set("_enemy_id", "ab".repeat(16))
	hud.queue_redraw()
	await at.get_tree().process_frame
	hud.queue_redraw()
	await at.shot("hud_16i_spectating")
	_check(hud.spectate_friend_state(b) == "add" and hud._spec_friend_rect.has_area(), "the SPECTATING card offers ADD FRIEND online", at)
	arena.set("online", false)
	arena.set("_enemy_id", "")
	hud.queue_redraw()
	await at.get_tree().process_frame
	_check(hud.spectate_friend_state(b) == "" and not hud._spec_friend_rect.has_area(), "no ADD FRIEND against a bot", at)
	arena.process_mode = Node.PROCESS_MODE_INHERIT
	b.alive = false
	p.spectating = null
	p.kit_at_death = {}
	# The break between rounds, step by step (staged: the player won round 1 but the ELIMINATED BY
	# card is up, to see that it stays readable over the dimmed screen).
	Engine.time_scale = 1.0
	hud._kill_banner.t = 0.0                # (the staged steps come seconds after the kill badge ended)
	arena.set("eliminated_by", {"cause": "gun", "name": b.display_name, "gun": String(b.gun().def.name), "gun_id": String(b.gun().id), "damage": 187})
	for st: Array in [["result", 3.0, "hud_16e_break_result"], ["score", 5.4, "hud_16f_break_score"],
			["score", 6.9, "hud_16g_break_tick"], ["band", 9.2, "hud_16h_break_band"]]:
		hud._break.age = float(st[1])
		hud.process_mode = Node.PROCESS_MODE_DISABLED
		hud.queue_redraw()
		await at.get_tree().process_frame
		hud.queue_redraw()
		await at.shot(String(st[2]))
		hud.process_mode = Node.PROCESS_MODE_INHERIT
		_check(hud.break_step() == String(st[0]), "%.1f s into the break: %s (got %s)" % [st[1], st[0], hud.break_step()], at)
		if st[2] == "hud_16f_break_score":
			_check(hud.break_score(true) == 0 and hud.break_score(false) == 0, "the plates start from the old score", at)
		elif st[2] == "hud_16g_break_tick":
			_check(hud.break_score(true) == 1 and hud.break_score(false) == 0, "the winner's number counts up", at)
	p.alive = true
	arena.set("eliminated_by", {})
	arena.set("_break_t", RoundRules.BREAK_S - 0.3)
	await at.wait_for_phase(arena, 0, 10.0)
	await at.wait(0.3)
	_check(int(arena.get("round_index")) == 2 and hud.break_step() == "" and float(hud._round_banner.t) <= 0.0,
		"the prep of round 2 follows the break with nothing over it", at)
	await at.shot("hud_16i_round2_prep")
	await at.wait_for_phase(arena, 1, 12.0)
	await at.wait(0.3)
	_check(float(hud._round_banner.t) <= 0.0, "nothing covers the fight when round 2 starts (its band closed the break)", at)
	await at.shot("hud_16j_round2_go")
	# HUD editor.
	Game.goto_hud_editor()
	await at.wait(1.2)
	await at.shot("hud_17_editor")
	var ed := at.get_tree().current_scene
	var eh: HUD = ed.get("hud")
	# The editor's minimap stand-in follows the setting: turned (arrow up, N) or north up.
	Game.settings.minimap_turns = false
	eh.minimap.queue_redraw()
	await at.wait(0.3)
	await at.shot("hud_17b_editor_north_up")
	Game.settings.minimap_turns = true
	eh.minimap.queue_redraw()
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
	# The gear on the weapon panel's corner is drawn and picked up in the editor too.
	var gear_c := HudLayout.center(eh.layout.settings, eh.size)
	_touch(at, 4, gear_c, true)
	await at.wait(0.1)
	_touch(at, 4, gear_c, false)
	await at.wait(0.2)
	await at.shot("hud_19_editor_gear")
	_check(eh.selected_id == "settings", "the editor picks the gear on the weapon panel (got %s)" % eh.selected_id, at)
	await team_tour(at)
	at.log_line("HUD TOUR fails=%d" % _fails)
	return 1 if _fails > 0 else 0


## True when every damage number on screen sits within 0.1u of its target's head point.
func _numbers_near_head(hud: HUD, p: Player, vs: Vector2) -> bool:
	var u := HudLayout.unit(vs)
	for n: Dictionary in hud._dmg_numbers:
		if n.target is Fighter and not p.camera.is_position_behind(hud._dmg_anchor3(n)):
			var head := p.camera.unproject_position(hud._dmg_anchor3(n))
			if hud._dmg_point(n, u).distance_to(head) > 0.1 * u:
				return false
	return true


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


# ---------------------------------------------------------------- DUO / SQUAD

## TRAINING GROUND SQUAD (then a DUO) against the real TeamArena, one round to win.
func team_tour(at: Node) -> void:
	Game.team_match = TeamArena.offline_match(4, "training", 0)
	Game.goto_arena()
	await at.wait(1.2)
	var arena: Node = at.get_tree().current_scene
	var hud: HUD = arena.get("hud")
	var p: Player = arena.get("player")
	_check(arena is TeamArena and hud.team != null and hud.get_node_or_null("HudTeam") == hud.team, "a SQUAD match has the team layer", at)
	if not arena is TeamArena or hud.team == null:
		return
	var team: HudTeam = hud.team
	var vs: Vector2 = hud.size
	arena.set("rounds_to_win", 1)
	var mates: Array = team.members(team.my_team())
	var foes: Array = team.members(1 - team.my_team())
	_check(mates.size() == 4 and foes.size() == 4, "SQUAD: four a team (%d / %d)" % [mates.size(), foes.size()], at)
	if mates.size() < 2 or foes.is_empty():
		return
	# PREP: the pick, then the match-up line.
	arena.set("prep_left", 40.0)
	await at.wait(0.4)
	if hud.panels.pick_open:
		await _tap(at, hud.panels.select_rect().get_center())
		await at.wait(0.3)
	arena.set("prep_left", 6.5)
	await at.wait(0.5)
	await at.shot("team_01_prep")
	var lines: Array = hud.team_matchup_lines()
	_check(String(lines[0][0][0]).begins_with("BLUE") and String(lines[1][0][0]).begins_with("ORANGE")
		and String(lines[0][1][0]).contains(p.display_name.to_upper()), "the prep line: BLUE (with the player) VS ORANGE", at)
	await at.wait_for_phase(arena, 1)
	await at.wait(0.3)
	for f: Fighter in mates + foes:
		if f is Bot:
			(f as Bot).frozen = true
	# Teammates ahead of the player, enemies far off: the tags and the panel.
	var fwd := -p.global_basis.z
	fwd.y = 0.0
	fwd = fwd.normalized()
	p.global_position = arena.call("closest_nav_point", p.global_position + fwd * 3.0)
	for i in range(1, mates.size()):
		var m: Fighter = mates[i]
		m.global_position = arena.call("closest_nav_point", p.global_position + fwd.rotated(Vector3.UP, (i - 2) * 0.35) * (5.0 + i))
	await at.wait(0.4)
	_aim_at(p, (mates[2] as Fighter).global_position + Vector3.UP * 1.2)
	await at.wait(0.4)
	await at.shot("team_02_fight")
	var tags := 0
	for i in range(1, mates.size()):
		if HudTeam.tag_point(p.camera, (mates[i] as Fighter).global_position + Vector3.UP * HudTeam.TAG_UP, vs) != null:
			tags += 1
	_check(tags >= 2, "teammates in view carry their tags (%d)" % tags, at)
	_check_clear(hud, team.panel_rect(), "the teammates panel", at)
	# A teammate knocked by an enemy's hits: KNOCKED in the panel, the feed and the marker.
	var mate: Fighter = mates[1]
	var foe: Fighter = foes[0]
	mate.take_damage(999.0, "chest", foe, foe.global_position)
	await at.wait(0.5)
	_check(team.status(mate) == "knocked", "a teammate out of HP is KNOCKED (%s)" % team.status(mate), at)
	_aim_at(p, mate.global_position + Vector3.UP * 0.6)
	await at.wait(0.3)
	await at.shot("team_03_knocked_mate")
	# Turned away: the marker is pinned to the screen edge.
	_aim_at(p, p.global_position - (mate.global_position - p.global_position) + Vector3.UP * 1.4)
	await at.wait(0.3)
	var mw := mate.global_position + Vector3.UP * HudTeam.TAG_UP_KNOCKED
	var edge := HudTeam.edge_point(p.camera.unproject_position(mw), p.camera.is_position_behind(mw), vs, HudTeam.EDGE_MARGIN)
	_check(bool(edge.edge), "a knocked teammate behind the player: the marker at the screen edge", at)
	await at.shot("team_04_marker_edge")
	# REVIVE: next to them the button shows; a real tap starts it; it ends with them UP.
	p.global_position = arena.call("closest_nav_point", mate.global_position + fwd * 1.2)
	_aim_at(p, mate.global_position + Vector3.UP * 0.4)
	await _until(at, func() -> bool: return team.revive_shown(), 3.0)
	_check(team.revive_shown() and team.revive_target() == mate, "REVIVE shows next to the knocked teammate", at)
	var rc := team.revive_center()
	var rr := team.revive_radius()
	_check(rr * 2.0 >= UI.TOUCH_MIN, "REVIVE is a full touch target (%d px)" % roundi(rr * 2.0), at)
	_check_clear(hud, Rect2(rc - Vector2(rr, rr) * 1.15, Vector2(rr, rr) * 2.3), "REVIVE", at)
	await at.shot("team_05_revive_button")
	await _tap(at, rc)
	await at.wait(0.6)
	_check(p.reviving == mate, "a tap on REVIVE starts reviving", at)
	await at.wait(1.6)
	_check_clear(hud, team.bar_rect("REVIVING " + mate.display_name.to_upper()), "the REVIVING bar", at)
	var stop_c := team.revive_center()
	var stop_r := team.revive_radius() * 1.15
	_check(not team.bar_rect("REVIVING " + mate.display_name.to_upper()).intersects(Rect2(stop_c - Vector2(stop_r, stop_r), Vector2(stop_r, stop_r) * 2.0)),
		"the REVIVING bar keeps clear of STOP", at)
	await at.shot("team_06_reviving")
	await _until(at, func() -> bool: return team.status(mate) == "up", Fighter.REVIVE_S + 4.0)
	_check(team.status(mate) == "up" and absf(mate.hp - Fighter.REVIVE_HP) < 1.0, "the revive stands the teammate up with %d HP" % roundi(Fighter.REVIVE_HP), at)
	# The player knocked: BLEEDING OUT, then a teammate reviving: BEING REVIVED.
	p.take_damage(999.0, "chest", foe, foe.global_position)
	await at.wait(0.6)
	_check(p.alive and p.knocked, "the player out of HP with teammates up is KNOCKED", at)
	_check_clear(hud, team.bar_rect("BLEEDING OUT"), "the BLEEDING OUT bar", at)
	await at.shot("team_07_knocked_self")
	var helper: Fighter = mates[2]
	helper.global_position = arena.call("closest_nav_point", p.global_position + fwd * 1.0)
	await at.wait(0.2)
	var started := bool(arena.call("start_revive", helper, p))
	await at.wait(1.4)
	_check(started and team.revive_progress(p) > 0.0, "a teammate reviving the player: BEING REVIVED", at)
	await at.shot("team_08_being_revived")
	arena.call("cancel_revive", helper)
	await at.wait(0.2)
	# Out: SPECTATING a teammate with NEXT.
	for i in 3:
		if p.alive:
			p.take_damage(400.0, "chest", foe, foe.global_position)
			await at.wait(0.3)
	await _until(at, func() -> bool: return team.spectated() != null, 4.0)
	var first := team.spectated()
	_check(first != null and first.team == p.team and team.next_shown(), "out: SPECTATING a teammate, with NEXT", at)
	var nr: Rect2 = team.spectate_rects()[1]
	_check(nr.size.x >= UI.TOUCH_MIN and nr.size.y >= UI.TOUCH_MIN, "NEXT is a full touch target", at)
	_check_clear(hud, nr, "NEXT", at)
	await at.shot("team_09_spectating")
	await _tap(at, nr.get_center())
	await at.wait(0.4)
	_check(team.spectated() != null and team.spectated() != first, "NEXT moves to another teammate", at)
	# The scoreboard by team.
	await _tap(at, hud.score_rect().get_center())
	await at.wait(0.5)
	await at.shot("team_10_scoreboard")
	_check(hud.panels.board_open and hud.panels.team_board() and hud.panels.board_rect().end.y <= vs.y, "the SQUAD scoreboard fits the screen", at)
	_check(team.get_index() < hud.panels.get_index(), "the scoreboard draws over the team layer", at)
	await _tap(at, hud.panels.board_close_rect().get_center())
	await at.wait(0.2)
	# The host's QUIT warning (as if this were an online co-op match hosted here).
	Game.team_match["online"] = true
	Game.team_match["coop"] = true
	Game.team_match["host"] = true
	await _tap(at, HudLayout.center(hud.layout.settings, vs))
	await at.wait(0.4)
	var menu := (arena.get("pause_layer") as Node).find_child("PauseMenu", false, false)
	var quit: Button = menu.find_child("Quit", true, false) as Button if menu else null
	if quit:
		quit.pressed.emit()
		await at.wait(0.2)
	var warn: Label = menu.find_child("QuitWarning", true, false) as Label if menu else null
	_check(warn != null and warn.is_visible_in_tree() and warn.text == PauseMenu.HOST_WARNING and menu.find_child("Confirm", true, false) != null
		and arena == at.get_tree().current_scene, "the host's QUIT MATCH asks first, the warning that it ends the match for the teammate in it", at)
	_check(hud._kill_feed.size() <= 3 and hud.feed_lines == 3, "DUO / SQUAD keep three kill feed lines", at)
	await at.shot("team_11_host_quit")
	Game.team_match["online"] = false
	Game.team_match["coop"] = false
	for n in (arena.get("pause_layer") as Node).get_children():
		n.queue_free()
	at.get_tree().paused = false
	hud.reload_layout()
	await at.wait(0.3)
	# The round to the end: the enemies go down, the results.
	await _wipe(at, foes, mates[1])
	await _until(at, func() -> bool: return _results_of(arena) != null, 25.0)
	await at.wait(1.6)
	await at.shot("team_12_results_squad")
	_check_results(_results_of(arena), 4, at)
	# DUO: the panel, the prep line, then the results.
	Game.team_match = TeamArena.offline_match(2, "training", 0)
	Game.goto_arena()
	await at.wait(1.2)
	arena = at.get_tree().current_scene
	hud = arena.get("hud")
	if not arena is TeamArena or hud.team == null:
		_check(false, "a DUO match has the team layer", at)
		return
	arena.set("rounds_to_win", 2)              # (a break between the rounds, with the team score)
	team = hud.team
	await at.wait_for_phase(arena, 1)
	await at.wait(0.6)
	await at.shot("team_13_duo_fight")
	_check(team.team_rows().size() == 2, "DUO: two rows in the panel", at)
	_check_clear(hud, team.panel_rect(), "the DUO panel", at)
	# The player knocks an enemy down (its teammate still up): the KNOCKED plate, then the round.
	var me: Fighter = arena.get("player")
	var duo_foes: Array = team.members(1 - team.my_team())
	(duo_foes[0] as Fighter).take_damage(999.0, "chest", me, me.global_position)
	await at.wait(0.3)
	_check(hud.banner_kind() == "knock", "knocking an enemy shows the KNOCKED plate (got '%s')" % hud.banner_kind(), at)
	await at.shot("team_14_knock_banner")
	await _wipe(at, duo_foes, me)
	await _until(at, func() -> bool: return int(arena.get("phase")) == 3, 10.0)
	arena.set("_break_t", -1000.0)
	Engine.time_scale = 1.0
	_check(hud.break_step() != "", "DUO: the break between rounds", at)
	hud._kill_banner.t = 0.0
	hud._break.age = 6.9
	hud.process_mode = Node.PROCESS_MODE_DISABLED
	hud.queue_redraw()
	await at.get_tree().process_frame
	hud.queue_redraw()
	await at.shot("team_14b_duo_break_score")
	hud.process_mode = Node.PROCESS_MODE_INHERIT
	_check(hud.break_score(true) == 1 and hud.break_score(false) == 0, "DUO: the team score counts up on the plates", at)
	arena.set("_break_t", RoundRules.BREAK_S - 0.3)
	await at.wait_for_phase(arena, 1, 25.0)
	await at.wait(0.5)
	await _wipe(at, team.members(1 - team.my_team()), me)
	await _until(at, func() -> bool: return _results_of(arena) != null, 25.0)
	await at.wait(1.6)
	await at.shot("team_15_results_duo")
	_check_results(_results_of(arena), 2, at)
	Game.team_match = {}


## Every enemy down: hits from `by` until each is out of the round.
func _wipe(at: Node, foes: Array, by: Fighter) -> void:
	for k in 4:
		for f: Fighter in foes:
			if is_instance_valid(f) and f.alive:
				f.take_damage(400.0, "chest", by, by.global_position)
		await at.wait(0.4)


func _results_of(arena: Node) -> ResultsScreen:
	var layer: Variant = arena.get("pause_layer")
	if not layer is Node:
		return null
	for n in (layer as Node).get_children():
		if n is ResultsScreen:
			return n
	return null


func _check_results(rs: ResultsScreen, size: int, at: Node) -> void:
	_check(rs != null, "the team results show (%d a team)" % size, at)
	if rs == null:
		return
	var rows := 0
	for i in size * 2:
		if rs.find_child("TeamRow_%d" % i, true, false) != null:
			rows += 1
	_check(rows == size * 2, "both teams' tables: %d rows (got %d)" % [size * 2, rows], at)
	_check(rs.find_child("Rematch", true, false) == null and rs.find_child("PlayAgain", true, false) != null,
		"team results: PLAY AGAIN offline, no REMATCH", at)
	var tables := rs.find_child("TeamTables", true, false) as Control
	var foot := rs.find_child("HonourSlot", true, false) as Control
	if tables != null and foot != null:
		var low := 0.0
		for c in tables.find_children("TeamRow_*", "", true, false):
			low = maxf(low, (c as Control).get_global_rect().end.y)
		_check(low <= foot.get_global_rect().position.y + 1.0, "the team tables end above the honour tag (%d <= %d)"
			% [roundi(low), roundi(foot.get_global_rect().position.y)], at)


## `r` (a team widget) covers none of the 1 vs 1 HUD's buttons, its weapon panel or minimap.
func _check_clear(hud: HUD, r: Rect2, what: String, at: Node) -> void:
	var hit := ""
	for b: Rect2 in hud.team.blocked_rects():
		if b.intersects(r.grow(-1.0)):
			hit = str(b)
			break
	_check(hit == "", "%s keeps clear of the other controls %s" % [what, hit], at)
