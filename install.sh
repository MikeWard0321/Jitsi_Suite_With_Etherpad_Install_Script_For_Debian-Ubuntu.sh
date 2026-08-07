#!/usr/bin/env bash
#
# Jitsi Suite (Meet, Jicofo, Videobridge, Jibri) + optional Jigasi and Etherpad
# installer for Debian/Ubuntu.
#
# Must be run as root, e.g.:  sudo ./install.sh
#
# The script is menu driven. Create the configuration file first (option 1),
# then install the components you need.

set -euo pipefail

# --- Constants --------------------------------------------------------------
VIDEOBRIDGE_PROPS="/etc/jitsi/videobridge/sip-communicator.properties"
KEYRING_DIR="/etc/apt/keyrings"
JITSI_KEYRING="${KEYRING_DIR}/jitsi.gpg"
JITSI_SOURCES="/etc/apt/sources.list.d/jitsi-stable.list"

LOG_FILE="/var/log/jitsi_script.log"
CONFIG_FILE="/etc/jitsi_script.conf"

ETHERPAD_USER="etherpad"
ETHERPAD_HOME="/opt/etherpad"
ETHERPAD_REPO="https://github.com/ether/etherpad-lite.git"
# Pin a release tag: the default branch (develop) is a moving target and its
# toolchain requirements change without notice.
ETHERPAD_VERSION="v3.3.3"
# Node.js major required by the pinned Etherpad release (package.json engines).
NODE_MAJOR_REQUIRED=24
ETHERPAD_SERVICE="/etc/systemd/system/etherpad.service"

# Configuration values (populated by read_config_file).
local_ip=""
public_ip=""
fqdn=""
behind_nat="no"
le_email=""

# --- Logging / error handling ----------------------------------------------
# A single, consistent error strategy: `set -e` aborts on any unchecked
# failure and the ERR trap records what failed. `die` is used for explicit,
# validated error conditions.
log_message() {
    local message=$1
    local level=${2:-INFO}
    local line
    line="$(date '+%Y-%m-%d %H:%M:%S'): [$level] $message"
    # Never let a logging failure abort the script.
    echo "$line" >>"$LOG_FILE" 2>/dev/null || true
    echo "$line"
}

die() {
    log_message "$1" "ERROR"
    exit 1
}

on_error() {
    local exit_code=$?
    log_message "Command failed (exit ${exit_code}): ${BASH_COMMAND}" "ERROR"
    exit "$exit_code"
}
trap on_error ERR

require_root() {
    if [[ ${EUID} -ne 0 ]]; then
        die "This script must be run as root (try: sudo $0)."
    fi
}

# --- Generic helpers --------------------------------------------------------
install_package() {
    DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

service_exists() {
    systemctl list-unit-files "${1}.service" --no-legend 2>/dev/null | grep -q "^${1}.service"
}

restart_service() {
    local service=$1
    if service_exists "$service"; then
        systemctl restart "$service"
        log_message "Restarted service: $service"
    else
        log_message "Service $service not found; skipping restart." "WARN"
    fi
}

# Set (or uncomment/append) a key=value property in a properties file.
# Values here are validated IP addresses, so a plain sed replacement is safe.
set_property() {
    local key=$1 value=$2 file=$3
    if grep -q "^${key}=" "$file" 2>/dev/null; then
        sed -i "s|^${key}=.*|${key}=${value}|" "$file"
    elif grep -q "^#[[:space:]]*${key}=" "$file" 2>/dev/null; then
        sed -i "s|^#[[:space:]]*${key}=.*|${key}=${value}|" "$file"
    else
        echo "${key}=${value}" >>"$file"
    fi
}

# --- Validation -------------------------------------------------------------
valid_ip() {
    local ip=$1
    local -a octets
    IFS='.' read -r -a octets <<<"$ip"
    [[ ${#octets[@]} -eq 4 ]] || return 1
    local octet
    for octet in "${octets[@]}"; do
        [[ $octet =~ ^[0-9]+$ ]] || return 1
        ((octet >= 0 && octet <= 255)) || return 1
    done
    return 0
}

valid_fqdn() {
    [[ $1 =~ ^([a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?\.)+[a-zA-Z]{2,}$ ]]
}

# --- Configuration ----------------------------------------------------------
create_config_file() {
    echo "Creating configuration file..."
    if [[ -f $CONFIG_FILE ]]; then
        read -rp "Configuration file already exists. Overwrite it? (y/N): " overwrite
        if [[ ${overwrite,,} != "y" ]]; then
            echo "Keeping existing configuration."
            return
        fi
    fi

    read -rp "Enter local IP address: " local_ip
    valid_ip "$local_ip" || die "Invalid local IP address: $local_ip"

    read -rp "Enter public IP address: " public_ip
    valid_ip "$public_ip" || die "Invalid public IP address: $public_ip"

    read -rp "Enter Fully Qualified Domain Name (FQDN): " fqdn
    valid_fqdn "$fqdn" || die "Invalid FQDN: $fqdn"

    read -rp "Is this server behind NAT? (y/N): " nat_answer
    if [[ ${nat_answer,,} == "y" ]]; then
        behind_nat="yes"
    else
        behind_nat="no"
    fi

    read -rp "Email for Let's Encrypt registration (empty = configure TLS manually): " le_email

    write_config_file
}

write_config_file() {
    # Restrict permissions before writing anything.
    umask 077
    cat >"$CONFIG_FILE" <<EOF
local_ip="$local_ip"
public_ip="$public_ip"
fqdn="$fqdn"
behind_nat="$behind_nat"
le_email="$le_email"
EOF
    chmod 600 "$CONFIG_FILE"
    log_message "Configuration file created at $CONFIG_FILE"
}

# Parse the config file without `source`ing it, so a tampered config cannot
# execute arbitrary code. Only known keys are imported.
read_config_file() {
    [[ -f $CONFIG_FILE ]] || die "Configuration file not found: $CONFIG_FILE. Create it first (menu option 1)."
    local key value
    while IFS='=' read -r key value; do
        # Strip surrounding quotes and whitespace.
        value=${value%\"}
        value=${value#\"}
        case "$key" in
            local_ip) local_ip=$value ;;
            public_ip) public_ip=$value ;;
            fqdn) fqdn=$value ;;
            behind_nat) behind_nat=$value ;;
            le_email) le_email=$value ;;
        esac
    done <"$CONFIG_FILE"

    valid_ip "$local_ip" || die "Configuration has an invalid local_ip: $local_ip"
    valid_ip "$public_ip" || die "Configuration has an invalid public_ip: $public_ip"
    valid_fqdn "$fqdn" || die "Configuration has an invalid fqdn: $fqdn"
}

# --- Jitsi ------------------------------------------------------------------
setup_jitsi_repo() {
    log_message "Configuring the Jitsi APT repository..."
    install_package apt-transport-https ca-certificates curl gnupg
    install -d -m 0755 "$KEYRING_DIR"
    # Store the signing key in its own keyring and pin it to the Jitsi repo
    # only (apt-key is deprecated and trusts the key globally).
    curl -fsSL https://download.jitsi.org/jitsi-key.gpg.key | gpg --dearmor --yes -o "$JITSI_KEYRING"
    chmod 0644 "$JITSI_KEYRING"
    echo "deb [signed-by=${JITSI_KEYRING}] https://download.jitsi.org stable/" >"$JITSI_SOURCES"
    apt-get update
}

configure_jitsi_nat() {
    log_message "Configuring Jitsi videobridge for NAT..."
    local jvb_conf="/etc/jitsi/videobridge/jvb.conf"
    if [[ -f $jvb_conf ]]; then
        # Current videobridge packages use HOCON config; the legacy
        # sip-communicator.properties is no longer shipped. Duplicate
        # top-level objects merge in HOCON, so appending is safe; the
        # marker keeps this idempotent.
        # allowed-addresses pins the harvester to the configured local
        # address. Without it, addresses on point-to-point interfaces
        # (e.g. WireGuard tunnels) are silently skipped, and a NAT that
        # forwards to such an address delivers media to a port nothing
        # is bound on.
        if ! grep -q "installer-managed NAT mapping" "$jvb_conf"; then
            cat >>"$jvb_conf" <<EOF

// installer-managed NAT mapping (do not duplicate)
ice4j {
  harvest {
    allowed-addresses = [ "${local_ip}" ]
    mapping {
      static-mappings = [
        {
          local-address = "${local_ip}"
          public-address = "${public_ip}"
        }
      ]
    }
  }
}
EOF
        else
            sed -i "s|allowed-addresses = \[ \".*\" \]|allowed-addresses = [ \"${local_ip}\" ]|; s|local-address = \".*\"|local-address = \"${local_ip}\"|; s|public-address = \".*\"|public-address = \"${public_ip}\"|" "$jvb_conf"
        fi
    elif [[ -f $VIDEOBRIDGE_PROPS ]]; then
        # Legacy fallback for older videobridge packages.
        set_property "org.ice4j.ice.harvest.NAT_HARVESTER_LOCAL_ADDRESS" "$local_ip" "$VIDEOBRIDGE_PROPS"
        set_property "org.ice4j.ice.harvest.NAT_HARVESTER_PUBLIC_ADDRESS" "$public_ip" "$VIDEOBRIDGE_PROPS"
    else
        die "No videobridge configuration found ($jvb_conf or $VIDEOBRIDGE_PROPS)."
    fi
    restart_service "jitsi-videobridge2"
}

install_jitsi() {
    read_config_file
    log_message "Installing Jitsi Meet and Jibri..."
    setup_jitsi_repo
    # Preseed the hostname so the package install is non-interactive.
    echo "jitsi-videobridge jitsi-videobridge/jvb-hostname string $fqdn" | debconf-set-selections
    install_package jitsi-meet jibri
    # The Let's Encrypt helper prompts for a registration email on stdin; feed
    # it from the config when provided so the install can run unattended.
    if [[ -n ${le_email} ]]; then
        if ! echo "$le_email" | /usr/share/jitsi-meet/scripts/install-letsencrypt-cert.sh; then
            log_message "Let's Encrypt certificate step did not complete; configure TLS manually." "WARN"
        fi
    else
        log_message "No le_email configured; skipping Let's Encrypt (self-signed cert in place). Configure TLS manually." "WARN"
    fi
    if [[ ${behind_nat} == "yes" ]]; then
        configure_jitsi_nat
    else
        log_message "Server is not behind NAT; skipping NAT harvester configuration."
    fi
    log_message "Jitsi Meet installation complete."
    log_message "NEXT STEPS: open firewall ports 80/tcp, 443/tcp, 10000/udp (and 22/tcp for SSH)," "WARN"
    log_message "and enable the secure domain so only authorized users can create rooms." "WARN"
    log_message "See the README (Firewall configuration / Authentication sections) for details." "WARN"
}

# --- Jibri (standalone) -----------------------------------------------------
# For dedicated recording hosts: installs ONLY the Jibri package (plus the
# repo), without Jitsi Meet. Pointing it at the conference host is a separate
# configuration step (XMPP accounts, jibri.conf, brewery MUC).
install_jibri_standalone() {
    log_message "Installing Jibri (standalone recording host)..."
    if [[ ! -f $JITSI_SOURCES ]]; then
        setup_jitsi_repo
    fi
    install_package jibri
    log_message "Jibri installed. Configure /etc/jitsi/jibri/jibri.conf before enabling."
}

# --- Jigasi -----------------------------------------------------------------
install_jigasi() {
    log_message "Installing Jigasi..."
    if [[ ! -f $JITSI_SOURCES ]]; then
        setup_jitsi_repo
    fi
    install_package jigasi
}

# --- Etherpad ---------------------------------------------------------------
create_etherpad_service() {
    cat >"$ETHERPAD_SERVICE" <<EOF
[Unit]
Description=Etherpad collaborative editor
After=network.target

[Service]
Type=simple
User=${ETHERPAD_USER}
Group=${ETHERPAD_USER}
WorkingDirectory=${ETHERPAD_HOME}
ExecStart=${ETHERPAD_HOME}/bin/run.sh
Restart=on-failure
# Hardening
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
    chmod 0644 "$ETHERPAD_SERVICE"
}

node_major() {
    command -v node >/dev/null 2>&1 || return 1
    local v
    v=$(node --version 2>/dev/null) || return 1
    v=${v#v}
    echo "${v%%.*}"
}

install_etherpad() {
    log_message "Installing Etherpad ${ETHERPAD_VERSION}..."
    install_package git curl

    # Etherpad's pinned release declares the Node.js major it needs. An
    # existing but too-old node must not short-circuit this: check the
    # version, not mere presence.
    local current_major
    current_major=$(node_major || echo 0)
    if (( current_major < NODE_MAJOR_REQUIRED )); then
        log_message "Installing Node.js ${NODE_MAJOR_REQUIRED}.x from NodeSource (found major: ${current_major})..."
        curl -fsSL "https://deb.nodesource.com/setup_${NODE_MAJOR_REQUIRED}.x" | bash -
        install_package nodejs
    fi

    # Etherpad's installDeps.sh tries `npm install pnpm -g` when pnpm is
    # missing, which fails for the unprivileged service user. Provide pnpm
    # system-wide as root instead.
    if ! command -v pnpm >/dev/null 2>&1; then
        npm install -g pnpm
    fi

    # Run Etherpad as a dedicated, unprivileged system user. Do NOT let
    # useradd create the home directory: it would copy /etc/skel into it and
    # git refuses to clone into a non-empty directory.
    if ! id -u "$ETHERPAD_USER" >/dev/null 2>&1; then
        useradd --system --home-dir "$ETHERPAD_HOME" \
            --shell /usr/sbin/nologin "$ETHERPAD_USER"
    fi
    install -d -o "$ETHERPAD_USER" -g "$ETHERPAD_USER" "$ETHERPAD_HOME"

    if [[ ! -d "$ETHERPAD_HOME/.git" ]]; then
        git clone --branch "$ETHERPAD_VERSION" --depth 1 "$ETHERPAD_REPO" "$ETHERPAD_HOME"
        chown -R "$ETHERPAD_USER:$ETHERPAD_USER" "$ETHERPAD_HOME"
    else
        # Run git as the owning user: as root it refuses the etherpad-owned
        # repo ("dubious ownership") and would abort a re-run.
        runuser -u "$ETHERPAD_USER" -- git -C "$ETHERPAD_HOME" fetch --depth 1 origin tag "$ETHERPAD_VERSION"
        runuser -u "$ETHERPAD_USER" -- git -C "$ETHERPAD_HOME" checkout "$ETHERPAD_VERSION"
    fi

    # Seed settings.json from the template and trust the local reverse proxy;
    # Etherpad must never be exposed on :9001 directly.
    if [[ ! -f "$ETHERPAD_HOME/settings.json" ]]; then
        runuser -u "$ETHERPAD_USER" -- \
            cp "$ETHERPAD_HOME/settings.json.template" "$ETHERPAD_HOME/settings.json"
        sed -i 's|"trustProxy": false|"trustProxy": true|' "$ETHERPAD_HOME/settings.json"
    fi

    # Install dependencies as the etherpad user (not root).
    runuser -u "$ETHERPAD_USER" -- bash -c "cd '$ETHERPAD_HOME' && ./bin/installDeps.sh"

    create_etherpad_service
    systemctl daemon-reload
    systemctl enable --now etherpad
    log_message "Etherpad ${ETHERPAD_VERSION} installed and running as a systemd service (user: $ETHERPAD_USER)."

    integrate_etherpad_with_jitsi
}

# Wire Etherpad into a Jitsi Meet install on the same host: proxy it under
# /etherpad/ on the Jitsi nginx vhost (same-origin, so the meeting iframe
# works without cross-site cookie trouble) and point config.js at it. This is
# the documented docker-jitsi-meet pattern. No-op when Jitsi is not installed.
integrate_etherpad_with_jitsi() {
    [[ -f $CONFIG_FILE ]] || return 0
    read_config_file
    local nginx_site="/etc/nginx/sites-available/${fqdn}.conf"
    local meet_config="/etc/jitsi/meet/${fqdn}-config.js"
    if [[ ! -f $nginx_site || ! -f $meet_config ]]; then
        log_message "Jitsi Meet not detected on this host; skipping Etherpad integration."
        return 0
    fi

    if ! grep -q "installer-managed etherpad location" "$nginx_site"; then
        # Insert the proxy location at the top of the server block that holds
        # the existing app locations (the one with the root directive).
        awk '
            /installer-managed/ { print; next }
            !inserted && /location = \/config.js/ {
                print "    # installer-managed etherpad location"
                print "    location ^~ /etherpad/ {"
                print "        proxy_pass http://127.0.0.1:9001/;"
                print "        proxy_http_version 1.1;"
                print "        proxy_set_header Upgrade $http_upgrade;"
                print "        proxy_set_header Connection \"upgrade\";"
                print "        proxy_set_header Host $host;"
                print "        proxy_set_header X-Forwarded-For $remote_addr;"
                print "        proxy_buffering off;"
                print "    }"
                inserted = 1
            }
            { print }
        ' "$nginx_site" >"${nginx_site}.tmp" && mv "${nginx_site}.tmp" "$nginx_site"
    fi

    if ! grep -q "installer-managed etherpad_base" "$meet_config"; then
        cat >>"$meet_config" <<EOF

// installer-managed etherpad_base
config.etherpad_base = 'https://${fqdn}/etherpad/p/';
EOF
    fi

    if nginx -t >/dev/null 2>&1; then
        systemctl reload nginx
        log_message "Etherpad integrated with Jitsi Meet at https://${fqdn}/etherpad/."
    else
        log_message "nginx config test failed after Etherpad integration; NOT reloaded. Inspect ${nginx_site}." "ERROR"
        return 1
    fi
}

# --- TURN + JWT tokens ------------------------------------------------------
# Note: neither package is a Jibri prerequisite. TURN helps clients behind
# restrictive NATs; jitsi-meet-tokens enables JWT auth (e.g. for embedding in
# Matrix/Nextcloud). Installing tokens switches Prosody to token auth, so the
# app ID/secret are preseeded here and recorded in the config file.
install_recording_service() {
    read_config_file
    log_message "Installing TURN server + JWT token support..."
    if [[ ! -f $JITSI_SOURCES ]]; then
        setup_jitsi_repo
    fi
    local app_id="jitsi" app_secret
    app_secret=$(head -c 32 /dev/urandom | base64 | tr -d '/+=' | head -c 32)
    echo "jitsi-meet-tokens jitsi-meet-tokens/appid string ${app_id}" | debconf-set-selections
    echo "jitsi-meet-tokens jitsi-meet-tokens/appsecret password ${app_secret}" | debconf-set-selections
    install_package jitsi-meet-tokens jitsi-meet-turnserver
    umask 077
    {
        echo "jwt_app_id=\"${app_id}\""
        echo "jwt_app_secret=\"${app_secret}\""
    } >>"$CONFIG_FILE"
    log_message "JWT app ID/secret recorded in ${CONFIG_FILE} (mode 0600)."
    log_message "TURN + token support installed. Configure Jibri separately to enable recording."
}

# --- Secure domain (lock down room creation) --------------------------------
# Switches the main virtual host to internal authentication and adds an
# anonymous guest host, so only registered users can create/open rooms while
# guests may still join. Idempotent.
harden_secure_domain() {
    read_config_file
    log_message "Enabling secure domain (authenticated room creation only)..."
    local prosody_cfg="/etc/prosody/conf.avail/${fqdn}.cfg.lua"
    local jicofo="/etc/jitsi/jicofo/jicofo.conf"
    local meet_cfg="/etc/jitsi/meet/${fqdn}-config.js"
    [[ -f $prosody_cfg ]] || die "Prosody config not found: $prosody_cfg (install Jitsi first)."

    # Flip the main domain's VirtualHost to internal auth. Packages ship it as
    # 'anonymous' or Debian's 'jitsi-anonymous'. Before the guest host is
    # appended below, that line is the only anonymous auth in the file, so a
    # global replace is safe (auth./recorder. hosts are already internal_hashed).
    sed -i 's/authentication = "anonymous"/authentication = "internal_hashed"/; s/authentication = "jitsi-anonymous"/authentication = "internal_hashed"/' "$prosody_cfg"
    if ! grep -q "VirtualHost \"guest.${fqdn}\"" "$prosody_cfg"; then
        cat >>"$prosody_cfg" <<EOF

VirtualHost "guest.${fqdn}"
    authentication = "anonymous"
    c2s_require_encryption = false
EOF
    fi

    if ! grep -q "installer-managed secure domain" "$jicofo"; then
        cat >>"$jicofo" <<EOF

// installer-managed secure domain
jicofo {
  authentication {
    enabled = true
    type = XMPP
    login-url = "${fqdn}"
  }
}
EOF
    fi

    if ! grep -q "installer-managed anonymousdomain" "$meet_cfg"; then
        cat >>"$meet_cfg" <<EOF

// installer-managed anonymousdomain (secure domain)
config.hosts.anonymousdomain = 'guest.${fqdn}';
EOF
    fi

    systemctl restart prosody jicofo jitsi-videobridge2
    log_message "Secure domain enabled. Create staff users with: $0 --add-user NAME"
}

# Register (or update) a Prosody user on the main domain. Password from
# --user-password if given, otherwise generated and recorded root-only.
add_prosody_user() {
    local user=$1 password=${2:-}
    read_config_file
    [[ -n $user ]] || die "add_prosody_user: username required."
    if [[ -z $password ]]; then
        password=$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 20)
    fi
    # prosodyctl register is idempotent-ish: it errors if the user exists, so
    # try register and fall back to passwd.
    if ! prosodyctl register "$user" "$fqdn" "$password" 2>/dev/null; then
        prosodyctl passwd "$user" "$fqdn" <<EOF || die "Failed to set password for ${user}@${fqdn}."
$password
$password
EOF
    fi
    umask 077
    local cred_file="/root/meet-credentials.txt"
    printf '%s@%s : %s\n' "$user" "$fqdn" "$password" >>"$cred_file"
    log_message "Registered ${user}@${fqdn}. Credentials appended to ${cred_file} (mode 0600)."
}

# --- Branding (brand-neutral; values passed as flags) -----------------------
# APP_NAME/PROVIDER default to Jitsi's own; pass --app-name/--provider (and
# optionally --watermark/--favicon files) to rebrand. Served via a per-domain
# interface_config.js so package upgrades don't clobber it.
apply_branding() {
    read_config_file
    local app_name=${BRAND_APP_NAME:-} provider=${BRAND_PROVIDER:-}
    local watermark=${BRAND_WATERMARK:-} favicon=${BRAND_FAVICON:-} link=${BRAND_LINK:-}
    local web="/usr/share/jitsi-meet"
    local ifcfg="/etc/jitsi/meet/${fqdn}-interface_config.js"
    local nginx_site="/etc/nginx/sites-available/${fqdn}.conf"
    [[ -f "$web/interface_config.js" ]] || die "Jitsi Meet not installed; nothing to brand."

    if [[ -n $watermark && -f $watermark ]]; then
        cp -a "$web/images/watermark.svg" "$web/images/watermark.svg.orig" 2>/dev/null || true
        cp "$watermark" "$web/images/watermark.svg"
    fi
    if [[ -n $favicon && -f $favicon ]]; then
        cp -a "$web/images/favicon.ico" "$web/images/favicon.ico.orig" 2>/dev/null || true
        cp "$favicon" "$web/images/favicon.ico"
        [[ -f "$web/favicon.ico" ]] && cp "$favicon" "$web/favicon.ico"
    fi

    cp "$web/interface_config.js" "$ifcfg"
    [[ -n $app_name ]] && sed -i "s|APP_NAME: '[^']*'|APP_NAME: '${app_name}'|; s|NATIVE_APP_NAME: '[^']*'|NATIVE_APP_NAME: '${app_name}'|" "$ifcfg"
    [[ -n $provider ]] && sed -i "s|PROVIDER_NAME: '[^']*'|PROVIDER_NAME: '${provider}'|" "$ifcfg"
    [[ -n $link ]] && sed -i "s|JITSI_WATERMARK_LINK: '[^']*'|JITSI_WATERMARK_LINK: '${link}'|" "$ifcfg"
    chmod 644 "$ifcfg"

    if [[ -f $nginx_site ]] && ! grep -q "installer-managed interface_config" "$nginx_site"; then
        awk -v ifcfg="$ifcfg" '
            !inserted && /location = \/config.js/ {
                print "    # installer-managed interface_config"
                print "    location = /interface_config.js {"
                print "        alias " ifcfg ";"
                print "    }"
                inserted = 1
            }
            { print }
        ' "$nginx_site" >"${nginx_site}.tmp" && mv "${nginx_site}.tmp" "$nginx_site"
        nginx -t >/dev/null 2>&1 && systemctl reload nginx
    fi
    log_message "Branding applied (APP_NAME='${app_name:-unchanged}')."
}

# --- Jibri: recorder accounts + brewery (run on the Jitsi/meet host) --------
# Registers the jibri (control) and recorder (call) XMPP accounts, wires the
# Jicofo brewery, and enables file recording in the meet config. Prints the
# passwords (and records them root-only) so the Jibri host can be configured.
setup_jibri_accounts() {
    read_config_file
    log_message "Provisioning Jibri XMPP accounts + brewery on ${fqdn}..."
    local jicofo="/etc/jitsi/jicofo/jicofo.conf"
    local meet_cfg="/etc/jitsi/meet/${fqdn}-config.js"
    local jibri_pw recorder_pw
    jibri_pw=$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 20)
    recorder_pw=$(head -c 24 /dev/urandom | base64 | tr -d '/+=' | head -c 20)

    prosodyctl register jibri "auth.${fqdn}" "$jibri_pw" 2>/dev/null || \
        prosodyctl passwd jibri "auth.${fqdn}" <<EOF
$jibri_pw
$jibri_pw
EOF
    prosodyctl register recorder "recorder.${fqdn}" "$recorder_pw" 2>/dev/null || \
        prosodyctl passwd recorder "recorder.${fqdn}" <<EOF
$recorder_pw
$recorder_pw
EOF

    if ! grep -q "installer-managed jibri brewery" "$jicofo"; then
        cat >>"$jicofo" <<EOF

// installer-managed jibri brewery
jicofo {
  jibri {
    brewery-jid = "JibriBrewery@internal.auth.${fqdn}"
    pending-timeout = 90 seconds
  }
}
EOF
    fi
    if ! grep -q "installer-managed recording" "$meet_cfg"; then
        cat >>"$meet_cfg" <<EOF

// installer-managed recording
config.recordingService = { enabled: true, sharingEnabled: false };
config.fileRecordingsEnabled = true;
config.hiddenDomain = 'recorder.${fqdn}';
EOF
    fi
    systemctl restart jicofo

    umask 077
    local cred="/root/jibri-credentials.txt"
    {
        echo "# Feed these to the Jibri host:  $0 --configure-jibri --meet-fqdn ${fqdn} \\"
        echo "#   --jibri-password '${jibri_pw}' --recorder-password '${recorder_pw}'"
        echo "jibri_control auth.${fqdn} jibri ${jibri_pw}"
        echo "jibri_recorder recorder.${fqdn} recorder ${recorder_pw}"
    } >"$cred"
    log_message "Jibri accounts provisioned. Passwords recorded in ${cred} (mode 0600)."
    log_message "Now configure the Jibri host with --configure-jibri (see ${cred})."
}

# --- Jibri: full runtime configuration (run on the Jibri host) --------------
# Installs media/browser prerequisites and writes jibri.conf pointing at the
# meet host. Requires --meet-fqdn and the two passwords from setup_jibri_accounts.
configure_jibri() {
    local meet_fqdn=${JIBRI_MEET_FQDN:-}
    local jibri_pw=${JIBRI_CONTROL_PW:-}
    local recorder_pw=${JIBRI_RECORDER_PW:-}
    local rec_dir=${JIBRI_REC_DIR:-/srv/recordings}
    [[ -n $meet_fqdn ]] || die "configure_jibri: --meet-fqdn required."
    [[ -n $jibri_pw && -n $recorder_pw ]] || die "configure_jibri: --jibri-password and --recorder-password required."

    log_message "Configuring Jibri to record ${meet_fqdn} into ${rec_dir}..."
    if [[ ! -f $JITSI_SOURCES ]]; then
        setup_jitsi_repo
    fi
    install_package jibri ffmpeg unzip curl "linux-image-extra-virtual" 2>/dev/null || \
        install_package jibri ffmpeg unzip curl

    # ALSA loopback for audio capture.
    echo snd-aloop >/etc/modules-load.d/snd-aloop.conf
    modprobe snd-aloop || log_message "modprobe snd-aloop failed; a reboot may be needed." "WARN"

    # Google Chrome + a matching chromedriver.
    install -d -m 0755 "$KEYRING_DIR"
    curl -fsSL https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor --yes -o "${KEYRING_DIR}/google-chrome.gpg"
    echo "deb [arch=amd64 signed-by=${KEYRING_DIR}/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" >/etc/apt/sources.list.d/google-chrome.list
    apt-get update
    install_package google-chrome-stable
    local cd_url
    cd_url=$(curl -fsSL https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json \
        | grep -o '"platform":"linux64","url":"[^"]*chromedriver[^"]*"' | head -1 | sed 's/.*"url":"//; s/"$//')
    if [[ -n $cd_url ]]; then
        curl -fsSL "$cd_url" -o /tmp/chromedriver.zip
        unzip -o -q /tmp/chromedriver.zip -d /tmp/cd
        install -m 0755 /tmp/cd/chromedriver-linux64/chromedriver /usr/local/bin/chromedriver
        rm -rf /tmp/chromedriver.zip /tmp/cd
    else
        log_message "Could not resolve a chromedriver download URL; install it manually." "WARN"
    fi

    id -u jibri >/dev/null 2>&1 || useradd --system --groups adm,audio,video,plugdev jibri || true
    install -d -o jibri -g jibri "$rec_dir"

    cat >/opt/jitsi/jibri-finalize.sh <<'FIN'
#!/bin/bash
# Jibri finalize hook. $1 = recording directory. No-op; extend to
# transcode/upload/notify as needed. Must exit 0.
logger -t jibri-finalize "Recording finalized: ${1:-?}"
exit 0
FIN
    chmod +x /opt/jitsi/jibri-finalize.sh

    cat >/etc/jitsi/jibri/jibri.conf <<EOF
jibri {
  id = "$(hostname)"
  single-use-mode = false
  api {
    http {
      external-api-port = 2222
      internal-api-port = 3333
    }
    xmpp {
      environments = [
        {
          name = "prod"
          xmpp-server-hosts = [ "${meet_fqdn}" ]
          xmpp-domain = "${meet_fqdn}"
          control-muc {
            domain = "internal.auth.${meet_fqdn}"
            room-name = "JibriBrewery"
            nickname = "$(hostname)"
          }
          control-login {
            domain = "auth.${meet_fqdn}"
            username = "jibri"
            password = "${jibri_pw}"
          }
          call-login {
            domain = "recorder.${meet_fqdn}"
            username = "recorder"
            password = "${recorder_pw}"
          }
          strip-from-room-domain = "conference."
          usage-timeout = 0
          trust-all-xmpp-certs = true
        }
      ]
    }
  }
  recording {
    recordings-directory = "${rec_dir}"
    finalize-script = "/opt/jitsi/jibri-finalize.sh"
  }
  chrome {
    flags = [
      "--use-fake-ui-for-media-stream",
      "--start-maximized",
      "--kiosk",
      "--enabled",
      "--autoplay-policy=no-user-gesture-required"
    ]
  }
  ffmpeg { resolution = "1920x1080" }
}
EOF
    chown jibri:jibri /etc/jitsi/jibri/jibri.conf
    chmod 600 /etc/jitsi/jibri/jibri.conf
    systemctl enable --now jibri-xorg jibri-icewm jibri
    log_message "Jibri configured and started; it should appear in the Jicofo brewery on ${meet_fqdn}."
}

# --- Uninstallers -----------------------------------------------------------
uninstall_jitsi() {
    log_message "Uninstalling Jitsi..."
    apt-get purge -y jitsi-meet jicofo jitsi-videobridge2 jibri || true
    apt-get autoremove -y
    rm -f "$JITSI_SOURCES" "$JITSI_KEYRING"
}

uninstall_jigasi() {
    log_message "Uninstalling Jigasi..."
    apt-get purge -y jigasi || true
    apt-get autoremove -y
}

uninstall_etherpad() {
    log_message "Uninstalling Etherpad..."
    if service_exists etherpad; then
        systemctl disable --now etherpad || true
    fi
    rm -f "$ETHERPAD_SERVICE"
    systemctl daemon-reload || true
    if id -u "$ETHERPAD_USER" >/dev/null 2>&1; then
        userdel --remove "$ETHERPAD_USER" || true
    fi
    rm -rf "$ETHERPAD_HOME"
    # System Node.js and git are intentionally left in place; other software
    # may depend on them.
    log_message "Etherpad removed. System Node.js and git were left intact."
}

uninstall_recording_service() {
    log_message "Uninstalling TURN + JWT token support..."
    apt-get purge -y jitsi-meet-tokens jitsi-meet-turnserver || true
    apt-get autoremove -y
}

reinstall_service() {
    local service=$1
    case $service in
        jitsi) uninstall_jitsi; install_jitsi ;;
        jigasi) uninstall_jigasi; install_jigasi ;;
        etherpad) uninstall_etherpad; install_etherpad ;;
        recording) uninstall_recording_service; install_recording_service ;;
        *) echo "Invalid service: $service" ;;
    esac
}

# --- Menu -------------------------------------------------------------------
display_menu() {
    cat <<'EOF'

===== Jitsi Suite Installer =====
 1) Create/update configuration file
 2) Install Jitsi (Meet, Jicofo, Videobridge, Jibri)
 3) Install Jigasi
 4) Install Etherpad
 5) Install TURN server + JWT token support
 6) Uninstall Jitsi
 7) Uninstall Jigasi
 8) Uninstall Etherpad
 9) Uninstall TURN + JWT token support
10) Reinstall Jitsi
11) Reinstall Jigasi
12) Reinstall Etherpad
13) Reinstall TURN + JWT token support
14) Exit
EOF
}

# --- Headless (flag-driven) mode --------------------------------------------
usage() {
    cat <<'EOF'
Usage: install.sh [options]           (no options = interactive menu)

Configuration (writes /etc/jitsi_script.conf non-interactively):
  --configure --local-ip IP --public-ip IP --fqdn FQDN
              [--behind-nat] [--le-email EMAIL]

Actions (run in the order given):
  --install-jitsi       Install Jitsi Meet + Jibri packages
  --install-jibri       Install ONLY the Jibri package (dedicated recording host)
  --install-jigasi      Install Jigasi
  --install-etherpad    Install Etherpad (pinned release, systemd service)
  --install-tokens      Install TURN server + JWT token support
  --uninstall-jitsi | --uninstall-jigasi | --uninstall-etherpad | --uninstall-tokens

Hardening / branding / recording (run on the Jitsi host unless noted):
  --secure-domain       Lock down room creation (authenticated users only)
  --add-user NAME [--user-password PW]
                        Register a Prosody user (generates a password if omitted)
  --brand [--app-name NAME] [--provider NAME] [--brand-link URL]
          [--watermark FILE] [--favicon FILE]
                        Rebrand the Jitsi Meet UI (brand-neutral by default)
  --jibri-accounts      Provision Jibri XMPP accounts + brewery on the Jitsi host
  --configure-jibri --meet-fqdn FQDN --jibri-password PW --recorder-password PW
          [--recordings-dir DIR]
                        Full Jibri runtime config (run on the Jibri/recording host)
  --help                Show this help
EOF
}

run_headless() {
    local do_configure="no"
    local add_user_name=""
    local -a actions=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --configure) do_configure="yes" ;;
            --local-ip) local_ip=$2; shift ;;
            --public-ip) public_ip=$2; shift ;;
            --fqdn) fqdn=$2; shift ;;
            --behind-nat) behind_nat="yes" ;;
            --le-email) le_email=$2; shift ;;
            --install-jitsi) actions+=(install_jitsi) ;;
            --install-jibri) actions+=(install_jibri_standalone) ;;
            --install-jigasi) actions+=(install_jigasi) ;;
            --install-etherpad) actions+=(install_etherpad) ;;
            --install-tokens|--install-recording) actions+=(install_recording_service) ;;
            --uninstall-jitsi) actions+=(uninstall_jitsi) ;;
            --uninstall-jigasi) actions+=(uninstall_jigasi) ;;
            --uninstall-etherpad) actions+=(uninstall_etherpad) ;;
            --uninstall-tokens|--uninstall-recording) actions+=(uninstall_recording_service) ;;
            --secure-domain) actions+=(harden_secure_domain) ;;
            --add-user) add_user_name=$2; shift; actions+=(_do_add_user) ;;
            --user-password) USER_PASSWORD=$2; shift ;;
            --brand) actions+=(apply_branding) ;;
            --app-name) BRAND_APP_NAME=$2; shift ;;
            --provider) BRAND_PROVIDER=$2; shift ;;
            --brand-link) BRAND_LINK=$2; shift ;;
            --watermark) BRAND_WATERMARK=$2; shift ;;
            --favicon) BRAND_FAVICON=$2; shift ;;
            --jibri-accounts) actions+=(setup_jibri_accounts) ;;
            --configure-jibri) actions+=(configure_jibri) ;;
            --meet-fqdn) JIBRI_MEET_FQDN=$2; shift ;;
            --jibri-password) JIBRI_CONTROL_PW=$2; shift ;;
            --recorder-password) JIBRI_RECORDER_PW=$2; shift ;;
            --recordings-dir) JIBRI_REC_DIR=$2; shift ;;
            --help|-h) usage; exit 0 ;;
            *) usage; die "Unknown option: $1" ;;
        esac
        shift
    done

    # Bind --add-user's argument to a thunk so it runs in action order.
    _do_add_user() { add_prosody_user "$add_user_name" "${USER_PASSWORD:-}"; }

    if [[ $do_configure == "yes" ]]; then
        valid_ip "$local_ip" || die "Invalid or missing --local-ip"
        valid_ip "$public_ip" || die "Invalid or missing --public-ip"
        valid_fqdn "$fqdn" || die "Invalid or missing --fqdn"
        write_config_file
    fi

    local action
    for action in "${actions[@]}"; do
        "$action"
    done
}

# --- Main -------------------------------------------------------------------
main() {
    require_root
    log_message "Script started."

    if [[ $# -gt 0 ]]; then
        run_headless "$@"
        log_message "Script finished."
        return
    fi

    local choice
    while true; do
        display_menu
        read -rp "Select an option [1-14]: " choice
        case "$choice" in
            1) create_config_file ;;
            2) install_jitsi ;;
            3)
                read -rp "Install Jigasi? (y/N): " confirm
                [[ ${confirm,,} == "y" ]] && install_jigasi
                ;;
            4) install_etherpad ;;
            5) install_recording_service ;;
            6) uninstall_jitsi ;;
            7) uninstall_jigasi ;;
            8) uninstall_etherpad ;;
            9) uninstall_recording_service ;;
            10) reinstall_service jitsi ;;
            11) reinstall_service jigasi ;;
            12) reinstall_service etherpad ;;
            13) reinstall_service recording ;;
            14) log_message "Exiting."; break ;;
            *) echo "Invalid option. Please choose 1-14." ;;
        esac
    done

    log_message "Script finished."
}

main "$@"
