# Lone Wolf Arena: style and feel spec

Measurable targets for the game, distilled from private reference research (facts in our own
words; the reference screenshots themselves are never stored in the repo). Everything here is
implemented with ORIGINAL assets and names. Positions are fractions of screen width/height
(x, y of the centre) on a landscape phone; sizes are fractions of screen height.
QA agents (`.claude/agents/visual-qa.md`, `gameplay-tester.md`) check against this file.

## 1. Mode and round flow (reference: 1v1 "Lone Wolf" duels)
| Item | Target |
|---|---|
| Format | 1 vs 1 bot, ONE round per START (owner's choice; the reference mode is first-to-5) |
| Flow | Lobby START -> loading -> PREP 10 s (spawn alcove behind a glowing red floor barrier, red countdown, weapon pick panel) -> "ROUND 1 / AREA: CARGO CAGE" banner -> FIGHT 90 s -> result |
| Weapon pick | Grid of weapons, the chosen gun is used by BOTH players; 10 s; default pick if the timer ends |
| Loadout | Chosen gun + fists, 2 medkits, 2 shield walls, 1 frag grenade, Lv2 helmet + Lv2 vest |
| HP | 200, resets each round; no knock-down in 1v1 (0 HP = eliminated) |
| Zone | Holds 25 s, then shrinks over 40 s to r = 4 m; damage 5 HP/s (first 10 s outside), then 10, then 20 |
| Time-out | Higher HP wins; equal HP -> draw |
| Score HUD | Top centre: [your bar][blue box: your rounds][timer + "OBJECTIVE 1"][orange box: enemy rounds][enemy bar]; timer red in the last 10 s and during prep |

## 2. Map "Cargo Cage" (original, warehouse duel arena)
- Enclosed industrial hall, 42 x 30 m inside, 9 m walls, 180-degree rotational symmetry, spawn
  alcoves at both short ends (red barrier during prep).
- Corrugated steel walls: ochre-orange lower band (0-2.6 m), light grey above; a row of high
  windows (bright daylight); rust-brown roof trusses with hanging fluorescent tubes.
- Grey polished concrete floor with 4 m slab joints, yellow-black hazard stripes, yellow hatched
  floor pads, dashed lane lines.
- Shipping containers in light blue, deep blue, rust red, orange and cream (20 ft and 40 ft, some
  stacked 2-high, an open walk-through container), steel ramps up to a central container block
  (high ground), X-braced wooden crates as steps/cover, barrels, pallets, a forklift, a tank,
  bollards, roll-up doors, fire cabinets, area signs (A / B).
- Lighting: neutral bright daylight + fluorescent ambience, soft shadows, vivid colours.
- Performance budget (phone): <= 220 draw calls and <= 250k primitives per frame in the arena.

## 3. In-match HUD (default layout, 16:9 .. 20:9)
| Element | Position (x, y) | Size | Style |
|---|---|---|---|
| Minimap (square) | top-left, 0.075, 0.17 | 0.24 h | dark translucent square, white walls, player arrow, enemy red dot when revealed |
| Score bar | 0.50, 0.06 | 0.09 h tall | see section 1 |
| Kill feed | bottom centre 0.50, 0.80 | text 0.035 h | "<killer> [weapon icon] <victim>", "HEADSHOT" in orange |
| Weapon panel | top-right 0.86, 0.10 | 0.16 x 0.09 | weapon silhouette (white), ammo "mag / reserve", fire-mode text |
| HP bar | bottom centre 0.50, 0.875 | 0.20 w | white frame, green fill, number "HP 200/200", helmet + vest level icons on the right |
| Joystick | 0.15, 0.72 | 0.30 | translucent ring + knob, floating within the left 40 % |
| Fire (right) | 0.85, 0.66 | 0.20 | big circle, bullet+crosshair glyph, red-orange ring |
| Fire (left) | 0.09, 0.42 | 0.13 | same glyph, smaller |
| Scope / ADS | 0.94, 0.47 | 0.11 | reticle glyph |
| Jump | 0.94, 0.80 | 0.11 | standing-figure glyph with up chevron |
| Crouch | 0.82, 0.89 | 0.10 | crouching-figure silhouette |
| Prone | 0.71, 0.92 | 0.09 | lying-figure silhouette |
| Reload | 0.62, 0.92 | 0.08 | circular arrow |
| Medkit | 0.27, 0.87 | 0.09 | kit glyph + count badge |
| Shield wall | 0.82, 0.37 | 0.10 | wall glyph + count badge |
| Grenade | 0.65, 0.87 -> right column | 0.09 | grenade silhouette + count |
| Settings / pause | top-right corner | 0.08 | gear |
| Scoreboard | next to settings | 0.08 | list glyph |
- Buttons: dark translucent circles (~35-45 % black), white glyphs, opacity per button editable.
- Crosshair: WHITE by default (4 short lines + centre dot, spreads with movement/firing), turns
  RED when the crosshair is on an enemy; red-dot reticle when aiming (ADS).
- Damage numbers: yellow, bold, outlined, float up; headshots orange-red and larger.
- Hit marker: white X; headshot: orange X + head icon; kill: red skull pop + kill banner.
- Damage direction: red arc segments around the centre; low HP: red vignette pulse.
- Prep: big red countdown digits; round banner: horizontal band blue (left) fading to orange (right).

## 4. Game feel (numbers)
| Item | Target |
|---|---|
| Run / sprint / walk | 5.0 / 6.0 / 2.0 m/s (sprint = joystick pushed past the ring for 0.3 s) |
| Crouch / prone | 1.75 / 0.75 m/s; stance change 0.2 s / 0.45 s |
| ADS / firing speed | x0.70 / x0.85 (SMG x0.95) |
| Jump | apex ~1.3 m (can climb 1.2 m crates), gravity 22 m/s2 |
| Fall damage | none up to 4 m, then 12 HP per extra metre |
| Head multiplier | pistols/snipers 5.5, ARs 4.0, SMGs 3.5, shotgun pellets 3.0 (decays to 80 % at range for SMG/SG) |
| Armour | helmet Lv2 45 %, vest Lv2 50 % |
| Medkit | +75 HP over 4 s (1 s wind-up then 25 HP/s), walk at 60 %, firing cancels |
| Shield wall | 600 HP, 3.5 x 2.0 m, lasts 45 s |
| Frag | 150 at centre -> 60 at 5 m, 3 s fuse |
| Aim assist | hip cone 5 deg within 25 m, scoped 2.5 deg to 80 m, slow-down 0.6 on target, tracking 30 % of target motion, pull while firing, head stop on upward drag; modes DEFAULT / PRECISE ON SCOPE / FULL CONTROL |
| Aim checks (`--autotest=aim`) | pull onto body < 0.6 s; head stop error -1.5..+0.8 deg; on-target % with assist > without; red crosshair only on the body |

## 5. Screens
- Loading: full-screen key art (our character), logo top-left, slim progress bar at the bottom
  with tips text.
- Lobby: character centred on a lit stage; top bar (avatar, name, level/XP, offline coins,
  settings); left column menu (BUNDLES, CUSTOM HUD, SETTINGS, HOW TO PLAY); right: mode card
  "LONE WOLF / CARGO CAGE" + big yellow START button bottom-right.
- Result: mode/map text top-left, big gold "VICTORY" / grey "DEFEAT", stats card (ELIMINATIONS,
  DAMAGE, HEADSHOTS, ACCURACY, TIME), honour tag, XP bar, PLAY AGAIN / LOBBY.
- Settings tabs: BASIC (graphics SMOOTH/STANDARD/ULTRA, frame rate, aim precision, show FPS,
  damage numbers, vibration), SENSITIVITY (general, red dot, 2x, 4x, sniper, fire-button drag),
  CONTROLS (custom HUD, left fire, crosshair colour/size), SOUND.
