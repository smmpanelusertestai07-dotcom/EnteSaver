class_name NetVoice
extends Node
## Push-to-talk voice in an online match (experimental; setting VOICE CHAT, off by default; on
## Android turning it on asks for the microphone, RECORD_AUDIO). Only while HOLD TO TALK is held
## (HudNet), the microphone plays into the muted bus BUS through an AudioEffectCapture; the sound
## is cut to 8 kHz mono and packed as IMA ADPCM (4 bits a sample) in FRAME_MS frames (`encode`),
## each sent over the match room's encryption (Cloud.send_voice, rate limited on both sides) and
## never stored. The other phone keeps a small jitter buffer (START_FRAMES before it starts,
## MAX_QUEUE at most) and plays it through an AudioStreamGenerator; the speaker button mutes it.

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
const MIC_PERMISSION := "android.permission.RECORD_AUDIO"

const STEPS := [7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45, 50, 55, 60, 66, 73, 80,
	88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658, 724,
	796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428,
	4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899, 15289, 16818, 18500, 20350, 22385,
	24623, 27086, 29794, 32767]
const INDEX_STEP := [-1, -1, -1, -1, 2, 4, 6, 8]

signal frame_ready(frame: PackedByteArray)

var talking := false
var muted := false                 # the speaker button: the other phone's voice is not played
var _capture: AudioEffectCapture
var _mic: AudioStreamPlayer
var _out: AudioStreamPlayer
var _gen: AudioStreamGeneratorPlayback
var _pending := PackedFloat32Array()   # 8 kHz samples not sent yet
var _acc := 0.0                        # resampling: input frames summed into the next 8 kHz sample
var _acc_n := 0
var _phase := 0.0
var _queue: Array = []                 # frames from the other phone waiting to play
var _wait_t := 0.0                     # how long frames have been waiting in the queue
var _room := 0                         # the generator's free frames when it is empty


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

## The microphone's muted bus with its capture (made once), and the player for the other phone.
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
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = RATE
	gen.buffer_length = 0.6
	_out = AudioStreamPlayer.new()
	_out.stream = gen
	add_child(_out)


## HOLD TO TALK pressed / released: the microphone runs only while it is held.
func set_talking(on: bool) -> void:
	if on == talking or _mic == null:
		return
	talking = on
	if on:
		_pending.clear()
		_acc = 0.0
		_acc_n = 0
		_phase = 0.0
		if _capture:
			_capture.clear_buffer()
		_mic.play()
	else:
		_read_mic()
		if _pending.size() > 0:
			frame_ready.emit(encode(_pending))       # the last words
		_pending.clear()
		_mic.stop()


## A frame from the other phone, played after a short buffer (dropped while muted).
func play_frame(frame: PackedByteArray) -> void:
	if muted or not frame_ok(frame):
		return
	_queue.append(frame)
	while _queue.size() > MAX_QUEUE:
		_queue.pop_front()                       # far behind: catch up


func _process(delta: float) -> void:
	if talking:
		_read_mic()
		while _pending.size() >= FRAME_SAMPLES:
			frame_ready.emit(encode(_pending.slice(0, FRAME_SAMPLES)))
			_pending = _pending.slice(FRAME_SAMPLES)
	_wait_t = _wait_t + delta if not _queue.is_empty() else 0.0
	_feed_speaker()


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


## The other phone's frames into the generator. After the sound ran dry (between two presses of
## TALK) START_FRAMES wait in the queue first, or the frames that came once START_WAIT_S passed, so
## uneven packets do not chop the next words up. The generator plays silence when it has nothing.
func _feed_speaker() -> void:
	if _out == null or _queue.is_empty():
		return
	if _gen == null:
		_out.play()
		_gen = _out.get_stream_playback() as AudioStreamGeneratorPlayback
		if _gen == null:
			return
		_room = _gen.get_frames_available()
	var buffered := _room - _gen.get_frames_available()
	if buffered < FRAME_SAMPLES / 4 and _queue.size() < START_FRAMES and _wait_t < START_WAIT_S:
		return
	while not _queue.is_empty() and _gen.get_frames_available() >= FRAME_SAMPLES:
		var samples := decode(_queue.pop_front())
		var frames := PackedVector2Array()
		frames.resize(samples.size())
		for i in samples.size():
			frames[i] = Vector2(samples[i], samples[i])
		_gen.push_buffer(frames)
