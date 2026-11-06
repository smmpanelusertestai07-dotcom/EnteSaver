class_name NetGroup
extends RefCounted
## The slot rules of a lobby GROUP (Cloud's group protocol, design/GROUPS.txt) as plain data, so
## Cloud, the lobby and the unit tests share them. A member is {"id", "name", "bundle", "team",
## "slot"}: team 0 is BLUE, 1 ORANGE; slot is the roster slot of the match the group would start
## (team 0 holds slots 0..per-1, team 1 per..2 x per-1, per = per_team(size)). A slot nobody holds
## stays empty: an all-human match never fills it with a bot, so teams may be uneven (1 VS 2,
## 1 VS 3). The leader may arrange the sides (Cloud.set_group_team); until then arrange() gives the
## default sides. The same structure (a host, a size, members in slots) is meant to serve the
## CUSTOM ROOM with slots too: a group is a private room that players join by invite.

const MAX := 4                  # players in a group (Cloud.GROUP_MAX)


## Players a team may have in a match of this size: SQUAD 4, DUO (and a group without a team size
## yet, SOLO) 2.
static func per_team(size: int) -> int:
	return 4 if size == 4 else 2


## Gives every member a team and a slot. Default (manual false), as GROUPS.txt: DUO up to two
## players all BLUE (a search finds the other team), three 2 VS 1, four 2 VS 2 (the leader and the
## first to join BLUE); SQUAD everyone BLUE. manual: the leader's own sides stay; a member without a
## valid place (new, or the size changed under it) takes the first free slot, BLUE first.
static func arrange(members: Array, size: int, manual: bool) -> void:
	var per := per_team(size)
	var taken := {}
	for i in members.size():
		var m: Dictionary = members[i]
		var t := int(m.get("team", -1))
		var s := int(m.get("slot", -1))
		if not manual:
			m["team"] = 1 if per == 2 and members.size() >= 3 and i >= 2 else 0
			m["slot"] = -1
		elif t in [0, 1] and s >= t * per and s < (t + 1) * per and not taken.has(s):
			taken[s] = true
		else:
			m["team"] = -1
			m["slot"] = -1
	for m: Dictionary in members:
		if int(m.slot) >= 0:
			continue
		var want := int(m.team) if int(m.team) in [0, 1] else 0
		for t: int in [want, 1 - want]:
			var s := first_free(taken, t, per)
			if s >= 0:
				m["team"] = t
				m["slot"] = s
				taken[s] = true
				break


static func first_free(taken: Dictionary, team: int, per: int) -> int:
	for s in range(team * per, (team + 1) * per):
		if not taken.has(s):
			return s
	return -1


## The leader moves member `id` to `team` (0 / 1) and `slot` (-1: the first free one of that team).
## A slot held by another member swaps the two. False when the move cannot be (no such member, a
## slot outside that team, a full team).
static func move(members: Array, id: String, team: int, slot: int, size: int) -> bool:
	var per := per_team(size)
	if team not in [0, 1]:
		return false
	var who := {}
	var taken := {}
	for m: Dictionary in members:
		if String(m.id) == id:
			who = m
		else:
			taken[int(m.slot)] = true
	if who.is_empty():
		return false
	if slot < 0:
		slot = int(who.slot) if int(who.team) == team else first_free(taken, team, per)
	if slot < team * per or slot >= (team + 1) * per:
		return false
	for m: Dictionary in members:
		if m != who and int(m.slot) == slot:
			m["team"] = who.team
			m["slot"] = who.slot
	who["team"] = team
	who["slot"] = slot
	return true


## What the leader's START does with these sides: "match" (both teams have a player: the group plays
## among itself at once, uneven allowed), "search" (one side only: a search finds the other team),
## else the notice why not.
static func plan(members: Array, size: int) -> String:
	var per := per_team(size)
	var n := [0, 0]
	for m: Dictionary in members:
		n[clampi(int(m.get("team", 0)), 0, 1)] += 1
	if n[0] > per or n[1] > per:
		return "A TEAM HAS MORE THAN %d PLAYERS" % per
	if n[0] >= 1 and n[1] >= 1:
		return "match"
	return "search"


## The match's roster from the members: [{"slot", "id", "name", "bundle", "team"}] in slot order.
static func match_roster(members: Array) -> Array:
	var out := []
	for m: Dictionary in members:
		out.append({"slot": int(m.slot), "id": String(m.id), "name": String(m.name), "bundle": String(m.bundle), "team": int(m.team)})
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.slot) < int(b.slot))
	return out


## Members as "groster" carries them: [[id, name, bundle, team, slot], ...] in join order.
static func pack_members(members: Array) -> Array:
	var out := []
	for m: Dictionary in members:
		out.append([String(m.id), String(m.name), String(m.bundle), int(m.team), int(m.slot)])
	return out


## A leader's "groster" members off the wire (untrusted, though only a key holder could send it):
## at most MAX, the leader first, ids real and unique, teams 0 / 1 with slots in their range and
## unique, names cleaned, outfits known. [] when anything is off.
static func members_from(v: Variant, leader: String, size: int) -> Array:
	if not v is Array or (v as Array).is_empty() or (v as Array).size() > MAX:
		return []
	var per := per_team(size)
	var out := []
	var ids := {}
	var used := {}
	for e: Variant in v:
		if not e is Array or (e as Array).size() != 5:
			return []
		var a := e as Array
		if typeof(a[0]) != TYPE_STRING or typeof(a[1]) != TYPE_STRING or typeof(a[2]) != TYPE_STRING or not _whole(a[3]) or not _whole(a[4]):
			return []
		var id := String(a[0])
		var t := int(a[3])
		var s := int(a[4])
		if not Game.is_player_id(id) or ids.has(id) or t not in [0, 1] or s < t * per or s >= (t + 1) * per or used.has(s):
			return []
		ids[id] = true
		used[s] = true
		out.append({"id": id, "name": _name(a[1]), "bundle": _bundle(a[2]), "team": t, "slot": s})
	return out if String(out[0].id) == leader else []


## A match roster as "gstart" carries it: [[slot, id, name, bundle, team], ...].
static func pack_roster(roster: Array) -> Array:
	var out := []
	for e: Dictionary in roster:
		out.append([int(e.slot), String(e.id), String(e.name), String(e.bundle), int(e.team)])
	return out


## A "gstart" roster off the wire: 2..2 x per players, each team 1..per, slots in their team's
## range and unique, ids real and unique. [] when anything is off.
static func roster_from(v: Variant, size: int) -> Array:
	var per := per_team(size)
	if size not in [2, 4] or not v is Array or (v as Array).size() < 2 or (v as Array).size() > 2 * per:
		return []
	var out := []
	var ids := {}
	var used := {}
	var n := [0, 0]
	for e: Variant in v:
		if not e is Array or (e as Array).size() != 5:
			return []
		var a := e as Array
		if not _whole(a[0]) or typeof(a[1]) != TYPE_STRING or typeof(a[2]) != TYPE_STRING or typeof(a[3]) != TYPE_STRING or not _whole(a[4]):
			return []
		var s := int(a[0])
		var id := String(a[1])
		var t := int(a[4])
		if not Game.is_player_id(id) or ids.has(id) or t not in [0, 1] or s < t * per or s >= (t + 1) * per or used.has(s):
			return []
		ids[id] = true
		used[s] = true
		n[t] += 1
		out.append({"slot": s, "id": id, "name": _name(a[2]), "bundle": _bundle(a[3]), "team": t})
	if n[0] < 1 or n[1] < 1:
		return []
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.slot) < int(b.slot))
	return out


static func _whole(v: Variant) -> bool:
	return (v is int or v is float) and is_finite(float(v)) and float(v) == floorf(float(v))


static func _name(v: Variant) -> String:
	var who := Game.clean_name(String(v).left(64))
	return who if who != "" else "PLAYER"


static func _bundle(v: Variant) -> String:
	return String(CharacterModel.bundle_info(String(v).left(32)).id)


## MATCHMAKING ("gseek"): which searching units make one match. `units` [{"n": players}, ...] with
## the deciding host's own unit first; each unit is a group (or a solo) kept whole on one team.
## Returns [[unit index, team], ...] whose players fill both teams exactly (per = per_team(size)
## each), the host's unit always in it on BLUE; [] when the units seen cannot fill a match yet.
static func pick_units(units: Array, size: int) -> Array:
	var per := per_team(size)
	var picked: Array = []
	if units.is_empty() or int(units[0].get("n", 0)) < 1 or int(units[0].get("n", 0)) > per:
		return []
	picked.append([0, 0])
	var fill := [int(units[0].n), 0]
	return picked if _fit(units.slice(0, 9), per, 1, fill, picked) else []


static func _fit(units: Array, per: int, i: int, fill: Array, picked: Array) -> bool:
	if int(fill[0]) == per and int(fill[1]) == per:
		return true
	if i >= units.size():
		return false
	var n := int(units[i].get("n", 0))
	if n >= 1:
		for t: int in [0, 1]:
			if int(fill[t]) + n <= per:
				fill[t] = int(fill[t]) + n
				picked.append([i, t])
				if _fit(units, per, i + 1, fill, picked):
					return true
				fill[t] = int(fill[t]) - n
				picked.pop_back()
	return _fit(units, per, i + 1, fill, picked)


## A searching unit's members as "gseek" carries them ([[id, name, bundle], ...], its leader
## first): 1..per players, ids real and unique, the first `leader`. [] when anything is off.
static func unit_from(v: Variant, leader: String, size: int) -> Array:
	if not v is Array or (v as Array).is_empty() or (v as Array).size() > per_team(size):
		return []
	var out := []
	var ids := {}
	for e: Variant in v:
		if not e is Array or (e as Array).size() != 3:
			return []
		var a := e as Array
		if typeof(a[0]) != TYPE_STRING or typeof(a[1]) != TYPE_STRING or typeof(a[2]) != TYPE_STRING:
			return []
		var id := String(a[0])
		if not Game.is_player_id(id) or ids.has(id):
			return []
		ids[id] = true
		out.append({"id": id, "name": _name(a[1]), "bundle": _bundle(a[2])})
	return out if String(out[0].id) == leader else []
