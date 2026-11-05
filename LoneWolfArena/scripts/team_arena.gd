class_name TeamArena
extends "res://scripts/arena.gd"
## STEP-0 SKELETON v2 (contract). Owner after step 0: WP-C (gameplay). The online subclass
## TeamArenaNet (scripts/team_arena_net.gd, WP-N) overrides only the SEAMS at the end of this file.
## Until WP-C fills it in, it plays the 1 vs 1 it extends (so the lobby's routing can be tested).
## DUO (2 vs 2) and SQUAD (4 vs 4) on CARGO CAGE, first to TEAM_ROUNDS_TO_WIN rounds, set up from
## Game.team_match (autoload/game.gd). Offline (TRAINING GROUND, or a team search that found nobody:
## scenes/team_arena.tscn) everything runs on this phone. Online (scenes/team_arena_net.tscn) the
## match runs between TWO phones over Cloud's 1 vs 1 session (Game.session): the host runs every
## bot and referees, each phone runs its own player. Team 0 spawns in alcove A, team 1 in alcove B;
## on every phone the player's team is BLUE, the other ORANGE. Knock-down and revive
## (Fighter.knocked, TeamReferee), friendly fire off, spectating a teammate once out.

const TEAM_ROUNDS_TO_WIN := 4             # LW_ROUNDS_TO_WIN overrides it in test runs

var team_size := 0                        # players a team: 2 DUO, 4 SQUAD (the HUD: > 1 means a team match)
var my_team := 0                          # the player's team (0 / 1)
var my_slot := 0                          # the player's roster slot (Game.team_match.my_slot)
var slots: Array[Fighter] = []            # every fighter by its slot (Game.team_match.roster order)
var roster: Array = []                    # Game.team_match.roster
var team_score := [0, 0]                  # rounds won by team 0 / 1 (`score` mirrors it: player = mine, bot = theirs)
var referee := TeamReferee.new()


func _ready() -> void:
	team_size = int(Game.team_match.get("size", 2))
	super()


## A team match on this phone only, as Game.team_match: TRAINING GROUND DUO / SQUAD, or a player
## whose DUO / SQUAD search found nobody (TeamMatch). The player in slot 0, bots in every other
## slot (team 0 = slots 0..n-1), each bot at level `diff`; a bot's empty name and outfit are picked
## by the arena ("BOT <NAME>", a random outfit).
static func offline_match(players_a_team: int, mode_id: String, diff: int) -> Dictionary:
	var out_roster := []
	for i in players_a_team * 2:
		var me := i == 0
		out_roster.append({"slot": i, "id": "", "name": String(Game.profile.name) if me else "",
			"bundle": String(Game.profile.bundle) if me else "", "team": 0 if i < players_a_team else 1,
			"bot": not me, "diff": clampi(diff, 0, 2)})
	return {"size": players_a_team, "online": false, "coop": false, "mode_id": mode_id, "my_slot": 0, "host": true,
		"roster": out_roster}


## A team match between two phones (a TEAM INVITE: coop, both players on team 0 against bots; or a
## team QUICK MATCH: each player with bot teammates against the other), as Game.team_match. Both
## phones build the same roster from the same inputs (host / guest: {"id", "name", "bundle"}), so
## slots, teams, bot names and outfits
## agree without being sent (`seed_value`: the same number on both, e.g. from the two ids). The host
## is slot 0; the guest slot 1 (coop) or `size` (vs).
static func link_match(size: int, coop: bool, host: Dictionary, guest: Dictionary, am_host: bool, seed_value: int, diff := 1) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var guest_slot := 1 if coop else size
	var outfits := ["desert", "neon", "shadow", "royal", "default"]
	var out_roster := []
	for i in size * 2:
		var human: Dictionary = host if i == 0 else (guest if i == guest_slot else {})
		var bot_name := "BOT " + String(BOT_NAMES[rng.randi() % BOT_NAMES.size()])
		var bot_outfit := String(outfits[rng.randi() % outfits.size()])
		out_roster.append({"slot": i, "id": String(human.get("id", "")), "team": 0 if i < size else 1, "bot": human.is_empty(),
			"name": String(human.get("name", "PLAYER")) if not human.is_empty() else bot_name,
			"bundle": String(human.get("bundle", "default")) if not human.is_empty() else bot_outfit,
			"diff": clampi(diff, 0, 2)})
	return {"size": size, "online": true, "coop": coop, "mode_id": "duo" if size == 2 else "squad",
		"my_slot": 0 if am_host else guest_slot, "host": am_host, "roster": out_roster}


# ---------------------------------------------------------------- read API (HUD, results: WP-B2)

func team_of(f: Fighter) -> int:
	return f.team if f != null else -1


## On the player's team (the player too).
func ally(f: Fighter) -> bool:
	return f != null and player != null and f.team == player.team


func members(t: int) -> Array[Fighter]:
	var out: Array[Fighter] = []
	for f in slots:
		if f.team == t:
			out.append(f)
	return out


## "up" | "knocked" | "out" | "left" this round.
func status_of(f: Fighter) -> String:
	if f == null or not f.alive:
		return "out"
	return "knocked" if f.knocked else "up"


## A KNOCKED teammate within Fighter.REVIVE_RANGE of `f` (who is UP), nearest first; null when none.
func revive_candidate(_f: Fighter) -> Fighter:
	return null


## The HUD's REVIVE: `f` starts reviving `target` (Fighter.REVIVE_S standing still next to it).
func start_revive(_f: Fighter, _target: Fighter) -> bool:
	return false


func cancel_revive(_f: Fighter) -> void:
	pass


## How far a revive of `target` has come: 0..1 while a teammate revives it, -1 when nobody does
## (the knocked player's own BEING REVIVED bar, the teammates panel).
func revive_progress(_target: Fighter) -> float:
	return -1.0


## Out of the round: the camera goes to the next teammate still UP (the HUD's NEXT).
func spectate_next() -> void:
	pass


## Whom the camera follows while the player is out (null: the player's own view).
func spectated() -> Fighter:
	return null


# ---------------------------------------------------------------- SEAMS (TeamArenaNet overrides these)
# Offline (this class) every fighter runs here and this phone referees. Slots and teams are the
# roster's on every phone. Decisions, as _apply_decision takes them and _announce sends them:
#   "ko" [slot, by_slot (-1: nobody), headshot, cause]     knocked down
#   "el" [slot, by_slot, headshot, cause]                  out of the round
#   "rv" [slot, by_slot]                                   revived (by_slot did it)
#   "rend" [round, winner_team (0 / 1, -1 a draw), score0, score1, timed_out]
#   "round" [round, score0, score1]                        the next round starts
#   "pick" [slot, gun_id, round]                           a fighter's gun for this round
# Causes: "gun", "frag", "zone", "fall", "self", "bleed", "left".

## Whether this phone decides knocks, eliminations, revives and rounds (offline: yes; online: the host).
func is_referee() -> bool:
	return true


## Whether `f` is simulated on this phone (offline: every fighter; online: the player, and on the host
## also the bots). Only these take hits, report going down and run revives here.
func runs_here(_f: Fighter) -> bool:
	return true


## The fighter for one roster entry (offline: the Player for my_slot, a Bot for the others; online
## also a RemoteFighter for a fighter the other phone runs). The arena adds it to the tree.
func _fighter_for(_entry: Dictionary) -> Fighter:
	return null


## Once per physics frame before the round logic: the online subclass sends the states here.
func _net_tick(_delta: float) -> void:
	pass


## A fighter that runs here went down by itself (HP gone: finished false; knock HP gone: finished
## true). Offline / host: the referee decides now; online guest: told to the host.
func _report_down(_f: Fighter, _killer: Fighter, _headshot: bool, _cause: String, _finished: bool) -> void:
	pass


## A revive done by a fighter that runs here. Offline / host: the referee decides now; guest: told.
func _report_revive(_reviver: Fighter, _target: Fighter) -> void:
	pass


## A decision this phone made as referee (or the player's own "pick"): online it goes to the other phone.
func _announce(_kind: String, _data: Array) -> void:
	pass


## Applies a decision (the referee's own, or online the host's): fighters, kill feed, HUD, score.
func _apply_decision(_kind: String, _data: Array) -> void:
	pass


## What fighters running here do that the other phone must show (online only; Fighter calls these
## for fighters with net_local set when the arena has them, else the 1 vs 1's net_shot / ...).
func net_shot_by(_f: Fighter, _origin: Vector3, _dir: Vector3) -> void:
	pass


func net_grenade_by(_f: Fighter, _pos: Vector3, _vel: Vector3) -> void:
	pass


func net_wall_by(_f: Fighter, _pos: Vector3, _fwd: Vector3) -> void:
	pass


## RemoteFighter calls this (instead of the 1 vs 1's net_hit) for every hit a fighter running here
## lands on a fighter the other phone runs: the other phone applies it.
func net_hit_by(_target: Fighter, _attacker: Fighter, _amount: float, _zone: String, _from_pos: Vector3) -> void:
	pass
