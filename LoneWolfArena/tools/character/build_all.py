"""Rebuild the whole character asset: python3 tools/character/build_all.py
Order: MPFB human+clothes -> mesh/texture processing -> animations -> GLB export -> validation ->
manifest -> previews. Intermediates go to tools/character/work/, outputs to assets/character/.
Needs the MakeHuman/MPFB CC0 packs and extension under MH_ROOT (default ~/mh, see mpfb_boot.py)."""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
for step in ["build_stage_a.py", "build_stage_b.py", "animate.py", "export_glb.py", "validate_glb.py",
             "finalize_manifest.py", "render_previews.py"]:
    print("==>", step, flush=True)
    subprocess.run([sys.executable, os.path.join(HERE, step)], check=True)
