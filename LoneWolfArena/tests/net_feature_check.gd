extends RefCounted
## Unit tests of the online extras (run from tests/run_tests.gd, which counts the checks):
## the ping (NetPing rules, the relay's PINGRESP and the room ping timed), the match state (short
## numbers, repeats skipped, NetSmoother drawing it in the past and bridging gaps), chat (NetChat's
## text rules, the match line's rate and settings, a friend's message sealed, opened, tampered and
## replayed, only from friends), card v3 (the career summary signed, hidden, malformed, older
## builds' check still passing), the voice codec (NetVoice) and the ONLINE settings tab.

var t: Node


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
	_check(NetPing.label(87) == "87 ms" and NetPing.label(-1) == "--- ms" and NetPing.label(123456) == "9999 ms", "the ping's text")
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
	var sent := [cl.send_state(s), cl.send_state(s), cl.send_state(s)]
	_check(sent == [true, true, false], "a state like the last goes out once more, then is skipped (%s)" % str(sent))
	cl._state_ms -= Cloud.STATE_IDLE_MS + 10
	_check(cl.send_state(s), "an unchanged state still goes out every STATE_IDLE_MS")
	s[0] += 0.5
	_check(cl.send_state(s), "a changed state goes out at once")
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
	b.voice_received.connect(func(f: PackedByteArray) -> void: got.append(f))
	Game.settings.voice_chat = false
	b._on_room(a._room_packet({"k": "vo", "a": Marshalls.raw_to_base64(frame)}))
	_check(got.is_empty(), "with VOICE CHAT off no voice is played")
	Game.settings.voice_chat = true
	for i in 20:
		b._on_room(a._room_packet({"k": "vo", "a": Marshalls.raw_to_base64(frame)}))
	_check(got.size() == int(NetVoice.MAX_FRAMES_S) and got[0] == frame, "voice frames arrive whole, at most %d at once" % int(NetVoice.MAX_FRAMES_S))
	Game.settings.voice_chat = false
	a.free()
	b.free()


func _settings() -> void:
	_check(SettingsPanel.TABS[4] == "ONLINE" and SettingsPanel.TAB_KEYS[4] == ["chat", "friend_chat", "show_career", "voice_chat"],
		"the ONLINE tab: chat, friends chat, SHOW MY CAREER, voice chat")
	_check(Game.DEFAULT_SETTINGS.chat == true and Game.DEFAULT_SETTINGS.friend_chat == true and Game.DEFAULT_SETTINGS.show_career == true
		and Game.DEFAULT_SETTINGS.voice_chat == false, "chat and the public career on by default, voice off until asked for")
	Game.settings = Game.DEFAULT_SETTINGS.duplicate(true)
	Game._apply_saved_settings({"voice_chat": "yes", "chat": 0, "show_career": false})
	_check(Game.settings.voice_chat == false and Game.settings.chat == true and Game.settings.show_career == false,
		"an ONLINE setting that is not true or false falls back to its default")
	var panel := SettingsPanel.new()
	t.add_child(panel)
	panel._show_tab(4)
	_check(["Toggle_chat", "Toggle_friend_chat", "Toggle_show_career", "Toggle_voice_chat"].all(func(n: String) -> bool:
		return panel.find_child(n, true, false) != null), "the ONLINE tab shows its four settings")
	panel.free()
