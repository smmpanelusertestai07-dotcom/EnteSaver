"""Rebuild the whole character asset: python3 /root/work/tools/character/build_all.py
Order: MPFB human+clothes -> mesh/texture processing -> animations -> GLB export -> validation ->
manifest -> previews. Intermediates go to work/, outputs to /root/work/assets/character/."""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
for step in ["build_stage_a.py", "build_stage_b.py", "animate.py", "export_glb.py", "validate_glb.py",
             "finalize_manifest.py", "render_previews.py"]:
    print("==>", step, flush=True)
    subprocess.run([sys.executable, os.path.join(HERE, step)], check=True)
