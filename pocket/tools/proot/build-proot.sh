#!/bin/bash
# Builds PRoot for Android from pinned sources, with 16 KB page alignment.
#
# The app ships 2.6.0's PRoot for arm64: Termux's prebuilt, with its file names and prefix
# byte-patched, proven on the owner's phone. The arm64 build here is a check and an artifact for
# a later release; its output replaces jniLibs only after it has been tested on a phone. The
# x86-64 build is what the Android emulator in CI runs the app's computer with.
#
# It builds the release marked "build": true in sources.json the way Termux packages it
# (make -C src PROOT_WITH_LIBANDROID_SHMEM=true, ARG_MAX=131072), with the NDK's plain sysroot
# instead of Termux's patched one, and with these changes: talloc and libandroid-shmem are linked
# in statically, so the app would ship just two files and nothing needs renaming or patching; the
# patches the release lists (in patches/, each saying what it fixes) are applied to PRoot; and
# every download is checked against its pinned SHA-256 before it is unpacked.
#
# Output, in OUT_DIR:
#   jniLibs/<ABI>/libproot.so         the proot executable (Android extracts only lib*.so)
#   jniLibs/<ABI>/libproot-loader.so  the loader, which the app names in PROOT_LOADER
#   sources/                          the three source archives, exactly as verified, and the patches
#   PROVENANCE.txt                    versions, checksums, NDK and flags
#
# Usage: build-proot.sh OUT_DIR [ABI]     (ABI: arm64-v8a, the default, or x86_64)
# Needs: ANDROID_NDK_HOME (the NDK version named in sources.json), python3, curl, make, unzip,
#        readelf and gawk (PRoot's loader-info step runs both on the host).
set -euo pipefail
shopt -s inherit_errexit

readonly API=29
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly HERE
readonly SOURCES_JSON="$HERE/sources.json"
# libandroid-shmem keeps a symlink per shared-memory key in _PATH_TMP. Termux defines it in its
# own paths.h; the NDK's bionic does not. PRoot creates those links itself, on the Android side,
# so the path must be one the app owns: LinuxDirs.prootTmp of the release package, which the app
# creates before PRoot starts and also hands to PRoot as PROOT_TMP_DIR.
readonly SHMEM_TMP=/data/data/com.pocketide/files/computer/proot-tmp/
# ashmem_memfd.c calls strcmp and memset without including <string.h>. Termux's patched <stdio.h>
# includes it for every file; the NDK's does not. Only that file gets it, because the loader
# defines its own basename(), which <string.h> would clash with.
readonly MISSING_INCLUDES='extension/ashmem_memfd/ashmem_memfd.o: CPPFLAGS += -include string.h'

die() { printf 'build-proot: %s\n' "$*" >&2; exit 1; }

# Prints "<field> <value>" lines for the release to build, from sources.json.
release_field() {
  python3 - "$SOURCES_JSON" "$1" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
builds = [r for r in data["releases"] if r.get("build")]
if len(builds) != 1:
    sys.exit("sources.json must mark exactly one release with build: true")
value = data if sys.argv[2] == "ndk" else builds[0]
for key in sys.argv[2].split("."):
    value = value[key]
print(value)
PY
}

# The part's url, then its mirrors, one per line.
release_urls() {
  python3 - "$SOURCES_JSON" "$1" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
builds = [r for r in data["releases"] if r.get("build")]
if len(builds) != 1:
    sys.exit("sources.json must mark exactly one release with build: true")
part = builds[0][sys.argv[2]]
print("\n".join([part["url"], *part.get("mirrors", [])]))
PY
}

# The patches the release lists, one path (relative to this folder) per line; none prints nothing.
release_patches() {
  python3 - "$SOURCES_JSON" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
builds = [r for r in data["releases"] if r.get("build")]
if len(builds) != 1:
    sys.exit("sources.json must mark exactly one release with build: true")
for patch in builds[0].get("patches", []):
    print(patch)
PY
}

# Saves the first of the given URLs whose download matches the pinned SHA-256. A plain
# curl --retry skips "could not connect", which is how one CI run lost samba.org, so every
# error is retried, and a host that stays down falls through to the next mirror.
fetch_verified() {
  local sha256="$1" dest="$2" url
  shift 2
  if [ -f "$dest" ] && echo "$sha256  $dest" | sha256sum --check --status; then
    return 0
  fi
  for url in "$@"; do
    if curl --fail --location --silent --show-error --connect-timeout 30 \
        --retry 5 --retry-delay 5 --retry-all-errors --output "$dest.part" "$url" &&
      echo "$sha256  $dest.part" | sha256sum --check --status; then
      mv "$dest.part" "$dest"
      return 0
    fi
    printf 'build-proot: %s failed or did not match its pinned SHA-256; trying the next source\n' "$url" >&2
  done
  rm -f "$dest.part"
  die "${dest##*/}: no source gave a file matching its pinned SHA-256"
}

check_ndk() {
  local wanted have
  wanted=$(release_field ndk)
  [ -n "${ANDROID_NDK_HOME:-}" ] || die "set ANDROID_NDK_HOME to NDK $wanted"
  have=$(sed -n 's/^Pkg.Revision *= *//p' "$ANDROID_NDK_HOME/source.properties")
  [ "$have" = "$wanted" ] || die "NDK $have found; sources.json pins $wanted"
  NDK_VERSION="$have"
}

setup_toolchain() {
  local bin="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin"
  [ -x "$bin/$TARGET-clang" ] || die "no $TARGET-clang in the NDK (the NDK runs on x86-64 Linux hosts)"
  export CC="$bin/$TARGET-clang"
  export AR="$bin/llvm-ar"
  export STRIP="$bin/llvm-strip"
  export OBJCOPY="$bin/llvm-objcopy"
  export OBJDUMP="$bin/llvm-objdump"
  # PRoot's makefile runs "awk" on a script that calls strtonum, which only gawk has; Ubuntu's
  # default awk is mawk.
  command -v gawk > /dev/null || die "PRoot's build needs gawk"
  mkdir -p "$WORK/bin"
  ln -s "$(command -v gawk)" "$WORK/bin/awk"
  export PATH="$WORK/bin:$PATH"
}

build_shmem() {
  local archive="$1" dir
  tar -xzf "$archive" -C "$WORK"
  dir=$(find "$WORK" -maxdepth 1 -type d -name 'libandroid-shmem-*' | head -n 1)
  # The makefile appends its own flags (-Wall -Wextra among them) with +=, so ours go through
  # the environment. The backslashes survive into make's shell, as in build_proot.
  CFLAGS="-O2 -D_PATH_TMP=\\\"$SHMEM_TMP\\\"" make -C "$dir" CC="$CC" AR="$AR" libandroid-shmem.a
  install -D -m 644 "$dir/libandroid-shmem.a" "$WORK/lib/libandroid-shmem.a"
  install -D -m 644 "$dir/shm.h" "$WORK/include/sys/shm.h"
}

# talloc's own build (waf) with Termux's cross-compile answers, then a static archive of its
# objects and of the libreplace objects it relies on.
build_talloc() {
  local archive="$1" dir objects
  tar -xzf "$archive" -C "$WORK"
  dir=$(find "$WORK" -maxdepth 1 -type d -name 'talloc-*' | head -n 1)
  cat > "$dir/cross-answers.txt" <<'EOF'
Checking uname sysname type: "Linux"
Checking uname machine type: "dontcare"
Checking uname release type: "dontcare"
Checking uname version type: "dontcare"
Checking simple C program: OK
building library support: OK
Checking for large file support: OK
Checking for -D_FILE_OFFSET_BITS=64: OK
Checking for WORDS_BIGENDIAN: OK
Checking for C99 vsnprintf: OK
Checking for HAVE_SECURE_MKSTEMP: OK
rpath library support: OK
-Wl,--version-script support: FAIL
Checking correct behavior of strtoll: OK
Checking correct behavior of strptime: OK
Checking for HAVE_IFACE_GETIFADDRS: OK
Checking for HAVE_IFACE_IFCONF: OK
Checking for HAVE_IFACE_IFREQ: OK
Checking getconf LFS_CFLAGS: OK
Checking for large file support without additional flags: OK
Checking for working strptime: OK
Checking for HAVE_SHARED_MMAP: OK
Checking for HAVE_MREMAP: OK
Checking for HAVE_INCOHERENT_MMAP: OK
Checking getconf large file support flags work: OK
EOF
  (
    cd "$dir"
    ./configure --prefix="$WORK/talloc-prefix" --disable-rpath --disable-python \
      --cross-compile --cross-answers=cross-answers.txt
    make
  )
  mapfile -t objects < <(find "$dir/bin/default" -maxdepth 1 -name 'talloc*.o'; \
    find "$dir/bin/default/lib/replace" -maxdepth 1 -name '*.o' 2> /dev/null)
  [ "${#objects[@]}" -gt 0 ] || die "talloc's build left no object files"
  mkdir -p "$WORK/lib"
  "$AR" rcs "$WORK/lib/libtalloc.a" "${objects[@]}"
  install -D -m 644 "$dir/talloc.h" "$WORK/include/talloc.h"
}

build_proot() {
  local archive="$1" version="$2" dir patch
  unzip -q "$archive" -d "$WORK"
  dir=$(find "$WORK" -maxdepth 1 -type d -name 'proot-*' | head -n 1)
  while IFS= read -r patch; do
    patch -d "$dir" -p1 --forward --batch < "$HERE/$patch" || die "$patch does not apply to PRoot $version"
    cp "$HERE/$patch" "$OUT/sources/"
  done < <(release_patches)
  # PRoot's makefile appends to these (+=), so they go through the environment, not the
  # command line, which would replace its own flags.
  # The backslashes survive into make's shell, which turns \" into the quotes of a C string.
  export CPPFLAGS="-I$WORK/include -DARG_MAX=131072 -DVERSION=\\\"$version\\\""
  export CFLAGS="-O2"
  export LDFLAGS="-L$WORK/lib -Wl,-z,max-page-size=16384 -llog -landroid"
  make -C "$dir/src" PROOT_WITH_LIBANDROID_SHMEM=true V=1 --eval="$MISSING_INCLUDES" proot loader/loader
  mkdir -p "$OUT/jniLibs/$ABI"
  "$STRIP" -o "$OUT/jniLibs/$ABI/libproot.so" "$dir/src/proot"
  "$STRIP" -o "$OUT/jniLibs/$ABI/libproot-loader.so" "$dir/src/loader/loader"
}

check_output() {
  local lib="$OUT/jniLibs/$ABI/libproot.so" needed
  needed=$("$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/linux-x86_64/bin/llvm-readelf" -d "$lib" \
    | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | tr '\n' ' ')
  case "$needed" in
    *talloc* | *shmem*) die "libproot.so still needs a shared talloc or libandroid-shmem: $needed" ;;
  esac
  grep -aq "$VERSION" "$lib" || die "libproot.so does not carry its version string $VERSION"
  python3 "$HERE/../gates/native_alignment.py" --lib-dir "$OUT/jniLibs"
  printf 'libproot.so needs: %s\n' "$needed"
}

write_provenance() {
  {
    printf 'PRoot %s for %s Android (API %s), built by PocketIDE CI.\n\n' "$VERSION" "$ABI" "$API"
    printf 'NDK %s, clang target %s\n' "$NDK_VERSION" "$TARGET"
    printf 'libandroid-shmem: make libandroid-shmem.a with CFLAGS=-O2 -D_PATH_TMP="%s"\n' "$SHMEM_TMP"
    printf 'make -C src PROOT_WITH_LIBANDROID_SHMEM=true --eval=%s\n' "'$MISSING_INCLUDES'"
    printf 'Patches applied to PRoot first (patch -p1, copies in sources/): %s\n' "$(release_patches | tr '\n' ' ')"
    printf 'CPPFLAGS=%s\nCFLAGS=%s\nLDFLAGS=%s\n\n' "$CPPFLAGS" "$CFLAGS" "$LDFLAGS"
    printf 'Sources (verified by SHA-256 before use; copies in sources/):\n'
    (cd "$OUT/sources" && sha256sum -- *)
    printf '\nOutputs:\n'
    (cd "$OUT/jniLibs/$ABI" && sha256sum -- *.so)
  } > "$OUT/PROVENANCE.txt"
}

main() {
  if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
    die "usage: build-proot.sh OUT_DIR [arm64-v8a|x86_64]"
  fi
  OUT="$(mkdir -p "$1" && cd "$1" && pwd)"
  ABI="${2:-arm64-v8a}"
  case "$ABI" in
    arm64-v8a) TARGET="aarch64-linux-android$API" ;;
    x86_64) TARGET="x86_64-linux-android$API" ;;
    *) die "no build for $ABI: arm64-v8a or x86_64" ;;
  esac
  WORK="$(mktemp -d)"
  trap 'rm -rf "$WORK"' EXIT
  VERSION=$(release_field version)
  check_ndk
  setup_toolchain
  mkdir -p "$OUT/sources"
  local proot talloc shmem
  proot="$OUT/sources/proot-$VERSION.zip"
  talloc="$OUT/sources/talloc-$(release_field talloc.version).tar.gz"
  shmem="$OUT/sources/libandroid-shmem-$(release_field libandroid_shmem.version).tar.gz"
  local -a urls
  mapfile -t urls < <(release_urls proot)
  fetch_verified "$(release_field proot.sha256)" "$proot" "${urls[@]}"
  mapfile -t urls < <(release_urls talloc)
  fetch_verified "$(release_field talloc.sha256)" "$talloc" "${urls[@]}"
  mapfile -t urls < <(release_urls libandroid_shmem)
  fetch_verified "$(release_field libandroid_shmem.sha256)" "$shmem" "${urls[@]}"
  build_shmem "$shmem"
  build_talloc "$talloc"
  build_proot "$proot" "$VERSION"
  check_output
  write_provenance
  printf 'Built PRoot %s into %s\n' "$VERSION" "$OUT"
}

main "$@"
