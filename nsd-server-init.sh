#!/usr/bin/env bash

# Bootstrap a fresh Ubuntu 24.04 VM for nsd deployment.
# Run this as root over SSH on a new machine.
# It creates the deploy user, copies SSH access, applies the bundled SSH config,
# prompts for a deploy password and hostname, and then removes root SSH keys.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/config"
SSHD_CONFIG_SOURCE="${CONFIG_DIR}/sshd_config"
SSHD_CONFIG_TARGET="/etc/ssh/sshd_config"
SSHD_RUNTIME_DIR="/run/sshd"
DEPLOY_USER="deploy"
ROOT_SSH_DIR="/root/.ssh"
DEPLOY_HOME="/home/${DEPLOY_USER}"
DEPLOY_SSH_DIR="${DEPLOY_HOME}/.ssh"
DEPLOY_AUTHORIZED_KEYS="${DEPLOY_SSH_DIR}/authorized_keys"
HOSTNAME_VALUE=""
PUBLIC_KEY_VALUE=""

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

get_reconnect_host() {
  local public_ipv4=""

  if command -v dig >/dev/null 2>&1; then
    public_ipv4="$(dig -4 +short CH TXT whoami.cloudflare @1.1.1.1 2>/dev/null | tr -d '"')"
    if [[ -n "${public_ipv4}" ]]; then
      printf '%s\n' "${public_ipv4}"
      return
    fi
  fi

  if [[ -n "${SSH_CONNECTION:-}" ]]; then
    awk '{ print $3 }' <<<"${SSH_CONNECTION}"
    return
  fi

  hostname -I 2>/dev/null | awk '{ print $1 }'
}

update_system_packages() {
  print_header "Updating system packages"
  print_step "Running apt-get update"
  apt-get update
  print_step "Running apt-get upgrade -y"
  DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
  print_success "System packages updated."
}

ensure_sshd_runtime_dir() {
  if [[ -d "${SSHD_RUNTIME_DIR}" ]]; then
    return
  fi

  mkdir -p "${SSHD_RUNTIME_DIR}"
  chmod 755 "${SSHD_RUNTIME_DIR}"
  print_success "Created ${SSHD_RUNTIME_DIR}."
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    print_error "This script must be run as root."
    exit 1
  fi
}

# Ensure required local files exist before we make system changes.
require_file() {
  local file_path="$1"

  if [[ ! -f "${file_path}" ]]; then
    print_error "Required file not found: ${file_path}"
    exit 1
  fi
}

# Create the shared deployment user and make sure it can use sudo.
create_deploy_user() {
  print_header "Creating deploy user"
  if id -u "${DEPLOY_USER}" >/dev/null 2>&1; then
    print_warning "User '${DEPLOY_USER}' already exists."
  else
    useradd --create-home --shell /bin/bash "${DEPLOY_USER}"
    print_success "User '${DEPLOY_USER}' created."
  fi

  usermod -aG sudo "${DEPLOY_USER}"
  print_success "User '${DEPLOY_USER}' added to sudo."
}

# Reuse root's existing authorized_keys so the deploy user can log in immediately.
# If root has no authorized_keys file, ask for a public key instead.
copy_authorized_keys() {
  print_header "Configuring SSH access"
  install -d -m 700 -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" "${DEPLOY_SSH_DIR}"

  if [[ -f "${ROOT_SSH_DIR}/authorized_keys" ]]; then
    install -m 600 -o "${DEPLOY_USER}" -g "${DEPLOY_USER}" \
      "${ROOT_SSH_DIR}/authorized_keys" \
      "${DEPLOY_AUTHORIZED_KEYS}"
    print_success "Copied root authorized_keys to '${DEPLOY_USER}'."
    return
  fi

  print_warning "Root authorized_keys not found."
  print_step "Paste a public key for '${DEPLOY_USER}':"

  while true; do
    read -r PUBLIC_KEY_VALUE

    if [[ -z "${PUBLIC_KEY_VALUE}" ]]; then
      print_error "Public key cannot be empty."
      continue
    fi

    printf '%s\n' "${PUBLIC_KEY_VALUE}" > "${DEPLOY_AUTHORIZED_KEYS}"
    chown "${DEPLOY_USER}:${DEPLOY_USER}" "${DEPLOY_AUTHORIZED_KEYS}"
    chmod 600 "${DEPLOY_AUTHORIZED_KEYS}"
    print_success "Installed provided public key for '${DEPLOY_USER}'."
    break
  done
}

# Prompt interactively so the password is never stored in the script.
set_deploy_password() {
  print_header "Setting password"
  print_step "Set a password for '${DEPLOY_USER}':"
  passwd "${DEPLOY_USER}"
  print_success "Password updated for '${DEPLOY_USER}'."
}

# Ask for a hostname until hostnamectl accepts the value.
prompt_for_hostname() {
  print_header "Setting hostname"
  while true; do
    read -r -p "Enter hostname for this VM: " HOSTNAME_VALUE

    if [[ -z "${HOSTNAME_VALUE}" ]]; then
      print_error "Hostname cannot be empty."
      continue
    fi

    if hostnamectl hostname "${HOSTNAME_VALUE}" 2>/dev/null; then
      print_success "Hostname set to '${HOSTNAME_VALUE}'."
      break
    fi

    print_error "Failed to set hostname. Please try again."
  done
}

# Replace the active SSH server config, but restore the old one if validation fails.
install_sshd_config() {
  local backup_path="${SSHD_CONFIG_TARGET}.bak.$(date +%Y%m%d%H%M%S)"

  print_header "Installing SSH configuration"
  print_step "Backing up current config to ${backup_path}"
  cp "${SSHD_CONFIG_TARGET}" "${backup_path}"
  install -m 600 "${SSHD_CONFIG_SOURCE}" "${SSHD_CONFIG_TARGET}"
  ensure_sshd_runtime_dir

  if sshd -t; then
    print_success "Installed sshd_config and validation passed."
  else
    cp "${backup_path}" "${SSHD_CONFIG_TARGET}"
    print_error "sshd_config validation failed. Restored backup: ${backup_path}"
    exit 1
  fi
}

# Reload SSH so the new configuration takes effect without rebooting.
reload_ssh() {
  print_header "Reloading SSH"
  if systemctl is-active --quiet ssh; then
    systemctl reload ssh
  else
    systemctl restart ssh
  fi

  print_success "OpenSSH reloaded."
}

# Remove root's SSH directory after the deploy user and SSH config are in place.
remove_root_ssh() {
  print_header "Removing root SSH keys"
  if [[ -d "${ROOT_SSH_DIR}" ]]; then
    rm -rf "${ROOT_SSH_DIR}"
    print_success "Removed ${ROOT_SSH_DIR}."
  else
    print_warning "${ROOT_SSH_DIR} does not exist, nothing to remove."
  fi
}

logout_current_ssh_session() {
  local reconnect_host

  if [[ -z "${SSH_CONNECTION:-}" ]]; then
    return
  fi

  reconnect_host="$(get_reconnect_host)"

  print_header "Reconnect"
  if [[ -n "${reconnect_host}" ]]; then
    print_step "Log back in with: ssh ${DEPLOY_USER}@${reconnect_host}"
  else
    print_step "Log back in with: ssh ${DEPLOY_USER}@<server-ip>"
  fi
  print_step "Closing the current root SSH session in 3 seconds."
  sleep 3
  kill -HUP "${PPID}"
}

# Run the setup steps in the order needed to avoid breaking SSH access mid-setup.
main() {
  print_header "VM bootstrap"
  print_step "Deploy user: ${DEPLOY_USER}"
  print_step "SSH config source: ${SSHD_CONFIG_SOURCE}"

  require_root
  require_file "${SSHD_CONFIG_SOURCE}"

  update_system_packages
  create_deploy_user
  copy_authorized_keys
  set_deploy_password
  prompt_for_hostname
  install_sshd_config
  reload_ssh
  remove_root_ssh

  print_header "Finished"
  print_success "Initial VM setup complete."
  print_step "Run ./nsd-install.sh to install NSD from source."
  print_blank_line
  logout_current_ssh_session
}

main "$@"
