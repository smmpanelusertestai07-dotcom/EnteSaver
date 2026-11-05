class_name TeamArenaNet
extends TeamArena
## STEP-0 SKELETON v2 (contract). Owner after step 0: WP-N (online teams). scenes/team_arena_net.tscn.
## A DUO / SQUAD match between TWO phones over Cloud's 1 vs 1 session (Game.online true,
## Game.session the Cloud whose session_team says the size and coop): the room, its keys, keep-alives,
## load stalls, the ping (Cloud.match_ping), chat, voice and the direct path are the 1 vs 1's. The
## host (Game.session.is_host) runs every bot and is the referee; each phone runs its own player and
## owns its HP (a hit on a fighter the other phone runs is sent there: net_hit_by). Overrides only the
## SEAMS of TeamArena (is_referee, runs_here, _fighter_for, _net_tick, _report_down, _report_revive,
## _announce, net_*_by) and the 1 vs 1's _on_net_state / _on_net_event / _on_net_ended; WP-C's
## rules stay in TeamArena. Messages (Cloud events, at most 16 values each):
##   "tk" [round, sent ms, "<bot states>"]   host, with its state tick: every bot's state packed in one
##                                           string (TeamArenaNet.pack_bots / unpack_bots)
##   "dn" [slot, round, by_slot, headshot, cause, finished]   the guest's own player went down
##   "rvd" [reviver_slot, target_slot, round]                 the guest's player finished a revive
##   "shot" / "grenade" / "wall" / "hit" with the fighter's slot first; "pick" [slot, gun, round]
##   host decisions as TeamArena's seams list them ("ko", "el", "rv", "rend", "round"), and "fin"
