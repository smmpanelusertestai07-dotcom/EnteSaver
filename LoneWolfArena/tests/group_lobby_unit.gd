extends RefCounted
## Unit tests of the lobby's GROUP parts (design/GROUPS.txt 1, UI), run from tests/run_tests.gd:
## - the texts: SEARCHING PLAYERS n/N, WAITING FOR <LEADER> TO START, GROUP INVITE, SELECT MODE's
##   DUO / SQUAD lines (real players, never bots);
## - the gating rules: what the GROUP bar offers a solo, a leader and a member (INVITE greyed when
##   full or not the leader, EXIT for a member, DISBAND and REMOVE for the leader), where it shows;
## - the podium: the spots of up to 3 other members (a member keeps theirs; clear of the hero);
## - the invite list (online friends first, never blocked ones or members) and TEAMS' arrangement;
## - the guarded group API through a stand-in (tests/group_stub.gd).

const GroupStub := preload("res://tests/group_stub.gd")

var t: Node


static func run(runner: Node) -> void:
	var me := new()
	me.t = runner
	me._texts()
	me._gating()
	me._placement()
	me._lists()
	me._stand_in()


func _check(cond: bool, what: String) -> void:
	t.call("_check", cond, what)


func _texts() -> void:
	_check(LobbyTeam.search_text(3, 4) == "SEARCHING PLAYERS 3/4" and LobbyTeam.search_text(9, 8) == "SEARCHING PLAYERS 8/8",
		"the search popup counts n/N (%s)" % LobbyTeam.search_text(3, 4))
	_check(LobbyTeam.search_text(0, 0) == "STARTING MATCH...", "a group of 4 in DUO starts at once")
	_check(LobbyTeam.start_gate_text(true, false, "ZORA") == "WAITING FOR ZORA TO START", "a member waits for the leader")
	_check(LobbyTeam.start_gate_text(true, false, "ZORA", Vector2i(5, 8)) == "SEARCHING PLAYERS 5/8", "a member sees the group's search")
	_check(LobbyTeam.start_gate_text(true, true, "ME") == "" and LobbyTeam.start_gate_text(false, true, "") == "",
		"the leader's and a solo's START works")
	_check(LobbyFriends.group_invite_text("VIPER") == "VIPER invites you to their group", "GROUP INVITE's words")
	var duo: Array = LobbyDialogs.mode_lines("lonewolf", 2, true)
	var squad: Array = LobbyDialogs.mode_lines("lonewolf", 4, true)
	_check(String(duo[0]) == "DUO · 2 VS 2 · REAL PLAYERS" and String(squad[0]) == "SQUAD · 4 VS 4 · REAL PLAYERS",
		"SELECT MODE's LONE WOLF DUO / SQUAD lines (%s / %s)" % [duo[0], squad[0]])
	for line: String in duo + squad:
		_check(not "BOT" in line, "LONE WOLF online never mentions bots (%s)" % line)
	_check(String(LobbyDialogs.mode_lines("training", 2)[0]).contains("BOTS"), "TRAINING keeps its bots")


func _gating() -> void:
	_check(LobbyTeam.bar_shown("lonewolf", false, true) and not LobbyTeam.bar_shown("training", false, true)
		and LobbyTeam.bar_shown("training", true, true) and not LobbyTeam.bar_shown("lonewolf", true, false),
		"the GROUP bar: LONE WOLF or in a group, never with online teams off")
	var solo := LobbyTeam.bar_actions(false, true, 0, 2)
	_check(solo.invite_on and not solo.exit and not solo.disband and not solo.remove and not solo.teams, "a solo invites, nothing else")
	var leader := LobbyTeam.bar_actions(true, true, 3, 2)
	_check(leader.invite_on and leader.disband and leader.remove and not leader.exit and leader.teams, "the leader: INVITE, REMOVE, DISBAND, TEAMS")
	_check(not LobbyTeam.bar_actions(true, true, 4, 2).invite_on, "INVITE is greyed in a full group")
	var member := LobbyTeam.bar_actions(true, false, 3, 2)
	_check(not member.invite_on and member.exit and not member.disband and not member.remove and member.invite, "a member: EXIT GROUP, INVITE greyed")
	_check(not LobbyTeam.bar_actions(true, true, 2, 1).teams, "no TEAMS in 1 VS 1")
	_check(LobbyTeam.leader_name([{"name": "A", "leader": false}, {"name": "B", "leader": true}]) == "B" and LobbyTeam.leader_name([]) == "",
		"the leader's name")


func _placement() -> void:
	_check(Lobby.MEMBER_SPOTS.size() == 3, "up to 3 other members on the podium")
	for i in Lobby.MEMBER_SPOTS.size():
		var p: Vector3 = Lobby.MEMBER_SPOTS[i]
		_check(p.z < -0.3 and absf(p.x) > 0.5, "member spot %d stands behind and beside the hero (%s)" % [i, str(p)])
		if p.y > 0.0:
			_check(Vector2(p.x, p.z).length() < 0.86, "member spot %d on the podium stays on it" % i)
	_check(Lobby.MEMBER_SCALE < 1.0, "members are a bit smaller than the hero")
	var a := Lobby.member_slots({}, ["x", "y", "z"])
	_check(a == {"x": 0, "y": 1, "z": 2}, "members take the spots in join order (%s)" % str(a))
	var b := Lobby.member_slots(a, ["y", "z"])
	_check(b == {"y": 1, "z": 2}, "the others keep their spots when one leaves (%s)" % str(b))
	var c := Lobby.member_slots(b, ["y", "z", "w"])
	_check(c.w == 0 and c.y == 1, "a new member takes the free spot")
	_check(Lobby.member_slots({}, ["a", "b", "c", "d"]).size() == 3, "never more than 3")


func _lists() -> void:
	var a := "aaaa".sha256_text().left(32)
	var b := "bbbb".sha256_text().left(32)
	var c := "cccc".sha256_text().left(32)
	var d := "dddd".sha256_text().left(32)
	var saved_blocked: Array = Game.profile.blocked
	Game.profile.blocked = [{"id": c, "name": "", "t": 0}]
	var rows := LobbyTeam.invite_rows({a: {"name": "ZED"}, b: {"name": "AMY"}, c: {"name": "BLOCKED"}, d: {"name": "IN"}}, {a: {}, d: {}}, [d])
	_check(rows.size() == 2 and rows[0].id == a and rows[0].online and rows[1].id == b and not rows[1].online,
		"the invite list: online friends first, never a blocked one or a member (%s)" % str(rows))
	Game.profile.blocked = saved_blocked
	var list := [{"id": "l", "name": "L", "leader": true, "me": true}, {"id": "m1", "name": "M1"}, {"id": "m2", "name": "M2"},
		{"id": "m3", "name": "M3"}]
	var e := LobbyTeam.team_entries(list, 2)
	_check(e.size() == 4 and e[0].team == 0 and e[1].team == 0 and e[2].team == 1 and e[3].team == 1 and e[0].host,
		"DUO teams by default: leader + first member BLUE, the others ORANGE")
	var moved := [{"id": "l", "name": "L", "leader": true, "team": 1, "slot": 1}, {"id": "m1", "name": "M1"}, {"id": "m2", "name": "M2"}]
	var e2 := LobbyTeam.team_entries(moved, 2)
	var seats := SlotPanel.seat_map(e2)
	_check(String(seats["1_1"].id) == "l" and String(seats["0_0"].id) == "m1" and String(seats["0_1"].id) == "m2",
		"a member's own team / slot wins, the rest fill the free places (%s)" % str(seats.keys()))
	_check(SlotPanel.places_for(1) == 1 and SlotPanel.places_for(2) == 2 and SlotPanel.places_for(4) == 4, "SOLO 2, DUO 4, SQUAD 8 places")


func _stand_in() -> void:
	var saved: Object = LobbyTeam.stand_in
	_check(LobbyTeam.api() == Game.cloud_service() or saved != null, "the group API is Cloud's without a stand-in")
	_check(not LobbyTeam.in_group() or saved != null, "Cloud without the group API: not in a group")
	var s := GroupStub.new()
	LobbyTeam.stand_in = s
	_check(LobbyTeam.is_leader() and not LobbyTeam.in_group() and not LobbyTeam.is_member() and LobbyTeam.group_max() == 4,
		"a solo leads itself")
	s.group = {"gid": "g1", "leader": "other", "members": [{"id": s.my_id, "name": "ME"}, {"id": "other", "name": "BOSS"}], "mode": "lonewolf", "size": 2}
	var m := LobbyTeam.members()
	_check(LobbyTeam.in_group() and LobbyTeam.is_member() and m.size() == 2 and m[0].leader and String(m[0].name) == "BOSS" and m[1].me,
		"a member: the leader first (%s)" % str(m))
	_check(String(LobbyTeam.cloud_call("group_start", [2], "x")) == "" and s.last("group_start") == ["group_start", 2], "calls reach the API")
	_check(LobbyTeam.cloud_call("no_such_call", [], "fallback") == "fallback", "a call the API lacks gives the fallback")
	s.search_found = 3
	s.search_needed = 4
	_check(LobbyTeam.search_progress() == [3, 4], "the search's progress")
	LobbyTeam.stand_in = saved
