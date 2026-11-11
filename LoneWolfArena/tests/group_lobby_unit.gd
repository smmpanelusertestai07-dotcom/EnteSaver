extends RefCounted
## Unit tests of the lobby's GROUP parts (design/GROUPS.txt 1, UI), run from tests/run_tests.gd:
## - the texts: SEARCHING PLAYERS n/N, WAITING FOR <LEADER> TO START, GROUP INVITE, SELECT MODE's
##   DUO / SQUAD lines (real players, never bots);
## - the gating rules: what the GROUP bar offers a solo, a leader and a member (INVITE greyed when
##   full or not the leader, EXIT for a member, DISBAND and REMOVE for the leader), where it shows;
## - the podium: the spots of up to 3 other members (a member keeps theirs; clear of the hero);
## - the invite list (online friends first, never blocked ones or members) and TEAMS' arrangement;
## - Cloud's group API as the lobby reads it (no stand-in: the real one);
## - the CUSTOM ROOM with slots: SOLO 2, DUO 4, SQUAD 8 places, a player takes an empty place only,
##   a newcomer joins the smaller team, the host's roster off the wire, START's gate, the panel's
##   entries, and Cloud's room handshake (the group keys RSA-wrapped in "rin", tagged with the
##   password's key; a KICK is never let in again).

var t: Node


static func run(runner: Node) -> void:
	var me := new()
	me.t = runner
	me._texts()
	me._gating()
	me._placement()
	me._lists()
	me._real_api()
	me._room_rules()
	me._room_cloud()


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
	var moved := [{"id": "l", "name": "L", "leader": true, "team": 1, "slot": 3}, {"id": "m1", "name": "M1"}, {"id": "m2", "name": "M2"}]
	var e2 := LobbyTeam.team_entries(moved, 2)
	var seats := SlotPanel.seat_map(e2)
	_check(String(seats["1_1"].id) == "l" and String(seats["0_0"].id) == "m1" and String(seats["0_1"].id) == "m2",
		"a member's own team / slot wins, the rest fill the free places (%s)" % str(seats.keys()))
	_check(SlotPanel.places_for(1) == 1 and SlotPanel.places_for(2) == 2 and SlotPanel.places_for(4) == 4, "SOLO 2, DUO 4, SQUAD 8 places")


func _real_api() -> void:
	var c := Game.cloud_service()
	_check(LobbyTeam.group() == c.group and LobbyTeam.group_max() == Cloud.GROUP_MAX, "the lobby reads Cloud's group")
	var saved := c.group
	c.group = {}
	_check(LobbyTeam.is_leader() and not LobbyTeam.in_group() and not LobbyTeam.is_member() and LobbyTeam.members().is_empty(),
		"a solo leads itself")
	c.group = {"gid": "g1", "leader": "other", "status": "idle", "mode": "lonewolf", "size": 2, "members": [
		{"id": "other", "name": "BOSS", "bundle": "default", "team": 0, "slot": 0}, {"id": c.my_id, "name": "ME", "bundle": "default", "team": 0, "slot": 1}]}
	var m := LobbyTeam.members()
	_check(LobbyTeam.in_group() and LobbyTeam.is_member() and m.size() == 2 and m[0].leader and String(m[0].name) == "BOSS" and m[1].me,
		"a member: the leader first (%s)" % str(m))
	c.search_found = 3
	c.search_needed = 4
	_check(LobbyTeam.search_progress() == [3, 4], "the search's progress")
	c.search_found = 0
	c.search_needed = 0
	c.group = saved


## The room's slot rules (NetGroup with room) and what the room tab shows.
func _room_rules() -> void:
	_check(NetGroup.places(1, true) == 1 and NetGroup.places(2, true) == 2 and NetGroup.places(4, true) == 4 and NetGroup.places(1) == 2,
		"a room's places a team: SOLO 1, DUO 2, SQUAD 4 (a group's SOLO keeps 2)")
	_check(NetGroup.cap(1, true) == 2 and NetGroup.cap(2, true) == 4 and NetGroup.cap(4, true) == 8 and NetGroup.cap(4) == NetGroup.MAX,
		"a room holds 2, 4 or 8 players")
	var ids: Array = []
	for n in 9:
		ids.append(("room player %d" % n).sha256_text().left(32))
	var mem: Array = [{"id": ids[0], "name": "HOST", "bundle": "default", "team": 0, "slot": 0}]
	for n in range(1, 8):
		mem.append({"id": ids[n], "name": "P%d" % n, "bundle": "default", "team": NetGroup.room_side(mem), "slot": -1})
		NetGroup.arrange(mem, 4, true, true)
	var seen := {}
	var per_team := [0, 0]
	for e: Dictionary in mem:
		seen[int(e.slot)] = true
		per_team[int(e.team)] += 1
	_check(seen.size() == 8 and per_team == [4, 4], "eight players fill SQUAD's 8 places, newcomers on the smaller team (%s)" % str(per_team))
	var duo: Array = [{"id": ids[0], "name": "HOST", "bundle": "default", "team": 0, "slot": 0},
		{"id": ids[1], "name": "A", "bundle": "default", "team": 1, "slot": 2}]
	_check(not NetGroup.take_empty(duo, ids[1], 0, 0, 2), "a taken place cannot be taken")
	_check(not NetGroup.take_empty(duo, ids[1], 1, 4, 2) and not NetGroup.take_empty(duo, ids[1], 0, 2, 2) and not NetGroup.take_empty(duo, ids[5], 0, 1, 2),
		"a place outside the team, or a player not in the room, changes nothing")
	_check(NetGroup.take_empty(duo, ids[1], 0, 1, 2) and int(duo[1].team) == 0 and int(duo[1].slot) == 1, "a player takes an empty place")
	_check(NetGroup.plan(duo, 2) == "search", "both on BLUE: the room cannot start yet")
	var solo: Array = [{"id": ids[0], "name": "HOST", "bundle": "default", "team": 0, "slot": 0}]
	solo.append({"id": ids[1], "name": "B", "bundle": "default", "team": NetGroup.room_side(solo), "slot": -1})
	NetGroup.arrange(solo, 1, true, true)
	_check(int(solo[1].team) == 1 and int(solo[1].slot) == 2 and not NetGroup.take_empty(solo, ids[1], 1, 3, 1),
		"SOLO: one place a team (ORANGE's is slot 2), no second one")
	var wire := NetGroup.pack_members(mem)
	_check(NetGroup.members_from(wire, ids[0], 4, true).size() == 8 and NetGroup.members_from(wire, ids[0], 4).is_empty(),
		"a room's roster of 8 is taken, a group's is never over 4")
	_check(NetGroup.members_from([[ids[0], "H", "default", 0, 0], [ids[1], "X", "default", 0, 1]], ids[0], 1, true).is_empty(),
		"SOLO's roster: no second BLUE place")
	_check(NetGroup.members_from(wire, ids[1], 4, true).is_empty(), "only the host's roster (the host first) counts")
	var e := LobbyFriends.room_entries([{"id": "h", "name": "H", "leader": true, "me": true, "team": 0, "slot": 1},
		{"id": "o", "name": "O", "team": 1, "slot": 3}], 2)
	var seats := SlotPanel.seat_map(e)
	_check(seats.has("0_1") and seats.has("1_1") and bool(seats["0_1"].host) and not bool(seats["1_1"].host),
		"the room's players sit in their team's places (%s)" % str(seats.keys()))
	_check(NetGroup.roster_from(NetGroup.pack_roster(NetGroup.match_roster(duo)), 2).is_empty(),
		"a roster with one team empty never starts")
	var even: Array = [{"id": ids[0], "name": "HOST", "bundle": "default", "team": 0, "slot": 0},
		{"id": ids[1], "name": "A", "bundle": "default", "team": 1, "slot": 2}, {"id": ids[2], "name": "B", "bundle": "default", "team": 1, "slot": 3}]
	_check(NetGroup.roster_from(NetGroup.pack_roster(NetGroup.match_roster(even)), 2).size() == 3, "1 VS 2 starts the all-human match")


## Cloud's room handshake between two Clouds (no relay): the host opens a DUO room, the right
## password gets the group keys RSA-wrapped for the joiner in "rin", the joiner's "gjoin" seats it,
## "gslot" moves it to an empty place, KICK removes it for good.
func _room_cloud() -> void:
	var host := Cloud.new()
	var guest := Cloud.new()
	var hk := Crypto.new().generate_rsa(1024)
	var gk := Crypto.new().generate_rsa(1024)
	host._use_key(hk)
	guest._use_key(gk)
	host.open_room("4821", {}, "424242", 2)
	_check(host.in_room() and int(host.group.size) == 2 and String(host.group.room) == "424242" and host.is_group_leader(),
		"a DUO room is the host's own group")
	guest.join_room("424242", "4821")
	var ask := {"t": "ask", "from": guest.my_id, "name": "GUEST", "bundle": "default", "pk": guest._pk_pem,
		"mac": guest._room_tag(guest._join.key, "ask", guest.my_id)}
	host._inbox_budget = 8.0
	host._on_room_ask(ask)
	_check((host._grp.invited as Dictionary).has(guest.my_id), "the right password: a place waits for the player")
	# The host's "rin", as it went out (rebuilt here: no relay): the keys wrapped for the guest.
	var sec := host._room_sec(guest._pk_pem)
	var rin := {"t": "rin", "from": host.my_id, "code": "424242", "sec": sec, "rt": host._room_tag(host._room_key("424242", "4821"), "rin" + sec, host.my_id)}
	var forged := rin.duplicate()
	forged.rt = "00".repeat(32)
	guest._inbox_budget = 8.0
	guest._on_inbox(forged)
	_check(guest.join_state == "in" and not guest.in_room(), "a \"rin\" without the password's tag lets nobody into a group")
	guest._on_inbox(rin)
	_check(guest.in_room() and String(guest._grp.gid) == String(host._grp.gid) and guest._grp.aes == host._grp.aes and String(guest.group.leader) == host.my_id,
		"the right \"rin\": the joiner holds the room group's keys")
	host._on_gjoin(guest.my_id, {"name": "GUEST", "bundle": "default"})
	var m := host.group_members()
	_check(m.size() == 2 and int(m[1].team) == 1 and int(m[1].slot) == 2, "the newcomer takes ORANGE's first place (%s)" % str(m))
	host._on_gslot(guest.my_id, {"t": 0, "s": 0})
	_check(int(host.group_members()[1].slot) == 2, "a place the host holds cannot be taken")
	host._on_gslot(guest.my_id, {"t": 0, "s": 1})
	_check(int(host.group_members()[1].team) == 0 and int(host.group_members()[1].slot) == 1, "\"gslot\" moves a player to an empty place")
	_check(host.room_start() != "" and not LobbyFriends.room_ready(host), "one team empty: START waits")
	host._on_gslot(guest.my_id, {"t": 1, "s": 3})
	_check(LobbyFriends.room_ready(host), "a player on each team: START can go (1 VS 1 in DUO's places)")
	host.kick_from_group(guest.my_id)
	host._on_room_ask(ask)
	_check(host.group_members().size() == 1 and not (host._grp.invited as Dictionary).has(guest.my_id), "a KICKed player is not let in again")
	host.close_room()
	_check(not host.in_room() and host.group.is_empty(), "CLOSE ROOM ends the room's group")
	host.free()
	guest.free()
