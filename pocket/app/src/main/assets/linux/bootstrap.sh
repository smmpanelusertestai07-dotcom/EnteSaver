#!/bin/bash
# Turns Ubuntu's base image into PocketIDE's connection to Cloud Shell: Ubuntu's own package
# sources and the few tools Google's gcloud needs (Python and OpenSSH), with settings that suit
# PRoot on a phone. The agents do not run here: they run in Cloud Shell.
#
# Runs as PRoot's faked root, with no init system, no services and no terminal. Safe to run
# again: every step checks before it acts, and the app runs it again when an app update
# changes it.
#
# Lines starting with "pocketide-progress" move the app's progress bar, "pocketide-step" lines
# name the step it shows, apt's own status lines (APT::Status-Fd) say which package is being
# fetched or set up, and "pocketide-installed <count>" says how many missing tools were
# installed (for Repair).
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive
export LC_ALL=C.UTF-8

# What Google's gcloud needs to reach Cloud Shell: Python for gcloud itself, OpenSSH for its
# connection, netcat for ssh to reach gcloud's tunnel through a private socket file, and the
# certificates of the web.
readonly PACKAGES=(
  ca-certificates python3 openssh-client netcat-openbsd curl procps tzdata
)
readonly CODENAME=resolute
readonly SOURCES=/etc/apt/sources.list.d/ubuntu.sources
readonly STAMP=/opt/pocketide/bootstrap.stamp
readonly VERSION=2

say() { printf '%s\n' "$*"; }

# A step the app shows as the set-up's current activity.
step() { printf 'pocketide-step %s\n' "$*"; }

progress() { printf 'pocketide-progress %s\n' "$1"; }

make_folders() {
  mkdir -p /opt/pocketide/bin /tmp /var/tmp
  chmod 1777 /tmp /var/tmp
}

# Nothing supervises services here, so no package may try to start one.
block_services() {
  printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
  chmod 755 /usr/sbin/policy-rc.d
}

configure_apt() {
  cat > /etc/apt/apt.conf.d/90pocketide <<'EOF'
// PocketIDE: a phone changes networks often, one dpkg at a time waits for the other,
// and nothing here reads translated package descriptions.
Acquire::Retries "3";
Acquire::Languages "none";
DPkg::Lock::Timeout "120";
EOF
  # Rebuilding the manual index takes minutes of silence under PRoot, and a set-up closed in
  # that silence leaves dpkg half configured. Nothing here reads man pages.
  echo 'man-db man-db/auto-update boolean false' | debconf-set-selections
}

# Ubuntu's own archive, checked by apt against the signed index with ubuntu-keyring. Plain HTTP
# until ca-certificates is installed, HTTPS from then on.
write_sources() {
  cat > "$SOURCES.new" <<EOF
Types: deb
URIs: $1://archive.ubuntu.com/ubuntu/
Suites: $CODENAME $CODENAME-updates $CODENAME-backports
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: $1://security.ubuntu.com/ubuntu/
Suites: $CODENAME-security
Components: main restricted universe multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
EOF
  mv "$SOURCES.new" "$SOURCES"
}

# A run killed part way (a flat battery, Android reclaiming the app) leaves dpkg mid-configure,
# and every later apt run refuses to start until that is finished.
repair_packages() {
  dpkg --configure -a || true
  apt-get -y -f install || true
}

# A phone drops its connection often enough that one failed fetch must not end a set-up.
# apt reports its progress on the output the app reads (APT::Status-Fd). Ubuntu 26.04's apt then
# needs a terminal for dpkg (Dpkg::Use-Pty): without one, a package script's first line of
# output fails with an I/O error, and so does the package.
apt_try() {
  local attempt
  for attempt in 1 2 3; do
    if apt-get -o APT::Status-Fd=1 -o Dpkg::Use-Pty=true "$@"; then
      return 0
    fi
    if [ "$attempt" -lt 3 ]; then
      say "That did not go through. Trying again ($((attempt + 1)) of 3)…"
      sleep $((attempt * 5))
      repair_packages
    fi
  done
  return 1
}

missing_packages() {
  local package
  for package in "${PACKAGES[@]}"; do
    if ! dpkg-query -W -f='${Status}\n' "$package" 2>/dev/null | grep -qx 'install ok installed'; then
      printf '%s\n' "$package"
    fi
  done
}

install_packages() {
  local missing
  mapfile -t missing < <(missing_packages)
  if [ "${#missing[@]}" -eq 0 ]; then
    say "The tools are already installed."
    printf 'pocketide-installed 0\n'
    return 0
  fi
  if dpkg-query -W -f='${Status}\n' ca-certificates 2>/dev/null | grep -qx 'install ok installed'; then
    write_sources https
  else
    write_sources http
  fi
  step "Updating the package list…"
  if ! apt_try update --error-on=any; then
    say "Could not reach Ubuntu's servers."
    return 1
  fi
  progress 30
  step "Installing Python and OpenSSH…"
  if ! apt_try install -y --no-install-recommends "${missing[@]}"; then
    say "Could not install the tools."
    return 1
  fi
  printf 'pocketide-installed %s\n' "${#missing[@]}"
}

# The lists are tens of megabytes and stale within a day; every apt user here updates first.
tidy() {
  apt-get clean
  rm -rf /var/lib/apt/lists/*
}

step "Preparing Ubuntu…"
progress 0
make_folders
block_services
configure_apt
repair_packages
progress 10
install_packages
progress 85
write_sources https
progress 90
tidy
printf 'version=%s\n' "$VERSION" > "$STAMP"
progress 100
say "Ubuntu is ready for gcloud."
