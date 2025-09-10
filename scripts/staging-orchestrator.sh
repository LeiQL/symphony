#!/bin/bash

# Symphony Staging Orchestrator - FIXED VERSION
# Fixed the cleanup logic to properly handle solution removal

# Script metadata
SCRIPT_NAME="staging-orchestrator.sh"
SCRIPT_VERSION="1.0.1-fixed"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default values
NAMESPACE=""
TARGETS=""
IMAGE_LIST=""
ACR_RESOURCE_ID=""
SOLUTION_IMAGES=""
VERBOSE=false
DRY_RUN=false
MONITOR_TIMEOUT_MINUTES=30
RETRY_INTERVAL_SECONDS=10
MAX_RETRY_INTERVAL_SECONDS=60
TOPOLOGY_NAME="staging-topology"
BACKUP_DIR="${SCRIPT_DIR}/backups"
OUTPUT_FILE="${SCRIPT_DIR}/staging-orchestrator-output.txt"
STEPS="1,2,3"  # Default: run all three steps

# Logging functions
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
$SCRIPT_NAME v$SCRIPT_VERSION - Symphony Staging Orchestrator (FIXED)

DESCRIPTION:
    Fixed version that properly handles cleanup of all solutions in imageList.
    
    ISSUE FIXED: The original version had a logic bug where SOLUTION_IMAGES was extracted
    from the original IMAGE_LIST but the cleanup target might have different solution names
    in the actual imageList. This version ensures ALL solutions are removed from the target.

USAGE:
    $SCRIPT_NAME --namespace <namespace> --targets <target1,target2> --image-list <json> [OPTIONS]

REQUIRED ARGUMENTS:
    --namespace, -n         Kubernetes namespace containing the Target CRs
    --targets, -t           Target name(s) - single name or comma-separated list
    --image-list           Image list JSON for staging (e.g., '{"sol1": ["img1:latest"]}')

OPTIONS:
    --steps, -s             Steps to execute (default: '1,2,3'). Use combinations like:
                           '1' - Only add staging bindings
                           '2' - Only monitor staging results  
                           '3' - Only cleanup staging components
                           '1,2' - Add bindings and monitor (no cleanup)
                           '2,3' - Monitor and cleanup (skip adding bindings)
                           '1,2,3' - Full workflow (default)
    --dry-run, -d           Preview changes without applying them
    --verbose, -v           Enable verbose logging
    --timeout-minutes       Monitor timeout in minutes (default: 30)
    --retry-interval        Initial retry interval in seconds (default: 10)
    --max-retry-interval    Maximum retry interval in seconds (default: 60)
    --topology-name         Topology name for bindings (default: 'staging-topology')
    --backup-dir            Directory for CR backups (default: ./backups)
    --help, -h              Show this help message

WORKFLOW STAGES:
    1. STAGE 1: Add staging bindings and components to targets
    2. STAGE 2: Monitor staging results until all images are staged
    3. STAGE 3: Cleanup staging components and reset reconciliation policy

EXAMPLES:
    # Basic staging workflow
    $SCRIPT_NAME -n default -t target1 --image-list '{"sol1": ["demo:latest"]}'

    # Multiple targets with custom timeout
    $SCRIPT_NAME -n default -t target1,target2 --image-list '{"sol1": ["img1:latest"], "sol2": ["img2:latest"]}' --timeout-minutes 60

    # Dry run to preview changes
    $SCRIPT_NAME -n default -t target1 --image-list '{"sol1": ["demo:latest"]}' --dry-run --verbose

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
    log_info "Reading JSON input from: $json_file"
    local json_content
    json_content=$(cat "$json_file")
    
    # DEBUG: Print the complete input JSON content
    log_info "DEBUG: Complete input JSON content:"
    if echo "$json_content" | jq empty 2>/dev/null; then
        # Valid JSON - format it nicely
        local formatted_json
        formatted_json=$(echo "$json_content" | jq '.' 2>/dev/null)
        log_info "$formatted_json"
    else
        # Invalid JSON or jq failed - print raw content
        log_info "Raw JSON content: $json_content"
    fi
    
    # Check for Symphony workflow metadata first, then fallback to regular fields
    NAMESPACE=$(echo "$json_content" | jq -r '.__namespace // .namespace // "default"')
    TARGETS=$(echo "$json_content" | jq -r '.targets // ""')
    
    # Handle image_list which comes as a JSON string that needs to be parsed
    local raw_image_list
    raw_image_list=$(echo "$json_content" | jq -r '.image_list // "{}"')
    
    # Parse the JSON string into actual JSON object
    if [[ "$raw_image_list" != "{}" && "$raw_image_list" != "null" ]]; then
        IMAGE_LIST=$(echo "$raw_image_list" | jq -c '.')
    else
        IMAGE_LIST="{}"
    fi
    
    ACR_RESOURCE_ID=$(echo "$json_content" | jq -r '.acrResourceId // ""')
    MONITOR_TIMEOUT_MINUTES=$(echo "$json_content" | jq -r '.timeout_minutes // 30')
    RETRY_INTERVAL_SECONDS=$(echo "$json_content" | jq -r '.retry_interval // 10')
    STEPS=$(echo "$json_content" | jq -r '.steps // "1,2,3"')
    
    local verbose_str
    verbose_str=$(echo "$json_content" | jq -r '.verbose // "false"')
    if [[ "$verbose_str" == "true" ]]; then
        VERBOSE=true
    fi
    
    # Extract solution names from image_list for use in stage 2 and 3
    SOLUTION_IMAGES=$(echo "$IMAGE_LIST" | jq -r 'keys[]' | tr '\n' ',' | sed 's/,$//')
    
    log_info "DEBUG: Raw image_list from input: '$raw_image_list'"
    log_info "DEBUG: Parsed IMAGE_LIST: '$IMAGE_LIST'"
    log_info "DEBUG: Extracted SOLUTION_IMAGES: '$SOLUTION_IMAGES'"
    
    log_debug "JSON parsed: namespace=$NAMESPACE, targets=$TARGETS, image_list=$IMAGE_LIST, acrResourceId=$ACR_RESOURCE_ID, solutions=$SOLUTION_IMAGES"
}

# Parse command line arguments
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
            --image-list)
                IMAGE_LIST="$2"
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
            --timeout-minutes)
                MONITOR_TIMEOUT_MINUTES="$2"
                shift 2
                ;;
            --retry-interval)
                RETRY_INTERVAL_SECONDS="$2"
                shift 2
                ;;
            --max-retry-interval)
                MAX_RETRY_INTERVAL_SECONDS="$2"
                shift 2
                ;;
            --topology-name)
                TOPOLOGY_NAME="$2"
                shift 2
                ;;
            --steps|-s)
                STEPS="$2"
                shift 2
                ;;
            --backup-dir)
                BACKUP_DIR="$2"
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

    if [[ -z "$IMAGE_LIST" ]]; then
        log_error "Image list required (--image-list)"
        exit 1
    fi
    
    # Extract solution names from image_list for use in stage 2 and 3
    SOLUTION_IMAGES=$(echo "$IMAGE_LIST" | jq -r 'keys[]' | tr '\n' ',' | sed 's/,$//')
}

# Ensure jq is installed
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

# Check if target exists
target_exists() {
    local target_name="$1"
    kubectl get target "$target_name" -n "$NAMESPACE" &> /dev/null
}

# ============================================================================
# STAGE 1: ADD STAGING BINDINGS
# ============================================================================

# Generate staging topology JSON
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
    local new_image_list_obj
    if echo "$IMAGE_LIST" | jq empty 2>/dev/null; then
        new_image_list_obj=$(echo "$IMAGE_LIST" | jq -c .)
    else
        new_image_list_obj='{"stage-sol-5.0.0.2": ["demo-data-02:latest"]}'
    fi

    # Build the component properties object
    local properties_obj
    if [[ -n "$ACR_RESOURCE_ID" ]]; then
        properties_obj=$(jq -nc --argjson imageList "$new_image_list_obj" --arg acrResourceId "$ACR_RESOURCE_ID" '{
            "acrResourceId": $acrResourceId,
            "imageList": $imageList
        }')
    else
        properties_obj=$(jq -nc --argjson imageList "$new_image_list_obj" '{
            "imageList": $imageList
        }')
    fi

    jq -nc --argjson properties "$properties_obj" '[{
        "name": "staging-component",
        "type": "staging", 
        "properties": $properties
    }]'
}

# Add bindings to target
add_bindings_to_target() {
    local target_name="$1"
    
    log_info "STAGE 1: Adding staging bindings to target: $target_name"

    if ! target_exists "$target_name"; then
        log_error "Target $target_name not found in namespace $NAMESPACE"
        return 1
    fi

    # Backup original target
    local timestamp
    timestamp=$(date +%Y%m%d_%H%M%S)
    local backup_file="${BACKUP_DIR}/${target_name}_${timestamp}.yaml"

    if ! kubectl get target "$target_name" -n "$NAMESPACE" -o yaml > "$backup_file"; then
        log_error "Failed to backup target $target_name"
        return 1
    fi
    log_info "Backup created: $backup_file"

    # Prepare patch operations
    local patch_operations=()
    local topology_json=""
    local components_json=""

    # Add topology
    log_info "Adding staging topology '$TOPOLOGY_NAME' to $target_name"
    topology_json=$(generate_staging_topology_json)
    patch_operations+=('{"op": "add", "path": "/spec/topologies/-", "value": '"$topology_json"'}')

    # Add components
    if [[ -n "$ACR_RESOURCE_ID" ]]; then
        log_info "Adding staging components for $target_name with ACR Resource ID: $ACR_RESOURCE_ID"
    else
        log_info "Adding staging components for $target_name"
    fi
    components_json=$(generate_components_json)
    patch_operations+=('{"op": "add", "path": "/spec/components", "value": '"$components_json"'}')

    # Apply combined patch
    local combined_patch="[$(IFS=','; echo "${patch_operations[*]}")]"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY-RUN: Would apply the following patch to $target_name:"
        echo "$combined_patch" | jq '.'
        return 0
    else
        log_debug "Applying combined patch to target $target_name"
        if kubectl patch target "$target_name" -n "$NAMESPACE" --type='json' -p="$combined_patch"; then
            log_info "Successfully added staging bindings to target $target_name"
            return 0
        else
            log_error "Failed to update target $target_name"
            return 1
        fi
    fi
}

# ============================================================================
# STAGE 2: MONITOR STAGING RESULTS
# ============================================================================

# Parse staging result from target CR
parse_staging_result_from_target() {
    local target_name="$1"
    
    local target_json
    target_json=$(kubectl get target "$target_name" -n "$NAMESPACE" -o json 2>/dev/null)
    
    if [[ $? -ne 0 ]]; then
        log_error "Failed to get target $target_name"
        return 1
    fi
    
    # Check overall target status first
    local target_status
    target_status=$(echo "$target_json" | jq -r '.status.status // .status.provisioningStatus.status // "Unknown"')
    
    # Extract staging result from target status
    local staging_result
    staging_result=$(echo "$target_json" | jq -r '.status.properties.stagingResult // .status.stagingResult // .spec.properties.stagingResult // null')
    
    # If no staging result found, try component statuses
    if [[ "$staging_result" == "null" || -z "$staging_result" ]]; then
        local component_statuses
        component_statuses=$(echo "$target_json" | jq -r '.status.targetStatuses[]?.componentStatuses // empty')
        
        if [[ -n "$component_statuses" ]]; then
            local success="false"
            local images_to_be_staged="{}"
            local staged_images="[]"
            
            while IFS= read -r component; do
                local comp_name
                comp_name=$(echo "$component" | jq -r '.name // empty')
                
                if [[ "$comp_name" == "staging-component" ]]; then
                    local status_str
                    status_str=$(echo "$component" | jq -r '.status // empty')
                    
                    # Check for success indicators in the status message
                    local has_success_message=false
                    if [[ "$status_str" =~ "Successfully checked the download status" ]] && [[ "$status_str" =~ "fully downloaded" ]]; then
                        has_success_message=true
                        # Use stderr for debug to avoid contaminating stdout
                        log_debug "Found success message in component status for $target_name" >&2
                    fi
                    
                    # Extract JSON part if present
                    if [[ -n "$status_str" && "$status_str" =~ \{.*\} ]]; then
                        local json_part
                        json_part=$(echo "$status_str" | sed 's/^[^{]*{/{/' | sed 's/\\"/"/g')
                        
                        if [[ -n "$json_part" ]]; then
                            local comp_success
                            comp_success=$(echo "$json_part" | jq -r '.Success // empty' 2>/dev/null)
                            
                            # Check for Message field with success indicators
                            local comp_message
                            comp_message=$(echo "$json_part" | jq -r '.Message // empty' 2>/dev/null)
                            
                            local has_success_in_message=false
                            if [[ "$comp_message" =~ "Successfully checked the download status" ]] && [[ "$comp_message" =~ "fully downloaded" ]]; then
                                has_success_in_message=true
                                # Use stderr for debug to avoid contaminating stdout
                                log_debug "Found success message in Message field for $target_name: $comp_message" >&2
                            fi
                            
                            # Set success based on multiple criteria:
                            # 1. Explicit Success flag in JSON
                            # 2. Success message in component status AND target is Succeeded
                            # 3. Success message in Message field AND target is Succeeded
                            # 4. Success message AND target is OK/OK -
                            if [[ "$comp_success" == "true" ]]; then
                                success="true"
                                # Use stderr for debug to avoid contaminating stdout
                                log_debug "Setting success=true based on Success flag for $target_name" >&2
                            elif [[ "$has_success_message" == "true" ]] || [[ "$has_success_in_message" == "true" ]]; then
                                if [[ "$target_status" == "Succeeded" ]] || [[ "$target_status" == "OK" ]] || [[ "$target_status" =~ ^"OK ".* ]] || [[ "$target_status" == "Updated" ]]; then
                                    success="true"
                                    # Use stderr for debug to avoid contaminating stdout
                                    log_debug "Setting success=true based on success message and target status ($target_status) for $target_name" >&2
                                fi
                            fi
                            
                            local comp_images_to_stage
                            comp_images_to_stage=$(echo "$json_part" | jq -r '.ImagesToBeStaged // empty' 2>/dev/null)
                            
                            if [[ -n "$comp_images_to_stage" && "$comp_images_to_stage" != "null" ]]; then
                                images_to_be_staged=$(echo "$images_to_be_staged $comp_images_to_stage" | jq -s 'add // {}')
                            fi
                            
                            local comp_staged_images
                            comp_staged_images=$(echo "$json_part" | jq -r '.StagedImages // empty' 2>/dev/null)
                            
                            if [[ -n "$comp_staged_images" && "$comp_staged_images" != "null" ]]; then
                                staged_images=$(echo "$staged_images $comp_staged_images" | jq -s 'add | unique // []')
                            fi
                        fi
                    else
                        # Even without JSON part, if we have success message and good target status, mark as success
                        if [[ "$has_success_message" == "true" ]]; then
                            if [[ "$target_status" == "Succeeded" ]] || [[ "$target_status" == "OK" ]] || [[ "$target_status" =~ ^"OK ".* ]] || [[ "$target_status" == "Updated" ]]; then
                                success="true"
                                # Use stderr for debug to avoid contaminating stdout
                                log_debug "Setting success=true based on success message and target status ($target_status) for $target_name (no JSON part)" >&2
                            fi
                        fi
                    fi
                    break
                fi
            done <<< "$(echo "$component_statuses" | jq -c '.[]')"
            
            # Use stderr for debug to avoid contaminating stdout
            log_debug "Final parsed success flag for $target_name: $success" >&2
            
            staging_result=$(jq -nc --arg success "$success" --argjson images_to_be_staged "$images_to_be_staged" --argjson staged_images "$staged_images" '{
                "success": ($success == "true"),
                "imagesToBeStaged": $images_to_be_staged,
                "stagedImages": $staged_images
            }')
        fi
        
        if [[ "$staging_result" == "null" || -z "$staging_result" ]]; then
            echo "{\"success\": false, \"imagesToBeStaged\": {}, \"stagedImages\": []}"
            return 0
        fi
    fi
    
    echo "$staging_result" | jq -c '.'
}

# Check if staging is complete for a solution
check_solution_staging_complete() {
    local staging_result="$1"
    local solution_name="$2"
    
    log_debug "check_solution_staging_complete received staging_result: $staging_result"
    
    local success
    success=$(printf '%s\n' "$staging_result" | jq -r '.success // false' 2>/dev/null)
    
    if [[ $? -ne 0 ]]; then
        log_debug "jq parsing failed for staging_result, attempting to clean and retry"
        # Try to clean up the JSON string and retry
        staging_result=$(printf '%s\n' "$staging_result" | tr -d '\r' | sed 's/\\"/"/g')
        success=$(printf '%s\n' "$staging_result" | jq -r '.success // false' 2>/dev/null)
        if [[ $? -ne 0 ]]; then
            log_debug "jq parsing still failed after cleanup, marking as false"
            success="false"
        fi
    fi
    
    log_debug "Extracted success flag from staging_result: '$success' for solution $solution_name"
    
    if [[ "$success" != "true" ]]; then
        log_debug "Staging result success flag is false for solution $solution_name"
        return 1
    fi
    
    # Get the required images for this solution from the original input IMAGE_LIST
    local required_images_for_solution
    required_images_for_solution=$(echo "$IMAGE_LIST" | jq -r ".[\"$solution_name\"] // []")
    
    if [[ "$required_images_for_solution" == "[]" || "$required_images_for_solution" == "null" ]]; then
        log_debug "No images required for solution $solution_name in input image list"
        return 0
    fi
    
    # Get the list of actually staged images
    local staged_images
    staged_images=$(printf '%s\n' "$staging_result" | jq -r '.stagedImages // []' 2>/dev/null)
    
    if [[ $? -ne 0 ]]; then
        log_debug "Failed to parse stagedImages from staging_result, marking as empty"
        staged_images="[]"
    fi
    
    if [[ "$staged_images" == "[]" || "$staged_images" == "null" ]]; then
        log_debug "No images staged yet. Continuing staging process."
        return 1
    fi
    
    # Convert to space-separated lists for comparison
    local required_images_list
    required_images_list=$(printf '%s\n' "$required_images_for_solution" | jq -r '.[] // empty' 2>/dev/null | tr '\n' ' ')
    
    local staged_images_list
    staged_images_list=$(printf '%s\n' "$staged_images" | jq -r '.[] // empty' 2>/dev/null | tr '\n' ' ')
    
    log_debug "Solution $solution_name - Required images: $required_images_list"
    log_debug "Solution $solution_name - Staged images: $staged_images_list"
    
    # Check if ALL required images for this solution are in the staged images list
    local all_staged=true
    for required_image in $required_images_list; do
        if [[ ! " $staged_images_list " =~ " $required_image " ]]; then
            log_debug "Required image $required_image for solution $solution_name not yet staged"
            all_staged=false
            break
        fi
    done
    
    if [[ "$all_staged" == "true" ]]; then
        log_info "All required images staged successfully for solution $solution_name"
        return 0
    else
        log_debug "Not all required images staged for solution $solution_name"
        return 1
    fi
}

# Monitor staging results for a target
monitor_target_staging() {
    local target_name="$1"
    
    log_info "STAGE 2: Monitoring staging results for target: $target_name"
    log_info "Monitor timeout set to: $MONITOR_TIMEOUT_MINUTES minutes (maximum)"
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY-RUN: Would monitor staging for target $target_name"
        return 0
    fi
    
    if ! target_exists "$target_name"; then
        log_error "Target $target_name not found in namespace $NAMESPACE"
        return 1
    fi
    
    # Enforce maximum 30-minute timeout
    if [[ $MONITOR_TIMEOUT_MINUTES -gt 30 ]]; then
        log_warn "Timeout of $MONITOR_TIMEOUT_MINUTES minutes exceeds maximum of 30 minutes. Setting to 30 minutes."
        MONITOR_TIMEOUT_MINUTES=30
    fi
    
    local start_time=$(date +%s)
    local timeout_seconds=$((MONITOR_TIMEOUT_MINUTES * 60))
    local retry_count=0
    local current_interval=$RETRY_INTERVAL_SECONDS
    
    log_info "Starting monitoring loop with $timeout_seconds second timeout (${MONITOR_TIMEOUT_MINUTES} minutes)"
    
    while true; do
        local current_time=$(date +%s)
        local elapsed_time=$((current_time - start_time))
        
        if [[ $elapsed_time -ge $timeout_seconds ]]; then
            log_error "Timeout reached ($MONITOR_TIMEOUT_MINUTES minutes) for target $target_name"
            
            # Get final status and report incomplete solutions
            local final_target_json
            final_target_json=$(kubectl get target "$target_name" -n "$NAMESPACE" -o json 2>/dev/null)
            
            if [[ $? -eq 0 ]]; then
                local final_target_status
                final_target_status=$(echo "$final_target_json" | jq -r '.status.status // .status.provisioningStatus.status // "Unknown"')
                
                log_error "Final target status: $final_target_status"
                
                if [[ "$final_target_status" == "Succeeded" ]]; then
                    # Check for incomplete staging in component status
                    local component_statuses
                    component_statuses=$(echo "$final_target_json" | jq -r '.status.targetStatuses[]?.componentStatuses // empty')
                    
                    if [[ -n "$component_statuses" ]]; then
                        while IFS= read -r component; do
                            local comp_name
                            comp_name=$(echo "$component" | jq -r '.name // empty')
                            
                            if [[ "$comp_name" == "staging-component" ]]; then
                                local status_str
                                status_str=$(echo "$component" | jq -r '.status // empty')
                                
                                if [[ "$status_str" =~ "Not all images were fully downloaded" ]]; then
                                    log_error "TIMEOUT ANALYSIS: Target shows 'Succeeded' but staging is incomplete"
                                    
                                    # Extract and analyze incomplete solutions
                                    if [[ "$status_str" =~ \{.*\} ]]; then
                                        local json_part
                                        json_part=$(echo "$status_str" | sed 's/^[^{]*{/{/')
                                        
                                        if [[ -n "$json_part" ]]; then
                                            local staged_images
                                            staged_images=$(echo "$json_part" | jq -r '.StagedImages // []' 2>/dev/null)
                                            
                                            log_error "Currently staged images: $staged_images"
                                            
                                            # Check each solution from input for completeness
                                            IFS=',' read -ra SOLUTION_ARRAY <<< "$SOLUTION_IMAGES"
                                            for solution in "${SOLUTION_ARRAY[@]}"; do
                                                solution=$(echo "$solution" | xargs)
                                                
                                                local required_images_for_solution
                                                required_images_for_solution=$(echo "$IMAGE_LIST" | jq -r ".[\"$solution\"] // []")
                                                
                                                if [[ "$required_images_for_solution" != "[]" && "$required_images_for_solution" != "null" ]]; then
                                                    local required_images_list
                                                    required_images_list=$(echo "$required_images_for_solution" | jq -r '.[] // empty' | tr '\n' ' ')
                                                    
                                                    local missing_images=()
                                                    for required_image in $required_images_list; do
                                                        if ! echo "$staged_images" | jq -e ". | contains([\"$required_image\"])" >/dev/null 2>&1; then
                                                            missing_images+=("$required_image")
                                                        fi
                                                    done
                                                    
                                                    if [[ ${#missing_images[@]} -gt 0 ]]; then
                                                        log_error "INCOMPLETE SOLUTION: '$solution' - missing images: ${missing_images[*]}"
                                                    else
                                                        log_info "COMPLETE SOLUTION: '$solution' - all images staged"
                                                    fi
                                                fi
                                            done
                                        fi
                                    fi
                                fi
                                break
                            fi
                        done <<< "$(echo "$component_statuses" | jq -c '.[]')"
                    fi
                fi
            fi
            
            return 1
        fi
        
        retry_count=$((retry_count + 1))
        log_debug "Attempt $retry_count for target $target_name"
        
        # Get target status
        local target_json
        target_json=$(kubectl get target "$target_name" -n "$NAMESPACE" -o json 2>/dev/null)
        
        if [[ $? -eq 0 ]]; then
            local target_status
            target_status=$(echo "$target_json" | jq -r '.status.status // .status.provisioningStatus.status // "Unknown"')
            
            log_debug "Target $target_name status: $target_status (attempt $retry_count)"
            
            if [[ "$target_status" == "Failed" ]]; then
                # Extract error information from the CR
                local error_message
                error_message=$(echo "$target_json" | jq -r '.status.provisioningStatus.error.message // .status.error.message // "No error message available"')
                local error_code
                error_code=$(echo "$target_json" | jq -r '.status.provisioningStatus.error.code // .status.error.code // "Unknown Error"')
                local error_target
                error_target=$(echo "$target_json" | jq -r '.status.provisioningStatus.error.target // .status.error.target // ""')
                
                # Also check target statuses for additional error info
                local target_error_status
                target_error_status=$(echo "$target_json" | jq -r '.status.targetStatuses[]?.status // empty' | head -1)
                
                log_error "Target $target_name status is Failed"
                log_error "Error Code: $error_code"
                log_error "Error Message: $error_message"
                if [[ -n "$error_target" ]]; then
                    log_error "Error Target: $error_target"
                fi
                if [[ -n "$target_error_status" ]]; then
                    log_error "Target Status: $target_error_status"
                fi
                return 1
            elif [[ "$target_status" == "Succeeded" ]]; then
                # Check component status for explicit incomplete staging message
                local component_statuses
                component_statuses=$(echo "$target_json" | jq -r '.status.targetStatuses[]?.componentStatuses // empty')
                
                local explicit_incomplete=false
                
                if [[ -n "$component_statuses" ]]; then
                    while IFS= read -r component; do
                        local comp_name
                        comp_name=$(echo "$component" | jq -r '.name // empty')
                        
                        if [[ "$comp_name" == "staging-component" ]]; then
                            local status_str
                            status_str=$(echo "$component" | jq -r '.status // empty')
                            
                            # If message explicitly says not all images downloaded, just continue monitoring till timeout
                            if [[ "$status_str" =~ "Not all images were fully downloaded" ]]; then
                                log_info "Target $target_name: 'Not all images were fully downloaded' - continuing monitoring until timeout"
                                log_debug "Status message: $status_str"
                                explicit_incomplete=true
                                break
                            fi
                        fi
                    done <<< "$(echo "$component_statuses" | jq -c '.[]')"
                fi
                
                # If explicit incomplete message found, just continue monitoring
                if [[ "$explicit_incomplete" == "true" ]]; then
                    log_debug "Target $target_name: Continuing monitoring due to explicit incomplete message"
                else
                    # No explicit incomplete message, verify completion normally
                    local staging_result
                    staging_result=$(parse_staging_result_from_target "$target_name")
                    
                    log_debug "monitor_target_staging received staging_result from parse_staging_result_from_target: $staging_result"
                    
                    if [[ $? -eq 0 ]]; then
                        IFS=',' read -ra SOLUTION_ARRAY <<< "$SOLUTION_IMAGES"
                        local all_solutions_complete=true
                        
                        for solution in "${SOLUTION_ARRAY[@]}"; do
                            solution=$(echo "$solution" | xargs)
                            
                            log_debug "Verifying complete staging for solution: '$solution'"
                            
                            # Validate that the solution name exists in IMAGE_LIST before proceeding
                            local solution_exists_check
                            solution_exists_check=$(echo "$IMAGE_LIST" | jq -e "has(\"$solution\")" 2>/dev/null)
                            
                            if [[ "$solution_exists_check" != "true" ]]; then
                                log_debug "Solution '$solution' not found in IMAGE_LIST, skipping check"
                                continue
                            fi
                            
                            # Check solution staging complete inline
                            local success
                            success=$(printf '%s\n' "$staging_result" | jq -r '.success // false' 2>/dev/null)
                            
                            if [[ $? -ne 0 ]]; then
                                log_debug "jq parsing failed for staging_result, marking as false"
                                success="false"
                            fi
                            
                            log_debug "Extracted success flag from staging_result: '$success' for solution $solution"
                            
                            if [[ "$success" != "true" ]]; then
                                log_debug "Staging result success flag is false for solution $solution"
                                all_solutions_complete=false
                                break
                            fi
                            
                            # Get the required images for this solution from the original input IMAGE_LIST
                            local required_images_for_solution
                            required_images_for_solution=$(echo "$IMAGE_LIST" | jq -r ".[\"$solution\"] // []")
                            
                            if [[ "$required_images_for_solution" == "[]" || "$required_images_for_solution" == "null" ]]; then
                                log_debug "No images required for solution $solution in input image list"
                                continue
                            fi
                            
                            # Get the list of actually staged images
                            local staged_images
                            staged_images=$(printf '%s\n' "$staging_result" | jq -r '.stagedImages // []' 2>/dev/null)
                            
                            if [[ $? -ne 0 ]]; then
                                log_debug "Failed to parse stagedImages from staging_result, marking as empty"
                                staged_images="[]"
                            fi
                            
                            if [[ "$staged_images" == "[]" || "$staged_images" == "null" ]]; then
                                log_debug "No images staged yet for solution $solution. Continuing staging process."
                                all_solutions_complete=false
                                break
                            fi
                            
                            # Convert to space-separated lists for comparison
                            local required_images_list
                            required_images_list=$(printf '%s\n' "$required_images_for_solution" | jq -r '.[] // empty' 2>/dev/null | tr '\n' ' ')
                            
                            local staged_images_list
                            staged_images_list=$(printf '%s\n' "$staged_images" | jq -r '.[] // empty' 2>/dev/null | tr '\n' ' ')
                            
                            log_debug "Solution $solution - Required images: $required_images_list"
                            log_debug "Solution $solution - Staged images: $staged_images_list"
                            
                            # Check if ALL required images for this solution are in the staged images list
                            local all_staged=true
                            for required_image in $required_images_list; do
                                if [[ ! " $staged_images_list " =~ " $required_image " ]]; then
                                    log_debug "Required image $required_image for solution $solution not yet staged"
                                    all_staged=false
                                    break
                                fi
                            done
                            
                            if [[ "$all_staged" == "true" ]]; then
                                log_info "All required images staged successfully for solution $solution"
                            else
                                log_debug "Not all required images staged for solution $solution"
                                all_solutions_complete=false
                                break
                            fi
                        done
                        
                        # Only declare success if ALL solutions are completely staged
                        if [[ "$all_solutions_complete" == "true" ]]; then
                            log_info "Target $target_name status is 'Succeeded' and ALL images are fully downloaded - staging completed successfully"
                            return 0
                        else
                            log_debug "Target $target_name status is 'Succeeded' but not all solutions are complete - continuing monitoring"
                        fi
                    else
                        log_debug "Failed to parse staging result for target $target_name, continuing monitoring"
                    fi
                fi
            fi
        fi
        
        local next_interval=$((current_interval * 2))
        if [[ $next_interval -gt $MAX_RETRY_INTERVAL_SECONDS ]]; then
            next_interval=$MAX_RETRY_INTERVAL_SECONDS
        fi
        
        log_debug "Retrying staging check for target $target_name after $current_interval seconds. Attempt $retry_count."
        sleep "$current_interval"
        current_interval=$next_interval
    done
}

# ============================================================================
# STAGE 3: CLEANUP STAGING COMPONENTS - FIXED VERSION
# ============================================================================

# FIXED: Cleanup staging components from target
# This version removes ALL solutions from the staging component imageList,
# not just the ones that were in the original input
cleanup_target() {
    local target_name="$1"

    log_info "STAGE 3: Cleaning up staging components for target: $target_name"

    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY-RUN: Would cleanup staging components for target $target_name"
        return 0
    fi

    local target_json
    kubectl config use-context lyaks3
    target_json=$(kubectl get target "$target_name" -n "$NAMESPACE" -o json)
    
    if [[ $? -ne 0 ]]; then
        log_error "Failed to get target $target_name"
        return 1
    fi

    # Extract the current imageList from the target
    local image_list
    image_list=$(echo "$target_json" | jq -r ".spec.components[] | select(.name == \"staging-component\") | .properties.imageList")
    
    if [[ -z "$image_list" || "$image_list" == "null" ]]; then
        log_info "No staging components found for target $target_name. Skipping cleanup."
        return 0
    fi

    # FIXED: Get ALL existing solution names from the current imageList in the target
    # This ensures we remove ALL solutions, regardless of what was in the original input
    local existing_solutions
    existing_solutions=($(echo "$image_list" | jq -r 'keys[]'))
    
    log_info "Current imageList contains solutions: ${existing_solutions[*]}"
    
    # FIXED: Remove ALL solutions from imageList (complete cleanup)
    if [[ ${#existing_solutions[@]} -gt 0 ]]; then
        log_info "Removing ALL solutions (${existing_solutions[*]}) from imageList in target $target_name"
        
        # Set imageList to empty object
        local updated_image_list="{}"
        
        # Update target JSON with empty imageList
        target_json=$(echo "$target_json" | jq ".spec.components[] |= if .name == \"staging-component\" then .properties.imageList = {} else . end")
        
        log_info "Successfully cleared all solutions from imageList for target $target_name"
    else
        log_info "No solutions found in imageList for target $target_name"
        updated_image_list="$image_list"
    fi

    # Remove staging component completely since imageList is now empty
    log_info "Removing staging component from target $target_name as imageList is empty"
    target_json=$(echo "$target_json" | jq "del(.spec.components[] | select(.name == \"staging-component\"))")

    # Reset reconciliation policy since no images are staged
    log_info "Resetting reconciliation policy for target $target_name"
    target_json=$(echo "$target_json" | jq "del(.spec.reconciliationPolicy)")

    # Apply the updated target JSON
    log_info "Applying cleanup changes to target $target_name"
    if echo "$target_json" | kubectl apply -f -; then
        log_info "Successfully cleaned up target $target_name"
        
        # FIXED: Add verification step
        log_info "Verifying cleanup completion for target $target_name"
        sleep 2  # Give kubernetes a moment to update
        
        local verification_json
        verification_json=$(kubectl get target "$target_name" -n "$NAMESPACE" -o json 2>/dev/null)
        
        if [[ $? -eq 0 ]]; then
            local remaining_solutions
            remaining_solutions=$(echo "$verification_json" | jq -r ".spec.components[]? | select(.name == \"staging-component\") | .properties.imageList | keys[]?" 2>/dev/null)
            
            if [[ -n "$remaining_solutions" ]]; then
                log_error "CLEANUP VERIFICATION FAILED: Solutions still remain in target $target_name: $remaining_solutions"
                return 1
            else
                log_info "CLEANUP VERIFICATION PASSED: No staging solutions remain in target $target_name"
            fi
        fi
        
        return 0
    else
        log_error "Failed to apply cleanup changes to target $target_name"
        return 1
    fi
}

# ============================================================================
# MAIN ORCHESTRATION FUNCTION
# ============================================================================

# Check if a step should be executed
should_execute_step() {
    local step="$1"
    [[ ",$STEPS," =~ ",$step," ]]
}

# Process a single target through selected stages
process_target_workflow() {
    local target_name="$1"
    
    log_info "Starting staging workflow for target: $target_name (steps: $STEPS)"
    echo "========================================"
    
    # Stage 1: Add staging bindings
    if should_execute_step "1"; then
        if ! add_bindings_to_target "$target_name"; then
            log_error "Stage 1 failed for target $target_name"
            return 1
        fi
    else
        log_info "Skipping Stage 1 (add staging bindings) as per steps configuration"
    fi
    
    # Stage 2: Monitor staging results
    if should_execute_step "2"; then
        if ! monitor_target_staging "$target_name"; then
            log_error "Stage 2 failed for target $target_name"
            return 1
        fi
    else
        log_info "Skipping Stage 2 (monitor staging results) as per steps configuration"
    fi
    
    # Stage 3: Cleanup staging components
    if should_execute_step "3"; then
        if ! cleanup_target "$target_name"; then
            log_error "Stage 3 failed for target $target_name"
            return 1
        fi
    else
        log_info "Skipping Stage 3 (cleanup staging components) as per steps configuration"
    fi
    
    log_info "Staging workflow completed successfully for target: $target_name"
    echo "========================================"
    return 0
}

# Global variables to track solution status across targets
SUCCEEDED_SOLUTIONS=""
FAILED_SOLUTIONS=""

# Analyze and track solution status for a target
analyze_solution_status_for_target() {
    local target_name="$1"
    
    log_info "========== SOLUTION ANALYSIS DEBUG START =========="
    log_info "Analyzing solution status for target: $target_name"
    log_info "Current SOLUTION_IMAGES: '$SOLUTION_IMAGES'"
    log_info "Current IMAGE_LIST: '$IMAGE_LIST'"
    log_info "Current SUCCEEDED_SOLUTIONS before analysis: '$SUCCEEDED_SOLUTIONS'"
    log_info "Current FAILED_SOLUTIONS before analysis: '$FAILED_SOLUTIONS'"
    
    # Get target JSON
    local target_json
    target_json=$(kubectl get target "$target_name" -n "$NAMESPACE" -o json 2>/dev/null)
    
    if [[ $? -ne 0 ]]; then
        log_info "Target $target_name not found or not accessible for solution status analysis"
        # If target doesn't exist, mark all solutions as failed
        IFS=',' read -ra SOLUTION_ARRAY <<< "$SOLUTION_IMAGES"
        log_info "SOLUTION_ARRAY length: ${#SOLUTION_ARRAY[@]}"
        for i in "${!SOLUTION_ARRAY[@]}"; do
            local solution="${SOLUTION_ARRAY[$i]}"
            solution=$(echo "$solution" | xargs)
            log_info "Processing solution $i: '$solution'"
            if [[ -n "$solution" ]]; then
                if [[ -z "$FAILED_SOLUTIONS" ]]; then
                    FAILED_SOLUTIONS="$solution"
                else
                    FAILED_SOLUTIONS="$FAILED_SOLUTIONS,$solution"
                fi
                log_info "Solution '$solution' marked as failed (target not accessible)"
                log_info "FAILED_SOLUTIONS now: '$FAILED_SOLUTIONS'"
            fi
        done
        log_info "========== SOLUTION ANALYSIS DEBUG END (TARGET NOT FOUND) =========="
        return 1
    fi
    
    log_info "Successfully retrieved target $target_name for analysis"
    
    # Check overall target status first
    local target_status
    target_status=$(echo "$target_json" | jq -r '.status.status // .status.provisioningStatus.status // "Unknown"')
    log_info "Target $target_name overall status: $target_status"
    
    # Check component status for staging results
    local component_statuses
    component_statuses=$(echo "$target_json" | jq -r '.status.targetStatuses[]?.componentStatuses // empty')
    
    log_info "Component statuses retrieved: '$component_statuses'"
    
    if [[ -n "$component_statuses" ]]; then
        log_info "Found component statuses for target $target_name"
        local found_staging_component=false
        
        while IFS= read -r component; do
            local comp_name
            comp_name=$(echo "$component" | jq -r '.name // empty')
            
            log_info "Checking component: '$comp_name'"
            
            if [[ "$comp_name" == "staging-component" ]]; then
                found_staging_component=true
                log_info "Found staging-component for target $target_name"
                
                local status_str
                status_str=$(echo "$component" | jq -r '.status // empty')
                
                log_info "Staging component status: '$status_str'"
                
                # Extract JSON part from status string
                if [[ "$status_str" =~ \{.*\} ]]; then
                    local json_part
                    json_part=$(echo "$status_str" | sed 's/^[^{]*{/{/')
                    
                    log_info "Extracted JSON part: '$json_part'"
                    
                    if [[ -n "$json_part" ]]; then
                        # Parse the JSON to get staging information
                        local staged_images
                        staged_images=$(echo "$json_part" | jq -r '.StagedImages // []' 2>/dev/null)
                        
                        local images_to_be_staged
                        images_to_be_staged=$(echo "$json_part" | jq -r '.ImagesToBeStaged // {}' 2>/dev/null)
                        
                        local success_flag
                        success_flag=$(echo "$json_part" | jq -r '.Success // false' 2>/dev/null)
                        
                        log_info "Staged images for target $target_name: '$staged_images'"
                        log_info "Images to be staged for target $target_name: '$images_to_be_staged'"
                        log_info "Success flag for target $target_name: '$success_flag'"
                        
                        # Check for success message in status
                        local is_success_message=false
                        if [[ "$status_str" =~ "Successfully checked the download status" ]] && [[ "$status_str" =~ "fully downloaded" ]]; then
                            is_success_message=true
                            log_info "Found success message in component status"
                        fi
                        
                        # Determine success based on multiple criteria
                        local is_successful=false
                        if [[ "$target_status" == "Succeeded" ]] || [[ "$target_status" == "OK" ]] || [[ "$target_status" =~ ^"OK ".* ]] || [[ "$target_status" == "Updated" ]]; then
                            if [[ "$is_success_message" == "true" ]] || [[ "$success_flag" == "true" ]]; then
                                is_successful=true
                                log_info "Target $target_name determined as successful based on status and success indicators"
                            fi
                        fi
                        
                        # Check each solution from input IMAGE_LIST
                        IFS=',' read -ra SOLUTION_ARRAY <<< "$SOLUTION_IMAGES"
                        log_info "SOLUTION_ARRAY length: ${#SOLUTION_ARRAY[@]}"
                        log_info "SOLUTION_ARRAY contents: [${SOLUTION_ARRAY[*]}]"
                        
                        for i in "${!SOLUTION_ARRAY[@]}"; do
                            local solution="${SOLUTION_ARRAY[$i]}"
                            solution=$(echo "$solution" | xargs)
                            
                            log_info "Processing solution $i: '$solution'"
                            
                            if [[ -n "$solution" ]]; then
                                log_info "Analyzing solution: '$solution'"
                                
                                # Check if solution exists in ImagesToBeStaged
                                local solution_in_staging=false
                                if echo "$images_to_be_staged" | jq -e "has(\"$solution\")" >/dev/null 2>&1; then
                                    solution_in_staging=true
                                    log_info "Solution '$solution' found in ImagesToBeStaged"
                                else
                                    log_info "Solution '$solution' NOT found in ImagesToBeStaged"
                                fi
                                
                                # Get required images for this solution from input
                                local required_images_for_solution
                                required_images_for_solution=$(echo "$IMAGE_LIST" | jq -r ".[\"$solution\"] // []")
                                
                                log_info "Required images for solution '$solution': '$required_images_for_solution'"
                                
                                if [[ "$required_images_for_solution" != "[]" && "$required_images_for_solution" != "null" ]]; then
                                    local required_images_list
                                    required_images_list=$(echo "$required_images_for_solution" | jq -r '.[] // empty' | tr '\n' ' ')
                                    
                                    log_info "Required images list for solution '$solution': '$required_images_list'"
                                    
                                    # Check if all required images for this solution are staged
                                    local all_images_staged=true
                                    local missing_images=()
                                    
                                    for required_image in $required_images_list; do
                                        log_info "Checking if '$required_image' is in staged images"
                                        if ! echo "$staged_images" | jq -e ". | contains([\"$required_image\"])" >/dev/null 2>&1; then
                                            log_info "Required image '$required_image' NOT found in staged images"
                                            all_images_staged=false
                                            missing_images+=("$required_image")
                                        else
                                            log_info "Required image '$required_image' FOUND in staged images"
                                        fi
                                    done
                                    
                                    # Determine if solution succeeded based on multiple criteria:
                                    # 1. Target is successful AND solution is in ImagesToBeStaged AND all images are staged
                                    # 2. OR success message indicates completion and solution was included
                                    local solution_succeeded=false
                                    
                                    if [[ "$is_successful" == "true" && "$solution_in_staging" == "true" && "$all_images_staged" == "true" ]]; then
                                        solution_succeeded=true
                                        log_info "Solution '$solution' succeeded: target successful + in staging + all images staged"
                                    elif [[ "$is_success_message" == "true" && "$solution_in_staging" == "true" ]]; then
                                        # Even if not all images appear staged, if we have success message and solution was included, consider it successful
                                        solution_succeeded=true
                                        log_info "Solution '$solution' succeeded: success message + in staging (trusting success message over image check)"
                                    else
                                        log_info "Solution '$solution' failed: is_successful=$is_successful, solution_in_staging=$solution_in_staging, all_images_staged=$all_images_staged, missing_images=[${missing_images[*]}]"
                                    fi
                                    
                                    # Add to appropriate list
                                    if [[ "$solution_succeeded" == "true" ]]; then
                                        if [[ -z "$SUCCEEDED_SOLUTIONS" ]]; then
                                            SUCCEEDED_SOLUTIONS="$solution"
                                        else
                                            SUCCEEDED_SOLUTIONS="$SUCCEEDED_SOLUTIONS,$solution"
                                        fi
                                        log_info "Solution '$solution' marked as SUCCEEDED for target $target_name"
                                        log_info "SUCCEEDED_SOLUTIONS now: '$SUCCEEDED_SOLUTIONS'"
                                    else
                                        if [[ -z "$FAILED_SOLUTIONS" ]]; then
                                            FAILED_SOLUTIONS="$solution"
                                        else
                                            FAILED_SOLUTIONS="$FAILED_SOLUTIONS,$solution"
                                        fi
                                        log_info "Solution '$solution' marked as FAILED for target $target_name"
                                        log_info "FAILED_SOLUTIONS now: '$FAILED_SOLUTIONS'"
                                    fi
                                else
                                    log_info "No required images found for solution '$solution' in IMAGE_LIST - marking as failed"
                                    if [[ -z "$FAILED_SOLUTIONS" ]]; then
                                        FAILED_SOLUTIONS="$solution"
                                    else
                                        FAILED_SOLUTIONS="$FAILED_SOLUTIONS,$solution"
                                    fi
                                    log_info "FAILED_SOLUTIONS now: '$FAILED_SOLUTIONS'"
                                fi
                            else
                                log_info "Empty solution name at index $i, skipping"
                            fi
                        done
                    else
                        log_info "No JSON part found in staging component status - marking all solutions as failed"
                        # Mark all solutions as failed
                        IFS=',' read -ra SOLUTION_ARRAY <<< "$SOLUTION_IMAGES"
                        for i in "${!SOLUTION_ARRAY[@]}"; do
                            local solution="${SOLUTION_ARRAY[$i]}"
                            solution=$(echo "$solution" | xargs)
                            if [[ -n "$solution" ]]; then
                                if [[ -z "$FAILED_SOLUTIONS" ]]; then
                                    FAILED_SOLUTIONS="$solution"
                                else
                                    FAILED_SOLUTIONS="$FAILED_SOLUTIONS,$solution"
                                fi
                                log_info "Solution '$solution' marked as failed (no JSON in component status)"
                            fi
                        done
                    fi
                else
                    log_info "No JSON structure found in staging component status - marking all solutions as failed"
                    # Mark all solutions as failed
                    IFS=',' read -ra SOLUTION_ARRAY <<< "$SOLUTION_IMAGES"
                    for i in "${!SOLUTION_ARRAY[@]}"; do
                        local solution="${SOLUTION_ARRAY[$i]}"
                        solution=$(echo "$solution" | xargs)
                        if [[ -n "$solution" ]]; then
                            if [[ -z "$FAILED_SOLUTIONS" ]]; then
                                FAILED_SOLUTIONS="$solution"
                            else
                                FAILED_SOLUTIONS="$FAILED_SOLUTIONS,$solution"
                            fi
                            log_info "Solution '$solution' marked as failed (no JSON structure)"
                        fi
                    done
                fi
                break
            fi
        done <<< "$(echo "$component_statuses" | jq -c '.[]')"
        
        if [[ "$found_staging_component" == "false" ]]; then
            log_info "No staging-component found in target $target_name - marking all solutions as failed"
            # Mark all solutions as failed if no staging component found
            IFS=',' read -ra SOLUTION_ARRAY <<< "$SOLUTION_IMAGES"
            log_info "SOLUTION_ARRAY length: ${#SOLUTION_ARRAY[@]}"
            for i in "${!SOLUTION_ARRAY[@]}"; do
                local solution="${SOLUTION_ARRAY[$i]}"
                solution=$(echo "$solution" | xargs)
                log_info "Processing solution $i: '$solution'"
                if [[ -n "$solution" ]]; then
                    if [[ -z "$FAILED_SOLUTIONS" ]]; then
                        FAILED_SOLUTIONS="$solution"
                    else
                        FAILED_SOLUTIONS="$FAILED_SOLUTIONS,$solution"
                    fi
                    log_info "Solution '$solution' marked as failed (no staging component)"
                    log_info "FAILED_SOLUTIONS now: '$FAILED_SOLUTIONS'"
                fi
            done
        fi
    else
        log_info "No component statuses found for target $target_name - marking all solutions as failed"
        # Mark all solutions as failed if no component statuses found
        IFS=',' read -ra SOLUTION_ARRAY <<< "$SOLUTION_IMAGES"
        log_info "SOLUTION_ARRAY length: ${#SOLUTION_ARRAY[@]}"
        for i in "${!SOLUTION_ARRAY[@]}"; do
            local solution="${SOLUTION_ARRAY[$i]}"
            solution=$(echo "$solution" | xargs)
            log_info "Processing solution $i: '$solution'"
            if [[ -n "$solution" ]]; then
                if [[ -z "$FAILED_SOLUTIONS" ]]; then
                    FAILED_SOLUTIONS="$solution"
                else
                    FAILED_SOLUTIONS="$FAILED_SOLUTIONS,$solution"
                fi
                log_info "Solution '$solution' marked as failed (no component statuses)"
                log_info "FAILED_SOLUTIONS now: '$FAILED_SOLUTIONS'"
            fi
        done
    fi
    
    log_info "Final SUCCEEDED_SOLUTIONS after analysis: '$SUCCEEDED_SOLUTIONS'"
    log_info "Final FAILED_SOLUTIONS after analysis: '$FAILED_SOLUTIONS'"
    log_info "========== SOLUTION ANALYSIS DEBUG END =========="
}

# Main function
main() {
    log_info "Starting $SCRIPT_NAME v$SCRIPT_VERSION"
    
    # Check if this is being called by Symphony script provider (JSON input)
    if [[ $# -eq 1 && -f "$1" ]]; then
        log_info "Running in Symphony JSON input mode: input file $1"
        parse_json_input "$1"
    else
        log_info "Running in CLI argument mode"
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
    local has_partial_staging=false
    
    log_info "Processing staging workflow for $total_count target(s) in namespace $NAMESPACE"
    log_info "Image list: $IMAGE_LIST"
    log_info "Solutions: $SOLUTION_IMAGES"
    
    # Process each target through the complete workflow
    for target in "${TARGET_ARRAY[@]}"; do
        target=$(echo "$target" | xargs)  # Trim whitespace
        
        if process_target_workflow "$target"; then
            ((success_count++))
            log_info "Successfully completed staging workflow for target: $target"
        else
            log_error "Failed staging workflow for target: $target"
        fi
        
        # Always analyze solution status if stage 2 was executed, regardless of success/failure
        if should_execute_step "2"; then
            analyze_solution_status_for_target "$target"
            # Check if we have any solution status data to determine partial staging
            if [[ -n "$SUCCEEDED_SOLUTIONS" || -n "$FAILED_SOLUTIONS" ]]; then
                has_partial_staging=true
            fi
        fi
        
        echo # Add spacing between targets
    done
    
    # Summary
    echo "========================================"
    log_info "FINAL SUMMARY: $success_count/$total_count targets completed staging workflow successfully"
    
    # Create JSON output for Symphony script provider
    if [[ $# -eq 1 && -f "$1" ]]; then
        local inputs_file="$1"
        local output_file="${inputs_file%.*}-output.${inputs_file##*.}"
        
        local status_code=200
        # if [[ "$success_count" -ne "$total_count" ]]; then
        #     status_code=400
        # fi
        
        # Generate enhanced JSON output with per-solution status when partial staging occurred
        if [[ "$has_partial_staging" == "true" ]]; then
            # Count succeeded and failed solutions
            local succeeded_count=0
            local failed_count=0
            
            if [[ -n "$SUCCEEDED_SOLUTIONS" ]]; then
                succeeded_count=$(echo "$SUCCEEDED_SOLUTIONS" | tr ',' '\n' | wc -l)
            fi
            
            if [[ -n "$FAILED_SOLUTIONS" ]]; then
                failed_count=$(echo "$FAILED_SOLUTIONS" | tr ',' '\n' | wc -l)
            fi
            
            # Create enhanced output with solution counts and names
            local enhanced_output
            enhanced_output=$(jq -nc \
                --arg status "$status_code" \
                --arg message "Processed $success_count/$total_count staging workflows" \
                --arg targets_processed "$success_count" \
                --arg total_targets "$total_count" \
                --arg solutionversion_succeeded "$succeeded_count" \
                --arg solutionversion_failed "$failed_count" \
                --arg succeeded_solutions "$SUCCEEDED_SOLUTIONS" \
                --arg failed_solutions "$FAILED_SOLUTIONS" \
                '{
                    "status": ($status | tonumber),
                    "message": $message,
                    "targets_processed": ($targets_processed | tonumber),
                    "total_targets": ($total_targets | tonumber),
                    "solutionversion_succeeded": ($solutionversion_succeeded | tonumber),
                    "solutionversion_failed": ($solutionversion_failed | tonumber),
                    "succeeded_solutions": $succeeded_solutions,
                    "failed_solutions": $failed_solutions
                }')
                
            echo "$enhanced_output" > "$output_file"
            log_info "Enhanced JSON output with solution status written to: $output_file"
            log_info "Solution counts - Succeeded: $succeeded_count ($SUCCEEDED_SOLUTIONS), Failed: $failed_count ($FAILED_SOLUTIONS)"
        else
            # Standard output when no partial staging detected
            echo "{\"status\":$status_code,\"message\":\"Processed $success_count/$total_count staging workflows\",\"targets_processed\":$success_count,\"total_targets\":$total_count}" > "$output_file"
            log_info "Standard JSON output written to: $output_file"
        fi
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY-RUN completed. No changes were applied."
        exit 0
    elif [[ "$success_count" -eq "$total_count" ]]; then
        log_info "All targets completed staging workflow successfully!"
        exit 0
    else
        log_warn "Some targets failed staging workflow. Check logs above for details."
    fi
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
