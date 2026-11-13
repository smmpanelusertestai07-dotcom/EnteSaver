extends RefCounted
## Unit tests of the microphone's hardening (NetVoice, round 8) through its OS seam (os_granted,
## os_request, on_android): asking, granting (the stream started again), refusing (MIC MODE OFF
## and one note), "don't ask again" (never asked twice), the NO MIC INPUT detector, and the cut to
## 8 kHz from a 44.1 and a 48 kHz capture. Run from tests/run_tests.gd (which counts the checks).

var t: Node
var asked := 0
var granted := false


static func run(runner: Node) -> void:
	var me := new()
	me.t = runner
	var saved_at := Game.autotest
	var saved_settings := Game.settings.duplicate(true)
	var saved := [NetVoice.os_granted, NetVoice.os_request, NetVoice.on_android, NetVoice.tone_source]
	Game.autotest = "unit"                  # nothing is saved
	NetVoice.on_android = true
	NetVoice.tone_source = false
	NetVoice.os_granted = func() -> bool: return me.granted
	NetVoice.os_request = func() -> bool:
		me.asked += 1
		return me.granted
	me._grant()
	me._deny()
	me._deny_for_good()
	me._no_input()
	me._resample()
	NetVoice.os_granted = saved[0]
	NetVoice.os_request = saved[1]
	NetVoice.on_android = saved[2]
	NetVoice.tone_source = saved[3]
	Game.settings = saved_settings
	Game.autotest = saved_at


func _check(cond: bool, what: String) -> void:
	t.call("_check", cond, what)


func _voice() -> NetVoice:
	asked = 0
	granted = false
	return NetVoice.new()


func _grant() -> void:
	var v := _voice()
	_check(v.perm_state == NetVoice.PERM_NOT_ASKED, "the microphone is not asked for before the player's tap")
	_check(not v.ask_mic() and asked == 1 and v.perm_state == NetVoice.PERM_WAITING, "a tap asks once and waits for the answer")
	_check(not v.ask_mic() and asked == 1, "a second tap while the question is open does not ask again")
	v._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)     # (the system's question showed)
	v.capturing = true
	granted = true
	v._on_permission(NetVoice.MIC_PERMISSION, true)
	_check(v.perm_state == NetVoice.PERM_GRANTED and v.restarts == 1, "the grant starts the microphone's stream again (%d)" % v.restarts)
	v._notification(Node.NOTIFICATION_APPLICATION_FOCUS_IN)
	_check(v.restarts == 2, "the app's focus back while it captures starts the stream again")
	_check(v.ask_mic() and asked == 1, "granted, nothing is asked any more")
	v.free()


func _deny() -> void:
	var v := _voice()
	Game.settings["mic_mode"] = NetVoice.ALL
	var notes := [0]
	v.mic_refused.connect(func() -> void: notes[0] += 1)
	v.ask_mic()
	v._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	v._ask_ms = Time.get_ticks_msec() - 2000                      # (the player read the question)
	v._on_permission(NetVoice.MIC_PERMISSION, false)
	_check(v.perm_state == NetVoice.PERM_DENIED and NetVoice.mic_mode() == NetVoice.OFF and notes[0] == 1,
		"a refusal puts MIC MODE back to OFF with one note (%s, %d)" % [v.perm_state, notes[0]])
	_check(NetVoice.REFUSED_NOTE.contains("ANDROID SETTINGS"), "the note says where to allow it")
	v.ask_mic()
	_check(asked == 2, "after one refusal the next tap may ask again")
	v._notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	v._ask_ms = Time.get_ticks_msec() - 2000
	v._on_permission(NetVoice.MIC_PERMISSION, false)
	_check(v.perm_state == NetVoice.PERM_DENIED_FOREVER, "a second refusal counts as for good (Android asks no more)")
	v.free()


func _deny_for_good() -> void:
	var v := _voice()
	var notes := [0]
	v.mic_refused.connect(func() -> void: notes[0] += 1)
	v.ask_mic()
	v._on_permission(NetVoice.MIC_PERMISSION, false)            # at once, no question seen
	_check(v.perm_state == NetVoice.PERM_DENIED_FOREVER, "a refusal at once with no question is \"don't ask again\"")
	for i in 3:
		_check(not v.ask_mic(), "denied for good, a tap gives no microphone")
	_check(asked == 1 and notes[0] == 4, "denied for good, the game never asks twice and only says where to allow it (%d asks, %d notes)" % [asked, notes[0]])
	v.free()


func _no_input() -> void:
	var v := _voice()
	v.capturing = true
	var now := Time.get_ticks_msec()
	v._input_ms = now - 1000
	v._check_input(now)
	_check(not v.no_input, "a second of silence is not yet no input")
	var zeros := PackedVector2Array()
	zeros.resize(441)
	v.take_capture(zeros, 44100.0)
	v._input_ms = now - NetVoice.NO_INPUT_MS - 100
	v._check_input(now)
	_check(v.no_input and v.restarts == 1, "2 s of exact zeros give the NO MIC INPUT note and one restart (%s, %d)" % [v.no_input, v.restarts])
	v._input_ms = now - NetVoice.NO_INPUT_MS - 100
	v.no_input = false
	v._check_input(now)
	_check(v.no_input and v.restarts == 1, "the stream is started again only once")
	var voice := PackedVector2Array()
	voice.resize(441)
	voice.fill(Vector2(0.1, 0.1))
	v.take_capture(voice, 44100.0)
	_check(not v.no_input, "a frame that is not silence clears the note")
	v.free()


func _resample() -> void:
	for rate: int in [44100, 48000]:
		var v := _voice()
		var buf := PackedVector2Array()
		buf.resize(rate / 10)
		for i in buf.size():
			var x := 0.3 * sin(TAU * 400.0 * float(i) / float(rate))
			buf[i] = Vector2(x, x)
		v.take_capture(buf, float(rate))
		_check(absi(v._pending.size() - NetVoice.FRAME_SAMPLES) <= 1, "100 ms of a %d Hz capture give %d samples (%d)" % [rate,
			NetVoice.FRAME_SAMPLES, v._pending.size()])
		v.free()
	_check(NetVoice.source_rate() > 0.0, "the capture's rate is known")
