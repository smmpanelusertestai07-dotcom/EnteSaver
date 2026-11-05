extends RefCounted
## Unit tests of the match's polish (run from tests/run_tests.gd, which counts the checks):
## - the round cap: rounds that keep ending in draws still end the match at Arena.MAX_ROUNDS (the
##   best-of when that is shorter); the most rounds won wins, level is a draw;
## - the end-of-match numbers ("fin") another phone sends are checked field by field;
## - an opponent who went down by itself (zone, fall, own frag) gets the out banner, never the
##   kill's ELIMINATED badge;
## - in the ONLINE lists only the row of the player a challenge waits for reads CANCEL.

const ArenaCode := preload("res://scripts/arena.gd")     # (the arena script has no class name)

var t: Node


static func run(runner: Node) -> void:
	var me := new()
	me.t = runner
	me._round_cap()
	me._final_numbers()
	me._out_banner()
	me._challenge_rows()


func _check(cond: bool, what: String) -> void:
	t.call("_check", cond, what)


func _round_cap() -> void:
	# First to 5: all draws end after round 9; a lead at round 9 wins it; 5 wins end it early.
	var ends := -1
	for r in range(1, 20):
		if ArenaCode.match_over_after(r, 0, 0, 5):
			ends = r
			break
	_check(ends == 9, "first to 5: rounds that keep ending in draws still end the match after round 9 (got %d)" % ends)
	_check(not ArenaCode.match_over_after(8, 4, 4, 5) and ArenaCode.match_over_after(9, 4, 3, 5) and ArenaCode.match_over_after(6, 5, 1, 5),
		"round 9 is the last one; five wins end the match before it")
	# A custom room's first to 7 is capped too (its best-of would be 13 rounds).
	_check(ArenaCode.match_over_after(ArenaCode.MAX_ROUNDS, 6, 3, 7) and not ArenaCode.match_over_after(ArenaCode.MAX_ROUNDS - 1, 6, 2, 7),
		"first to 7 still ends at round %d" % ArenaCode.MAX_ROUNDS)
	_check(ArenaCode.match_over_after(1, 0, 0, 1) and not ArenaCode.match_over_after(2, 1, 1, 2) and ArenaCode.match_over_after(3, 1, 1, 2),
		"first to 1 is one round; first to 2 three at most")


func _final_numbers() -> void:
	var host := [9, 312.5, 140, 0, 4, 3, 4, 1210, 5, 96, 41]
	var f := ArenaCode.final_from(host, true)
	_check(not f.is_empty() and is_equal_approx(float(f.time), 312.5) and int(f.host_hp) == 140 and int(f.guest_hp) == 0
		and int(f.host_score) == 4 and int(f.guest_score) == 3 and int(f.kills) == 4 and int(f.damage) == 1210
		and int(f.headshots) == 5 and int(f.shots) == 96 and int(f.hits) == 41, "the host's end-of-match numbers are read field by field")
	var guest := [9, -1, -1, -1, -1, -1, 3, 880, 2, 70, 30]
	_check(not ArenaCode.final_from(guest, false).is_empty() and ArenaCode.final_from(guest, true).is_empty(),
		"a guest's numbers carry no time, HP or score (only the host's count for those)")
	var bad := 0
	for broken: Array in [host.slice(0, 10), [9, 312.5, 140, 0, 4, 3, 4, 1210, 5, 96, 97], [9, 312.5, 260, 0, 4, 3, 4, 1210, 5, 96, 41],
			[9, 312.5, 140, 0, 4, 3, 4, 1210, 50, 96, 41], [9, "x", 140, 0, 4, 3, 4, 1210, 5, 96, 41], [9, 312.5, 140, 0, 4, 3, -1, 1210, 5, 96, 41],
			[9, NAN, 140, 0, 4, 3, 4, 1210, 5, 96, 41], [9, 312.5, 140, 0, 40, 3, 4, 1210, 5, 96, 41]]:
		if not ArenaCode.final_from(broken, true).is_empty():
			bad += 1
	_check(bad == 0, "numbers that cannot be (more hits than shots, HP over 200, text, NaN, a missing field) are dropped (%d got through)" % bad)


func _out_banner() -> void:
	var hud := HUD.new()
	_check(hud.banner_kind() == "", "no banner at first")
	hud.out_banner("RIVAL", "zone")
	var zone := hud.banner_kind()
	hud.kill_banner("RIVAL", false)
	var kill := hud.banner_kind()
	hud.out_banner("RIVAL", "left")         # (a player who left: OPPONENT LEFT says it, no plate)
	var left := hud.banner_kind()
	_check(zone == "zone" and kill == "kill" and left == "kill" and HUD.OUT_LINES.has("fall") and HUD.OUT_LINES.has("self")
		and not HUD.OUT_LINES.has("gun") and not String(HUD.OUT_LINES.zone).contains("ELIMINATED"),
		"a zone death shows its own line (not ELIMINATED); a kill shows the badge; leaving shows neither")
	hud.free()


func _challenge_rows() -> void:
	var saved := Game.profile.duplicate(true)
	var saved_at := Game.autotest
	Game.autotest = "unit"
	Game.profile = Game.DEFAULT_PROFILE.duplicate(true)
	var cl := Cloud.new()
	var a := "a".sha256_text().left(32)
	var b := "b".sha256_text().left(32)
	cl.peers = {a: {"name": "ALPHA", "bundle": "default", "pk": "", "seen": 0}, b: {"name": "BRAVO", "bundle": "default", "pk": "", "seen": 0}}
	cl.opponent = {"id": a, "name": "ALPHA", "bundle": "default"}       # (Cloud.invite sets it up for the challenge)
	var lf := LobbyFriends.new(null)
	var row_a: HBoxContainer = lf._player_row(cl, a, "ALPHA", "ALPHA")
	var row_b: HBoxContainer = lf._player_row(cl, b, "BRAVO", "ALPHA")
	var free_b: HBoxContainer = lf._player_row(cl, b, "BRAVO", "")
	_check(row_a.find_child("Cancel_" + Cloud.friend_code(a), true, false) != null and row_b.find_child("Duel_" + Cloud.friend_code(b), true, false) != null
		and row_b.find_child("Cancel_" + Cloud.friend_code(b), true, false) == null and free_b.find_child("Duel_" + Cloud.friend_code(b), true, false) != null,
		"while a challenge to one player waits, only their row reads CANCEL; the others keep DUEL 1 VS 1")
	for n: Node in [row_a, row_b, free_b, cl]:
		n.free()
	Game.profile = saved
	Game.autotest = saved_at
