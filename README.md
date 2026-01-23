# TDX GitHub Runner Platform

Run GitHub Actions workloads in Intel TDX (Trust Domain Extensions) VMs with hardware-based attestation.

## Overview

This platform enables:
- **`measure-tdx` action**: Ephemeral TDX VMs that run docker-compose workloads and capture cryptographic attestation
- **`launch-tdx` action**: Persistent TDX VMs for long-running services
- **VM-level attestation**: Launcher handles Intel Trust Authority integration, workloads only need /health endpoint

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     GITHUB ACTIONS                          │
│  User repo triggers workflow → Self-hosted runner executes  │
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│                 TDX HOST (Self-hosted Runner)               │
│  ┌─────────────────┐  ┌─────────────────────────────────┐   │
│  │ GitHub Runner   │  │ Shared Directory (9P)           │   │
│  │ (self-hosted)   │  │ - config.json (input)           │   │
│  │                 │  │ - attestation.json (output)     │   │
│  └────────┬────────┘  └─────────────────────────────────┘   │
│           │                                                  │
│           ▼                                                  │
│  ┌─────────────────────────────────────────────────────────┐│
│  │ TDX VM (Trust Domain)                                   ││
│  │  - Launcher (waits for health, generates attestation)   ││
│  │  - Docker + docker-compose (user workload)              ││
│  │  - TDX quote generation via ConfigFS-TSM                ││
│  └─────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────┐
│              INTEL TRUST AUTHORITY (Cloud)                  │
│  - Verifies TDX quotes from genuine Intel hardware          │
│  - Returns JWT attestation tokens                           │
└─────────────────────────────────────────────────────────────┘
```

## Quick Start

### 1. Host Setup

```bash
# Verify TDX is enabled
./scripts/setup_host.sh

# Build the TDX VM image with Docker and attestation tools
./vm_images/build_image.sh

# Generate base image attestation (publish MRTD for consumers)
./scripts/attest_base_image.sh
```

### 2. Install GitHub Runner

```bash
./scripts/install_runner.sh -r owner/repo -t YOUR_TOKEN -l tdx,self-hosted
```

### 3. Use GitHub Actions

**Ephemeral workload with attestation:**
```yaml
- uses: ./.github/actions/measure-tdx
  with:
    docker_compose_path: './docker-compose.yml'
    intel_api_key: ${{ secrets.INTEL_API_KEY }}
```

**Persistent service:**
```yaml
- uses: ./.github/actions/launch-tdx
  with:
    vm_name: 'my-service'
    docker_compose_path: './docker-compose.yml'
```

## GitHub Actions

### `measure-tdx`

Runs a docker-compose workload in an ephemeral TDX VM and captures attestation.

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| `docker_compose_path` | Yes | `./docker-compose.yml` | Path to compose file |
| `intel_api_key` | No | | Intel Trust Authority API key |
| `intel_api_url` | No | `https://api.trustauthority.intel.com` | Intel TA API URL |
| `health_endpoint` | No | `/health` | Health check endpoint |
| `vm_memory_gb` | No | `4` | VM memory in GB |
| `vm_cpus` | No | `2` | Number of VM CPUs |
| `timeout_minutes` | No | `30` | Workload timeout |

**Outputs:**
| Name | Description |
|------|-------------|
| `attestation_json` | Full attestation response with TDX quote and Intel TA token |
| `compose_hash` | SHA256 hash of docker-compose file |
| `vm_name` | Name of the TDX VM |

### `launch-tdx`

Launches a persistent TDX VM for long-running services.

**Inputs:**
| Name | Required | Default | Description |
|------|----------|---------|-------------|
| `vm_name` | Yes | | Name for the VM |
| `docker_compose_path` | No | | Initial compose setup |
| `vm_memory_gb` | No | `8` | VM memory in GB |
| `vm_cpus` | No | `4` | Number of VM CPUs |

**Outputs:**
| Name | Description |
|------|-------------|
| `vm_id` | Unique VM identifier |
| `vm_name` | Full VM name |
| `ssh_port` | SSH port for VM access |

## Workload Requirements

Workloads running in TDX VMs only need to expose a `/health` endpoint. The launcher handles all attestation:

```python
# Example minimal workload (main.py)
from fastapi import FastAPI

app = FastAPI()

@app.get("/health")
async def health():
    return {"status": "healthy"}
```

```yaml
# Example docker-compose.yml
services:
  app:
    build: .
    ports:
      - "8080:8080"
```

No Intel API keys, TDX mounts, or privileged mode needed in the workload.

## Attestation Chain of Trust

1. **MRTD (TD Measurement)**: Fingerprint of the VM configuration
   - Matches published value → proves same trusted base image

2. **Workload Binding**: Hash of compose file included in attestation
   - Proves which exact workload configuration ran

3. **Intel TA JWT**: Cryptographic proof
   - Verifies genuine Intel TDX hardware
   - Can be validated by anyone with Intel's public keys

**Attestation Output Format:**
```json
{
  "timestamp": "2026-01-22T16:30:00Z",
  "tdx": {
    "quote_b64": "...",
    "intel_ta_token": "eyJ...",
    "measurements": {
      "mrtd": "...",
      "rtmr0": "...",
      "rtmr1": "...",
      "rtmr2": "...",
      "rtmr3": "..."
    }
  },
  "workload": {
    "compose_hash": "sha256:...",
    "health_status": "healthy"
  }
}
```

## Directory Structure

```
tdx_github_runner/
├── .github/
│   ├── actions/
│   │   ├── measure-tdx/          # Ephemeral VM + attestation
│   │   └── launch-tdx/           # Persistent VM
│   └── workflows/                 # Example workflows
├── vm_images/
│   ├── build_image.sh            # Build customized TDX image
│   ├── customize.sh              # VM customization script
│   └── launcher/
│       └── launcher.py           # VM launcher with attestation
├── scripts/
│   ├── setup_host.sh             # Host setup verification
│   ├── install_runner.sh         # GitHub runner installation
│   └── attest_base_image.sh      # Base image attestation
└── examples/
    └── sample-app/
```

## Requirements

**Host:**
- Intel CPU with TDX support
- Canonical TDX tools (`tdvirsh`, `create-td-image.sh`)
- libvirt/QEMU with TDX support
- Python 3.11+

**TDX VM Image:**
- Docker CE + docker-compose plugin
- TDX quote generation tools (ConfigFS-TSM)
- Python requests library

**User:**
- Intel Trust Authority API key (for JWT attestation)
- GitHub repository with self-hosted runner

## Components Used

- [canonical/tdx](https://github.com/canonical/tdx) - TDX VM management
- [actions/runner](https://github.com/actions/runner) - GitHub Actions runner
- [Intel Trust Authority](https://www.intel.com/trustauthority) - Attestation verification

## License

MIT
