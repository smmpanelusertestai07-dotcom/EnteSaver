class_name TeamReferee
extends RefCounted
## The rules of a DUO / SQUAD round with no scene (the offline arena and the online host run this
## one; the unit tests drive it): every slot is UP, KNOCKED or OUT. A fighter whose HP runs out
## while a teammate is still UP is KNOCKED, else OUT, and its KNOCKED teammates go OUT with it (the
## team is wiped). A KNOCKED fighter finished off (hits, the zone, bleeding out) is OUT; the kill
## goes to the finisher when it is an enemy, else to the one who knocked it. A revive needs the
## target KNOCKED and the reviver UP on the same team. A team with nobody UP loses the round.
## Slots are the roster's (Game.team_match); -1 as a killer means nobody (the zone, a fall).

const UP := 0
const KNOCKED := 1
const OUT := 2

var team := {}                            # slot -> 0 / 1
var status := {}                          # slot -> UP / KNOCKED / OUT
var knocker := {}                         # slot -> the slot that knocked it (-1)
var left := {}                            # slot -> true: left the match (OUT every round)
var knock_cause := {}                     # slot -> what knocked it ("gun", "frag", "zone", ...)


func setup(slot_teams: Dictionary) -> void:
	team = slot_teams.duplicate()
	reset_round()


## Everyone UP again (but those who left).
func reset_round() -> void:
	for s: int in team:
		status[s] = OUT if left.has(s) else UP
		knocker[s] = -1
		knock_cause[s] = ""


## A fighter went down: its HP ran out (finished false) or, KNOCKED, its knock HP did (finished
## true). Returns the decisions in order, each [kind, slot, killer, headshot, cause] with kind "ko"
## (knocked) or "el" (out); [] when nothing changes (already OUT).
func down(slot: int, killer: int, headshot: bool, cause: String, _finished: bool) -> Array:
	if not team.has(slot):
		return []
	var st := int(status.get(slot, OUT))
	if st == OUT:
		return []
	if st == KNOCKED:
		# Finished off (or bled out): the kill is the finisher's when an enemy did it, else the
		# knocker's (the zone, a fall or bleeding out after their knock).
		var by := killer if killer >= 0 and team.has(killer) and int(team[killer]) != int(team[slot]) else int(knocker.get(slot, -1))
		status[slot] = OUT
		return [["el", slot, by, headshot and by == killer, cause]]
	if _teammate_up(slot):
		status[slot] = KNOCKED
		knocker[slot] = killer if killer != slot else -1
		knock_cause[slot] = cause
		return [["ko", slot, killer, headshot, cause]]
	status[slot] = OUT
	return [["el", slot, killer, headshot, cause]] + _wipe(int(team[slot]))


## A finished revive: true when it stands (the target is UP again).
func revive(reviver: int, target: int) -> bool:
	if reviver == target or not team.has(reviver) or not team.has(target) or int(team[reviver]) != int(team[target]):
		return false
	if int(status.get(target, OUT)) != KNOCKED or int(status.get(reviver, OUT)) != UP:
		return false
	status[target] = UP
	knocker[target] = -1
	knock_cause[target] = ""
	return true


## A member left the match: OUT now and every round after; the decisions as down() returns them.
func leave(slot: int) -> Array:
	if not team.has(slot) or left.has(slot):
		return []
	left[slot] = true
	if int(status.get(slot, OUT)) == OUT:
		return []
	status[slot] = OUT
	var out := [["el", slot, -1, false, "left"]]
	if up_count(int(team[slot])) == 0:
		out += _wipe(int(team[slot]))
	return out


func up_count(t: int) -> int:
	var n := 0
	for s: int in team:
		if int(team[s]) == t and int(status.get(s, OUT)) == UP:
			n += 1
	return n


## The round as it stands: 0 or 1 won (the other team has nobody UP), 2 both down (a draw), -1 on.
func winner() -> int:
	var up0 := up_count(0)
	var up1 := up_count(1)
	if up0 == 0 and up1 == 0:
		return 2
	if up1 == 0:
		return 0
	if up0 == 0:
		return 1
	return -1


## At the time-out: the team whose UP fighters have more HP in all (hp: slot -> HP); -1 a draw.
## KNOCKED and OUT fighters count 0.
func timeout_winner(hp: Dictionary) -> int:
	var sum := [0.0, 0.0]
	for s: int in team:
		if int(status.get(s, OUT)) == UP and hp.has(s):
			sum[int(team[s])] += maxf(float(hp[s]), 0.0)
	if absf(sum[0] - sum[1]) < 0.5:
		return -1
	return 0 if sum[0] > sum[1] else 1


func _teammate_up(slot: int) -> bool:
	for s: int in team:
		if s != slot and int(team[s]) == int(team[slot]) and int(status.get(s, OUT)) == UP:
			return true
	return false


## The team has nobody UP: its KNOCKED members go OUT (each the kill of the one who knocked it).
func _wipe(t: int) -> Array:
	var out := []
	for s: int in team:
		if int(team[s]) == t and int(status.get(s, OUT)) == KNOCKED:
			status[s] = OUT
			out.append(["el", s, int(knocker.get(s, -1)), false, String(knock_cause.get(s, "gun"))])
	return out
