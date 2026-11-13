extends RefCounted
## Unit tests of DUO / SQUAD, WP-C: TeamReferee knocks, wipes, revives, time-outs and members who
## left; team spawns in the alcoves; ally_of, friendly fire, a fighter's own frag, the knock / bleed /
## revive numbers; the offline and two-phone rosters.
## Run from tests/run_tests.gd (which counts the checks).

var t: Node


static func run(runner: Node) -> void:
	var me := new()
	me.t = runner
	me._test_referee()
	me._test_referee_out()
	me._test_spawns()
	me._test_fighters()
	me._test_rosters()


func _check(cond: bool, what: String) -> void:
	t.call("_check", cond, what)


func _ref(size: int) -> TeamReferee:
	var r := TeamReferee.new()
	var teams := {}
	for i in size * 2:
		teams[i] = 0 if i < size else 1
	r.setup(teams)
	return r


func _test_referee() -> void:
	# SQUAD: slots 0-3 against 4-7.
	var r := _ref(4)
	var d := r.down(1, 4, true, "gun", false)
	_check(d == [["ko", 1, 4, true, "gun"]] and r.status[1] == TeamReferee.KNOCKED,
		"a fighter downed with a teammate UP is KNOCKED (%s)" % str(d))
	_check(r.winner() == -1 and r.up_count(0) == 3, "a knock does not end the round")
	_check(not r.revive(4, 1), "an enemy cannot revive")
	_check(not r.revive(1, 1), "nobody revives themselves")
	_check(not r.revive(0, 2), "an UP fighter needs no revive")
	_check(r.revive(0, 1) and r.status[1] == TeamReferee.UP and r.knocker[1] == -1, "a teammate revives a KNOCKED fighter")
	_check(r.down(1, 4, false, "gun", false)[0][0] == "ko" and r.down(2, 5, false, "frag", false)[0][0] == "ko",
		"knocked again, and a second teammate")
	_check(not r.revive(2, 1), "a KNOCKED fighter cannot revive")
	# finished off: by an enemy (their kill), by the zone and by bleeding out (the knocker's kill)
	_check(r.down(1, 6, true, "gun", true) == [["el", 1, 6, true, "gun"]], "a knocked fighter finished by an enemy is that enemy's kill")
	_check(r.down(2, -1, false, "bleed", true) == [["el", 2, 5, false, "bleed"]], "bleeding out is the knocker's kill")
	_check(r.down(2, 4, false, "gun", true).is_empty(), "an OUT fighter goes down no more")
	_check(r.down(3, 7, false, "gun", false)[0][0] == "ko", "slot 3 knocked: slot 0 is the last one UP")
	_check(r.down(3, 0, false, "gun", true) == [["el", 3, 7, false, "gun"]], "a teammate finishing is no kill of theirs (the knocker's)")
	# the last one standing goes out and nobody is left KNOCKED
	var r2 := _ref(2)
	r2.down(1, 2, false, "frag", false)
	var wipe := r2.down(0, 3, true, "gun", false)
	_check(wipe == [["el", 0, 3, true, "gun"], ["el", 1, 2, false, "frag"]],
		"the last one UP down: out, and the knocked teammate with it, the knocker's kill (%s)" % str(wipe))
	_check(r2.winner() == 1, "a team with nobody UP loses the round")
	r2.reset_round()
	_check(r2.winner() == -1 and r2.up_count(0) == 2 and r2.up_count(1) == 2, "a new round: everyone UP again")
	r2.down(0, 2, false, "gun", false)
	r2.down(1, 2, false, "gun", false)
	r2.down(2, 0, false, "zone", false)
	r2.down(3, -1, false, "zone", false)
	_check(r2.winner() == 2, "both teams down: a draw")
	# time-out: the UP fighters' HP in all (knocked count 0); within 0.5 a draw
	var r3 := _ref(2)
	_check(r3.timeout_winner({0: 50.0, 1: 30.0, 2: 70.0, 3: 0.0}) == 0, "time-out: more HP in all wins")
	r3.down(0, 2, false, "gun", false)
	_check(r3.timeout_winner({0: 100.0, 1: 30.0, 2: 20.0, 3: 20.0}) == 1, "time-out: a knocked fighter's HP counts 0")
	_check(r3.timeout_winner({0: 0.0, 1: 40.2, 2: 20.0, 3: 20.0}) == -1, "time-out: within 0.5 HP a draw")


func _test_referee_out() -> void:
	var r := _ref(2)
	_check(r.leave(1) == [["el", 1, -1, false, "left"]], "a member who left is out")
	r.reset_round()
	_check(r.status[1] == TeamReferee.OUT and r.up_count(0) == 1, "and stays out in the next round")
	_check(r.leave(1).is_empty(), "leaving twice changes nothing")
	var r2 := _ref(2)
	r2.down(0, 2, false, "gun", false)
	var d := r2.leave(1)
	_check(d == [["el", 1, -1, false, "left"], ["el", 0, 2, false, "gun"]], "the last one UP leaving wipes the knocked teammate (%s)" % str(d))


func _test_spawns() -> void:
	var mb := MapBuilder.new()
	for side in 2:
		var base: Vector3 = mb.spawn_a if side == 0 else mb.spawn_b
		var yaw: float = mb.spawn_a_yaw if side == 0 else mb.spawn_b_yaw
		var spots: Array[Vector3] = []
		for i in 4:
			spots.append(TeamArena.spawn_spot(base, yaw, i))
		var inside := true
		for p in spots:
			var depth := absf(p.x) - MapBuilder.HX
			inside = inside and depth > 0.5 and depth < MapBuilder.AL_D - 0.5 and absf(p.z) < MapBuilder.AL_HW - 0.5
		var apart := true
		for i in 4:
			for j in range(i + 1, 4):
				apart = apart and spots[i].distance_to(spots[j]) >= 1.0
		_check(inside, "team %d spawns inside its alcove (%s)" % [side, str(spots)])
		_check(apart, "team %d spawns at least 1 m apart" % side)


func _test_fighters() -> void:
	_check(Fighter.KNOCK_HP == 100.0 and Fighter.BLEED_S == 30.0 and Fighter.KNOCK_SPEED == 0.8 and Fighter.REVIVE_S == 5.0
		and Fighter.REVIVE_HP == 50.0 and Fighter.REVIVE_RANGE == 2.0, "knock / bleed / revive numbers")
	var a := Bot.new()
	var b := Bot.new()
	var c := Bot.new()
	var solo := Bot.new()
	a.team = 0
	b.team = 0
	c.team = 1
	_check(a.ally_of(b) and not a.ally_of(c) and not a.ally_of(a) and not solo.ally_of(a) and not a.ally_of(null), "ally_of")
	_check(b.take_damage(60.0, "body", a, Vector3.ZERO) == 0.0 and b.hp == Fighter.MAX_HP, "friendly fire takes no HP")
	_check(b.take_damage(60.0, "body", a, Vector3.ZERO, "frag") == 0.0 and b.hp == Fighter.MAX_HP, "a teammate's frag takes no HP")
	_check(a.take_damage(30.0, "body", a, Vector3.ZERO, "frag") > 0.0 and a.hp < Fighter.MAX_HP, "a fighter's own frag still hurts it")
	var knocks := [0]
	c.knocked_down.connect(func(_v: Fighter, _k: Fighter, _h: bool) -> void: knocks[0] += 1)
	c.take_damage(9999.0, "head", a, Vector3.ZERO)
	_check(c.alive and c.knocked and c.knock_hp == Fighter.KNOCK_HP and c.hp == 0.0 and c.knocked_by == a and knocks[0] == 1,
		"HP gone in a team match: KNOCKED, not out")
	_check(c.stance == Fighter.Stance.PRONE and not c.set_stance(Fighter.Stance.STAND), "a knocked fighter lies prone and stays down")
	var finished := [0]
	c.knock_finished.connect(func(_v: Fighter, _k: Fighter, _h: bool) -> void: finished[0] += 1)
	var took := c.take_damage(40.0, "body", a, Vector3.ZERO)
	_check(took > 0.0 and is_equal_approx(c.knock_hp, Fighter.KNOCK_HP - took) and finished[0] == 0, "hits take knock HP")
	c.stand_up(Fighter.REVIVE_HP, null)
	_check(not c.knocked and c.hp == Fighter.REVIVE_HP and c.alive, "a revive stands it up with REVIVE_HP")
	c.take_damage(9999.0, "head", a, Vector3.ZERO)
	c.take_damage(9999.0, "head", a, Vector3.ZERO)
	_check(c.knocked and c.knock_hp == 0.0 and finished[0] == 1 and c.alive, "knock HP gone: finished once, out on the referee's word")
	solo.take_damage(9999.0, "head", c, Vector3.ZERO)
	_check(not solo.alive and not solo.knocked, "the 1 vs 1 never knocks")
	for f: Fighter in [a, b, c, solo]:
		f.free()


func _test_rosters() -> void:
	var m := TeamArena.offline_match(4, "training", 1)
	var roster: Array = m.roster
	var team0 := roster.filter(func(e: Dictionary) -> bool: return int(e.team) == 0).size()
	_check(roster.size() == 8 and team0 == 4 and not bool(roster[0].bot) and bool(roster[1].bot) and int(m.my_slot) == 0
		and not bool(m.online) and String(m.mode_id) == "training", "TRAINING SQUAD: the player and 7 bots, 4 a team")
	var host := {"id": "AAAA", "name": "HOSTY", "bundle": "neon"}
	var guest := {"id": "BBBB", "name": "GUESTY", "bundle": "royal"}
	for coop: bool in [true, false]:
		var a := TeamArena.link_match(2, coop, host, guest, true, 1234)
		var b := TeamArena.link_match(2, coop, host, guest, false, 1234)
		var gs := 1 if coop else 2
		_check(a.roster == b.roster and int(a.my_slot) == 0 and int(b.my_slot) == gs and String(b.roster[gs].name) == "GUESTY"
			and int(b.roster[gs].team) == (0 if coop else 1), "two phones build the same roster (coop %s)" % coop)
	_check(TeamArena.team_rounds_to_win() >= 1, "team matches have a round goal")
