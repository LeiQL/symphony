#!/bin/bash

# Symphony Staging Results Monitor
# Monitors staging results for Target CRs and checks if all images have been staged
# Based on C# PullStagingResultAsync logic for Symphony orchestration
# Uses kubectl and jq for JSON processing

# Script metadata
SCRIPT_NAME="pull-staging-results.sh"
SCRIPT_VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default values
NAMESPACE=""
TARGETS=""
SOLUTION_NAMES=""
MONITOR_TIMEOUT_MINUTES=30
RETRY_INTERVAL_SECONDS=10
MAX_RETRY_INTERVAL_SECONDS=60
VERBOSE=false
OUTPUT_FILE="${SCRIPT_DIR}/staging-results-output.txt"

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
$SCRIPT_NAME v$SCRIPT_VERSION - Symphony Staging Results Monitor

DESCRIPTION:
    Monitors staging results for Symphony Target CRs and checks if all images 
    for specified solutions have been staged successfully.
    Based on C# PullStagingResultAsync logic.

USAGE:
    $SCRIPT_NAME --namespace <namespace> --targets <target1,target2> --solutions <sol1,sol2> [OPTIONS]

REQUIRED ARGUMENTS:
    --namespace, -n         Kubernetes namespace containing the Target CRs
    --targets, -t           Target name(s) - single name or comma-separated list
    --solutions, -s         Solution name(s) to monitor - comma-separated list

OPTIONS:
    --timeout-minutes       Monitor timeout in minutes (default: 30)
    --retry-interval        Initial retry interval in seconds (default: 10)
    --max-retry-interval    Maximum retry interval in seconds (default: 60)
    --verbose, -v           Enable verbose logging
    --help, -h              Show this help message

EXAMPLES:
    # Monitor staging for single target and solution
    $SCRIPT_NAME --namespace default --targets testtarget --solutions stage-sol-5.0.0.2

    # Monitor multiple targets and solutions
    $SCRIPT_NAME -n symphony-system -t target1,target2 -s sol1,sol2 --verbose

    # Custom timeout and retry settings
    $SCRIPT_NAME -n default -t target1 -s solution1 --timeout-minutes 60 --retry-interval 5

STAGING RESULT FORMAT:
    The script expects staging results in Target CR status with the following structure:
    - ImagesToBeStaged: Dictionary of solution to image arrays
    - StagedImages: Array of successfully staged images
    - Success: Boolean indicating staging operation success

EOF
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
            --solutions|-s)
                SOLUTION_NAMES="$2"
                shift 2
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
            --verbose|-v)
                VERBOSE=true
                shift
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

    if [[ -z "$SOLUTION_NAMES" ]]; then
        log_error "Solution name(s) required (--solutions)"
        exit 1
    fi

    log_debug "Arguments parsed: namespace=$NAMESPACE, targets=$TARGETS, solutions=$SOLUTION_NAMES"
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

# Check if target exists
target_exists() {
    local target_name="$1"
    kubectl get target "$target_name" -n "$NAMESPACE" &> /dev/null
}

# Extract images to be staged from Target CR component statuses
extract_images_to_be_staged_from_cr() {
    local target_name="$1"
    
    log_info "Extracting ImagesToBeStaged from Target CR: $target_name"
    
    # Get target as JSON
    local target_json
    target_json=$(kubectl get target "$target_name" -n "$NAMESPACE" -o json 2>/dev/null)
    
    if [[ $? -ne 0 ]]; then
        log_error "Failed to get target $target_name"
        return 1
    fi
    
    # Extract component statuses from target status
    local component_statuses
    component_statuses=$(echo "$target_json" | jq -r '.status.targetStatuses[]?.componentStatuses // empty')
    
    if [[ -z "$component_statuses" ]]; then
        log_debug "No component statuses found in target $target_name"
        echo "{}"
        return 0
    fi
    
    # Parse ImagesToBeStaged from component status JSON strings
    local images_to_be_staged="{}"
    
    # Look through each component status for staging information
    echo "$component_statuses" | jq -r '.[] | select(.status | contains("ImagesToBeStaged")) | .status' | while read -r status_json_str; do
        if [[ -n "$status_json_str" ]]; then
            # Extract JSON from the status string (after the dash)
            local json_part
            json_part=$(echo "$status_json_str" | sed 's/^[^{]*{/{/')
            
            if [[ -n "$json_part" ]]; then
                # Parse the JSON and extract ImagesToBeStaged
                local component_images
                component_images=$(echo "$json_part" | jq -r '.ImagesToBeStaged // empty' 2>/dev/null)
                
                if [[ -n "$component_images" && "$component_images" != "null" ]]; then
                    log_debug "Found ImagesToBeStaged in component: $component_images"
                    # Merge with existing images_to_be_staged
                    images_to_be_staged=$(echo "$images_to_be_staged $component_images" | jq -s 'add')
                fi
            fi
        fi
    done
    
    echo "$images_to_be_staged"
}

# Parse staging result from target CR
parse_staging_result_from_target() {
    local target_name="$1"
    
    # Get target as JSON
    local target_json
    target_json=$(kubectl get target "$target_name" -n "$NAMESPACE" -o json 2>/dev/null)
    
    if [[ $? -ne 0 ]]; then
        log_error "Failed to get target $target_name"
        return 1
    fi
    
    # Extract staging result from target status
    # Look for staging result in various possible locations in the target status
    local staging_result
    staging_result=$(echo "$target_json" | jq -r '.status.properties.stagingResult // .status.stagingResult // .spec.properties.stagingResult // null')
    
    # If no staging result found in standard locations, try to extract from component statuses
    if [[ "$staging_result" == "null" || -z "$staging_result" ]]; then
        log_debug "No staging result found in standard locations, checking component statuses"
        
        # Look for staging information in component statuses
        local component_statuses
        component_statuses=$(echo "$target_json" | jq -r '.status.targetStatuses[]?.componentStatuses // empty')
        
        if [[ -n "$component_statuses" ]]; then
            # Parse staging data from component status JSON strings
            local success="false"
            local images_to_be_staged="{}"
            local staged_images="[]"
            
            # Look through each component status for staging information
            while IFS= read -r component; do
                local status_str
                status_str=$(echo "$component" | jq -r '.status // empty')
                
                if [[ -n "$status_str" && "$status_str" =~ \{.*\} ]]; then
                    # Extract JSON from the status string (after the dash)
                    local json_part
                    json_part=$(echo "$status_str" | sed 's/^[^{]*{/{/')
                    
                    if [[ -n "$json_part" ]]; then
                        # Parse the JSON and extract staging information
                        local comp_success
                        comp_success=$(echo "$json_part" | jq -r '.Success // empty' 2>/dev/null)
                        
                        local comp_images_to_stage
                        comp_images_to_stage=$(echo "$json_part" | jq -r '.ImagesToBeStaged // empty' 2>/dev/null)
                        
                        local comp_staged_images
                        comp_staged_images=$(echo "$json_part" | jq -r '.StagedImages // empty' 2>/dev/null)
                        
                        # Update combined result
                        if [[ "$comp_success" == "true" ]]; then
                            success="true"
                        fi
                        
                        if [[ -n "$comp_images_to_stage" && "$comp_images_to_stage" != "null" ]]; then
                            images_to_be_staged=$(echo "$images_to_be_staged $comp_images_to_stage" | jq -s 'add // {}')
                        fi
                        
                        if [[ -n "$comp_staged_images" && "$comp_staged_images" != "null" ]]; then
                            staged_images=$(echo "$staged_images $comp_staged_images" | jq -s 'add | unique // []')
                        fi
                    fi
                fi
            done <<< "$(echo "$component_statuses" | jq -c '.[]')"
            
            # Construct staging result from component data
            staging_result=$(jq -nc --arg success "$success" --argjson images_to_be_staged "$images_to_be_staged" --argjson staged_images "$staged_images" '{
                "success": ($success == "true"),
                "imagesToBeStaged": $images_to_be_staged,
                "stagedImages": $staged_images
            }')
        fi
        
        if [[ "$staging_result" == "null" || -z "$staging_result" ]]; then
            log_debug "No staging result found in target $target_name"
            echo "{\"success\": false, \"imagesToBeStaged\": {}, \"stagedImages\": []}"
            return 0
        fi
    fi
    
    # Parse the staging result JSON
    echo "$staging_result" | jq -c '.'
}

# Check if staging is complete for a solution
check_solution_staging_complete() {
    local staging_result="$1"
    local solution_name="$2"
    
    # Extract success flag
    local success
    success=$(echo "$staging_result" | jq -r '.success // false')
    
    if [[ "$success" != "true" ]]; then
        log_debug "Staging result success flag is false"
        return 1
    fi
    
    # Get images to be staged for the solution
    local images_to_be_staged
    images_to_be_staged=$(echo "$staging_result" | jq -r ".imagesToBeStaged[\"$solution_name\"] // []")
    
    if [[ "$images_to_be_staged" == "[]" || "$images_to_be_staged" == "null" ]]; then
        log_info "No images to stage for solution $solution_name. Skipping staging check."
        return 0
    fi
    
    # Get staged images
    local staged_images
    staged_images=$(echo "$staging_result" | jq -r '.stagedImages // []')
    
    if [[ "$staged_images" == "[]" || "$staged_images" == "null" ]]; then
        log_info "No images staged. Continuing staging process."
        return 1
    fi
    
    # Convert arrays to space-separated strings for comparison
    local images_to_stage_list
    images_to_stage_list=$(echo "$images_to_be_staged" | jq -r '.[] // empty' | tr '\n' ' ')
    
    local staged_images_list
    staged_images_list=$(echo "$staged_images" | jq -r '.[] // empty' | tr '\n' ' ')
    
    log_info "Checking if staged images contain all input image paths"
    log_info "Staged images: $staged_images_list"
    log_info "Input image paths: $images_to_stage_list"
    
    # Check if all input images are in staged images
    local all_staged=true
    local missing_images=""
    
    for image in $images_to_stage_list; do
        if [[ ! " $staged_images_list " =~ " $image " ]]; then
            all_staged=false
            missing_images="$missing_images $image"
        fi
    done
    
    if [[ "$all_staged" == "true" ]]; then
        log_info "All input images have been staged successfully for solution $solution_name."
        return 0
    else
        log_info "Missing images in staging for solution $solution_name:$missing_images"
        return 1
    fi
}

# Determine if staging is finished for a target
determine_stage_finished() {
    local target_name="$1"
    
    # Get target as JSON
    local target_json
    target_json=$(kubectl get target "$target_name" -n "$NAMESPACE" -o json 2>/dev/null)
    
    if [[ $? -ne 0 ]]; then
        log_error "Failed to get target $target_name"
        return 1  # Continue retrying
    fi
    
    # Check target deployment status
    local target_status
    target_status=$(echo "$target_json" | jq -r '.status.status // .status.provisioningStatus.status // "Unknown"')
    
    if [[ "$target_status" != "Succeeded" ]]; then
        log_debug "Target $target_name deployment status is not Succeeded: $target_status. Retrying."
        return 1  # Continue retrying
    fi
    
    # Parse staging result
    local staging_result
    staging_result=$(parse_staging_result_from_target "$target_name")
    
    if [[ $? -ne 0 ]]; then
        log_debug "Failed to parse staging result for target $target_name. Retrying."
        return 1  # Continue retrying
    fi
    
    # Check staging completion for all specified solutions
    IFS=',' read -ra SOLUTION_ARRAY <<< "$SOLUTION_NAMES"
    local all_solutions_complete=true
    
    for solution in "${SOLUTION_ARRAY[@]}"; do
        solution=$(echo "$solution" | xargs)  # Trim whitespace
        
        if ! check_solution_staging_complete "$staging_result" "$solution"; then
            all_solutions_complete=false
            break
        fi
    done
    
    if [[ "$all_solutions_complete" == "true" ]]; then
        log_info "All solutions staging completed for target $target_name"
        return 0  # Staging complete
    else
        log_debug "Staging not complete for target $target_name. Retrying."
        return 1  # Continue retrying
    fi
}

# Monitor staging results for a target with retry logic
monitor_target_staging() {
    local target_name="$1"
    
    log_info "Starting staging monitor for target: $target_name"
    
    # Check if target exists
    if ! target_exists "$target_name"; then
        log_error "Target $target_name not found in namespace $NAMESPACE"
        return 1
    fi
    
    local start_time=$(date +%s)
    local timeout_seconds=$((MONITOR_TIMEOUT_MINUTES * 60))
    local retry_count=0
    local current_interval=$RETRY_INTERVAL_SECONDS
    
    while true; do
        local current_time=$(date +%s)
        local elapsed_time=$((current_time - start_time))
        
        # Check timeout
        if [[ $elapsed_time -ge $timeout_seconds ]]; then
            log_error "Timeout reached ($MONITOR_TIMEOUT_MINUTES minutes) for target $target_name"
            return 1
        fi
        
        retry_count=$((retry_count + 1))
        log_debug "Attempt $retry_count for target $target_name"
        
        # Check if staging is finished
        if determine_stage_finished "$target_name"; then
            log_info "Staging completed successfully for target $target_name"
            return 0
        fi
        
        # Calculate next retry interval with exponential backoff
        local next_interval=$((current_interval * 2))
        if [[ $next_interval -gt $MAX_RETRY_INTERVAL_SECONDS ]]; then
            next_interval=$MAX_RETRY_INTERVAL_SECONDS
        fi
        
        log_info "Retrying to pull staging result for target $target_name after $current_interval seconds. Attempt $retry_count."
        sleep "$current_interval"
        current_interval=$next_interval
    done
}

# Main function
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
    local json_content
    json_content=$(cat "$json_file")
    NAMESPACE=$(echo "$json_content" | jq -r '.namespace // "default"')
    TARGETS=$(echo "$json_content" | jq -r '.targets // ""')
    SOLUTION_NAMES=$(echo "$json_content" | jq -r '.solutions // ""')
    MONITOR_TIMEOUT_MINUTES=$(echo "$json_content" | jq -r '.timeout_minutes // 30')
    RETRY_INTERVAL_SECONDS=$(echo "$json_content" | jq -r '.retry_interval // 10')
    MAX_RETRY_INTERVAL_SECONDS=$(echo "$json_content" | jq -r '.max_retry_interval // 60')
    local verbose_str
    verbose_str=$(echo "$json_content" | jq -r '.verbose // "false"')
    if [[ "$verbose_str" == "true" ]]; then
        VERBOSE=true
    fi
    log_debug "JSON parsed: namespace=$NAMESPACE, targets=$TARGETS, solutions=$SOLUTION_NAMES, timeout_minutes=$MONITOR_TIMEOUT_MINUTES, retry_interval=$RETRY_INTERVAL_SECONDS, max_retry_interval=$MAX_RETRY_INTERVAL_SECONDS, verbose=$VERBOSE"
}

main() {
    log_info "Starting $SCRIPT_NAME v$SCRIPT_VERSION"

    if [[ $# -eq 1 && -f "$1" ]]; then
        log_info "Running in Symphony JSON input mode: input file $1"
        log_debug "Symphony mode: parsing JSON input"
        parse_json_input "$1"
    else
        log_info "Running in CLI argument mode"
        parse_args "$@"
    fi

    # Ensure jq is installed
    if ! ensure_jq_installed; then
        exit 1
    fi
    
    # Convert comma-separated targets to array
    IFS=',' read -ra TARGET_ARRAY <<< "$TARGETS"
    
    local success_count=0
    local total_count=${#TARGET_ARRAY[@]}
    
    log_info "Monitoring staging results for $total_count target(s) in namespace $NAMESPACE"
    log_info "Solutions to check: $SOLUTION_NAMES"
    log_info "Timeout: $MONITOR_TIMEOUT_MINUTES minutes"
    
    # Monitor each target
    for target in "${TARGET_ARRAY[@]}"; do
        # Trim whitespace
        target=$(echo "$target" | xargs)
        
        if monitor_target_staging "$target"; then
            ((success_count++))
            log_info "Successfully completed staging monitor for target: $target"
        else
            log_error "Failed to complete staging monitor for target: $target"
        fi
        echo # Add spacing between targets
    done
    
    # Summary
    echo "========================================"
    log_info "Summary: $success_count/$total_count targets completed staging successfully"

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

    if [[ "$success_count" -eq "$total_count" ]]; then
        log_info "All targets completed staging successfully!"
        exit 0
    else
        log_warn "Some targets failed to complete staging. Check logs above for details."
        exit 1
    fi
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
