#!/bin/bash
# TDX Host Setup Script
# Installs and manages TDX tools and GitHub runner

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Managed dependencies directory
DEPS_DIR="${DEPS_DIR:-$PROJECT_ROOT/deps}"
TDX_DIR="$DEPS_DIR/tdx"
RUNNER_DIR="$DEPS_DIR/actions-runner"

# Versions
TDX_REPO="https://github.com/canonical/tdx.git"
TDX_BRANCH="${TDX_BRANCH:-main}"
RUNNER_VERSION="${RUNNER_VERSION:-2.321.0}"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

show_usage() {
    cat << EOF
Usage: $0 [OPTIONS] [COMMAND]

Setup and manage TDX GitHub Runner dependencies.

Commands:
    install         Install/update all dependencies (default)
    update          Update TDX tools and runner to latest
    verify          Verify TDX is working on this host
    status          Show status of all components

Options:
    --tdx-branch BRANCH    TDX repo branch (default: main)
    --runner-version VER   GitHub runner version (default: $RUNNER_VERSION)
    --deps-dir DIR         Dependencies directory (default: ./deps)
    -h, --help             Show this help message

Examples:
    $0                      # Install everything
    $0 install              # Same as above
    $0 update               # Update to latest versions
    $0 verify               # Check TDX is working
EOF
}

check_system_deps() {
    log_info "Checking system dependencies..."

    local missing=()

    # Required packages
    command -v git &>/dev/null || missing+=("git")
    command -v curl &>/dev/null || missing+=("curl")
    command -v jq &>/dev/null || missing+=("jq")
    command -v qemu-img &>/dev/null || missing+=("qemu-utils")
    command -v virt-customize &>/dev/null || missing+=("libguestfs-tools")
    command -v virsh &>/dev/null || missing+=("libvirt-clients")
    command -v python3 &>/dev/null || missing+=("python3")

    # Check for virtiofsd (required for virtio-fs host/guest sharing)
    if ! command -v virtiofsd &>/dev/null && ! [ -x /usr/libexec/virtiofsd ]; then
        missing+=("virtiofsd")
    fi

    if [ ${#missing[@]} -gt 0 ]; then
        log_warn "Missing system packages: ${missing[*]}"
        log_info "Installing..."
        sudo apt-get update
        sudo apt-get install -y "${missing[@]}"
    fi

    log_info "System dependencies OK"
}

install_tdx_tools() {
    log_info "Installing Canonical TDX tools..."

    mkdir -p "$DEPS_DIR"

    if [ -d "$TDX_DIR/.git" ]; then
        log_info "Updating existing TDX installation..."
        cd "$TDX_DIR"
        git fetch origin
        git checkout "$TDX_BRANCH"
        git pull origin "$TDX_BRANCH"
    else
        log_info "Cloning canonical/tdx ($TDX_BRANCH)..."
        rm -rf "$TDX_DIR"
        git clone --branch "$TDX_BRANCH" "$TDX_REPO" "$TDX_DIR"
    fi

    # Make tools executable
    chmod +x "$TDX_DIR/guest-tools/tdvirsh" 2>/dev/null || true
    chmod +x "$TDX_DIR/guest-tools/run_td" 2>/dev/null || true

    # Create symlinks in project bin
    mkdir -p "$PROJECT_ROOT/bin"
    ln -sf "$TDX_DIR/guest-tools/tdvirsh" "$PROJECT_ROOT/bin/tdvirsh"
    ln -sf "$TDX_DIR/guest-tools/run_td" "$PROJECT_ROOT/bin/run_td"

    log_info "TDX tools installed to: $TDX_DIR"
    log_info "Symlinks created in: $PROJECT_ROOT/bin/"

    # Show version/info
    echo "  tdvirsh: $PROJECT_ROOT/bin/tdvirsh"
}

install_github_runner() {
    log_info "Installing GitHub Actions runner v${RUNNER_VERSION}..."

    mkdir -p "$RUNNER_DIR"
    cd "$RUNNER_DIR"

    RUNNER_ARCH="x64"
    RUNNER_FILE="actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
    RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${RUNNER_FILE}"

    # Check if already installed with same version
    if [ -f "$RUNNER_DIR/.runner_version" ]; then
        INSTALLED_VERSION=$(cat "$RUNNER_DIR/.runner_version")
        if [ "$INSTALLED_VERSION" = "$RUNNER_VERSION" ] && [ -f "$RUNNER_DIR/run.sh" ]; then
            log_info "GitHub runner v${RUNNER_VERSION} already installed"
            return 0
        fi
    fi

    # Download
    log_info "Downloading from: $RUNNER_URL"
    curl -fsSL -o "$RUNNER_FILE" "$RUNNER_URL"

    # Extract
    log_info "Extracting..."
    tar xzf "$RUNNER_FILE"
    rm "$RUNNER_FILE"

    # Mark version
    echo "$RUNNER_VERSION" > "$RUNNER_DIR/.runner_version"

    # Create symlink
    ln -sf "$RUNNER_DIR/run.sh" "$PROJECT_ROOT/bin/actions-runner"

    log_info "GitHub runner installed to: $RUNNER_DIR"
}

create_td_guest_image() {
    log_info "Checking for TDX guest image..."

    IMAGE_DIR="$TDX_DIR/guest-tools/image"
    EXPECTED_IMAGE="$IMAGE_DIR/tdx-guest-ubuntu-24.04-generic.qcow2"

    if [ -f "$EXPECTED_IMAGE" ]; then
        log_info "TDX guest image found: $EXPECTED_IMAGE"
        return 0
    fi

    # Check if there's a create script in the TDX tools
    CREATE_SCRIPT="$TDX_DIR/guest-tools/image/create-td-image.sh"
    if [ -f "$CREATE_SCRIPT" ]; then
        log_info "Creating TDX guest image (this may take a while)..."
        cd "$TDX_DIR/guest-tools/image"
        # Set required environment variables
        export UBUNTU_VERSION="24.04"
        export GUEST_USER="ubuntu"
        export GUEST_PASSWORD="ubuntu"
        sudo -E bash "$CREATE_SCRIPT" -v 24.04 || {
            log_warn "Image creation failed - will use fallback in build_image.sh"
            return 0
        }
        return 0
    fi

    log_warn "No TDX guest image found. Will be created during build_image.sh"
}

verify_tdx() {
    log_info "Verifying TDX status..."

    echo ""

    # Check TDX in KVM
    if [ -f /sys/module/kvm_intel/parameters/tdx ]; then
        TDX_ENABLED=$(cat /sys/module/kvm_intel/parameters/tdx 2>/dev/null || echo "N")
        if [ "$TDX_ENABLED" = "Y" ] || [ "$TDX_ENABLED" = "1" ]; then
            echo -e "  KVM TDX:        ${GREEN}enabled${NC}"
        else
            echo -e "  KVM TDX:        ${RED}disabled${NC} (value: $TDX_ENABLED)"
        fi
    else
        echo -e "  KVM TDX:        ${YELLOW}unknown${NC} (parameter not found)"
    fi

    # Check libvirt
    if systemctl is-active --quiet libvirtd; then
        echo -e "  libvirtd:       ${GREEN}running${NC}"
    else
        echo -e "  libvirtd:       ${RED}not running${NC}"
    fi

    # Check QEMU TDX support
    if qemu-system-x86_64 -cpu help 2>&1 | grep -qi "tdx"; then
        echo -e "  QEMU TDX:       ${GREEN}supported${NC}"
    else
        echo -e "  QEMU TDX:       ${YELLOW}not detected${NC}"
    fi

    # Check our tools
    if [ -x "$PROJECT_ROOT/bin/tdvirsh" ]; then
        echo -e "  tdvirsh:        ${GREEN}installed${NC} ($PROJECT_ROOT/bin/tdvirsh)"
    else
        echo -e "  tdvirsh:        ${RED}not installed${NC}"
    fi

    # Check runner
    if [ -f "$RUNNER_DIR/run.sh" ]; then
        RUNNER_VER=$(cat "$RUNNER_DIR/.runner_version" 2>/dev/null || echo "unknown")
        echo -e "  GitHub runner:  ${GREEN}installed${NC} (v$RUNNER_VER)"
    else
        echo -e "  GitHub runner:  ${RED}not installed${NC}"
    fi

    echo ""
}

show_status() {
    echo "========================================="
    echo "TDX GitHub Runner - Status"
    echo "========================================="
    echo ""
    echo "Paths:"
    echo "  Project root:   $PROJECT_ROOT"
    echo "  Dependencies:   $DEPS_DIR"
    echo "  TDX tools:      $TDX_DIR"
    echo "  GitHub runner:  $RUNNER_DIR"
    echo "  Binaries:       $PROJECT_ROOT/bin/"
    echo ""

    verify_tdx

    echo "Next steps:"
    echo "  1. Build VM image:     ./vm_images/build_image.sh"
    echo "  2. Configure runner:   ./scripts/install_runner.sh -r owner/repo"
    echo ""
}

do_install() {
    echo "========================================="
    echo "TDX GitHub Runner - Setup"
    echo "========================================="
    echo ""

    check_system_deps
    echo ""

    install_tdx_tools
    echo ""

    install_github_runner
    echo ""

    create_td_guest_image
    echo ""

    # Add bin to PATH hint
    if [[ ":$PATH:" != *":$PROJECT_ROOT/bin:"* ]]; then
        log_info "Add to your shell profile:"
        echo "  export PATH=\"$PROJECT_ROOT/bin:\$PATH\""
        echo ""
    fi

    show_status
}

do_update() {
    log_info "Updating dependencies..."

    # Update TDX
    if [ -d "$TDX_DIR/.git" ]; then
        log_info "Updating TDX tools..."
        cd "$TDX_DIR"
        git fetch origin
        git pull origin "$TDX_BRANCH"
    else
        install_tdx_tools
    fi

    # Re-download runner (to get latest)
    log_info "Checking for runner updates..."
    # Get latest version from GitHub API
    LATEST_VERSION=$(curl -fsSL https://api.github.com/repos/actions/runner/releases/latest | jq -r '.tag_name' | sed 's/^v//')
    if [ -n "$LATEST_VERSION" ] && [ "$LATEST_VERSION" != "null" ]; then
        RUNNER_VERSION="$LATEST_VERSION"
        install_github_runner
    fi

    log_info "Update complete"
}

main() {
    COMMAND="install"

    while [[ $# -gt 0 ]]; do
        case $1 in
            install|update|verify|status)
                COMMAND="$1"
                shift
                ;;
            --tdx-branch)
                TDX_BRANCH="$2"
                shift 2
                ;;
            --runner-version)
                RUNNER_VERSION="$2"
                shift 2
                ;;
            --deps-dir)
                DEPS_DIR="$2"
                TDX_DIR="$DEPS_DIR/tdx"
                RUNNER_DIR="$DEPS_DIR/actions-runner"
                shift 2
                ;;
            -h|--help)
                show_usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_usage
                exit 1
                ;;
        esac
    done

    case $COMMAND in
        install)
            do_install
            ;;
        update)
            do_update
            ;;
        verify)
            verify_tdx
            ;;
        status)
            show_status
            ;;
    esac
}

main "$@"
