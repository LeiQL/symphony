#!/bin/bash

# Symphony Target Bindings Manager (No yq dependency)
# Adds connected registry monitor and staging status monitor bindings to Target CRs
# Based on C# BindingSpec logic for Symphony orchestration
# Uses only kubectl and standard bash tools

# set -eo pipefail  # Temporarily disabled for debugging

# Script metadata
SCRIPT_NAME="add-target-bindings.sh"
SCRIPT_VERSION="2.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default values
NAMESPACE=""
TARGETS=""
DRY_RUN=false
VERBOSE=false
BACKUP_DIR="${SCRIPT_DIR}/backups"
TOPOLOGY_NAME="staging-topology"
OUTPUT_FILE="${SCRIPT_DIR}/target-bindings-output6.txt"
ADD_COMPONENTS=false
IMAGE_LIST="demo-image-05:latest"
IMAGE_REF_KEY="demo-image-05:latest"
IMAGE_REF_VALUE="lcc2-solution2-1.0.0.1"

# Logging functions (no colors for provider.target.script compatibility)
log_info() {
    local msg="[INFO] $1"
    echo "$msg"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" >> "$OUTPUT_FILE"
}

log_warn() {
    local msg="[WARN] $1"
    echo "$msg"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" >> "$OUTPUT_FILE"
}

log_error() {
    local msg="[ERROR] $1"
    echo "$msg" >&2
    echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" >> "$OUTPUT_FILE"
}

log_debug() {
    if [[ "$VERBOSE" == "true" ]]; then
        local msg="[DEBUG] $1"
        echo "$msg"
        echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" >> "$OUTPUT_FILE"
    fi
}

# Print usage information
usage() {
    cat << EOF
$SCRIPT_NAME v$SCRIPT_VERSION - Symphony Target Bindings Manager

DESCRIPTION:
    Adds connected registry monitor and staging status monitor bindings to Symphony Target CRs.
    Converts C# BindingSpec logic to Kubernetes Custom Resource updates.

USAGE:
    $SCRIPT_NAME --namespace <namespace> --targets <target1,target2> [OPTIONS]

REQUIRED ARGUMENTS:
    --namespace, -n     Kubernetes namespace containing the Target CRs
    --targets, -t       Target name(s) - single name or comma-separated list

OPTIONS:
    --dry-run, -d       Preview changes without applying them
    --verbose, -v       Enable verbose logging
    --topology-name     Topology name to add bindings to (default: 'staging-topology')
    --backup-dir        Directory for CR backups (default: ./backups)
    --add-components    Also add components section alongside topologies
    --image-list        Image list for staging-status component (default: 'demo-image-05:latest')
    --image-ref-key     Image reference key (default: 'demo-image-05:latest')
    --image-ref-value   Image reference value (default: 'lcc2-solution2-1.0.0.1')
    --help, -h          Show this help message

EXAMPLES:
    # Add bindings to a single target
    $SCRIPT_NAME --namespace symphony-system --targets my-target

    # Add bindings to multiple targets with dry-run
    $SCRIPT_NAME -n symphony-system -t target1,target2 --dry-run

    # Add both topologies and components with custom image settings
    $SCRIPT_NAME -n default -t target03 --add-components --image-list "my-image:v1.0" --verbose

    # Verbose mode with custom topology
    $SCRIPT_NAME -n symphony-system -t my-target --verbose --topology-name staging-topology

SECTIONS ADDED:
    1. Topologies: Connected Registry Monitor and Staging Status Monitor bindings
    2. Components (optional): Connection string and staging status components with image references

PREREQUISITES:
    - Target CRs must exist in the specified namespace

EOF
}


# Parse JSON input from Symphony script provider
parse_json_input() {
    local json_file="$1"
    
    if [[ -z "$json_file" ]]; then
        log_error "No JSON input file provided"
        exit 1
    fi
    
    if [[ ! -f "$json_file" ]]; then
        log_error "JSON input file not found: $json_file"
        exit 1
    fi
    
    log_debug "Reading JSON input from: $json_file"
    
    # Parse JSON using python3
    local json_content
    json_content=$(cat "$json_file")
    
    # Extract values from JSON using python3
    NAMESPACE=$(echo "$json_content" | python3 -c "import json, sys; data=json.load(sys.stdin); print(data.get('namespace', 'default'))")
    TARGETS=$(echo "$json_content" | python3 -c "import json, sys; data=json.load(sys.stdin); print(data.get('targets', ''))")
    
    # Parse optional flags
    local add_components_str
    add_components_str=$(echo "$json_content" | python3 -c "import json, sys; data=json.load(sys.stdin); print(data.get('add_components', 'false'))")
    if [[ "$add_components_str" == "true" ]]; then
        ADD_COMPONENTS=true
    fi
    
    local verbose_str
    verbose_str=$(echo "$json_content" | python3 -c "import json, sys; data=json.load(sys.stdin); print(data.get('verbose', 'false'))")
    if [[ "$verbose_str" == "true" ]]; then
        VERBOSE=true
    fi
    
    # Parse component-specific settings
    IMAGE_LIST=$(echo "$json_content" | python3 -c "import json, sys; data=json.load(sys.stdin); print(data.get('image_list', '$IMAGE_LIST'))")
    IMAGE_REF_KEY=$(echo "$json_content" | python3 -c "import json, sys; data=json.load(sys.stdin); print(data.get('image_ref_key', '$IMAGE_REF_KEY'))")
    IMAGE_REF_VALUE=$(echo "$json_content" | python3 -c "import json, sys; data=json.load(sys.stdin); print(data.get('image_ref_value', '$IMAGE_REF_VALUE'))")
    
    # Validate required arguments
    if [[ -z "$NAMESPACE" ]]; then
        log_error "Namespace is required in JSON input"
        exit 1
    fi

    if [[ -z "$TARGETS" ]]; then
        log_error "Target name(s) required in JSON input"
        exit 1
    fi

    log_debug "JSON parsed: namespace=$NAMESPACE, targets=$TARGETS, add_components=$ADD_COMPONENTS, verbose=$VERBOSE"
}

# Parse command line arguments (fallback for direct script execution)
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --namespace|-n)
                NAMESPACE="$2"
                shift 2
                ;;
            --targets|-t)
                TARGETS="$2"
                shift 2
                ;;
            --dry-run|-d)
                DRY_RUN=true
                shift
                ;;
            --verbose|-v)
                VERBOSE=true
                shift
                ;;
            --topology-name)
                TOPOLOGY_NAME="$2"
                shift 2
                ;;
            --backup-dir)
                BACKUP_DIR="$2"
                shift 2
                ;;
            --add-components)
                ADD_COMPONENTS=true
                shift
                ;;
            --image-list)
                IMAGE_LIST="$2"
                shift 2
                ;;
            --image-ref-key)
                IMAGE_REF_KEY="$2"
                shift 2
                ;;
            --image-ref-value)
                IMAGE_REF_VALUE="$2"
                shift 2
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown argument: $1"
                usage
                exit 1
                ;;
        esac
    done

    # Validate required arguments
    if [[ -z "$NAMESPACE" ]]; then
        log_error "Namespace is required (--namespace)"
        exit 1
    fi

    if [[ -z "$TARGETS" ]]; then
        log_error "Target name(s) required (--targets)"
        exit 1
    fi

    log_debug "Arguments parsed: namespace=$NAMESPACE, targets=$TARGETS, dry-run=$DRY_RUN"
}

# Check and install Python if needed
ensure_python_installed() {
    if command -v python3 &> /dev/null; then
        log_debug "Python3 is already installed"
        return 0
    fi
    
    log_info "Python3 not found, installing via apt-get..."
    
    if apt-get update && apt-get install -y python3; then
        log_info "Python3 installed successfully"
        return 0
    else
        log_error "Failed to install Python3 via apt-get"
        log_error "Please install Python3 manually and retry"
        return 1
    fi
}

# Create backup directory
create_backup_dir() {
    if [[ ! -d "$BACKUP_DIR" ]]; then
        mkdir -p "$BACKUP_DIR"
        log_debug "Created backup directory: $BACKUP_DIR"
    fi
}

# Backup original Target CR
backup_target() {
    local target_name="$1"
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${BACKUP_DIR}/${target_name}_${timestamp}.yaml"

    log_debug "Backing up target $target_name to $backup_file"
    
    if kubectl get target "$target_name" -n "$NAMESPACE" -o yaml > "$backup_file"; then
        log_info "Backup created: $backup_file"
        echo "$backup_file"
    else
        log_error "Failed to backup target $target_name"
        return 1
    fi
}

# Check if target exists
target_exists() {
    local target_name="$1"
    kubectl get target "$target_name" -n "$NAMESPACE" &> /dev/null
}

# Check if staging topology already exists using kubectl and grep (no yq)
staging_topology_exists() {
    local target_name="$1"
    
    # Get target as JSON and check for staging topology with connected-registry-monitor
    local json_output
    json_output=$(kubectl get target "$target_name" -n "$NAMESPACE" -o json 2>/dev/null || echo "{}")
    
    # Use python to check if staging topology exists (built-in json module)
    python3 -c "
import json, sys
try:
    data = json.loads('''$json_output''')
    topologies = data.get('spec', {}).get('topologies', [])
    for topology in topologies:
        bindings = topology.get('bindings', [])
        if (len(bindings) == 2 and 
            len(bindings) > 0 and 
            'connected-registry-monitor' in bindings[0].get('role', '')):
            sys.exit(0)  # Found
    sys.exit(1)  # Not found
except:
    sys.exit(1)  # Error
"
}

# Generate new topology JSON
generate_staging_topology_json() {
    cat << EOF
{
  "device": "$TOPOLOGY_NAME",
  "bindings": [
    {
      "role": "connected-registry-monitor",
      "provider": "providers.target.script",
      "config": {
        "applyScript": "get-connected-registry.sh",
        "removeScript": "mock-remove.sh",
        "getScript": "target-get.sh",
        "scriptFolder": "external_distribution/staging"
      }
    },
    {
      "role": "staging-status-monitor",
      "provider": "providers.target.script",
      "config": {
        "applyScript": "get-staging-status.sh",
        "removeScript": "mock-remove.sh",
        "getScript": "target-get.sh",
        "scriptFolder": "external_distribution/staging"
      }
    }
  ]
}
EOF
}

# Generate components JSON
generate_components_json() {
    cat << EOF
[
  {
    "name": "connection-string",
    "type": "connected-registry-monitor"
  },
  {
    "name": "staging-status",
    "type": "staging-status-monitor",
    "properties": {
      "imageList": [
        "$IMAGE_LIST"
      ],
      "imageRef": {
        "$IMAGE_REF_KEY": [
          "$IMAGE_REF_VALUE"
        ]
      }
    }
  }
]
EOF
}

# Add bindings to target using kubectl patch (no yq)
add_bindings_to_target() {
    local target_name="$1"
    
    log_info "Processing target: $target_name"

    # Check if target exists
    if ! target_exists "$target_name"; then
        log_error "Target $target_name not found in namespace $NAMESPACE"
        return 1
    fi

    # C# Logic: Check if staging topology already exists 
    # var topology = targetSpec.Topologies.FirstOrDefault(t => t.Bindings.Count == 2 && t.Bindings[0].Role.Contains("connected-registry-monitor"));
    if staging_topology_exists "$target_name"; then
        log_warn "Staging topology with 2 bindings including connected-registry-monitor already exists in $target_name, skipping"
        return 0
    fi

    # Backup original target
    local backup_file
    if ! backup_file=$(backup_target "$target_name"); then
        return 1
    fi

    # C# Logic: targetSpec.Topologies.Add(new TopologySpec { Device = "staging-topology", Bindings = bindings })
    log_info "Adding new staging topology '$TOPOLOGY_NAME' with 2 bindings to $target_name"
    
    # Generate the new topology JSON
    local new_topology
    new_topology=$(generate_staging_topology_json)
    
    log_debug "Generated topology JSON: $new_topology"

    # Create patch operation to add the topology
    local patch_json
    patch_json=$(cat << EOF
[
  {
    "op": "add",
    "path": "/spec/topologies/-",
    "value": $new_topology
  }
]
EOF
)

    # Apply changes using kubectl patch
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY-RUN: Would add the following topology to $target_name:"
        echo "----------------------------------------"
        echo "$new_topology" | python3 -m json.tool
        echo "----------------------------------------"
        
        # Show components if enabled
        if [[ "$ADD_COMPONENTS" == "true" ]]; then
            log_info "DRY-RUN: Would also add the following components:"
            echo "----------------------------------------"
            generate_components_json | python3 -m json.tool
            echo "----------------------------------------"
        fi
    else
        log_info "Patching target $target_name with new topology"
        if kubectl patch target "$target_name" -n "$NAMESPACE" --type='json' -p="$patch_json"; then
            log_info "Successfully updated target $target_name with topology"
            log_debug "About to check ADD_COMPONENTS flag: $ADD_COMPONENTS"
            
            # Add components if enabled
            if [[ "$ADD_COMPONENTS" == "true" ]]; then
                log_info "Adding components to $target_name"
                local components_json
                components_json=$(generate_components_json)
                log_debug "Generated components JSON"
                
                # Create patch for components
                local components_patch
                components_patch=$(cat << EOF
[
  {
    "op": "add",
    "path": "/spec/components",
    "value": $components_json
  }
]
EOF
)
                log_debug "Created components patch"
                
                if kubectl patch target "$target_name" -n "$NAMESPACE" --type='json' -p="$components_patch"; then
                    log_info "Successfully added components to $target_name"
                else
                    log_warn "Failed to add components to $target_name, but topology was added successfully"
                fi
            else
                log_debug "ADD_COMPONENTS is false, skipping components"
            fi
            log_debug "Finished topology processing for $target_name"
        else
            log_error "Failed to update target $target_name"
            log_info "Restore from backup: kubectl apply -f $backup_file"
            return 1
        fi
    fi

    log_debug "Completed processing target: $target_name"
    log_debug "About to return from add_bindings_to_target function"
    return 0
}

# Main function
main() {
    log_info "Starting $SCRIPT_NAME v$SCRIPT_VERSION"
    
    # Check if this is being called by Symphony script provider (JSON input)
    if [[ $# -eq 1 && -f "$1" ]]; then
        log_debug "Symphony mode: parsing JSON input"
        parse_json_input "$1"
    else
        log_debug "Command-line mode: parsing arguments"
        parse_args "$@"
    fi
    
    # Ensure Python3 is installed
    if ! ensure_python_installed; then
        exit 1
    fi
    
    create_backup_dir

    # Convert comma-separated targets to array
    IFS=',' read -ra TARGET_ARRAY <<< "$TARGETS"
    
    local success_count=0
    local total_count=${#TARGET_ARRAY[@]}
    
    log_info "Processing $total_count target(s) in namespace $NAMESPACE"
    
    # Process each target
    for target in "${TARGET_ARRAY[@]}"; do
        # Trim whitespace
        target=$(echo "$target" | xargs)
        log_debug "About to process target: $target"
        
        if add_bindings_to_target "$target"; then
            ((success_count++))
            log_debug "Successfully processed target: $target (count: $success_count)"
        else
            log_debug "Failed to process target: $target"
        fi
        echo # Add spacing between targets
    done

    log_debug "Completed processing all targets. Success: $success_count, Total: $total_count"
    
    # Summary
    echo "========================================"
    log_info "Summary: $success_count/$total_count targets processed successfully"
    
    # Create JSON output for Symphony script provider
    if [[ $# -eq 1 && -f "$1" ]]; then
        local inputs_file="$1"
        local output_file="${inputs_file%.*}-output.${inputs_file##*.}"
        
        local status_code=200
        if [[ "$success_count" -ne "$total_count" ]]; then
            status_code=500
        fi
        
        echo "{\"status\":$status_code,\"message\":\"Processed $success_count/$total_count targets\",\"targets_processed\":$success_count,\"total_targets\":$total_count}" > "$output_file"
        log_info "JSON output written to: $output_file"
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY-RUN completed. No changes were applied."
        log_info "Remove --dry-run flag to apply changes."
    else
        if [[ "$success_count" -eq "$total_count" ]]; then
            log_info "All targets updated successfully!"
        else
            log_warn "Some targets failed to update. Check logs above for details."
            exit 1
        fi
    fi
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
