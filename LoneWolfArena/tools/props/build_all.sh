#!/bin/bash
# Rebuild every prop GLB the game ships (assets/props/; build_container_open.py also writes
# container_open_colliders.json there), render previews (Cycles CPU) and their contact sheet into
# tools/props/previews/, and write the props report tools/props/manifest.json.
set -e
cd "$(dirname "$0")"
for f in build_*.py; do   # one script per shipped GLB
  blender -b --python "$f" 2>&1 | grep -E "tris=|Error" || true
done
blender -b --python preview.py -- weapon_ar weapon_smg weapon_sg weapon_pistol weapon_sniper medkit grenade \
  shield_wall container container_40 container_open crate wall_bay wall_column rollup_door roof_truss \
  lamp_tube barrel pallet bollard fire_cabinet | grep -E "^== "
python3 contact_sheet.py
python3 -I manifest.py
