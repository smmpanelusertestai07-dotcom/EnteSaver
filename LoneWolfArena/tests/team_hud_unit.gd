extends RefCounted
## Unit tests of DUO / SQUAD, WP-B2: the team HUD (HudTeam against a stand-in arena that has only
## TeamArena's read API), the team kill feed, the knock banner, the minimap's teammates, the team
## results and the host's QUIT warning. Run from tests/run_tests.gd (which counts the checks).

var t: Node


## A stand-in for TeamArena's read API (scripts/team_arena.gd): what HudTeam reads, nothing else.
class StandIn extends Node:
	var team_size := 2
	var my_team := 0
	var player: Fighter
	var slots: Array[Fighter] = []
	var override := {}            # fighter -> status ("left")
	var candidate: Fighter
	var progress := {}            # fighter -> revive progress 0..1
	var spect: Fighter
	var score := {"player": 1, "bot": 2}

	func members(team: int) -> Array[Fighter]:
		var out: Array[Fighter] = []
		for f in slots:
			if f.team == team:
				out.append(f)
		return out

	func status_of(f: Fighter) -> String:
		if override.has(f):
			return String(override[f])
		if f == null or not f.alive:
			return "out"
		return "knocked" if f.knocked else "up"

	func revive_candidate(_f: Fighter) -> Fighter:
		return candidate

	func revive_progress(f: Fighter) -> float:
		return float(progress.get(f, -1.0))

	func spectated() -> Fighter:
		return spect


static func run(runner: Node) -> void:
	var me := new()
	me.t = runner
	me._test_rows_and_revive()
	me._test_geometry()
	me._test_feed()
	me._test_results()
	me._test_quit_warning()


func _check(cond: bool, what: String) -> void:
	t.call("_check", cond, what)


func _fighter(nm: String, team: int, slot: int) -> Fighter:
	var f := Fighter.new()
	f.display_name = nm
	f.team = team
	f.slot = slot
	return f


## A SQUAD stand-in: the player and three teammates (one knocked, one out, one left), four enemies.
func _squad() -> StandIn:
	var a := StandIn.new()
	a.team_size = 4
	for i in 8:
		a.slots.append(_fighter("P%d" % i, 0 if i < 4 else 1, i))
	a.player = a.slots[0]
	a.slots[1].knocked = true
	a.slots[1].knock_hp = Fighter.KNOCK_HP * 0.5
	a.slots[2].alive = false
	a.override[a.slots[3]] = "left"
	a.slots[0].hp = Fighter.MAX_HP * 0.5
	return a


func _free(a: StandIn) -> void:
	for f in a.slots:
		if is_instance_valid(f):
			f.free()
	a.free()


func _test_rows_and_revive() -> void:
	var plain := Node.new()
	_check(not HudTeam.wanted(plain) and not HudTeam.wanted(null), "a 1 vs 1 arena (no team_size) gets no HudTeam")
	plain.free()
	var a := _squad()
	_check(HudTeam.wanted(a), "a team arena with 4 a team gets HudTeam")
	a.team_size = 1
	_check(not HudTeam.wanted(a), "team_size 1 gets no HudTeam")
	a.team_size = 4
	var hud := HUD.new()
	var ht := HudTeam.new()
	ht.hud = hud
	ht.arena = a
	var rows := ht.team_rows()
	_check(rows.size() == 4, "the panel lists the four of the team (got %d)" % rows.size())
	if rows.size() == 4:
		_check(int(rows[0].n) == 1 and int(rows[3].n) == 4 and bool(rows[0].me) and not bool(rows[1].me), "badges 1..4 in slot order, the player first")
		_check(String(rows[0].status) == "up" and is_equal_approx(float(rows[0].hp), 0.5), "an UP row has its HP")
		_check(String(rows[1].status) == "knocked" and is_equal_approx(float(rows[1].bleed), 0.5) and float(rows[1].revive) < 0.0,
			"a KNOCKED row has its bleed-out bar, no revive yet")
		_check(String(rows[2].status) == "out" and float(rows[2].hp) == 0.0, "an OUT row is empty")
		_check(String(rows[3].status) == "left", "a member who left reads LEFT")
	a.progress[a.slots[1]] = 0.4
	_check(is_equal_approx(float(ht.team_rows()[1].revive), 0.4), "a revive in progress shows on the knocked row")
	_check(ht.badge(a.slots[2]) == 3 and ht.badge(a.slots[5]) == 0, "an enemy has no badge")
	_check(is_equal_approx(ht.team_hp(0), 0.5 / 4.0) and is_equal_approx(ht.team_hp(1), 1.0), "team HP counts only the fighters UP")
	# REVIVE only with a candidate, never while knocked or after the match.
	_check(not ht.revive_shown(), "no REVIVE without a candidate")
	a.candidate = a.slots[1]
	_check(ht.revive_shown() and ht.revive_target() == a.slots[1], "REVIVE shows with a knocked teammate in reach")
	a.player.knocked = true
	_check(not ht.revive_shown(), "a knocked player gets no REVIVE")
	a.player.knocked = false
	hud.match_over = true
	_check(not ht.revive_shown(), "no REVIVE once the match is over")
	hud.match_over = false
	a.candidate = null
	a.player.reviving = a.slots[1]
	_check(ht.revive_shown() and ht.reviving() == a.slots[1], "REVIVE stays (as STOP with its ring) while reviving")
	_check(ht.reviver_of(a.slots[1]) == a.player, "the knocked teammate knows who revives them")
	a.player.reviving = null
	# Spectating: only once out; NEXT only on a teammate.
	_check(ht.spectated() == null, "nobody to spectate while the player is in the round")
	a.player.alive = false
	a.spect = a.slots[1]
	_check(ht.spectated() == a.slots[1] and ht.next_shown(), "out: SPECTATING the teammate, with NEXT")
	a.spect = a.slots[6]
	_check(ht.spectated() == a.slots[6] and not ht.next_shown(), "following an enemy (nobody of the team UP): no NEXT")
	ht.free()
	hud.free()
	_free(a)


func _test_geometry() -> void:
	var vs := Vector2(1280, 720)
	var on := HudTeam.edge_point(Vector2(400, 300), false, vs, 46.0)
	_check(not bool(on.edge) and on.pos == Vector2(400, 300), "a knocked teammate in view: the marker on them")
	var right := HudTeam.edge_point(Vector2(1900, 360), false, vs, 46.0)
	_check(bool(right.edge) and is_equal_approx((right.pos as Vector2).x, 1280.0 - 46.0) and is_equal_approx((right.pos as Vector2).y, 360.0),
		"off screen to the right: pinned to the right edge (%s)" % str(right.pos))
	var back := HudTeam.edge_point(Vector2(700, 300), true, vs, 46.0)
	var bp: Vector2 = back.pos
	_check(bool(back.edge) and Rect2(Vector2(45, 45), vs - Vector2(90, 90)).has_point(bp)
		and (is_equal_approx(bp.y, 720.0 - 46.0) or is_equal_approx(bp.x, 46.0) or is_equal_approx(bp.x, 1280.0 - 46.0)),
		"behind the camera: pinned to an edge, never in the middle (%s)" % str(bp))
	var corner := HudTeam.edge_point(Vector2(-500, -400), false, vs, 46.0)
	_check(Rect2(Vector2(45, 45), vs - Vector2(90, 90)).has_point(corner.pos), "far off at a corner: kept on screen")
	# Tags: a real camera in the tree.
	var cam := Camera3D.new()
	t.add_child(cam)
	cam.global_position = Vector3(0, 1.6, 0)
	var view := cam.get_viewport().get_visible_rect().size
	_check(HudTeam.tag_point(cam, Vector3(0, 2.2, -8), view) != null, "an ally ahead gets a tag")
	_check(HudTeam.tag_point(cam, Vector3(0, 2.2, 8), view) == null, "an ally behind the camera gets no tag")
	_check(HudTeam.tag_point(cam, Vector3(60, 2.2, -2), view) == null, "an ally off the side of the screen gets no tag")
	cam.free()
	# The free-spot search never picks a blocked place when a free one exists.
	var blocked: Array[Rect2] = [Rect2(0, 0, 100, 100)]
	var cands: Array[Rect2] = [Rect2(50, 50, 40, 40), Rect2(200, 50, 40, 40)]
	_check(HudTeam.free_spot(cands, blocked) == cands[1], "a free spot beats a covered one")
	# The minimap's teammates: knocked ones marked, the player and those out left out.
	var a := _squad()
	var root := Node3D.new()
	t.add_child(root)
	for f in a.slots:
		root.add_child(f)
	a.slots[1].global_position = Vector3(3, 0, 4)
	var hud := HUD.new()
	var ht := HudTeam.new()
	ht.hud = hud
	ht.arena = a
	var marks := HudMinimap.ally_marks(ht, Vector2.ZERO, 2.0)
	_check(marks.size() == 1 and int(marks[0].n) == 2 and bool(marks[0].knocked) and (marks[0].pos as Vector2) == Vector2(6, 8),
		"the minimap marks the knocked teammate (2) at its place; not the player, the one out or the one who left")
	_check(HudMinimap.ally_marks(null, Vector2.ZERO, 2.0).is_empty(), "no teammates on a 1 vs 1 minimap")
	ht.free()
	hud.free()
	root.free()
	a.free()


func _test_feed() -> void:
	var hud := HUD.new()
	hud.add_team_feed("ALLY", true, "ENEMY", false, "VIPER AR", "", false, true, "KNOCKED")
	var k: Dictionary = hud._kill_feed[0]
	_check(k.get("kc") == HudTeam.BLUE_TEXT and k.get("vc") == HudTeam.ORANGE_TEXT and k.get("verb_col") == HUD.FEED_VERB_COLORS.KNOCKED,
		"the team feed: our side blue, theirs orange, KNOCKED in its colour")
	hud.add_team_feed("FOE", false, "MATE", true, "FRAG", "item_grenade", true, false)
	k = hud._kill_feed[0]
	_check(k.get("kc") == HudTeam.ORANGE_TEXT and k.get("vc") == HudTeam.BLUE_TEXT and k.get("verb_col") == HudDraw.FEED_HEAD,
		"an enemy taking out a teammate: orange then blue, a headshot in the headshot colour")
	hud.add_team_feed("ME", true, "MATE", true, "VIPER AR", "", false, true, "REVIVED")
	_check(String(hud._kill_feed[0].weapon) == "" and hud._kill_feed[0].get("verb_col") == HUD.FEED_VERB_COLORS.REVIVED,
		"REVIVED in green, no gun named")
	hud.add_team_feed("MATE", true, "", true, "", "", false, false, "LEFT")
	_check(hud._kill_feed[0].get("verb_col") == HUD.FEED_VERB_COLORS.LEFT and String(hud._kill_feed[0].verb) == "LEFT", "LEFT in grey")
	_check(hud._kill_feed.size() == 3, "the feed keeps three lines")
	hud.knock_banner("ENEMY")
	_check(hud.banner_kind() == "knock", "knocking an enemy shows the KNOCKED plate")
	hud.kill_banner("ENEMY", false)
	_check(hud.banner_kind() == "kill", "a kill still shows the elimination badge")
	hud.free()


func _team_result(online: bool, enemy_id := "") -> Dictionary:
	var rows := []
	for i in 4:
		var mine := i < 2
		rows.append({"name": "P%d" % i, "me": i == 0, "ally": mine, "team": 0 if mine else 1, "slot": i, "status": "up", "bot": i > 0,
			"kills": i, "knocks": 1, "revives": 1 if mine else 0, "damage": 100 * i, "headshots": 0, "accuracy": 40, "hp": 200, "alive": true})
	return {"won": true, "draw": false, "invalid": false, "kills": 1, "damage": 120, "headshots": 0, "accuracy": 40.0, "time": 95.0,
		"xp": 200, "enemy": "ORANGE TEAM", "enemy_id": enemy_id, "mode": "DUO", "mode_id": "duo", "map": "CARGO CAGE", "weapon": "VIPER AR",
		"score_player": 4, "score_bot": 2, "hp_left": 120, "difficulty": "NORMAL", "taken": 80, "team": true, "team_size": 2, "rows": rows,
		"knocks": 1, "revives": 1, "bots": 3, "online": online}


func _results(r: Dictionary) -> ResultsScreen:
	var rs := ResultsScreen.new()
	t.add_child(rs)
	rs.setup(r)
	return rs


func _bg(n: Node) -> Color:
	var sb := (n as Control).get_theme_stylebox("panel") if n is Control else null
	return (sb as StyleBoxFlat).bg_color if sb is StyleBoxFlat else Color.BLACK


func _test_results() -> void:
	var rs := _results(_team_result(false))
	var t0 := rs.find_child("TeamTable_0", true, false)
	var t1 := rs.find_child("TeamTable_1", true, false)
	_check(t0 != null and t1 != null, "team results: both teams' tables")
	if t0 != null and t1 != null:
		_check(t0.find_child("TeamRow_0", true, false) != null and t0.find_child("TeamRow_1", true, false) != null
			and t1.find_child("TeamRow_2", true, false) != null and t1.find_child("TeamRow_3", true, false) != null,
			"my team's rows (me first) in the blue table, theirs in the orange one")
		var mine := _bg(t0.find_child("TeamRow_0", true, false))
		var theirs := _bg(t1.find_child("TeamRow_2", true, false))
		_check(mine.b > mine.r and theirs.r > theirs.b, "rows in their team's colour (blue / orange)")
		var v: Variant = t1.find_child("TeamRow_3", true, false).find_child("Value_3", true, false)
		_check(v is Label and (v as Label).text == "300", "a row shows its damage")
	_check(rs.find_child("Stats", true, false) == null, "no 1 vs 1 table in a team result")
	_check(rs.find_child("Rematch", true, false) == null, "no REMATCH after a team match")
	_check(rs.find_child("PlayAgain", true, false) != null and rs.find_child("Lobby", true, false) != null, "offline: PLAY AGAIN and LOBBY")
	rs.queue_free()
	# Between two phones (Game.team_match from TeamArena.link_match): the same two humans get another
	# match, PLAY AGAIN TOGETHER after a co-op one, REMATCH after one against each other, in PLAY
	# AGAIN's place under a status line; none after a forfeit or once a player left (LOBBY only).
	var keep: Dictionary = Game.team_match
	var me := {"id": "cd".repeat(16), "name": "ME", "bundle": "default"}
	var them := {"id": "ab".repeat(16), "name": "ACE", "bundle": "default"}
	Game.team_match = TeamArena.link_match(2, false, me, them, true, 7)
	_check(ResultsScreen.other_player(Game.team_match) == {"id": them.id, "name": "ACE"}, "the other phone's player comes from the roster")
	var on := _results(_team_result(true, String(them.id)))
	_check(on.find_child("PlayAgain", true, false) == null and on.find_child("Rematch", true, false) != null and on.find_child("Lobby", true, false) != null
		and on.find_child("RematchStatus", true, false) != null and on.find_child("PlayAgainTogether", true, false) == null,
		"online against another player: REMATCH with its status line (no PLAY AGAIN), LOBBY")
	_check(on.find_child("AddFriend", true, false) != null, "online against another player: ADD FRIEND for them")
	_drop(on)
	var left := _team_result(true, String(them.id))
	left["opponent_left"] = true
	var forfeit := _results(left)
	_check(forfeit.find_child("Rematch", true, false) == null and forfeit.find_child("PlayAgainTogether", true, false) == null
		and forfeit.find_child("AddFriend", true, false) != null and forfeit.find_child("Lobby", true, false) != null,
		"after a forfeit: no REMATCH (LOBBY, ADD FRIEND)")
	_drop(forfeit)
	# The tap tells Cloud whose team invite to take (play_again) until the screen closes. (No session
	# here: the fresh invite would go out on a later frame; none comes in this test.)
	var tap := _results(_team_result(true, String(them.id)))
	(tap.find_child("Rematch", true, false) as Button).pressed.emit()
	_check(Game.cloud_service().play_again == {"id": String(them.id), "size": 2, "coop": false},
		"REMATCH tells Cloud the player, size and coop whose team invite to take")
	_drop(tap)
	_check(Game.cloud_service().play_again.is_empty(), "closing the results clears Cloud.play_again")
	Game.team_match = TeamArena.link_match(2, true, me, them, true, 7)
	var coop := _results(_team_result(true, ""))
	_check(coop.find_child("AddFriend", true, false) == null, "co-op against bots: no ADD FRIEND")
	var together := coop.find_child("PlayAgainTogether", true, false) as Button
	_check(together != null and (together.get_node("Caption") as Label).text == "PLAY AGAIN TOGETHER" and not together.disabled
		and coop.find_child("Rematch", true, false) == null
		and coop.find_child("PlayAgain", true, false) == null, "online co-op: PLAY AGAIN TOGETHER in PLAY AGAIN's place")
	_drop(coop)
	var gone := _team_result(true, "")
	(gone.rows[1] as Dictionary)["status"] = "left"          # the teammate left (the host's bots played on)
	var mate_left := _results(gone)
	_check(mate_left.find_child("PlayAgainTogether", true, false) == null and mate_left.find_child("Lobby", true, false) != null,
		"once a player left: no PLAY AGAIN TOGETHER")
	_drop(mate_left)
	Game.team_match = {}
	var unknown := _results(_team_result(true, ""))
	_check(unknown.find_child("PlayAgainTogether", true, false) == null and unknown.find_child("Rematch", true, false) == null,
		"no other player known: no PLAY AGAIN TOGETHER")
	_drop(unknown)
	Game.team_match = keep


## Takes a results screen out now (its _exit_tree runs; its Cloud connections go with it).
func _drop(rs: ResultsScreen) -> void:
	t.remove_child(rs)
	rs.free()


func _test_quit_warning() -> void:
	var keep: Dictionary = Game.team_match
	Game.team_match = {"online": true, "coop": true, "host": true, "size": 2}
	_check(PauseMenu.host_of_team(), "the host of an online co-op team match gets the QUIT warning")
	Game.team_match = {"online": true, "coop": true, "host": false, "size": 2}
	_check(not PauseMenu.host_of_team(), "the guest gets none")
	Game.team_match = {"online": false, "coop": false, "host": true, "size": 2}
	_check(not PauseMenu.host_of_team(), "an offline team match gets none")
	Game.team_match = keep
	_check(PauseMenu.HOST_WARNING.contains("HOST") and PauseMenu.HOST_WARNING.contains("TEAMMATE"), "the warning says why")
