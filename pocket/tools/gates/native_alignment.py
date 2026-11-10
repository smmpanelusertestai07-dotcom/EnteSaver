#!/usr/bin/env python3
"""Every bundled native library, against what a 16 KB-page Android device does to it.

Two things must hold, and only the first is widely known:

  1. Every LOAD segment has p_align >= 16384, or a 16 KB device cannot map the library.
  2. Where GNU_RELRO does not end on a 16 KB boundary, bionic still rounds its mprotect out to
     whole pages (linker_phdr.cpp: page_start(relro) .. page_end(relro + memsz)). That is only
     harmless when the rounded range holds no writable memory RELRO itself does not cover;
     otherwise the first write there is a segmentation fault on a 16 KB phone.

The ELF program headers are read here directly (no readelf), from the source tree's jniLibs
or from inside a built APK, so the check sees exactly the bytes that ship.

Usage: native_alignment.py [--apk PATH | --lib-dir DIR]
"""
from __future__ import annotations

import argparse
import struct
import sys
import zipfile
from dataclasses import dataclass
from pathlib import Path

import common

PAGE = 0x4000
PT_LOAD = 1
PT_GNU_RELRO = 0x6474E552
PF_W = 2
EM_AARCH64 = 183


@dataclass(frozen=True)
class Segment:
    vaddr: int
    memsz: int
    writable: bool
    align: int


class ElfError(ValueError):
    pass


def program_headers(data: bytes) -> tuple[list[Segment], tuple[int, int] | None]:
    """(LOAD segments, (relro vaddr, relro memsz) or None) of a 64-bit little-endian ELF."""
    if data[:4] != b"\x7fELF":
        raise ElfError("not an ELF file")
    if data[4] != 2 or data[5] != 1:
        raise ElfError("not a 64-bit little-endian ELF; only arm64-v8a libraries belong here")
    machine = struct.unpack_from("<H", data, 0x12)[0]
    if machine != EM_AARCH64:
        raise ElfError(f"built for machine {machine}, not arm64 ({EM_AARCH64})")
    phoff = struct.unpack_from("<Q", data, 0x20)[0]
    phentsize, phnum = struct.unpack_from("<HH", data, 0x36)
    if phentsize < 56 or phoff + phnum * phentsize > len(data):
        raise ElfError("program header table is truncated")
    loads, relro = [], None
    for index in range(phnum):
        p_type, p_flags, _off, vaddr, _paddr, _filesz, memsz, align = struct.unpack_from(
            "<IIQQQQQQ", data, phoff + index * phentsize)
        if p_type == PT_LOAD:
            loads.append(Segment(vaddr, memsz, bool(p_flags & PF_W), align))
        elif p_type == PT_GNU_RELRO:
            relro = (vaddr, memsz)
    return loads, relro


def _page_start(address: int) -> int:
    return address & ~(PAGE - 1)


def _page_end(address: int) -> int:
    return (address + PAGE - 1) & ~(PAGE - 1)


def judge(name: str, loads: list[Segment], relro: tuple[int, int] | None) -> tuple[str | None, str | None]:
    """(problem, note); at most one is set."""
    if not loads:
        return f"{name} has no LOAD segments", None
    for segment in loads:
        if segment.align < PAGE:
            return (f"{name} has a LOAD segment aligned to 0x{segment.align:x}; a 16 KB device cannot "
                    f"map it. Link with -Wl,-z,max-page-size=16384"), None
    if relro is None:
        return None, None
    start, size = relro
    end = start + size
    if end % PAGE == 0:
        return None, None
    low, high = _page_start(start), _page_end(end)
    caught = [
        f"0x{s.vaddr:x}..0x{s.vaddr + s.memsz:x}"
        for s in loads
        if s.writable
        and _page_end(s.vaddr + s.memsz) > low and _page_start(s.vaddr) < high
        and not (start <= s.vaddr and s.vaddr + s.memsz <= end)
    ]
    if caught:
        return (f"{name}: GNU_RELRO ends at 0x{end:x}; a 16 KB device makes 0x{low:x}..0x{high:x} read-only, "
                f"which catches writable memory RELRO does not cover ({', '.join(caught)}). That is a crash "
                f"on a 16 KB phone. Rebuild with -Wl,-z,max-page-size=16384"), None
    return None, (f"{name}: GNU_RELRO ends 0x{PAGE - end % PAGE:x} short of a 16 KB boundary; harmless in "
                  f"this layout (the rounding covers only RELRO and padding)")


def libraries_in_apk(apk: Path) -> dict[str, bytes]:
    with zipfile.ZipFile(apk) as archive:
        return {n: archive.read(n) for n in archive.namelist() if n.startswith("lib/") and n.endswith(".so")}


def check_libraries(libraries: dict[str, bytes], where: str) -> common.Report:
    """PocketIDE 4 ships no native code of its own; libraries that AndroidX brings are checked here."""
    report = common.Report()
    if not libraries:
        report.note(f"no native libraries in {where}")
        return report
    for name, data in sorted(libraries.items()):
        if Path(name).parent.name != "arm64-v8a":
            # 16 KB pages come on 64-bit ARM phones; other ABIs serve emulators and old phones.
            report.note(f"{name}: not arm64-v8a, not checked")
            continue
        try:
            problem, note = judge(name, *program_headers(data))
        except (ElfError, struct.error) as error:
            report.fail(f"{name}: {error}")
            continue
        if problem:
            report.fail(problem)
        if note:
            report.note(note)
    return report


def libraries_in_dir(directory: Path) -> dict[str, bytes]:
    return {str(p.relative_to(directory)): p.read_bytes() for p in common.files_under(directory, [".so"])}


def check(root: Path = common.POCKET, apk: Path | None = None, lib_dir: Path | None = None) -> common.Report:
    if apk is not None:
        return check_libraries(libraries_in_apk(apk), apk.name)
    if lib_dir is not None:
        return check_libraries(libraries_in_dir(lib_dir), str(lib_dir))
    return check_libraries(libraries_in_dir(common.main_src(root) / "jniLibs"), "app/src/main/jniLibs")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--apk", type=Path, help="check the libraries inside this APK instead of jniLibs")
    parser.add_argument("--lib-dir", type=Path, help="check a jniLibs-shaped directory (<abi>/lib*.so)")
    args = parser.parse_args()
    sys.exit(common.run_standalone("16 KB native alignment", lambda: check(apk=args.apk, lib_dir=args.lib_dir)))
