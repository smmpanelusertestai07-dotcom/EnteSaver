class_name NetVoice
extends Node
## Voice between players, as the reference does it: the SPEAKER plays the others (ALL by
## default), the MIC is OFF until the player picks ALL or GROUP (asking Android for the microphone,
## RECORD_AUDIO, at that moment). One NetVoice (`hub()`, made on first use under the tree's root,
## it outlives scene changes) runs the microphone and every player's sound:
##  - CHANNELS (`channel()`): in a match (Game.session in session: the 1 vs 1, online or LOCAL, and
##    DUO / SQUAD) the match room (Cloud.send_voice: "vo" to everyone, "vg" to the own team only);
##    out of one, the lobby GROUP or CUSTOM ROOM this phone is in (Cloud.send_group_voice, the group
##    room's own voice topic). Every frame goes inside that room's end-to-end encryption and is
##    never stored. No channel (alone, offline): the microphone does not run.
##  - MIC MODE (setting mic_mode): OFF / ALL (everyone in the match, room or group: in a 1 vs 1 the
##    opponent too) / GROUP (the player's own group or team; with no teammates it sends nothing).
##    The open microphone sends only while the player speaks (`gate_next`: a 100 ms frame louder
##    than GATE_OPEN opens it, GATE_HANG quiet frames close it, the frame before the voice goes
##    too); PUSH TO TALK (setting push_to_talk) sends only while TALK is held (`ptt_held`) and
##    runs the microphone only then.
##  - SPEAKER MODE (setting speaker_mode): OFF / ALL / GROUP (only teammates: Cloud.voice_from's
##    `mate`). A player muted for this session (`set_muted`) or blocked is never played.
##  - Each talker gets an AudioStreamGenerator of its own (so two talkers mix) on the bus OUT_BUS,
##    whose volume is SOUND > VOICE CHAT > VOICE (setting vol_voice, Game.apply_settings), with a
##    small jitter buffer (START_FRAMES before it starts, MAX_QUEUE at most). `speaking(id)`: a frame
##    of that player played within SPEAKING_MS (the HUD's and the lobby's speaking marks); "" is
##    this phone (its gate open).
##  - MIC TEST (SOUND > VOICE CHAT, `test_loop`): the microphone's frames come back here through
##    the codec (what the others would hear) with the level meter (`level`), nothing is sent.
## The microphone plays into the muted bus BUS through an AudioEffectCapture; the sound is cut to
## 8 kHz mono and packed as IMA ADPCM (4 bits a sample) in FRAME_MS frames (`encode`). On Android
## Godot starts the input only when the microphone stream starts, and it fails without the
## permission: when the permission arrives later (or the app comes back from the background) the
## stream is started again. `tone_source` (tests and the cloud phones, which have no microphone:
## LW_VOICE_TONE=1 in a debug build, or SETTINGS' hidden test switch) replaces the microphone with a
## generated tone that speaks for TONE_ON_S and pauses for TONE_OFF_S.

const RATE := 8000
const FRAME_MS := 100
const FRAME_SAMPLES := RATE * FRAME_MS / 1000          # 800
const HEADER := 4                                        # version, predictor (int16), step index
const MAX_FRAME := HEADER + FRAME_SAMPLES / 2            # 404 bytes
const MAX_B64 := 600                                     # its base64 is 540 characters
const MAX_FRAMES_S := 14.0                               # frames a second accepted (10 are sent)
const START_FRAMES := 2
const MAX_QUEUE := 6
const START_WAIT_S := 0.25
const BUS := "VoiceIn"
const OUT_BUS := "Voice"                                 # made by Game (_setup_audio_buses)
const MIC_PERMISSION := "android.permission.RECORD_AUDIO"
## The modes of the settings mic_mode and speaker_mode.
const OFF := 0
const ALL := 1
const GROUP := 2
const MODE_NAMES := ["OFF", "ALL", "GROUP"]
## The open microphone's gate: RMS of a 100 ms frame (-1..1) that opens it, and the quiet frames
## it stays open after the voice dropped (the ends of words are not cut).
const GATE_OPEN := 0.02
const GATE_HANG := 6
const SPEAKING_MS := 450
const MAX_TALKERS := 8                                   # players heard at once (the oldest quiet one makes room)
const QUIET_FREE_MS := 15000                             # a talker's player is freed after this long without a frame
const TONE_HZ := 440.0
const TONE_ON_S := 1.0
const TONE_OFF_S := 0.6
const ME := ""                                           # this phone in `speaking` and the MIC TEST's player
const REFUSED_NOTE := "MICROPHONE NOT ALLOWED: ALLOW IT IN YOUR PHONE'S SETTINGS > APPS > WOLF ARENA > PERMISSIONS"

const STEPS := [7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80,
	88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724,
	796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428,
	4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385,
	24623, 27086, 29794, 32767]
const INDEX_STEP := [-1, -1, -1, -1, 2, 4, 6, 8]

signal frame_ready(frame: PackedByteArray)    # every frame the microphone lets out (sent, or the MIC TEST's)
signal changed                                # a mode, a mute or the microphone changed (the buttons redraw)
signal mic_refused                            # Android refused the microphone: the mic is OFF again (REFUSED_NOTE)

static var _hub: NetVoice = null
## Tests and the cloud phones: a generated tone instead of the microphone (no permission needed).
static var tone_source := not OS.has_feature("template") and OS.get_environment("LW_VOICE_TONE") == "1"
static var _muted := {}                       # id -> true: players muted for this session

var capturing := false                        # the microphone (or the test tone) runs
var sending := false                          # frames go out now: the gate is open, or TALK is held
var ptt_held := false                         # PUSH TO TALK: the TALK button is held
var test_loop := false                        # MIC TEST: the own voice back here, nothing sent
var level := 0.0                              # RMS of the last frame (0..1): the MIC TEST's meter
var frames_sent := 0
var frames_heard := 0                         # frames pushed into a talker's generator
var _capture: AudioEffectCapture
var _mic: AudioStreamPlayer
var _out: AudioStreamPlayer                   # the MIC TEST's player (ME)
var _talkers := {}                            # id -> {"player", "gen", "queue", "wait", "room", "ms"}
var _pending := PackedFloat32Array()          # 8 kHz samples not framed yet
var _acc := 0.0                               # resampling: input frames summed into the next 8 kHz sample
var _acc_n := 0
var _phase := 0.0
var _tone_t := 0.0
var _tone_due := 0.0
var _gate := {"open": false, "hang": 0}
var _prev := PackedByteArray()                # the frame before the gate opened (it goes first)
var _heard := {}                              # id -> when its last frame came (ms; ME: the last one sent)
var _asking := false
var _paused := false
var _speaker_back := ALL                      # the match's speaker button turns this back on
var _log_t := 0.0


## The one NetVoice (made on first use under the tree's root; it outlives scene changes).
static func hub() -> NetVoice:
	if _hub == null or not is_instance_valid(_hub):
		_hub = NetVoice.new()
		_hub.name = "NetVoiceHub"
		var tree := Engine.get_main_loop() as SceneTree
		if tree != null and tree.root != null:
			tree.root.add_child.call_deferred(_hub)
	return _hub


static func mic_mode() -> int:
	return clampi(int(Game.settings.get("mic_mode", OFF)), OFF, GROUP)


static func speaker_mode() -> int:
	return clampi(int(Game.settings.get("speaker_mode", ALL)), OFF, GROUP)


static func push_to_talk() -> bool:
	return bool(Game.settings.get("push_to_talk", false))


## Muted for this session (V4), or blocked: never played.
static func is_muted(id: String) -> bool:
	return _muted.has(id) or (id != "" and Game.is_blocked(id))


static func set_muted(id: String, on: bool) -> void:
	if on:
		_muted[id] = true
	else:
		_muted.erase(id)
	if _hub != null and is_instance_valid(_hub):
		_hub._drop_talker(id)
		_hub.changed.emit()


## Whether that player was heard within SPEAKING_MS (ME: this phone's own voice going out).
static func speaking(id: String) -> bool:
	if _hub == null or not is_instance_valid(_hub) or not _hub._heard.has(id):
		return false
	return Time.get_ticks_msec() - int(_hub._heard[id]) < SPEAKING_MS


## Whether a frame from a player is played: the speaker mode (GROUP: teammates only), mutes.
static func hears(mate: bool, mode: int, muted: bool) -> bool:
	if muted or mode == OFF:
		return false
	return mate if mode == GROUP else true


## What the microphone sends in a channel: "" nothing, "all" to everyone, "group" to teammates.
static func sends(mode: int, ch: String, mate_n: int) -> String:
	if mode == OFF or ch == "":
		return ""
	if mode == GROUP:
		return "group" if mate_n > 0 else ""
	return "all"


## The open microphone's gate over one frame's RMS: open from GATE_OPEN, closed after GATE_HANG
## quieter frames. `state`: {"open", "hang"}.
static func gate_next(state: Dictionary, rms: float) -> bool:
	if rms >= GATE_OPEN:
		state.open = true
		state.hang = GATE_HANG
	elif bool(state.open):
		state.hang = int(state.hang) - 1
		if int(state.hang) <= 0:
			state.open = false
	return bool(state.open)


static func rms_of(samples: PackedFloat32Array) -> float:
	if samples.is_empty():
		return 0.0
	var sum := 0.0
	for v in samples:
		sum += v * v
	return sqrt(sum / samples.size())


## Where the voice goes now: "match" (Game.session in a session), "group" (the lobby group or
## custom room this phone is in, with someone else in it), "" (nowhere: the microphone stays off).
static func channel() -> String:
	var s: Cloud = Game.session
	if s != null and is_instance_valid(s) and s.in_session:
		return "match"
	var c: Cloud = Game.cloud
	if c != null and is_instance_valid(c) and c.voice_group_ready():
		return "group"
	return ""


## The other players of the channel who count as GROUP (teammates; in a 1 vs 1 none).
static func mates() -> int:
	match channel():
		"match":
			return Game.session.voice_mates()
		"group":
			return Game.cloud.voice_mates()
	return 0


static func mic_allowed() -> bool:
	return tone_source or OS.get_name() != "Android" or MIC_PERMISSION in OS.get_granted_permissions()


## MIC MODE (the lobby's and the match's popup): a mode other than OFF asks Android for the
## microphone the first time; refused, the mode goes back to OFF and mic_refused says so.
func set_mic_mode(m: int) -> void:
	Game.settings["mic_mode"] = clampi(m, OFF, GROUP)
	Game.save_settings()
	if m != OFF:
		ask_mic()
	changed.emit()


func set_speaker_mode(m: int) -> void:
	Game.settings["speaker_mode"] = clampi(m, OFF, GROUP)
	Game.save_settings()
	if m == OFF:
		for id: String in _talkers.keys():
			if id != ME:
				_drop_talker(id)
	else:
		_speaker_back = m
	changed.emit()


## The match's speaker button: OFF, and back to what it was.
func toggle_speaker() -> void:
	set_speaker_mode(OFF if speaker_mode() != OFF else _speaker_back)


func set_push_to_talk(on: bool) -> void:
	Game.settings["push_to_talk"] = on
	Game.save_settings()
	ptt_held = false
	changed.emit()


## True when the microphone may run now; else asks for it (the answer comes in _on_permission).
func ask_mic() -> bool:
	if mic_allowed():
		return true
	var tree := Engine.get_main_loop() as SceneTree
	if tree != null and not tree.on_request_permissions_result.is_connected(_on_permission):
		tree.on_request_permissions_result.connect(_on_permission)
	if _asking:
		return false
	_asking = true
	if OS.request_permission(MIC_PERMISSION):
		_asking = false
		return true
	return false


func _on_permission(perm: String, granted: bool) -> void:
	if perm != MIC_PERMISSION:
		return
	_asking = false
	if granted:
		if capturing and not tone_source and _mic != null:
			_mic.stop()                  # Godot's input failed to start without it: start it again
			_mic.play()
	else:
		test_loop = false
		Game.settings["mic_mode"] = OFF
		Game.save_settings()
		mic_refused.emit()
	changed.emit()


# ---------------------------------------------------------------- codec

## 8 kHz samples (-1..1) as one frame: [1, predictor lo, hi, step index] + two samples a byte.
static func encode(samples: PackedFloat32Array) -> PackedByteArray:
	var n := mini(samples.size(), FRAME_SAMPLES)
	var pred := clampi(roundi(samples[0] * 32767.0), -32768, 32767) if n > 0 else 0
	var index := 0
	if n > 1:
		var first_diff := absi(roundi(samples[1] * 32767.0) - pred)
		while index < 88 and STEPS[index] < first_diff / 4:
			index += 1
	var out := PackedByteArray([1, pred & 0xFF, (pred >> 8) & 0xFF, index])
	var byte := 0
	for i in n:
		var target := clampi(roundi(samples[i] * 32767.0), -32768, 32767)
		var step: int = STEPS[index]
		var diff := target - pred
		var code := 0
		if diff < 0:
			code = 8
			diff = -diff
		var delta := step >> 3
		if diff >= step:
			code |= 4
			diff -= step
			delta += step
		if diff >= step >> 1:
			code |= 2
			diff -= step >> 1
			delta += step >> 1
		if diff >= step >> 2:
			code |= 1
			delta += step >> 2
		pred = clampi(pred - delta if code & 8 else pred + delta, -32768, 32767)
		index = clampi(index + int(INDEX_STEP[code & 7]), 0, 88)
		if i % 2 == 0:
			byte = code
		else:
			out.append(byte | (code << 4))
	if n % 2 == 1:
		out.append(byte)
	return out


## A frame back to 8 kHz samples (-1..1); empty when it is not a frame (`frame_ok`).
static func decode(frame: PackedByteArray) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	if not frame_ok(frame):
		return out
	var pred := frame[1] | (frame[2] << 8)
	if pred >= 32768:
		pred -= 65536
	var index := int(frame[3])
	for i in range(HEADER, frame.size()):
		for code: int in [frame[i] & 0x0F, frame[i] >> 4]:
			var step: int = STEPS[index]
			var delta := step >> 3
			if code & 4:
				delta += step
			if code & 2:
				delta += step >> 1
			if code & 1:
				delta += step >> 2
			pred = clampi(pred - delta if code & 8 else pred + delta, -32768, 32767)
			index = clampi(index + int(INDEX_STEP[code & 7]), 0, 88)
			out.append(pred / 32768.0)
	return out


static func frame_ok(frame: PackedByteArray) -> bool:
	return frame.size() > HEADER and frame.size() <= MAX_FRAME and frame[0] == 1 and frame[3] <= 88


# ---------------------------------------------------------------- microphone and speaker

## The microphone's muted bus with its capture (made once), and the MIC TEST's player.
func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var bus := AudioServer.get_bus_index(BUS)
	if bus == -1:
		AudioServer.add_bus()
		bus = AudioServer.bus_count - 1
		AudioServer.set_bus_name(bus, BUS)
		AudioServer.set_bus_mute(bus, true)          # captured, never heard here
		var cap := AudioEffectCapture.new()
		cap.buffer_length = 0.5                      # half a second between two reads at most
		AudioServer.add_bus_effect(bus, cap)
	_capture = AudioServer.get_bus_effect(bus, 0) as AudioEffectCapture
	_mic = AudioStreamPlayer.new()
	_mic.stream = AudioStreamMicrophone.new()
	_mic.bus = BUS
	add_child(_mic)
	_out = _new_player()
	_talkers[ME] = _talker_entry(_out)


func _exit_tree() -> void:
	if _mic != null and capturing:
		_mic.stop()
	capturing = false


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_PAUSED:
		_paused = true                   # no microphone in the background
	elif what == NOTIFICATION_APPLICATION_RESUMED:
		_paused = false                  # (the input starts afresh)


func _new_player() -> AudioStreamPlayer:
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = RATE
	gen.buffer_length = 0.6
	var p := AudioStreamPlayer.new()
	p.stream = gen
	p.bus = OUT_BUS
	add_child(p)
	return p


func _talker_entry(p: AudioStreamPlayer) -> Dictionary:
	return {"player": p, "gen": null, "queue": [], "wait": 0.0, "room": 0, "ms": Time.get_ticks_msec()}


func _want_capture() -> bool:
	if not is_inside_tree() or _paused or not mic_allowed():
		return false
	if test_loop:
		return true
	if sends(mic_mode(), channel(), mates()) == "":
		return false
	return not push_to_talk() or ptt_held


func _set_capture(on: bool) -> void:
	if not on and sending and not test_loop:
		_read_source(0.0)
		if _pending.size() > 0:
			_send(encode(_pending))     # the last words
	capturing = on
	sending = false
	level = 0.0
	_pending.clear()
	_acc = 0.0
	_acc_n = 0
	_phase = 0.0
	_tone_due = 0.0
	_gate = {"open": false, "hang": 0}
	_prev = PackedByteArray()
	if not tone_source and _mic != null:
		if on:
			if _capture:
				_capture.clear_buffer()
			_mic.play()
		else:
			_mic.stop()
	changed.emit()


func _process(delta: float) -> void:
	for c: Cloud in [Game.cloud, Game.lan, Game.session]:
		if c != null and is_instance_valid(c) and not c.voice_from.is_connected(on_voice):
			c.voice_from.connect(on_voice)
	var want := _want_capture()
	if want != capturing:
		_set_capture(want)
	if capturing:
		_read_source(delta)
		while _pending.size() >= FRAME_SAMPLES:
			_frame(_pending.slice(0, FRAME_SAMPLES))
			_pending = _pending.slice(FRAME_SAMPLES)
	var now := Time.get_ticks_msec()
	for id: String in _talkers.keys():
		var t: Dictionary = _talkers[id]
		_feed(t, delta)
		if id != ME and (t.queue as Array).is_empty() and now - int(t.ms) > QUIET_FREE_MS:
			_drop_talker(id)
	if tone_source:
		_log_t += delta
		if _log_t >= 3.0:
			_log_t = 0.0
			print("VOICE ch=%s mic=%s spk=%s capturing=%s sent=%d heard=%d talkers=%d" % [channel(), MODE_NAMES[mic_mode()],
				MODE_NAMES[speaker_mode()], capturing, frames_sent, frames_heard, _talkers.size() - 1])


## The source's new samples into _pending: the microphone's capture, or the test tone.
func _read_source(delta: float) -> void:
	if not tone_source:
		_read_mic()
		return
	_tone_due += delta * RATE
	while _tone_due >= 1.0:
		_tone_due -= 1.0
		_tone_t += 1.0 / RATE
		var on := fmod(_tone_t, TONE_ON_S + TONE_OFF_S) < TONE_ON_S
		_pending.append(0.4 * sin(TAU * TONE_HZ * _tone_t) if on else 0.0)


## One 100 ms frame of the source: the level, the gate, then out (or back here in the MIC TEST).
func _frame(samples: PackedFloat32Array) -> void:
	level = rms_of(samples)
	var enc := encode(samples)
	if test_loop:
		sending = level >= GATE_OPEN
		_queue_frame(ME, enc)
		frame_ready.emit(enc)
		return
	var was := sending
	sending = ptt_held if push_to_talk() else gate_next(_gate, level)
	if sending:
		if not was and not _prev.is_empty() and not push_to_talk():
			_send(_prev)                 # the start of the first word
		_send(enc)
		frame_ready.emit(enc)
		_heard[ME] = Time.get_ticks_msec()
	_prev = enc


func _send(frame: PackedByteArray) -> void:
	var kind := sends(mic_mode(), channel(), mates())
	match channel():
		"match":
			if kind != "":
				Game.session.send_voice(frame, kind == "group")
				frames_sent += 1
		"group":
			if kind != "" and Game.cloud.send_group_voice(frame, kind == "group"):
				frames_sent += 1


## A frame from another player (Cloud.voice_from): played unless the speaker mode, a mute or a block
## says no (GROUP: only a teammate's, `mate`).
func on_voice(frame: PackedByteArray, from: String, mate: bool) -> void:
	if from == ME or not hears(mate, speaker_mode(), is_muted(from)) or not frame_ok(frame):
		return
	_queue_frame(from, frame)


func _queue_frame(id: String, frame: PackedByteArray) -> void:
	if not is_inside_tree():
		return
	var now := Time.get_ticks_msec()
	if not _talkers.has(id):
		if _talkers.size() > MAX_TALKERS:
			var oldest := ""
			for k: String in _talkers:
				if k != ME and (oldest == "" or int(_talkers[k].ms) < int(_talkers[oldest].ms)):
					oldest = k
			_drop_talker(oldest)
		_talkers[id] = _talker_entry(_new_player())
	var t: Dictionary = _talkers[id]
	var q: Array = t.queue
	q.append(frame)
	while q.size() > MAX_QUEUE:
		q.pop_front()                    # far behind: catch up
	t.ms = now
	if id != ME:
		_heard[id] = now


func _drop_talker(id: String) -> void:
	if id == ME or not _talkers.has(id):
		return
	var p := _talkers[id].player as AudioStreamPlayer
	_talkers.erase(id)
	if p != null and is_instance_valid(p):
		p.queue_free()


## The captured sound so far, cut to 8 kHz mono (each 8 kHz sample the mean of its input frames).
func _read_mic() -> void:
	if _capture == null:
		return
	var avail := _capture.get_frames_available()
	if avail <= 0:
		return
	var buf := _capture.get_buffer(avail)
	var ratio := float(RATE) / AudioServer.get_mix_rate()
	for f in buf:
		_acc += (f.x + f.y) * 0.5
		_acc_n += 1
		_phase += ratio
		if _phase >= 1.0:
			_phase -= 1.0
			_pending.append(clampf(_acc / _acc_n, -1.0, 1.0))
			_acc = 0.0
			_acc_n = 0


## A talker's frames into its generator. After its sound ran dry (between two sentences)
## START_FRAMES wait in the queue first, or the frames that came once START_WAIT_S passed, so
## uneven packets do not chop the next words up. The generator plays silence when it has nothing.
func _feed(t: Dictionary, delta: float) -> void:
	var q: Array = t.queue
	if q.is_empty():
		t.wait = 0.0
		return
	t.wait = float(t.wait) + delta
	var gen := t.gen as AudioStreamGeneratorPlayback
	if gen == null:
		var p := t.player as AudioStreamPlayer
		if p == null or not p.is_inside_tree():
			return
		p.play()
		gen = p.get_stream_playback() as AudioStreamGeneratorPlayback
		if gen == null:
			return
		t.gen = gen
		t.room = gen.get_frames_available()
	var buffered := int(t.room) - gen.get_frames_available()
	if buffered < FRAME_SAMPLES / 4 and q.size() < START_FRAMES and float(t.wait) < START_WAIT_S:
		return
	while not q.is_empty() and gen.get_frames_available() >= FRAME_SAMPLES:
		var samples := decode(q.pop_front())
		var frames := PackedVector2Array()
		frames.resize(samples.size())
		for i in samples.size():
			frames[i] = Vector2(samples[i], samples[i])
		gen.push_buffer(frames)
		frames_heard += 1
