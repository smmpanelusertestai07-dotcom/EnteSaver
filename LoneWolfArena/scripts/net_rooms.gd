class_name NetRooms
extends RefCounted
## PUBLIC custom rooms: the room list of CUSTOM ROOM (LobbyFriends, the "rooms" page).
## A room is private unless its host switches PUBLIC on when creating it. A public room's host
## publishes a signed ROOM CARD every CARD_EVERY_S (and at once when its players change) as a
## retained message on its own topic Cloud.ROOT + "/rm/<host id>" (Cloud.publish_room_card), and
## clears it (an empty retained message) when the room closes, starts or the lobby is left. Every
## phone that has the CUSTOM ROOM / FRIENDS pages open listens to "/rm/+" (with the player cards,
## Cloud.start_directory) and keeps the cards here (`take`).
## The card: {"t": "room", "v": 1, "id": host id, "pk": host's public key (PEM), "host": host
## name, "name": room name, "size": 1 | 2 | 4 (SOLO / DUO / SQUAD), "filled", "total" (2 x size),
## "rules": a short summary, "pw": a password is needed, "code": the 6-digit room ID, "ts": unix
## time, "sig": the host's RSA signature over card_text}. Checked like a player card: every field's
## type and length, the id is the key's hash and the topic's, the signature, at most MAX_AGE_S old
## (a host gone without clearing its card drops out by itself), one card per host (the topic), at
## most MAX_CARDS kept (the oldest goes), never a blocked host's and never this phone's own.
## What it shows anyone online: the room's name, its host's name and its code (the Privacy Notice
## says so); the password never leaves the host's phone (only whether there is one).

const MAX_CARDS := 200
const MAX_AGE_S := 120
const CARD_EVERY_S := 30.0
const FIELD_MAX := 48              # host name, rules summary (the room name: RoomRules.NAME_MAX)
const PK_MAX := 1024

## id -> {"id", "host", "name", "size", "filled", "total", "rules", "pw", "code", "ts"}
var cards := {}
## The room this phone publishes (its code), "" when none.
var hosting := ""
var _every := 0.0
var _sent_sig := ""

## The one list every page reads, kept on the Game autoload (meta "net_rooms"; a static of this
## script holding its own instance would never be freed at exit).
static func hub() -> NetRooms:
	if not Game.has_meta("net_rooms"):
		Game.set_meta("net_rooms", NetRooms.new())
	return Game.get_meta("net_rooms") as NetRooms


## The signed text of a card.
static func card_text(d: Dictionary) -> String:
	return "room|%s|%s|%s|%d|%d|%d|%s|%s|%s|%d" % [String(d.id), String(d.name), String(d.host), int(d.size),
		int(d.filled), int(d.total), String(d.rules), "1" if typeof(d.pw) == TYPE_BOOL and d.pw else "0", String(d.code), int(d.ts)]


## A card as published: `fields` (host, name, size, filled, total, rules, pw, code) signed with `key`
## (the private key of `pk`; tests make cards with their own keys).
static func card_json(fields: Dictionary, id: String, pk: String, ts: int, key: CryptoKey) -> String:
	var d := {"t": "room", "v": 1, "id": id, "pk": pk, "host": String(fields.get("host", "")), "name": String(fields.get("name", "")),
		"size": int(fields.get("size", 1)), "filled": int(fields.get("filled", 0)), "total": int(fields.get("total", 2)),
		"rules": String(fields.get("rules", "")), "pw": fields.get("pw", false), "code": String(fields.get("code", "")), "ts": ts}
	d.sig = Marshalls.raw_to_base64(Crypto.new().sign(HashingContext.HASH_SHA256, card_text(d).sha256_buffer(), key))
	return JSON.stringify(d)


static func _whole(v: Variant, lo: int, hi: int) -> bool:
	return (v is int or v is float) and float(v) == floorf(float(v)) and float(v) >= lo and float(v) <= hi


## A card off the broker (anyone can publish one) from topic owner `topic_id`: the cleaned entry, or
## {} when anything is wrong (see the header). `me`: this phone's id (its own card is not listed).
static func check(payload: PackedByteArray, topic_id: String, now: int, me := "") -> Dictionary:
	if payload.is_empty() or payload.size() > Cloud.MAX_MESSAGE:
		return {}
	var d: Variant = JSON.parse_string(payload.get_string_from_utf8())
	if not d is Dictionary or String((d as Dictionary).get("t", "")) != "room" or not _whole(d.get("v"), 1, 1):
		return {}
	for k in ["id", "pk", "host", "name", "rules", "code", "sig"]:
		if typeof(d.get(k)) != TYPE_STRING:
			return {}
		if k != "pk" and k != "sig" and "|" in String(d.get(k)):
			return {}                # (a "|" would blur where the signed fields part)
	if typeof(d.get("pw")) != TYPE_BOOL or not _whole(d.get("ts"), 0, 4102444800):
		return {}
	if not _whole(d.get("size"), 1, 4) or not int(d.size) in [1, 2, 4] or not _whole(d.get("total"), 2, 8) \
			or int(d.total) != 2 * int(d.size) or not _whole(d.get("filled"), 1, int(d.total)):
		return {}
	var code := String(d.code)
	if code.length() != 6 or not code.is_valid_int() or String(d.pk).length() > PK_MAX or String(d.host).length() > FIELD_MAX \
			or String(d.rules).length() > FIELD_MAX or String(d.name).length() > RoomRules.NAME_MAX:
		return {}
	var id := String(d.id)
	var ts := int(d.ts)
	if id != topic_id or id == me or id != String(d.pk).sha256_text().left(32) or ts > now + 60 or now - ts > MAX_AGE_S:
		return {}
	if Game.is_blocked(id) or not Cloud.verify_signed(String(d.pk), card_text(d), String(d.sig)):
		return {}
	var who := Game.clean_name(String(d.host))
	if who == "":
		who = "PLAYER"
	var room := Game.clean_name(String(d.name)).left(RoomRules.NAME_MAX)
	return {"id": id, "host": who, "name": room if room != "" else "%s'S ROOM" % who,
		"size": int(d.size), "filled": int(d.filled), "total": int(d.total), "rules": Game.clean_text(String(d.rules), FIELD_MAX),
		"pw": bool(d.pw), "code": code, "ts": ts}


## A message on "/rm/<topic_id>": an empty one takes that host's card away, a good card replaces
## an older one of the same host. True when the list changed.
func take(topic_id: String, payload: PackedByteArray, now: int, me := "") -> bool:
	if payload.is_empty():
		return cards.erase(topic_id)
	var e := check(payload, topic_id, now, me)
	if e.is_empty() or (cards.has(topic_id) and int(cards[topic_id].ts) >= int(e.ts)):
		return false
	cards[topic_id] = e
	while cards.size() > MAX_CARDS:
		var oldest := ""
		for k: String in cards:
			if oldest == "" or int(cards[k].ts) < int(cards[oldest].ts):
				oldest = k
		cards.erase(oldest)
	return true


## The rooms to show: fresh, no blocked host, newest first.
func list(now: int) -> Array:
	var out: Array = []
	for k: String in cards.keys():
		var e: Dictionary = cards[k]
		if now - int(e.ts) > MAX_AGE_S:
			cards.erase(k)
		elif not Game.is_blocked(k):
			out.append(e)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return int(a.ts) > int(b.ts))
	return out


## QUICK JOIN's room: the newest one with a free place and no password ({} when none).
func quick_pick(now: int) -> Dictionary:
	for e: Dictionary in list(now):
		if int(e.filled) < int(e.total) and not bool(e.pw):
			return e
	return {}


## The listed card of a room ID ({} when none).
func by_code(code: String, now: int) -> Dictionary:
	for e: Dictionary in list(now):
		if String(e.code) == code:
			return e
	return {}


## What this phone's public room card says now ({} when it hosts no public room).
static func my_fields(cloud: Cloud) -> Dictionary:
	if cloud == null or cloud.room_code == "" or not cloud.in_room() or String(cloud.group.get("leader", "")) != cloud.my_id:
		return {}
	var size := int(cloud.group.get("size", 1))
	var rules := RoomRules.sanitize(cloud.room_rules)
	return {"host": String(Game.profile.name), "name": String(rules.name), "size": size,
		"filled": clampi((cloud.group.get("members", []) as Array).size(), 1, 2 * size), "total": 2 * size,
		"rules": summary(rules, size > 1), "pw": cloud.room_pin != "", "code": cloud.room_code}


## The rules in a few words for a list row (the first two of RoomRules.summary).
static func summary(rules: Dictionary, team: bool) -> String:
	var parts: Array = RoomRules.summary(RoomRules.sanitize(rules), team)
	return " - ".join(parts.slice(0, 2)).left(FIELD_MAX)       # (what Game.clean_text keeps)


## Starts publishing the room this phone just opened as PUBLIC.
func host(code: String) -> void:
	hosting = code
	_every = 0.0
	_sent_sig = ""


## Stops publishing and clears the card from the relay.
func stop(cloud: Cloud) -> void:
	if hosting == "":
		return
	hosting = ""
	if cloud:
		cloud.publish_room_card({})


## Every frame from the lobby: the card again every CARD_EVERY_S or when what it says changed;
## cleared once the room is closed, changed or gone.
func process(delta: float, cloud: Cloud) -> void:
	if hosting == "" or cloud == null:
		return
	var f := my_fields(cloud)
	if f.is_empty() or String(f.code) != hosting:
		stop(cloud)
		return
	_every -= delta
	var sig := str(f)
	if _every > 0.0 and sig == _sent_sig:
		return
	if cloud.publish_room_card(f):
		_every = CARD_EVERY_S
		_sent_sig = sig
	else:
		_every = 2.0                 # offline: again soon
