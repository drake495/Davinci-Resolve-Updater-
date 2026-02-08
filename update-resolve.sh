#!/bin/bash
# update-resolve.sh — Automated DaVinci Resolve updater for Arch Linux
# Checks for updates, downloads via Blackmagic API, builds via makepkg
#
# Usage: ./update-resolve.sh [--force] [--check-only] [--skip-install] [--reconfigure]
#
# Dependencies: curl, jq, makepkg, pacman, git
#
# On first run, you'll be prompted for registration info (required by
# Blackmagic's download API). Your info is saved locally in a config
# file and reused on subsequent runs.

set -euo pipefail

# Configuration
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
CONFIG_FILE="${SCRIPT_DIR}/.config"
PRODUCT="davinci-resolve"  # Change to "davinci-resolve-studio" for Studio edition

# Blackmagic API endpoints
API_BASE="https://www.blackmagicdesign.com/api"

# This is a generic product/page identifier for the DaVinci Resolve download page.
# It is NOT user-specific. Source: Blackmagic's website download page URL structure.
# Also used in other open-source downloaders (e.g., Kimiblock/resolve-download).
REFER_ID="77ef91f67a9e411bbbe299e595b4cfcc"

# Shared curl options
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36"

# Static Google Analytics cookies to make requests look like normal browser traffic.
# These are NOT tied to any real user session — they're generic values used to avoid
# potential bot detection by Blackmagic's API.
COOKIES="_ga=GA1.2.1849503966.1518103294; _gid=GA1.2.953840595.1518103294"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[resolve-update]${NC} $*"; }
ok()   { echo -e "${GREEN}[✓]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }

# Parse arguments
FORCE=false
CHECK_ONLY=false
SKIP_INSTALL=false
RECONFIGURE=false
for arg in "$@"; do
    case $arg in
        --force) FORCE=true ;;
        --check-only) CHECK_ONLY=true ;;
        --skip-install) SKIP_INSTALL=true ;;
        --reconfigure) RECONFIGURE=true ;;
        -h|--help)
            echo "Usage: $0 [--force] [--check-only] [--skip-install] [--reconfigure]"
            echo "  --force        Update even if already on latest version"
            echo "  --check-only   Just check for updates, don't download or install"
            echo "  --skip-install Download and build but don't install"
            echo "  --reconfigure  Re-enter registration info"
            exit 0
            ;;
        *) err "Unknown argument: $arg"; exit 1 ;;
    esac
done

# --- Configuration Management ---

prompt_config() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  First-time Setup: Registration Info                ║${NC}"
    echo -e "${BLUE}╠══════════════════════════════════════════════════════╣${NC}"
    echo -e "${BLUE}║  Blackmagic requires registration to download.      ║${NC}"
    echo -e "${BLUE}║  This is the same info you'd enter on their site.   ║${NC}"
    echo -e "${BLUE}║  It's saved locally and never shared elsewhere.     ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
    echo ""

    read -rp "First name: " REG_FIRSTNAME
    read -rp "Last name: " REG_LASTNAME
    read -rp "Email: " REG_EMAIL
    read -rp "Phone (digits only): " REG_PHONE
    read -rp "Country code (e.g., us, uk, de): " REG_COUNTRY
    read -rp "State/Province: " REG_STATE
    read -rp "City: " REG_CITY
    read -rp "Street address: " REG_STREET

    # Validate required fields
    if [[ -z "$REG_FIRSTNAME" || -z "$REG_LASTNAME" || -z "$REG_EMAIL" || -z "$REG_STREET" ]]; then
        err "First name, last name, email, and street are required."
        exit 1
    fi

    # Save config (values are stored verbatim, not as shell code)
    {
        echo "# update-resolve configuration (auto-generated)"
        echo "# Re-run with --reconfigure to change these values"
        printf 'firstname=%s\n' "$REG_FIRSTNAME"
        printf 'lastname=%s\n' "$REG_LASTNAME"
        printf 'email=%s\n' "$REG_EMAIL"
        printf 'phone=%s\n' "$REG_PHONE"
        printf 'country=%s\n' "$REG_COUNTRY"
        printf 'state=%s\n' "$REG_STATE"
        printf 'city=%s\n' "$REG_CITY"
        printf 'street=%s\n' "$REG_STREET"
    } > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    ok "Configuration saved to ${CONFIG_FILE}"
    echo ""
}

load_config() {
    if [[ "$RECONFIGURE" == "true" || ! -f "$CONFIG_FILE" ]]; then
        prompt_config
    fi

    # Read config safely — no shell evaluation, just plain key=value parsing
    _cfg() { grep "^$1=" "$CONFIG_FILE" | cut -d= -f2-; }
    local cfg_firstname cfg_lastname cfg_email cfg_phone cfg_country cfg_state cfg_city cfg_street
    cfg_firstname=$(_cfg firstname)
    cfg_lastname=$(_cfg lastname)
    cfg_email=$(_cfg email)
    cfg_phone=$(_cfg phone)
    cfg_country=$(_cfg country)
    cfg_state=$(_cfg state)
    cfg_city=$(_cfg city)
    cfg_street=$(_cfg street)

    # Build the JSON registration payload (jq handles escaping)
    REG_DATA=$(jq -n \
        --arg fn "$cfg_firstname" \
        --arg ln "$cfg_lastname" \
        --arg em "$cfg_email" \
        --arg ph "$cfg_phone" \
        --arg co "$cfg_country" \
        --arg st "$cfg_state" \
        --arg ci "$cfg_city" \
        --arg sr "$cfg_street" \
        '{firstname:$fn, lastname:$ln, email:$em, phone:$ph, country:$co, state:$st, city:$ci, street:$sr, product:"DaVinci Resolve"}')
}

# --- Core Functions ---

# Step 1: Get installed version
get_installed_version() {
    pacman -Q "${PRODUCT}" 2>/dev/null | awk '{print $2}' | cut -d- -f1 || echo "none"
}

# Step 2: Get latest version from Blackmagic API
get_latest_version() {
    local response
    response=$(curl -s "${API_BASE}/support/latest-stable-version/${PRODUCT}/linux")

    if [[ -z "$response" || "$response" == *"error"* ]]; then
        err "Failed to query Blackmagic API for latest version"
        return 1
    fi

    local major minor release download_id
    major=$(echo "$response" | jq -r '.linux.major')
    minor=$(echo "$response" | jq -r '.linux.minor')
    release=$(echo "$response" | jq -r '.linux.releaseNum')
    download_id=$(echo "$response" | jq -r '.linux.downloadId')

    if [[ "$release" == "0" ]]; then
        echo "${major}.${minor}|${download_id}"
    else
        echo "${major}.${minor}.${release}|${download_id}"
    fi
}

# Step 3: Download the zip
download_resolve() {
    local download_id="$1"
    local version="$2"
    local zip_name="DaVinci_Resolve_${version}_Linux.zip"
    local zip_path="${BUILD_DIR}/${zip_name}"

    if [[ -f "$zip_path" && "$FORCE" != "true" ]]; then
        ok "Zip already downloaded: ${zip_name}"
        return 0
    fi

    log "Requesting download URL from Blackmagic..."
    local download_url
    download_url=$(curl -s -X POST "${API_BASE}/register/us/download/${download_id}" \
        -H "Host: www.blackmagicdesign.com" \
        -H "Accept: application/json, text/plain, */*" \
        -H "Origin: https://www.blackmagicdesign.com" \
        -H "User-Agent: ${UA}" \
        -H "Content-Type: application/json;charset=UTF-8" \
        -H "Referer: https://www.blackmagicdesign.com/support/download/${REFER_ID}/Linux" \
        -b "${COOKIES}" \
        -d "${REG_DATA}")

    if [[ -z "$download_url" || "$download_url" == *"Error"* || "$download_url" == *"Bad Request"* ]]; then
        err "Failed to get download URL: ${download_url}"
        return 1
    fi

    log "Downloading ${zip_name} (~3GB)..."

    curl -L --progress-bar \
        -H "User-Agent: ${UA}" \
        -o "$zip_path" \
        "$download_url"

    if [[ -f "$zip_path" ]]; then
        local size
        size=$(du -h "$zip_path" | cut -f1)
        ok "Downloaded: ${zip_name} (${size})"
    else
        err "Download failed"
        return 1
    fi
}

# Step 4: Fetch and update PKGBUILD
setup_pkgbuild() {
    local version="$1"

    log "Fetching latest PKGBUILD from AUR..."
    pushd "$BUILD_DIR" > /dev/null

    # Clean previous build artifacts but keep downloaded zips
    find . -maxdepth 1 ! -name "*.zip" ! -name "." -exec rm -rf {} + 2>/dev/null || true

    # Fetch PKGBUILD from AUR
    git clone --depth 1 "https://aur.archlinux.org/${PRODUCT}.git" _aur_pkg 2>/dev/null
    cp _aur_pkg/* . 2>/dev/null || true
    rm -rf _aur_pkg

    # Verify PKGBUILD exists
    if [[ ! -f "PKGBUILD" ]]; then
        err "Failed to fetch PKGBUILD from AUR"
        popd > /dev/null
        return 1
    fi

    # Check if AUR PKGBUILD version matches what we're building
    local aur_version
    aur_version=$(grep '^pkgver=' PKGBUILD | cut -d= -f2)
    if [[ "$aur_version" != "$version" ]]; then
        warn "AUR PKGBUILD is for ${aur_version}, but latest is ${version}"
        warn "Updating pkgver in PKGBUILD to ${version}"
        sed -i "s/^pkgver=.*/pkgver=${version}/" PKGBUILD
        sed -i "s/^pkgrel=.*/pkgrel=1/" PKGBUILD
    fi

    # Verify the zip file is in the build directory
    local zip_name="DaVinci_Resolve_${version}_Linux.zip"
    if [[ ! -f "$zip_name" ]]; then
        err "Zip file not found: ${BUILD_DIR}/${zip_name}"
        popd > /dev/null
        return 1
    fi

    # Update sha256sums
    log "Generating sha256sums..."
    local new_hash
    new_hash=$(sha256sum "$zip_name" | awk '{print $1}')
    # Use updpkgsums if available, otherwise manual update
    if command -v updpkgsums &>/dev/null; then
        updpkgsums 2>/dev/null
        ok "Updated sha256sums via updpkgsums"
    else
        # Manual update: replace the first hash in sha256sums array
        local old_hash
        old_hash=$(grep -A1 "^sha256sums=" PKGBUILD | tail -1 | tr -d "' " | head -c 64)
        if [[ -n "$old_hash" && ${#old_hash} -eq 64 ]]; then
            sed -i "s/${old_hash}/${new_hash}/" PKGBUILD
            ok "Updated zip sha256sum: ${new_hash:0:16}..."
        else
            warn "Could not auto-update sha256sum. You may need to run 'updpkgsums' manually."
        fi
    fi

    popd > /dev/null
}

# Step 5: Build and install
build_and_install() {
    log "Building package with makepkg (this takes a while)..."
    pushd "$BUILD_DIR" > /dev/null

    if [[ "$SKIP_INSTALL" == "true" ]]; then
        yes "" | makepkg -sf --noconfirm
        ok "Package built (not installed due to --skip-install)"
    else
        yes "" | makepkg -sric --noconfirm
        ok "Package built and installed!"
    fi

    popd > /dev/null
}

# --- Main ---
main() {
    echo ""
    echo -e "${BLUE}╔══════════════════════════════════════════╗${NC}"
    echo -e "${BLUE}║  DaVinci Resolve Updater for Arch Linux  ║${NC}"
    echo -e "${BLUE}╚══════════════════════════════════════════╝${NC}"
    echo ""

    # Check dependencies
    for cmd in curl jq makepkg pacman git; do
        if ! command -v "$cmd" &>/dev/null; then
            err "Missing dependency: $cmd"
            exit 1
        fi
    done

    # Load or create configuration
    load_config

    # Get versions
    local installed_version
    installed_version=$(get_installed_version)
    log "Installed version: ${installed_version}"

    log "Checking Blackmagic API for latest version..."
    local latest_info latest_version download_id
    latest_info=$(get_latest_version)
    latest_version=$(echo "$latest_info" | cut -d'|' -f1)
    download_id=$(echo "$latest_info" | cut -d'|' -f2)

    ok "Latest version: ${latest_version}"

    # Compare versions
    if [[ "$installed_version" == "$latest_version" && "$FORCE" != "true" ]]; then
        ok "Already on latest version (${installed_version}). Nothing to do."
        if [[ "$CHECK_ONLY" == "true" ]]; then
            exit 0
        fi
        echo ""
        echo "Use --force to reinstall anyway."
        exit 0
    fi

    if [[ "$installed_version" != "$latest_version" ]]; then
        log "Update available: ${installed_version} → ${latest_version}"
    fi

    if [[ "$CHECK_ONLY" == "true" ]]; then
        warn "Check-only mode. Exiting."
        exit 0
    fi

    # Create build directory
    mkdir -p "$BUILD_DIR"

    # Download
    download_resolve "$download_id" "$latest_version"

    # Setup PKGBUILD
    setup_pkgbuild "$latest_version"

    # Build and install
    build_and_install

    echo ""
    ok "DaVinci Resolve ${latest_version} installed successfully!"
    log "Run 'davinci-resolve' to launch."
}

main "$@"
