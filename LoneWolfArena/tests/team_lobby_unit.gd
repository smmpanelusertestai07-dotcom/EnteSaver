extends RefCounted
## Unit tests of DUO / SQUAD in the lobby (WP-B1), run from tests/run_tests.gd (which counts the
## checks):
## - the team size setting (Game.team_size) keeps only SOLO 1, DUO 2, SQUAD 4;
## - START's routing for each mode and size (Lobby.start_route), with online teams on and off;
##   the mode card's format line and SELECT MODE's card lines for each size;
## - the records (R8): duo / squad matches count in their own numbers, keep size, bots and the
##   friend in HISTORY, "ended" is no win, and all of it survives a save and a load; a profile from
##   before DUO / SQUAD loads them as zeros;
## - HISTORY's row texts ("DUO · VS BOTS", "SQUAD · WITH <NAME>", "DUO · VS <NAME>");
## - the TEAM bar (shown, its tiles), the invite list's order, the TEAM INVITE popup's words;
## - a session a team invite started becomes the team match (the same roster on both phones), a
##   duel's never does; the team match's loading card.

var t: Node


static func run(runner: Node) -> void:
	var me := new()
	me.t = runner
	me._team_size()
	me._routing()
	me._records()
	me._history_texts()
	me._team_bar()
	me._invites()
	me._session()
	me._loading_card()


func _check(cond: bool, what: String) -> void:
	t.call("_check", cond, what)


func _team_size() -> void:
	var saved: Dictionary = Game.settings.duplicate(true)
	Game.team_size = 2
	_check(Game.team_size == 2 and int(Game.settings.team_size) == 2, "DUO is kept as the setting team_size")
	Game.team_size = 4
	_check(Game.team_size == 4, "SQUAD is kept")
	Game.team_size = 3
	_check(Game.team_size == 1, "a size of 3 sets SOLO")
	Game.settings.team_size = 3
	_check(Game.team_size == 1, "a saved size of 3 reads as SOLO")
	Game.settings.team_size = "two"
	_check(Game.team_size == 1, "a saved size that is no number reads as SOLO")
	_check(Game.DEFAULT_SETTINGS.team_size == 1 and Game.TEAM_SIZES == [1, 2, 4], "a new install plays SOLO")
	Game.settings = saved


func _routing() -> void:
	var saved: Dictionary = Game.settings.duplicate(true)
	var saved_practice := Game.practice
	_check(Lobby.start_route("training", 1) == "training" and Lobby.start_route("training", 2) == "training_team"
		and Lobby.start_route("training", 4) == "training_team", "START in TRAINING GROUND: SOLO the 1 vs 1, DUO / SQUAD the team match here")
	_check(Lobby.start_route("lonewolf", 1) == "quick" and Lobby.start_route("lonewolf", 2, true) == "team_search"
		and Lobby.start_route("lonewolf", 4, true) == "team_search", "START in LONE WOLF: SOLO QUICK MATCH, DUO / SQUAD the team search")
	_check(Lobby.start_route("lonewolf", 2, false) == "team_later" and Lobby.start_route("lonewolf", 1, false) == "quick"
		and Lobby.start_route("training", 4, false) == "training_team", "online teams off: only LONE WOLF DUO / SQUAD waits for the next update")
	Game.settings.difficulty = 1
	Game.practice = false
	Game.mode = "training"
	Game.team_size = 2
	_check(Lobby.mode_format() == "DUO  ·  BOT: NORMAL", "the mode card in TRAINING DUO (%s)" % Lobby.mode_format())
	Game.practice = true
	_check(Lobby.mode_format().begins_with("DUO"), "a team match is never against the dummy")
	Game.practice = false
	Game.team_size = 4
	_check(Lobby.mode_format() == "SQUAD  ·  BOT: NORMAL", "the mode card in TRAINING SQUAD")
	Game.mode = "lonewolf"
	_check(Lobby.mode_format(true) == "SQUAD  ·  4 VS 4 ONLINE" and Lobby.mode_format(false) == "SQUAD: NEXT UPDATE",
		"the mode card in LONE WOLF SQUAD, online teams on and off")
	Game.team_size = 1
	_check(Lobby.mode_format() == "1 VS 1 ONLINE", "LONE WOLF SOLO is the 1 vs 1 as before")
	Game.mode = "training"
	_check(Lobby.mode_format() == "BOT: NORMAL  ·  FIRST TO %d" % Game.rounds_to_win(), "TRAINING SOLO as before")
	_check(LobbyDialogs.mode_lines("training", 1) == LobbyDialogs.MODE_INFO.training.lines
		and LobbyDialogs.mode_lines("lonewolf", 1) == LobbyDialogs.MODE_INFO.lonewolf.lines, "SELECT MODE's SOLO lines are today's")
	var duo: Array = LobbyDialogs.mode_lines("training", 2)
	_check(String(duo[0]) == "DUO · YOU + A BOT VS 2 BOTS · BOT: NORMAL" and "DUMMY IS SOLO ONLY" in duo, "TRAINING DUO's card lines (%s)" % str(duo))
	_check(String(LobbyDialogs.mode_lines("lonewolf", 4, true)[0]) == "SQUAD · 4 VS 4 · REAL PLAYERS"
		and String(LobbyDialogs.mode_lines("lonewolf", 2, false)[0]) == "ONLINE DUO / SQUAD: NEXT UPDATE", "LONE WOLF DUO / SQUAD card lines")
	_check(TeamMatch.fill_s() >= 1.0 and TeamMatch.FILL_S == 25.0, "the team search plays bots after FILL_S (LW_FILL_S in tests)")
	_check(Loading.team_rounds_to_win() >= 1, "a team match is first to TEAM_ROUNDS_TO_WIN (LW_ROUNDS_TO_WIN in tests)")
	Game.settings = saved
	Game.practice = saved_practice


## The R8 regression: duo / squad numbers through record_match, sanitising, a save and a load.
func _records() -> void:
	var saved_profile: Dictionary = Game.profile.duplicate(true)
	var saved_result: Dictionary = Game.last_result
	var saved_tm: Dictionary = Game.team_match
	var at := Game.autotest
	Game.autotest = "unit"           # nothing is written to user://
	Game.profile = Game.DEFAULT_PROFILE.duplicate(true)
	_check(Game.RECORD_MODES.keys() == ["training", "lonewolf", "duo", "squad"] and Game.MODE_NAMES.keys() == ["training", "lonewolf"],
		"the records know four modes, START two")
	_check(Game.RECORD_MODES.keys().all(func(m: String) -> bool: return Game.DEFAULT_PROFILE.modes.has(m)), "a new profile has numbers for every mode")
	var friend := "teammate".sha256_text().left(32)
	var rival := "rival team".sha256_text().left(32)
	# A friend's TEAM INVITE (coop DUO), won.
	Game.team_match = TeamArena.link_match(2, true, {"id": "a".repeat(32), "name": "ME", "bundle": "default"},
		{"id": friend, "name": "Buddy", "bundle": "neon"}, true, 7)
	Game.count_match("duo")
	Game.record_match({"won": true, "kills": 3, "xp": 300, "mode_id": "duo", "team": true, "team_size": 2, "bots": 2,
		"enemy": "ORANGE TEAM", "enemy_id": "", "score_player": 4, "score_bot": 1})
	# A team search against another player (vs SQUAD), lost.
	Game.team_match = TeamArena.link_match(4, false, {"id": rival, "name": "RIVAL", "bundle": "neon"},
		{"id": "a".repeat(32), "name": "ME", "bundle": "default"}, false, 9)
	Game.count_match("squad")
	Game.record_match({"won": false, "kills": 2, "xp": 100, "mode_id": "squad", "team": true, "team_size": 4, "bots": 6,
		"enemy": "RIVAL", "enemy_id": rival, "score_player": 2, "score_bot": 4})
	# The host left a TEAM INVITE match: ENDED, never a win.
	Game.team_match = TeamArena.link_match(2, true, {"id": friend, "name": "BUDDY", "bundle": "neon"},
		{"id": "a".repeat(32), "name": "ME", "bundle": "default"}, false, 11)
	Game.count_match("duo")
	Game.record_match({"won": true, "ended": true, "kills": 1, "mode_id": "duo", "team": true, "team_size": 2, "bots": 2,
		"enemy": "ORANGE TEAM", "enemy_id": ""})
	# Nobody found: the team against bots here.
	Game.team_match = TeamArena.offline_match(4, "squad", 1)
	Game.count_match("squad")
	Game.record_match({"won": true, "kills": 4, "mode_id": "squad", "team": true, "team_size": 4, "bots": 7,
		"enemy": "ORANGE TEAM", "enemy_id": ""})
	var p := Game.profile
	_check(p.modes.duo == {"matches": 2, "wins": 1, "kills": 4} and p.modes.squad == {"matches": 2, "wins": 1, "kills": 6},
		"DUO and SQUAD count in their own numbers (%s)" % str(p.modes))
	_check(p.modes.training == {"matches": 0, "wins": 0, "kills": 0} and int(p.matches) == 4 and int(p.wins) == 2,
		"team matches are never counted as TRAINING GROUND")
	var h: Array = p.history
	_check(h.size() == 4 and h[3].mode == "duo" and h[3].result == "won" and h[3].size == 2 and h[3].bots == 2 and h[3].with == "BUDDY"
		and h[3].id == "", "HISTORY keeps a TEAM INVITE match: size, bots, the friend (%s)" % str(h[3] if h.size() > 3 else {}))
	_check(h[2].mode == "squad" and h[2].result == "lost" and h[2].size == 4 and h[2].bots == 6 and h[2].with == "" and h[2].id == rival
		and h[2].enemy == "RIVAL", "HISTORY keeps a team search match against a player")
	_check(h[1].result == "ended" and h[1].with == "BUDDY", "a match the host ended is ENDED, no win")
	_check(h[0].size == 4 and h[0].bots == 7 and h[0].with == "" and h[0].id == "", "a match against bots keeps its size and bots")
	_check(p.recent.size() == 1 and p.recent[0].id == rival, "the opponent of a team search becomes a recent player")
	# Save and load (signature, JSON, merge, sanitising): nothing is dropped.
	var before: Dictionary = Game.profile.duplicate(true)
	var raw: Dictionary = JSON.parse_string(JSON.stringify(Guard.sign_dict(Game.profile), "\t"))
	Game.profile = Game.DEFAULT_PROFILE.duplicate(true)
	var ok := Game._apply_saved_profile(raw)
	_check(ok and Game.profile.modes == before.modes and Game.profile.history == before.history,
		"DUO / SQUAD numbers and HISTORY survive a save and a load")
	Game._sanitize_profile()
	_check(Game.profile.modes.duo.matches == 2 and Game.profile.history[1].result == "ended", "and a second sanitising")
	# A profile from before DUO / SQUAD.
	var old: Dictionary = Game.DEFAULT_PROFILE.duplicate(true)
	old.modes = {"training": {"matches": 3, "wins": 1, "kills": 2}, "lonewolf": {"matches": 1, "wins": 0, "kills": 1}}
	old.history = [{"result": "won", "mode": "lonewolf", "enemy": "X", "id": "", "score": 5, "enemy_score": 1, "kills": 5,
		"damage": 900, "headshots": 1, "t": 1780000000}]
	Game.profile = Game.DEFAULT_PROFILE.duplicate(true)
	ok = Game._apply_saved_profile(JSON.parse_string(JSON.stringify(Guard.sign_dict(old))))
	_check(ok and Game.profile.modes.duo == {"matches": 0, "wins": 0, "kills": 0} and Game.profile.modes.squad == {"matches": 0, "wins": 0, "kills": 0}
		and Game.profile.modes.training.matches == 3, "a profile without DUO / SQUAD loads them as zeros")
	_check((Game.profile.history[0] as Dictionary).size() == 10 and not Game.profile.history[0].has("size"), "a 1 vs 1 HISTORY entry keeps its ten keys")
	# Saved team entries are checked like the others.
	var e := Game._history_entry({"result": "ended", "mode": "squad", "enemy": "x", "size": 3, "bots": 99, "with": "  pal!"})
	_check(e.result == "ended" and e.mode == "squad" and not e.has("size"), "a size other than 2 or 4 is no team entry")
	e = Game._history_entry({"result": "won", "mode": "duo", "enemy": "x", "size": 2, "bots": 99, "with": "  pal!"})
	_check(e.size == 2 and e.bots == 3 and e.with == "PAL", "a team entry's bots are clamped, the friend's name cleaned")
	_check(Game._history_entry({"result": "won", "mode": "battle"}).mode == "training", "an unknown mode still reads as TRAINING GROUND")
	_check(Game.mode_name("duo") == "LONE WOLF DUO" and Game.mode_name("squad") == "LONE WOLF SQUAD" and Game.mode_name("nope") == "TRAINING GROUND",
		"the record modes' names")
	_check(Game.team_mate_name({}) == "" and Game.team_mate_name(TeamArena.offline_match(2, "training", 1)) == "", "no friend in a team of bots")
	Game.profile = saved_profile
	Game.last_result = saved_result
	Game.team_match = saved_tm
	Game.autotest = at


func _history_texts() -> void:
	var rival := "rival".sha256_text().left(32)
	_check(LobbyProfile.history_texts({"mode": "lonewolf", "enemy": "NIGHT FOX"}) == ["VS  NIGHT FOX", "LONE WOLF"], "a 1 vs 1 row as before")
	_check(LobbyProfile.history_texts({"mode": "duo", "enemy": "ORANGE TEAM", "size": 2, "with": "", "id": ""}) == ["DUO · VS BOTS", "LONE WOLF"],
		"DUO · VS BOTS")
	_check(LobbyProfile.history_texts({"mode": "squad", "enemy": "ORANGE TEAM", "size": 4, "with": "BUDDY", "id": ""}) == ["SQUAD · WITH BUDDY", "LONE WOLF"],
		"SQUAD · WITH <NAME>")
	_check(LobbyProfile.history_texts({"mode": "duo", "enemy": "RIVAL", "size": 2, "with": "", "id": rival}) == ["DUO · VS RIVAL", "LONE WOLF"],
		"DUO · VS <NAME>")
	_check(LobbyProfile.history_texts({"mode": "training", "enemy": "ORANGE TEAM", "size": 4}) == ["SQUAD · VS BOTS", "TRAINING GROUND"],
		"TRAINING SQUAD")
	_check(LobbyProfile.RESULT_WORDS.ended == "ENDED", "HISTORY says ENDED")


## (The TEAM bar became the GROUP bar: tests/group_lobby_unit.gd.)
func _team_bar() -> void:
	_check(LobbyTeam.bar_shown("lonewolf", false, true) and not LobbyTeam.bar_shown("lonewolf", false, false),
		"the GROUP bar in LONE WOLF, never with online teams off")


func _invites() -> void:
	var a := "aaaa".sha256_text().left(32)
	var b := "bbbb".sha256_text().left(32)
	var c := "cccc".sha256_text().left(32)
	var saved_blocked: Array = Game.profile.blocked
	Game.profile.blocked = [{"id": c, "name": "", "t": 0}]
	var rows := LobbyTeam.invite_rows({a: {"name": "ZED"}, b: {"name": "AMY"}, c: {"name": "BLOCKED"}}, {a: {}})
	_check(rows.size() == 2 and rows[0].id == a and rows[0].online and rows[1].id == b and not rows[1].online,
		"the invite list: friends online first, offline ones after, never a blocked one (%s)" % str(rows))
	Game.profile.blocked = saved_blocked
	_check(LobbyFriends.challenge_text("VIPER", {}) == ["DUEL CHALLENGE", "VIPER challenges you to a 1 vs 1 duel"], "a duel's popup as before")
	_check(LobbyFriends.challenge_text("VIPER", {"size": 2, "coop": true}) == ["TEAM INVITE", "VIPER wants you in their DUO team: YOU TWO VS BOTS"],
		"TEAM INVITE: <NAME> wants you in their DUO team: YOU TWO VS BOTS")
	var sq: Array = LobbyFriends.challenge_text("VIPER", {"size": 4, "coop": true})
	_check(sq[0] == "TEAM INVITE" and String(sq[1]).begins_with("VIPER wants you in their SQUAD") and "2 BOTS" in String(sq[1]), "a SQUAD invite (%s)" % sq[1])


## A session a TEAM INVITE started is the team match on both phones (same roster, the guest in its
## place); a duel's session never is one.
func _session() -> void:
	var host_id := "host".sha256_text().left(32)
	var guest_id := "guest".sha256_text().left(32)
	var saved_name := String(Game.profile.name)
	var saved_bundle := String(Game.profile.bundle)
	var on_host := Cloud.new()
	on_host.my_id = host_id
	on_host.is_host = true
	on_host.opponent = {"id": guest_id, "name": "GUEST", "bundle": "neon"}
	var on_guest := Cloud.new()
	on_guest.my_id = guest_id
	on_guest.is_host = false
	on_guest.opponent = {"id": host_id, "name": "HOST", "bundle": "royal"}
	_check(LobbyFriends.session_team_match(on_host).is_empty(), "a duel's session is no team match")
	on_host.session_team = {"size": 2, "coop": true}
	on_guest.session_team = {"size": 2, "coop": true}
	Game.profile.merge({"name": "HOST", "bundle": "royal"}, true)
	var a := LobbyFriends.session_team_match(on_host)
	Game.profile.merge({"name": "GUEST", "bundle": "neon"}, true)
	var b := LobbyFriends.session_team_match(on_guest)
	_check(not a.is_empty() and a.online and a.coop and a.size == 2 and a.my_slot == 0 and a.host and b.my_slot == 1 and not b.host,
		"a TEAM INVITE session: the host in slot 0, the guest in slot 1")
	_check(not a.is_empty() and a.roster == b.roster and String(a.roster[1].id) == guest_id and int(a.roster[1].team) == 0,
		"both phones build the same roster")
	on_host.session_team = {"size": 4, "coop": false}
	on_guest.session_team = {"size": 4, "coop": false}
	Game.profile.merge({"name": "HOST", "bundle": "royal"}, true)
	a = LobbyFriends.session_team_match(on_host)
	Game.profile.merge({"name": "GUEST", "bundle": "neon"}, true)
	b = LobbyFriends.session_team_match(on_guest)
	_check(a.roster == b.roster and b.my_slot == 4 and int(b.roster[4].team) == 1 and a.mode_id == "squad",
		"a team search's SQUAD: the guest leads team 1 from slot 4")
	Game.profile.merge({"name": saved_name, "bundle": saved_bundle}, true)
	on_host.free()
	on_guest.free()


func _loading_card() -> void:
	var training := Loading.team_info(TeamArena.offline_match(4, "training", 2), 4)
	_check(training.mode == "TRAINING GROUND" and training.badge == "SQUAD" and training.chips == ["FIRST TO 4", "4 VS 4", "VS BOTS", "BOT: HARD"],
		"TRAINING SQUAD's card (%s)" % str(training.chips))
	var fill := Loading.team_info(TeamArena.offline_match(2, "duo", 1), 4)
	_check(fill.mode == "LONE WOLF" and fill.desc == "NO PLAYER FOUND: YOUR TEAM VS BOTS" and "VS BOTS" in fill.chips,
		"a team search that found nobody says so plainly")
	var me := {"id": "m".sha256_text().left(32), "name": "ME", "bundle": "default"}
	var pal := {"id": "p".sha256_text().left(32), "name": "PAL", "bundle": "neon"}
	var coop := Loading.team_info(TeamArena.link_match(2, true, me, pal, true, 3), 4)
	_check("WITH PAL VS BOTS" in coop.chips and coop.chips[1] == "2 VS 2", "a TEAM INVITE's card: WITH <NAME> VS BOTS (%s)" % str(coop.chips))
	var vs := Loading.team_info(TeamArena.link_match(4, false, pal, me, false, 3), 4)
	_check("VS PAL" in vs.chips and not "VS BOTS" in vs.chips, "a team search's card: VS <NAME> (%s)" % str(vs.chips))
