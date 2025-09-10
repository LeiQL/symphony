#!/bin/bash

# Symphony Staging Orchestrator - FIXED VERSION
# Fixed the cleanup logic to properly handle solution removal

# Script metadata
SCRIPT_NAME="staging-orchestrator-fixed.sh"
SCRIPT_VERSION="1.0.1-fixed"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default values
NAMESPACE=""
TARGETS=""
IMAGE_LIST=""
SOLUTION_IMAGES=""
VERBOSE=false
DRY_RUN=false
MONITOR_TIMEOUT_MINUTES=30
RETRY_INTERVAL_SECONDS=10
MAX_RETRY_INTERVAL_SECONDS=60
TOPOLOGY_NAME="staging-topology"
BACKUP_DIR="${SCRIPT_DIR}/backups"
OUTPUT_FILE="${SCRIPT_DIR}/staging-orchestrator-output.txt"

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
    --dry-run, -d           Preview changes without applying them
    --verbose, -v           Enable verbose logging
    --timeout-minutes       Monitor timeout in minutes (default: 30)
    --retry-interval        Initial retry interval in seconds (default: 10)
    --max-retry-interval    Maximum retry interval in seconds (default: 60)
    --topology-name         Topology name for bindings (default: 'staging-topology')
    --backup-dir            Directory for CR backups (default: ./backups)
    --help, -h              Show this help message

EXAMPLES:
    # Basic staging workflow
    $SCRIPT_NAME -n default -t target1 --image-list '{"sol1": ["demo:latest"]}'

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
    
    NAMESPACE=$(echo "$json_content" | jq -r '.namespace // "default"')
    TARGETS=$(echo "$json_content" | jq -r '.targets // ""')
    IMAGE_LIST=$(echo "$json_content" | jq -c '.image_list // {}')
    MONITOR_TIMEOUT_MINUTES=$(echo "$json_content" | jq -r '.timeout_minutes // 30')
    RETRY_INTERVAL_SECONDS=$(echo "$json_content" | jq -r '.retry_interval // 10')
    
    local verbose_str
    verbose_str=$(echo "$json_content" | jq -r '.verbose // "false"')
    if [[ "$verbose_str" == "true" ]]; then
        VERBOSE=true
    fi
    
    # Extract solution names from image_list for use in stage 2 and 3
    SOLUTION_IMAGES=$(echo "$IMAGE_LIST" | jq -r 'keys[]' | tr '\n' ',' | sed 's/,$//')
    
    log_debug "JSON parsed: namespace=$NAMESPACE, targets=$TARGETS, image_list=$IMAGE_LIST, solutions=$SOLUTION_IMAGES"
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

# Check if target exists
target_exists() {
    local target_name="$1"
    kubectl get target "$target_name" -n "$NAMESPACE" &> /dev/null
}

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

    jq -nc --argjson imageList "$new_image_list_obj" '[{
        "name": "staging-component",
        "type": "staging", 
        "properties": {
            "imageList": $imageList
        }
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
    log_info "Adding staging components for $target_name"
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

# Parse staging result from target CR
parse_staging_result_from_target() {
    local target_name="$1"
    
    local target_json
    target_json=$(kubectl get target "$target_name" -n "$NAMESPACE" -o json 2>/dev/null)
    
    if [[ $? -ne 0 ]]; then
        log_error "Failed to get target $target_name"
        return 1
    fi
    
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
                local status_str
                status_str=$(echo "$component" | jq -r '.status // empty')
                
                if [[ -n "$status_str" && "$status_str" =~ \{.*\} ]]; then
                    local json_part
                    json_part=$(echo "$status_str" | sed 's/^[^{]*{/{/')
                    
                    if [[ -n "$json_part" ]]; then
                        local comp_success
                        comp_success=$(echo "$json_part" | jq -r '.Success // empty' 2>/dev/null)
                        
                        if [[ "$comp_success" == "true" ]]; then
                            success="true"
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
                fi
            done <<< "$(echo "$component_statuses" | jq -c '.[]')"
            
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
    
    local success
    success=$(echo "$staging_result" | jq -r '.success // false')
    
    if [[ "$success" != "true" ]]; then
        log_debug "Staging result success flag is false"
        return 1
    fi
    
    local images_to_be_staged
    images_to_be_staged=$(echo "$staging_result" | jq -r ".imagesToBeStaged[\"$solution_name\"] // []")
    
    if [[ "$images_to_be_staged" == "[]" || "$images_to_be_staged" == "null" ]]; then
        log_info "No images to stage for solution $solution_name. Skipping staging check."
        return 0
    fi
    
    local staged_images
    staged_images=$(echo "$staging_result" | jq -r '.stagedImages // []')
    
    if [[ "$staged_images" == "[]" || "$staged_images" == "null" ]]; then
        log_info "No images staged. Continuing staging process."
        return 1
    fi
    
    local images_to_stage_list
    images_to_stage_list=$(echo "$images_to_be_staged" | jq -r '.[] // empty' | tr '\n' ' ')
    
    local staged_images_list
    staged_images_list=$(echo "$staged_images" | jq -r '.[] // empty' | tr '\n' ' ')
    
    log_debug "Staged images: $staged_images_list"
    log_debug "Required images: $images_to_stage_list"
    
    local all_staged=true
    for image in $images_to_stage_list; do
        if [[ ! " $staged_images_list " =~ " $image " ]]; then
            all_staged=false
            break
        fi
    done
    
    if [[ "$all_staged" == "true" ]]; then
        log_info "All images staged successfully for solution $solution_name"
        return 0
    else
        log_debug "Not all images staged for solution $solution_name"
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
            
            if [[ "$target_status" == "Succeeded" ]]; then
                local staging_result
                staging_result=$(parse_staging_result_from_target "$target_name")
                
                if [[ $? -eq 0 ]]; then
                    IFS=',' read -ra SOLUTION_ARRAY <<< "$SOLUTION_IMAGES"
                    local all_solutions_complete=true
                    
                    for solution in "${SOLUTION_ARRAY[@]}"; do
                        solution=$(echo "$solution" | xargs)
                        
                        if ! check_solution_staging_complete "$staging_result" "$solution"; then
                            all_solutions_complete=false
                            break
                        fi
                    done
                    
                    if [[ "$all_solutions_complete" == "true" ]]; then
                        log_info "Staging completed successfully for target $target_name"
                        return 0
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

# Process a single target through all three stages
process_target_workflow() {
    local target_name="$1"
    
    log_info "Starting complete staging workflow for target: $target_name"
    echo "========================================"
    
    # Stage 1: Add staging bindings
    if ! add_bindings_to_target "$target_name"; then
        log_error "Stage 1 failed for target $target_name"
        return 1
    fi
    
    # Stage 2: Monitor staging results
    if ! monitor_target_staging "$target_name"; then
        log_error "Stage 2 failed for target $target_name"
        return 1
    fi
    
    # Stage 3: Cleanup staging components
    if ! cleanup_target "$target_name"; then
        log_error "Stage 3 failed for target $target_name"
        return 1
    fi
    
    log_info "Complete staging workflow successful for target: $target_name"
    echo "========================================"
    return 0
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
    
    # Convert comma-separated targets to array
    IFS=',' read -ra TARGET_ARRAY <<< "$TARGETS"
    
    local success_count=0
    local total_count=${#TARGET_ARRAY[@]}
    
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
        if [[ "$success_count" -ne "$total_count" ]]; then
            status_code=500
        fi
        
        echo "{\"status\":$status_code,\"message\":\"Processed $success_count/$total_count staging workflows\",\"targets_processed\":$success_count,\"total_targets\":$total_count}" > "$output_file"
        log_info "JSON output written to: $output_file"
    fi
    
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "DRY-RUN completed. No changes were applied."
        exit 0
    elif [[ "$success_count" -eq "$total_count" ]]; then
        log_info "All targets completed staging workflow successfully!"
        exit 0
    else
        log_warn "Some targets failed staging workflow. Check logs above for details."
        exit 1
    fi
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
