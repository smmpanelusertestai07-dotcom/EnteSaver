"""Bootstrap helper: install/enable the MPFB 2 extension inside the bpy module and
point its user data dir at a merged asset tree built from the extracted CC0 packs.

Usage (from another script in this directory):
    import mpfb_boot
    S = mpfb_boot.boot()          # returns a namespace with MPFB services
"""
import os
import sys
import shutil
import importlib
import types

import bpy

MH_ROOT = os.environ.get("MH_ROOT", os.path.expanduser("~/mh"))
MPFB_SRC = os.path.join(MH_ROOT, "ext", "mpfb")                # extracted extension zip
PACKS_DIR = os.path.join(MH_ROOT, "ext", "packs")              # each pack extracted into its own dir
EXT_DIR = os.path.expanduser("~/.config/blender/5.0/extensions/user_default/mpfb")
MERGED_DATA = os.path.join(MH_ROOT, "mpfb_user_data")          # merged (symlinked) asset tree
PKG = "bl_ext.user_default.mpfb"

ASSET_SUBDIRS = ["clothes", "skins", "eyebrows", "eyelashes", "eyes", "hair", "proxymeshes",
                 "teeth", "tongue", "packs", "ink_layers", "poses", "rigs", "expressions"]


def build_merged_data():
    """Create MERGED_DATA/<subdir>/<asset> symlinks for every extracted pack."""
    os.makedirs(MERGED_DATA, exist_ok=True)
    for pack in sorted(os.listdir(PACKS_DIR)):
        proot = os.path.join(PACKS_DIR, pack)
        if not os.path.isdir(proot):
            continue
        for sub in os.listdir(proot):
            spath = os.path.join(proot, sub)
            if not os.path.isdir(spath):
                continue
            dst_sub = os.path.join(MERGED_DATA, sub)
            os.makedirs(dst_sub, exist_ok=True)
            for item in os.listdir(spath):
                src = os.path.join(spath, item)
                dst = os.path.join(dst_sub, item)
                if os.path.lexists(dst):
                    continue
                os.symlink(src, dst)


def install_extension():
    if not os.path.isdir(EXT_DIR):
        os.makedirs(os.path.dirname(EXT_DIR), exist_ok=True)
        shutil.copytree(MPFB_SRC, EXT_DIR)


def boot(verbose=False):
    build_merged_data()
    install_extension()
    if PKG not in sys.modules:
        bpy.ops.preferences.addon_enable(module=PKG)
    m = importlib.import_module(PKG)
    services = importlib.import_module(PKG + ".services")
    LocationService = services.LocationService
    # Redirect MPFB user data to the merged tree
    LocationService._user_data = MERGED_DATA
    from importlib import import_module
    ns = types.SimpleNamespace()
    ns.mpfb = m
    for name in ["HumanService", "TargetService", "RigService", "ClothesService", "MaterialService",
                 "ObjectService", "AssetService", "LocationService", "NodeService", "ModifierService",
                 "MeshService", "AnimationService", "SystemService", "ExportService"]:
        if hasattr(services, name):
            setattr(ns, name, getattr(services, name))
    ns.AssetService.update_all_asset_lists()
    if verbose:
        print("MPFB", m.VERSION, "data roots:", ns.AssetService.get_available_data_roots())
    return ns
