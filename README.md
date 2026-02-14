# update-resolve

Automated DaVinci Resolve updater for Arch Linux.

Checks for new versions via Blackmagic's API, downloads the installer, fetches the latest PKGBUILD from the AUR, updates version numbers and checksums, and builds/installs the package — all in one command.

[![Watch the video](https://img.youtube.com/vi/Tm3iNIgTRXw/maxresdefault.jpg)](https://www.youtube.com/watch?v=Tm3iNIgTRXw)


## What it automates

1. Queries Blackmagic's API for the latest stable Linux version
2. Compares against your currently installed version
3. Installs all runtime dependencies (official repos + AUR)
4. Downloads the ~3GB zip (bypassing the manual web registration form)
5. Fetches the latest `davinci-resolve` PKGBUILD from the AUR
6. Patches `pkgver` if the AUR is behind the latest release
7. Regenerates SHA256 checksums
8. Builds and installs via `makepkg -sric` (stays tracked in pacman/yay)

## Dependencies

- `curl`
- `jq`
- `git`
- `makepkg` / `pacman` (included with Arch)
- `yay` or `paru` (AUR helper — needed for AUR-only runtime deps)
- `updpkgsums` (optional, from `pacman-contrib` — falls back to manual hash update)

If you don't have an AUR helper installed, the script will tell you how to install `yay`.
If a dependency install fails, the script will exit, and manual intervention to get that dependency package installed will be required. Re-run the script after you have the problematic dependency installed.

## Runtime dependencies

The script automatically installs these before building. Packages in official repos are installed via `pacman`; AUR-only packages are installed via your AUR helper. When a package has multiple providers, the first option is selected automatically.

| Package | Source |
|---------|--------|
| `glu` | official |
| `gtk2` | official |
| `libpng12` | AUR |
| `fuse2` | official |
| `opencl-driver` | official (multiple providers) |
| `qt5-x11extras` | official |
| `qt5-svg` | official |
| `qt5-webengine` | AUR |
| `qt5-websockets` | official |
| `qt5-quickcontrols2` | official |
| `qt5-multimedia` | official |
| `libxcrypt-compat` | AUR |
| `xmlsec` | official |
| `java-runtime` | official (multiple providers) |
| `ffmpeg4.4` | AUR |
| `gst-plugins-bad-libs` | official |
| `python-numpy` | official |
| `tbb` | official |
| `apr-util` | official |
| `luajit` | official |
| `libc++` | AUR |
| `libc++abi` | AUR |

## Installation

```bash
# Clone the repo
git clone https://github.com/drake495/Davinci-Resolve-Updater.git
cd update-resolve

# Make executable
chmod +x update-resolve.sh

# Optional: symlink to PATH
ln -s "$(pwd)/update-resolve.sh" ~/.local/bin/update-resolve
```

## Usage

```bash
# Standard update (checks version, downloads, builds, installs)
./update-resolve.sh

# Just check if an update is available
./update-resolve.sh --check-only

# Force reinstall even if already on latest
./update-resolve.sh --force

# Download and build but don't install
./update-resolve.sh --skip-install

# Re-enter your registration info
./update-resolve.sh --reconfigure
```

On first run, you'll be prompted for registration info (name, email, etc.). This is the same info Blackmagic requires on their download page. It's saved locally in a `.config` file next to the script and reused on subsequent runs.

## DaVinci Resolve Studio

To use this for the Studio edition, change the `PRODUCT` variable near the top of the script:

```bash
PRODUCT="davinci-resolve-studio"
```

## How it works

Blackmagic requires a registration POST to their API before providing a download URL. This script automates that handshake using the same API endpoints their website uses. The registration data you provide is sent directly to Blackmagic — it's not stored or sent anywhere else.

## License

MIT
