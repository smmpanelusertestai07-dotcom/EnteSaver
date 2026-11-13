extends Node
## Voice end to end between two copies (LW_NET_ROLE host / guest) through tests/mqtt_mock.gd
## (tools/qa/run_checks.sh step "voice", LW_VOICE_TONE=1: NetVoice.tone_source, a generated tone,
## stands in for the microphone; there is none on a test machine). The host talks, the guest
## listens (its MIC OFF, its SPEAKER on ALL, the default):
##  a. 1 vs 1 (the host's duel challenge, the guest accepts; the lobby loads the arena): the host's
##     MIC ALL reaches the guest (frames taken by its Cloud and pushed into the host's generator on
##     the guest's NetVoice, the host shown as speaking); the host's MIC GROUP sends nothing (a 1 vs 1
##     has no teammates) and the guest hears nothing more. The host leaves; both go to the lobby.
##  b. CUSTOM ROOM (DUO, waiting): the guest joins with the code and password (on the other side):
##     the room's group carries the voice (its own voice topic): ALL reaches the guest; GROUP does
##     not (an enemy); once the guest takes a place on the host's side, GROUP reaches it. With PUSH
##     TO TALK the host sends nothing until the lobby's TALK (beside the pill) is held, then sends.
##  c. the room's DUO match (the guest back on the other side, the host's START: an all-human match
##     over the match room): ALL reaches the guest, GROUP ("vg") does not reach the enemy.
## Prints "VOICE CHECK DONE bad=N".

const CODE := "424242"
const PIN := "7788"

var bad := 0
var at: Node
var host := false
var cloud: Cloud
var other := ""
var heard := 0                   # frames from the other copy that this Cloud passed on (voice_from)


func run(autotest: Node) -> int:
	at = autotest
	host = OS.get_environment("LW_NET_ROLE") == "host"
	if not NetVoice.tone_source:
		return _done("LW_VOICE_TONE=1 is needed (the tone stands in for the microphone)")
	Game.settings.speaker_mode = NetVoice.ALL
	Game.settings.mic_mode = NetVoice.OFF
	Game.settings.push_to_talk = false
	cloud = Game.cloud_service()
	cloud.start_lobby()
	cloud.voice_from.connect(func(_f: PackedByteArray, id: String, _mate: bool) -> void:
		if id == other:
			heard += 1)
	var started := [false]
	cloud.session_started.connect(func(_h: bool) -> void: started[0] = true)
	if not host:
		cloud.invited.connect(func(_who: String) -> void: cloud.answer(true))
	if not await _until(func() -> bool: return cloud.status == "online" and not cloud.peers.is_empty(), 30.0):
		return _done("the other copy was never seen in the lobby")
	other = String(cloud.peers.keys()[0])
	var hub := NetVoice.hub()
	# a. The 1 vs 1.
	if host and not cloud.invite(other):
		return _done("the duel challenge was not sent")
	if not await _until(func() -> bool: return started[0], 40.0):
		return _done("no 1 vs 1 session")
	at.log_line("1 vs 1 up, channel %s" % NetVoice.channel())
	if host:
		hub.set_mic_mode(NetVoice.ALL)
		await at.wait(8.0)
		at.log_line("host sent %d frames with MIC ALL" % hub.frames_sent)
		if hub.frames_sent < 20:
			_fail("the host's open mic sent only %d frames in 8 s (the tone speaks 1 s of every 1.6)" % hub.frames_sent)
		var sent := hub.frames_sent
		hub.set_mic_mode(NetVoice.GROUP)
		await at.wait(8.0)
		if hub.frames_sent != sent or hub.capturing:
			_fail("MIC GROUP in a 1 vs 1 still sent %d frames (no teammates: nothing goes out)" % (hub.frames_sent - sent))
		cloud.end_session("left")
	else:
		if not await _until(func() -> bool: return heard >= 10 and hub.frames_heard >= 10, 12.0):
			_fail("the 1 vs 1 opponent's voice did not come through (taken %d, played %d)" % [heard, hub.frames_heard])
		if not hub._talkers.has(other):
			_fail("the host has no player of its own on the guest")
		at.log_line("guest: 1 vs 1 voice taken %d, pushed to the generator %d, speaking %s" % [heard, hub.frames_heard, NetVoice.speaking(other)])
		if not await _quiet(14.0):
			_fail("the host's MIC GROUP still reached its 1 vs 1 opponent")
		await _until(func() -> bool: return not cloud.in_session, 15.0)
	await _until(func() -> bool: return not cloud.in_session, 10.0)
	hub.set_mic_mode(NetVoice.OFF)
	Game.goto_lobby()
	await at.wait(2.0)
	# b. The custom room (DUO), waiting.
	if host:
		cloud.open_room(PIN, {"rounds": 1}, CODE, 2)
		if not await _until(func() -> bool: return cloud.voice_group_ready(), 40.0):
			return _done("the guest never got into the room")
		hub.set_mic_mode(NetVoice.ALL)
		await at.wait(8.0)
		var sent := hub.frames_sent
		at.log_line("host: room ALL sent %d frames" % sent)
		if sent < 20:
			_fail("the open mic sent only %d frames to the room" % sent)
		# PUSH TO TALK in the room: nothing until the lobby's TALK (beside the pill) is held.
		hub.set_push_to_talk(true)
		await at.wait(0.3)
		sent = hub.frames_sent           # (the open mic's last words went as it stopped)
		var talk := at.get_tree().root.find_child("LobbyTalk", true, false) as Button
		await at.wait(2.0)
		if talk == null or not talk.is_visible_in_tree():
			_fail("no TALK beside the lobby's pill with PUSH TO TALK in a room")
		if hub.frames_sent != sent or hub.capturing:
			_fail("PUSH TO TALK sent %d frames to the room with TALK not held" % (hub.frames_sent - sent))
		if talk != null:
			talk.button_down.emit()
			await at.wait(3.0)
			talk.button_up.emit()
			at.log_line("host: TALK held 3 s in the room sent %d frames" % (hub.frames_sent - sent))
			if hub.frames_sent - sent < 15:
				_fail("TALK held 3 s in the room sent only %d frames" % (hub.frames_sent - sent))
			await at.wait(0.5)
			if hub.ptt_held or hub.capturing:
				_fail("the microphone still ran after TALK was let go")
		hub.set_push_to_talk(false)
		hub.set_mic_mode(NetVoice.GROUP)
		await at.wait(2.0)
		if hub.capturing:
			_fail("MIC GROUP ran with nobody on the host's side")
		# the guest takes the host's side: GROUP now reaches it
		if not await _until(func() -> bool: return cloud.voice_mates() == 1, 30.0):
			return _done("the guest never came to the host's side")
		await at.wait(8.0)
		hub.set_mic_mode(NetVoice.OFF)
		# the guest goes back to the other side; START
		if not await _until(func() -> bool: return cloud.voice_mates() == 0 and NetGroup.plan(cloud.group.members, 2) == "match", 30.0):
			return _done("the guest never went back to the other side")
		var why := cloud.room_start()
		if why != "":
			return _done("the room's START: %s" % why)
	else:
		await at.wait(1.0)
		cloud.join_room(CODE, PIN)
		if not await _until(func() -> bool: return cloud.voice_group_ready(), 40.0):
			return _done("the guest never got into the room (%s)" % cloud.join_state)
		heard = 0
		var played := hub.frames_heard
		if not await _until(func() -> bool: return heard >= 10 and hub.frames_heard - played >= 10, 15.0):
			_fail("the room's voice did not come through (taken %d, played %d)" % [heard, hub.frames_heard - played])
		at.log_line("guest: room voice taken %d, played %d" % [heard, hub.frames_heard - played])
		if not await _quiet(22.0):           # (the host's ALL, then TALK held, then GROUP)
			_fail("the host's MIC GROUP reached the other side of the room")
		var host_side := -1
		for m: Dictionary in cloud.group_members():
			if bool(m.leader):
				host_side = int(m.team)
		var mine := -1
		for m: Dictionary in cloud.group_members():
			if bool(m.me):
				mine = int(m.team)
		if not cloud.room_take(host_side, 1):
			_fail("the guest could not take the host's side")
		heard = 0
		if not await _until(func() -> bool: return heard >= 10, 15.0):
			_fail("GROUP did not reach the host's teammate in the room (%d)" % heard)
		at.log_line("guest: on the host's side, GROUP frames %d" % heard)
		await at.wait(3.0)
		if not cloud.room_take(mine, 0):
			_fail("the guest could not go back to its side")
	# c. The room's DUO match.
	if not await _until(func() -> bool: return cloud.in_session and cloud.session_multi, 40.0):
		return _done("the room's DUO match never started")
	at.log_line("DUO match up, channel %s, mates %d" % [NetVoice.channel(), cloud.voice_mates()])
	if host:
		hub.set_mic_mode(NetVoice.ALL)
		await at.wait(8.0)
		var sent := hub.frames_sent
		hub.set_mic_mode(NetVoice.GROUP)
		await at.wait(8.0)
		if hub.frames_sent != sent:
			_fail("MIC GROUP with no teammate in the match still sent %d frames" % (hub.frames_sent - sent))
		hub.set_mic_mode(NetVoice.OFF)
		cloud.end_session("left")
	else:
		heard = 0
		var played := hub.frames_heard
		if not await _until(func() -> bool: return heard >= 10 and hub.frames_heard - played >= 10, 15.0):
			_fail("the DUO match's voice did not come through (taken %d, played %d)" % [heard, hub.frames_heard - played])
		at.log_line("guest: DUO match voice taken %d, played %d" % [heard, hub.frames_heard - played])
		if not await _quiet(10.0):
			_fail("the host's MIC GROUP reached the enemy in the DUO match")
		await _until(func() -> bool: return not cloud.in_session, 15.0)
	return _done("")


## The guest: frames stop coming (the host switched to GROUP) within `seconds`, then none for 4 s.
func _quiet(seconds: float) -> bool:
	var last := heard
	var still := 0.0
	var t := 0.0
	while t < seconds and still < 2.5:
		await at.wait(0.25)
		t += 0.25
		if heard == last:
			still += 0.25
		else:
			still = 0.0
			last = heard
	if still < 2.5:
		return false
	var n := heard
	await at.wait(4.0)
	return heard == n


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
	at.log_line("VOICE CHECK DONE bad=%d" % bad)
	return bad
