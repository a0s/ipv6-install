#!/bin/bash

# Automatic IPv6 for macOS: WireGuard tunnel when the network has no IPv6
# https://github.com/a0s/ipv6-install

readonly VERSION="0.1.4"
readonly REPO_RAW="https://raw.githubusercontent.com/a0s/ipv6-install/master"
readonly ETC_DIR="/usr/local/etc/ipv6-auto"
readonly CONF="${ETC_DIR}/wg6.conf"
readonly PARAMS="${ETC_DIR}/params"
readonly BIN="/usr/local/sbin/ipv6-auto"
readonly LABEL="io.github.a0s.ipv6-auto"
readonly PLIST="/Library/LaunchDaemons/${LABEL}.plist"
readonly LOG="/var/log/ipv6-auto.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
ORANGE='\033[0;33m'
NC='\033[0m'

function isRoot() {
	if [ "${EUID}" -ne 0 ]; then
		echo "You need to run this script with sudo"
		exit 1
	fi
	if [ -z "${SUDO_USER}" ] || [ "${SUDO_USER}" == "root" ]; then
		echo "Run it with sudo from your normal user account (Homebrew does not run as root)"
		exit 1
	fi
}

function checkOS() {
	if [ "$(uname -s)" != "Darwin" ]; then
		echo "This installer is for macOS only"
		exit 1
	fi
	MACOS_MAJOR=$(sw_vers -productVersion | cut -d. -f1)
	if [ "${MACOS_MAJOR}" -lt 13 ]; then
		echo "Your version of macOS ($(sw_vers -productVersion)) is not supported. Please use macOS 13 Ventura or later"
		exit 1
	fi
}

function checkBrew() {
	BREW=""
	for b in /opt/homebrew/bin/brew /usr/local/bin/brew; do
		[ -x "$b" ] && BREW=$b && break
	done
	if [ -z "${BREW}" ]; then
		echo -e "${RED}Homebrew is not installed.${NC} Install it from https://brew.sh and run this script again."
		exit 1
	fi
	BREW_PREFIX=$(dirname "$(dirname "${BREW}")")
}

function initialCheck() {
	isRoot
	checkOS
	checkBrew
}

function userHome() {
	dscl . -read "/Users/${SUDO_USER}" NFSHomeDirectory | awk '{print $2}'
}

# ask "Question" default -> REPLY
function ask() {
	read -rp "$1 [$2]: " REPLY
	REPLY=${REPLY:-$2}
}

function installQuestions() {
	echo "Welcome to the ipv6-auto installer!"
	echo "The git repository is available at: https://github.com/a0s/ipv6-install"
	echo ""
	echo "When your Mac joins a network without IPv6, ipv6-auto brings up a WireGuard tunnel"
	echo "to an IPv6 tunnel broker. On networks with native IPv6 the tunnel goes away."
	echo ""
	echo "I need to ask you a few questions before starting the setup."
	echo "You can keep the default options and just press enter if you are ok with them."
	echo ""
	echo "You need a WireGuard config with IPv6. A free one: https://manager.route64.org"
	echo "  Tunnel Management > Add tunnel > IPv6 Tunnelbroker > closest PoP > WireGuard"
	echo "  then Raw Config > Download .conf"
	echo ""

	echo "Where is the WireGuard config?"
	echo "   1) Path to a .conf file"
	echo "   2) Paste it here"
	until [[ ${CONF_CHOICE} =~ ^[1-2]$ ]]; do
		ask "Config choice [1-2]" 1
		CONF_CHOICE=$REPLY
	done
	if [ "${CONF_CHOICE}" == 1 ]; then
		pickConfig
	else
		CONF_SRC=$(mktemp)
		echo "Paste the config, then press Ctrl-D on an empty line:"
		cat >"${CONF_SRC}"
	fi
	readConfig "${CONF_SRC}" || exit 1

	echo ""
	echo "How should apps use the tunnel?"
	echo "   1) Like native IPv6: websites that have IPv6 use it (recommended)"
	echo "   2) Only for addresses that are IPv6-only (IPv4 stays preferred)"
	until [[ ${MIRROR_CHOICE} =~ ^[1-2]$ ]]; do
		ask "Mode [1-2]" 1
		MIRROR_CHOICE=$REPLY
	done
	[ "${MIRROR_CHOICE}" == 1 ] && MIRROR=yes || MIRROR=no

	echo ""
	echo "When another VPN connects (for example a WireGuard.app tunnel):"
	echo "   1) Step aside and come back when it disconnects (recommended)"
	echo "   2) Keep the tunnel running"
	until [[ ${YIELD_CHOICE} =~ ^[1-2]$ ]]; do
		ask "Choice [1-2]" 1
		YIELD_CHOICE=$REPLY
	done
	[ "${YIELD_CHOICE}" == 1 ] && YIELD_TO_VPN=yes || YIELD_TO_VPN=no

	echo ""
	echo "Okay, that was all I needed. We are ready to set up ipv6-auto now."
	read -n1 -r -p "Press any key to continue..."
	echo ""
}

# Show WireGuard configs from Downloads and Desktop with their endpoints, let the user pick one.
# There is no default on purpose: other VPN configs often sit in Downloads too.
function pickConfig() {
	local f ep v6 n=0
	FOUND=()
	while IFS= read -r f; do
		grep -q '^\[Interface\]' "$f" 2>/dev/null || continue
		n=$((n + 1))
		FOUND+=("$f")
		ep=$(awk -F' *= *' '$1=="Endpoint"{print $2; exit}' "$f")
		grep -Eq '^Address *=.*:' "$f" && v6="IPv6" || v6="no IPv6 address"
		echo "   ${n}) ${f/#"$(userHome)"/\~}  (${ep:-no endpoint}, ${v6})"
	done < <(find "$(userHome)/Downloads" "$(userHome)/Desktop" -maxdepth 1 -name '*.conf' 2>/dev/null)
	[ "$n" -gt 0 ] && echo "Pick a number or type a path."
	CONF_SRC=""
	until [ -r "${CONF_SRC}" ]; do
		read -rp "Config: " REPLY
		if [[ ${REPLY} =~ ^[0-9]+$ ]] && [ "${REPLY}" -ge 1 ] && [ "${REPLY}" -le "$n" ]; then
			CONF_SRC=${FOUND[$((REPLY - 1))]}
		else
			CONF_SRC=${REPLY/#\~/$(userHome)}
		fi
		[ -r "${CONF_SRC}" ] || echo -e "${ORANGE}Cannot read ${CONF_SRC:-that}${NC}"
	done
}

# Keep only IPv6 from a WireGuard config: drop DNS, IPv4 routes and lines that are not config
# (Route64 "Raw Config" includes a "ping ..." line).
function readConfig() {
	local src=$1
	CLEAN_CONF=$(grep -E '^[[:space:]]*(\[|#|$|[A-Za-z]+[[:space:]]*=)' "$src" |
		sed -E -e '/^[[:space:]]*DNS[[:space:]]*=/d' \
			-e 's#0\.0\.0\.0/0[[:space:]]*,?[[:space:]]*##; s#,[[:space:]]*$##')
	local missing=""
	grep -q '^\[Interface\]' <<<"${CLEAN_CONF}" || missing+=" [Interface]"
	grep -q '^\[Peer\]' <<<"${CLEAN_CONF}" || missing+=" [Peer]"
	grep -Eq '^PrivateKey *=' <<<"${CLEAN_CONF}" || missing+=" PrivateKey"
	grep -Eq '^Endpoint *=' <<<"${CLEAN_CONF}" || missing+=" Endpoint"
	grep -Eq '^Address *=.*:' <<<"${CLEAN_CONF}" || missing+=" IPv6-Address"
	grep -Eq '^AllowedIPs *=.*:' <<<"${CLEAN_CONF}" || missing+=" IPv6-AllowedIPs"
	if [ -n "${missing}" ]; then
		echo -e "${RED}This does not look like an IPv6 WireGuard config. Missing:${missing}${NC}"
		return 1
	fi
	if grep -Eq '^AllowedIPs *=.*[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' <<<"${CLEAN_CONF}"; then
		echo -e "${ORANGE}Removing IPv4 ranges from AllowedIPs: ipv6-auto only carries IPv6.${NC}"
		CLEAN_CONF=$(sed -E '/^AllowedIPs/ s#[0-9.]+/[0-9]+[[:space:]]*,?[[:space:]]*##g; s#,[[:space:]]*$##' <<<"${CLEAN_CONF}")
	fi
	echo -e "${GREEN}Config looks good:${NC} $(grep -E '^Endpoint' <<<"${CLEAN_CONF}")"
}

function installDeps() {
	local need=()
	[ -x "${BREW_PREFIX}/bin/bash" ] || need+=(bash)
	[ -x "${BREW_PREFIX}/bin/wg-quick" ] || need+=(wireguard-tools)
	if [ ${#need[@]} -gt 0 ]; then
		echo "Installing ${need[*]} with Homebrew..."
		if ! sudo -u "${SUDO_USER}" "${BREW}" install "${need[@]}"; then
			echo -e "${RED}Failed to install packages.${NC}"
			echo "Please check your internet connection and try: brew install ${need[*]}"
			exit 1
		fi
	fi
}

function fetchDaemon() {
	# next to this script (git clone), in Homebrew's share dir, or download it
	local self here
	self=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || echo "${BASH_SOURCE[0]}")
	here=$(cd "$(dirname "${self}")" 2>/dev/null && pwd)
	if [ -f "${here}/ipv6-auto" ]; then
		cp "${here}/ipv6-auto" "$1"
	elif [ -f "${here}/../share/ipv6-install/ipv6-auto" ]; then
		cp "${here}/../share/ipv6-install/ipv6-auto" "$1"
	elif ! curl -fsSL "${REPO_RAW}/ipv6-auto" -o "$1"; then
		echo -e "${RED}Failed to download ${REPO_RAW}/ipv6-auto${NC}"
		exit 1
	fi
}

function writePlist() {
	cat >"${PLIST}" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array><string>${BIN}</string><string>daemon</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>10</integer>
  <key>ProcessType</key><string>Background</string>
  <key>AbandonProcessGroup</key><true/>
  <key>StandardErrorPath</key><string>${LOG}</string>
</dict>
</plist>
EOF
	chmod 644 "${PLIST}"
}

function stopService() {
	launchctl bootout "system/${LABEL}" 2>/dev/null
	for _ in $(seq 1 20); do
		launchctl print "system/${LABEL}" >/dev/null 2>&1 || break
		sleep 1
	done
	pkill -f "${BIN} daemon" 2>/dev/null
	sleep 1
}

function startService() {
	if ! launchctl bootstrap system "${PLIST}"; then
		echo -e "${RED}Failed to start the service.${NC} Check ${LOG}"
		exit 1
	fi
}

function writeConfig() {
	install -d -m 700 "${ETC_DIR}"
	(
		umask 077
		echo "${CLEAN_CONF}" >"${CONF}"
	)
	chmod 600 "${CONF}"
}

function installDaemon() {
	local tmp
	tmp=$(mktemp)
	fetchDaemon "${tmp}"
	install -d -m 755 /usr/local/sbin
	sed -e "1s|.*|#!${BREW_PREFIX}/bin/bash|" \
		-e "s|^export PATH=.*|export PATH=${BREW_PREFIX}/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin|" \
		"${tmp}" >"${BIN}"
	chmod 755 "${BIN}"
	rm -f "${tmp}"
}

# Replace the daemon with the current version, keep the config and settings
function updateIPv6Auto() {
	installDeps
	stopService
	installDaemon
	writePlist
	# a new version deserves a fresh try: the fuse blows again by itself if needed
	rm -f "${ETC_DIR}/mirror-disabled"
	startService
	echo -e "${GREEN}ipv6-auto updated to ${VERSION}, service restarted.${NC}"
}

function installIPv6Auto() {
	installQuestions
	installDeps

	installDaemon

	writeConfig
	cat >"${PARAMS}" <<EOF
MIRROR=${MIRROR}
YIELD_TO_VPN=${YIELD_TO_VPN}
EOF
	chmod 600 "${PARAMS}"

	stopService
	writePlist
	startService

	echo ""
	echo "Waiting for the first check..."
	sleep 12
	"${BIN}" selftest
	echo ""
	echo -e "${GREEN}ipv6-auto is installed.${NC} It starts on boot and follows network changes by itself."
	echo "  Status:     sudo ipv6-auto status"
	echo "  Self-test:  sudo ipv6-auto selftest"
	echo "  Log:        tail -f ${LOG}"
	echo "Run this script again to change the config or uninstall."
}

function replaceConfig() {
	echo "Where is the new WireGuard config?"
	pickConfig
	local src=${CONF_SRC}
	readConfig "${src}" || exit 1
	stopService
	"${BIN}" cleanup
	writeConfig
	startService
	echo -e "${GREEN}Config replaced, service restarted.${NC}"
}

function uninstallIPv6Auto() {
	echo ""
	read -rp "Do you really want to remove ipv6-auto? [y/n]: " -n1 REMOVE
	echo ""
	if [[ ${REMOVE} != "y" ]]; then
		echo "Removal aborted!"
		return
	fi
	stopService
	"${BIN}" cleanup 2>/dev/null
	rm -f "${PLIST}" "${BIN}" "${PARAMS}"
	read -rp "Also delete the tunnel config with its private key? [y/n]: " -n1 DELCONF
	echo ""
	if [[ ${DELCONF} == "y" ]]; then
		rm -rf "${ETC_DIR}"
	else
		echo "Config kept in ${CONF}"
	fi
	echo -e "${GREEN}ipv6-auto removed.${NC}"
}

function manageMenu() {
	echo "Welcome to ipv6-install!"
	echo "The git repository is available at: https://github.com/a0s/ipv6-install"
	echo ""
	echo "It looks like ipv6-auto is already installed."
	echo ""
	echo "What do you want to do?"
	echo "   1) Show status"
	echo "   2) Run self-test"
	echo "   3) Replace the tunnel config"
	echo "   4) Update to this version (keeps the config)"
	echo "   5) Reinstall (ask the questions again)"
	echo "   6) Remove ipv6-auto"
	echo "   7) Exit"
	until [[ ${MENU_OPTION} =~ ^[1-7]$ ]]; do
		read -rp "Select an option [1-7]: " MENU_OPTION
	done
	case "${MENU_OPTION}" in
	1) "${BIN}" status ;;
	2) "${BIN}" selftest ;;
	3) replaceConfig ;;
	4) updateIPv6Auto ;;
	5) installIPv6Auto ;;
	6) uninstallIPv6Auto ;;
	7) exit 0 ;;
	esac
}

case "${1:-}" in
--version)
	echo "ipv6-install ${VERSION}"
	exit 0
	;;
--help | -h)
	echo "usage: sudo $0 [--update | --uninstall | --version]"
	echo "Without options: install, or show the management menu if already installed."
	exit 0
	;;
--update)
	initialCheck
	if [[ -e ${PLIST} ]]; then updateIPv6Auto; else echo "ipv6-auto is not installed"; fi
	exit 0
	;;
--uninstall)
	initialCheck
	if [[ -e ${PLIST} ]]; then uninstallIPv6Auto; else echo "ipv6-auto is not installed"; fi
	exit 0
	;;
esac

initialCheck

if [[ -e ${PLIST} ]]; then
	manageMenu
else
	installIPv6Auto
fi
