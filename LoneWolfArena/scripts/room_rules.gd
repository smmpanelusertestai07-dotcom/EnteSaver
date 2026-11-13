class_name RoomRules
extends RefCounted
## A CUSTOM ROOM's rules: the one object every arena plays them by (arena.gd 1 vs 1, team_arena.gd
## DUO / SQUAD). The host sets them on the room's create page (GAME tab, LobbyFriends); they travel
## to every phone in the room with the room's own messages, tagged by the host (Cloud: "rin" / the
## room group's roster carry `text()`, the 1 vs 1's start carries it too), and each phone reads them
## back with `parse()`. A match that is not a room's (training, QUICK MATCH, a duel, a group's own
## match, PLAY WITHOUT INTERNET) has none: `active()` is then DEFAULTS, today's rules exactly.
##
## Keys (DEFAULTS = today's rules):
##   rounds  the rounds a side needs to win (1-7; 5 = the 1 vs 1's own, a team room starts on 4)
##   ammo    unlimited reserve ammo           walls / frags  unlimited walls / frags (up to a cap)
##   throw   walls and frags at all (false: none in the round)
##   hp      every fighter's health (200 = today's; 150, 100 or 50 = lower, heals stop there)
##   speed   movement speed, % (100 = today's)        jump  jump height, % (100 = today's)
##   gun     "pick" (today's: the pick panel), "fixed" (`gun_id` the whole match) or "random"
##           (a gun drawn for every pick, alike on every phone: Cloud.match_seed)
##   gun_id  the gun of "fixed"                       zone  the safe zone closes (false: never)
##   aim     aim assist allowed (false: manual aim for everyone, whatever their setting)
##   name    the room's name (shown in the room's lobby)
## Older builds (1.8.0) read only rounds / ammo / walls / frags (Cloud.rules_from); a room whose
## other rules are not the defaults (`needs_new()`) does not let such a phone in (Cloud._on_room_ask).

const DEFAULTS := {"rounds": 5, "ammo": false, "walls": false, "frags": false, "throw": true, "hp": 200, "speed": 100,
	"jump": 100, "gun": "pick", "gun_id": "ar", "zone": true, "aim": true, "name": ""}
const ROUNDS := [1, 3, 4, 5, 7]
const HP := [200, 150, 100, 50]
const SPEED := [100, 50, 75, 125, 150]
const JUMP := [100, 150, 200]
const GUNS := ["pick", "fixed", "random"]
const TEXT_V := 1                        # the first field of text(): its layout
const NAME_MAX := 24
## The keys an older build does not know: any of them off its default needs this build.
const NEW_KEYS := ["throw", "hp", "speed", "jump", "gun", "zone", "aim"]

var rules: Dictionary = DEFAULTS.duplicate()
var custom := false                      # a room's rules (false: a normal match, DEFAULTS)


func _init(from: Variant = null) -> void:
	if from is Dictionary and not (from as Dictionary).is_empty():
		rules = sanitize(from)
		custom = true


## The rules the match being played goes by: the room's (Game.room_rules, set when a room's
## session starts) online, else today's.
static func active() -> RoomRules:
	if Game.online and Game.room_rules is Dictionary and not Game.room_rules.is_empty():
		return RoomRules.new(Game.room_rules)
	return RoomRules.new()


## Rules from untrusted data: known keys only, each value one of its choices (else the default).
static func sanitize(v: Variant) -> Dictionary:
	var out := DEFAULTS.duplicate()
	if not v is Dictionary:
		return out
	var d := v as Dictionary
	var r: Variant = d.get("rounds", 5)
	if typeof(r) == TYPE_INT or typeof(r) == TYPE_FLOAT:
		out.rounds = clampi(int(r), 1, 7)
	for k in ["ammo", "walls", "frags"]:
		out[k] = d.get(k, false) == true
	for k in ["throw", "zone", "aim"]:
		out[k] = not (typeof(d.get(k)) == TYPE_BOOL and d.get(k) == false)
	out.hp = _choice(d.get("hp"), HP, 200)
	out.speed = _choice(d.get("speed"), SPEED, 100)
	out.jump = _choice(d.get("jump"), JUMP, 100)
	out.gun = String(d.gun) if typeof(d.get("gun")) == TYPE_STRING and String(d.gun) in GUNS else "pick"
	out.gun_id = String(d.gun_id) if typeof(d.get("gun_id")) == TYPE_STRING and String(d.gun_id) in Weapons.PICKABLE else Weapons.DEFAULT_PICK
	out.name = Game.clean_name(String(d.name)).left(NAME_MAX) if typeof(d.get("name")) == TYPE_STRING else ""
	return out


static func _choice(v: Variant, choices: Array, fallback: int) -> int:
	if (typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT) and int(v) in choices and float(v) == float(int(v)):
		return int(v)
	return fallback


## The rules as one line of text (what the host tags and the room's messages carry).
static func text(r: Dictionary) -> String:
	var s := sanitize(r)
	return JSON.stringify([TEXT_V, s.rounds, s.ammo, s.walls, s.frags, s.throw, s.hp, s.speed, s.jump, s.gun, s.gun_id,
		s.zone, s.aim, s.name])


## text() read back ({} when it is not one: too long, another layout, wrong types).
static func parse(t: Variant) -> Dictionary:
	if typeof(t) != TYPE_STRING or String(t).length() > 400:
		return {}
	var a: Variant = JSON.parse_string(String(t))
	if not a is Array or (a as Array).size() < 14 or not (a[0] is float or a[0] is int) or int(a[0]) != TEXT_V:
		return {}
	var keys := ["rounds", "ammo", "walls", "frags", "throw", "hp", "speed", "jump", "gun", "gun_id", "zone", "aim", "name"]
	var d := {}
	for i in keys.size():
		d[keys[i]] = a[i + 1]
	return sanitize(d)


## Whether an older build (which knows only rounds / ammo / walls / frags) would play these
## differently.
static func needs_new(r: Dictionary) -> bool:
	var s := sanitize(r)
	for k: String in NEW_KEYS:
		if s[k] != DEFAULTS[k]:
			return true
	return false


## Whether these are today's rules (rounds aside: `team` picks the default it is compared with).
static func is_classic(r: Dictionary, team := false) -> bool:
	var s := sanitize(r)
	for k: String in DEFAULTS:
		if k == "name":
			continue
		var want: Variant = (4 if team else 5) if k == "rounds" else DEFAULTS[k]
		if s[k] != want:
			return false
	return true


## The CLASSIC preset (today's rules) for a room of `size` (SOLO 1, DUO 2, SQUAD 4), keeping its name.
static func classic(size: int, room_name := "") -> Dictionary:
	var d := DEFAULTS.duplicate()
	d.rounds = 5 if size <= 1 else 4
	d.name = room_name
	return d


# ---------------------------------------------------------------- what the arenas read

func get_rounds() -> int:
	return int(rules.rounds)


## Movement speed factor (Fighter.rule_speed).
func speed_mult() -> float:
	return float(rules.speed) / 100.0


## Jump take-off speed factor (Fighter.rule_jump): the height grows with its square.
func jump_mult() -> float:
	return sqrt(float(rules.jump) / 100.0)


## Every fighter's health at a round's start and the most a heal brings back (Fighter.hp_max).
func hp() -> float:
	return float(rules.hp)


func throwables() -> bool:
	return bool(rules.throw)


func zone() -> bool:
	return bool(rules.zone)


func aim_assist() -> bool:
	return bool(rules.aim)


func unlimited_ammo() -> bool:
	return bool(rules.ammo)


## The walls ("wall") or frags ("grenade") one fighter may use in a round: `start` normally, none
## without throwables, `cap` when they are unlimited.
func throw_cap(kind: String, start: int, cap: int) -> int:
	if not throwables():
		return 0
	if bool(rules.get("walls" if kind == "wall" else "frags", false)):
		return cap
	return start


## Whether a pick round gives a gun without the pick panel (ONE GUN or RANDOM).
func gun_forced() -> bool:
	return custom and String(rules.gun) != "pick"


## The gun the round's pick gives without the pick panel: "fixed" its gun, "random" one drawn from
## `draw` (the same on every phone), "" = the pick panel as today.
func forced_gun(draw: int) -> String:
	match String(rules.gun):
		"fixed":
			return String(rules.gun_id)
		"random":
			var rng := RandomNumberGenerator.new()
			rng.seed = draw
			return String(Weapons.PICKABLE[rng.randi() % Weapons.PICKABLE.size()])
	return ""


## The rules as short lines for the room's lobby (SlotPanel's RULES strip, the room tab).
static func summary(r: Dictionary, team := false) -> PackedStringArray:
	var s := sanitize(r)
	var out := PackedStringArray()
	out.append("FIRST TO %d" % int(s.rounds))
	if is_classic(s, team) and int(s.rounds) == (4 if team else 5):
		out.append("CLASSIC RULES")
		return out
	if int(s.hp) != 200:
		out.append("HP %d" % int(s.hp))
	if int(s.speed) != 100:
		out.append("SPEED %d%%" % int(s.speed))
	if int(s.jump) != 100:
		out.append("JUMP %d%%" % int(s.jump))
	match String(s.gun):
		"fixed":
			out.append("GUN: " + String(Weapons.DEFS[String(s.gun_id)].name) if Weapons.DEFS.has(String(s.gun_id)) else "ONE GUN")
		"random":
			out.append("RANDOM GUNS")
	if not bool(s.throw):
		out.append("NO WALLS OR FRAGS")
	else:
		if bool(s.walls):
			out.append("UNLIMITED WALLS")
		if bool(s.frags):
			out.append("UNLIMITED FRAGS")
	if bool(s.ammo):
		out.append("UNLIMITED AMMO")
	if not bool(s.zone):
		out.append("NO ZONE")
	if not bool(s.aim):
		out.append("NO AIM ASSIST")
	return out
