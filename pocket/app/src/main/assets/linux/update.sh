#!/bin/bash
# Installs Ubuntu's updates, security fixes included. The app runs it once a day while the
# computer is on, and whenever the owner taps "Update now".
#
# Every update Ubuntu has published for this release is installed, new dependencies with it,
# but nothing is ever removed. The last line the app reads is "pocketide-fixed <count>", the
# number of packages updated.
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8

say() { printf '%s\n' "$*"; }

# A step the app shows as the current activity.
step() { printf 'pocketide-step %s\n' "$*"; }

# A run killed part way leaves dpkg mid-configure; finish that before anything else.
repair_packages() {
  dpkg --configure -a || true
  apt-get -y -f install || true
}

# apt reports its progress on the output the app reads; Ubuntu 26.04's apt then needs a terminal
# for dpkg, or a package script's first line of output fails (see bootstrap.sh).
apt_try() {
  local attempt
  for attempt in 1 2 3; do
    if apt-get -o APT::Status-Fd=1 -o Dpkg::Use-Pty=true "$@"; then
      return 0
    fi
    if [ "$attempt" -lt 3 ]; then
      sleep $((attempt * 5))
      repair_packages
    fi
  done
  return 1
}

step "Checking Ubuntu's updates…"
repair_packages
# Without --error-on=any a list that failed to download is only a warning, and a phone that
# reached nothing would report "no updates waiting".
if ! apt_try update --error-on=any; then
  say "Could not reach Ubuntu's servers."
  exit 1
fi

count=$(apt-get -s upgrade --with-new-pkgs | grep -c '^Inst ' || true)
if [ "$count" -eq 0 ]; then
  say "Ubuntu is up to date."
else
  step "Installing $count updates…"
  # A configuration file the owner changed is kept; the package's new one is set beside it.
  if ! apt_try upgrade -y --with-new-pkgs --no-install-recommends \
      -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold; then
    say "Some updates could not be installed."
    exit 1
  fi
fi

apt-get clean
rm -rf /var/lib/apt/lists/*
printf 'pocketide-fixed %s\n' "$count"
