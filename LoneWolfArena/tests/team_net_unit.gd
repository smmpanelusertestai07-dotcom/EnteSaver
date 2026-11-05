extends RefCounted
## Unit tests of DUO / SQUAD between two phones (WP-N): Cloud's team invites ("tinv") and team
## searches (ROOT/mm/t<size>), the Privacy Notice about them, and TeamArenaNet's message limits
## (bot states packed into one "tk", hits held to the attacker's gun, decisions only from the host).
## Run from tests/run_tests.gd (which counts the checks).

var t: Node


## A Cloud that keeps what it would publish ([topic, payload]) instead of sending it.
class RecordingCloud extends Cloud:
	var sent := []

	func _publish(topic: String, payload: PackedByteArray, _retain := false) -> void:
		sent.append([topic, payload])

	func _send_packet(_p: PackedByteArray) -> void:
		pass

	func last() -> Dictionary:
		if sent.is_empty():
			return {}
		var d: Variant = JSON.parse_string((sent[sent.size() - 1][1] as PackedByteArray).get_string_from_utf8())
		return d if d is Dictionary else {}


static func run(runner: Node) -> void:
	var me := new()
	me.t = runner
	var saved_at := Game.autotest
	var saved_profile := Game.profile.duplicate(true)
	var saved_settings := Game.settings.duplicate(true)
	Game.autotest = "unit"                  # nothing is saved
	me._team_bytes()
	me._team_invites()
	me._team_seek()
	me._privacy()
	me._arena_net()
	Game.profile = saved_profile
	Game.settings = saved_settings
	Game.autotest = saved_at


func _check(cond: bool, what: String) -> void:
	t.call("_check", cond, what)


func _team_bytes() -> void:
	var ok := true
	for size: int in [2, 4]:
		for coop: bool in [false, true]:
			for quick: bool in [false, true]:
				var b := Cloud.team_byte(size, coop, quick)
				if coop and quick:
					ok = ok and b == -1
				else:
					ok = ok and b >= 0 and b < 256 and Cloud.team_from_byte(b) == {"size": size, "coop": coop, "quick": quick}
	_check(ok, "a team invite's byte packs and unpacks the size, coop and quick")
	_check(Cloud.team_byte(3, false, false) == -1 and Cloud.team_byte(1, true, false) == -1 and Cloud.team_byte(8, false, true) == -1,
		"only DUO and SQUAD are team sizes")
	var bad := true
	for b: int in [-1, 0, 1, 3, 5, 6, 7, 2 | 8 | 16, 4 | 32, 255, 2 | 64]:
		bad = bad and Cloud.team_from_byte(b).is_empty()
	_check(bad, "a byte naming no team (another size, coop and quick, high bits) is refused")


func _team_invites() -> void:
	var c := Crypto.new()
	var ka := c.generate_rsa(2048)
	var kb := c.generate_rsa(2048)
	var me := RecordingCloud.new()
	me._use_key(kb)
	var rival := RecordingCloud.new()
	rival._use_key(ka)
	rival._connected = true
	rival.peers[me.my_id] = {"name": "ME", "bundle": "default", "pk": kb.save_to_string(true), "seen": 0}
	var rid := rival.my_id
	Game.profile.blocked = []
	Game.profile.friends = {rid: {"name": "ACE"}}
	Game.settings.challenges_from = Game.CHALLENGES_EVERYONE
	var shown := []
	me.invited.connect(func(who: String) -> void: shown.append(who))
	# A coop TEAM INVITE: signed, the team only inside the RSA part.
	_check(not rival.team_invite(me.my_id, 3, true) and not rival.team_invite(me.my_id, 2, true, true) and rival.sent.is_empty(),
		"no team invite for another size, or a quick one into one's own team")
	_check(rival.team_invite(me.my_id, 2, true) and rival.sent.size() == 1, "a team invite goes out")
	var inv := rival.last()
	var keys := inv.keys()
	keys.sort()
	_check(keys == ["bundle", "from", "name", "pk", "sec", "sig", "t"] and String(inv.get("t", "")) == "tinv"
		and String(rival.sent[0][0]).ends_with("/u/" + me.my_id), "a team invite carries a duel challenge's fields, kind tinv (%s)" % str(keys))
	_check(rival.session_team == {"size": 2, "coop": true} and rival.is_host and rival.waiting_for() == "ME",
		"the inviter hosts, its session_team set")
	var opened := c.decrypt(kb, Marshalls.base64_to_raw(String(inv.sec)))
	_check(opened.size() == 81 and Cloud.team_from_byte(opened[80]) == {"size": 2, "coop": true, "quick": false},
		"the RSA part is the 80 key bytes and the team byte")
	_check(me.team_invite_proven(inv, rid) and not me.team_invite_proven(inv, "c3".repeat(16)) and not me.invite_proven(inv, rid),
		"its signature proves the sender for a team invite only (not as a duel challenge)")
	var changed := inv.duplicate()
	var sec := String(inv.sec)
	changed.sec = sec.left(10) + ("A" if sec[10] != "A" else "B") + sec.substr(11)
	_check(not me.team_invite_proven(changed, rid), "a changed byte fails the signature")
	me._on_inbox(inv)
	_check(shown.size() == 1, "a friend's coop team invite is shown")
	_check(me.has_invite() and me.invite_from().get("team", {}) == {"size": 2, "coop": true} and String(me.invite_from().id) == rid,
		"invite_from names the team")
	me.answer(true)
	_check(me.session_team == {"size": 2, "coop": true} and not me.is_host and String(me.last().get("t", "")) == "acc",
		"accepting sets session_team on the guest too")
	me.in_session = true
	me.end_session("left")
	_check(me.session_team.is_empty() and not me.in_session, "end_session clears session_team")
	# The same invite from a stranger (signed) is never shown: declined at once.
	_reset(me)
	shown.clear()
	Game.profile.friends = {}
	me._on_inbox(inv)
	_check(shown.is_empty() and not me.has_invite() and String(me.last().get("t", "")) == "dec", "a coop team invite from a non-friend is declined, never shown")
	Game.profile.friends = {rid: {"name": "ACE"}}
	# Unsigned, or signed as a duel: ignored without an answer.
	_reset(me)
	var unsigned := inv.duplicate()
	unsigned.erase("sig")
	me._on_inbox(unsigned)
	var as_duel := inv.duplicate()
	as_duel.sig = rival._sign(Cloud.invite_text(rid, me.my_id, String(inv.sec)))
	me._on_inbox(as_duel)
	_check(shown.is_empty() and not me.has_invite() and me.sent.is_empty(), "an unsigned team invite, or one signed as a duel, is ignored")
	# A duel's 80 key bytes sent as a team invite (properly signed): no team, ignored.
	_reset(me)
	var pub := CryptoKey.new()
	pub.load_from_string(kb.save_to_string(true), true)
	var short_sec := Marshalls.raw_to_base64(c.encrypt(pub, c.generate_random_bytes(80)))
	me._on_inbox({"t": "tinv", "from": rid, "name": "ACE", "sec": short_sec, "pk": rival._pk_pem,
		"sig": rival._sign(Cloud.team_invite_text(rid, me.my_id, short_sec))})
	_check(not me.has_invite() and me.sent.is_empty() and shown.is_empty(), "a team invite without its team byte is ignored")
	# FRIENDS ONLY takes a friend's; NOBODY takes none; a blocked friend is ignored.
	_reset(me)
	Game.settings.challenges_from = Game.CHALLENGES_FRIENDS
	me._on_inbox(inv)
	_check(shown.size() == 1, "with challenges from friends only, a friend's team invite is shown")
	_reset(me)
	shown.clear()
	Game.settings.challenges_from = Game.CHALLENGES_NOBODY
	me._on_inbox(inv)
	_check(shown.is_empty() and String(me.last().get("t", "")) == "dec", "with challenges from nobody, a team invite is declined")
	Game.settings.challenges_from = Game.CHALLENGES_EVERYONE
	_reset(me)
	Game.profile.blocked = [{"id": rid, "name": "ACE"}]
	me._on_inbox(inv)
	_check(shown.is_empty() and me.sent.is_empty() and not me.has_invite(), "a blocked player's team invite is ignored")
	Game.profile.blocked = []
	# Busy (a challenge waiting here already): declined at once.
	_reset(me)
	me._incoming = {"id": "d4".repeat(16), "name": "OTHER", "room": "00", "mac": PackedByteArray([1]), "t": Time.get_ticks_msec()}
	me._on_inbox(inv)
	_check(shown.is_empty() and String(me.last().get("t", "")) == "dec" and String(me.invite_from().id) == "d4".repeat(16),
		"a team invite while busy is declined, the waiting one kept")
	# In a match nobody listens: declined at once.
	_reset(me)
	var listeners := me.invited.get_connections()
	for con: Dictionary in listeners:
		me.invited.disconnect(con.callable)
	me._on_inbox(inv)
	_check(not me.has_invite() and String(me.last().get("t", "")) == "dec", "a team invite with nobody listening (in a match) is declined")
	for con: Dictionary in listeners:
		me.invited.connect(con.callable)
	# Quick: taken at once only while searching that size and having heard the seeker.
	rival.cancel_invite(false)
	_check(rival.session_team.is_empty(), "calling a team invite off clears the inviter's session_team")
	rival.sent.clear()
	_check(rival.team_invite(me.my_id, 2, false, true), "a quick team challenge goes out")
	var quick := rival.last()
	for c2: Array in [[0, true, false, "not searching"], [4, true, false, "searching SQUAD"], [2, false, false, "never heard it seek"],
			[2, true, true, "searching DUO, heard it"]]:
		_reset(me)
		shown.clear()
		if int(c2[0]) > 0:
			me.team_seek_start(int(c2[0]))
		if bool(c2[1]):
			me.quick_seen[rid] = Time.get_ticks_msec()
		me._on_inbox(quick)
		var said := String(me.last().get("t", ""))
		_check(shown.is_empty() and said == ("acc" if c2[2] else "dec") and (me.session_team == {"size": 2, "coop": false}) == bool(c2[2]),
			"a quick DUO team challenge %s: %s" % [c2[3], "taken at once" if c2[2] else "declined"])
		me.seek_stop()
	# The 1 vs 1 quick challenge is not taken during a team search.
	_reset(me)
	me.team_seek_start(2)
	me.quick_seen[rid] = Time.get_ticks_msec()
	rival.cancel_invite(false)
	rival.sent.clear()
	rival.invite(me.my_id, {"quick": true})
	me._on_inbox(rival.last())
	_check(String(me.last().get("t", "")) == "dec", "a 1 vs 1 quick challenge during a team search is declined")
	me.seek_stop()
	rival.cancel_invite(false)
	_check(rival.session_team.is_empty(), "a duel challenge never carries a team")
	_play_again(me, rival, shown)
	me.free()
	rival.free()
	Game.profile.friends = {}


## PLAY AGAIN TOGETHER / a team REMATCH (Cloud.play_again, set by the results screen's tap): a
## stranger's team invite (not quick) is declined as before, and reaches the results (which take it
## at once) only while this player wants another match with exactly that player, size and coop.
## Every other check stays: DUEL CHALLENGES FROM, blocked players, busy.
func _play_again(me: RecordingCloud, rival: RecordingCloud, shown: Array) -> void:
	var rid := rival.my_id
	Game.profile.friends = {}
	Game.settings.challenges_from = Game.CHALLENGES_EVERYONE
	rival.cancel_invite(false)
	rival.sent.clear()
	_check(rival.team_invite(me.my_id, 2, false), "a team REMATCH invite (not quick) goes out")
	var again := rival.last()
	rival.cancel_invite(false)
	rival.sent.clear()
	rival.team_invite(me.my_id, 2, true)
	var together := rival.last()
	rival.cancel_invite(false)
	var take := func(_who: String) -> void: me.answer(true)
	me.invited.connect(take)
	_reset(me)
	shown.clear()
	me.play_again = {}
	me._on_inbox(again)
	_check(shown.is_empty() and String(me.last().get("t", "")) == "dec", "a stranger's team invite is declined while no play-again is wanted")
	for c3: Array in [[{"id": rid, "size": 4, "coop": false}, "for SQUAD"], [{"id": rid, "size": 2, "coop": true}, "for co-op"],
			[{"id": "c3".repeat(16), "size": 2, "coop": false}, "with another player"]]:
		_reset(me)
		shown.clear()
		me.play_again = c3[0]
		me._on_inbox(again)
		_check(shown.is_empty() and String(me.last().get("t", "")) == "dec", "a play-again wanted %s does not let this invite in" % c3[1])
	_reset(me)
	shown.clear()
	me.play_again = {"id": rid, "size": 2, "coop": false}
	me._on_inbox(again)
	_check(shown.size() == 1 and String(me.last().get("t", "")) == "acc" and me.session_team == {"size": 2, "coop": false} and not me.is_host,
		"while a REMATCH with that player (DUO, against them) is wanted, their team invite is taken")
	_reset(me)
	shown.clear()
	me.play_again = {"id": rid, "size": 2, "coop": true}
	me._on_inbox(together)
	_check(shown.size() == 1 and String(me.last().get("t", "")) == "acc" and me.session_team == {"size": 2, "coop": true},
		"while PLAY AGAIN TOGETHER with that player is wanted, their co-op invite is taken (friend or not)")
	# The checks before it still hold.
	_reset(me)
	shown.clear()
	me.play_again = {"id": rid, "size": 2, "coop": false}
	Game.settings.challenges_from = Game.CHALLENGES_NOBODY
	me._on_inbox(again)
	_check(shown.is_empty() and String(me.last().get("t", "")) == "dec", "with challenges from nobody, a wanted play-again invite is declined")
	Game.settings.challenges_from = Game.CHALLENGES_FRIENDS
	_reset(me)
	me._on_inbox(again)
	_check(shown.is_empty() and String(me.last().get("t", "")) == "dec", "with challenges from friends only, a stranger's play-again invite is declined")
	Game.settings.challenges_from = Game.CHALLENGES_EVERYONE
	_reset(me)
	Game.profile.blocked = [{"id": rid, "name": "ACE"}]
	me._on_inbox(again)
	_check(shown.is_empty() and me.sent.is_empty() and not me.has_invite(), "a blocked player's play-again invite is ignored")
	Game.profile.blocked = []
	_reset(me)
	me._incoming = {"id": "d4".repeat(16), "name": "OTHER", "room": "00", "mac": PackedByteArray([1]), "t": Time.get_ticks_msec()}
	me._on_inbox(again)
	_check(shown.is_empty() and String(me.last().get("t", "")) == "dec", "a play-again invite while busy is declined")
	var unsigned := again.duplicate()
	unsigned.erase("sig")
	_reset(me)
	me._on_inbox(unsigned)
	_check(shown.is_empty() and me.sent.is_empty() and not me.has_invite(), "an unsigned play-again invite is ignored")
	rival.sent.clear()
	rival.team_invite(me.my_id, 2, false, true)
	var quick := rival.last()
	rival.cancel_invite(false)
	_reset(me)
	me._on_inbox(quick)
	_check(shown.is_empty() and String(me.last().get("t", "")) == "dec", "a quick team challenge is not a play-again: declined outside a search")
	me.play_again = {}
	_reset(me)
	me._on_inbox(again)
	_check(shown.is_empty() and String(me.last().get("t", "")) == "dec", "once the results let go (play_again cleared) it is declined again")
	me.invited.disconnect(take)


func _reset(me: RecordingCloud) -> void:
	me._incoming = {}
	me._outgoing = {}
	me._leave_room()
	me.session_team = {}
	me.sent.clear()
	me._inbox_budget = 8.0


func _team_seek() -> void:
	var me := RecordingCloud.new()
	me.my_id = "a1".repeat(16)
	me._connected = true
	var seen := []
	me.seeker_seen.connect(func(id: String, _saw: Array) -> void: seen.append(id))
	var seek := func(id: String) -> PackedByteArray:
		return JSON.stringify({"t": "seek", "id": id, "saw": []}).to_utf8_buffer()
	me.team_seek_start(2)
	me.send_seek([])
	_check(me.seeking and me.seek_team == 2 and String(me.sent[0][0]) == Cloud.ROOT + "/mm/t2", "a DUO search seeks on ROOT/mm/t2")
	me._on_publish(Cloud.SEEK_TOPIC, seek.call("b1".repeat(16)))
	me._on_publish(Cloud.ROOT + "/mm/t4", seek.call("b2".repeat(16)))
	me._on_publish(Cloud.ROOT + "/mm/t2", seek.call("b3".repeat(16)))
	_check(seen == ["b3".repeat(16)] and me.quick_seen.keys() == ["b3".repeat(16)], "a DUO search hears only DUO seekers (%s)" % str(seen))
	for i in 300:
		me._on_seek(seek.call("%032x" % (i + 1)))
	_check(me.quick_seen.size() <= Cloud.QUICK_SEEN_MAX and me.quick_seen.has("%032x" % 300), "a flood of seekers keeps quick_seen at %d at most (%d)" % [Cloud.QUICK_SEEN_MAX, me.quick_seen.size()])
	me.seek_start()
	me.sent.clear()
	me.send_seek([])
	_check(me.seek_team == 0 and me.quick_seen.is_empty() and String(me.sent[0][0]) == Cloud.SEEK_TOPIC, "the 1 vs 1 search after a team search seeks on its own topic")
	seen.clear()
	me._on_publish(Cloud.ROOT + "/mm/t2", seek.call("b4".repeat(16)))
	me._on_publish(Cloud.SEEK_TOPIC, seek.call("b5".repeat(16)))
	_check(seen == ["b5".repeat(16)], "the 1 vs 1 search hears only 1 vs 1 seekers")
	me.team_seek_start(4)
	me.team_seek_stop()
	_check(not me.seeking and me.seek_team == 0 and me.quick_seen.is_empty(), "team_seek_stop ends the search")
	me.team_seek_start(3)
	_check(not me.seeking, "no team search for another size")
	me.free()


func _privacy() -> void:
	var notice := ""
	for sct: Array in Login.privacy_sections():
		notice += String(sct[0]) + "\n" + String(sct[1]) + "\n"
	_check(notice.contains("TEAM INVITE") and notice.contains("team size travels encrypted")
		and notice.contains("QUICK MATCH, or a DUO or SQUAD match") and notice.contains("IDs of the other players it saw searching"),
		"the Privacy Notice tells of team invites and the searches")


## TeamArenaNet's limits on what the other phone says, on a stand-in match (not in the tree: its
## _ready would build the arena). Coop DUO: slot 0 the host's player, 1 the guest's, 2 and 3 bots.
func _arena_net() -> void:
	var holder := Node3D.new()
	t.add_child(holder)
	var guest := _stand_in(holder, false)
	var g: Array = guest.slots
	var mine: Fighter = g[1]
	var bot: Fighter = g[2]
	_check(guest.runs_here(mine) and not guest.runs_here(g[0]) and not guest.runs_here(bot) and g[0] is RemoteFighter and bot is RemoteFighter,
		"the guest runs only its own player")
	# A hit far over the attacker's gun is held to one bullet of it (x 1.02, before the armour).
	var most := guest.max_hit_by(bot, "limb")
	guest._on_net_event("hit", [1, 2, 5000.0, "limb", 0.0, 1.0, 0.0])
	var took := Fighter.MAX_HP - mine.hp
	_check(took > 0.0 and took <= mine.hit_points(most, "limb") + 0.01, "a hit over the attacker's gun is clamped (%.1f taken, %.1f at most)" % [took, most])
	mine.hp = Fighter.MAX_HP
	guest._on_net_event("hit", [1, 0, 30.0, "body", 0.0, 1.0, 0.0])
	guest._on_net_event("hit", [2, 3, 30.0, "body", 0.0, 1.0, 0.0])
	guest._on_net_event("hit", [1, 2, NAN, "body", 0.0, 1.0, 0.0])
	guest._on_net_event("hit", [1, 2, 30.0, "feet", 0.0, 1.0, 0.0])
	_check(mine.hp == Fighter.MAX_HP, "no hit from a teammate, on a fighter the other phone runs, of NaN or in no zone")
	guest.phase = TeamArenaNet.Phase.BREAK
	guest._on_net_event("hit", [1, 2, 30.0, "body", 0.0, 1.0, 0.0])
	_check(mine.hp == Fighter.MAX_HP, "no hit outside the fight")
	guest.phase = TeamArenaNet.Phase.FIGHT
	var n := 0
	for i in 60:
		var before := mine.hp
		mine.hp = Fighter.MAX_HP
		guest._on_net_event("hit", [1, 2, 1.0, "limb", 0.0, 1.0, 0.0])
		n += 1 if mine.hp < Fighter.MAX_HP else 0
		mine.hp = before
	_check(n > 0 and n < 40, "a burst of hits is held to the attacker's rate (%d of 60 taken)" % n)
	# Decisions: only the host's; the guest's player's own "dn" goes to the host.
	guest._on_net_event("ko", [1, 2, false, "laser"])
	_check(not mine.knocked, "a decision naming no known cause is ignored")
	guest._on_net_event("ko", [1, 2, false, "gun"])
	_check(mine.knocked and mine.alive, "the host's \"ko\" is applied on the guest")
	var host := _stand_in(holder, true)
	var h: Array = host.slots
	host._on_net_event("ko", [0, 2, false, "gun"])
	host._on_net_event("el", [2, 0, false, "gun"])
	host._on_net_event("rend", [1, 0, 1, 0, false])
	_check(not (h[0] as Fighter).knocked and (h[2] as Fighter).alive and host.phase == TeamArenaNet.Phase.FIGHT,
		"decisions sent by the guest are ignored by the host")
	host._on_net_event("dn", [2, 1, 1, false, "gun", false])
	host._on_net_event("dn", [0, 1, 2, false, "gun", false])
	_check(not (h[2] as Fighter).knocked and not (h[0] as Fighter).knocked, "a \"dn\" for a slot the guest does not run is ignored")
	host._on_net_event("dn", [1, 2, 2, false, "gun", false])
	_check(not (h[1] as Fighter).knocked, "a \"dn\" for another round is ignored")
	host._on_net_event("dn", [1, 1, 2, true, "gun", false])
	_check((h[1] as Fighter).knocked and (h[1] as Fighter).alive, "the guest's \"dn\" makes the host's referee knock its player")
	host._on_net_event("rvd", [1, 0, 1])
	_check((h[1] as Fighter).knocked, "a revive by a knocked fighter (or of an UP one) is refused")
	# The bots' states in one "tk".
	var packed := TeamArenaNet.pack_bots([h[2], h[3]])
	var back := TeamArenaNet.unpack_bots(packed, [2, 3], 1)
	var same: bool = back.size() == 2
	if same:
		var a := RemoteFighter.pack(h[2], 1)
		for i in RemoteFighter.STATE_SIZE:
			same = same and absf(float(back[2][i]) - a[i]) <= (0.006 if i < 3 else (0.0006 if i < 5 else 0.06))
	_check(same, "pack_bots / unpack_bots round trip (%s)" % packed)
	_check(TeamArenaNet.unpack_bots(packed, [3], 1).is_empty(), "a \"tk\" naming a slot that is not a bot is refused")
	_check(TeamArenaNet.unpack_bots("2:1,2,nan,0,0,0,0,0,100", [2], 1).is_empty() and TeamArenaNet.unpack_bots("2:1,2,3,0,0,0,0,0", [2], 1).is_empty()
		and TeamArenaNet.unpack_bots("2:1,2,3,0,0,0,0,0,inf", [2], 1).is_empty() and TeamArenaNet.unpack_bots("2:1,2,3,0,0,0,0,0,1;2:1,2,3,0,0,0,0,0,1", [2], 1).is_empty(),
		"a \"tk\" with NaN, a missing number or a slot twice is refused")
	_check(TeamArenaNet.unpack_bots("2:" + "1,".repeat(2000) + "1", [2], 1).is_empty(), "an over-long \"tk\" is refused")
	# A SQUAD's worst case: six bots, every number as long as it gets.
	var six := []
	for i in 6:
		var b := Bot.new()
		b.slot = i + 2
		b.set_loadout("ar")
		b.process_mode = Node.PROCESS_MODE_DISABLED
		holder.add_child(b)
		b.global_position = Vector3(-21.99, 10.55, -15.99)
		b.aim_yaw = -3.1415
		b.aim_pitch = -1.2345
		b.knocked = true
		b.knock_hp = 33.33
		six.append(b)
	var squad := TeamArenaNet.pack_bots(six)
	_check(squad.length() <= 1000 and TeamArenaNet.unpack_bots(squad, [2, 3, 4, 5, 6, 7], 1).size() == 6, "a SQUAD \"tk\" is %d characters (at most 1000)" % squad.length())
	_check(TeamArenaNet.fin_from([1, 1, 2, 1, 0, 120, 1, 10, 5, 0]).size() > 0 and TeamArenaNet.fin_from([1, 1, 2, 1, 0, 120, 1, 10, 50, 0]).is_empty()
		and TeamArenaNet.fin_from([1, 1, -2, 1, 0, 120, 1, 10, 5, 0]).is_empty() and TeamArenaNet.fin_from([1, 1, 2]).is_empty(),
		"a \"fin\" with more hits than shots, a negative number or too few numbers is refused")
	guest.free()
	host.free()
	holder.queue_free()


## A coop DUO TeamArenaNet as one phone sees it in the fight (not in the tree), with its fighters
## under `holder` (in the tree, not processing).
func _stand_in(holder: Node3D, as_host: bool) -> TeamArenaNet:
	var a := TeamArenaNet.new()
	a.am_host = as_host
	a.coop = true
	a.guest_slot = 1
	a.my_slot = 0 if as_host else 1
	a.round_index = 1
	a.phase = TeamArenaNet.Phase.FIGHT
	var teams := {}
	var list: Array[Fighter] = []
	for s in 4:
		a.roster.append({"slot": s, "team": 0 if s < 2 else 1, "bot": s >= 2, "name": "F%d" % s})
		var f: Fighter = Bot.new() if a.runs_slot(s) else RemoteFighter.new()
		f.slot = s
		f.team = 0 if s < 2 else 1
		f.set_loadout("ar")
		f.process_mode = Node.PROCESS_MODE_DISABLED
		holder.add_child(f)
		f.global_position = Vector3(float(s), 1.0, 0.0)
		list.append(f)
		teams[s] = f.team
	a.slots = list
	a.fighters = list.duplicate()
	a.referee.setup(teams)
	return a
