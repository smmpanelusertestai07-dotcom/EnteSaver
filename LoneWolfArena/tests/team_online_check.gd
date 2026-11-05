extends Node
## DUO between two phones end to end (TeamArenaNet over Cloud's 1 vs 1 session, the team invite and
## the team search, through tests/mqtt_mock.gd on port 47820, started by tools/qa/run_checks.sh):
## two copies (LW_NET_ROLE host / guest), LW_ROUNDS_TO_WIN=1.
##  a. TEAM INVITE (coop): the host invites the guest (a friend), the guest taps ACCEPT; both load
##     team_arena_net (the online pause menu never pauses the tree) and fight two bots together. An
##     enemy bot's real hits on the host knock the guest's player ("ko" on both), the host's player
##     revives it (UP on both), the host's player puts both enemy bots out: the same round's end on
##     both, results whose tables match (each copy writes its table to LW_TEAM_OUT; the step compares
##     the two files), every state the guest sent arrived (a lossless mock: 100%), the match in each
##     HISTORY.
##  a2. PLAY AGAIN TOGETHER: both copies tap it on those results (each once its own are up, in either
##     order); a second co-op match loads from the results (team_arena_net, the same slots and sides,
##     the old host hosting again), plays to its results, and HISTORY keeps two co-op matches.
##  d. TEAM INVITE again, and the host quits once the fight began: the guest's match cannot go on
##     (the bots ran on the host): THE HOST LEFT, back to the lobby, the match kept as ENDED.
##  b. random DUO (the team search): both search ROOT/mm/t2, the lower id challenges ("tinv" quick),
##     the other takes it at once: each player with a bot teammate against the other. The guest sees
##     the host's bots move, a guest hit on a host bot lands on the host, the guest's pause menu
##     keeps its match running for 3 s while the host never hears it go quiet, then the guest quits:
##     the host wins by forfeit: its results offer no REMATCH (a forfeit), ADD FRIEND stays.
##  c. a plain duel between the same two copies afterwards is still the 1 vs 1 (arena.tscn, no
##     session_team) once the lobby has cleared Game.team_match.
## Prints "TEAM ONLINE CHECK DONE bad=N".

var bad := 0
var at: Node
var host := false
var cloud: Cloud
var other := ""
var _started := false
var _history_before := 0


func run(autotest: Node) -> int:
	at = autotest
	host = OS.get_environment("LW_NET_ROLE") == "host"
	Game.mode = "lonewolf"
	if not await _until(func() -> bool: return get_tree().current_scene is Lobby, 30.0):
		return _done("the lobby never came up")
	cloud = Game.cloud_service()
	cloud.start_lobby()
	cloud.session_started.connect(func(_h: bool) -> void: _started = true)
	if not await _until(func() -> bool: return cloud.status == "online" and not cloud.peers.is_empty(), 30.0):
		return _done("the other phone was never seen in the lobby")
	other = String(cloud.peers.keys()[0])
	Game.add_friend(other, String(cloud.peers[other].name))      # (each other's friend: a TEAM INVITE needs it)
	if not await _coop():
		return _done("")
	if not await _until(func() -> bool: return get_tree().current_scene is Lobby and not cloud.in_session, 30.0):
		return _done("never back in the lobby after the first match")
	await at.wait(1.0)
	await _host_quits()
	if not await _until(func() -> bool: return get_tree().current_scene is Lobby and not cloud.in_session, 30.0):
		return _done("never back in the lobby after the host left")
	await at.wait(1.0)
	var role_host := host
	await _random_duo()
	host = role_host
	if await _until(func() -> bool: return get_tree().current_scene is Lobby and not cloud.in_session, 30.0):
		await _duel()
	else:
		_fail("never back in the lobby after the random DUO")
	return _done("")


func _info(id: String) -> Dictionary:
	if id == cloud.my_id:
		return {"id": id, "name": String(Game.profile.name), "bundle": String(Game.profile.bundle)}
	var p: Dictionary = cloud.peers.get(id, cloud.opponent)
	return {"id": id, "name": String(p.get("name", "PLAYER")), "bundle": String(p.get("bundle", "default"))}


## Both phones build the same roster (what the lobby does when the session starts).
func _link(size: int, coop: bool, host_id: String, guest_id: String) -> void:
	Game.team_match = TeamArena.link_match(size, coop, _info(host_id), _info(guest_id), host_id == cloud.my_id, (host_id + guest_id).hash())


func _arena() -> TeamArenaNet:
	if not await _until(func() -> bool: return get_tree().current_scene is TeamArenaNet, 40.0):
		_fail("the match never loaded team_arena_net (%s)" % str(get_tree().current_scene))
		return null
	var arena := get_tree().current_scene as TeamArenaNet
	await at.wait_for_phase(arena, 1, 60.0)
	if arena.phase != 1:
		_fail("never reached FIGHT")
		return null
	return arena


# ---------------------------------------------------------------- a. TEAM INVITE (coop)

func _coop() -> bool:
	_started = false
	_history_before = (Game.profile.get("history", []) as Array).size()
	if host:
		await at.wait(2.0)
		_link(2, true, cloud.my_id, other)
		# The guest makes the host its friend when it first sees it in the lobby, which can be a
		# lobby announcement later than the host saw the guest: a TEAM INVITE before that is
		# declined (only a friend's team invite is shown), and _invite_until_taken sends it again.
		if not await _invite_until_taken(func() -> bool: return cloud.team_invite(other, 2, true), "team invite"):
			_fail("the team invite did not go out")
			return false
	else:
		if not await _until(func() -> bool: return cloud.has_invite(), 30.0):
			_fail("the team invite never came")
			return false
		var inv := cloud.invite_from()
		if inv.get("team", {}) != {"size": 2, "coop": true} or String(inv.id) != other:
			_fail("the invite is not the host's DUO team invite: %s" % str(inv))
		_link(2, true, other, cloud.my_id)
		var accept: Button = null
		if await _until(func() -> bool: return get_tree().current_scene.find_child("AcceptButton", true, false) != null, 5.0):
			accept = get_tree().current_scene.find_child("AcceptButton", true, false) as Button
		if accept:
			accept.pressed.emit()
		else:
			at.log_line("no popup with ACCEPT: answering directly")
			cloud.answer(true)
	if not await _until(func() -> bool: return _started, 30.0):
		_fail("the team invite never started a session")
		return false
	if cloud.session_team != {"size": 2, "coop": true}:
		_fail("session_team is %s" % str(cloud.session_team))
	var arena := await _arena()
	if arena == null:
		return false
	at.log_line("coop DUO up: host %s, my slot %d, slots %d" % [arena.am_host, arena.my_slot, arena.slots.size()])
	var guest_f := arena.slot_fighter(1)
	var host_f := arena.slot_fighter(0)
	var foes := arena.members(1)
	if arena.slots.size() != 4 or foes.size() != 2 or not (guest_f is RemoteFighter if host else host_f is RemoteFighter) \
			or not (foes[0] is RemoteFighter) == (not host):
		_fail("the coop roster is wrong on this phone")
	if arena.online != true:
		_fail("the team arena is not online")
	# The bots stand still: the check moves the match on, step by step.
	if host:
		for b in foes:
			b.frozen = true
			b.hold_fire = true
	await at.wait(1.0)
	# An enemy bot's real hits on the guest's player (on the host, through its RemoteFighter).
	if host:
		var shooter := foes[0]
		var d: Dictionary = shooter.gun().def
		var hit := float(d.damage) * Weapons.zone_mult(d, "head", 0.0) * Weapons.pen_mult(d, "head")
		for _i in 30:
			if guest_f.knocked or not guest_f.alive:
				break
			guest_f.take_damage(hit, "head", shooter, shooter.global_position)
			await at.wait(maxf(float(d.interval), 0.15))
	if not await _until(func() -> bool: return guest_f.knocked, 15.0):
		_fail("the guest's player was never knocked here (%s)" % ("host" if host else "guest"))
		return false
	at.log_line("the guest's player is KNOCKED on this phone (alive %s)" % guest_f.alive)
	if not guest_f.alive:
		_fail("a knock with a teammate UP put the guest's player out")
	# The host's player revives it.
	if host:
		var p := arena.player
		var away := p.global_position - guest_f.global_position
		away.y = 0.0
		p.global_position = guest_f.global_position + (away.normalized() if away.length() > 0.1 else Vector3.RIGHT) * 1.0 + Vector3.UP * 0.2
		await at.wait(0.6)
		if not arena.start_revive(p, guest_f):
			_fail("the host's player could not start the revive (%.1f m)" % p.global_position.distance_to(guest_f.global_position))
	else:
		if not await _until(func() -> bool: return arena.revive_progress(guest_f) >= 0.0, 10.0):
			_fail("the guest never saw the revive start (BEING REVIVED)")
	if not await _until(func() -> bool: return guest_f.alive and not guest_f.knocked, 15.0):
		_fail("the guest's player was never revived here")
		return false
	at.log_line("revived: the guest's player is UP with %.0f HP here" % guest_f.hp)
	# The host's player puts both enemy bots out (knocked first, then finished: the last one wipes).
	if host:
		var p := arena.player
		var d: Dictionary = p.gun().def
		var hit := float(d.damage) * Weapons.zone_mult(d, "head", 0.0) * Weapons.pen_mult(d, "head")
		for b in foes:
			for _i in 40:
				if not b.alive:
					break
				b.take_damage(hit, "head", p, p.global_position)
				await at.wait(0.12)
	if not await _until(func() -> bool: return arena._result_shown, 30.0):
		_fail("the match did not end with results")
		return false
	var won := arena._winner == arena.player
	at.log_line("coop result: won %s, score %d - %d, rounds %d" % [won, arena.team_score[0], arena.team_score[1], arena.round_index])
	if not won or int(arena.team_score[0]) != 1 or int(arena.team_score[1]) != 0:
		_fail("the coop match should be won 1 - 0 on both")
	for f in arena.slots:
		if not arena.runs_here(f) and not arena.final_stats.has(f.slot):
			_fail("no \"fin\" came for slot %d" % f.slot)
	var table := _table(arena)
	at.log_line("table: " + table)
	await at.wait(1.0)                   # (both phones stopped sending states at the match's end)
	# Each copy's table, and the states it sent and took through the relay: the step compares the
	# tables and wants every state one copy sent taken by the other (a lossless mock: 100%).
	var out := OS.get_environment("LW_TEAM_OUT")
	if out != "":
		for pair: Array in [[out, table], [out + ".st", "%d %d" % [cloud.relay_states_out, cloud.relay_states_in]]]:
			var file := FileAccess.open(String(pair[0]), FileAccess.WRITE)
			if file:
				file.store_string(String(pair[1]) + "\n")
				file.close()
	at.log_line("relay states: sent %d, taken %d" % [cloud.relay_states_out, cloud.relay_states_in])
	var hist: Array = Game.profile.get("history", [])
	if hist.size() != _history_before + 1 or String((hist[0] as Dictionary).get("result", "")) != "won":
		_fail("HISTORY does not keep the won match (%d entries, %d before)" % [hist.size(), _history_before])
	else:
		at.log_line("HISTORY: %s" % str(hist[0]).left(200))
	await _play_again_together(arena)
	Game.goto_lobby()
	return true


# ---------------------------------------------------------------- a2. PLAY AGAIN TOGETHER

## Both copies tap PLAY AGAIN TOGETHER on the co-op results (each once its own results are up: no
## copy needs to be first). The second match must load from the results alone (no _link here: the
## results build Game.team_match from the new session), with the same two humans on the same side
## and the old host hosting; it is played to its results like the first, and HISTORY then keeps
## two co-op matches.
func _play_again_together(first: TeamArenaNet) -> void:
	_started = false
	var layer: Node = first.pause_layer
	if not await _until(func() -> bool: return layer.find_child("PlayAgainTogether", true, false) != null, 15.0):
		_fail("the co-op results have no PLAY AGAIN TOGETHER")
		return
	var again := layer.find_child("PlayAgainTogether", true, false) as Button
	var status := layer.find_child("RematchStatus", true, false) as Label
	if layer.find_child("PlayAgain", true, false) != null or layer.find_child("Rematch", true, false) != null \
			or layer.find_child("AddFriend", true, false) != null:
		_fail("the co-op results still offer PLAY AGAIN, REMATCH or ADD FRIEND")
	if again.disabled:
		_fail("PLAY AGAIN TOGETHER is off on the co-op results")
	again.pressed.emit()
	at.log_line("PLAY AGAIN TOGETHER tapped: \"%s\" / \"%s\"" % [again.text, status.text])
	var old := first.get_instance_id()
	var fresh := func() -> bool:
		var sc := get_tree().current_scene
		return sc is TeamArenaNet and sc.get_instance_id() != old
	if not await _until(fresh, 45.0):
		_fail("PLAY AGAIN TOGETHER never loaded a second match (\"%s\")" % (status.text if is_instance_valid(status) else "?"))
		return
	if not _started:
		_fail("the second match did not come from a new session")
	var arena := get_tree().current_scene as TeamArenaNet
	await at.wait_for_phase(arena, 1, 60.0)
	if arena.phase != 1:
		_fail("the second co-op match never reached FIGHT")
		return
	var mate := arena.slot_fighter(1 if host else 0)
	at.log_line("second co-op DUO up: host %s, my slot %d, slots %d, session_team %s" % [arena.am_host, arena.my_slot, arena.slots.size(),
		str(Game.session.session_team)])
	if arena.am_host != host or arena.my_slot != (0 if host else 1) or not arena.coop or arena.slots.size() != 4 \
			or not (mate is RemoteFighter) or mate.team != arena.player.team or arena.player.team != 0 or arena.members(1).size() != 2 \
			or Game.session.session_team != {"size": 2, "coop": true} or not bool(Game.team_match.get("online", false)):
		_fail("the second co-op match does not have the same roster sides and roles")
	var foes := arena.members(1)
	if host:
		for b in foes:
			b.frozen = true
			b.hold_fire = true
		await at.wait(1.0)
		var p := arena.player
		var d: Dictionary = p.gun().def
		var hit := float(d.damage) * Weapons.zone_mult(d, "head", 0.0) * Weapons.pen_mult(d, "head")
		for b in foes:
			for _i in 40:
				if not b.alive:
					break
				b.take_damage(hit, "head", p, p.global_position)
				await at.wait(0.12)
	if not await _until(func() -> bool: return arena._result_shown, 40.0):
		_fail("the second co-op match did not end with results")
		return
	var won := arena._winner == arena.player
	at.log_line("second coop result: won %s, score %d - %d" % [won, arena.team_score[0], arena.team_score[1]])
	if not won or int(arena.team_score[0]) != 1 or int(arena.team_score[1]) != 0:
		_fail("the second co-op match should be won 1 - 0 on both")
	var hist: Array = Game.profile.get("history", [])
	var coop_rows := 0
	for i in mini(hist.size(), 2):
		var h: Dictionary = hist[i]
		if String(h.get("result", "")) == "won" and int(h.get("size", 0)) == 2 and String(h.get("with", "")) != "":    # (WITH the teammate)
			coop_rows += 1
	at.log_line("HISTORY after PLAY AGAIN TOGETHER: %d entries (%d before), %d co-op rows on top" % [hist.size(), _history_before, coop_rows])
	if hist.size() != _history_before + 2 or coop_rows != 2:
		_fail("HISTORY does not keep the two co-op matches")
	await at.wait(1.0)                   # (the other copy checks its results too before both go back)


## The results table as both phones must show it: each row's numbers by slot.
func _table(arena: TeamArenaNet) -> String:
	var rows: Array = arena.result.get("rows", arena.scoreboard_rows())
	var parts := []
	for s in arena.slots.size():
		for r: Dictionary in rows:
			if int(r.get("slot", -1)) == s:
				parts.append("%d:%s k%d kn%d rv%d d%d hs%d a%d" % [s, String(r.name), int(r.kills), int(r.get("knocks", 0)),
					int(r.get("revives", 0)), int(r.damage), int(r.headshots), int(r.accuracy)])
	return " | ".join(parts)


# ---------------------------------------------------------------- d. the host leaves a coop match

func _host_quits() -> void:
	_started = false
	_history_before = (Game.profile.get("history", []) as Array).size()
	Game.match_notice = []
	if host:
		_link(2, true, cloud.my_id, other)
		if not await _invite_until_taken(func() -> bool: return cloud.team_invite(other, 2, true), "second team invite"):
			_fail("the second team invite did not go out")
			return
	elif await _until(func() -> bool: return cloud.has_invite(), 20.0):
		_link(2, true, other, cloud.my_id)
		cloud.answer(true)
	if not await _until(func() -> bool: return _started, 25.0):
		_fail("the second team invite never started a session")
		return
	var arena := await _arena()
	if arena == null:
		return
	await at.wait(1.5)
	if host:
		arena.record_left()              # QUIT MATCH
		Game.goto_lobby()
		return
	if not await _until(func() -> bool: return arena._called_off, 15.0):
		_fail("the guest's match went on after the host left")
		return
	var notice: Array = Game.match_notice.duplicate()          # (the lobby shows it and clears it)
	if not await _until(func() -> bool: return get_tree().current_scene is Lobby, 20.0):
		_fail("the guest never went back to the lobby when the host left")
		return
	var hist: Array = Game.profile.get("history", [])
	at.log_line("the host left: notice %s, HISTORY %s" % [str(notice), str(hist[0]).left(120) if not hist.is_empty() else "empty"])
	if notice.is_empty() or String(notice[0]) != "THE HOST LEFT":
		_fail("the guest was not told THE HOST LEFT")
	var want := "ended" if "ended" in Game.HISTORY_RESULTS else "lost"     # (builds before the team records: no win)
	if hist.size() != _history_before + 1 or String((hist[0] as Dictionary).get("result", "")) != want:
		_fail("the match the host left is not kept as %s" % want.to_upper())


# ---------------------------------------------------------------- b. random DUO (team search)

func _random_duo() -> void:
	_started = false
	var saw_me := [false]
	var on_seek := func(id: String, saw: Array) -> void:
		if id == other and saw.has(cloud.my_id):
			saw_me[0] = true
	cloud.seeker_seen.connect(on_seek)
	var host_id := cloud.my_id if cloud.my_id < other else other
	host = host_id == cloud.my_id        # (the lower id challenges and hosts)
	_link(2, false, host_id, cloud.my_id if not host else other)
	cloud.team_seek_start(2)
	var t := 0.0
	var invited := false
	while not _started and t < 30.0:
		if int(t * 4.0) % 4 == 0:
			cloud.send_seek(cloud.quick_seen.keys())
		if host and saw_me[0] and not invited:
			invited = cloud.team_invite(other, 2, false, true)
		await at.wait(0.25)
		t += 0.25
	cloud.seeker_seen.disconnect(on_seek)
	cloud.team_seek_stop()
	if not _started:
		_fail("the two DUO searches never paired")
		return
	if cloud.is_host != host or cloud.session_team != {"size": 2, "coop": false}:
		_fail("wrong pairing: host %s, session_team %s" % [cloud.is_host, str(cloud.session_team)])
	var arena := await _arena()
	if arena == null:
		return
	var mine := arena.player
	mine.invulnerable = true             # (nobody may end the round here: the bots move, never shoot)
	if host:
		for s in arena.bot_slots():
			arena.slot_fighter(s).hold_fire = true
	at.log_line("random DUO up: host %s, my slot %d (team %d)" % [arena.am_host, arena.my_slot, mine.team])
	var bots := []
	for s in arena.bot_slots():
		bots.append(arena.slot_fighter(s))
	if bots.size() != 2 or arena.slot_fighter(2) == null or (arena.slot_fighter(2) == mine) == host:
		_fail("the DUO roster is wrong (the guest is slot 2)")
	var hit_from_guest := [false]
	if host:
		var target := arena.slot_fighter(1)
		target.damaged.connect(func(_a: float, _p: Vector3, _h: bool, by: Fighter) -> void:
			if by == arena.slot_fighter(2):
				hit_from_guest[0] = true)
	else:
		# The host's bots move here (their states come in the host's "tk").
		var start := []
		for b: Fighter in bots:
			start.append(b.global_position)
		await at.wait(3.0)
		var moved := 0.0
		for i in bots.size():
			moved = maxf(moved, (bots[i] as Fighter).global_position.distance_to(start[i]))
		at.log_line("the host's bots moved up to %.1f m here in 3 s" % moved)
		if moved < 0.3 or not (bots[0] is RemoteFighter):
			_fail("the host's bots do not move on the guest")
		# A hit on the host's bot of the other team (slot 1): applied on the host.
		var target := arena.slot_fighter(1)
		target.take_damage(8.0, "body", mine, mine.global_position)
	if host:
		if not await _until(func() -> bool: return hit_from_guest[0], 10.0):
			_fail("the guest's hit on a host bot never landed on the host")
		else:
			at.log_line("the guest's hit landed on the host's bot")
	# The guest's pause menu: the match keeps running there; the host never hears it go quiet.
	var heard := [true]
	var on_end := func(_r: String) -> void: heard[0] = false
	cloud.session_ended.connect(on_end)
	if not host:
		await at.wait(1.0)
		var e0 := arena.elapsed
		arena.open_pause()
		await at.wait(3.0)
		if get_tree().paused or arena.elapsed - e0 < 2.0:
			_fail("the pause menu paused the online team match (tree paused %s, %.1f s ran)" % [get_tree().paused, arena.elapsed - e0])
		else:
			at.log_line("under the pause menu the match ran %.1f s" % (arena.elapsed - e0))
		arena.close_pause()
		await at.wait(1.0)
		# QUIT MATCH: LEFT here, the host wins by forfeit.
		arena.record_left()
		Game.goto_lobby()
		if not await _until(func() -> bool: return get_tree().current_scene is Lobby, 20.0):
			_fail("QUIT MATCH never went back to the lobby")
		var hist: Array = Game.profile.get("history", [])
		if hist.is_empty() or not bool((hist[0] as Dictionary).get("left", false)) and String((hist[0] as Dictionary).get("result", "")) != "left":
			at.log_line("HISTORY after the quit: %s" % (str(hist[0]).left(160) if not hist.is_empty() else "empty"))
	else:
		await at.wait(4.0)
		if not heard[0]:
			_fail("the host heard the guest go quiet under its pause menu")
		if not await _until(func() -> bool: return arena._result_shown, 25.0):
			_fail("the guest's quit gave the host no result")
		else:
			at.log_line("after the guest quit: won %s, forfeit %s" % [arena._winner == arena.player, arena._forfeit])
			if arena._winner != arena.player or not arena._forfeit:
				_fail("the host should win by forfeit")
			var layer: Node = arena.pause_layer
			if await _until(func() -> bool: return layer.find_child("Lobby", true, false) != null, 10.0):
				if layer.find_child("Rematch", true, false) != null or layer.find_child("PlayAgainTogether", true, false) != null:
					_fail("the results after a forfeit offer a REMATCH")
				else:
					at.log_line("after the forfeit the results offer no REMATCH (ADD FRIEND %s)" % (layer.find_child("AddFriend", true, false) != null))
		Game.goto_lobby()
	cloud.session_ended.disconnect(on_end)


# ---------------------------------------------------------------- c. a plain duel after them

func _duel() -> void:
	_started = false
	Game.team_match = {}                 # (the lobby clears it for every duel)
	await at.wait(1.0)
	if host:
		if not await _invite_until_taken(func() -> bool: return cloud.invite(other), "duel challenge"):
			_fail("the duel challenge did not go out")
			return
	elif await _until(func() -> bool: return cloud.has_invite(), 20.0):
		if not (cloud.invite_from().get("team", {}) as Dictionary).is_empty():
			_fail("a duel challenge reads as a team invite")
		cloud.answer(true)
	if not await _until(func() -> bool: return _started, 25.0):
		_fail("the duel never started")
		return
	if not cloud.session_team.is_empty():
		_fail("a duel's session has a team: %s" % str(cloud.session_team))
	if not await _until(func() -> bool: return get_tree().current_scene != null and get_tree().current_scene.name == "Arena", 30.0):
		_fail("the duel never loaded")
		return
	var arena: Node = get_tree().current_scene
	if arena is TeamArena or arena.scene_file_path != "res://scenes/arena.tscn":
		_fail("the duel loaded %s" % arena.scene_file_path)
	await at.wait_for_phase(arena, 1, 40.0)
	if arena.get("phase") != 1 or not (arena.get("bot") is RemoteFighter):
		_fail("the duel is not the 1 vs 1 against the other phone (phase %s, opponent %s)" % [str(arena.get("phase")), str(arena.get("bot"))])
	else:
		at.log_line("the duel after the team matches is the 1 vs 1 (arena.tscn)")
	if host:
		await at.wait(6.0)               # (the duel stays up while the guest, a little behind, checks it too)


## Sends an invite (send: a Callable that returns whether it went out) until the other copy takes
## it: a copy still on its results (no lobby listening) or one that has not yet made this one its
## friend declines at once, as a phone does, so a declined invite goes out again (up to 8 times).
func _invite_until_taken(send: Callable, what: String) -> bool:
	var declined := [false]
	var on_answer := func(accepted: bool, _who: String) -> void:
		if not accepted:
			declined[0] = true
	cloud.invite_answered.connect(on_answer)
	var sent := false
	for attempt in 8:
		declined[0] = false
		if not send.call():
			break
		sent = true
		await _until(func() -> bool: return _started or declined[0], 10.0)
		if not declined[0]:
			break
		at.log_line("%s %d declined (the other copy is not ready for it yet): again" % [what, attempt + 1])
		await at.wait(1.5)
	cloud.invite_answered.disconnect(on_answer)
	return sent


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
	at.log_line("TEAM ONLINE CHECK DONE bad=%d" % bad)
	return bad
