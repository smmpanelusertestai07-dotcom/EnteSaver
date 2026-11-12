class_name RoundRules
extends RefCounted
## The rules of a round that every arena (1 vs 1, DUO, SQUAD) and both phones of an online match
## work out alike, kept as pure functions so the unit tests can check them:
##  - the TWO-STAGE CLOCK: a round's fight is stage 1 (STAGE1_S) and then stage 2 (the arena's
##    stage2 length: STAGE2_S, SQUAD_STAGE2_S); fighting is allowed in both, the top clock counts
##    each stage down on its own, and at the end of stage 2 the time-out decides;
##  - the SAFE ZONE: through stage 1 it covers the whole hall and stays put; from the first second
##    of stage 2 it closes continuously and evenly to ZONE_FINAL_R exactly when stage 2 ends, its
##    centre sliding from the map's centre to the round's final centre;
##  - the 1 vs 1 WEAPON COOLDOWN: a gun picked for a pair of rounds cannot be picked again for the
##    next COOLDOWN_ROUNDS rounds, whoever picks.

const STAGE1_S := 20.0
const STAGE2_S := 90.0              # the 1 vs 1 and DUO
const SQUAD_STAGE2_S := 120.0
const ZONE_FINAL_R := 0.5           # m: the zone's radius when stage 2 ends
const COOLDOWN_ROUNDS := 4
const PICK_ROUNDS := 2              # one pick holds for this many rounds


## The whole fight of a round (s): both stages.
static func fight_time(stage2: float) -> float:
	return STAGE1_S + stage2


## The stage (1 or 2) at `elapsed` s into the fight.
static func stage_at(elapsed: float) -> int:
	return 1 if elapsed < STAGE1_S else 2


## What the top clock shows at `elapsed` s into the fight: the seconds left of the current stage.
static func stage_left(elapsed: float, stage2: float) -> float:
	if elapsed < STAGE1_S:
		return STAGE1_S - elapsed
	return maxf(STAGE1_S + stage2 - elapsed, 0.0)


## How far the zone has closed at `elapsed` (0 through stage 1, 1 when stage 2 ends).
static func zone_t(elapsed: float, stage2: float) -> float:
	return clampf((elapsed - STAGE1_S) / maxf(stage2, 0.01), 0.0, 1.0)


## The zone's radius at `elapsed`: `start` (the whole hall) through stage 1, then evenly down to
## ZONE_FINAL_R at the end of stage 2.
static func zone_radius_at(elapsed: float, start: float, stage2: float) -> float:
	return lerpf(start, ZONE_FINAL_R, zone_t(elapsed, stage2))


## The zone's centre at `elapsed`: `from` (the map's centre) through stage 1, then evenly to `to`.
static func zone_center_at(elapsed: float, from: Vector3, to: Vector3, stage2: float) -> Vector3:
	return from.lerp(to, zone_t(elapsed, stage2))


## Seconds until the zone changes state: to the start of the closing in stage 1, to the end of the
## closing in stage 2, 0 once closed.
static func zone_next(elapsed: float, stage2: float) -> float:
	if elapsed < STAGE1_S:
		return STAGE1_S - elapsed
	return maxf(STAGE1_S + stage2 - elapsed, 0.0)


## The round that opens the pick pair round `r` belongs to (1, 3, 5, ...).
static func pick_round_of(r: int) -> int:
	return r - (r - 1) % PICK_ROUNDS


## The rounds the pick of round `r` holds for, as the pick panel's header names them: "ROUNDS 3-4",
## or "ROUND 9" when the pair's second round would be past the match's `last` round.
static func pick_span(r: int, last: int) -> String:
	var first := pick_round_of(r)
	var second := mini(first + PICK_ROUNDS - 1, maxi(last, first))
	return "ROUND %d" % first if second <= first else "ROUNDS %d-%d" % [first, second]


## Rounds a gun still waits before it can be picked again, at the pick of round `r`: `picks` maps
## each earlier pick round to the gun picked for it. A gun picked for rounds p and p + 1 is out for
## rounds p + 2 .. p + 1 + COOLDOWN_ROUNDS (shown as 4 ROUNDS at the next pick, 2 at the one after).
static func cooldown_left(gun: String, r: int, picks: Dictionary) -> int:
	var left := 0
	for p: int in picks:
		if String(picks[p]) != gun or p >= r:
			continue
		var last_out := p + PICK_ROUNDS - 1 + COOLDOWN_ROUNDS
		if r <= last_out:
			left = maxi(left, last_out - r + 1)
	return left


## The guns of `options` on cooldown at the pick of round `r`: gun -> rounds left.
static func cooldowns(options: Array, r: int, picks: Dictionary) -> Dictionary:
	var out := {}
	for g: String in options:
		var n := cooldown_left(g, r, picks)
		if n > 0:
			out[g] = n
	return out


## The first gun of `options` that is free at round `r` (the first option if none is).
static func first_free(options: Array, r: int, picks: Dictionary) -> String:
	for g: String in options:
		if cooldown_left(g, r, picks) == 0:
			return g
	return String(options[0]) if not options.is_empty() else ""


## The gun a pick of `gun` for round `r` gives: itself when it is one of `options` and free, else
## the first free one (both phones replace a pick that breaks the cooldown alike).
static func legal_pick(gun: String, options: Array, r: int, picks: Dictionary) -> String:
	if options.has(gun) and cooldown_left(gun, r, picks) == 0:
		return gun
	return first_free(options, r, picks)


## The rounds strip of the pick panel: for each round of the match (up to `last`), whether this
## player picks its gun, given whether it picks for the first pair (the picks alternate by pair).
static func picker_rows(last: int, i_pick_first: bool) -> Array:
	var out := []
	for r in range(1, last + 1):
		var first_pair := ((r - 1) / PICK_ROUNDS) % 2 == 0
		out.append(first_pair == i_pick_first)
	return out


## "a:b,c:d" of a picks dictionary (pick round -> gun), for the online "sync".
static func picks_text(picks: Dictionary) -> String:
	var parts := PackedStringArray()
	var keys := picks.keys()
	keys.sort()
	for p: int in keys:
		parts.append("%d:%s" % [p, String(picks[p])])
	return ",".join(parts)


## The picks dictionary back from picks_text; entries that are not a round and a known gun of
## `options` are left out.
static func picks_from_text(text: String, options: Array) -> Dictionary:
	var out := {}
	for part in text.split(",", false):
		var kv := part.split(":")
		if kv.size() == 2 and kv[0].is_valid_int() and options.has(kv[1]):
			var p := int(kv[0])
			if p >= 1 and p <= 99:
				out[p] = kv[1]
	return out
