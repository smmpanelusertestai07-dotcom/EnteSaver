extends Node
## An all-human DUO (2 VS 2) over tests/mqtt_mock.gd with FOUR copies of the game (LW_NET_ROLE host,
## m1, m2, m3; tools/qa/run_checks.sh, step "team_direct", one round, LW_DIRECT=local: each copy's
## only candidate is 127.0.0.1, no STUN). The host opens a CUSTOM ROOM (DUO) with a fixed code and
## password, the three others join it by code, the host starts the match.
## 1. Within 10 s of the first fight every copy has its 3 pairs (Cloud._pairs) up, the HUD tag says
##    DIRECT, and more than 80 % of the states it takes from the others come over the pairs.
## 2. Team chat (Cloud.send_chat team_only): m1 says "TEST ONE" to its TEAM: its teammate shows it,
##    both enemies do not; then "TEST TWO" to ALL reaches all three.
## 3. m3 blocks its pairs (its UDP cut, as cloud_check does to the 1 vs 1's guest): within 3 s of
##    its pair going down every other copy takes m3's states from the relay again, its fighter keeps
##    moving there (m3 walks its player) and is never AWAY.
## 4. The host's team goes down in the zone: every copy ends with the same result (the host's team
##    DEFEAT, the other VICTORY) and prints the same RESULT line.
## Prints "TEAM DIRECT CHECK DONE bad=N".

const CODE := "434343"
const PIN := "4812"

var bad := 0
var at: Node
var role := ""
var host := false
var cloud: Cloud
var heard_chat: Array = []         # [text, from_id, team_only]


func run(autotest: Node) -> int:
	at = autotest
	role = OS.get_environment("LW_NET_ROLE")
	host = role == "host"
	cloud = Game.cloud_service()
	at.log_line("team direct check: %s (direct mode %s)" % [role, NetDirect.mode()])
	cloud.chat_from.connect(func(text: String, from_id: String, team_only: bool) -> void: heard_chat.append([text, from_id, team_only]))
	cloud.start_lobby()
	if not await _until(func() -> bool: return cloud.status == "online" and cloud.my_id != "", 30.0):
		return _done("never online")
	if host:
		await at.wait(1.0)
		cloud.open_room(PIN, {}, CODE, 2)
		if not await _until(func() -> bool: return (cloud.group.get("members", []) as Array).size() == 4, 60.0):
			return _done("the three others never joined the room (%d)" % (cloud.group.get("members", []) as Array).size())
		await at.wait(2.0)
		var why := cloud.room_start()
		if why != "":
			return _done("START refused: " + why)
	else:
		await at.wait(3.0)
		cloud.join_room(CODE, PIN)
	if not await _until(func() -> bool: return get_tree().current_scene is TeamArenaNet, 60.0):
		return _done("the match did not load")
	var arena := get_tree().current_scene
	await at.wait_for_phase(arena, 1, 60.0)
	if not is_instance_valid(arena) or int(arena.get("phase")) != 1:
		return _done("the fight never began")
	var ids := {}
	for e: Dictionary in arena.get("roster"):
		ids[String(e.id)] = int(e.slot)
	var me := cloud.my_id
	var others: Array = ids.keys().filter(func(id: String) -> bool: return id != me)
	# 1. Three pairs up within 10 s, the tag DIRECT, the states mostly over the pairs.
	var all_up := func() -> bool:
		for id: String in others:
			if not cloud.pair_up(id):
				return false
		return true
	if not await _until(all_up, 10.0):
		var ups := []
		for id: String in others:
			ups.append(cloud.pair_up(id))
		return _done("the 3 pairs were not up within 10 s of the fight (%s, %d open)" % [str(ups), cloud.pairs().size()])
	var hud_net := arena.find_child("HudNet", true, false)
	at.log_line("%s: 3 pairs up, tag %s, ping %d ms" % [role, cloud.link_tag(), cloud.match_ping()])
	if cloud.link_tag() != "DIRECT":
		_fail("the tag is not DIRECT with every pair up (%s)" % cloud.link_tag())
	if hud_net != null and String(hud_net.call("link_tag")) != "DIRECT":
		_fail("the HUD's tag is not DIRECT (%s)" % String(hud_net.call("link_tag")))
	var r0 := cloud.relay_states_in
	var p0 := cloud.pair_states_in
	await at.wait(3.0)
	var dr := cloud.relay_states_in - r0
	var dp := cloud.pair_states_in - p0
	at.log_line("%s: in 3 s %d states over the pairs, %d through the relay" % [role, dp, dr])
	if dp < 30 or float(dp) / float(maxi(dp + dr, 1)) <= 0.8:
		_fail("80 %% of the states do not come over the pairs (%d direct, %d relay)" % [dp, dr])
	# 2. Team chat: m1 to its TEAM, then to ALL.
	var mates := {}
	var my_team := int(arena.get("my_team"))
	for e: Dictionary in arena.get("roster"):
		mates[String(e.id)] = int(e.team) == my_team
	var m1_id := ""
	await at.wait(1.0)
	if role == "m1":
		var why := cloud.send_chat("test one", true)
		if why != "":
			_fail("m1's TEAM line did not go out (%s)" % why)
		await at.wait(NetChat.RATE_S + 0.5)
		why = cloud.send_chat("test two", false)
		if why != "":
			_fail("m1's ALL line did not go out (%s)" % why)
		await at.wait(3.0)
	else:
		await at.wait(NetChat.RATE_S + 3.5)
		var one := heard_chat.filter(func(c: Array) -> bool: return c[0] == "TEST ONE")
		var two := heard_chat.filter(func(c: Array) -> bool: return c[0] == "TEST TWO")
		if not two.is_empty():
			m1_id = String(two[0][1])
		var mate_of_m1 := m1_id != "" and bool(mates.get(m1_id, false))
		at.log_line("%s: chat heard %s (m1 is a teammate: %s)" % [role, str(heard_chat), mate_of_m1])
		if two.size() != 1 or bool(two[0][2]):
			_fail("the ALL line did not reach this copy once as ALL")
		elif mate_of_m1 and (one.size() != 1 or not bool(one[0][2]) or String(one[0][1]) != m1_id):
			_fail("m1's teammate did not get its TEAM line")
		elif not mate_of_m1 and not one.is_empty():
			_fail("an enemy got m1's TEAM line")
	# 3. m3 cuts its pairs.
	var down := [""]
	await at.wait(1.0)
	if role == "m3":
		for p: NetDirect in cloud.pairs().values():
			p.blocked = true
		at.log_line("m3: pairs blocked, tag %s" % cloud.link_tag())
		var pl := arena.get("player") as Fighter
		var out0 := cloud.relay_states_out
		for i in 16:
			pl.global_position += Vector3(0.25, 0.0, 0.0)   # (it walks: its state changes)
			await at.wait(0.25)
			if i % 4 == 3:
				at.log_line("m3: %d states through the relay since the block" % (cloud.relay_states_out - out0))
		if cloud.relay_states_out < 10:
			_fail("m3 did not send its states through the relay with its pairs blocked (%d)" % cloud.relay_states_out)
		if cloud.link_tag() != "RELAY":
			_fail("m3's tag is not RELAY with its pairs blocked (%s)" % cloud.link_tag())
	else:
		# (m3: the one whose pair goes down; never this copy)
		if not await _until(func() -> bool:
				for id: String in others:
					if not cloud.pair_up(id):
						down[0] = id
						return true
				return false, 12.0):
			return _done("no pair went down when m3 blocked its pairs")
		var m3_id := String(down[0])
		var c0: Array = cloud.state_counts.get(m3_id, [0, 0])
		var f := arena.call("slot_fighter", int(ids[m3_id])) as RemoteFighter
		var pos0 := f.global_position
		var away := [false]
		var watch := func() -> bool:
			away[0] = away[0] or f.away
			var c: Array = cloud.state_counts.get(m3_id, [0, 0])
			return int(c[0]) - int(c0[0]) >= 10
		for i in 6:
			at.log_line("%s: m3's states %s" % [role, str(cloud.state_counts.get(m3_id))])
			await at.wait(0.5)
		if not await _until(watch, 3.0):
			_fail("m3's states did not come through the relay within 3 s of its pair going down (%s -> %s)"
				% [str(c0), str(cloud.state_counts.get(m3_id))])
		await at.wait(1.5)
		away[0] = away[0] or f.away
		at.log_line("%s: m3's pair down, its states from the relay %s -> %s, moved %.2f m, away %s, tag %s" % [role, str(c0),
			str(cloud.state_counts.get(m3_id)), f.global_position.distance_to(pos0), away[0], cloud.link_tag()])
		if f.global_position.distance_to(pos0) < 0.5:
			_fail("m3's fighter does not keep moving here")
		if away[0]:
			_fail("m3's fighter went AWAY when its pairs were cut")
		if not cloud.link_tag().begins_with("DIRECT 2/3"):
			_fail("the tag is not DIRECT 2/3 with m3's pair down (%s)" % cloud.link_tag())
	await at.wait(2.0)
	# 4. The host's team goes down in the zone.
	var host_id := String(arena.get("host_id"))
	var hslot := int(ids[host_id])
	var host_team := int((arena.call("slot_fighter", hslot) as Fighter).team)
	if my_team == host_team:
		var pl := arena.get("player") as Fighter
		var n := 0
		while pl.alive and n < 20:
			n += 1
			pl.take_damage(100.0, "body", null, pl.global_position, "zone")
			await at.wait(0.2)
	if not await _until(func() -> bool: return is_instance_valid(arena) and bool(arena.get("_result_shown")), 60.0):
		return _done("the match did not end with its result")
	var hist: Array = Game.profile.history
	var h: Dictionary = hist[0] if not hist.is_empty() else {}
	var want := "lost" if my_team == host_team else "won"
	var host_result := String(h.get("result", "?"))
	if my_team != host_team:
		host_result = {"won": "lost", "lost": "won"}.get(host_result, "?")
	at.log_line("RESULT the host's team %s" % host_result)
	at.log_line("%s: result %s (want %s), history %d" % [role, str(h.get("result")), want, hist.size()])
	if h.get("result") != want or hist.size() != 1:
		_fail("the match did not end as one %s here" % want)
	await at.wait(3.0)
	return _done("")


func _until(cond: Callable, seconds: float) -> bool:
	var t := 0.0
	while not cond.call() and t < seconds:
		await at.wait(0.25)
		t += 0.25
	return cond.call()


func _fail(what: String) -> void:
	bad += 1
	at.log_line("FAIL " + what)


func _done(error: String) -> int:
	if error != "":
		_fail(error)
	at.log_line("TEAM DIRECT CHECK DONE bad=%d" % bad)
	return bad
