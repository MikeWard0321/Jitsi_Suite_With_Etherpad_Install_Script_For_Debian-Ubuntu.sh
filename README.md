# Jitsi Suite With Etherpad Install Script (Debian/Ubuntu)

A menu-driven installer for the Jitsi suite — **Jitsi Meet, Jicofo, Jitsi
Videobridge, and Jibri** — with optional **Jigasi** (SIP gateway) and
**Etherpad** (collaborative document editor).

Because setting these services up by hand is fiddly, this script automates the
process so they can be deployed consistently. It creates a small configuration
file, then uses it to drive the installation, including optional NAT
configuration for the videobridge.

The script targets Debian/Ubuntu but can be adapted for other distributions.

## Requirements

- Debian or Ubuntu with `systemd`.
- Root privileges (run with `sudo` or as `root`).
- A DNS record pointing your FQDN at the server's public IP (required for
  Jitsi Meet and Let's Encrypt certificate issuance).
- Inbound firewall access for the standard Jitsi ports (TCP `80`, `443`;
  UDP `10000`).

## Usage

```bash
# Make it executable, then run it as root:
chmod +x install.sh
sudo ./install.sh
```

You'll be presented with a menu:

```
 1) Create/update configuration file
 2) Install Jitsi (Meet, Jicofo, Videobridge, Jibri)
 3) Install Jigasi
 4) Install Etherpad
 5) Install recording prerequisites (TURN + tokens)
 6) Uninstall Jitsi
 7) Uninstall Jigasi
 8) Uninstall Etherpad
 9) Uninstall recording prerequisites
10) Reinstall Jitsi
11) Reinstall Jigasi
12) Reinstall Etherpad
13) Reinstall recording prerequisites
14) Exit
```

**Run option 1 first** to create the configuration file. You'll be asked for:

- **Local IP address** — the server's private/LAN address.
- **Public IP address** — the server's public/WAN address.
- **FQDN** — the fully qualified domain name for Jitsi Meet.
- **Behind NAT?** — if yes, the videobridge is configured with the local and
  public NAT harvester addresses.

The configuration is stored at `/etc/jitsi_script.conf` with `0600`
permissions (root-only). Actions are logged to `/var/log/jitsi_script.log`.

## Notes on the components

- **Jitsi (option 2)** installs Jitsi Meet and Jibri from the official Jitsi
  APT repository and attempts to obtain a Let's Encrypt certificate. NAT
  configuration is applied only when you indicated the server is behind NAT.
- **Etherpad (option 4)** is installed into `/opt/etherpad`, run as a
  dedicated unprivileged `etherpad` system user, and managed by a hardened
  `etherpad.service` systemd unit (so it restarts on failure and survives
  reboots). Node.js is installed from NodeSource if a suitable version isn't
  already present.
- **Recording prerequisites (option 5)** install `jitsi-meet-turnserver` and
  `jitsi-meet-tokens`. Jibri must be configured separately to enable
  recording.

## Security notes

- The Jitsi signing key is stored in its own keyring
  (`/etc/apt/keyrings/jitsi.gpg`) and pinned to the Jitsi repository via
  `signed-by=`, rather than using the deprecated `apt-key`.
- The configuration file contains no secrets and is written with restrictive
  permissions.
- Etherpad does not run as root.
- Review Jitsi's own [security
  recommendations](https://jitsi.github.io/handbook/docs/devops-guide/secure-domain)
  (e.g. enabling authentication so only authorized users can create rooms)
  before exposing an instance to the internet.

## Uninstalling

The uninstall options remove the relevant packages. Note that uninstalling
Etherpad removes the `etherpad` user, its home directory, and the systemd
unit, but **intentionally leaves system Node.js and git in place** so other
software isn't broken.

## Contributing

The installer lives in [`install.sh`](install.sh). Feel free to fork and adapt
it to your needs.
