# NSD Server Bootstrap

Initialization scripts for a basic NSD server on Ubuntu 24.04 LTS.

This repository is meant for bootstrapping a fresh Ubuntu 24.04 machine and installing NSD from source with a simple, opinionated setup.

This repository is public only so these scripts can be fetched from newly provisioned or otherwise unauthenticated machines during initial setup. They are primarily maintained for my own server workflow, not as a general-purpose setup for other environments.

Included files:

- `nsd-server-init.sh` bootstraps a new VM for deployment by creating a `deploy` user, copying SSH access, applying the bundled `sshd_config`, and setting the hostname.
- `nsd-install.sh` installs NSD from source along with the required build dependencies.
- `config/sshd_config` contains the SSH server configuration used by the bootstrap script.

These scripts assume Ubuntu 24.04 LTS and should be reviewed before running on any other distribution or server layout.
