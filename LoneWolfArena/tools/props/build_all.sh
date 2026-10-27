#!/bin/bash
# Rebuild every prop GLB, render previews (Cycles CPU), and regenerate manifest.json.
set -e
cd "$(dirname "$0")"
for f in build_ar.py build_sg.py build_pistol.py build_medkit.py build_grenade.py build_shield.py build_container.py \
         build_crate.py build_barrier.py build_sandbags.py build_trees.py build_rock.py build_mountains.py \
         build_watchtower.py build_lamp.py build_house.py; do
  python3 "$f" 2>&1 | grep -E "tris=|Error" || true
done
python3 preview.py --cycles weapon_ar weapon_sg weapon_pistol medkit grenade shield_wall container crate barrier sandbags \
  tree_pine tree_round rock mountains watchtower lamp_post house | grep -E "^== "
python3 contact_sheet.py
python3 -I manifest.py
