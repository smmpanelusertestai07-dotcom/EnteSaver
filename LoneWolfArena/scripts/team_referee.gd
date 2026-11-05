class_name TeamReferee
extends RefCounted
## STEP-0 SKELETON (contract). Owner after step 0: WP-C (gameplay).
## The rules of a DUO / SQUAD round with no scene (the offline arena and the online host run this
## one; the unit tests drive it): every slot is UP, KNOCKED or OUT. A fighter whose HP runs out
## while a teammate is still UP is KNOCKED, else OUT, and its KNOCKED teammates go OUT with it (the
## team is wiped). A KNOCKED fighter finished off (hits, the zone, bleeding out) is OUT; the kill
## goes to the finisher when it is an enemy, else to the one who knocked it. A revive needs the
## target KNOCKED and the reviver UP on the same team. A team with nobody UP loses the round.

const UP := 0
const KNOCKED := 1
const OUT := 2

var team := {}                            # slot -> 0 / 1
var status := {}                          # slot -> UP / KNOCKED / OUT
var knocker := {}                         # slot -> the slot that knocked it (-1)
var left := {}                            # slot -> true: left the match (OUT every round)


func setup(slot_teams: Dictionary) -> void:
	team = slot_teams.duplicate()
	reset_round()


## Everyone UP again (but those who left).
func reset_round() -> void:
	for s: int in team:
		status[s] = OUT if left.has(s) else UP
		knocker[s] = -1


## A fighter went down: its HP ran out (finished false) or, KNOCKED, its knock HP did (finished
## true). Returns the decisions in order, each [kind, slot, killer, headshot, cause] with kind "ko"
## (knocked) or "el" (out); [] when nothing changes (already OUT).
func down(_slot: int, _killer: int, _headshot: bool, _cause: String, _finished: bool) -> Array:
	return []


## A finished revive: true when it stands (the target is UP again).
func revive(_reviver: int, _target: int) -> bool:
	return false


## A member left the match: OUT now and every round after; the decisions as down() returns them.
func leave(_slot: int) -> Array:
	return []


func up_count(t: int) -> int:
	var n := 0
	for s: int in team:
		if int(team[s]) == t and int(status.get(s, OUT)) == UP:
			n += 1
	return n


## The round as it stands: 0 or 1 won (the other team has nobody UP), 2 both down (a draw), -1 on.
func winner() -> int:
	return -1


## At the time-out: the team whose UP fighters have more HP in all (hp: slot -> HP); -1 a draw.
func timeout_winner(_hp: Dictionary) -> int:
	return -1
