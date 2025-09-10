#!/bin/bash

# Symphony Staging Bindings Manager (No yq dependency)
# Adds staging bindings to Target CRs with custom topology and components
# Based on C# BindingSpec logic for Symphony orchestration
# Uses only kubectl and standard bash tools

# set -eo pipefail  # Temporarily disabled for debugging

# Script metadata
SCRIPT_NAME="add-staging-bindings.sh"
SCRIPT_VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default values
NAMESPACE=""
TARGETS=""
DRY_RUN=false
VERBOSE=false
BACKUP_DIR="${SCRIPT_DIR}/backups"
TOPOLOGY_NAME="staging-topology"
OUTPUT_FILE="${SCRIPT_DIR}/staging-bindings-output.txt"
ADD_COMPONENTS=true
# Default image list for staging component (can be overridden via JSON input)
# Store as JSON string to support dictionary format
IMAGE_LIST='{"stage-sol-5.0.0.2": ["demo-data-02:latest"]}'

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
$SCRIPT_NAME v$SCRIPT_VERSION - Symphony Staging Bindings Manager

DESCRIPTION:
    Adds staging bindings to Symphony Target CRs with custom topology and components.
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
    --add-components    Also add components section alongside topologies (default: true)
    --image-list        Image list for staging component (default: 'stage-sol-5.0.0.2:demo-data-02:latest')
    --help, -h          Show this help message

EXAMPLES:
    # Add staging bindings to a single target
    $SCRIPT_NAME --namespace symphony-system --targets my-target

    # Add bindings to multiple targets with dry-run
    $SCRIPT_NAME -n symphony-system -t target1,target2 --dry-run

    # Add with custom image list
    $SCRIPT_NAME -n default -t target03 --image-list "my-stage-sol:my-data:latest" --verbose

    # Verbose mode with custom topology
    $SCRIPT_NAME -n symphony-system -t my-target --verbose --topology-name staging-topology

SECTIONS ADDED:
    1. Topologies: Staging topology with trigger-staging.sh binding
    2. Components: Staging component with configurable image list

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
    
    # Parse JSON using jq
    local json_content
    json_content=$(cat "$json_file")
    
    # Extract values from JSON using jq
    NAMESPACE=$(echo "$json_content" | jq -r '.namespace // "default"')
    TARGETS=$(echo "$json_content" | jq -r '.targets // ""')
    
    # ADD_COMPONENTS is now always true by default, no parsing from JSON
    
    local verbose_str
    verbose_str=$(echo "$json_content" | jq -r '.verbose // "false"')
    if [[ "$verbose_str" == "true" ]]; then
        VERBOSE=true
    fi
    
    # Parse image list - expect solution to images dictionary format
    local image_list_json
    image_list_json=$(echo "$json_content" | jq -c '.image_list // {}')
    
    if [[ "$image_list_json" != "{}" && "$image_list_json" != "null" ]]; then
        # Store the full dictionary as JSON for proper component generation
        IMAGE_LIST="$image_list_json"
        log_debug "Parsed image list from JSON: $IMAGE_LIST"
    fi
    
    # Validate required arguments
    if [[ -z "$NAMESPACE" ]]; then
        log_error "Namespace is required in JSON input"
        exit 1
    fi

    if [[ -z "$TARGETS" ]]; then
        log_error "Target name(s) required in JSON input"
        exit 1
    fi

    log_debug "JSON parsed: namespace=$NAMESPACE, targets=$TARGETS, add_components=$ADD_COMPONENTS, verbose=$VERBOSE, image_list=$IMAGE_LIST"
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

# Check and install jq if needed
ensure_jq_installed() {
    if command -v jq &> /dev/null; then
        log_debug "jq is already installed"
        return 0
    fi
    
    log_info "jq not found, installing via apt-get..."
    
    if apt-get update && apt-get install -y jq; then
        log_info "jq installed successfully"
        return 0
    else
        log_error "Failed to install jq via apt-get"
        log_error "Please install jq manually and retry"
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

# Check if staging topology already exists using kubectl and jq
staging_topology_exists() {
    local target_name="$1"
    
    # Get target as JSON and check for staging topology
    local json_output
    json_output=$(kubectl get target "$target_name" -n "$NAMESPACE" -o json 2>/dev/null || echo "{}")
    
    # Use jq to check if staging topology exists
    local topology_count
    topology_count=$(echo "$json_output" | jq -r "
        .spec.topologies[]? | 
        select(.device == \"$TOPOLOGY_NAME\" and (.bindings[]?.role == \"staging\")) | 
        length" 2>/dev/null || echo "0")
    
    if [[ "$topology_count" != "0" && "$topology_count" != "" ]]; then
        return 0  # Found staging topology
    else
        return 1  # Not found
    fi
}

# Generate new staging topology JSON
generate_staging_topology_json() {
    cat << EOF
{
  "device": "$TOPOLOGY_NAME",
  "bindings": [
    {
      "role": "staging",
      "provider": "providers.target.script",
      "config": {
        "applyScript": "trigger-staging.sh",
        "getScript": "target-get.sh",
        "removeScript": "mock-remove.sh",
        "scriptFolder": "external_distribution/staging"
      }
    }
  ]
}
EOF
}

# Generate staging components JSON
generate_components_json() {
    # Parse new image list as JSON
    local new_image_list_obj
    if echo "$IMAGE_LIST" | jq empty 2>/dev/null; then
        new_image_list_obj=$(echo "$IMAGE_LIST" | jq -c .)
    else
        # Convert colon/comma format to JSON
        # Handle format: "solution:image:tag" where tag may contain additional colons
        new_image_list_obj=$(echo "$IMAGE_LIST" | awk -F, '{
            printf "{";
            for(i=1;i<=NF;i++){
                split($i,a,":");
                # Reconstruct the image name with all parts after the first colon
                image_name = "";
                for(j=2; j<=length(a); j++){
                    if(j > 2) image_name = image_name ":";
                    image_name = image_name a[j];
                }
                printf "\"%s\":[\"%s\"]", a[1], image_name;
                if(i<NF) printf ",";
            }
            printf "}";
        }')
    fi

    # Validate new image list JSON
    if ! echo "$new_image_list_obj" | jq empty 2>/dev/null; then
        new_image_list_obj='{"stage-sol-5.0.0.2": ["demo-data-02:latest"]}'
    fi

    # Generate compact JSON output - use new image list directly to avoid merge issues
    jq -nc --argjson imageList "$new_image_list_obj" '[{
        "name": "staging-component",
        "type": "staging", 
        "properties": {
            "imageList": $imageList
        }
    }]'
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

    # Check if staging topology already exists
    local topology_exists=false
    if staging_topology_exists "$target_name"; then
        log_warn "Staging topology already exists in $target_name"
        topology_exists=true
    fi

    # Backup original target
    local backup_file
    if ! backup_file=$(backup_target "$target_name"); then
        return 1
    fi

    # Prepare combined patch operations
    local patch_operations=()
    local topology_json=""
    local components_json=""

    # Add topology if it doesn't exist
    if [[ "$topology_exists" == "false" ]]; then
        log_info "Adding new staging topology '$TOPOLOGY_NAME' to $target_name"
        topology_json=$(generate_staging_topology_json)
        log_debug "Generated topology JSON: $topology_json"
        patch_operations+=('{"op": "add", "path": "/spec/topologies/-", "value": '"$topology_json"'}')
    fi

    # Always add/update components (ADD_COMPONENTS is always true)
    log_info "Adding/updating staging components for $target_name"
    components_json=$(generate_components_json)
    log_debug "Generated staging components JSON"
    log_debug "Image list being used: $IMAGE_LIST"
    patch_operations+=('{"op": "add", "path": "/spec/components", "value": '"$components_json"'}')

    # Create combined patch if we have operations to perform
    if [[ ${#patch_operations[@]} -gt 0 ]]; then
        local combined_patch="[$(IFS=','; echo "${patch_operations[*]}")]"
        
        if [[ "$DRY_RUN" == "true" ]]; then
            log_info "DRY-RUN: Would apply the following combined patch to $target_name:"
            echo "----------------------------------------"
            echo "$combined_patch" | jq '.'
            echo "----------------------------------------"
            if [[ "$topology_exists" == "false" ]]; then
                log_info "Would add staging topology:"
                echo "$topology_json" | jq '.'
            fi
            log_info "Would add/update staging components:"
            echo "$components_json" | jq '.'
        else
            log_info "Applying combined patch to target $target_name (topology + components)"
            log_debug "Current target JSON before combined patch:"
            kubectl get target "$target_name" -n "$NAMESPACE" -o json | jq '.'
            log_debug "Combined patch to apply:"
            echo "$combined_patch" | jq '.'
            
            if kubectl patch target "$target_name" -n "$NAMESPACE" --type='json' -p="$combined_patch"; then
                log_info "Successfully updated target $target_name with staging topology and components"
            else
                log_error "Failed to update target $target_name"
                log_info "Restore from backup: kubectl apply -f $backup_file"
                return 1
            fi
        fi
    else
        log_info "No updates needed for target $target_name"
    fi

    log_debug "Completed processing target: $target_name"
    return 0
}

# Main function
main() {
    log_info "Starting $SCRIPT_NAME v$SCRIPT_VERSION"

    # Check if this is being called by Symphony script provider (JSON input)
    if [[ $# -eq 1 && -f "$1" ]]; then
        log_info "Running in Symphony JSON input mode: input file $1"
        log_debug "Symphony mode: parsing JSON input"
        parse_json_input "$1"
    else
        log_info "Running in CLI argument mode"
        log_debug "Command-line mode: parsing arguments"
        parse_args "$@"
    fi
    
    # Ensure jq is installed
    if ! ensure_jq_installed; then
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
        
        echo "{\"status\":$status_code,\"message\":\"Processed $success_count/$total_count staging targets\",\"targets_processed\":$success_count,\"total_targets\":$total_count}" > "$output_file"
        log_info "JSON output written to: $output_file"
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY-RUN completed. No changes were applied."
        log_info "Remove --dry-run flag to apply changes."
    else
        if [[ "$success_count" -eq "$total_count" ]]; then
            log_info "All targets updated successfully with staging bindings!"
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
