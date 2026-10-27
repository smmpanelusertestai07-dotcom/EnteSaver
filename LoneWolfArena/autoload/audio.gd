extends Node
## Sound effects and music. Streams are loaded lazily from res://assets/audio.

const DIR := "res://assets/audio/"
const LOOPING := ["lobby_music", "match_ambience", "heal"]

var _cache := {}
var _players: Array[AudioStreamPlayer] = []
var _music: AudioStreamPlayer
var _ambience: AudioStreamPlayer


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	for i in 14:
		var p := AudioStreamPlayer.new()
		p.bus = "SFX"
		add_child(p)
		_players.append(p)
	_music = AudioStreamPlayer.new()
	_music.bus = "Music"
	add_child(_music)
	_ambience = AudioStreamPlayer.new()
	_ambience.bus = "SFX"
	add_child(_ambience)


func stream(sound_name: String) -> AudioStream:
	if _cache.has(sound_name):
		return _cache[sound_name]
	var s: AudioStream = null
	for ext in [".ogg", ".wav"]:
		var path: String = DIR + sound_name + ext
		if ResourceLoader.exists(path):
			s = load(path)
			break
	if s != null and sound_name in LOOPING:
		_make_looping(s)
	_cache[sound_name] = s
	return s


func _make_looping(s: AudioStream) -> void:
	if s is AudioStreamWAV:
		var w := s as AudioStreamWAV
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_begin = 0
		w.loop_end = int(w.get_length() * w.mix_rate)
	elif s is AudioStreamOggVorbis:
		(s as AudioStreamOggVorbis).loop = true


func play(sound_name: String, volume_db := 0.0, pitch := 1.0) -> void:
	var s := stream(sound_name)
	if s == null:
		return
	var p: AudioStreamPlayer = null
	for cand in _players:
		if not cand.playing:
			p = cand
			break
	if p == null:
		p = _players[randi() % _players.size()]
	p.stream = s
	p.volume_db = volume_db
	p.pitch_scale = pitch
	p.play()


func play_at(sound_name: String, pos: Vector3, volume_db := 0.0, pitch := 1.0, max_distance := 90.0) -> void:
	var s := stream(sound_name)
	if s == null:
		return
	var tree := get_tree()
	if tree == null or tree.current_scene == null:
		return
	var p := AudioStreamPlayer3D.new()
	p.stream = s
	p.bus = "SFX"
	p.volume_db = volume_db
	p.pitch_scale = pitch
	p.max_distance = max_distance
	p.unit_size = 8.0
	tree.current_scene.add_child(p)
	p.global_position = pos
	p.finished.connect(p.queue_free)
	p.play()


func play_music(sound_name: String, volume_db := -3.0) -> void:
	var s := stream(sound_name)
	if s == null:
		_music.stop()
		return
	if _music.stream == s and _music.playing:
		return
	_music.stream = s
	_music.volume_db = -40.0
	_music.play()
	var tw := create_tween()
	tw.tween_property(_music, "volume_db", volume_db, 1.2)


func stop_music() -> void:
	_music.stop()


func play_ambience(sound_name: String, volume_db := -10.0) -> void:
	var s := stream(sound_name)
	if s == null:
		return
	_ambience.stream = s
	_ambience.volume_db = -40.0
	_ambience.play()
	var tw := create_tween()
	tw.tween_property(_ambience, "volume_db", volume_db, 1.5)


func stop_ambience() -> void:
	_ambience.stop()
