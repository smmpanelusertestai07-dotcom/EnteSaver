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
## What the profile counts matches as (CAREER's rows, HISTORY's "mode", the arena's "mode_id"): the
## two modes above, then LONE WOLF's DUO and SQUAD (a team match against another player, a friend's
## TEAM INVITE, or a team search that found nobody and was played against bots). TRAINING GROUND's
## DUO and SQUAD count as TRAINING GROUND. Every list of modes in the records goes through this one
## (_sanitize_profile, _history_entry, _mode_counts), so no mode's numbers are dropped at a load.
const RECORD_MODES := {"training": "TRAINING GROUND", "lonewolf": "LONE WOLF", "duo": "LONE WOLF DUO",
	"squad": "LONE WOLF SQUAD"}
## DUO / SQUAD between two phones (the TEAM bar's invites, LONE WOLF's DUO / SQUAD search): the
## release's off switch. false hides the TEAM bar, declines team invites, and LONE WOLF with DUO or
## SQUAD says "ONLINE DUO / SQUAD: NEXT UPDATE"; TRAINING GROUND's DUO and SQUAD play either way.
const TEAMS_ONLINE := true
## A match is first to ROUNDS_TO_WIN rounds (the reference mode: first to 5, best of 9); a custom
## room sets its own (see rounds_to_win()).
const ROUNDS_TO_WIN := 5

const SETTINGS_VERSION := 7
const DEFAULT_SETTINGS := {
	"settings_version": SETTINGS_VERSION,
	"mode": DEFAULT_MODE,
	"graphics": 1,
	"graphics_auto": true,        # the game picks the graphics level for the phone (see AUTO graphics)
	"graphics_auto_done": false,  # AUTO has measured this phone (until then the next lobby or match does)
	"fps": 60,
	"sens_general": 100,
	"sens_reddot": 100,
	"sens_2x": 100,               # aiming through a 2x scope (Player.sens_key)
	"sens_sniper": 71,
	"sens_freelook": 100,         # free look (the eye button)
	"dynamic_joystick": true,     # the stick follows the thumb (the reference's default) or stays put
	# Vibration (vibrate(), VIBRATE_KEYS), the reference's rows and defaults: in a match (CONTROLS)
	# an enemy's footsteps close by, taking damage, shooting (heavy shots, a kill); out of a match
	# (ONLINE) a duel challenge or a friend request in the lobby.
	"vibrate_footsteps": true,
	"vibrate_damage": false,
	"vibrate_shooting": false,
	"vibration": true,
	"aim_precision": 0,           # aim assist: 0 always, 1 not while aiming down a sight, 2 never (Player.assist_allowed)
	"left_fire": 0,               # the left fire button: 0 always, 1 only while aiming, 2 off (HUD.LEFT_FIRE_OFF)
	"reload_button": true,        # the RELOAD button up and left of FIRE (HUD)
	"switch_button": true,        # the SWITCH button left of the weapon panel: gun <-> fists
	"reload_on_crosshair": true,  # the reload's progress ring on the crosshair
	"hold_fire_scope": true,      # sniper rifles: holding FIRE looks through the scope, letting go fires
	"freelook_button": false,     # the free look (eye) button: off, as the reference ships it
	"run_mode": 2,                # sprint: 0 TAP (the sprint button), 1 DRAG (push the stick past its ring), 2 MIXED (both)
	"visual_effects": true,       # muzzle / explosion lights and full particle bursts (Effects.configure)
	"minimap_turns": true,        # the minimap turns with the view (the player's arrow up) or stays north up (HudMinimap)
	"vol_sfx": 90,
	"vol_music": 45,
	"vol_voice": 80,              # the other player's push-to-talk voice (NetVoice, bus "Voice")
	"difficulty": 1,
	"last_pick": "ar",
	"team_size": 1,               # SOLO 1, DUO 2, SQUAD 4: the team size START plays (Game.team_size)
	# ONLINE (SettingsPanel's tab, scripts/settings_online.gd)
	"chat": true,                 # chat in an online match (NetChat)
	"friend_chat": true,          # FRIENDS CHAT: true friends only, false off
	"show_career": true,          # SHOW MY CAREER: the player card carries a career summary (Cloud card v3)
	"voice_chat": false,          # push-to-talk in an online match (NetVoice; asks for the microphone)
	"challenges_from": 0,         # DUEL CHALLENGES FROM: CHALLENGES_EVERYONE, _FRIENDS, _NOBODY (Cloud.challenge_allowed)
	"team_status": 1,             # the social panel's status (LobbySocial): 0 JOIN ME ANYTIME, 1 ONLINE, 2 BUSY
	"friend_requests": true,      # FRIEND REQUESTS: off, Cloud ignores them (never shown, never answered)
	"direct_connect": true,       # DIRECT CONNECTION: the match state straight to the other phone (NetDirect)
}
## The values of the setting challenges_from (SettingsOnline shows them in this order).
const CHALLENGES_EVERYONE := 0
const CHALLENGES_FRIENDS := 1
const CHALLENGES_NOBODY := 2

## Behaviour that is not a setting (the settings screen keeps to what the reference offers, plus
## what the owner asked for): always these values, whatever an older settings file says. Version
## 6 made two settings of version 5 fixed again: there is no FPS counter (the screenshot tours
## turn show_fps on in memory) and a drag that starts on FIRE turns at the view's own sensitivity
## (sens_fire 100 %, Player).
const FIXED_SETTINGS := {
	"damage_numbers": true, "dynamic_crosshair": true, "show_fps": false, "sens_fire": 100,
}
## Settings that FIXED_SETTINGS held until version 4, whatever the file said: a file from then
## has no say in them, they start from their defaults (what version 4 played with).
const FIXED_UNTIL_V4 := ["show_fps", "vibration", "crosshair_color", "crosshair_size", "sens_fire"]
## The master volume of version 5 (dropped in version 6): one a player left here is not folded
## into the other volumes (_migrate_settings).
const OLD_MASTER_DEFAULT := 85

## Valid ranges of the numeric settings. Values outside them (an edited or corrupted settings
## file) are clamped on load and on save, so nothing can index past a list or overdrive a value.
const SETTING_RANGES := {
	"graphics": [0, 3], "sens_general": [1, 200], "sens_reddot": [1, 200], "sens_2x": [1, 200],
	"sens_sniper": [1, 200], "sens_freelook": [1, 200], "vol_sfx": [0, 100], "vol_music": [0, 100],
	"difficulty": [0, 2], "aim_precision": [0, 2], "left_fire": [0, 2], "run_mode": [0, 2],
	"vol_voice": [0, 100], "challenges_from": [CHALLENGES_EVERYONE, CHALLENGES_NOBODY], "team_status": [0, 2], "team_size": [1, 4],
}
## On/off settings: anything but true or false falls back to the default.
const BOOL_SETTINGS := ["graphics_auto", "graphics_auto_done", "dynamic_joystick", "vibrate_footsteps", "vibrate_damage",
	"vibrate_shooting", "vibration", "visual_effects", "reload_button", "switch_button", "reload_on_crosshair", "hold_fire_scope",
	"freelook_button", "chat", "friend_chat", "show_career", "voice_chat", "friend_requests", "direct_connect", "minimap_turns"]
## What each kind of buzz (vibrate()) needs on: the reference's vibration rows (CONTROLS) and,
## out of a match, the lobby's (ONLINE).
const VIBRATE_KEYS := {"footsteps": "vibrate_footsteps", "damage": "vibrate_damage", "shooting": "vibrate_shooting",
	"lobby": "vibration"}
## Every frame rate the setting can hold; the settings offer those the screen can show
## (fps_choices).
const FPS_OPTIONS := [30, 60, 90, 120]

## The crosshair's scale: the size the HUD drew before version 5 made it a setting (version 6 made
## it fixed again, white like the reference's; it turns red on an enemy).
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
	"modes": {"training": {"matches": 0, "wins": 0, "kills": 0}, "lonewolf": {"matches": 0, "wins": 0, "kills": 0},
		"duo": {"matches": 0, "wins": 0, "kills": 0}, "squad": {"matches": 0, "wins": 0, "kills": 0}},
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
	# lost, draw, left: quit with QUIT MATCH, a defeat, or ended: a team match the host left, no
	# win, no loss), "mode" (RECORD_MODES), "enemy" (name), "id" (an online opponent's id, else
	# ""), "score" and "enemy_score" (rounds), "kills", "damage", "headshots", "t" (unix time)}];
	# a DUO / SQUAD match also keeps "size" (2 | 4), "bots" (how many fighters were bots) and
	# "with" (the friend on this player's team, "" when none).
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
const HISTORY_RESULTS := ["won", "lost", "draw", "left", "ended"]
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
## (internet, see scripts/cloud.gd) or the Lan (PLAY WITHOUT INTERNET, scripts/lan.gd: a Cloud whose
## room runs over the local network) that connected the two.
var online := false
var session: Cloud
## The custom room's rules the next online match is played with ({} = a plain duel); see
## Cloud.ROOM_RULES.
var room_rules := {}
var cloud: Cloud
var lan: Lan
## [title, text] the lobby shows once when it opens again: why an online match was called off (the
## connection was lost, or the other player left before it began); [] = nothing to say.
var match_notice: Array = []
## DUO / SQUAD (PLAN_TEAMS). The team sizes START offers: 1 SOLO (the 1 vs 1), 2 DUO, 4 SQUAD.
const TEAM_SIZES := [1, 2, 4]
## The team size START plays, kept as the setting "team_size" (anything else is SOLO).
var team_size: int:
	get:
		var n := int(settings.get("team_size", 1))
		return n if n in TEAM_SIZES else 1
	set(value):
		settings["team_size"] = value if value in TEAM_SIZES else 1
## The next arena run is a team match ({} = a 1 vs 1, scenes/arena.tscn): {"size": 2 | 4 (players a
## team), "online": bool (two phones over Cloud's 1 vs 1 session: scenes/team_arena_net.tscn),
## "coop": bool (online: both players on team 0 against bots), "mode_id": "duo" | "squad" | "training"
## (what the profile counts it as), "my_slot": int, "host": bool, "roster": [{"slot", "id" ("" for a
## bot), "name", "bundle", "team" (0 | 1), "bot": bool, "diff": 0..2 (a bot's level)}]}: built by
## TeamArena.offline_match / TeamArena.link_match; TeamArena reads it. Cleared ({}) whenever a lobby
## opens or a 1 vs 1 starts (WP-B1).
var team_match := {}


## The scene the next match runs in: a team match on this phone (team_arena) or between two phones
## (team_arena_net), else the 1 vs 1 arena.
func arena_scene() -> String:
	if team_match.is_empty():
		return "res://scenes/arena.tscn"
	return "res://scenes/team_arena_net.tscn" if bool(team_match.get("online", false)) else "res://scenes/team_arena.tscn"


## The online service (made on first use; it outlives scene changes).
func cloud_service() -> Cloud:
	if cloud == null:
		cloud = Cloud.new()
		add_child(cloud)
	return cloud


## PLAY WITHOUT INTERNET's service (made on first use; it outlives scene changes).
func lan_service() -> Lan:
	if lan == null:
		lan = Lan.new()
		add_child(lan)
	return lan


## The match against another phone is on the local network (PLAY WITHOUT INTERNET).
func local_match() -> bool:
	return online and session is Lan

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
		# v4: every player started on that version's default joystick (it stayed put).
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
	if int(version) < 6:
		# v6, the reference's settings: the FPS counter, the crosshair colour and size, the
		# fire-button drag and the master volume are gone (the merge drops them). A master volume
		# the player had turned from its default goes into the volumes left, so the game sounds as
		# before. Every player gets the reference's defaults for the joystick (it follows the
		# thumb) and the free look button (off). The one vibration switch becomes the reference's
		# rows: off, every buzz stays off; on, their defaults (footsteps and the lobby on, taking
		# damage and shooting off).
		var master: Variant = saved.get("vol_master")
		if (master is int or master is float) and int(master) != OLD_MASTER_DEFAULT:
			var m := clampf(float(master), 0.0, 100.0) / 100.0
			for k: String in ["vol_sfx", "vol_music", "vol_voice"]:
				var v: Variant = saved.get(k, DEFAULT_SETTINGS[k])
				if v is int or v is float:
					saved[k] = roundi(clampf(float(v), 0.0, 100.0) * m)
		saved.erase("dynamic_joystick")
		saved.erase("freelook_button")
		if saved.get("vibration") is bool and not bool(saved.vibration):
			saved["vibrate_footsteps"] = false
	if int(version) < 7:
		# v7: the minimap turns with the view, as the reference's does by default. Before it was
		# always north up and never a choice, so every older file starts on the new default
		# (SETTINGS > DISPLAY > MINIMAP sets NORTH UP back).
		saved.erase("minimap_turns")


## Every setting as on a new install (DELETE MY DATA): the defaults, the fixed behaviour, AUTO
## graphics measuring this phone again, applied at once.
func reset_settings() -> void:
	settings = DEFAULT_SETTINGS.duplicate(true)
	_apply_saved_settings({})
	if bool(settings.graphics_auto):
		start_auto_graphics()
	apply_settings()


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
	return String(RECORD_MODES.get(m if m != "" else mode, MODE_NAMES[DEFAULT_MODE]))


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
	if autotest != "":
		return {}
	return read_json(path)


func _save_json(path: String, data: Dictionary) -> void:
	if autotest != "":
		return
	write_json(path, data)


## A save as written by write_json: the file, or its previous version (path + ".bak") when the file
## is missing or does not read as a JSON object (a write cut short); {} when neither does.
static func read_json(path: String) -> Dictionary:
	for p: String in [path, path + ".bak"]:
		var json := JSON.new()
		if FileAccess.file_exists(p) and json.parse(FileAccess.get_file_as_string(p)) == OK and json.data is Dictionary:
			return json.data
	return {}


## Writes a save so that a write cut short (a full phone, the app killed) never leaves a broken
## file in its place: the JSON goes to path + ".tmp" and is checked whole; only then does the old
## file become path + ".bak" and the new one take its name (renames, so one of the two is always
## complete). Returns whether the save was written; when it was not, the old file is untouched.
static func write_json(path: String, data: Dictionary) -> bool:
	var text := JSON.stringify(data, "\t")
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		return false
	var stored := f.store_string(text)
	f.flush()
	var ok := stored and f.get_error() == OK and f.get_length() == text.to_utf8_buffer().size()
	f.close()
	if not ok or FileAccess.get_file_as_string(tmp) != text:
		DirAccess.remove_absolute(tmp)
		return false
	if FileAccess.file_exists(path) and DirAccess.rename_absolute(path, path + ".bak") != OK:
		DirAccess.remove_absolute(tmp)
		return false
	return DirAccess.rename_absolute(tmp, path) == OK


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
	for m: String in RECORD_MODES:
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
## checked, names cleaned; {} when it is not one (an unknown result). A match played without
## internet (PLAY WITHOUT INTERNET) also has "local": true; a DUO / SQUAD match "size", "bots" and
## "with" (1 vs 1 entries keep their ten keys).
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
	var out := {"result": String(r), "mode": String(m) if typeof(m) == TYPE_STRING and RECORD_MODES.has(m) else DEFAULT_MODE,
		"enemy": who if who != "" else "PLAYER", "id": String(id) if is_player_id(id) else "",
		"score": _count(d.get("score"), 99), "enemy_score": _count(d.get("enemy_score"), 99),
		"kills": _count(d.get("kills"), 999), "damage": _count(d.get("damage"), 999999),
		"headshots": _count(d.get("headshots"), 9999), "t": _count(d.get("t"), UNIX_MAX)}
	if d.get("local") == true:
		out["local"] = true          # PLAY WITHOUT INTERNET (HISTORY shows LONE WOLF · LOCAL)
	var size := _count(d.get("size"), 4)
	if size in [2, 4]:               # DUO / SQUAD (HISTORY shows "DUO · VS BOTS", "SQUAD · WITH NAME")
		out["size"] = size
		out["bots"] = _count(d.get("bots"), size * 2 - 1)
		out["with"] = clean_name(String(d.get("with"))) if typeof(d.get("with")) == TYPE_STRING else ""
	return out


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
## space, _ - . and at most max_len characters. Accented Latin letters become their plain letter
## (JOSÉ -> JOSE, MÜLLER -> MULLER, ß -> SS); anything else (other scripts, symbols) is dropped.
func clean_text(t: String, max_len: int) -> String:
	var out := ""
	for ch in t.strip_edges().to_upper():
		if (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9") or ch in [" ", "_", "-", "."]:
			out += ch
		elif ch >= "À":
			out += _fold_letter(ch)
	return out.strip_edges().substr(0, max_len)


## A plain letter for an accented capital (Latin-1 and Latin Extended-A), "" for anything else.
const FOLD := {"A": "ÀÁÂÃÄÅĀĂĄ", "C": "ÇĆĈĊČ", "D": "ÐĎĐ", "E": "ÈÉÊËĒĔĖĘĚ", "G": "ĜĞĠĢ", "H": "ĤĦ",
	"I": "ÌÍÎÏĨĪĬĮİ", "J": "Ĵ", "K": "Ķ", "L": "ĹĻĽĿŁ", "N": "ÑŃŅŇ", "O": "ÒÓÔÕÖØŌŎŐ", "R": "ŔŖŘ",
	"S": "ŚŜŞŠ", "T": "ŢŤŦ", "U": "ÙÚÛÜŨŪŬŮŰŲ", "W": "Ŵ", "Y": "ÝŶŸ", "Z": "ŹŻŽ", "AE": "Æ", "OE": "Œ",
	"SS": "ß", "TH": "Þ"}
static func _fold_letter(ch: String) -> String:
	for plain: String in FOLD:
		if String(FOLD[plain]).contains(ch):
			return plain
	return ""


## Saves the signed profile; its first save stamps "created".
func save_profile() -> void:
	if int(profile.get("created", 0)) <= 0:
		profile.created = int(Time.get_unix_time_from_system())
	_save_json(PROFILE_PATH, Guard.sign_dict(profile))


func save_hud_layout(layout: Dictionary) -> void:
	hud_layout = layout.duplicate(true)
	_save_json(HUD_PATH, hud_layout)


## The crosshair's idle colour: white, as the reference's (the HUD turns it red on an enemy).
func crosshair_color() -> Color:
	return Color.WHITE


## The crosshair's scale (CROSSHAIR_SCALE: not a setting).
func crosshair_scale() -> float:
	return CROSSHAIR_SCALE


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


## The volume buses (settings vol_music, vol_sfx, vol_voice), each sent to Master.
func _setup_audio_buses() -> void:
	for bus_name in ["Music", "SFX", "Voice"]:
		if AudioServer.get_bus_index(bus_name) == -1:
			AudioServer.add_bus()
			var idx := AudioServer.bus_count - 1
			AudioServer.set_bus_name(idx, bus_name)
			AudioServer.set_bus_send(idx, "Master")


func apply_settings() -> void:
	Engine.max_fps = int(settings.fps)
	_set_bus("Master", 100)               # no master volume since version 6: one each for effects, music, voice
	_set_bus("Music", settings.vol_music)
	_set_bus("SFX", settings.vol_sfx)
	_set_bus("Voice", settings.vol_voice)


func _set_bus(bus_name: String, percent: float) -> void:
	var idx := AudioServer.get_bus_index(bus_name)
	if idx >= 0:
		var lin := clampf(percent / 100.0, 0.0, 1.0)
		AudioServer.set_bus_mute(idx, lin <= 0.001)
		AudioServer.set_bus_volume_db(idx, linear_to_db(maxf(lin, 0.001)))


## Whether a buzz of `kind` (a key of VIBRATE_KEYS) is on: its vibration row.
func vibration_on(kind: String) -> bool:
	return bool(settings.get(String(VIBRATE_KEYS.get(kind, "")), false))


## A buzz of `ms` for `kind` (VIBRATE_KEYS: "footsteps", "damage", "shooting", "lobby") when its
## row is on; phones only.
func vibrate(ms: int, kind: String) -> void:
	if vibration_on(kind) and OS.has_feature("mobile"):
		Input.vibrate_handheld(ms)


## A fight counts as played once it starts, so leaving mid-fight (QUIT MATCH, closing the app)
## still records it, as a loss (QUIT MATCH also puts it into HISTORY as LEFT: Arena.record_left).
## `m` is the mode it is counted as (a key of RECORD_MODES): it counts in the totals and in that
## mode's numbers (profile.modes).
func count_match(m := DEFAULT_MODE) -> void:
	profile.matches = int(profile.matches) + 1
	var c := _mode_counts(m)
	c.matches = int(c.matches) + 1
	save_profile()


## The end of a counted fight: wins, kills and XP, in the totals and in the numbers of the
## result's mode ("mode_id", see ResultsScreen); the profile page's CAREER counters, a HISTORY
## entry and, online, the opponent among the recent players. "left": the match was quit before
## its end (HISTORY says LEFT; no win, whatever "won" says). "ended": a team match that could not
## go on (the host left a TEAM INVITE match: HISTORY says ENDED, no win). A team match ("team":
## true, "team_size", "bots") keeps its size, its bots and the friend on this player's team (from
## Game.team_match) in HISTORY.
func record_match(result: Dictionary) -> void:
	last_result = result
	var c := _mode_counts(String(result.get("mode_id", DEFAULT_MODE)))
	var kills := int(result.get("kills", 0))
	var left := bool(result.get("left", false))
	var ended := bool(result.get("ended", false)) and not left
	var won := bool(result.get("won", false)) and not left and not ended
	if won:
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
	var outcome := "left" if left else ("ended" if ended else ("draw" if result.get("draw", false) else ("won" if won else "lost")))
	var raw := {"result": outcome,
		"mode": result.get("mode_id"), "enemy": result.get("enemy"), "id": result.get("enemy_id"),
		"score": result.get("score_player"), "enemy_score": result.get("score_bot"), "kills": result.get("kills"),
		"damage": result.get("damage"), "headshots": result.get("headshots"), "t": int(Time.get_unix_time_from_system()),
		"local": result.get("local", false)}
	if bool(result.get("team", false)):
		raw.merge({"size": result.get("team_size", team_match.get("size", 0)), "bots": result.get("bots", 0),
			"with": result.get("with", team_mate_name(team_match))})
	var entry := _history_entry(raw)
	var history: Array = profile.history
	history.push_front(entry)
	history.resize(mini(history.size(), MAX_HISTORY))
	if entry.id != "":
		var recent: Array = (profile.recent as Array).filter(func(r: Dictionary) -> bool: return r.id != entry.id)
		recent.push_front({"id": entry.id, "name": entry.enemy, "t": entry.t})
		recent.resize(mini(recent.size(), MAX_RECENT))
		profile.recent = recent
	save_profile()


## A mode's numbers in the profile (profile.modes[m]: matches, wins, kills; m a key of
## RECORD_MODES); an unknown mode counts as the default one.
func _mode_counts(m: String) -> Dictionary:
	var modes: Dictionary = profile.modes
	if not modes.has(DEFAULT_MODE):
		modes[DEFAULT_MODE] = {"matches": 0, "wins": 0, "kills": 0}
	if RECORD_MODES.has(m) and not modes.has(m):
		modes[m] = {"matches": 0, "wins": 0, "kills": 0}
	return modes[m] if RECORD_MODES.has(m) else modes[DEFAULT_MODE]


## The other player on this player's team in a team match (a TEAM INVITE: the friend), "" when the
## team is this player and bots (`tm`: Game.team_match).
func team_mate_name(tm: Dictionary) -> String:
	var roster: Variant = tm.get("roster")
	if not roster is Array:
		return ""
	var mine := int(tm.get("my_slot", 0))
	var my_team := -1
	for e: Variant in roster:
		if e is Dictionary and int((e as Dictionary).get("slot", -1)) == mine:
			my_team = int((e as Dictionary).get("team", 0))
	for e: Variant in roster:
		if e is Dictionary:
			var d := e as Dictionary
			if int(d.get("slot", -1)) != mine and int(d.get("team", -2)) == my_team and not bool(d.get("bot", true)):
				return String(d.get("name", "PLAYER"))
	return ""


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
	get_tree().change_scene_to_file(arena_scene())


func goto_hud_editor() -> void:
	get_tree().paused = false
	Engine.time_scale = 1.0
	get_tree().change_scene_to_file("res://scenes/hud_editor.tscn")
