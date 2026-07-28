#!/usr/bin/env bash
# update-resolve_FEDORA.sh — DaVinci Resolve updater for Fedora Linux
#
# Checks the Blackmagic API, downloads the official Linux ZIP, runs the
# official .run installer, then applies the Fedora library compatibility fix.
#
# Usage:
#   ./update-resolve_FEDORA.sh [options]
#
# Options:
#   --force              Reinstall even when already on the latest version
#   --check-only         Check for an update without downloading/installing
#   --skip-install       Download and extract the .run file without installing
#   --no-backup          Do not back up Resolve data stored below /opt/resolve
#   --no-post-install    Do not disable Resolve's bundled GLib libraries
#   --skip-gpu-check     Do not check/install GPU compute runtime packages
#   --studio             Download DaVinci Resolve Studio instead of Free
#   --reconfigure        Re-enter Blackmagic registration information
#   -h, --help           Show this help
#
# Run this script as your normal user. It invokes sudo only when required.

set -Eeuo pipefail

SCRIPT_VERSION="2026.07.1"
RESOLVE_TESTED="20.x"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/build"
CONFIG_FILE="${SCRIPT_DIR}/.config"
BACKUP_DIR="${BUILD_DIR}/backups"

PRODUCT="davinci-resolve"
PRODUCT_DISPLAY="DaVinci Resolve"

API_BASE="https://www.blackmagicdesign.com/api"
REFER_ID="77ef91f67a9e411bbbe299e595b4cfcc"
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36"
COOKIES="_ga=GA1.2.1849503966.1518103294; _gid=GA1.2.953840595.1518103294"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[0;33m'
BLUE=$'\033[0;34m'
NC=$'\033[0m'

log()  { printf '%s[resolve-update]%s %s\n' "$BLUE" "$NC" "$*" >&2; }
ok()   { printf '%s[✓]%s %s\n' "$GREEN" "$NC" "$*" >&2; }
warn() { printf '%s[!]%s %s\n' "$YELLOW" "$NC" "$*" >&2; }
err()  { printf '%s[✗]%s %s\n' "$RED" "$NC" "$*" >&2; }

FORCE=false
CHECK_ONLY=false
SKIP_INSTALL=false
RECONFIGURE=false
CREATE_BACKUP=true
APPLY_POST_INSTALL=true
CHECK_GPU=true

usage() {
    cat <<EOF
Usage: $0 [options]

  --force              Reinstall even when already on the latest version
  --check-only         Check for an update without downloading/installing
  --skip-install       Download and extract the .run file without installing
  --no-backup          Do not back up Resolve data stored below /opt/resolve
  --no-post-install    Do not disable Resolve's bundled GLib libraries
  --skip-gpu-check     Do not check/install GPU compute runtime packages
  --studio             Download DaVinci Resolve Studio instead of Free
  --reconfigure        Re-enter Blackmagic registration information
  -h, --help           Show this help
EOF
}

for arg in "$@"; do
    case "$arg" in
        --force) FORCE=true ;;
        --check-only) CHECK_ONLY=true ;;
        --skip-install) SKIP_INSTALL=true ;;
        --no-backup) CREATE_BACKUP=false ;;
        --no-post-install) APPLY_POST_INSTALL=false ;;
        --skip-gpu-check) CHECK_GPU=false ;;
        --studio)
            PRODUCT="davinci-resolve-studio"
            PRODUCT_DISPLAY="DaVinci Resolve Studio"
            ;;
        --reconfigure) RECONFIGURE=true ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            err "Unknown argument: $arg"
            usage >&2
            exit 1
            ;;
    esac
done

on_error() {
    local exit_code=$?
    local line_no=${1:-unknown}
    err "Stopped after an error near line ${line_no} (exit ${exit_code})."
    exit "$exit_code"
}
trap 'on_error "$LINENO"' ERR

check_platform() {
    if [[ $EUID -eq 0 ]]; then
        err "Do not run the whole script with sudo."
        err "Run it as your normal user; it will request sudo when needed."
        exit 1
    fi

    if [[ ! -r /etc/os-release ]]; then
        err "Cannot identify this Linux distribution."
        exit 1
    fi

    # /etc/os-release is a system-owned key/value file.
    # shellcheck disable=SC1091
    source /etc/os-release

    local distro_id="${ID:-}"
    local distro_like="${ID_LIKE:-}"
    if [[ "$distro_id" != "fedora" && "$distro_like" != *"fedora"* ]]; then
        err "This script targets Fedora and Fedora-based distributions."
        err "Detected: ${PRETTY_NAME:-unknown distribution}"
        exit 1
    fi

    log "Detected system: ${PRETTY_NAME:-Fedora Linux}"
}

install_script_tools() {
    local -A command_packages=(
        [curl]="curl"
        [jq]="jq"
        [unzip]="unzip"
        [pgrep]="procps-ng"
        [tar]="tar"
    )
    local missing_packages=()
    local command_name

    for command_name in "${!command_packages[@]}"; do
        if ! command -v "$command_name" &>/dev/null; then
            missing_packages+=("${command_packages[$command_name]}")
        fi
    done

    if [[ ${#missing_packages[@]} -gt 0 ]]; then
        log "Installing script tools: ${missing_packages[*]}"
        sudo dnf install -y "${missing_packages[@]}"
    fi

    for command_name in curl jq unzip pgrep tar rpm dnf sudo; do
        if ! command -v "$command_name" &>/dev/null; then
            err "Missing required command: ${command_name}"
            exit 1
        fi
    done
}

prompt_config() {
    printf '\n'
    printf '%s\n' "${BLUE}╔══════════════════════════════════════════════════════╗${NC}"
    printf '%s\n' "${BLUE}║  First-time setup: Blackmagic registration          ║${NC}"
    printf '%s\n' "${BLUE}╠══════════════════════════════════════════════════════╣${NC}"
    printf '%s\n' "${BLUE}║  The download API requires registration details.    ║${NC}"
    printf '%s\n' "${BLUE}║  They are stored locally with mode 600 and sent      ║${NC}"
    printf '%s\n' "${BLUE}║  only to Blackmagic when requesting a download.      ║${NC}"
    printf '%s\n' "${BLUE}╚══════════════════════════════════════════════════════╝${NC}"
    printf '\n'

    local reg_firstname reg_lastname reg_email reg_phone
    local reg_country reg_state reg_city reg_street

    read -r -p "First name: " reg_firstname
    read -r -p "Last name: " reg_lastname
    read -r -p "Email: " reg_email
    read -r -p "Phone: " reg_phone
    read -r -p "Country code (for example fr, us, uk): " reg_country
    read -r -p "State/Province: " reg_state
    read -r -p "City: " reg_city
    read -r -p "Street address: " reg_street

    if [[ -z "$reg_firstname" || -z "$reg_lastname" || -z "$reg_email" || -z "$reg_street" ]]; then
        err "First name, last name, email, and street address are required."
        exit 1
    fi

    {
        printf '# update-resolve configuration (auto-generated)\n'
        printf '# Re-run with --reconfigure to change these values\n'
        printf 'firstname=%s\n' "$reg_firstname"
        printf 'lastname=%s\n' "$reg_lastname"
        printf 'email=%s\n' "$reg_email"
        printf 'phone=%s\n' "$reg_phone"
        printf 'country=%s\n' "$reg_country"
        printf 'state=%s\n' "$reg_state"
        printf 'city=%s\n' "$reg_city"
        printf 'street=%s\n' "$reg_street"
    } > "$CONFIG_FILE"

    chmod 600 "$CONFIG_FILE"
    ok "Registration configuration saved to ${CONFIG_FILE}"
}

config_value() {
    local key="$1"
    awk -F= -v wanted="$key" '$1 == wanted { sub(/^[^=]*=/, ""); print; exit }' "$CONFIG_FILE"
}

load_config() {
    if [[ "$RECONFIGURE" == "true" || ! -f "$CONFIG_FILE" ]]; then
        prompt_config
    fi

    chmod 600 "$CONFIG_FILE"

    local cfg_firstname cfg_lastname cfg_email cfg_phone
    local cfg_country cfg_state cfg_city cfg_street
    cfg_firstname="$(config_value firstname)"
    cfg_lastname="$(config_value lastname)"
    cfg_email="$(config_value email)"
    cfg_phone="$(config_value phone)"
    cfg_country="$(config_value country)"
    cfg_state="$(config_value state)"
    cfg_city="$(config_value city)"
    cfg_street="$(config_value street)"

    if [[ -z "$cfg_firstname" || -z "$cfg_lastname" || -z "$cfg_email" || -z "$cfg_street" ]]; then
        err "The configuration is incomplete. Run again with --reconfigure."
        exit 1
    fi

    REG_DATA="$(jq -n \
        --arg fn "$cfg_firstname" \
        --arg ln "$cfg_lastname" \
        --arg em "$cfg_email" \
        --arg ph "$cfg_phone" \
        --arg co "$cfg_country" \
        --arg st "$cfg_state" \
        --arg ci "$cfg_city" \
        --arg sr "$cfg_street" \
        --arg product "$PRODUCT_DISPLAY" \
        '{
            firstname: $fn,
            lastname: $ln,
            email: $em,
            phone: $ph,
            country: $co,
            state: $st,
            city: $ci,
            street: $sr,
            product: $product,
            hasAgreedToTerms: true
        }')"
}

# Dependencies used by davinci-helper on recent Fedora versions. Resolve
# bundles most of its application libraries, so the large Arch PKGBUILD list
# should not be copied verbatim to Fedora.
RESOLVE_DEPS=(
    libxcrypt-compat
    libcurl
    libcurl-devel
    mesa-libGLU
    fuse-libs
    zlib-ng-compat
)

install_missing_packages() {
    local description="$1"
    shift
    local packages=("$@")
    local missing=()
    local package

    for package in "${packages[@]}"; do
        if ! rpm -q "$package" &>/dev/null; then
            missing+=("$package")
        fi
    done

    if [[ ${#missing[@]} -eq 0 ]]; then
        ok "${description}: already installed"
        return 0
    fi

    log "Installing ${description}: ${missing[*]}"
    sudo dnf install -y "${missing[@]}"
    ok "${description}: installed"
}

install_runtime_dependencies() {
    log "Checking Fedora runtime dependencies..."
    install_missing_packages "Resolve runtime dependencies" "${RESOLVE_DEPS[@]}"
}

install_gpu_dependencies() {
    if [[ "$CHECK_GPU" != "true" ]]; then
        warn "GPU runtime check skipped."
        return 0
    fi

    if ! command -v lspci &>/dev/null; then
        warn "lspci is unavailable; GPU runtime check skipped."
        warn "Install pciutils if you want automatic GPU detection."
        return 0
    fi

    local gpu_info
    gpu_info="$(lspci | grep -Ei 'vga|3d|display' || true)"

    if grep -qiE 'AMD|ATI' <<< "$gpu_info"; then
        log "AMD GPU detected; checking the ROCm runtime..."

        if rpm -q opencl-rocr-amdgpu-pro &>/dev/null; then
            err "The conflicting package opencl-rocr-amdgpu-pro is installed."
            err "This updater will not remove GPU drivers automatically."
            err "Resolve the ROCm/AMDGPU-PRO conflict manually, or use --skip-gpu-check."
            exit 1
        fi

        install_missing_packages \
            "AMD ROCm compute runtime" \
            rocm-opencl rocm-smi rocm-core rocm-hip rocm-clinfo

        local user_groups
        user_groups="$(id -nG)"
        if [[ " ${user_groups} " != *" render "* || " ${user_groups} " != *" video "* ]]; then
            warn "Your user is not in both the render and video groups."
            warn "If Resolve cannot access the GPU, run:"
            warn "  sudo usermod -aG render,video $(id -un)"
            warn "Then log out and back in."
        fi

    elif grep -qi 'NVIDIA' <<< "$gpu_info"; then
        if rpm -q akmod-nvidia xorg-x11-drv-nvidia-cuda &>/dev/null; then
            ok "NVIDIA driver and CUDA runtime: already installed"
        else
            warn "NVIDIA GPU detected, but the RPM Fusion driver/CUDA packages were not both found."
            warn "Expected packages: akmod-nvidia xorg-x11-drv-nvidia-cuda"
            warn "They are not installed automatically because that requires RPM Fusion."
        fi

    elif grep -qi 'Intel' <<< "$gpu_info"; then
        install_missing_packages \
            "Intel compute runtime" \
            intel-compute-runtime intel-opencl
    else
        warn "No supported AMD, NVIDIA, or Intel GPU was detected automatically."
    fi
}

get_installed_version() {
    if [[ ! -d /opt/resolve ]]; then
        printf 'none\n'
        return 0
    fi

    local welcome_file="/opt/resolve/docs/Welcome.txt"
    local version=""

    if [[ -r "$welcome_file" ]]; then
        version="$(grep -oP 'DaVinci Resolve(?: Studio)?\s+\K[0-9]+(?:\.[0-9]+){1,2}' \
            "$welcome_file" | head -n 1 || true)"
    fi

    if [[ -n "$version" ]]; then
        printf '%s\n' "$version"
    else
        printf 'unknown\n'
    fi
}

get_latest_version() {
    local response
    response="$(curl --fail --silent --show-error \
        --retry 3 --retry-delay 2 --retry-all-errors \
        "${API_BASE}/support/latest-stable-version/${PRODUCT}/linux")"

    if ! jq -e '
        .linux
        and (.linux.major != null)
        and (.linux.minor != null)
        and (.linux.releaseNum != null)
        and (.linux.downloadId != null)
    ' >/dev/null <<< "$response"; then
        err "Blackmagic returned an unexpected latest-version response."
        return 1
    fi

    local major minor release download_id version
    major="$(jq -er '.linux.major | tostring' <<< "$response")"
    minor="$(jq -er '.linux.minor | tostring' <<< "$response")"
    release="$(jq -er '.linux.releaseNum | tostring' <<< "$response")"
    download_id="$(jq -er '.linux.downloadId | tostring' <<< "$response")"

    if [[ "$release" == "0" ]]; then
        version="${major}.${minor}"
    else
        version="${major}.${minor}.${release}"
    fi

    if [[ ! "$version" =~ ^[0-9]+(\.[0-9]+){1,2}$ || -z "$download_id" ]]; then
        err "Invalid version metadata received from Blackmagic."
        return 1
    fi

    printf '%s|%s\n' "$version" "$download_id"
}

archive_basename() {
    local version="$1"
    if [[ "$PRODUCT" == "davinci-resolve-studio" ]]; then
        printf 'DaVinci_Resolve_Studio_%s_Linux\n' "$version"
    else
        printf 'DaVinci_Resolve_%s_Linux\n' "$version"
    fi
}

download_resolve() {
    local download_id="$1"
    local version="$2"
    local base_name zip_name zip_path partial_path
    base_name="$(archive_basename "$version")"
    zip_name="${base_name}.zip"
    zip_path="${BUILD_DIR}/${zip_name}"
    partial_path="${zip_path}.part"

    if [[ -f "$zip_path" && "$FORCE" != "true" ]]; then
        if unzip -tq "$zip_path" &>/dev/null; then
            ok "Validated existing download: ${zip_name}"
            printf '%s\n' "$zip_path"
            return 0
        fi

        local invalid_path="${zip_path}.invalid.$(date +%Y%m%d_%H%M%S)"
        warn "Existing ZIP is invalid; preserving it as $(basename "$invalid_path")."
        mv -- "$zip_path" "$invalid_path"
    fi

    log "Requesting a download URL from Blackmagic..."

    local registration_response download_url
    registration_response="$(curl --fail --silent --show-error \
        --retry 3 --retry-delay 2 --retry-all-errors \
        -X POST "${API_BASE}/register/us/download/${download_id}" \
        -H "Host: www.blackmagicdesign.com" \
        -H "Accept: application/json, text/plain, */*" \
        -H "Origin: https://www.blackmagicdesign.com" \
        -H "User-Agent: ${UA}" \
        -H "Content-Type: application/json;charset=UTF-8" \
        -H "Referer: https://www.blackmagicdesign.com/support/download/${REFER_ID}/Linux" \
        -b "${COOKIES}" \
        --data-binary "${REG_DATA}")"

    if download_url="$(jq -er '
        if type == "string" then .
        elif type == "object" then (.downloadUrl // .url // empty)
        else empty
        end
    ' <<< "$registration_response" 2>/dev/null)"; then
        :
    elif [[ "$registration_response" == https://* ]]; then
        download_url="$registration_response"
    else
        err "Blackmagic did not return a valid download URL."
        return 1
    fi

    if [[ "$download_url" != https://* ]]; then
        err "Refusing a non-HTTPS download URL."
        return 1
    fi

    log "Downloading ${zip_name} (several GB)..."
    curl --fail --location --progress-bar \
        --retry 3 --retry-delay 3 --retry-all-errors \
        --continue-at - \
        -H "User-Agent: ${UA}" \
        --output "$partial_path" \
        "$download_url"

    log "Checking ZIP integrity..."
    if ! unzip -tq "$partial_path" &>/dev/null; then
        local invalid_partial="${partial_path}.invalid.$(date +%Y%m%d_%H%M%S)"
        mv -- "$partial_path" "$invalid_partial"
        err "The downloaded file is not a valid ZIP."
        err "It was preserved as: ${invalid_partial}"
        return 1
    fi

    mv -- "$partial_path" "$zip_path"
    local size
    size="$(du -h "$zip_path" | cut -f1)"
    ok "Downloaded and validated: ${zip_name} (${size})"
    printf '%s\n' "$zip_path"
}

ensure_resolve_is_closed() {
    if pgrep -f '/opt/resolve/bin/resolve' &>/dev/null; then
        err "DaVinci Resolve is currently running."
        err "Close it completely before starting the update."
        exit 1
    fi
}

backup_resolve_data() {
    if [[ "$CREATE_BACKUP" != "true" || ! -d /opt/resolve ]]; then
        return 0
    fi

    local candidates=(
        "configs"
        "LUT"
        ".LUT"
        ".license"
        "Resolve Disk Database"
        "DolbyVision"
        "Fairlight"
    )
    local existing=()
    local item

    for item in "${candidates[@]}"; do
        if sudo test -e "/opt/resolve/${item}"; then
            existing+=("$item")
        fi
    done

    if [[ ${#existing[@]} -eq 0 ]]; then
        warn "No persistent Resolve data was found below /opt/resolve to back up."
        return 0
    fi

    mkdir -p "$BACKUP_DIR"
    local backup_path="${BACKUP_DIR}/resolve-data-$(date +%Y%m%d_%H%M%S).tar.gz"
    log "Backing up Resolve configuration/LUT/licence data..."

    sudo tar -C /opt/resolve -czf - -- "${existing[@]}" > "$backup_path"
    chmod 600 "$backup_path"
    ok "Safety backup created: ${backup_path}"
}

extract_installer() {
    local zip_path="$1"
    local version="$2"
    local extract_dir
    extract_dir="$(mktemp -d "${BUILD_DIR}/installer-${version}.XXXXXX")"

    log "Extracting the official installer..."
    unzip -q "$zip_path" -d "$extract_dir"

    local run_files=()
    while IFS= read -r -d '' run_file; do
        run_files+=("$run_file")
    done < <(find "$extract_dir" -maxdepth 2 -type f \
        -name 'DaVinci_Resolve*_Linux.run' -print0)

    if [[ ${#run_files[@]} -ne 1 ]]; then
        err "Expected exactly one DaVinci Resolve .run installer in the ZIP."
        err "Found: ${#run_files[@]}"
        return 1
    fi

    chmod u+x "${run_files[0]}"
    printf '%s\n' "${run_files[0]}"
}

apply_fedora_post_install_fix() {
    if [[ "$APPLY_POST_INSTALL" != "true" ]]; then
        warn "Fedora post-install library fix skipped."
        return 0
    fi

    local resolve_libs="/opt/resolve/libs"
    local disabled_dir="${resolve_libs}/disabled_libraries"

    if [[ ! -d "$resolve_libs" ]]; then
        err "Resolve library directory not found after installation: ${resolve_libs}"
        return 1
    fi

    local bundled_libs=()
    local pattern file
    for pattern in 'libglib*' 'libgio*' 'libgmodule*'; do
        for file in "${resolve_libs}"/${pattern}; do
            [[ -e "$file" ]] || continue
            bundled_libs+=("$file")
        done
    done

    if [[ ${#bundled_libs[@]} -eq 0 ]]; then
        ok "Fedora GLib compatibility fix: already applied"
        return 0
    fi

    log "Applying Fedora GLib compatibility fix..."
    sudo mkdir -p "$disabled_dir"
    sudo mv -f -- "${bundled_libs[@]}" "$disabled_dir/"
    ok "Bundled libglib/libgio/libgmodule libraries disabled"
}

install_resolve() {
    local run_file="$1"
    local expected_version="$2"

    if [[ "$SKIP_INSTALL" == "true" ]]; then
        ok "Installer extracted; installation skipped."
        log "Installer ready at: ${run_file}"
        return 0
    fi

    ensure_resolve_is_closed
    backup_resolve_data

    log "Running the official Blackmagic installer..."
    sudo env SKIP_PACKAGE_CHECK=1 "$run_file" -i

    if [[ ! -x /opt/resolve/bin/resolve ]]; then
        err "The installer finished, but /opt/resolve/bin/resolve is missing."
        return 1
    fi

    apply_fedora_post_install_fix

    local installed_after
    installed_after="$(get_installed_version)"
    if [[ "$installed_after" == "$expected_version" ]]; then
        ok "Installed version verified: ${installed_after}"
    elif [[ "$installed_after" == "unknown" ]]; then
        warn "Resolve is installed, but its exact version could not be read."
    else
        warn "Expected ${expected_version}, but detected ${installed_after}."
    fi
}

cleanup_extracted_installer() {
    local run_file="$1"
    local version="$2"
    local candidate extract_dir=""
    candidate="$(dirname "$run_file")"

    while [[ "$candidate" != "$BUILD_DIR" && "$candidate" != "/" ]]; do
        if [[ "$(dirname "$candidate")" == "$BUILD_DIR" \
            && "$(basename "$candidate")" == "installer-${version}."* ]]; then
            extract_dir="$candidate"
            break
        fi
        candidate="$(dirname "$candidate")"
    done

    # Delete only the mktemp directory created by extract_installer().
    if [[ -n "$extract_dir" && -d "$extract_dir" ]]; then
        find "$extract_dir" -mindepth 1 -delete
        rmdir "$extract_dir"
        ok "Temporary extracted installer removed"
    else
        warn "Temporary installer directory was not recognized; leaving it untouched."
    fi
}

main() {
    printf '\n'
    printf '%s\n' "${BLUE}╔════════════════════════════════════════════╗${NC}"
    printf '%s\n' "${BLUE}║  DaVinci Resolve Updater for Fedora Linux  ║${NC}"
    printf '%s\n' "${BLUE}╚════════════════════════════════════════════╝${NC}"
    printf '\n'

    log "Script version: ${SCRIPT_VERSION} (tested with Resolve ${RESOLVE_TESTED})"
    log "Edition: ${PRODUCT_DISPLAY}"

    check_platform
    install_script_tools

    local installed_version
    installed_version="$(get_installed_version)"
    log "Installed version: ${installed_version}"

    log "Checking Blackmagic for the latest stable version..."
    local latest_info latest_version download_id
    latest_info="$(get_latest_version)"
    latest_version="${latest_info%%|*}"
    download_id="${latest_info#*|}"
    ok "Latest stable version: ${latest_version}"

    if [[ "$installed_version" == "$latest_version" && "$FORCE" != "true" ]]; then
        ok "Already on the latest version (${installed_version})."
        log "Use --force to reinstall it."
        exit 0
    fi

    if [[ "$installed_version" != "$latest_version" ]]; then
        log "Update available: ${installed_version} → ${latest_version}"
    fi

    if [[ "$CHECK_ONLY" == "true" ]]; then
        ok "Check-only mode complete."
        exit 0
    fi

    load_config
    install_runtime_dependencies
    install_gpu_dependencies
    mkdir -p "$BUILD_DIR"

    local zip_path run_file
    zip_path="$(download_resolve "$download_id" "$latest_version")"
    run_file="$(extract_installer "$zip_path" "$latest_version")"
    install_resolve "$run_file" "$latest_version"
    if [[ "$SKIP_INSTALL" != "true" ]]; then
        cleanup_extracted_installer "$run_file" "$latest_version"
    fi

    printf '\n'
    if [[ "$SKIP_INSTALL" == "true" ]]; then
        ok "Download and extraction completed successfully."
    else
        ok "${PRODUCT_DISPLAY} ${latest_version} installed successfully."
        log "Launch it from the application menu or with /opt/resolve/bin/resolve"
    fi
}

main "$@"
