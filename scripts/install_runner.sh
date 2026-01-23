#!/bin/bash
# Install GitHub Actions self-hosted runner
# Run this on the TDX host to enable GitHub Actions integration

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

RUNNER_VERSION="${RUNNER_VERSION:-2.321.0}"
RUNNER_DIR="${RUNNER_DIR:-$HOME/actions-runner}"
RUNNER_USER="${RUNNER_USER:-$(whoami)}"

show_usage() {
    cat << EOF
Usage: $0 [OPTIONS]

Install and configure GitHub Actions self-hosted runner.

Options:
    -r, --repo OWNER/REPO    GitHub repository (required for repo runner)
    -o, --org ORG            GitHub organization (for org-level runner)
    -t, --token TOKEN        Runner registration token
    -l, --labels LABELS      Comma-separated labels (default: tdx,self-hosted)
    -n, --name NAME          Runner name (default: hostname)
    -d, --dir DIR            Installation directory (default: ~/actions-runner)
    --unattended             Run registration unattended
    -h, --help               Show this help message

Environment Variables:
    GITHUB_TOKEN             GitHub PAT for registration (alternative to --token)
    RUNNER_VERSION           Runner version (default: $RUNNER_VERSION)

Examples:
    # Interactive setup
    $0 -r owner/repo

    # Unattended setup with token
    $0 -r owner/repo -t ABC123TOKEN --unattended

    # Organization-level runner
    $0 -o my-org -t ABC123TOKEN --unattended -l tdx,gpu,self-hosted
EOF
}

download_runner() {
    log_info "Downloading GitHub Actions Runner v${RUNNER_VERSION}..."

    mkdir -p "$RUNNER_DIR"
    cd "$RUNNER_DIR"

    RUNNER_ARCH="x64"
    RUNNER_URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"

    if [ -f "run.sh" ]; then
        log_warn "Runner already exists in $RUNNER_DIR"
        read -p "Overwrite? (y/N) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            return 0
        fi
    fi

    curl -fsSL -o runner.tar.gz "$RUNNER_URL"
    tar xzf runner.tar.gz
    rm runner.tar.gz

    log_info "Runner downloaded and extracted to $RUNNER_DIR"
}

configure_runner() {
    log_info "Configuring runner..."

    cd "$RUNNER_DIR"

    CONFIG_ARGS=()

    if [ -n "$GITHUB_ORG" ]; then
        CONFIG_ARGS+=(--url "https://github.com/${GITHUB_ORG}")
    elif [ -n "$GITHUB_REPO" ]; then
        CONFIG_ARGS+=(--url "https://github.com/${GITHUB_REPO}")
    else
        log_error "Either --repo or --org is required"
        exit 1
    fi

    if [ -n "$RUNNER_TOKEN" ]; then
        CONFIG_ARGS+=(--token "$RUNNER_TOKEN")
    elif [ -n "$GITHUB_TOKEN" ]; then
        # Get registration token from API
        if [ -n "$GITHUB_ORG" ]; then
            API_URL="https://api.github.com/orgs/${GITHUB_ORG}/actions/runners/registration-token"
        else
            API_URL="https://api.github.com/repos/${GITHUB_REPO}/actions/runners/registration-token"
        fi

        log_info "Getting registration token from GitHub API..."
        RUNNER_TOKEN=$(curl -fsSL \
            -H "Authorization: token $GITHUB_TOKEN" \
            -H "Accept: application/vnd.github+json" \
            -X POST "$API_URL" | jq -r '.token')

        if [ -z "$RUNNER_TOKEN" ] || [ "$RUNNER_TOKEN" = "null" ]; then
            log_error "Failed to get registration token"
            exit 1
        fi
        CONFIG_ARGS+=(--token "$RUNNER_TOKEN")
    fi

    CONFIG_ARGS+=(--name "${RUNNER_NAME:-$(hostname)}")
    CONFIG_ARGS+=(--labels "${RUNNER_LABELS:-tdx,self-hosted}")
    CONFIG_ARGS+=(--work "_work")

    if [ "$UNATTENDED" = true ]; then
        CONFIG_ARGS+=(--unattended)
        CONFIG_ARGS+=(--replace)
    fi

    ./config.sh "${CONFIG_ARGS[@]}"

    log_info "Runner configured successfully"
}

install_service() {
    log_info "Installing runner as system service..."

    cd "$RUNNER_DIR"

    if [ -f "./svc.sh" ]; then
        sudo ./svc.sh install "$RUNNER_USER"
        sudo ./svc.sh start

        log_info "Runner service installed and started"
        log_info "Check status: sudo ./svc.sh status"
    else
        log_warn "Service script not found, run manually with: ./run.sh"
    fi
}

main() {
    GITHUB_REPO=""
    GITHUB_ORG=""
    RUNNER_TOKEN=""
    RUNNER_NAME=""
    RUNNER_LABELS=""
    UNATTENDED=false

    while [[ $# -gt 0 ]]; do
        case $1 in
            -r|--repo)
                GITHUB_REPO="$2"
                shift 2
                ;;
            -o|--org)
                GITHUB_ORG="$2"
                shift 2
                ;;
            -t|--token)
                RUNNER_TOKEN="$2"
                shift 2
                ;;
            -l|--labels)
                RUNNER_LABELS="$2"
                shift 2
                ;;
            -n|--name)
                RUNNER_NAME="$2"
                shift 2
                ;;
            -d|--dir)
                RUNNER_DIR="$2"
                shift 2
                ;;
            --unattended)
                UNATTENDED=true
                shift
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

    if [ -z "$GITHUB_REPO" ] && [ -z "$GITHUB_ORG" ]; then
        log_error "Either --repo or --org is required"
        show_usage
        exit 1
    fi

    echo "========================================="
    echo "GitHub Actions Runner Installation"
    echo "========================================="
    echo

    download_runner
    configure_runner
    install_service

    echo
    log_info "Installation complete!"
    echo
    echo "Runner directory: $RUNNER_DIR"
    echo "Runner name: ${RUNNER_NAME:-$(hostname)}"
    echo "Labels: ${RUNNER_LABELS:-tdx,self-hosted}"
    echo
    echo "To check status: cd $RUNNER_DIR && sudo ./svc.sh status"
    echo "To view logs: journalctl -u actions.runner.*"
}

main "$@"
