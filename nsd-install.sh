#!/usr/bin/env bash

# Build and install NSD from source on Ubuntu.
# This follows the official Ubuntu build steps using NSD 4.14.2 by default.
# Run it as root, or as a sudo-capable user.

set -Eeuo pipefail

NSD_VERSION="${NSD_VERSION:-4.14.2}"
NSD_TARBALL="nsd-${NSD_VERSION}.tar.gz"
NSD_DIR="nsd-${NSD_VERSION}"
NSD_URL="https://nlnetlabs.nl/downloads/nsd/${NSD_TARBALL}"
BUILD_JOBS="${BUILD_JOBS:-4}"
WORK_DIR="${WORK_DIR:-${PWD}}"

if [[ -t 1 ]] && command -v tput >/dev/null 2>&1; then
  BOLD="$(tput bold)"
  RESET="$(tput sgr0)"
  BLUE="$(tput setaf 4)"
  GREEN="$(tput setaf 2)"
  YELLOW="$(tput setaf 3)"
  RED="$(tput setaf 1)"
else
  BOLD=""
  RESET=""
  BLUE=""
  GREEN=""
  YELLOW=""
  RED=""
fi

print_blank_line() {
  printf '\n'
}

print_header() {
  print_blank_line
  printf '%s%s==> %s%s\n' "${BOLD}" "${BLUE}" "$1" "${RESET}"
}

print_step() {
  printf '%s•%s %s\n' "${BOLD}" "${RESET}" "$1"
}

print_success() {
  printf '%s%sOK:%s %s\n' "${BOLD}" "${GREEN}" "${RESET}" "$1"
}

print_warning() {
  printf '%s%sWARN:%s %s\n' "${BOLD}" "${YELLOW}" "${RESET}" "$1"
}

print_error() {
  printf '%s%sERROR:%s %s\n' "${BOLD}" "${RED}" "${RESET}" "$1" >&2
}

require_root_or_sudo() {
  if [[ "${EUID}" -ne 0 ]] && ! command -v sudo >/dev/null 2>&1; then
    print_error "Run this script as root or from a user with sudo available."
    exit 1
  fi
}

# Use sudo only when needed so the same script works for root and non-root users.
run_as_root() {
  if [[ "${EUID}" -eq 0 ]]; then
    "$@"
  else
    sudo "$@"
  fi
}

# Disable Ubuntu's local resolver and install a static upstream resolver.
configure_system_dns() {
  local hostname_value
  local hosts_entry
  local resolver_tmp

  print_header "Configuring system DNS"

  if command -v systemctl >/dev/null 2>&1 && systemctl cat systemd-resolved.service >/dev/null 2>&1; then
    print_step "Stopping systemd-resolved"
    run_as_root systemctl stop systemd-resolved
    print_step "Disabling systemd-resolved"
    run_as_root systemctl disable systemd-resolved
    print_success "systemd-resolved stopped and disabled."
  else
    print_warning "systemd-resolved service not found, skipping."
  fi

  print_step "Replacing /etc/resolv.conf"
  resolver_tmp="$(mktemp)"
  printf 'nameserver 8.8.8.8\n' > "${resolver_tmp}"
  run_as_root rm -f /etc/resolv.conf
  run_as_root install -m 644 "${resolver_tmp}" /etc/resolv.conf
  rm -f "${resolver_tmp}"
  print_success "/etc/resolv.conf now uses nameserver 8.8.8.8."

  hostname_value="$(hostname)"
  hosts_entry="127.0.1.1 ${hostname_value}"

  if grep -Fxq "${hosts_entry}" /etc/hosts; then
    print_warning "/etc/hosts already contains '${hosts_entry}'."
  else
    print_step "Adding '${hosts_entry}' to /etc/hosts"
    printf '%s\n' "${hosts_entry}" | run_as_root tee -a /etc/hosts >/dev/null
    print_success "Added hostname entry to /etc/hosts."
  fi
}

require_command() {
  local command_name="$1"

  if ! command -v "${command_name}" >/dev/null 2>&1; then
    print_error "Required command not found: ${command_name}"
    exit 1
  fi
}

# Install the compiler, build tools, and development libraries NSD needs.
install_dependencies() {
  print_header "Installing dependencies"
  run_as_root apt update
  run_as_root apt install -y \
    build-essential \
    bison \
    dnsutils \
    flex \
    libevent-dev \
    libssl-dev \
    wget \
    pkg-config
  print_success "Build dependencies installed."
}

# Download the requested NSD release and unpack it into the working directory.
download_source() {
  print_header "Preparing source"
  run_as_root mkdir -p "${WORK_DIR}"
  cd "${WORK_DIR}"

  if [[ ! -f "${NSD_TARBALL}" ]]; then
    print_step "Downloading ${NSD_TARBALL}"
    wget "${NSD_URL}"
  else
    print_warning "Using existing tarball: ${WORK_DIR}/${NSD_TARBALL}"
  fi

  if [[ ! -d "${NSD_DIR}" ]]; then
    print_step "Extracting ${NSD_TARBALL}"
    tar xzf "${NSD_TARBALL}"
  else
    print_warning "Using existing source directory: ${WORK_DIR}/${NSD_DIR}"
  fi

  print_success "Source tree ready in ${WORK_DIR}/${NSD_DIR}."
}

# Configure the source tree before compilation.
configure_build() {
  print_header "Configuring build"
  cd "${WORK_DIR}/${NSD_DIR}"
  ./configure --disable-dnstap
  print_success "Configuration completed."
}

# Compile and install NSD from the prepared source tree.
build_and_install() {
  print_header "Building and installing"
  cd "${WORK_DIR}/${NSD_DIR}"
  print_step "Compiling with ${BUILD_JOBS} parallel job(s)"
  make -j"${BUILD_JOBS}"
  print_step "Installing NSD"
  run_as_root make install
  print_success "NSD installed."
}

# Remove the downloaded tarball and extracted source tree after a successful install.
cleanup_build_files() {
  print_header "Cleaning up"
  run_as_root rm -rf "${WORK_DIR:?}/${NSD_DIR}"
  run_as_root rm -f "${WORK_DIR:?}/${NSD_TARBALL}"
  print_success "Removed build artifacts."
}

# Print the installed NSD version so we can verify the binary is available.
verify_installation() {
  print_header "Verifying installation"
  nsd -v
  print_success "NSD binary is available."
}

# Look up the server's public IP addresses using Cloudflare's DNS debug endpoint.
print_public_ips() {
  local public_ipv4=""
  local public_ipv6=""

  public_ipv4="$(dig -4 +short CH TXT whoami.cloudflare @1.1.1.1 2>/dev/null | tr -d '"')"
  public_ipv6="$(dig -6 +short CH TXT whoami.cloudflare @2606:4700:4700::1111 2>/dev/null | tr -d '"')"

  print_header "Detected public IPs"

  if [[ -n "${public_ipv4}" ]]; then
    print_success "Public IPv4: ${public_ipv4}"
  else
    print_warning "Public IPv4: not detected"
  fi

  if [[ -n "${public_ipv6}" ]]; then
    print_success "Public IPv6: ${public_ipv6}"
  else
    print_warning "Public IPv6: not detected"
  fi
}

main() {
  print_header "NSD installer"
  print_step "Version: ${NSD_VERSION}"
  print_step "Working directory: ${WORK_DIR}"

  require_root_or_sudo
  require_command apt
  require_command tar

  configure_system_dns
  install_dependencies
  require_command dig
  require_command wget
  require_command make
  download_source
  configure_build
  build_and_install
  cleanup_build_files
  verify_installation
  print_public_ips

  print_header "Finished"
  print_success "NSD ${NSD_VERSION} installation complete."
  print_blank_line
}

main "$@"
