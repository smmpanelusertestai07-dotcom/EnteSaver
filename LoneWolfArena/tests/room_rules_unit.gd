extends RefCounted
## Unit tests of a custom room's rules (scripts/room_rules.gd; run from tests/run_tests.gd):
## - the defaults are today's rules exactly, and a match that is not a room's plays by them;
## - untrusted rules are cleaned (unknown keys dropped, values off their choices replaced);
## - text() / parse() round trip, and an older build's four keys still read;
## - an older build is kept out only of a room whose other rules differ (needs_new);
## - each option changes what the arena does: health and heals, speed, jump, walls and frags,
##   the gun of a pick round (ONE GUN, RANDOM alike for the same draw), the zone, aim assist.

const ArenaCode := preload("res://scripts/arena.gd")

var t: Node


static func run(runner: Node) -> void:
	var me := new()
	me.t = runner
	me._defaults()
	me._clean()
	me._text()
	me._older_builds()
	me._fighter_rules()
	me._arena_rules()


func _check(cond: bool, what: String) -> void:
	t.call("_check", cond, what)


func _defaults() -> void:
	var d := RoomRules.new()
	_check(not d.custom and d.get_rounds() == Game.ROUNDS_TO_WIN and d.hp() == Fighter.MAX_HP and d.speed_mult() == 1.0
		and d.jump_mult() == 1.0 and d.throwables() and d.zone() and d.aim_assist() and not d.unlimited_ammo() and not d.gun_forced(),
		"room rules: the defaults are today's rules (5 rounds, 200 HP, 100% speed and jump, walls and frags, the zone, aim assist, the pick)")
	_check(d.throw_cap("wall", Fighter.START_SHIELDS, 30) == Fighter.START_SHIELDS and d.throw_cap("grenade", Fighter.START_GRENADES, 30) == Fighter.START_GRENADES
		and d.forced_gun(1234) == "", "room rules: the defaults keep today's walls, frags and the pick panel")
	var saved_online := Game.online
	var saved_rules: Dictionary = Game.room_rules
	Game.online = false
	Game.room_rules = {"hp": 50}
	_check(not RoomRules.active().custom, "room rules: a match that is not online plays by today's rules whatever Game.room_rules holds")
	Game.online = true
	Game.room_rules = {}
	_check(not RoomRules.active().custom, "room rules: an online match that is not a room's (no rules) plays by today's rules")
	Game.room_rules = {"hp": 50}
	_check(RoomRules.active().custom and RoomRules.active().hp() == 50.0, "room rules: a room's session plays by its rules")
	Game.online = saved_online
	Game.room_rules = saved_rules
	_check(RoomRules.is_classic(RoomRules.classic(1)) and RoomRules.is_classic(RoomRules.classic(4), true)
		and int(RoomRules.classic(4).rounds) == 4 and int(RoomRules.classic(1).rounds) == 5,
		"room rules: CLASSIC is today's rules (SOLO first to 5, DUO / SQUAD first to 4)")


func _clean() -> void:
	var s := RoomRules.sanitize({"rounds": 99, "hp": 1000, "speed": 300, "jump": 77, "gun": "laser", "gun_id": "rocket",
		"zone": "no", "evil": true, "name": "A\nVERY LONG ROOM NAME THAT GOES ON AND ON"})
	_check(int(s.rounds) == 7 and int(s.hp) == 200 and int(s.speed) == 100 and int(s.jump) == 100 and String(s.gun) == "pick"
		and String(s.gun_id) == Weapons.DEFAULT_PICK and bool(s.zone) and not s.has("evil") and String(s.name).length() <= RoomRules.NAME_MAX,
		"room rules: untrusted rules are cleaned (values off their choices, unknown keys, long names)")
	_check(Cloud.rules_from({"rounds": 3, "ammo": true}).hp == 200 and int(Cloud.rules_from({"rounds": 3, "ammo": true}).rounds) == 3,
		"room rules: Cloud.rules_from reads an older host's four rules, the others at their defaults")


func _text() -> void:
	var r := {"rounds": 3, "ammo": true, "walls": false, "frags": true, "throw": true, "hp": 100, "speed": 125, "jump": 200,
		"gun": "fixed", "gun_id": "sniper", "zone": false, "aim": false, "name": "FRIDAY CUP"}
	var back := RoomRules.parse(RoomRules.text(r))
	_check(back == RoomRules.sanitize(r), "room rules: text() reads back the same rules (%s)" % RoomRules.text(r))
	_check(RoomRules.parse("[9,1]").is_empty() and RoomRules.parse(42).is_empty() and RoomRules.parse("x".repeat(500)).is_empty(),
		"room rules: a text of another layout, type or size is no rules")


func _older_builds() -> void:
	_check(not RoomRules.needs_new(RoomRules.classic(1)) and not RoomRules.needs_new({"rounds": 3, "ammo": true, "walls": true, "frags": true}),
		"room rules: a room with only today's four rules lets an older build in")
	_check(RoomRules.needs_new({"hp": 100}) and RoomRules.needs_new({"gun": "random"}) and RoomRules.needs_new({"zone": false}),
		"room rules: a room whose other rules differ keeps an older build out (it would play them as today's)")


func _fighter_rules() -> void:
	var f := Fighter.new()
	f.set_loadout("ar")
	var base_speed := f.move_speed()
	f.rule_speed = RoomRules.new({"speed": 150}).speed_mult()
	_check(is_equal_approx(f.move_speed(), base_speed * 1.5), "room rules: MOVEMENT SPEED 150% moves a fighter half as fast again")
	var j := RoomRules.new({"jump": 200}).jump_mult()
	_check(is_equal_approx(j * j, 2.0), "room rules: JUMP HEIGHT 200% takes off sqrt(2) as fast (twice as high)")
	f.hp_max = RoomRules.new({"hp": 100}).hp()
	f.medkits = 1
	f.hp = 100.0
	_check(not f.start_heal(), "room rules: no heal above the room's HP (it is the most a fighter has)")
	f.free()


func _arena_rules() -> void:
	var a: Node = ArenaCode.new()
	a.set("rules", RoomRules.new({"walls": true}))
	_check(int(a.call("spawn_cap", "wall")) == ArenaCode.ROOM_SPAWN_CAP and int(a.call("spawn_cap", "grenade")) == Fighter.START_GRENADES,
		"room rules: UNLIMITED WALLS raises the walls' cap only")
	a.set("rules", RoomRules.new({"throw": false, "walls": true}))
	_check(int(a.call("spawn_cap", "wall")) == 0 and int(a.call("spawn_cap", "grenade")) == 0, "room rules: without throwables no wall or frag is allowed")
	a.set("rules", RoomRules.new())
	_check(int(a.call("spawn_cap", "wall")) == Fighter.START_SHIELDS and String(a.call("forced_pick")) == "", "room rules: a normal match keeps the walls' cap and the pick")
	a.set("rules", RoomRules.new({"gun": "fixed", "gun_id": "sniper"}))
	_check(String(a.call("forced_pick")) == "sniper", "room rules: ONE GUN gives that gun at every pick round")
	var r := RoomRules.new({"gun": "random"})
	var seen := {}
	for i in 40:
		seen[r.forced_gun(i)] = true
	_check(r.forced_gun(77) == r.forced_gun(77) and seen.size() > 3 and Weapons.PICKABLE.has(r.forced_gun(5)),
		"room rules: RANDOM draws a pickable gun, the same for the same draw (every phone alike)")
	a.set("rules", RoomRules.new({"zone": false}))
	a.set("elapsed", RoundRules.STAGE1_S + 30.0)
	a.set("zone_warning", "X")
	a.call("_update_zone", 0.5)
	_check(String(a.get("zone_state")) == "stationary" and String(a.get("zone_warning")) == "",
		"room rules: without the zone it never closes (still the whole hall after stage 1)")
	a.free()
	var p := Player.new()
	_check(p.room_assist, "room rules: aim assist is on unless a room turns it off")
	p.room_assist = false
	_check(not p._assist_active(), "room rules: NO AIM ASSIST turns the assist off whatever the player's setting")
	p.free()
