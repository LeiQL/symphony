# Symphony Target Bindings Manager

This script adds connected registry monitor and staging status monitor bindings to Symphony Target Custom Resources, converting the C# BindingSpec logic to Kubernetes CR operations.

## Features

- **Multi-target support**: Process single target or comma-separated list
- **Safe operations**: Automatic backup of original CRs before modification
- **Duplicate prevention**: Checks if bindings already exist to avoid duplicates
- **Dry-run capability**: Preview changes without applying them
- **Comprehensive error handling**: Validates targets exist and handles failures gracefully

## Prerequisites

- `kubectl` configured and authenticated to your Kubernetes cluster
- `yq` v4+ installed for YAML processing
- Target CRs must exist in the specified namespace

### Install yq

```bash
# Linux
curl -L https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -o yq && chmod +x yq && sudo mv yq /usr/local/bin/

# macOS
brew install yq
```

## Usage

### Basic Usage

```bash
# Add bindings to a single target
./add-target-bindings.sh --namespace symphony-system --targets my-target

# Add bindings to multiple targets
./add-target-bindings.sh --namespace symphony-system --targets target1,target2,target3
```

### Advanced Usage

```bash
# Dry-run to preview changes
./add-target-bindings.sh -n symphony-system -t my-target --dry-run

# Verbose mode for debugging
./add-target-bindings.sh -n symphony-system -t my-target --verbose

# Custom topology name
./add-target-bindings.sh -n symphony-system -t my-target --topology-name custom-topology

# Custom backup directory
./add-target-bindings.sh -n symphony-system -t my-target --backup-dir ./my-backups
```

## Bindings Added

The script adds these two bindings to each target:

### 1. Connected Registry Monitor
```yaml
- role: connected-registry-monitor
  provider: providers.target.script
  config:
    applyScript: get-connected-registry.sh
    removeScript: mock-remove.sh
    getScript: target-get.sh
    scriptFolder: external_distribution/staging
```

### 2. Staging Status Monitor
```yaml
- role: staging-status-monitor
  provider: providers.target.script
  config:
    applyScript: get-staging-status.sh
    removeScript: mock-remove.sh
    getScript: target-get.sh
    scriptFolder: external_distribution/staging
```

## Command Line Options

| Option | Short | Description |
|--------|-------|-------------|
| `--namespace` | `-n` | Kubernetes namespace containing Target CRs (required) |
| `--targets` | `-t` | Target name(s) - single or comma-separated list (required) |
| `--dry-run` | `-d` | Preview changes without applying them |
| `--verbose` | `-v` | Enable verbose logging |
| `--topology-name` | | Topology name to add bindings to (default: 'default') |
| `--backup-dir` | | Directory for CR backups (default: ./backups) |
| `--help` | `-h` | Show help message |

## Examples

### Example 1: Basic Usage
```bash
./add-target-bindings.sh --namespace production --targets edge-device-001
```

### Example 2: Multiple Targets with Dry-Run
```bash
./add-target-bindings.sh \
  --namespace staging \
  --targets device-001,device-002,device-003 \
  --dry-run \
  --verbose
```

### Example 3: Production Deployment
```bash
# First, test with dry-run
./add-target-bindings.sh -n production -t critical-device --dry-run

# If satisfied, apply changes
./add-target-bindings.sh -n production -t critical-device
```

## Error Handling

The script includes comprehensive error handling:

- **Prerequisites check**: Validates kubectl and yq are available
- **Target validation**: Ensures targets exist before modification
- **Duplicate prevention**: Skips bindings that already exist
- **Automatic backups**: Creates timestamped backups before changes
- **Rollback guidance**: Provides backup file location for manual rollback

## Recovery

If something goes wrong, you can restore from automatic backups:

```bash
# Backups are stored in ./backups/ by default
ls backups/

# Restore a target from backup
kubectl apply -f backups/my-target_20240710_143000.yaml
```

## Integration

This script can be integrated into CI/CD pipelines:

```bash
# Exit code 0 on success, non-zero on failure
./add-target-bindings.sh -n production -t device-list || exit 1
```

## Troubleshooting

### Common Issues

1. **Target not found**
   ```
   [ERROR] Target my-target not found in namespace symphony-system
   ```
   Solution: Verify target name and namespace

2. **Permission denied**
   ```
   [ERROR] Cannot connect to Kubernetes cluster
   ```
   Solution: Check kubectl configuration and permissions

3. **yq not found**
   ```
   [ERROR] yq v4+ is required but not installed
   ```
   Solution: Install yq v4+ using the provided instructions

### Debug Mode

Use `--verbose` flag for detailed operation logs:

```bash
./add-target-bindings.sh -n symphony-system -t my-target --verbose
