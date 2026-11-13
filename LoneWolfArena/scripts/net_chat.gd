class_name NetChat
extends RefCounted
## Text chat, end-to-end encrypted, with no account and no server of our own (see Cloud):
##  - in an online match (HudNet): quick messages (QUICK, our own short phrases) or free text, at
##    most MATCH_MAX characters, over the match room's own encryption (AES-256 + HMAC, Cloud
##    send_chat), at most one per RATE_S (the other phone drops faster ones), shown in a small feed
##    that can be muted. Setting CHAT (ON / OFF).
##  - with a friend (LobbyChat, the CHAT button of a friend's row or player card): at most
##    FRIEND_MAX characters, encrypted with the friend's public key (RSA: only their phone can read
##    it) and signed with this phone's key over every field (`fchat_text`). It goes out as a
##    RETAINED message on ROOT/fm/<to>/<from>, so a friend who is online gets it at once and one who
##    is offline finds the last unread one when the game next connects; their phone deletes it from
##    the relay once read. The last HISTORY_MAX messages with each friend are kept on this phone
##    only (CHAT_PATH, left out of phone backups like every save). Setting FRIENDS CHAT (FRIENDS
##    ONLY / OFF): only friends, never a blocked player.
## Text: Game.clean_text's characters (A-Z, 0-9, space, _ - .) plus EXTRA punctuation, upper case,
## accented letters folded to plain ones, everything else left out.

const MATCH_MAX := 60
const FRIEND_MAX := 100
const RATE_S := 2.0               # match chat: one line per this many seconds
const FRIEND_RATE_MS := 1000      # friends chat: one message a second at most
const HISTORY_MAX := 50
const EXTRA := [",", "!", "?", "'", ":", "(", ")", "+", "/", "#"]
const QUICK := ["GG", "NICE SHOT!", "WAIT!", "REMATCH?", "GOOD LUCK!", "WELL PLAYED", "OOPS!", "HELLO!"]
const CHAT_PATH := "user://chat.json"
const GameCode := preload("res://autoload/game.gd")       # its static helpers
const MAX_AGE_S := 30 * 86400     # a waiting message older than this is dropped (Cloud.REQUEST_MAX_AGE_S)

## id -> {"pk": friend's public key (as last seen), "last": newest received ts, "sent": newest sent
## ts, "unread": n, "msgs": [[ts, mine, text], ...] oldest first}
static var _store := {}
static var _loaded := false


## Chat text as others see it: upper case, the name characters plus EXTRA, single spaces, at most
## max_len characters.
static func clean(t: String, max_len: int) -> String:
	var out := ""
	for ch in t.strip_edges().to_upper():
		if (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9") or ch in ["_", "-", "."] or ch in EXTRA:
			out += ch
		elif ch == " " or ch == "\t" or ch == "\n":
			if not out.ends_with(" "):
				out += " "
		elif ch >= "À":
			out += GameCode._fold_letter(ch)
	return out.strip_edges().substr(0, max_len).strip_edges()


# ---------------------------------------------------------------- friends: sealed messages

## What a friend message signs: every field, so none can be changed or moved to another pair.
static func fchat_text(from: String, to: String, ts: int, c: String) -> String:
	return "fchat|%s|%s|%d|%s" % [from, to, ts, c]


## A message to `to` (public key `their_pk`) as published: the text encrypted to their key, signed
## with `key` (this phone's, public key `my_pk`). {} when their key does not load or the text does
## not fit.
static func seal(text: String, from: String, to: String, ts: int, their_pk: String, key: CryptoKey, my_pk: String) -> Dictionary:
	var pub := CryptoKey.new()
	if their_pk.length() > 1200 or pub.load_from_string(their_pk, true) != OK:
		return {}
	var raw := text.to_utf8_buffer()
	if raw.is_empty() or raw.size() > 200:
		return {}
	var crypto := Crypto.new()
	var enc := crypto.encrypt(pub, raw)
	if enc.is_empty():
		return {}
	var c := Marshalls.raw_to_base64(enc)
	var sig := Marshalls.raw_to_base64(crypto.sign(HashingContext.HASH_SHA256, fchat_text(from, to, ts, c).sha256_buffer(), key))
	return {"t": "fchat", "from": from, "to": to, "ts": ts, "c": c, "pk": my_pk, "sig": sig}


## The text of a message from `from` to `me` (`key`: this phone's private key), "" unless every
## check passes: the fields' types, the sender's key matching its id, its signature, the time (not
## older than MAX_AGE_S, not ahead by more than 10 min, newer than `last_ts`, the newest message
## already read from them) and the text after `clean`.
static func open_message(d: Dictionary, from: String, me: String, key: CryptoKey, now: int, last_ts: int) -> String:
	for k in ["from", "to", "c", "pk", "sig"]:
		if typeof(d.get(k)) != TYPE_STRING:
			return ""
	var tsv: Variant = d.get("ts")
	if not (tsv is float or tsv is int) or String(d.get("t", "")) != "fchat":
		return ""
	var ts := int(tsv)
	if String(d.from) != from or String(d.to) != me or from == me or String(d.pk).length() > 1200 \
			or from != String(d.pk).sha256_text().left(32) or ts > now + 600 or now - ts > MAX_AGE_S or ts <= last_ts \
			or String(d.c).length() > 400:
		return ""
	if not Cloud.verify_signed(String(d.pk), fchat_text(from, me, ts, String(d.c)), String(d.sig)):
		return ""
	var raw := Crypto.new().decrypt(key, Marshalls.base64_to_raw(String(d.c)))
	if raw.is_empty():
		return ""
	return clean(raw.get_string_from_utf8(), FRIEND_MAX)


# ---------------------------------------------------------------- friends: this phone's copy

static func _load() -> void:
	if _loaded:
		return
	_loaded = true
	_store = {}
	if Game.autotest != "":
		return                       # automated runs keep it in memory only
	var d := GameCode.read_json(CHAT_PATH)
	var friends: Variant = d.get("friends")
	if not friends is Dictionary:
		return
	for id: Variant in friends:
		var e: Variant = (friends as Dictionary)[id]
		if Game.is_player_id(id) and e is Dictionary:
			var msgs := []
			var src: Variant = (e as Dictionary).get("msgs")
			if src is Array:
				for m: Variant in src:
					if m is Array and (m as Array).size() == 3 and (m[0] is float or m[0] is int) and m[1] is bool and m[2] is String:
						msgs.append([int(m[0]), bool(m[1]), clean(String(m[2]), FRIEND_MAX)])
			_store[id] = {"pk": String((e as Dictionary).get("pk", "")) if (e as Dictionary).get("pk") is String else "",
				"last": _int((e as Dictionary).get("last")), "sent": _int((e as Dictionary).get("sent")),
				"unread": clampi(_int((e as Dictionary).get("unread")), 0, HISTORY_MAX), "msgs": msgs.slice(-HISTORY_MAX)}


static func _int(v: Variant) -> int:
	return int(v) if (v is float or v is int) else 0


static func _save() -> void:
	if Game.autotest == "":
		GameCode.write_json(CHAT_PATH, {"v": 1, "friends": _store})


static func _entry(id: String) -> Dictionary:
	_load()
	if not _store.has(id):
		_store[id] = {"pk": "", "last": 0, "sent": 0, "unread": 0, "msgs": []}
	return _store[id]


## The messages with a friend, oldest first: [[ts, mine, text], ...].
static func messages(id: String) -> Array:
	_load()
	return (_store[id].msgs as Array).duplicate() if _store.has(id) else []


## Adds a message (sent: mine; received: counts as unread) and keeps the last HISTORY_MAX.
static func add(id: String, ts: int, mine: bool, text: String) -> void:
	var e := _entry(id)
	var msgs: Array = e.msgs
	msgs.append([ts, mine, text])
	while msgs.size() > HISTORY_MAX:
		msgs.pop_front()
	if mine:
		e.sent = maxi(int(e.sent), ts)
	else:
		e.last = maxi(int(e.last), ts)
		e.unread = mini(int(e.unread) + 1, HISTORY_MAX)
	_save()


static func unread(id: String) -> int:
	_load()
	return int(_store[id].unread) if _store.has(id) else 0


## The unread messages from friends (not blocked) in all: the lobby's ONLINE 1 VS 1 badge. 0 while
## FRIENDS CHAT is off.
static func unread_total() -> int:
	_load()
	if not bool(Game.settings.get("friend_chat", true)):
		return 0
	var n := 0
	for id: String in _store:
		if Game.is_friend(id) and not Game.is_blocked(id):
			n += int(_store[id].unread)
	return n


## A message's first words for a short notice: the whole text when it fits in max_len characters,
## else the words that fit (a word cut in two is left out when a space comes after half of it)
## and "...".
static func first_words(text: String, max_len := 34) -> String:
	if text.length() <= max_len:
		return text
	var cut := text.substr(0, max_len)
	var sp := cut.rfind(" ")
	if text[max_len] != " " and sp >= max_len * 0.5:
		cut = cut.substr(0, sp)
	return cut.strip_edges() + "..."


## What all the unread counts are, in one string (a list redraws when it changes).
static func unread_key() -> String:
	_load()
	var parts := PackedStringArray()
	for id: String in _store:
		if int(_store[id].unread) > 0:
			parts.append("%s%d" % [id.left(6), int(_store[id].unread)])
	return ",".join(parts)


static func mark_read(id: String) -> void:
	_load()
	if _store.has(id) and int(_store[id].unread) > 0:
		_store[id].unread = 0
		_save()


static func last_received(id: String) -> int:
	_load()
	return int(_store[id].last) if _store.has(id) else 0


static func last_sent(id: String) -> int:
	_load()
	return int(_store[id].sent) if _store.has(id) else 0


## A friend's public key as last seen (their messages and card carry it): their id is its hash.
static func cached_key(id: String) -> String:
	_load()
	var pk := String(_store[id].pk) if _store.has(id) else ""
	return pk if pk != "" and pk.sha256_text().left(32) == id else ""


static func cache_key(id: String, pk: String) -> void:
	if pk.sha256_text().left(32) != id or cached_key(id) == pk:
		return
	_entry(id).pk = pk
	_save()


## Forgets a player's messages (they were removed as a friend or blocked).
static func forget(id: String) -> void:
	_load()
	if _store.erase(id):
		_save()


# ---------------------------------------------------------------- team / room chat
## The TEAM chat (a group's) and the ROOM chat (a custom room's: a room is a group too): text over
## the group room's own end-to-end encryption (Cloud.send_group_chat, "gchat"), at most FRIEND_MAX
## characters, one message a second from a phone (the others drop faster ones: Cloud's group rate).
## Kept in memory only, for the group it was said in (a new group starts empty): [[ts, mine, name,
## text], ...], the last HISTORY_MAX.
static var _group := {"gid": "", "msgs": [], "unread": 0}


static func group_add(gid: String, ts: int, mine: bool, who: String, text: String) -> void:
	if String(_group.gid) != gid:
		_group = {"gid": gid, "msgs": [], "unread": 0}
	var msgs: Array = _group.msgs
	msgs.append([ts, mine, who, text])
	while msgs.size() > HISTORY_MAX:
		msgs.pop_front()
	if not mine:
		_group.unread = mini(int(_group.unread) + 1, HISTORY_MAX)


## The group's messages, oldest first ([] for another group than the one they were said in).
static func group_messages(gid: String) -> Array:
	return (_group.msgs as Array).duplicate() if gid != "" and String(_group.gid) == gid else []


static func group_unread(gid: String) -> int:
	return int(_group.unread) if gid != "" and String(_group.gid) == gid else 0


static func group_mark_read(gid: String) -> void:
	if String(_group.gid) == gid:
		_group.unread = 0


## Tests: an empty, unsaved store.
static func reset_for_test() -> void:
	_store = {}
	_group = {"gid": "", "msgs": [], "unread": 0}
	_loaded = true
