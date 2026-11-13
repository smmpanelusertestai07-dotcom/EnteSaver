extends RefCounted
## Unit tests of the lobby's GROUP parts (design/GROUPS.txt 1, UI), run from tests/run_tests.gd:
## - the texts: the search tab (ESTIMATED 0:10 / STILL SEARCHING..., m:ss, PLAYERS n/N), WAITING FOR <LEADER> TO START, GROUP INVITE, SELECT MODE's
##   DUO / SQUAD lines (real players, never bots);
## - the gating rules: what the GROUP bar offers a solo, a leader and a member (INVITE greyed when
##   full or not the leader, EXIT for a member, DISBAND and REMOVE for the leader), where it shows;
## - the podium: the spots of up to 3 other members (a member keeps theirs; clear of the hero);
## - the invite list (online friends first, never blocked ones or members) and TEAMS' arrangement;
## - Cloud's group API as the lobby reads it (no stand-in: the real one);
## - the CUSTOM ROOM with slots: SOLO 2, DUO 4, SQUAD 8 places, a player takes an empty place only,
##   a newcomer joins the smaller team, the host's roster off the wire, START's gate, the panel's
##   entries, and Cloud's room handshake (the group keys RSA-wrapped in "rin", tagged with the
##   password's key; a KICK is never let in again);
## - the GROUP CODE between Clouds (no relay): JOIN BY CODE lets a player in at once, a full group
##   says so, a wrong code finds nobody, a blocked player is never answered, a leader the joiner
##   blocked is never joined, the switch off answers nobody, too many tries wait;
## - the DUEL in a group of two: START's route, SELECT MODE's chip, the member's phone taking the
##   leader's tagged challenge at once (and nobody else's tag);
## - QUICK MATCH behind a waiting DUEL CHALLENGE / GROUP INVITE (two Clouds): no quick challenge goes
##   out and none is taken while the popup waits; ACCEPT ends the search, DECLINE lets it go on;
## - JOIN BY CODE that never gets in (COULD NOT JOIN: TRY AGAIN, then JOIN again) and the leader's
##   switch carried in the roster (a member shows the code only while it is on);
## - IN A MATCH: the lobby announce's flag (only while in a match, never the room), read from a
##   "hi" (an older build's, without it, reads as in the lobby), the rows' words and greyed buttons.

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
	me._group_code()
	me._duel()
	me._quick_behind_popup()
	me._code_leftovers()
	me._presence()


func _check(cond: bool, what: String) -> void:
	t.call("_check", cond, what)


func _texts() -> void:
	_check(SearchTab.players_text(3, 4) == "PLAYERS 3/4" and SearchTab.players_text(9, 8) == "PLAYERS 8/8" and SearchTab.players_text(0, 0) == "",
		"the search tab counts PLAYERS n/N, nothing for the 1 vs 1 (%s)" % SearchTab.players_text(3, 4))
	_check(SearchTab.line_text(0.0) == "ESTIMATED 0:10" and SearchTab.line_text(10.5) == "ESTIMATED 0:10" and SearchTab.line_text(11.0) == "STILL SEARCHING...",
		"the search tab's line: the estimate for 10 s, then STILL SEARCHING...")
	_check(SearchTab.timer_text(0.0) == "0:00" and SearchTab.timer_text(75.4) == "1:15", "the search tab counts up (m:ss)")
	_check(LobbyTeam.start_gate_text(true, false, "ZORA") == "WAITING FOR ZORA TO START", "a member waits for the leader")
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
	_check(Lobby.podium_invite_shown(true, true, 1, 4, false) and Lobby.podium_invite_shown(true, true, 3, 4, false)
		and not Lobby.podium_invite_shown(true, true, 4, 4, false) and not Lobby.podium_invite_shown(true, false, 2, 4, false)
		and not Lobby.podium_invite_shown(true, true, 2, 4, true) and not Lobby.podium_invite_shown(false, true, 1, 4, false),
		"the podium's +: the leader or a solo with room, never full, for a member, during a search or without the GROUP bar")
	_check(Lobby.podium_invite_spot({}) == 1 and Lobby.podium_invite_spot({"a": 0}) == 1 and Lobby.podium_invite_spot({"a": 0, "b": 1}) == 2
		and Lobby.podium_invite_spot({"a": 1, "b": 2}) == -1, "the podium's + stands over the first free spot right of the hero")
	for i: int in Lobby.INVITE_SPOTS:
		_check((Lobby.MEMBER_SPOTS[i] as Vector3).x > 0.0, "the + plate's spot %d is right of the hero" % i)
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
	# An older build (an "ask" without "rv") plays a DUO room by today's rules: a room set to
	# FIRST TO 7 keeps it out; with "rv" (this build) it gets in.
	host.open_room("4821", RoomRules.classic(2), "424242", 2)
	_check(RoomRules.is_classic(host.room_rules, true), "a CLASSIC DUO room")
	host._inbox_budget = 8.0
	host._on_room_ask(ask)
	_check((host._grp.invited as Dictionary).has(guest.my_id), "a CLASSIC DUO room lets an older build in")
	var seven := RoomRules.classic(2)
	seven.rounds = 7
	host.open_room("4821", seven, "424242", 2)
	host._inbox_budget = 8.0
	host._on_room_ask(ask)
	_check(not (host._grp.invited as Dictionary).has(guest.my_id), "a DUO room FIRST TO 7 keeps an older build (no \"rv\") out")
	var ask_new := ask.duplicate()
	ask_new.rv = 1
	host._on_room_ask(ask_new)
	_check((host._grp.invited as Dictionary).has(guest.my_id), "a DUO room FIRST TO 7 lets this build (\"rv\") in")
	host.open_room("4821", {}, "424242", 2)
	_check(RoomRules.is_classic(host.room_rules, true), "a DUO room opened with {} is CLASSIC (first to 4)")
	host.close_room()
	host.free()
	guest.free()


func _peer(c: Cloud, bits := 1024) -> Cloud:
	c._use_key(Crypto.new().generate_rsa(bits))
	c._connected = true                      # (no relay: what it publishes goes nowhere)
	return c


## JOIN BY CODE between Clouds: the asks and answers rebuilt here as they would go out.
func _group_code() -> void:
	var host := _peer(Cloud.new())
	var guest := _peer(Cloud.new())
	var made := _peer(Cloud.new())
	_check(Cloud.is_group_code(made.group_code()) and made.group_code().length() == 10 and Cloud.code_display("4213579086") == "42 1357 9086",
		"a made GROUP CODE has 10 digits, shown as 42 1357 9086")
	made.free()
	host.my_code = "4213579086"
	_check(host.group_code() == "4213579086" and host.group.is_empty(), "a solo has a GROUP CODE of its own")
	_check(Cloud.code_topic("4213579086") == Cloud.ROOT + "/gc/42", "the topic names only the 2 bucket digits, never the 8 secret ones")
	var said_9 := guest.join_group_code("421357908")
	_check(said_9 == "A GROUP CODE HAS 10 DIGITS" and guest.join_group_code("+421357908") == said_9 and guest.join_group_code("135790") == said_9,
		"JOIN BY CODE takes exactly 10 digits (%s)" % said_9)
	var said_ok := guest.join_group_code("42 1357 9086")
	_check(said_ok == "" and guest.code_state == "asking" and String(guest._cjoin.get("code", "")) == "4213579086",
		"JOIN BY CODE takes the code as shown (spaces) and asks (%s)" % said_ok)
	_check(not host.code_join and host._on_code_ask(guest._code_ask_msg()).is_empty(), "JOIN BY CODE is OFF until the player turns it on")
	host.set_code_join(true)
	var reply := host._on_code_ask(guest._code_ask_msg())
	_check(String(reply.get("t", "")) == "gin" and not host.group.is_empty() and (host._grp.invited as Dictionary).has(guest.my_id),
		"the right code: the solo's group is made and a place waits for the joiner")
	var forged := reply.duplicate()
	forged.rt = "00".repeat(32)
	guest._on_code_answer(host.my_id, forged)
	_check(guest.group.is_empty() and guest.code_state == "asking", "a \"gin\" without the code's tag lets nobody in")
	guest._on_code_answer(host.my_id, reply)
	_check(guest.code_state == "in" and String(guest.group.leader) == host.my_id and guest._grp.aes == host._grp.aes
		and String(guest.group.code) == "4213579086", "the right \"gin\": the joiner holds the group's keys, no invite needed")
	host._on_gjoin(guest.my_id, {"name": "GUEST", "bundle": "default"})
	_check(host.group_members().size() == 2, "the joiner's \"gjoin\" seats it")
	# TEAM chat over the group room ("gchat"): the member's line reaches the leader with its name,
	# counts as unread, a replay or a flood is dropped; the sender keeps its own line.
	NetChat.reset_for_test()
	var gid := String(host._grp.gid)
	_check(guest.send_group_chat("too soon") == "NO GROUP", "TEAM chat: not before the leader's roster has the member")
	guest._on_groster(host._roster_msg())          # (the leader's roster, as it would arrive)
	_check(guest.send_group_chat("meet at 9!") == "" and NetChat.group_messages(gid).size() == 1 and bool(NetChat.group_messages(gid)[0][1]),
		"TEAM chat: a member's SEND keeps its own line")
	_check(guest.send_group_chat("again") == "WAIT" and guest.send_group_chat("   ") == "EMPTY", "TEAM chat: one message a second, never an empty one")
	NetChat.reset_for_test()
	var pkt := guest._seal({"k": "gchat", "x": "meet at 9!", "ts": 0}, guest.my_id, 900, guest._grp.aes, guest._grp.mac)
	host._on_group(pkt)
	var gm := NetChat.group_messages(gid)
	_check(gm.size() == 1 and String(gm[0][2]) == "GUEST" and String(gm[0][3]) == "MEET AT 9!" and not bool(gm[0][1]) and NetChat.group_unread(gid) == 1,
		"TEAM chat: the leader gets the member's line with its name, unread (%s)" % str(gm))
	host._on_group(pkt)
	for n in 6:
		host._on_group(guest._seal({"k": "gchat", "x": "spam %d" % n, "ts": 0}, guest.my_id, 901 + n, guest._grp.aes, guest._grp.mac))
	_check(NetChat.group_messages(gid).size() < 5, "TEAM chat: a replayed line and a flood are dropped (%d kept)" % NetChat.group_messages(gid).size())
	host._on_group(guest._seal({"k": "gchat", "x": 42, "ts": 0}, guest.my_id, 950, guest._grp.aes, guest._grp.mac))
	_check(NetChat.group_messages(gid).size() < 5, "TEAM chat: a line that is not text is dropped")
	NetChat.group_mark_read(gid)
	_check(NetChat.group_unread(gid) == 0 and NetChat.group_messages("another").is_empty(), "TEAM chat: read marks; another group starts empty")
	NetChat.reset_for_test()
	_check(guest.join_group_code("1124680211") == "EXIT YOUR GROUP FIRST", "a member cannot join another group by code")
	# A wrong code: nobody answers, and the search gives up with NO GROUP WITH THIS CODE.
	var lost := _peer(Cloud.new())
	_check(lost.join_group_code("4200000001") == "", "a wrong code still asks")
	_check(host._on_code_ask(lost._code_ask_msg()).is_empty(), "another code's ask is not answered")
	lost._cjoin.t = Time.get_ticks_msec() - Cloud.CODE_WAIT_MS - 10
	lost._tick_code(0.0, Time.get_ticks_msec())
	_check(lost.code_state == "none" and LobbyTeam.code_state_text(lost.code_state) == "NO GROUP WITH THIS CODE", "a wrong code: NO GROUP WITH THIS CODE")
	# Full: four in the group (members and places waiting) answer "gno".
	for n in 2:
		host.group.members.append({"id": ("filler %d" % n).sha256_text().left(32), "name": "F%d" % n, "bundle": "default", "team": 0, "slot": -1})
	var late := _peer(Cloud.new())
	late.join_group_code("4213579086")
	var no := host._on_code_ask(late._code_ask_msg())
	late._on_code_answer(host.my_id, no)
	_check(String(no.get("t", "")) == "gno" and late.code_state == "full" and LobbyTeam.code_state_text("full") == "THE GROUP IS FULL",
		"a full group answers THE GROUP IS FULL")
	host.group.members.resize(2)
	# A blocked player is never answered.
	var shady := _peer(Cloud.new())
	shady.join_group_code("4213579086")
	Game.block(shady.my_id, "SHADY")
	_check(host._on_code_ask(shady._code_ask_msg()).is_empty(), "a blocked player never joins (no answer)")
	Game.unblock(shady.my_id)
	# A joiner never enters the group of a leader it blocked.
	var wary := _peer(Cloud.new())
	wary.join_group_code("4213579086")
	var gin := host._on_code_ask(wary._code_ask_msg())
	Game.block(host.my_id, "HOST")
	wary._on_code_answer(host.my_id, gin)
	_check(String(gin.get("t", "")) == "gin" and wary.group.is_empty() and wary.code_state == "blocked", "never into a blocked leader's group")
	Game.unblock(host.my_id)
	# DUEL CHALLENGES FROM: NOBODY lets nobody in by code, FRIENDS only friends.
	var who_may: Variant = Game.settings.get("challenges_from", Game.CHALLENGES_EVERYONE)
	var odd := _peer(Cloud.new())
	odd.join_group_code("4213579086")
	Game.settings.challenges_from = Game.CHALLENGES_NOBODY
	var nobody := host._on_code_ask(odd._code_ask_msg())
	Game.settings.challenges_from = Game.CHALLENGES_FRIENDS
	var friends := host._on_code_ask(odd._code_ask_msg())
	Game.settings.challenges_from = who_may
	_check(nobody.is_empty() and friends.is_empty(), "DUEL CHALLENGES FROM NOBODY / FRIENDS: a stranger's code ask is not answered")
	# REMOVE: the removed player's code asks are not answered again this run (an invite still can).
	host.kick_from_group(guest.my_id)
	guest._group_close(false)
	guest.code_state = ""
	_check(guest.join_group_code("4213579086") == "" and host._on_code_ask(guest._code_ask_msg()).is_empty() and host.group_members().size() == 1,
		"a REMOVEd player cannot come back by the code")
	# QUICK MATCH: a searching phone neither listens for code joins nor joins by code, and a group
	# made or joined ends its QUICK MATCH search.
	var seeker := _peer(Cloud.new())
	seeker.my_code = "5500000001"
	seeker.set_code_join(true)
	seeker.seek_start()
	var asker := _peer(Cloud.new())
	asker.join_group_code("5500000001")
	_check(seeker.join_group_code("4213579086") == "CANCEL THE SEARCH FIRST" and seeker._on_code_ask(asker._code_ask_msg()).is_empty(),
		"in QUICK MATCH: no join by code, no code joins answered")
	seeker._want_lobby = true
	seeker._tick_code(0.0, Time.get_ticks_msec())
	var quiet := seeker._code_topic
	seeker.seek_stop()
	seeker._tick_code(0.0, Time.get_ticks_msec())
	_check(quiet == "" and seeker._code_topic == Cloud.code_topic("5500000001"), "in QUICK MATCH nobody listens on the code's bucket; after it, the leader does")
	seeker.search_needed = 4
	_check(seeker.join_group_code("4213579086") == "CANCEL THE SEARCH FIRST", "in a DUO / SQUAD search: no join by code")
	seeker.search_needed = 0
	var welcome := seeker._on_code_ask(asker._code_ask_msg())
	asker.seek_start()                       # (as if QUICK MATCH began while the ask was out)
	asker._on_code_answer(seeker.my_id, welcome)
	_check(asker.code_state == "in" and not asker.seeking, "joining a group by code ends this phone's QUICK MATCH search")
	var lone := _peer(Cloud.new())
	lone.seek_start()
	lone._group_create(2)
	_check(not lone.seeking, "a group made here ends this phone's QUICK MATCH search")
	# The switch off: nobody is answered.
	host.set_code_join(false)
	var shut := _peer(Cloud.new())
	shut.join_group_code("4213579086")
	_check(host._on_code_ask(shut._code_ask_msg()).is_empty(), "JOIN BY CODE: OFF lets nobody in")
	host.code_join = true
	# Too many tries in a minute wait.
	var eager := _peer(Cloud.new())
	var said := ""
	for n in Cloud.CODE_TRIES_MAX + 1:
		eager.code_state = ""
		said = eager.join_group_code("%010d" % (4200500000 + n))
	_check(said == "TOO MANY TRIES: WAIT A MINUTE", "join attempts are rate-limited (%s)" % said)
	for c: Cloud in [host, guest, lost, late, shady, wary, shut, eager, odd, seeker, asker, lone]:
		c.free()


## The DUEL in a group of two: START routes it, SELECT MODE names it, the member takes it at once.
func _duel() -> void:
	_check(Lobby.start_route("lonewolf", 1, true, 2) == "duel" and Lobby.start_route("lonewolf", 1, true, 0) == "quick"
		and Lobby.start_route("lonewolf", 1, true, 3) == "quick" and Lobby.start_route("lonewolf", 2, true, 2) == "team_search"
		and Lobby.start_route("training", 1, true, 2) == "training", "START: a group of two with SOLO plays the DUEL, 3 or 4 keep the notice")
	var two := [{"id": "a", "name": "ME", "me": true}, {"id": "b", "name": "VIPER", "me": false}]
	_check(LobbyDialogs.size_chip_text("lonewolf", 1, two) == "DUEL · YOU VS VIPER" and LobbyDialogs.size_chip_text("lonewolf", 1, []) == "SOLO"
		and LobbyDialogs.size_chip_text("lonewolf", 2, two) == "DUO" and LobbyDialogs.size_chip_text("training", 1, two) == "SOLO"
		and LobbyDialogs.size_chip_text("lonewolf", 1, two + [{"id": "c", "name": "Z"}]) == "SOLO", "SELECT MODE's SOLO chip: DUEL · YOU VS <NAME>")
	var lead := _peer(Cloud.new(), 2048)        # (a challenge's signature is checked as a 2048-bit one)
	var mem := _peer(Cloud.new())
	lead.my_code = "7700777001"
	lead.code_join = true
	mem.join_group_code("7700777001")
	mem._on_code_answer(lead.my_id, lead._on_code_ask(mem._code_ask_msg()))
	lead._on_gjoin(mem.my_id, {"name": "MEM", "bundle": "default"})
	mem.group.members = [{"id": lead.my_id, "name": "LEAD", "bundle": "default", "team": 0, "slot": 0},
		{"id": mem.my_id, "name": "MEM", "bundle": "default", "team": 0, "slot": 1}]
	mem._grp.joining = false
	_check(lead.in_group() and mem.in_group() and lead.group_duel_tag(lead.my_id) == mem.group_duel_tag(lead.my_id) and lead.group_duel_tag(lead.my_id) != "",
		"both phones make the same group tag")
	_check(mem.group_duel() == "ONLY THE LEADER CAN START", "only the leader starts the duel")
	lead.peers[mem.my_id] = {"name": "MEM", "bundle": "default", "pk": mem._pk_pem, "seen": Time.get_ticks_msec()}
	_check(lead.group_duel() == "" and String(lead._outgoing.get("id", "")) == mem.my_id, "the leader's START challenges the member")
	# The challenge as it went out (rebuilt: no relay), into the member's inbox.
	var pub := CryptoKey.new()
	pub.load_from_string(mem._pk_pem, true)
	var sec: PackedByteArray = String(lead._outgoing.room).hex_decode()
	sec.append_array(lead._outgoing.aes as PackedByteArray)
	sec.append_array(lead._outgoing.mac as PackedByteArray)
	var sec_text := Marshalls.raw_to_base64(Crypto.new().encrypt(pub, sec))
	var inv := {"t": "inv", "from": lead.my_id, "name": "LEAD", "bundle": "default", "sec": sec_text, "pk": lead._pk_pem,
		"sig": lead._sign(Cloud.invite_text(lead.my_id, mem.my_id, sec_text)), "gd": "00".repeat(32)}
	mem._inbox_budget = 8.0
	mem._on_inbox(inv)
	_check(String(mem.opponent.get("id", "")) != lead.my_id, "a challenge with a wrong group tag is not taken at once")
	mem._incoming = {}
	inv.gd = lead.group_duel_tag(lead.my_id)
	mem._inbox_budget = 8.0
	mem._on_inbox(inv)
	_check(String(mem.opponent.get("id", "")) == lead.my_id and mem._incoming.is_empty() and not mem.is_host,
		"the member takes the leader's DUEL at once (the usual 1 vs 1 session)")
	_check(mem.in_group() and lead.in_group(), "both stay in the group")
	lead.free()
	mem.free()


## The challenge `from` sent `to` (from._outgoing), rebuilt as it went out (no relay), with `extra`.
func _inv_msg(from: Cloud, to: Cloud, extra := {}) -> Dictionary:
	var pub := CryptoKey.new()
	pub.load_from_string(to._pk_pem, true)
	var sec: PackedByteArray = String(from._outgoing.room).hex_decode()
	sec.append_array(from._outgoing.aes as PackedByteArray)
	sec.append_array(from._outgoing.mac as PackedByteArray)
	var sec_text := Marshalls.raw_to_base64(Crypto.new().encrypt(pub, sec))
	var msg := {"t": "inv", "from": from.my_id, "name": "P", "bundle": "default", "sec": sec_text, "pk": from._pk_pem,
		"sig": from._sign(Cloud.invite_text(from.my_id, to.my_id, sec_text))}
	msg.merge(extra)
	return msg


## QUICK MATCH and a popup waiting for this player's answer (design/GROUPS.txt 7): two seekers.
func _quick_behind_popup() -> void:
	var a := _peer(Cloud.new(), 2048)
	var b := _peer(Cloud.new(), 2048)
	for pair: Array in [[a, b], [b, a]]:
		var x: Cloud = pair[0]
		var y: Cloud = pair[1]
		x.peers[y.my_id] = {"name": "Y", "bundle": "default", "pk": y._pk_pem, "seen": Time.get_ticks_msec()}
		x.seek_start()
		x.quick_seen[y.my_id] = Time.get_ticks_msec()
	# A friend's challenge waits on a's phone: a's search sends no quick challenge.
	a._incoming = {"id": "f".repeat(32), "name": "FRIEND", "room": "00".repeat(16), "aes": PackedByteArray(), "mac": PackedByteArray(), "t": Time.get_ticks_msec()}
	_check(a.answer_waiting() and not a.invite(b.my_id, {"quick": true}) and a._outgoing.is_empty(),
		"a waiting DUEL CHALLENGE: QUICK MATCH sends no quick challenge")
	a._incoming = {}
	a._ginv = {"id": "f".repeat(32), "name": "FRIEND", "gid": "00".repeat(16), "room": "00".repeat(16), "aes": PackedByteArray(),
		"mac": Crypto.new().generate_random_bytes(32), "size": 2, "t": Time.get_ticks_msec()}
	_check(a.answer_waiting() and not a.invite(b.my_id, {"quick": true}), "a waiting GROUP INVITE: QUICK MATCH sends no quick challenge")
	# b's quick challenge reaches a while the GROUP INVITE waits: declined at once, nothing taken.
	_check(b.invite(a.my_id, {"quick": true}), "the other seeker challenges")
	var quick := _inv_msg(b, a, {"quick": true})
	a._inbox_budget = 8.0
	a._on_inbox(quick)
	_check(a.opponent.is_empty() and a._incoming.is_empty() and not a._ginv.is_empty() and a.seeking,
		"a quick challenge behind a GROUP INVITE is declined; the invite still waits, the search goes on")
	# DECLINE: the search goes on, and a quick challenge is taken again.
	a.answer_group_invite(false)
	_check(a.seeking and not a.answer_waiting(), "DECLINE of the popup lets the search go on")
	a._inbox_budget = 8.0
	a._on_inbox(quick)
	_check(String(a.opponent.get("id", "")) == b.my_id and a.seeking, "with no popup waiting, the quick challenge is taken (the match follows)")
	# The room handshake runs (no "join" yet): a friend's duel challenge is declined at once, never shown.
	var g := _peer(Cloud.new(), 2048)
	g.peers[a.my_id] = {"name": "A", "bundle": "default", "pk": a._pk_pem, "seen": Time.get_ticks_msec()}
	_check(g.invite(a.my_id), "a friend challenges during the handshake")
	var shown := [0]
	a.invited.connect(func(_n: String) -> void: shown[0] += 1)
	a._inbox_budget = 8.0
	a._on_inbox(_inv_msg(g, a))
	_check(not a.in_session and a.busy_for_challenge() and a._incoming.is_empty() and shown[0] == 0
		and String(a.opponent.get("id", "")) == b.my_id, "a challenge during a QUICK MATCH handshake is declined at once (never shown)")
	# A group invite that came in meanwhile is declined when the session starts.
	a._ginv = {"id": g.my_id, "name": "FRIEND", "gid": "00".repeat(16), "room": "00".repeat(16), "aes": PackedByteArray(),
		"mac": Crypto.new().generate_random_bytes(32), "size": 2, "t": Time.get_ticks_msec()}
	a._on_room(b._room_packet({"k": "join"}))
	_check(a.in_session and a._ginv.is_empty() and a._incoming.is_empty(), "the session starts and a waiting group invite is declined at once")
	a.clear_resume()
	a.free()
	b.free()
	g.free()
	# ACCEPT of a friend's challenge ends the search (NetMatch stops when Cloud is no longer seeking).
	var c := _peer(Cloud.new(), 2048)
	var f := _peer(Cloud.new(), 2048)
	c.seek_start()
	f.peers[c.my_id] = {"name": "C", "bundle": "default", "pk": c._pk_pem, "seen": Time.get_ticks_msec()}
	_check(f.invite(c.my_id), "a friend challenges a searching player")
	c._inbox_budget = 8.0
	c._incoming = {}
	var who_may: Variant = Game.settings.get("challenges_from", Game.CHALLENGES_EVERYONE)
	Game.settings.challenges_from = Game.CHALLENGES_EVERYONE
	c.invited.connect(func(_n: String) -> void: pass)
	c._on_inbox(_inv_msg(f, c))
	Game.settings.challenges_from = who_may
	_check(c.has_invite() and c.seeking, "the friend's challenge waits for an answer; the search still runs")
	c.answer(true)
	_check(not c.seeking and String(c.opponent.get("id", "")) == f.my_id, "ACCEPT ends the QUICK MATCH search and enters the friend's room")
	c.free()
	f.free()


## JOIN BY CODE's failure state and the leader's switch in the roster (design/GROUPS.txt 7).
func _code_leftovers() -> void:
	var host := _peer(Cloud.new())
	var guest := _peer(Cloud.new())
	host.my_code = "6612345678"
	host.set_code_join(true)
	guest.join_group_code("6612345678")
	guest._on_code_answer(host.my_id, host._on_code_ask(guest._code_ask_msg()))
	_check(guest.code_state == "in", "a valid answer: JOINING THE GROUP...")
	# The leader never lets the joiner in (it entered a match, the group filled): the join fails,
	# timed from the join's start even while the leader's rosters without this phone keep coming.
	guest._on_groster({"size": 2, "members": [{"id": host.my_id, "name": "HOST", "bundle": "default", "team": 0, "slot": 0}]})
	guest._grp.leader_ms = Time.get_ticks_msec()
	guest._tick_group(0.0, Time.get_ticks_msec())
	_check(guest.code_state == "in" and bool(guest._grp.joining), "a roster without this phone: still JOINING THE GROUP...")
	guest._grp.join_ms = Time.get_ticks_msec() - Cloud.JOIN_TIMEOUT_MS - 10
	guest._tick_group(0.0, Time.get_ticks_msec())
	_check(guest.code_state == "failed" and guest.group.is_empty() and LobbyTeam.code_state_text("failed") == "COULD NOT JOIN: TRY AGAIN",
		"never let in: COULD NOT JOIN: TRY AGAIN, out of the half-joined group (%s)" % guest.code_state)
	_check(guest.join_group_code("6612345678") == "" and guest.code_state == "asking", "after COULD NOT JOIN, JOIN asks again")
	# JOIN again while a join waits to be let in: the waiting one is dropped and the ask goes out.
	guest._on_code_answer(host.my_id, host._on_code_ask(guest._code_ask_msg()))
	_check(guest.code_state == "in" and not guest.group.is_empty(), "let in again")
	# The same code again, refused by a check (too many tries, offline): the waiting join stays as it was.
	var tries: Array = guest._code_tries.duplicate()
	for i in Cloud.CODE_TRIES_MAX:
		guest._code_tries.append(Time.get_ticks_msec())
	var waiting_leader := String(guest.group.get("leader", ""))
	_check(guest.join_group_code("6612345678") == "TOO MANY TRIES: WAIT A MINUTE" and guest.code_state == "in"
		and String(guest.group.get("leader", "")) == waiting_leader and bool(guest._grp.get("joining", false)),
		"the same code again, refused (too many tries): the waiting join is kept, no stale leader")
	guest._code_tries = tries
	guest._connected = false
	_check(guest.join_group_code("6612345678").begins_with("OFFLINE") and guest.code_state == "in" and not guest.group.is_empty(),
		"the same code again, offline: the waiting join is kept")
	guest._connected = true
	_check(guest.join_group_code("6612345678") == "" and guest.code_state == "asking" and guest.group.is_empty(),
		"JOIN while still waiting to be let in asks afresh (no EXIT YOUR GROUP FIRST)")
	# An answer this phone cannot take (wrapped for another phone's key): failed, not stuck.
	var other := _peer(Cloud.new())
	other.join_group_code("6612345678")
	var not_mine := host._on_code_ask(other._code_ask_msg())
	guest._on_code_answer(host.my_id, not_mine)
	_check(guest.code_state == "failed" and guest.group.is_empty(), "an answer that cannot be taken: COULD NOT JOIN (%s)" % guest.code_state)
	# In at last: the roster with this phone in it ends the join (no line left over).
	guest.join_group_code("6612345678")
	guest._on_code_answer(host.my_id, host._on_code_ask(guest._code_ask_msg()))
	host._on_gjoin(guest.my_id, {"name": "GUEST", "bundle": "default"})
	host.set_code_join(false)
	guest._on_groster(host._roster_msg())
	_check(guest.in_group() and guest.code_state == "", "in the group: the join by code is done")
	# The switch in the roster: a member shows the code only while the leader's switch is on.
	_check(String(guest.group.get("code", "")) == "6612345678" and guest.group_code() == "6612345678", "the roster carries the 10-digit code")
	_check(not guest.code_open() and not host.code_open(), "the leader's JOIN BY CODE off: the member's code is not open")
	host.set_code_join(true)
	guest._on_groster(host._roster_msg())
	_check(guest.code_open() and host.code_open(), "the leader turns it on: the member's code is open")
	var no_cj := host._roster_msg()
	no_cj.erase("cj")
	guest._on_groster(no_cj)
	_check(not guest.code_open(), "a roster without the switch reads as off")
	for c: Cloud in [host, guest, other]:
		c.free()


## IN A MATCH in the FRIENDS / ONLINE lists and the group's INVITE list: the lobby announce's "im".
func _presence() -> void:
	var me := _peer(Cloud.new())
	var other := _peer(Cloud.new())
	var hi := other.hello_msg()
	_check(not hi.has("im") and String(hi.get("t", "")) == "hi", "in the lobby the announce carries no IN A MATCH flag")
	other.in_session = true
	hi = other.hello_msg()
	_check(bool(hi.get("im", false)) and hi.keys().size() == 6,
		"in a match the announce says so (\"im\"), and nothing of the session")
	other.in_session = false
	var changed := [0]
	me.peers_changed.connect(func() -> void: changed[0] += 1)
	me._on_lobby(other.hello_msg())
	_check(me.peers.has(other.my_id) and not me.peer_in_match(other.my_id) and changed[0] == 1, "a player in the lobby reads ONLINE")
	other.session_multi = true
	me._on_lobby(other.hello_msg())
	_check(me.peer_in_match(other.my_id) and changed[0] == 2, "their announce from a match: IN A MATCH, the lists redraw")
	var old_build := other.hello_msg()
	old_build.erase("im")
	me._on_lobby(old_build)
	_check(not me.peer_in_match(other.my_id) and changed[0] == 3, "back in the lobby (or an older build, no flag): ONLINE again")
	var odd := other.hello_msg()
	odd["im"] = "yes"
	me._on_lobby(odd)
	_check(not me.peer_in_match(other.my_id), "a flag that is not a plain true reads as in the lobby")
	_check(LobbyFriends.presence_tag("  ·  ONLINE", true) == "  ·  IN A MATCH" and LobbyFriends.presence_tag("  ·  ONLINE", false) == "  ·  ONLINE"
		and LobbyFriends.presence_tag("  ·  OFFLINE", true) == "  ·  OFFLINE", "a row reads IN A MATCH only for an online player in a match")
	var a := "pa".sha256_text().left(32)
	var b := "pb".sha256_text().left(32)
	var rows := LobbyTeam.invite_rows({a: {"name": "ACE"}, b: {"name": "BEA"}}, {a: {"im": true}, b: {}})
	_check(rows.size() == 2 and bool(rows[0].in_match) and not bool(rows[1].in_match) and rows[0].online and rows[1].online,
		"the INVITE list marks a friend in a match (%s)" % str(rows))
	me.free()
	other.free()
