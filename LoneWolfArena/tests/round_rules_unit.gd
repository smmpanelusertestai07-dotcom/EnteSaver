extends RefCounted
## Unit tests of a round's rules (run from tests/run_tests.gd, which counts the checks):
## - the two-stage clock: stage 1 is 20 s, stage 2 90 s (SQUAD 120 s), each counted down on its own;
## - the zone over time: the whole hall and still through stage 1, closing evenly in stage 2 to
##   0.5 m exactly at its end, the centre sliding to the final spot; the circles are nested;
## - the break between rounds: its steps in order (beat, result, score plates with the tick, the next
##   round's band) and about 10.5 s, so a round without a pick starts about 15.5 s after the kill;
##   the band's FINAL ROUND / MATCH POINT! line;
## - the 1 vs 1 weapon cooldown: a gun picked for a pair of rounds rests for the next 4 rounds
##   (4 ROUNDS, then 2), whoever picked it; both phones replace a pick that breaks it alike, and a
##   phone back from being away gets the same cooldowns from the "sync" text;
## - the pick panel: its header names the pair of rounds the pick holds for; the side that does not
##   pick sees it read-only (no choice, no tap, no callback, also when its ring runs out);
## - the kit: 3 shield walls a round; before a pick round's pick only the fists (await_pick), the
##   old gun cannot be drawn, and the pick ends it.

const ArenaCode := preload("res://scripts/arena.gd")     # (the arena script has no class name)

var t: Node


static func run(runner: Node) -> void:
	var me := new()
	me.t = runner
	me._stage_clock()
	me._zone_over_time()
	me._zone_start()
	me._match_end()
	me._break_steps()
	me._cooldown()
	me._pick_panel()
	me._kit()


func _check(cond: bool, what: String) -> void:
	t.call("_check", cond, what)


func _stage_clock() -> void:
	var s2 := RoundRules.STAGE2_S
	_check(RoundRules.STAGE1_S == 20.0 and s2 == 90.0 and RoundRules.SQUAD_STAGE2_S == 120.0,
		"stages: 20 s, then 90 s (SQUAD 120 s)")
	_check(RoundRules.fight_time(s2) == 110.0 and ArenaCode.ROUND_TIME == RoundRules.fight_time(s2),
		"a 1 vs 1 fight lasts both stages (110 s)")
	_check(RoundRules.stage_at(0.0) == 1 and RoundRules.stage_at(19.9) == 1 and RoundRules.stage_at(20.0) == 2,
		"stage 2 begins at 20 s")
	_check(HudDraw.time_text(RoundRules.stage_left(0.0, s2)) == "00:20" and HudDraw.time_text(RoundRules.stage_left(19.99, s2)) == "00:01",
		"stage 1 counts 00:20 down")
	_check(HudDraw.time_text(RoundRules.stage_left(20.0, s2)) == "01:30" and HudDraw.time_text(RoundRules.stage_left(109.99, s2)) == "00:01"
		and RoundRules.stage_left(115.0, s2) == 0.0, "stage 2 counts 01:30 down to 00:00")
	_check(HudDraw.time_text(RoundRules.stage_left(20.0, RoundRules.SQUAD_STAGE2_S)) == "02:00", "a SQUAD's stage 2 counts 02:00 down")
	_check(ArenaCode.PREP_TIME == 15.0 and ArenaCode.PREP_SHORT == 5.0, "the pick prep is 15 s, the round after it 5 s")


func _zone_over_time() -> void:
	var s2 := RoundRules.STAGE2_S
	var start := MapBuilder.ZONE_START_R
	var from := Vector3(0, 0, 0)
	var to := Vector3(14.0, 0, -9.0)
	var still := true
	for i in 21:
		var e := float(i) * 0.99
		still = still and RoundRules.zone_radius_at(e, start, s2) == start and RoundRules.zone_center_at(e, from, to, s2) == from
	_check(still, "through stage 1 the zone covers the whole hall and does not move")
	_check(is_equal_approx(RoundRules.zone_radius_at(110.0, start, s2), 0.5) and RoundRules.zone_radius_at(200.0, start, s2) == 0.5,
		"the zone is 0.5 m when stage 2 ends")
	_check(RoundRules.zone_center_at(110.0, from, to, s2).is_equal_approx(to), "its centre reaches the round's final spot")
	var mid := RoundRules.zone_radius_at(65.0, start, s2)
	_check(is_equal_approx(mid, (start + 0.5) * 0.5), "it closes evenly (half way at the middle of stage 2: %.2f m)" % mid)
	_check(RoundRules.zone_radius_at(20.5, start, s2) < start, "it starts closing in the first second of stage 2")
	# The farthest final spot (zone_final_for) moves less than the radius shrinks: nested circles.
	var far := Vector3(MapBuilder.HX - ArenaCode.ZONE_EDGE - 1.0, 0, MapBuilder.HZ - ArenaCode.ZONE_EDGE - 1.0)
	var nested := true
	for i in 90:
		var e := 20.0 + float(i)
		var c0 := RoundRules.zone_center_at(e, from, far, s2)
		var c1 := RoundRules.zone_center_at(e + 1.0, from, far, s2)
		nested = nested and c0.distance_to(c1) <= RoundRules.zone_radius_at(e, start, s2) - RoundRules.zone_radius_at(e + 1.0, start, s2)
	_check(nested, "each later circle lies inside the earlier ones")
	# Stage 2 starts wide (a tuning from an estimate): about 1.1-1.15 x the hall's long side, so a
	# fighter standing at its spawn end stays inside until roughly the last 35-45 s (the final spot
	# in the middle; nearer or farther spots move that by some seconds).
	var long_side := MapBuilder.HX * 2.0
	_check(start >= 1.1 * long_side and start <= 1.15 * long_side, "stage 2 starts at %.1f m, %.2f x the hall's long side" % [start, start / long_side])
	var spawn := Vector3(-MapBuilder.HX - 2.0, 0, 0)
	var out_at := -1.0
	for i in 1100:
		var e := float(i) * 0.1
		if out_at < 0.0 and spawn.distance_to(RoundRules.zone_center_at(e, from, from, s2)) > RoundRules.zone_radius_at(e, start, s2):
			out_at = e
	var left := RoundRules.fight_time(s2) - out_at
	_check(out_at > 0.0 and left >= 35.0 and left <= 45.0, "the spawn end leaves the zone with %.0f s of stage 2 left" % left)
	var r40 := RoundRules.zone_radius_at(RoundRules.STAGE1_S + 41.0, start, s2)
	_check(r40 > 0.5 * long_side and r40 < 0.7 * long_side, "41 s into stage 2 the circle is still %.2f of the hall wide" % (r40 / long_side))
	_check(is_equal_approx(RoundRules.zone_next(5.0, s2), 15.0) and is_equal_approx(RoundRules.zone_next(30.0, s2), 80.0),
		"zone_next: to the closing in stage 1, to its end in stage 2")


func _break_steps() -> void:
	var order := []
	var at := 0.0
	while at < 12.0:
		var st := RoundRules.break_step(at)
		if order.is_empty() or order[-1] != st:
			order.append(st)
		at += 0.05
	_check(order == ["beat", "result", "score", "band", "done"], "the break: a beat, the result, the score plates, the round band (%s)" % str(order))
	_check(RoundRules.BREAK_RESULT_AT >= 1.0 and RoundRules.BREAK_RESULT_AT <= 3.0, "the result band comes after a short beat")
	_check(RoundRules.BREAK_S >= 10.0 and RoundRules.BREAK_S <= 11.0 and ArenaCode.BREAK_TIME == RoundRules.BREAK_S,
		"the break lasts 10-11 s, the arena's break too")
	var to_go := RoundRules.BREAK_S + ArenaCode.PREP_SHORT
	_check(to_go >= 15.0 and to_go <= 16.5, "a round without a pick starts about 16 s after the kill (%.1f s)" % to_go)
	_check(RoundRules.break_step(RoundRules.BREAK_S - 0.01) == "band" and RoundRules.break_step(RoundRules.BREAK_BAND_AT - 0.01) == "score",
		"the next round's band closes the break, before the prep")
	_check(RoundRules.break_score(RoundRules.BREAK_SCORE_AT + 0.1, 2, 3) == 2 and RoundRules.break_score(RoundRules.BREAK_TICK_AT, 2, 3) == 3
		and RoundRules.BREAK_TICK_AT > RoundRules.BREAK_SCORE_AT and RoundRules.BREAK_TICK_AT < RoundRules.BREAK_BAND_AT,
		"the winner's number counts up on the plates, from the old score")
	_check(RoundRules.round_sub(9, 9, 4, 4, 5) == "FINAL ROUND" and RoundRules.round_sub(6, 9, 4, 1, 5) == "MATCH POINT!"
		and RoundRules.round_sub(3, 9, 1, 1, 5) == "" and RoundRules.round_sub(2, 1, 0, 0, 1) == "", "the band's FINAL ROUND / MATCH POINT! line")


func _cooldown() -> void:
	var guns := ["ar", "smg", "lever", "sg"]
	var picks := {1: "ar"}
	_check(RoundRules.pick_round_of(1) == 1 and RoundRules.pick_round_of(2) == 1 and RoundRules.pick_round_of(4) == 3,
		"a pick holds for a pair of rounds")
	_check(RoundRules.cooldown_left("ar", 3, picks) == 4 and RoundRules.cooldown_left("ar", 5, picks) == 2
		and RoundRules.cooldown_left("ar", 7, picks) == 0, "a gun picked for rounds 1-2 rests 4 rounds, then 2, then is free")
	_check(RoundRules.cooldown_left("smg", 3, picks) == 0 and RoundRules.cooldown_left("ar", 1, picks) == 0,
		"other guns are free, and a pick does not block its own round")
	picks[3] = "smg"
	var cd := RoundRules.cooldowns(guns, 5, picks)
	_check(cd == {"ar": 2, "smg": 4}, "both sides' picks rest, whoever picked (%s)" % str(cd))
	_check(RoundRules.legal_pick("ar", guns, 5, picks) == "lever" and RoundRules.legal_pick("sg", guns, 5, picks) == "sg",
		"a pick that breaks the cooldown becomes the first free gun")
	_check(RoundRules.legal_pick("nuke", guns, 5, picks) == "lever", "an unknown gun becomes the first free gun")
	# Both phones: the same picks give the same answer, and the "sync" text carries them over.
	var other := RoundRules.picks_from_text(RoundRules.picks_text(picks), guns)
	_check(other == picks and RoundRules.cooldowns(guns, 5, other) == cd, "the other phone works the cooldowns out alike (%s)" % RoundRules.picks_text(picks))
	_check(RoundRules.picks_from_text("1:ar,x:smg,3:nuke,200:sg", guns) == {1: "ar"}, "a sync text keeps only real rounds and guns")
	_check(RoundRules.picker_rows(9, true) == [true, true, false, false, true, true, false, false, true]
		and RoundRules.picker_rows(4, false) == [false, false, true, true], "the ROUNDS strip: the picks alternate by pair")
	# The arena: a pick on cooldown is replaced, the bot never picks one, the preselection skips one.
	var a: Node3D = ArenaCode.new()
	a.round_index = 3
	a.picks = {1: "ar"}
	var saved := String(Game.settings.get("last_pick", "ar"))
	Game.settings.last_pick = "ar"
	_check(a.legal_pick("ar") == String(Weapons.PICKABLE[1]) and a.preselected_pick() != "ar", "the arena skips the resting gun")
	var bot_ok := true
	for i in 40:
		bot_ok = bot_ok and a._bot_choice() != "ar"
	_check(bot_ok, "the bot never picks a gun on cooldown")
	a.practice = true
	_check(a.pick_cooldowns().is_empty() and a.legal_pick("ar") == "ar", "the target dummy has no cooldown")
	Game.settings.last_pick = saved
	a.free()


func _pick_panel() -> void:
	_check(RoundRules.pick_span(1, 9) == "ROUNDS 1-2" and RoundRules.pick_span(4, 9) == "ROUNDS 3-4"
		and RoundRules.pick_span(9, 9) == "ROUND 9" and RoundRules.pick_span(1, 1) == "ROUND 1", "the pick covers a pair of rounds (the last one alone)")
	var words := func(parts: Array) -> String:
		var out := ""
		for p: Array in parts:
			out += String(p[0])
		return out
	_check(words.call(HudPanels.pick_header(1, 9)) == "PICK FOR ROUNDS 1-2", "the picker's header names its rounds")
	_check(words.call(HudPanels.pick_header(3, 9, "Rex")) == "WAITING FOR REX TO PICK FOR ROUNDS 3-4", "the waiting side's header")
	_check(words.call(HudPanels.pick_header(2, 3, "", true)) == "PICK YOUR WEAPON FOR ROUND 2"
		and words.call(HudPanels.pick_header(1, 0)) == "PICK YOUR WEAPON", "DUO / SQUAD and the target dummy headers")
	var hp := HudPanels.new()
	hp.size = Vector2(1560, 720)
	var got := []
	var cb := func(id: String) -> void: got.append(id)
	hp.open_pick(Weapons.PICKABLE, "ar", 14.0, cb, 3, {"ar": 4}, RoundRules.picker_rows(9, true), "REX", 9)
	_check(hp.watching() and hp.pick_choice == "", "the waiting side's panel is read-only with no choice marked")
	hp.tap(hp.card_rect(1).get_center())
	hp.tap(hp.select_rect().get_center())
	_check(hp.pick_choice == "" and hp.pick_open and got.is_empty(), "a card or SELECT tap does nothing there")
	hp.tick(20.0, 0.1)
	_check(hp.pick_open and got.is_empty() and hp.pick_left == 0.0, "its ring runs out without a pick")
	hp.tap(hp.pick_close_rect().get_center())
	_check(not hp.pick_open and not hp.watching(), "its X closes it")
	hp.open_pick(Weapons.PICKABLE, "ar", 14.0, cb, 1, {}, RoundRules.picker_rows(9, true), "", 9)
	_check(not hp.watching() and hp.pick_choice == "ar", "the picker's panel keeps its choice")
	hp.tick(20.0, 0.1)
	_check(got == ["ar"] and not hp.pick_open, "the picker's timer still picks")
	hp.free()


func _kit() -> void:
	var f := Fighter.new()
	_check(Fighter.START_SHIELDS == 3 and f.shields == 3, "a round starts with 3 shield walls")
	f.set_loadout("sniper")
	f.await_pick()
	_check(f.awaiting_pick and f.current == 1 and f.weapon().id == "fists", "before the pick only the fists are in hand")
	f.switch_weapon(0)
	_check(f.current == 1, "the last pair's gun cannot be drawn before the pick")
	f.set_loadout("smg")
	_check(not f.awaiting_pick and f.current == 0 and f.gun().id == "smg", "the pick equips its gun")
	f.free()


## Round 8: the zone starts outside the walls (0.58 x the map's diagonal) and comes onto the
## whole-arena minimap (its view: the long side + 5 %) a while into stage 2, not at its first second.
func _zone_start() -> void:
	var mr := Rect2(-27.6, -15.6, 55.2, 31.2)
	var r0 := RoundRules.zone_start_for(mr, 47.0)
	_check(is_equal_approx(r0, 0.58 * mr.size.length()), "the zone starts at 0.58 x the map's diagonal (%.1f m)" % r0)
	_check(r0 > mr.size.length() * 0.5, "the starting circle lies outside the walls' corners")
	var half_view := HudMinimap.view_m(mr) * 0.5
	var enter := -1.0
	for i in 900:
		var el := RoundRules.STAGE1_S + i * 0.1
		if RoundRules.zone_radius_at(el, r0, RoundRules.STAGE2_S) < half_view:
			enter = i * 0.1
			break
	_check(enter >= 5.0 and enter <= 40.0, "the circle reaches the minimap's sides %.0f s into stage 2" % enter)
	_check(RoundRules.zone_start_for(Rect2(), 47.0) == 47.0, "a map without a rect keeps its own start")
	_check(RoundRules.zone_start_for(mr, MapBuilder.ZONE_START_R, true) == MapBuilder.ZONE_START_R,
		"online the zone starts at the map's own radius (what a 1.9.x phone uses: both phones draw the same circle)")


## Round 8: the match's end in steps; a win's VICTORY! sequence before the results, a loss's
## results 1-2 s after its band.
func _match_end() -> void:
	var seq := []
	for i in 80:
		var st := RoundRules.match_end_step(i * 0.1, true)
		if seq.is_empty() or seq[-1] != st:
			seq.append(st)
	_check(seq == ["beat", "band", "word", "top", "results"], "a win: beat, band, VICTORY!, band at the top, results (%s)" % [seq])
	_check(is_equal_approx(RoundRules.VICTORY_WORD_S, 1.5) and RoundRules.RESULTS_WIN_AT > RoundRules.VICTORY_TOP_AT, "the big word stays 1.5 s, then the band at the top")
	var lost := []
	for i in 80:
		var st := RoundRules.match_end_step(i * 0.1, false)
		if lost.is_empty() or lost[-1] != st:
			lost.append(st)
	_check(lost == ["beat", "band", "results"], "a loss: beat, the DEFEAT band, results (%s)" % [lost])
	var after := RoundRules.results_at(false) - RoundRules.MATCH_BAND_AT
	_check(after >= 1.0 and after <= 2.0, "a loss's results come 1-2 s after its band")
