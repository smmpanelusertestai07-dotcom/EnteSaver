extends Node
## Global state: settings, profile, HUD layout and persistence.
## Everything is stored locally as JSON in user:// (on this phone only: no server, no database).
## Automated runs (--autotest) read and write none of it: they start from the defaults and keep
## their changes in memory, so a test never changes the player's saves and parallel runs share
## nothing.

const SETTINGS_PATH := "user://settings.json"
const PROFILE_PATH := "user://profile.json"
const HUD_PATH := "user://hud_layout.json"

## The two modes START plays (the setting "mode", see `mode`), both on the one map CARGO CAGE:
## TRAINING GROUND is 1 vs a bot (EASY, NORMAL, HARD) or the target dummy (`practice`), LONE
## WOLF the online 1 vs 1 (Cloud: START opens the ONLINE window). TRAINING GROUND is the
## default: on a new install START plays a bot match (the CI emulator test taps START and
## expects one).
const MODE_NAMES := {"training": "TRAINING GROUND", "lonewolf": "LONE WOLF"}
const DEFAULT_MODE := "training"
## A match is first to ROUNDS_TO_WIN rounds (the reference mode: first to 5, best of 9); a custom
## room sets its own (see rounds_to_win()).
const ROUNDS_TO_WIN := 5

const SETTINGS_VERSION := 5
const DEFAULT_SETTINGS := {
	"settings_version": SETTINGS_VERSION,
	"mode": DEFAULT_MODE,
	"graphics": 1,
	"graphics_auto": true,        # the game picks the graphics level for the phone (see AUTO graphics)
	"graphics_auto_done": false,  # AUTO has measured this phone (until then the next lobby or match does)
	"fps": 60,
	"show_fps": false,
	"sens_general": 100,
	"sens_reddot": 100,
	"sens_2x": 100,               # aiming through a 2x scope (Player.sens_key)
	"sens_sniper": 71,
	"sens_freelook": 100,         # free look (the eye button)
	"sens_fire": 100,             # a drag that starts on the fire button, % of the view's own
	"dynamic_joystick": false,
	"vibration": true,
	"crosshair_color": 0,         # index into CROSSHAIR_COLORS
	"crosshair_size": 100,        # % of the standard crosshair (CROSSHAIR_SCALE)
	"aim_precision": 0,           # aim assist: 0 always, 1 not while aiming down a sight, 2 never (Player.assist_allowed)
	"left_fire": 0,               # the left fire button: 0 always, 1 only while aiming
	"visual_effects": true,       # muzzle / explosion lights and full particle bursts (Effects.configure)
	"vol_master": 85,
	"vol_sfx": 90,
	"vol_music": 45,
	"difficulty": 1,
	"last_pick": "ar",
}

## Behaviour that is not a setting (the settings screen keeps to graphics, sensitivity,
## joystick, custom HUD and sound): always these values, whatever an older settings file says.
const FIXED_SETTINGS := {
	"damage_numbers": true, "hold_fire_scope": true, "reload_on_crosshair": true, "run_mode": 2,
	"dynamic_crosshair": true,
}
## Settings that FIXED_SETTINGS held until version 4, whatever the file said: a file from then
## has no say in them, they start from their defaults (what version 4 played with).
const FIXED_UNTIL_V4 := ["show_fps", "vibration", "crosshair_color", "crosshair_size", "sens_fire"]

## Valid ranges of the numeric settings. Values outside them (an edited or corrupted settings
## file) are clamped on load and on save, so nothing can index past a list or overdrive a value.
const SETTING_RANGES := {
	"graphics": [0, 3], "sens_general": [1, 200], "sens_reddot": [1, 200], "sens_2x": [1, 200],
	"sens_sniper": [1, 200], "sens_freelook": [1, 200], "sens_fire": [1, 200], "vol_master": [0, 100],
	"vol_sfx": [0, 100], "vol_music": [0, 100], "difficulty": [0, 2], "crosshair_color": [0, 3],
	"crosshair_size": [50, 150], "aim_precision": [0, 2], "left_fire": [0, 1],
}
## On/off settings: anything but true or false falls back to the default.
const BOOL_SETTINGS := ["graphics_auto", "graphics_auto_done", "show_fps", "dynamic_joystick", "vibration", "visual_effects"]
## Every frame rate the setting can hold; the settings offer those the screen can show
## (fps_choices).
const FPS_OPTIONS := [30, 60, 90, 120]

## The crosshair's idle colour (it always turns red on an enemy).
const CROSSHAIR_COLORS := [Color(1, 1, 1), Color(0.25, 1.0, 0.35), Color(1.0, 0.88, 0.2), Color(0.25, 0.9, 1.0)]
## The crosshair's scale at crosshair_size 100: the size the HUD drew before it was a setting.
const CROSSHAIR_SCALE := 1.05
const DIFFICULTY_NAMES := ["EASY", "NORMAL", "HARD"]
const GRAPHICS_NAMES := ["LOW", "MEDIUM", "HIGH", "EXTREME"]
const XP_PER_LEVEL := 500

const PROFILE_VERSION := 3
## A new player's profile. Loading keeps only these keys, with these value types (see
## _merge_into), so every key a save may hold is listed here; the HMAC signature covers the whole
## dictionary. Player ids are the 32 hex characters of Cloud.my_id. The profile page
## (scripts/lobby_profile.gd) shows them: CAREER the counters, HISTORY "history", NAME CARD the
## avatar, banner and signature, BLOCKED "blocked".
const DEFAULT_PROFILE := {
	"profile_version": PROFILE_VERSION,
	"name": "ROOKIE", "bundle": "default", "matches": 0, "wins": 0, "kills": 0, "xp": 0,
	"name_set": false,           # false until the player chose a name (also on installs from before the prompt)
	"guest_ok": false,           # the guest login was passed (version 1 profiles: whoever had chosen a name)
	"created": 0,                # unix time of the profile's first save (0: never saved)
	"avatar": "emblem",          # profile picture: the emblem or an outfit's portrait (avatar_ids)
	"banner": "default",         # name card background (BANNERS)
	"signature": "",             # a line under the name: clean_name characters, SIGNATURE_MAX at most
	# Lifetime numbers of counted matches, like Fighter.stats: shots and hits per trigger pull,
	# headshots = hits with a head pellet, damage dealt in HP, time_played in seconds.
	"deaths": 0, "headshots": 0, "damage": 0, "shots": 0, "hits": 0, "rounds_won": 0, "rounds_lost": 0,
	"time_played": 0,
	"modes": {"training": {"matches": 0, "wins": 0, "kills": 0}, "lonewolf": {"matches": 0, "wins": 0, "kills": 0}},
	"friends": {},               # id -> {"name"}: players who accepted a friend request (online)
	"friend_in": {},             # id -> {"name", "t"}: friend requests to answer (t: unix time)
	"friend_out": {},            # id -> {"name", "t"}: friend requests sent, not answered yet
	# ids: friend requests taken back while offline (a block): the relay's waiting copy is deleted
	# at the next connection (Cloud.withdraw_request)
	"withdrawn": [],
	"recent": [],                # [{"id", "name", "t"}]: the latest online opponents, newest first
	# [{"id", "name" ("" when unknown), "t"}]: blocked players, oldest first; their invites and
	# friend requests are ignored (see block())
	"blocked": [],
	# The last counted matches, newest first (record_match, MAX_HISTORY at most): [{"result" (won,
	# lost or draw), "mode", "enemy" (name), "id" (an online opponent's id, else ""), "score" and
	# "enemy_score" (rounds), "kills", "damage", "headshots", "t" (unix time)}].
	"history": [],
}
## Lifetime counters (whole numbers, 0..COUNTER_MAX) and the ones kept per mode (in "modes").
const PROFILE_COUNTERS := ["matches", "wins", "kills", "xp", "deaths", "headshots", "damage", "shots", "hits",
	"rounds_won", "rounds_lost", "time_played"]
const MODE_COUNTERS := ["matches", "wins", "kills"]
const COUNTER_MAX := 1000000000
const UNIX_MAX := 4102444800        # 2100-01-01: the latest time a profile entry may carry
const NAME_MAX := 14
const SIGNATURE_MAX := 30
const MAX_FRIENDS := 50
const MAX_REQUESTS := 50            # each of friend_in and friend_out
const MAX_RECENT := 20
const MAX_BLOCKED := 50
const MAX_HISTORY := 20
const HISTORY_RESULTS := ["won", "lost", "draw"]
## The name card backgrounds, in the order of their art assets/ui/banners/banner_<n>.png
## (tools/media/make_banners.py: EMBER RIDGE, GOLD RUSH, HIVE, CONTOUR, SHARDS, SCOPE; see
## Login.banner_texture).
const BANNERS := ["default", "gold_rush", "hive", "contour", "shards", "scope"]

var settings: Dictionary = {}
## The mode START plays (a key of MODE_NAMES), kept as the setting "mode": save_settings()
## stores it. Anything else sets the default mode.
var mode: String:
	get:
		return String(settings.get("mode", DEFAULT_MODE))
	set(value):
		settings["mode"] = value if MODE_NAMES.has(value) else DEFAULT_MODE
var profile: Dictionary = DEFAULT_PROFILE.duplicate(true)
var hud_layout: Dictionary = {}
var last_result: Dictionary = {}

## Automation (tests / screenshot runs from the editor binary): user args after "--".
## Ignored in exported builds, so an installed game can't be started in a test mode.
var autotest := ""
var shots_dir := ""
## TRAINING GROUND against the target dummy (the lobby's DUMMY chip) instead of a bot: a dummy
## with endless HP, no zone, no clock, nothing recorded. The chips set it and it stays chosen for
## this session; an online match ignores it.
var practice := false
## The next arena run is a match against another phone (LONE WOLF): `session` is the Cloud
## (internet, see scripts/cloud.gd) that connected the two.
var online := false
var session: Cloud
## The custom room's rules the next online match is played with ({} = a plain duel); see
## Cloud.ROOM_RULES.
var room_rules := {}
var cloud: Cloud


## The online service (made on first use; it outlives scene changes).
func cloud_service() -> Cloud:
	if cloud == null:
		cloud = Cloud.new()
		add_child(cloud)
	return cloud

signal settings_changed


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if not OS.has_feature("template"):
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--autotest="):
				autotest = arg.substr(11)
			elif arg.begins_with("--shots="):
				shots_dir = arg.substr(8)
	settings = DEFAULT_SETTINGS.duplicate(true)
	_apply_saved_settings(_load_json(SETTINGS_PATH))
	if bool(settings.graphics_auto) and not bool(settings.graphics_auto_done):
		start_auto_graphics()        # the first run: a guess now, measured in the lobby
	_load_profile()
	var hud: Variant = _load_json(HUD_PATH)
	hud_layout = hud if hud is Dictionary else {}
	_setup_audio_buses()
	apply_settings()
	if autotest == "":
		Licences.publish.call_deferred()
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


## Takes a saved settings file (as read from settings.json) over `settings`: brought up to this
## version, merged (unknown keys and wrongly typed values are dropped), the fixed behaviour forced
## and every value checked.
func _apply_saved_settings(saved: Variant) -> void:
	if saved is Dictionary:
		_migrate_settings(saved as Dictionary)
	_merge_into(settings, saved)
	settings.merge(FIXED_SETTINGS, true)
	settings.settings_version = SETTINGS_VERSION
	_sanitize_settings()


## Brings a settings file from an older version up to SETTINGS_VERSION, in place, before it is
## merged.
func _migrate_settings(saved: Dictionary) -> void:
	var version: Variant = saved.get("settings_version", 1)
	if not (version is int or version is float):
		version = 1
	if int(version) < 2:
		# v1 used 0-100 sensitivities and a different crosshair palette: keep the rest.
		for k in ["sens_general", "sens_reddot", "sens_fire", "settings_version"]:
			saved.erase(k)
	if int(version) < 4:
		# v4: the joystick stays put by default (the reference's default), as on a new install.
		saved.erase("dynamic_joystick")
	if int(version) < 5:
		# v5: the FPS counter, vibration, crosshair colour and size and the fire-button drag are
		# settings now; they start as version 4 played (crosshair_size 100 is that size). Free
		# look and the 2x scope get their own sensitivity, which starts at the one they turned
		# with (General, Red Dot). AUTO graphics stays off for a player who had picked a level
		# other than the default.
		for k in FIXED_UNTIL_V4:
			saved.erase(k)
		for pair: Array in [["sens_freelook", "sens_general"], ["sens_2x", "sens_reddot"]]:
			if saved.has(pair[1]):
				saved[pair[0]] = saved[pair[1]]
		var g: Variant = saved.get("graphics")
		if (g is int or g is float) and int(g) != int(DEFAULT_SETTINGS.graphics):
			saved["graphics_auto"] = false


func _sanitize_settings() -> void:
	for k in SETTING_RANGES:
		var r: Array = SETTING_RANGES[k]
		settings[k] = clampi(int(settings[k]), int(r[0]), int(r[1]))
	for k in BOOL_SETTINGS:
		if not settings.get(k) is bool:
			settings[k] = DEFAULT_SETTINGS[k]
	if not int(settings.fps) in FPS_OPTIONS:
		settings.fps = 60
	if not String(settings.last_pick) in Weapons.PICKABLE:
		settings.last_pick = Weapons.DEFAULT_PICK
	if not MODE_NAMES.has(settings.get("mode")):
		settings.mode = DEFAULT_MODE


## A mode's player-facing name ("TRAINING GROUND", "LONE WOLF"), the current mode's by default.
func mode_name(m := "") -> String:
	return String(MODE_NAMES.get(m if m != "" else mode, MODE_NAMES[DEFAULT_MODE]))


## The rounds a match is played to ("FIRST TO n"): ROUNDS_TO_WIN, online a custom room's own
## number (Cloud.ROOM_RULES, 1 to 7). Test runs of the editor binary may set LW_ROUNDS_TO_WIN
## (never an exported game). The arena plays by it; the lobby and the match card show it.
func rounds_to_win(online_match := false) -> int:
	var n := ROUNDS_TO_WIN
	if not OS.has_feature("template") and OS.get_environment("LW_ROUNDS_TO_WIN") != "":
		n = maxi(int(OS.get_environment("LW_ROUNDS_TO_WIN")), 1)     # tests: shorter matches
	if online_match and not room_rules.is_empty():
		n = clampi(int(room_rules.get("rounds", ROUNDS_TO_WIN)), 1, 7)
	return n


func _load_json(path: String) -> Variant:
	if autotest != "" or not FileAccess.file_exists(path):
		return {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return {}
	var data: Variant = JSON.parse_string(f.get_as_text())
	return data if data is Dictionary else {}


func _save_json(path: String, data: Dictionary) -> void:
	if autotest != "":
		return
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data, "\t"))


func save_settings() -> void:
	_sanitize_settings()
	_save_json(SETTINGS_PATH, settings)
	apply_settings()
	settings_changed.emit()


## The profile (level, XP, wins) is signed with a device-bound HMAC; an edited or unsigned file
## is rejected and the profile starts fresh (keeping only the player name).
func _load_profile() -> void:
	var raw: Variant = _load_json(PROFILE_PATH)
	if not raw is Dictionary or (raw as Dictionary).is_empty():
		return
	if not _apply_saved_profile(raw as Dictionary):
		save_profile()


## Takes a saved profile (the signed dictionary of profile.json) into `profile`: verified,
## brought up to this version, merged (unknown keys and wrongly typed values are dropped) and
## sanitised. A signature that does not match keeps only the name and flags the save; returns
## whether the save was accepted.
func _apply_saved_profile(raw: Dictionary) -> bool:
	var check := Guard.verify_dict(raw)
	if check.ok:
		var data: Dictionary = check.data
		_migrate_profile(data)
		_merge_into(profile, data)
	else:
		var keep_name: Variant = raw.get("name", profile.name)
		if typeof(keep_name) == TYPE_STRING:
			profile.name = String(keep_name)
		Guard.flag("save")
	_sanitize_profile()
	return bool(check.ok)


## Brings a saved profile from an older version up to PROFILE_VERSION, in place, before it is
## merged.
func _migrate_profile(data: Dictionary) -> void:
	var version: Variant = data.get("profile_version", 1)
	if not (version is int or version is float):
		version = 1
	if int(version) < 2:
		# Version 2 added the guest login, the profile page's keys and the numbers per mode. A
		# player who had chosen a name was playing already: no login for them. Until then START
		# was the bot duel (now TRAINING GROUND) and every match counted only in the totals, so
		# the totals become its numbers.
		data["guest_ok"] = _flag(data.get("name_set"))
		data["modes"] = {"training": {"matches": data.get("matches", 0), "wins": data.get("wins", 0),
			"kills": data.get("kills", 0)}}
	if int(version) < 3:
		# Version 3 keeps the last matches (the profile page's HISTORY): none were kept before.
		data["history"] = []
	data["profile_version"] = PROFILE_VERSION


func _sanitize_profile() -> void:
	var n := clean_name(String(profile.name))
	profile.name = n if n != "" else "ROOKIE"
	profile.bundle = String(CharacterModel.bundle_info(String(profile.bundle)).id)
	for k: String in PROFILE_COUNTERS:
		profile[k] = _count(profile.get(k))
	profile.wins = mini(int(profile.wins), int(profile.matches))
	profile.hits = mini(int(profile.hits), int(profile.shots))
	profile.headshots = mini(int(profile.headshots), int(profile.hits))
	for k: String in ["name_set", "guest_ok"]:
		profile[k] = _flag(profile.get(k))
	profile.created = _count(profile.get("created"), UNIX_MAX)
	if not String(profile.get("avatar", "")) in avatar_ids():
		profile.avatar = DEFAULT_PROFILE.avatar
	if not String(profile.get("banner", "")) in BANNERS:
		profile.banner = DEFAULT_PROFILE.banner
	profile.signature = clean_text(String(profile.get("signature", "")), SIGNATURE_MAX)
	var modes := {}
	var saved_modes: Variant = profile.get("modes")
	for m: String in MODE_NAMES:
		var src: Variant = (saved_modes as Dictionary).get(m) if saved_modes is Dictionary else null
		var c := {}
		for k: String in MODE_COUNTERS:
			c[k] = _count((src as Dictionary).get(k) if src is Dictionary else null)
		c.wins = mini(int(c.wins), int(c.matches))
		modes[m] = c
	profile.modes = modes
	profile.friends = _player_map(profile.get("friends"), MAX_FRIENDS, false)
	profile.friend_in = _player_map(profile.get("friend_in"), MAX_REQUESTS, true)
	profile.friend_out = _player_map(profile.get("friend_out"), MAX_REQUESTS, true)
	profile.withdrawn = _id_list(profile.get("withdrawn"), MAX_REQUESTS)
	var recent := []
	var seen := {}
	var saved_recent: Variant = profile.get("recent")
	if saved_recent is Array:
		for e: Variant in saved_recent:
			var id: Variant = (e as Dictionary).get("id") if e is Dictionary else null
			if recent.size() < MAX_RECENT and is_player_id(id) and not seen.has(id):
				seen[id] = true
				recent.append({"id": String(id), "name": clean_name(String((e as Dictionary).get("name", ""))),
					"t": _count((e as Dictionary).get("t"), UNIX_MAX)})
	profile.recent = recent
	profile.blocked = _blocked_list(profile.get("blocked"))
	var history := []
	var saved_history: Variant = profile.get("history")
	if saved_history is Array:
		for e: Variant in saved_history:
			var h := _history_entry(e)
			if not h.is_empty() and history.size() < MAX_HISTORY:
				history.append(h)
	profile.history = history


## One HISTORY entry from saved or untrusted data (see DEFAULT_PROFILE "history"): every value
## checked, names cleaned; {} when it is not one (an unknown result).
func _history_entry(e: Variant) -> Dictionary:
	if not e is Dictionary:
		return {}
	var d := e as Dictionary
	var r: Variant = d.get("result")
	if typeof(r) != TYPE_STRING or not String(r) in HISTORY_RESULTS:
		return {}
	var m: Variant = d.get("mode")
	var who := clean_name(String(d.get("enemy"))) if typeof(d.get("enemy")) == TYPE_STRING else ""
	var id: Variant = d.get("id")
	return {"result": String(r), "mode": String(m) if typeof(m) == TYPE_STRING and MODE_NAMES.has(m) else DEFAULT_MODE,
		"enemy": who if who != "" else "PLAYER", "id": String(id) if is_player_id(id) else "",
		"score": _count(d.get("score"), 99), "enemy_score": _count(d.get("enemy_score"), 99),
		"kills": _count(d.get("kills"), 999), "damage": _count(d.get("damage"), 999999),
		"headshots": _count(d.get("headshots"), 9999), "t": _count(d.get("t"), UNIX_MAX)}


## A whole number 0..hi from a saved value (anything but a number counts as 0).
static func _count(v: Variant, hi := COUNTER_MAX) -> int:
	return clampi(int(v), 0, hi) if (v is int or v is float) else 0


## A saved on/off value (anything but true counts as false).
static func _flag(v: Variant) -> bool:
	return v is bool and bool(v)


## id -> {"name"} (with "t", a unix time, when timed) from a saved player list: valid ids only,
## names cleaned, at most `limit` entries.
func _player_map(saved: Variant, limit: int, timed: bool) -> Dictionary:
	var out := {}
	if saved is Dictionary:
		for id: Variant in saved:
			var e: Variant = (saved as Dictionary)[id]
			if is_player_id(id) and e is Dictionary and out.size() < limit:
				var entry := {"name": clean_name(String((e as Dictionary).get("name", "")))}
				if timed:
					entry.t = _count((e as Dictionary).get("t"), UNIX_MAX)
				out[String(id)] = entry
	return out


## A list of player ids from a saved value: valid ids only, each once, at most `limit`.
func _id_list(saved: Variant, limit: int) -> Array:
	var out := []
	if saved is Array:
		for id: Variant in saved:
			if out.size() < limit and is_player_id(id) and not out.has(id):
				out.append(String(id))
	return out


## The saved blocks (DEFAULT_PROFILE "blocked"): valid ids only, each once, at most MAX_BLOCKED,
## names cleaned. A bare id, as builds before the name was kept saved a block, is a block without
## a name.
func _blocked_list(saved: Variant) -> Array:
	var out := []
	var seen := {}
	if saved is Array:
		for e: Variant in saved:
			var d: Dictionary = e if e is Dictionary else {"id": e}
			var id: Variant = d.get("id")
			if out.size() < MAX_BLOCKED and is_player_id(id) and not seen.has(id):
				seen[id] = true
				var who: Variant = d.get("name")
				out.append({"id": String(id), "name": clean_name(String(who)) if typeof(who) == TYPE_STRING else "",
					"t": _count(d.get("t"), UNIX_MAX)})
	return out


## A player id: the 32 hex characters of Cloud.my_id.
func is_player_id(id: Variant) -> bool:
	return typeof(id) == TYPE_STRING and String(id).length() == 32 and String(id).is_valid_hex_number()


## The profile pictures a player can have: the game's emblem (everyone's so far) and the outfits'
## portraits (by bundle id, assets/ui/bundle_<id>.png).
func avatar_ids() -> PackedStringArray:
	var ids := PackedStringArray([DEFAULT_PROFILE.avatar])
	for b: Dictionary in CharacterModel.BUNDLE_INFO:
		ids.append(String(b.id))
	return ids


func is_friend(id: String) -> bool:
	return (profile.friends as Dictionary).has(id)


func add_friend(id: String, friend_name: String) -> void:
	var f: Dictionary = profile.friends
	if not is_player_id(id) or (f.size() >= MAX_FRIENDS and not f.has(id)):
		return
	f[id] = {"name": clean_name(friend_name)}
	save_profile()


func is_blocked(id: String) -> bool:
	for e: Dictionary in profile.blocked:
		if e.id == id:
			return true
	return false


## The blocked ids as a set (id -> true): for filtering long lists (ALL PLAYERS).
func blocked_ids() -> Dictionary:
	var out := {}
	for e: Dictionary in profile.blocked:
		out[e.id] = true
	return out


## Blocks a player: their challenges and friend requests are ignored (Cloud) and the lobby's
## lists leave them out; a friend stops being one and requests either way are dropped. Their name
## (`who`, "" when unknown) and the time are kept with the block, so BLOCKED still names them
## after a restart. At most MAX_BLOCKED players: blocking one more lifts the oldest block (the one
## block_lifts() returns).
func block(id: String, who := "") -> void:
	if not is_player_id(id) or is_blocked(id):
		return
	var b: Array = profile.blocked
	b.append({"id": id, "name": clean_name(who), "t": int(Time.get_unix_time_from_system())})
	while b.size() > MAX_BLOCKED:
		b.pop_front()
	(profile.friends as Dictionary).erase(id)
	(profile.friend_in as Dictionary).erase(id)
	(profile.friend_out as Dictionary).erase(id)
	save_profile()


## The block that the next block would lift (BLOCKED is full: the oldest), else {}.
func block_lifts() -> Dictionary:
	var b: Array = profile.blocked
	return b[0] if b.size() >= MAX_BLOCKED else {}


func unblock(id: String) -> void:
	var b: Array = profile.blocked
	for i in b.size():
		if b[i].id == id:
			b.remove_at(i)
			save_profile()
			return


func remove_friend(id: String) -> void:
	if (profile.friends as Dictionary).erase(id):
		save_profile()


## A random player name (two short words and two digits, at most 14 characters).
func random_name() -> String:
	const FIRST := ["SWIFT", "SILENT", "IRON", "NEON", "ROGUE", "BLAZE", "STORM", "FROST", "LUCKY", "GHOST",
		"RAPID", "WILD", "STEEL", "NIGHT", "DUSTY", "RED", "GOLD", "SHADOW", "TURBO", "STONE"]
	const SECOND := ["WOLF", "FOX", "HAWK", "VIPER", "TIGER", "RAVEN", "LYNX", "SHARK", "FALCON", "BEAR",
		"RHINO", "COBRA", "PUMA", "BISON", "EAGLE", "JACKAL"]
	var a: String = FIRST.pick_random()
	var b: String = SECOND.pick_random()
	if (a + b).length() > 12:
		a = a.substr(0, 12 - b.length())
	return a + b + "%02d" % randi_range(1, 99)


## Player names: upper-case A-Z, 0-9, space, _ - . and at most 14 characters.
func clean_name(t: String) -> String:
	return clean_text(t, NAME_MAX)


## Text a player types for others to see (a name, the profile signature): upper-case A-Z, 0-9,
## space, _ - . and at most max_len characters.
func clean_text(t: String, max_len: int) -> String:
	var out := ""
	for ch in t.strip_edges().to_upper():
		if (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9") or ch in [" ", "_", "-", "."]:
			out += ch
	return out.strip_edges().substr(0, max_len)


## Saves the signed profile; its first save stamps "created".
func save_profile() -> void:
	if int(profile.get("created", 0)) <= 0:
		profile.created = int(Time.get_unix_time_from_system())
	_save_json(PROFILE_PATH, Guard.sign_dict(profile))


func save_hud_layout(layout: Dictionary) -> void:
	hud_layout = layout.duplicate(true)
	_save_json(HUD_PATH, hud_layout)


func crosshair_color() -> Color:
	return CROSSHAIR_COLORS[clampi(int(settings.crosshair_color), 0, CROSSHAIR_COLORS.size() - 1)]


## The crosshair's scale: crosshair_size is a percentage of the standard size.
func crosshair_scale() -> float:
	var r: Array = SETTING_RANGES.crosshair_size
	return CROSSHAIR_SCALE * float(clampi(int(settings.crosshair_size), int(r[0]), int(r[1]))) / 100.0


## The frame rates the settings offer on a screen that refreshes `hz` times a second: 30 and 60
## always, 90 and 120 only where the screen can show them (an unknown rate, NaN or 0, offers 30
## and 60).
func fps_options_for(hz: float) -> Array:
	var out := []
	for f: int in FPS_OPTIONS:
		if f <= 60 or hz >= f - 2.0:
			out.append(f)
	return out


## The frame rates offered on this screen.
func fps_choices() -> Array:
	return fps_options_for(DisplayServer.screen_get_refresh_rate())


# ---------------------------------------------------------------- AUTO graphics

## AUTO graphics (graphics_auto): the game picks LOW..HIGH for this phone. start_auto_graphics()
## sets a first guess from the hardware (PerfGovernor.device_level) and asks for a measurement:
## while auto_graphics_pending the lobby's or the arena's PerfGovernor measures the frame times for
## a few seconds and finish_auto_graphics() takes its level. A lowered level is measured once more
## (it may go lower still, never back up); then graphics_auto_done keeps the result until AUTO is
## picked again, the frame rate changes or BASIC is reset. Automated runs keep a fixed level.
var auto_graphics_pending := false
var _auto_passes := 0


func start_auto_graphics() -> void:
	settings.graphics_auto = true
	settings.graphics_auto_done = false
	_auto_passes = 0
	auto_graphics_pending = autotest == ""
	if auto_graphics_pending:
		settings.graphics = PerfGovernor.device_level(RenderingServer.get_video_adapter_name(), OS.get_processor_count(),
			int(OS.get_memory_info().get("physical", 0)), DisplayServer.screen_get_size(), OS.has_feature("mobile"))


## A level picked by hand: AUTO is off and stops measuring.
func stop_auto_graphics() -> void:
	settings.graphics_auto = false
	auto_graphics_pending = false


## True for AUTO's first measurement (it may go a level up; the second one only down).
func auto_graphics_first_pass() -> bool:
	return _auto_passes == 0


## A measurement's answer (PerfGovernor): the level is applied and saved; a lowered one is
## measured once more.
func finish_auto_graphics(picked: int) -> void:
	if not auto_graphics_pending:
		return
	var lowered := picked < int(settings.graphics)
	_auto_passes += 1
	settings.graphics = clampi(picked, 0, PerfGovernor.AUTO_MAX)
	auto_graphics_pending = bool(settings.graphics_auto) and lowered and _auto_passes < 2
	settings.graphics_auto_done = not auto_graphics_pending
	save_settings()


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


## A fight counts as played once it starts, so leaving mid-fight (QUIT MATCH, closing the app)
## still records it, as a loss. `m` is the mode it is played in (a key of MODE_NAMES): it counts
## in the totals and in that mode's numbers (profile.modes).
func count_match(m := DEFAULT_MODE) -> void:
	profile.matches = int(profile.matches) + 1
	var c := _mode_counts(m)
	c.matches = int(c.matches) + 1
	save_profile()


## The end of a counted fight: wins, kills and XP, in the totals and in the numbers of the
## result's mode ("mode_id", see ResultsScreen); the profile page's CAREER counters, a HISTORY
## entry and, online, the opponent among the recent players.
func record_match(result: Dictionary) -> void:
	last_result = result
	var c := _mode_counts(String(result.get("mode_id", DEFAULT_MODE)))
	var kills := int(result.get("kills", 0))
	if result.get("won", false):
		profile.wins = int(profile.wins) + 1
		c.wins = int(c.wins) + 1
	profile.kills = int(profile.kills) + kills
	c.kills = int(c.kills) + kills
	profile.xp = int(profile.xp) + int(result.get("xp", 0))
	# CAREER: [profile counter, result key] (the arena's result, see ResultsScreen.setup()).
	for k: Array in [["deaths", "deaths"], ["headshots", "headshots"], ["damage", "damage"], ["shots", "shots"],
			["hits", "hits"], ["rounds_won", "score_player"], ["rounds_lost", "score_bot"], ["time_played", "time"]]:
		profile[k[0]] = mini(int(profile[k[0]]) + _count(result.get(k[1])), COUNTER_MAX)
	profile.hits = mini(int(profile.hits), int(profile.shots))
	profile.headshots = mini(int(profile.headshots), int(profile.hits))
	var entry := _history_entry({"result": "draw" if result.get("draw", false) else ("won" if result.get("won", false) else "lost"),
		"mode": result.get("mode_id"), "enemy": result.get("enemy"), "id": result.get("enemy_id"),
		"score": result.get("score_player"), "enemy_score": result.get("score_bot"), "kills": result.get("kills"),
		"damage": result.get("damage"), "headshots": result.get("headshots"), "t": int(Time.get_unix_time_from_system())})
	var history: Array = profile.history
	history.push_front(entry)
	history.resize(mini(history.size(), MAX_HISTORY))
	if entry.id != "":
		var recent: Array = (profile.recent as Array).filter(func(r: Dictionary) -> bool: return r.id != entry.id)
		recent.push_front({"id": entry.id, "name": entry.enemy, "t": entry.t})
		recent.resize(mini(recent.size(), MAX_RECENT))
		profile.recent = recent
	save_profile()


## A mode's numbers in the profile (profile.modes[m]: matches, wins, kills); an unknown mode
## counts as the default one.
func _mode_counts(m: String) -> Dictionary:
	var modes: Dictionary = profile.modes
	return modes[m] if modes.has(m) else modes[DEFAULT_MODE]


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


## Logs where a control is on screen, once per name and session: "[LoneWolf] ui <name> <x> <y>"
## in screen pixels (local_point is in the item's own coordinates). The emulator test taps there.
func mark_ui(what: String, item: CanvasItem, local_point: Vector2) -> void:
	var key := "ui " + what
	if _marks.has(key) or item == null or not item.is_inside_tree():
		return
	_marks[key] = true
	var p := item.get_viewport().get_screen_transform() * item.get_global_transform_with_canvas() * local_point
	print("[LoneWolf] ui %s %d %d" % [what, roundi(p.x), roundi(p.y)])


## Where a session starts once the boot screen is done: the guest login (scenes/login.tscn: PLAY
## AS GUEST, then the first profile setup) until the player has passed it (profile.guest_ok),
## the lobby after that. Automated runs always start in the lobby (their scripts expect it).
func goto_login() -> void:
	if bool(profile.get("guest_ok", false)) or autotest != "":
		goto_lobby()
		return
	get_tree().paused = false
	Engine.time_scale = 1.0
	get_tree().change_scene_to_file("res://scenes/login.tscn")


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
