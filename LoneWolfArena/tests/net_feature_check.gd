extends RefCounted
## Unit tests of the online extras (run from tests/run_tests.gd, which counts the checks):
## the ping (NetPing rules, the relay's PINGRESP and the room ping timed), the match state (short
## numbers, repeats skipped, NetSmoother drawing it in the past and bridging gaps), chat (NetChat's
## text rules, the match line's rate and settings, a friend's message sealed, opened, tampered and
## replayed, only from friends), card v3 (the career summary signed, hidden, malformed, older
## builds' check still passing), the voice codec (NetVoice), the ONLINE settings tab, who can reach
## you (DUEL CHALLENGES FROM, FRIEND REQUESTS: settings and Cloud), the lobby's notice helpers and
## the SOUND tab's volumes (VOICE CHAT on its own bus, every slider heard at once).

var t: Node


## A Cloud that keeps what it would publish ([topic, payload, retain]) instead of sending it.
class RecordingCloud extends Cloud:
	var sent := []

	func _publish(topic: String, payload: PackedByteArray, retain := false) -> void:
		sent.append([topic, payload, retain])


static func run(runner: Node) -> void:
	var me := new()
	me.t = runner
	var saved_at := Game.autotest
	var saved_profile := Game.profile.duplicate(true)
	var saved_settings := Game.settings.duplicate(true)
	Game.autotest = "unit"                  # nothing is saved
	NetChat.reset_for_test()
	me._ping()
	me._state()
	me._smoother()
	me._chat_text()
	me._match_chat()
	me._friend_chat()
	me._card_v3()
	me._voice()
	me._settings()
	me._reach()
	me._notices()
	me._chat_cutout()
	me._volumes()
	NetChat.reset_for_test()
	Game.profile = saved_profile
	Game.settings = saved_settings
	Game.autotest = saved_at


func _check(cond: bool, what: String) -> void:
	t._check(cond, what)


## Two Cloud services that share a match room's keys: a's messages are b's opponent's.
func _pair() -> Array:
	var a := Cloud.new()
	var b := Cloud.new()
	var aes := Crypto.new().generate_random_bytes(32)
	var mac := Crypto.new().generate_random_bytes(32)
	a.my_id = "a".repeat(32)
	b.my_id = "b".repeat(32)
	for c: Cloud in [a, b]:
		c._aes = aes
		c._mac = mac
		c.in_session = true
	a.opponent = {"id": b.my_id, "name": "BEE"}
	b.opponent = {"id": a.my_id, "name": "ACE"}
	return [a, b]


func _ping() -> void:
	_check(NetPing.color(99) == NetPing.GREEN and NetPing.color(100) == NetPing.YELLOW and NetPing.color(199) == NetPing.YELLOW
		and NetPing.color(200) == NetPing.RED and NetPing.color(-1) == NetPing.GREY, "ping colours: green < 100, yellow < 200, red, grey offline")
	_check(NetPing.bars(40) == 4 and NetPing.bars(150) == 3 and NetPing.bars(250) == 2 and NetPing.bars(400) == 1 and NetPing.bars(-1) == 0,
		"signal bars: 4, 3, 2, 1 and none offline")
	_check(NetPing.label(87) == "87 ms" and NetPing.label(-1) == "-- ms" and NetPing.label(123456) == "9999 ms", "the ping's text")
	_check(NetPing.smooth(-1, 180) == 180 and NetPing.smooth(180, 220) == 200 and NetPing.smooth(200, -1) == 200
		and NetPing.smooth(-1, 50000) == NetPing.MAX_MS, "a sample: the first as it is, then averaged; none ignored; capped")
	_check(NetPing.match_ms(140, 230, true) == 140 and NetPing.match_ms(-1, 230, true) == 230 and NetPing.match_ms(140, 230, false) == -1,
		"the match shows the opponent's round trip, the relay's before the first answer, nothing offline")
	# The relay: the time from the PINGREQ to its PINGRESP.
	var cl := Cloud.new()
	cl._pingreq_ms = Time.get_ticks_msec() - 120
	cl._rx = PackedByteArray([0xD0, 0x00])
	cl._parse()
	_check(cl.relay_rtt >= 120 and cl.relay_rtt < 160 and cl._pingreq_ms == 0, "a PINGRESP times the relay's round trip (%d ms)" % cl.relay_rtt)
	cl._rx = PackedByteArray([0xD0, 0x00])
	cl._parse()
	_check(cl.relay_rtt >= 120 and cl.relay_rtt < 160, "a PINGRESP nobody asked for changes nothing")
	cl.free()
	# The opponent: a numbered room ping answered by the other phone.
	var p := _pair()
	var a: Cloud = p[0]
	var b: Cloud = p[1]
	b._peer_pings = {7: Time.get_ticks_msec() - 90}
	b._on_room(a._room_packet({"k": "po", "i": 7}))
	_check(b.peer_rtt >= 90 and b.peer_rtt < 130 and not b._peer_pings.has(7), "the room's pong times the round trip to the other phone (%d ms)" % b.peer_rtt)
	b._on_room(a._room_packet({"k": "po", "i": 8}))
	_check(b.peer_rtt >= 90 and b.peer_rtt < 130, "a pong for no ping changes nothing")
	b._pong_budget = 1.5
	b._on_room(a._room_packet({"k": "pi", "i": 0}))
	_check(is_equal_approx(b._pong_budget, 1.5), "a phone still loading its match does not answer pings (it may fall silent)")
	var listen := func(_k: String, _d: Array) -> void: pass
	b.event_received.connect(listen)
	b._on_room(a._room_packet({"k": "pi", "i": 1}))
	b._on_room(a._room_packet({"k": "pi", "i": 2}))
	_check(b._pong_budget >= 0.4 and b._pong_budget < 1.0, "a flood of pings is not answered in kind")
	b.end_session("left")
	_check(b.peer_rtt == -1, "a session's end forgets the opponent's round trip")
	a.free()
	b.free()


func _state() -> void:
	var s := PackedFloat32Array([12.345678, 1.0, -3.21987, 3.14159, -0.12345, 1.0, 9.0, 0.0, 173.25, 2.0])
	var c := Cloud.compact_state(s)
	_check(c[0] == 12.35 and c[1] is int and c[2] == -3.22 and c[3] == 3.142 and c[4] == -0.123 and c[5] is int and c[8] == 173.3
		and c[9] is int, "the state in short numbers: cm, mrad, tenths of HP, whole values as integers (%s)" % str(c))
	_check(JSON.stringify({"k": "st", "s": c, "t": 123456789}).length() < 80, "a state message stays short")
	var cl := Cloud.new()
	cl.in_session = true
	var sent := [cl.send_state(s)]
	cl._state_ms -= 50                  # (the next physics tick, 50 ms on)
	sent.append(cl.send_state(s))
	cl._state_ms -= 50
	sent.append(cl.send_state(s))
	_check(sent == [true, true, false], "a state like the last goes out once more, then is skipped (%s)" % str(sent))
	cl._state_ms -= Cloud.STATE_IDLE_MS + 10
	_check(cl.send_state(s), "an unchanged state still goes out every STATE_IDLE_MS")
	s[0] += 0.5
	cl._state_ms -= 50
	_check(cl.send_state(s), "a changed state goes out at once")
	# A slow frame runs physics steps back to back: a second state in the same millisecond would
	# carry the same "t", which the other phone throws away, so it never goes out.
	var out_before := cl.relay_states_out
	s[0] += 0.5
	cl._state_ms = Time.get_ticks_msec() + 1000        # (this millisecond, and the clock not yet past it)
	_check(not cl.send_state(s) and cl.relay_states_out == out_before, "no second state in the same millisecond")
	cl._state_ms -= 2000
	cl.in_session = false
	_check(not cl.send_state(s), "no state outside a match")
	# The arena's own limit on states (30 a second) still lets 20 a second through.
	_check(is_equal_approx(cl.state_interval, 0.05), "states go out 20 times a second")
	cl.free()


func _smoother() -> void:
	var sm := NetSmoother.new()
	_check(sm.sample(1000.0).is_empty(), "nothing to draw before the first state")
	# States every 50 ms of the sender's clock, arriving 200 ms later with up to 40 ms of jitter.
	var jitter := [0.0, 35.0, 5.0, 40.0, 10.0, 0.0, 25.0, 15.0]
	for i in 8:
		sm.push(Vector3(i * 0.5, 0, 0), 0.0, 0.0, 1000.0 + i * 50.0, 1200.0 + i * 50.0 + float(jitter[i]))
	# The quickest packets came 200 ms after they were sent: drawn 100 ms behind that.
	var at := sm.sample(1200.0 + 4 * 50.0 + 25.0 + NetSmoother.DELAY_MS)
	_check(absf((at.pos as Vector3).x - 2.25) < 0.02, "drawn between two states by the sender's clock, jitter or not (%s)" % str(at.pos))
	var gap := sm.sample(1200.0 + 7 * 50.0 + NetSmoother.DELAY_MS + 60.0)
	_check(absf((gap.pos as Vector3).x - (3.5 + 0.6)) < 0.02, "a short gap carries the movement on (%s)" % str(gap.pos))
	var long := sm.sample(1200.0 + 7 * 50.0 + NetSmoother.DELAY_MS + 2000.0)
	_check(absf((long.pos as Vector3).x - (3.5 + NetSmoother.EXTRAP_MS / 100.0)) < 0.02,
		"a long gap carries it on for EXTRAP_MS at most, then holds (%s)" % str(long.pos))
	var fall := NetSmoother.new()
	fall.push(Vector3(0, 2, 0), 0.0, 0.0, 0.0, 100.0)
	fall.push(Vector3(0, 1, 0), 0.0, 0.0, 50.0, 150.0)
	_check((fall.sample(150.0 + NetSmoother.DELAY_MS + 100.0).pos as Vector3).y >= 1.0, "a carried-on fall never sinks below the last height")
	var old := NetSmoother.new()
	old.push(Vector3(0, 0, 0), 0.0, 0.0, -1.0, 100.0)
	old.push(Vector3(1, 0, 0), 0.0, 0.0, -1.0, 200.0)
	_check(absf((old.sample(250.0).pos as Vector3).x - 0.5) < 0.01, "an older build's states (no clock) count at their arrival")
	var turn := NetSmoother.new()
	turn.push(Vector3.ZERO, 3.0, 0.0, 0.0, 0.0)
	turn.push(Vector3.ZERO, -3.0, 0.0, 100.0, 100.0)
	_check(absf(angle_difference(float(turn.sample(150.0).yaw), PI)) < 0.2, "a turn across the back is drawn the short way round")
	var back := NetSmoother.new()
	back.push(Vector3.ZERO, 0.0, 0.0, 100.0, 100.0)
	back.push(Vector3(1, 0, 0), 0.0, 0.0, 150.0, 150.0)
	back.push(Vector3(5, 0, 0), 0.0, 0.0, 20.0, 170.0)
	_check(back.size() == 1 and back.sample(400.0).pos == Vector3(5, 0, 0),
		"a clock that goes back starts over from the newest state: it cannot freeze the fighter")
	var future := NetSmoother.new()
	future.push(Vector3.ZERO, 0.0, 0.0, 1.0e12, 100.0)
	future.push(Vector3(2, 0, 0), 0.0, 0.0, 150.0, 150.0)
	_check((future.sample(400.0).pos as Vector3).x == 2.0, "a made-up clock far ahead does not hold the fighter back either")


func _chat_text() -> void:
	_check(NetChat.clean("gg, wp!!", 60) == "GG, WP!!" and NetChat.clean("  héllo \t\n  world ", 60) == "HELLO WORLD",
		"chat text: upper case, accents folded, one space")
	_check(NetChat.clean("hi <script>{x}; ☺ 你好 @all", 60) == "HI SCRIPTX ALL", "other characters are left out")
	_check(NetChat.clean("A".repeat(80), NetChat.MATCH_MAX).length() == 60 and NetChat.clean("wait?! (2) #1: ok/no + 'go'", 60)
		== "WAIT?! (2) #1: OK/NO + 'GO'", "basic punctuation stays, the length is capped")
	_check(NetChat.MAX_AGE_S == Cloud.REQUEST_MAX_AGE_S, "a waiting chat message ages like a friend request (the Privacy Notice)")
	_check(NetChat.QUICK.all(func(q: String) -> bool: return NetChat.clean(q, NetChat.MATCH_MAX) == q) and NetChat.QUICK.has("GG")
		and NetChat.QUICK.has("REMATCH?"), "the quick messages are clean chat text")
	_check(HudNet.wrap_words("ONE TWO THREE FOUR", 16, HudDraw.text_width("THREE FOUR", 16, "semi") + 1.0) == PackedStringArray(["ONE TWO", "THREE FOUR"]),
		"the feed wraps a long line by words")


func _match_chat() -> void:
	var p := _pair()
	var a: Cloud = p[0]
	var b: Cloud = p[1]
	var got := []
	b.chat_received.connect(func(x: String) -> void: got.append(x))
	Game.settings.chat = true
	for i in 3:
		b._on_room(a._room_packet({"k": "chat", "x": "nice shot %d" % i}))
	_check(got == ["NICE SHOT 0", "NICE SHOT 1"], "match chat: two lines at once, then at most one per %d s (%s)" % [int(NetChat.RATE_S), str(got)])
	b._chat_in = [2.0, Time.get_ticks_msec()]
	b._on_room(a._room_packet({"k": "chat", "x": "x".repeat(200)}))
	b._on_room(a._room_packet({"k": "chat", "x": 42}))
	_check(got.size() == 3 and String(got[2]).length() == NetChat.MATCH_MAX, "a long line is cut to %d characters, a non-text one dropped" % NetChat.MATCH_MAX)
	Game.settings.chat = false
	b._chat_in = [2.0, Time.get_ticks_msec()]
	b._on_room(a._room_packet({"k": "chat", "x": "hello"}))
	_check(got.size() == 3, "with CHAT off nothing is shown")
	Game.settings.chat = true
	var blocked: Array = (Game.profile.blocked as Array).duplicate(true)
	Game.profile.blocked.append({"id": a.my_id, "name": "", "t": 0})
	b._on_room(a._room_packet({"k": "chat", "x": "hello"}))
	_check(got.size() == 3, "a blocked player's chat is never shown")
	Game.profile.blocked = blocked
	_check(a.send_chat("gg") == "" and a.send_chat("again") == "WAIT" and a.send_chat("   ") == "EMPTY",
		"sending: one line per %d s, an empty line is not sent" % int(NetChat.RATE_S))
	a._chat_out_ms -= int(NetChat.RATE_S * 1000.0) + 10
	Game.settings.chat = false
	_check(a.send_chat("gg") == "OFF", "with CHAT off nothing is sent")
	Game.settings.chat = true
	a.free()
	b.free()


func _friend_chat() -> void:
	var ka := Crypto.new().generate_rsa(2048)
	var kb := Crypto.new().generate_rsa(2048)
	var pa := ka.save_to_string(true)
	var pb := kb.save_to_string(true)
	var ida := pa.sha256_text().left(32)
	var idb := pb.sha256_text().left(32)
	var now := int(Time.get_unix_time_from_system())
	var text := "SEE YOU AT 9? " + "X".repeat(86)
	var d := NetChat.seal(text, ida, idb, now, pb, ka, pa)
	_check(not d.is_empty() and text.length() == NetChat.FRIEND_MAX and not JSON.stringify(d).contains("SEE YOU"),
		"a %d-character message fits the friend's key and travels encrypted" % NetChat.FRIEND_MAX)
	_check(NetChat.open_message(d, ida, idb, kb, now, 0) == text, "the friend's phone opens it")
	_check(NetChat.open_message(d, ida, idb, ka, now, 0) == "" and NetChat.open_message(d, ida, ida, ka, now, 0) == "",
		"nobody else can read it, nor is it taken for one to another player")
	var changed := {"c": Marshalls.raw_to_base64(Crypto.new().encrypt(_pub(pb), "HACKED".to_utf8_buffer())), "ts": now - 5,
		"from": idb, "pk": pb, "sig": NetChat.seal("OTHER", ida, idb, now, pb, ka, pa).sig}
	for k: String in changed:
		var bad := d.duplicate()
		bad[k] = changed[k]
		_check(NetChat.open_message(bad, ida, idb, kb, now, 0) == "", "a message with a changed %s is rejected" % k)
	_check(NetChat.open_message(d, ida, idb, kb, now, now) == "" and NetChat.open_message(d, ida, idb, kb, now + NetChat.MAX_AGE_S + 1, 0) == "",
		"a message read already (or older) and one past its age are rejected")
	# Received by the service: friends only, never blocked, FRIENDS CHAT on; kept with its unread mark.
	var cl := Cloud.new()
	cl._use_key(kb)
	var heard := []
	cl.friend_chat_changed.connect(func(id: String) -> void: heard.append(id))
	Game.settings.friend_chat = true
	Game.profile.friends = {}
	cl._on_friend_chat(ida, d)
	_check(heard.is_empty() and NetChat.messages(ida).is_empty(), "a message from someone who is not a friend is dropped unread")
	Game.profile.friends = {ida: {"name": "ACE"}}
	cl._on_friend_chat(ida, d)
	_check(heard == [ida] and NetChat.messages(ida) == [[now, false, text]] and NetChat.unread(ida) == 1 and NetChat.cached_key(ida) == pa,
		"a friend's message is kept, marked unread, and their key remembered")
	cl._on_friend_chat(ida, d)
	_check(heard.size() == 1 and NetChat.messages(ida).size() == 1, "the same message again (a replay) is dropped")
	NetChat.mark_read(ida)
	_check(NetChat.unread(ida) == 0 and NetChat.unread_key() == "", "opening the chat marks it read")
	var d2 := NetChat.seal("TWO", ida, idb, now + 1, pb, ka, pa)
	Game.settings.friend_chat = false
	cl._on_friend_chat(ida, d2)
	Game.settings.friend_chat = true
	Game.profile.blocked = [{"id": ida, "name": "", "t": 0}]
	cl._on_friend_chat(ida, d2)
	_check(heard.size() == 1, "with FRIENDS CHAT off, or from a blocked friend, nothing comes in")
	Game.profile.blocked = []
	_check(cl.send_friend_chat(ida, "hi") == "OFFLINE" and cl.send_friend_chat("c".repeat(32), "hi") == "NOT A FRIEND",
		"sending needs the relay and a friend")
	for i in NetChat.HISTORY_MAX + 5:
		NetChat.add(ida, now + 10 + i, i % 2 == 0, "M%d" % i)
	_check(NetChat.messages(ida).size() == NetChat.HISTORY_MAX and String(NetChat.messages(ida)[-1][2]) == "M%d" % (NetChat.HISTORY_MAX + 4),
		"the last %d messages per friend are kept" % NetChat.HISTORY_MAX)
	cl.free()


func _pub(pem: String) -> CryptoKey:
	var k := CryptoKey.new()
	k.load_from_string(pem, true)
	return k


func _card_v3() -> void:
	var key := Crypto.new().generate_rsa(2048)
	var pk := key.save_to_string(true)
	var id := pk.sha256_text().left(32)
	var now := int(Time.get_unix_time_from_system())
	var career := {"matches": 40, "wins": 25, "kills": 120, "kd": 315, "hs": 27}
	var c := {"name": "SWIFTWOLF42", "bundle": "neon", "avatar": "royal", "banner": "hive", "level": 12, "signature": "GG", "career": career}
	var card: Dictionary = JSON.parse_string(Cloud.card_json(c, id, pk, now, key))
	_check(int(card.v) == 3 and card.has("sig3") and Cloud.verify_signed(pk, Cloud.card3_text(id, "SWIFTWOLF42", "neon", "royal", "hive", 12,
		"GG", "40,25,120,315,27", now), String(card.sig3)), "card v3: sig3 signs every field and the career summary")
	_check(Cloud.verify_signed(pk, Cloud.card2_text(id, "SWIFTWOLF42", "neon", "royal", "hive", 12, "GG", now), String(card.sig2))
		and Cloud.verify_signed(pk, Cloud.card_text(id, "SWIFTWOLF42", "neon", now), String(card.sig)),
		"a v3 card still carries the v2 and v1 signatures: older builds keep listing it")
	var cl := Cloud.new()
	cl._check_card(JSON.stringify(card).to_utf8_buffer())
	_check(cl.directory.has(id) and cl.directory[id].v == 3 and cl.directory[id].career == career, "a v3 card is listed with its career")
	for k: String in career:
		var bad := card.duplicate(true)
		bad.career[k] = int(career[k]) + 1
		cl.directory.clear()
		cl._check_card(JSON.stringify(bad).to_utf8_buffer())
		_check(not cl.directory.has(id), "a v3 card with a changed career %s is rejected" % k)
	var hidden := c.duplicate()
	hidden.career = {}
	cl.directory.clear()
	cl._check_card(Cloud.card_json(hidden, id, pk, now, key).to_utf8_buffer())
	_check(cl.directory.has(id) and (cl.directory[id].career as Dictionary).is_empty(), "a hidden career ({}) is listed as hidden")
	for bad_career: Variant in [{"matches": 1, "wins": 2, "kills": 0, "kd": -1, "hs": -1}, {"matches": 1, "wins": 0, "kills": 0, "kd": 0},
			{"matches": "1", "wins": 0, "kills": 0, "kd": 0, "hs": 0}, {"matches": 1, "wins": 0, "kills": 0, "kd": 0, "hs": 101}, [1, 2], null]:
		var bc := c.duplicate()
		bc.career = bad_career
		var signed: Dictionary = JSON.parse_string(Cloud.card_json(c, id, pk, now, key))
		signed.career = bad_career
		cl.directory.clear()
		cl._check_card(JSON.stringify(signed).to_utf8_buffer())
		_check(not cl.directory.has(id), "a malformed career is rejected (%s)" % str(bad_career))
	cl.free()
	_check(Cloud.career_summary({"matches": 10, "wins": 4, "kills": 10, "deaths": 4, "headshots": 3, "hits": 12})
		== {"matches": 10, "wins": 4, "kills": 10, "kd": 250, "hs": 25}, "the summary: K/D x 100 and headshots per hit in %")
	_check(Cloud.career_summary({"kills": 3}).kd == 300 and Cloud.career_summary({}).kd == -1 and Cloud.career_summary({}).hs == -1,
		"before the first death K/D is the kills; with no data it is unknown (-1)")
	Game.settings.show_career = false
	var off := Cloud.my_card()
	Game.settings.show_career = true
	var on := Cloud.my_card()
	_check((off.career as Dictionary).is_empty() and (on.career as Dictionary).size() == 5 and Cloud.card_key(off) != Cloud.card_key(on),
		"SHOW MY CAREER off publishes no career; turning it on changes the card")
	_check(LobbyNet.career_values({"matches": 40, "wins": 25, "kills": 120, "kd": 315, "hs": 27}, 12)
		== ["40", "25", "120", "3.15", "27%", "12"] and LobbyNet.career_values({"matches": 0, "wins": 0, "kills": 0, "kd": -1, "hs": -1}, 3)
		== ["0", "0", "0", "-", "-", "3"], "the CAREER block's values")


func _voice() -> void:
	var tone := PackedFloat32Array()
	for i in NetVoice.FRAME_SAMPLES:
		tone.append(0.5 * sin(TAU * 400.0 * i / NetVoice.RATE))
	var frame := NetVoice.encode(tone)
	_check(frame.size() == NetVoice.MAX_FRAME and NetVoice.frame_ok(frame) and Marshalls.raw_to_base64(frame).length() <= NetVoice.MAX_B64,
		"a 100 ms voice frame is %d bytes (4 bits a sample at 8 kHz)" % frame.size())
	var back := NetVoice.decode(frame)
	var sig := 0.0
	var err := 0.0
	for i in mini(back.size(), tone.size()):
		sig += tone[i] * tone[i]
		err += (tone[i] - back[i]) * (tone[i] - back[i])
	var snr := 10.0 * log(sig / maxf(err, 1e-9)) / log(10.0)
	_check(back.size() >= NetVoice.FRAME_SAMPLES and snr > 15.0, "the voice codec keeps the sound (SNR %.1f dB)" % snr)
	var bad := frame.duplicate()
	bad[0] = 2
	var big := frame.duplicate()
	big.append_array(PackedByteArray([0, 0]))
	var idx := frame.duplicate()
	idx[3] = 89
	_check(not NetVoice.frame_ok(bad) and not NetVoice.frame_ok(big) and not NetVoice.frame_ok(idx) and NetVoice.decode(bad).is_empty(),
		"a frame of another version, size or step index is not played")
	var p := _pair()
	var a: Cloud = p[0]
	var b: Cloud = p[1]
	var got := []
	var from := []
	b.voice_received.connect(func(f: PackedByteArray) -> void: got.append(f))
	b.voice_from.connect(func(_f: PackedByteArray, id: String, mate: bool) -> void: from.append([id, mate]))
	Game.settings.speaker_mode = NetVoice.OFF
	b._on_room(a._room_packet({"k": "vo", "a": Marshalls.raw_to_base64(frame)}))
	_check(got.is_empty() and from.is_empty(), "with the SPEAKER OFF no voice is taken")
	Game.settings.speaker_mode = NetVoice.ALL
	b._on_room(a._room_packet({"k": "vg", "a": Marshalls.raw_to_base64(frame)}))
	_check(from.is_empty(), "a 1 vs 1 has no teammates: a GROUP frame is never played there")
	for i in 20:
		b._on_room(a._room_packet({"k": "vo", "a": Marshalls.raw_to_base64(frame)}))
	_check(got.size() == int(NetVoice.MAX_FRAMES_S) and got[0] == frame and from.size() == got.size() and from[0] == [a.my_id, false],
		"voice frames arrive whole, with their sender, at most %d at once (the SPEAKER's default ALL)" % int(NetVoice.MAX_FRAMES_S))
	a.free()
	b.free()
	_voice_group_key(frame)
	_voice_units(frame)


## GROUP voice under the sender's own key, given only to its teammates: the other team holds the
## match room's keys too, and still cannot open it.
func _voice_group_key(frame: PackedByteArray) -> void:
	var p := _pair()
	var a: Cloud = p[0]
	var b: Cloud = p[1]
	var e := Cloud.new()                     # an enemy in the same match room (its keys)
	for c: Cloud in [a, b, e]:
		c._use_key(Crypto.new().generate_rsa(2048))
		c.my_id = c._pk_pem.sha256_text().left(32)
		c._room = "r".repeat(16)
	a.opponent = {"id": b.my_id, "name": "BEE"}
	b.opponent = {"id": a.my_id, "name": "ACE"}
	e._aes = a._aes
	e._mac = a._mac
	e.in_session = true
	e.opponent = {"id": a.my_id, "name": "ACE"}
	for c: Cloud in [a, b]:
		c.session_team = {"coop": true}
	Game.settings.speaker_mode = NetVoice.ALL
	var got := {"b": 0, "e": 0}
	b.voice_from.connect(func(f: PackedByteArray, _id: String, mate: bool) -> void:
		if f == frame and mate:
			got.b += 1)
	e.voice_from.connect(func(_f: PackedByteArray, _id: String, _mate: bool) -> void: got.e += 1)
	a._vk_sync()
	# a learns b's public key ("vp") and gives it its GROUP key; the enemy hears both messages too
	a._vk_on({"k": "vp", "pk": b._pk_pem}, b.my_id)
	_check((a._vk.given as Dictionary).has(b.my_id) and not (a._vk.given as Dictionary).has(e.my_id), "the GROUP key goes to the teammate only")
	var pub := CryptoKey.new()
	pub.load_from_string(b._pk_pem, true)
	var vk := {"k": "vk", "to": b.my_id, "s": Marshalls.raw_to_base64(Crypto.new().encrypt(pub, a._vk.raw))}
	b._on_room(a._room_packet(vk.duplicate()))
	e._on_room(a._room_packet(vk.duplicate()))
	_check(b._vkeys.has(a.my_id) and e._vkeys.is_empty(), "the teammate opens the GROUP key; the enemy, not its addressee, cannot")
	for i in 3:
		var pkt := a._room_packet({"k": "vg", "s": Marshalls.raw_to_base64(a._vk_seal(frame))})
		b._on_room(pkt)
		e._on_room(pkt)
	_check(got.b == 3 and got.e == 0, "GROUP frames reach the teammate, never the other team (%s)" % str(got))
	# a teammate no more (a custom room's side changed): a new key, the old one opens nothing
	var old := a._vk.raw as PackedByteArray
	a.session_team = {"coop": false}
	a._vk_sync()
	b._on_room(a._room_packet({"k": "vg", "s": Marshalls.raw_to_base64(a._vk_seal(frame))}))
	_check(a._vk.raw != old and got.b == 3, "a player who stops being a teammate keeps no key to the new GROUP frames")
	for c: Cloud in [a, b, e]:
		c.free()


## The open mic's gate, the MIC / SPEAKER modes, the channels' teammates, mutes, the playback per
## talker and the settings' migration from VOICE CHAT.
func _voice_units(frame: PackedByteArray) -> void:
	var st := {"open": false, "hang": 0, "loud": 0}
	var seq := []
	for r: float in [0.001, 0.05, 0.004, 0.05, 0.05, 0.004, 0.004, 0.004, 0.004, 0.004, 0.004, 0.03, 0.03]:
		seq.append(NetVoice.gate_next(st, r))
	_check(seq == [false, false, false, false, true, true, true, true, true, true, false, false, true],
		"the open mic opens on speech (%d frames in a row: not on a click), stays open %d quiet frames (the ends of words), then closes: %s"
		% [NetVoice.GATE_FRAMES, NetVoice.GATE_HANG - 1, str(seq)])
	# The phone's own loudspeaker: no echo of the others sent back, no shots sent.
	st = {"open": false, "hang": 0, "loud": 0}
	seq = []
	for r: float in [0.5, 0.5, 0.5]:
		seq.append(NetVoice.gate_next(st, r, NetVoice.NEVER))
	for r: float in [0.05, 0.05, 0.05, 0.2, 0.2]:
		seq.append(NetVoice.gate_next(st, r, NetVoice.GATE_LOUD))
	_check(seq == [false, false, false, false, false, false, false, true],
		"while another player is heard here the gate stays shut; while the game is loud only a louder voice opens it: %s" % str(seq))
	st = {"open": true, "hang": NetVoice.GATE_HANG, "loud": 0}
	seq = []
	for r: float in [0.2, 0.03, 0.03, 0.03, 0.03, 0.03, 0.03]:
		seq.append(NetVoice.gate_next(st, r, NetVoice.NEVER))
	_check(seq == [true, true, true, true, true, true, false],
		"talking over another player goes on, their quieter echo alone closes it: %s" % str(seq))
	var quiet := PackedFloat32Array()
	quiet.resize(NetVoice.FRAME_SAMPLES)
	_check(NetVoice.rms_of(quiet) == 0.0 and NetVoice.rms_of(NetVoice.decode(frame)) > NetVoice.GATE_OPEN, "silence keeps it shut, a voice opens it")
	_check(NetVoice.sends(NetVoice.OFF, "match", 3) == "" and NetVoice.sends(NetVoice.ALL, "", 3) == ""
		and NetVoice.sends(NetVoice.ALL, "match", 0) == "all" and NetVoice.sends(NetVoice.GROUP, "match", 0) == ""
		and NetVoice.sends(NetVoice.GROUP, "group", 2) == "group" and NetVoice.sends(NetVoice.ALL, "group", 1) == "all",
		"MIC: OFF sends nothing, ALL to everyone (the 1 vs 1's opponent too), GROUP only with teammates, nothing without a channel")
	_check(NetVoice.hears(false, NetVoice.ALL, false) and not NetVoice.hears(false, NetVoice.GROUP, false) and NetVoice.hears(true, NetVoice.GROUP, false)
		and not NetVoice.hears(true, NetVoice.OFF, false) and not NetVoice.hears(true, NetVoice.ALL, true),
		"SPEAKER: ALL plays everyone, GROUP teammates only, OFF nobody, a muted player never")
	var d := Game.DEFAULT_SETTINGS
	_check(d.mic_mode == NetVoice.OFF and d.speaker_mode == NetVoice.ALL and d.push_to_talk == false and not d.has("voice_chat"),
		"the reference's defaults: the mic OFF, the speaker ALL (others are heard), PUSH TO TALK unticked")
	# Teammates: a DUO / SQUAD match's own team, a custom room's own side, anyone in a lobby group.
	var c := Cloud.new()
	c.my_id = "m".repeat(32)
	c.in_session = true
	c.session_multi = true
	c.session_roster = [{"slot": 0, "id": c.my_id, "team": 0}, {"slot": 1, "id": "t".repeat(32), "team": 0},
		{"slot": 2, "id": "e".repeat(32), "team": 1}, {"slot": 3, "id": "f".repeat(32), "team": 1}]
	_check(c.voice_mate("t".repeat(32)) and not c.voice_mate("e".repeat(32)) and not c.voice_mate(c.my_id) and c.voice_mates() == 1,
		"in a DUO match the teammate is GROUP, the other team is not")
	c.in_session = false
	c.session_multi = false
	c._grp = {"gid": "0".repeat(32), "aes": PackedByteArray(), "mac": PackedByteArray()}
	c.group = {"gid": "0".repeat(32), "leader": c.my_id, "members": [{"id": c.my_id, "name": "ME", "team": -1}, {"id": "t".repeat(32), "name": "T", "team": -1}]}
	_check(c.voice_mate("t".repeat(32)) and c.voice_mates() == 1, "in a lobby group every member is GROUP")
	c.group.room = "123456"
	c.group.members = [{"id": c.my_id, "name": "ME", "team": 0}, {"id": "t".repeat(32), "name": "T", "team": 0}, {"id": "e".repeat(32), "name": "E", "team": 1}]
	_check(c.voice_mate("t".repeat(32)) and not c.voice_mate("e".repeat(32)) and c.voice_mates() == 1, "in a custom room only the own side is GROUP")
	c.free()
	# The hub plays each talker on a player of its own; the speaker modes and mutes decide.
	var v := NetVoice.new()
	t.add_child(v)
	var hub_was := NetVoice._hub
	NetVoice._hub = v
	Game.settings.speaker_mode = NetVoice.ALL
	v.on_voice(frame, "x".repeat(32), false)
	v.on_voice(frame, "y".repeat(32), true)
	_check(v._talkers.has("x".repeat(32)) and v._talkers.has("y".repeat(32)) and NetVoice.speaking("x".repeat(32)),
		"two talkers get a player each (they mix), and show as speaking")
	Game.settings.speaker_mode = NetVoice.GROUP
	v.on_voice(frame, "z".repeat(32), false)
	_check(not v._talkers.has("z".repeat(32)), "SPEAKER GROUP: an enemy's voice is not played")
	Game.settings.speaker_mode = NetVoice.ALL
	NetVoice.set_muted("y".repeat(32), true)
	var before := ((v._talkers.get("y".repeat(32), {"queue": []}) as Dictionary).queue as Array).size()
	v.on_voice(frame, "y".repeat(32), true)
	_check(NetVoice.is_muted("y".repeat(32)) and not v._talkers.has("y".repeat(32)) and before == 0,
		"a muted player is dropped at once and never played (this session)")
	NetVoice.set_muted("y".repeat(32), false)
	Game.profile.blocked = [{"id": "w".repeat(32), "name": "W", "t": 0}]
	v.on_voice(frame, "w".repeat(32), true)
	_check(NetVoice.is_muted("w".repeat(32)) and not v._talkers.has("w".repeat(32)), "a blocked player is always muted")
	Game.profile.blocked = []
	for i in 12:
		v.on_voice(frame, "x".repeat(32), false)
	_check(((v._talkers["x".repeat(32)] as Dictionary).queue as Array).size() <= NetVoice.MAX_QUEUE, "a talker far behind catches up")
	# A talker's voice queued here: the gate's need is NEVER (its echo), then back to GATE_OPEN.
	v._echo_until = 0
	v._loud_until = 0
	var calm := v.gate_need()
	v._process(0.05)
	v._process(0.05)
	var echo := v.gate_need()
	v._echo_until = 0
	v._loud_until = Time.get_ticks_msec() + 1000
	var loud := v.gate_need()
	v._loud_until = 0
	_check(calm == NetVoice.GATE_OPEN and echo == NetVoice.NEVER and loud == NetVoice.GATE_LOUD,
		"the open mic stays shut while another player's voice plays on this phone, needs more while the game is loud: %s" % str([calm, echo, loud]))
	# The app goes to the background: the microphone stops at once, TALK is let go; back, it starts afresh.
	var tone_was := NetVoice.tone_source
	NetVoice.tone_source = false
	v.test_loop = true
	v._process(0.0)
	var ran := v.capturing and v._mic.playing
	v.ptt_held = true
	v._notification(Node.NOTIFICATION_APPLICATION_PAUSED)
	var stopped := not v.capturing and not v._mic.playing and not v.ptt_held
	v._process(0.0)
	var still := not v.capturing and not v._mic.playing
	v._notification(Node.NOTIFICATION_APPLICATION_RESUMED)
	var back := not v.capturing
	v._process(0.0)
	_check(ran and stopped and still and back and v.capturing and v._mic.playing,
		"the microphone stops when the app is paused (TALK let go) and starts again on the way back: %s" % str([ran, stopped, still, back, v.capturing]))
	v.test_loop = false
	v._process(0.0)
	NetVoice.tone_source = tone_was
	NetVoice._hub = hub_was
	v.free()
	# VOICE CHAT (1.8) into the new keys.
	Game.settings = Game.DEFAULT_SETTINGS.duplicate(true)
	Game._apply_saved_settings({"voice_chat": true, "settings_version": 7})
	_check(Game.settings.mic_mode == NetVoice.ALL and Game.settings.push_to_talk == true and Game.settings.speaker_mode == NetVoice.ALL
		and not Game.settings.has("voice_chat"), "VOICE CHAT on (1.8) keeps talking as before: the mic ALL with PUSH TO TALK")
	Game.settings = Game.DEFAULT_SETTINGS.duplicate(true)
	Game._apply_saved_settings({"voice_chat": false, "settings_version": 7})
	_check(Game.settings.mic_mode == NetVoice.OFF and Game.settings.push_to_talk == false and Game.settings.speaker_mode == NetVoice.ALL,
		"VOICE CHAT off (1.8's default): the mic stays OFF, the speaker now plays the others")
	Game._apply_saved_settings({"mic_mode": 9, "speaker_mode": -2, "push_to_talk": "yes"})
	_check(Game.settings.mic_mode == NetVoice.GROUP and Game.settings.speaker_mode == NetVoice.OFF and Game.settings.push_to_talk == false,
		"modes past their range are clamped, PUSH TO TALK not true or false is off")
	Game.settings = Game.DEFAULT_SETTINGS.duplicate(true)


func _settings() -> void:
	_check(SettingsPanel.TABS[4] == "ONLINE" and SettingsPanel.TAB_KEYS[4] == ["chat", "friend_chat", "show_career",
		"challenges_from", "friend_requests", "vibration", "direct_connect"],
		"the ONLINE tab: chat, friends chat, SHOW MY CAREER, challenges, requests, vibration out of a match, direct connection (voice: SOUND)")
	_check(Game.DEFAULT_SETTINGS.chat == true and Game.DEFAULT_SETTINGS.friend_chat == true and Game.DEFAULT_SETTINGS.show_career == true
		and Game.DEFAULT_SETTINGS.mic_mode == NetVoice.OFF, "chat and the public career on by default, the mic off until asked for")
	Game.settings = Game.DEFAULT_SETTINGS.duplicate(true)
	Game._apply_saved_settings({"push_to_talk": "yes", "chat": 0, "show_career": false})
	_check(Game.settings.push_to_talk == false and Game.settings.chat == true and Game.settings.show_career == false,
		"an ONLINE setting that is not true or false falls back to its default")
	var panel := SettingsPanel.new()
	t.add_child(panel)
	panel._show_tab(4)
	_check(["Toggle_chat", "Toggle_friend_chat", "Toggle_show_career", "Toggle_challenges_from",
		"Toggle_friend_requests", "Toggle_vibration", "Toggle_direct_connect"].all(func(n: String) -> bool:
		return panel.find_child(n, true, false) != null) and panel.find_child("Toggle_voice_chat", true, false) == null,
		"the ONLINE tab shows its seven settings (no VOICE CHAT: the voice is under the character, in a match and in SOUND)")
	var duel := panel.find_child("Toggle_challenges_from", true, false)
	(duel.get_child(2) as Button).pressed.emit()
	_check(Game.settings.challenges_from == Game.CHALLENGES_NOBODY, "DUEL CHALLENGES FROM's third choice is NOBODY")
	Game.settings.challenges_from = Game.CHALLENGES_EVERYONE
	panel.free()


## DUEL CHALLENGES FROM and FRIEND REQUESTS: their defaults, their checks on load, and Cloud
## declining or ignoring what they leave out (never shown here).
func _reach() -> void:
	var d := Game.DEFAULT_SETTINGS
	_check(d.challenges_from == Game.CHALLENGES_EVERYONE and d.friend_requests == true and d.vol_voice == 80,
		"challenges from everyone, friend requests on and the voice at 80 by default")
	Game.settings = Game.DEFAULT_SETTINGS.duplicate(true)
	Game._apply_saved_settings({"challenges_from": 7, "friend_requests": "off", "vol_voice": 250})
	_check(Game.settings.challenges_from == Game.CHALLENGES_NOBODY and Game.settings.friend_requests == true
		and Game.settings.vol_voice == 100, "a choice or volume past its range is clamped, a request switch not true or false is ON")
	Game._apply_saved_settings({"challenges_from": -3, "vol_voice": -5, "friend_requests": false})
	_check(Game.settings.challenges_from == Game.CHALLENGES_EVERYONE and Game.settings.vol_voice == 0 and Game.settings.friend_requests == false,
		"a negative choice is EVERYONE, a negative volume 0, OFF is kept")
	Game.settings = Game.DEFAULT_SETTINGS.duplicate(true)
	Game._apply_saved_settings({"challenges_from": "NOBODY"})
	_check(Game.settings.challenges_from == Game.CHALLENGES_EVERYONE, "a choice saved as text is dropped")
	# Challenges: shown, or declined at once (the challenger hears "dec", nothing pops up here).
	var me := RecordingCloud.new()
	var key := Crypto.new().generate_rsa(2048)
	me._use_key(key)
	var ka := Crypto.new().generate_rsa(2048)
	var pa := ka.save_to_string(true)
	var friend := pa.sha256_text().left(32)
	var stranger := "b2".repeat(16)
	var rival := RecordingCloud.new()           # the friend's phone: its challenge (Cloud.invite) is signed
	rival._use_key(ka)
	rival._connected = true
	rival.peers[me.my_id] = {"name": "ME", "bundle": "default", "pk": key.save_to_string(true), "seen": 0}
	_check(rival.invite(me.my_id) and rival.sent.size() == 1, "a challenge goes out")
	var signed: Variant = JSON.parse_string((rival.sent[0][1] as PackedByteArray).get_string_from_utf8()) if rival.sent.size() == 1 else {}
	_check(signed is Dictionary and me.invite_proven(signed, friend) and not me.invite_proven(signed, stranger),
		"a challenge is signed with its sender's key, for its sender's id")
	rival.free()
	var pub := _pub(key.save_to_string(true))
	var made_up := func(from: String) -> Dictionary:
		return {"t": "inv", "from": from, "name": "RIVAL", "sec": Marshalls.raw_to_base64(Crypto.new().encrypt(pub, Crypto.new().generate_random_bytes(80)))}
	var shown := []
	me.invited.connect(func(who: String) -> void: shown.append(who))
	Game.profile.friends = {friend: {"name": "ACE"}}
	Game.profile.blocked = []
	for c: Array in [[Game.CHALLENGES_EVERYONE, stranger, made_up.call(stranger), true, "a stranger's"],
			[Game.CHALLENGES_FRIENDS, stranger, made_up.call(stranger), false, "a stranger's"],
			[Game.CHALLENGES_FRIENDS, friend, signed, true, "a friend's"],
			[Game.CHALLENGES_FRIENDS, friend, made_up.call(friend), false, "an unsigned one in a friend's name"],
			[Game.CHALLENGES_NOBODY, friend, signed, false, "a friend's"]]:
		Game.settings.challenges_from = c[0]
		me._inbox_budget = 8.0
		me._incoming = {}
		me.sent.clear()
		shown.clear()
		me._on_inbox(c[2])
		var said_no := false
		if me.sent.size() == 1 and String(me.sent[0][0]).ends_with("/u/" + String(c[1])):
			var answer: Variant = JSON.parse_string((me.sent[0][1] as PackedByteArray).get_string_from_utf8())
			said_no = answer is Dictionary and String((answer as Dictionary).get("t", "")) == "dec"
		_check(shown.size() == (1 if c[3] else 0) and me.has_invite() == c[3] and said_no != c[3],
			"challenges from %s: %s challenge is %s" % [SettingsOnline.CHALLENGE_CHOICES[c[0]], c[4],
			"shown" if c[3] else "declined at once, never shown"])
	Game.settings.challenges_from = Game.CHALLENGES_EVERYONE
	Game.profile.friends = {}
	# Friend requests, straight and waiting on the relay: ignored while FRIEND REQUESTS is off.
	var changed := [0]
	me.friends_changed.connect(func() -> void: changed[0] += 1)
	Game.profile.friend_in = {}
	var pk := "A NEW PLAYER'S KEY"
	var asker := pk.sha256_text().left(32)
	Game.settings.friend_requests = false
	me._inbox_budget = 8.0
	me.sent.clear()
	me._on_inbox({"t": "frq", "from": asker, "name": "NEWBIE", "pk": pk})
	_check(me.friend_requests.is_empty() and changed[0] == 0 and me.sent.is_empty(), "with FRIEND REQUESTS off a request is ignored, unanswered")
	var ida := friend                           # (not a friend any more: a request from them is listed)
	var now := int(Time.get_unix_time_from_system())
	var waiting := {"t": "frq", "from": ida, "to": me.my_id, "name": "WAITER", "pk": pa, "ts": now,
		"sig": Cloud._sign_with(ka, Cloud.waiting_text("frq", ida, me.my_id, now))}
	me._on_waiting(true, ida, waiting)
	_check(me.friend_requests.is_empty() and changed[0] == 0 and me.sent.size() == 1 and (me.sent[0][1] as PackedByteArray).is_empty()
		and bool(me.sent[0][2]), "and one waiting on the relay is deleted there unread")
	Game.settings.friend_requests = true
	me._inbox_budget = 8.0
	me._on_inbox({"t": "frq", "from": asker, "name": "NEWBIE", "pk": pk})
	me._on_waiting(true, ida, waiting)
	_check(me.friend_requests.has(asker) and me.friend_requests.has(ida) and changed[0] == 2, "with it on both are listed")
	Game.profile.friend_in = {}
	me.free()


## The lobby's notices: the unread badge's count and a message's first words.
func _notices() -> void:
	NetChat.reset_for_test()
	var a := "c3".repeat(16)
	var b := "d4".repeat(16)
	var stranger := "e5".repeat(16)
	var now := int(Time.get_unix_time_from_system())
	Game.profile.friends = {a: {"name": "ACE"}, b: {"name": "BOLT"}}
	Game.profile.blocked = []
	Game.settings.friend_chat = true
	NetChat.add(a, now, false, "ONE")
	NetChat.add(a, now + 1, false, "TWO")
	NetChat.add(a, now + 2, true, "MINE")
	NetChat.add(b, now, false, "HI")
	NetChat.add(stranger, now, false, "NOT A FRIEND")
	_check(NetChat.unread_total() == 3, "the ONLINE 1 VS 1 badge counts the friends' unread messages")
	Game.profile.blocked = [{"id": b, "name": "", "t": 0}]
	_check(NetChat.unread_total() == 2, "not a blocked player's")
	Game.settings.friend_chat = false
	_check(NetChat.unread_total() == 0, "and none while FRIENDS CHAT is off")
	Game.settings.friend_chat = true
	NetChat.mark_read(a)
	_check(NetChat.unread_total() == 0, "read, they leave the badge")
	Game.profile.blocked = []
	_check(NetChat.first_words("SEE YOU AT 9") == "SEE YOU AT 9"
		and NetChat.first_words("SEE YOU AT 9? BRING THE SNIPER AND THE SHOTGUN TOO") == "SEE YOU AT 9? BRING THE SNIPER AND..."
		and NetChat.first_words("SEE YOU AT 9? BRING THE SNIPERRIFLE") == "SEE YOU AT 9? BRING THE..."
		and NetChat.first_words("X".repeat(60)) == "X".repeat(34) + "...", "a notice shows a message's first words")
	NetChat.reset_for_test()


## The chat panel's background runs to the screen's edge, its content keeps clear of a camera
## cutout on that side (UI.pad_clear_of_cutout, as the lobby's keep_clear_of_cutout).
func _chat_cutout() -> void:
	UI.margins_for_test = Vector2(90, 40)
	var m := MarginContainer.new()
	t.add_child(m)
	UI.pad_clear_of_cutout(m)
	_check(m.get_theme_constant("margin_left") == 90 and m.get_theme_constant("margin_right") == 0,
		"the chat panel's content is padded by a left cutout (only on the side it touches)")
	UI.margins_for_test = Vector2.ZERO
	(m.get_child(0) as Timer).timeout.emit()
	_check(m.get_theme_constant("margin_left") == 0, "and follows the cutout when the phone turns over")
	UI.margins_for_test = Vector2(-1, -1)
	m.queue_free()               # after its deferred update has run


## SOUND (no master volume, as the reference's): VOICE CHAT plays the other player's voice on its own
## bus; every slider is heard at once; the Master bus stays at full volume.
func _volumes() -> void:
	Game.settings = Game.DEFAULT_SETTINGS.duplicate(true)
	var panel := SettingsPanel.new()
	t.add_child(panel)
	panel._show_tab(3)
	var sliders := panel.find_children("*", "HSlider", true, false)
	_check(SettingsPanel.TAB_KEYS[3] == ["vol_sfx", "vol_music", "vol_voice", "push_to_talk"] and sliders.size() == 3
		and panel.find_child("Stepper_vol_voice", true, false) != null and panel.find_child("Toggle_push_to_talk", true, false) != null
		and panel.find_child("MicTest", true, false) != null,
		"the SOUND tab: effects, music, then VOICE CHAT: PUSH TO TALK, the voice's volume and MIC TEST")
	if sliders.size() == 3:
		(sliders[0] as HSlider).value = 20         # GAME AUDIO: music first, as the reference
		(sliders[1] as HSlider).value = 30
		(sliders[2] as HSlider).value = 0
	var db := func(bus: String) -> float: return AudioServer.get_bus_volume_db(AudioServer.get_bus_index(bus))
	_check(Game.settings.vol_sfx == 30 and absf(float(db.call("SFX")) - linear_to_db(0.3)) < 0.01
		and Game.settings.vol_music == 20 and absf(float(db.call("Music")) - linear_to_db(0.2)) < 0.01,
		"moving EFFECTS or MUSIC sets its bus at once, while the panel is open")
	_check(Game.settings.vol_voice == 0 and AudioServer.is_bus_mute(AudioServer.get_bus_index("Voice")), "VOICE CHAT at 0 mutes the voice")
	_check(is_zero_approx(float(db.call("Master"))) and not AudioServer.is_bus_mute(AudioServer.get_bus_index("Master")),
		"the Master bus plays at full volume (no master setting)")
	panel.free()
	var voice := NetVoice.new()
	t.add_child(voice)
	var out_bus := AudioServer.get_bus_index(NetVoice.OUT_BUS)
	_check(voice._out.bus == NetVoice.OUT_BUS and out_bus >= 0 and AudioServer.get_bus_send(out_bus) == &"Master",
		"the other phone's voice plays on the Voice bus")
	voice.free()
	Game.settings = Game.DEFAULT_SETTINGS.duplicate(true)
	Game.apply_settings()
