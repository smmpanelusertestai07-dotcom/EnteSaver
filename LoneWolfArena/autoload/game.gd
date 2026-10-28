extends Node
## Global state: settings, profile, HUD layout and persistence.
## Everything is stored locally as JSON in user:// (offline, no database).

const SETTINGS_PATH := "user://settings.json"
const PROFILE_PATH := "user://profile.json"
const HUD_PATH := "user://hud_layout.json"

const SETTINGS_VERSION := 2
const DEFAULT_SETTINGS := {
	"settings_version": SETTINGS_VERSION,
	"graphics": 1,
	"fps": 60,
	"show_fps": false,
	"vibration": true,
	"damage_numbers": true,
	"sens_general": 100,
	"sens_reddot": 100,
	"sens_sniper": 71,
	"sens_fire": 100,
	"aim_assist": true,
	"aim_assist_strength": 70,
	"aim_precision": 0,
	"hold_fire_scope": true,
	"left_fire": 0,
	"reload_on_crosshair": true,
	"run_mode": 2,
	"dynamic_joystick": true,
	"dynamic_crosshair": true,
	"crosshair_color": 0,
	"crosshair_size": 50,
	"vol_master": 85,
	"vol_sfx": 90,
	"vol_music": 45,
	"difficulty": 1,
	"last_pick": "ar",
}

## Valid ranges of the numeric settings. Values outside them (an edited or corrupted settings
## file) are clamped on load and on save, so nothing can index past a list or overdrive a value.
const SETTING_RANGES := {
	"graphics": [0, 3], "sens_general": [1, 200], "sens_reddot": [1, 200], "sens_sniper": [1, 200],
	"sens_fire": [1, 200], "aim_assist_strength": [0, 100], "aim_precision": [0, 2], "left_fire": [0, 2],
	"run_mode": [0, 2], "crosshair_color": [0, 3], "crosshair_size": [0, 100], "vol_master": [0, 100],
	"vol_sfx": [0, 100], "vol_music": [0, 100], "difficulty": [0, 2],
}
const FPS_OPTIONS := [30, 60, 90]

## The crosshair's idle colour (it always turns red on an enemy).
const CROSSHAIR_COLORS := [Color(1, 1, 1), Color(0.25, 1.0, 0.35), Color(1.0, 0.88, 0.2), Color(0.25, 0.9, 1.0)]
const CROSSHAIR_COLOR_NAMES := ["WHITE", "GREEN", "YELLOW", "CYAN"]
const AIM_PRECISION_NAMES := ["DEFAULT", "PRECISE ON SCOPE", "FULL CONTROL"]
const LEFT_FIRE_NAMES := ["ALWAYS", "WHEN SCOPED", "OFF"]
const RUN_MODE_NAMES := ["TAP", "DRAG", "MIXED"]
const DIFFICULTY_NAMES := ["EASY", "NORMAL", "HARD"]
const GRAPHICS_NAMES := ["SMOOTH", "STANDARD", "ULTRA", "MAX"]
const XP_PER_LEVEL := 500

var settings: Dictionary = {}
var profile: Dictionary = {"name": "ROOKIE", "bundle": "default", "matches": 0, "wins": 0, "kills": 0, "xp": 0}
var hud_layout: Dictionary = {}
var last_result: Dictionary = {}

## Automation (tests / screenshot runs from the editor binary): user args after "--".
## Ignored in exported builds, so an installed game can't be started in a test mode.
var autotest := ""
var shots_dir := ""

signal settings_changed


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	settings = DEFAULT_SETTINGS.duplicate(true)
	var saved: Variant = _load_json(SETTINGS_PATH)
	if saved is Dictionary and int((saved as Dictionary).get("settings_version", 1)) < SETTINGS_VERSION:
		# v1 used 0-100 sensitivities and a different crosshair palette: keep the rest.
		for k in ["sens_general", "sens_reddot", "sens_fire", "crosshair_color", "left_fire", "aim_assist_strength", "settings_version"]:
			(saved as Dictionary).erase(k)
	_merge_into(settings, saved)
	settings.settings_version = SETTINGS_VERSION
	_sanitize_settings()
	_load_profile()
	var hud: Variant = _load_json(HUD_PATH)
	hud_layout = hud if hud is Dictionary else {}
	if not OS.has_feature("template"):
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--autotest="):
				autotest = arg.substr(11)
			elif arg.begins_with("--shots="):
				shots_dir = arg.substr(8)
	_setup_audio_buses()
	apply_settings()
	if autotest != "":
		var runner: Node = load("res://scripts/autotest.gd").new()
		runner.name = "AutoTest"
		add_child(runner)


func _merge_into(target: Dictionary, src: Variant) -> void:
	if not src is Dictionary:
		return
	for k in src:
		if not target.has(k):
			continue
		var cur: Variant = target[k]
		var v: Variant = src[k]
		match typeof(cur):
			TYPE_INT:
				if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
					target[k] = int(v)
			TYPE_FLOAT:
				if typeof(v) == TYPE_FLOAT or typeof(v) == TYPE_INT:
					target[k] = float(v)
			_:
				if typeof(v) == typeof(cur):
					target[k] = v


func _sanitize_settings() -> void:
	for k in SETTING_RANGES:
		var r: Array = SETTING_RANGES[k]
		settings[k] = clampi(int(settings[k]), int(r[0]), int(r[1]))
	if not int(settings.fps) in FPS_OPTIONS:
		settings.fps = 60
	if not String(settings.last_pick) in Weapons.PICKABLE:
		settings.last_pick = Weapons.DEFAULT_PICK


func _load_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var data: Variant = JSON.parse_string(f.get_as_text())
	return data if data is Dictionary else {}


func _save_json(path: String, data: Dictionary) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data, "\t"))


func save_settings() -> void:
	_sanitize_settings()
	_save_json(SETTINGS_PATH, settings)
	apply_settings()
	settings_changed.emit()


func reset_settings() -> void:
	settings = DEFAULT_SETTINGS.duplicate(true)
	save_settings()


## The profile (level, XP, wins) is signed with a device-bound HMAC; an edited file is
## rejected and the profile starts fresh (keeping only the player name).
func _load_profile() -> void:
	var raw: Variant = _load_json(PROFILE_PATH)
	if not raw is Dictionary or (raw as Dictionary).is_empty():
		return
	var check := Guard.verify_dict(raw)
	if check.ok:
		_merge_into(profile, check.data)
		if check.unsigned:
			save_profile()
	else:
		var keep_name: Variant = (raw as Dictionary).get("name", profile.name)
		if typeof(keep_name) == TYPE_STRING:
			profile.name = String(keep_name).substr(0, 14)
		Guard.flag("save")
		save_profile()


func save_profile() -> void:
	_save_json(PROFILE_PATH, Guard.sign_dict(profile))


func save_hud_layout(layout: Dictionary) -> void:
	hud_layout = layout.duplicate(true)
	_save_json(HUD_PATH, hud_layout)


func reset_hud_layout() -> void:
	hud_layout = {}
	_save_json(HUD_PATH, hud_layout)


func crosshair_color() -> Color:
	return CROSSHAIR_COLORS[clampi(int(settings.crosshair_color), 0, CROSSHAIR_COLORS.size() - 1)]


func _setup_audio_buses() -> void:
	for bus_name in ["Music", "SFX"]:
		if AudioServer.get_bus_index(bus_name) == -1:
			AudioServer.add_bus()
			var idx := AudioServer.bus_count - 1
			AudioServer.set_bus_name(idx, bus_name)
			AudioServer.set_bus_send(idx, "Master")


func apply_settings() -> void:
	Engine.max_fps = int(settings.fps)
	_set_bus("Master", settings.vol_master)
	_set_bus("Music", settings.vol_music)
	_set_bus("SFX", settings.vol_sfx)


func _set_bus(bus_name: String, percent: float) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx >= 0:
		var lin := clampf(percent / 100.0, 0.0, 1.0)
		AudioServer.set_bus_mute(idx, lin <= 0.001)
		AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(lin, 0.001)))


func vibrate(ms: int) -> void:
	if settings.vibration and OS.has_feature("mobile"):
		Input.vibrate_handheld(ms)


func record_match(result: Dictionary) -> void:
	last_result = result
	profile.matches = int(profile.matches) + 1
	if result.get("won", false):
		profile.wins = int(profile.wins) + 1
	profile.kills = int(profile.kills) + int(result.get("kills", 0))
	profile.xp = int(profile.xp) + int(result.get("xp", 0))
	save_profile()


func level() -> int:
	return 1 + int(profile.xp) / XP_PER_LEVEL


func level_progress() -> float:
	return float(int(profile.xp) % XP_PER_LEVEL) / float(XP_PER_LEVEL)


var _marks := {}

## Logs a progress marker once per session (the emulator test reads these from logcat).
func mark(what: String) -> void:
	if not _marks.has(what):
		_marks[what] = true
		print("[LoneWolf] ", what)


func goto_lobby() -> void:
	get_tree().paused = false
	Engine.time_scale = 1.0
	get_tree().change_scene_to_file("res://scenes/lobby.tscn")


func goto_arena() -> void:
	get_tree().paused = false
	Engine.time_scale = 1.0
	get_tree().change_scene_to_file("res://scenes/arena.tscn")


func goto_hud_editor() -> void:
	get_tree().paused = false
	Engine.time_scale = 1.0
	get_tree().change_scene_to_file("res://scenes/hud_editor.tscn")
