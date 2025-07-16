#!/bin/bash

# Symphony Target Status Checker
# Monitors target deployment status and verifies staging-status component
# Returns 0 for success, 1 for failure (for campaign flow control)

# set -eo pipefail  # Commented out to avoid early termination

# Script metadata
SCRIPT_NAME="check-target-status.sh"
SCRIPT_VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default values
NAMESPACE=""
TARGETS=""
VERBOSE=false
OUTPUT_FILE="${SCRIPT_DIR}/target-status-check.txt"
TIMEOUT_SECONDS=300  # 5 minutes default timeout
CHECK_INTERVAL=10    # Check every 10 seconds

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
$SCRIPT_NAME v$SCRIPT_VERSION - Symphony Target Status Checker

DESCRIPTION:
    Monitors target deployment status and verifies staging-status component is successful.
    Returns 0 for success, 1 for failure (for campaign flow control).

USAGE:
    $SCRIPT_NAME --namespace <namespace> --targets <target1,target2> [OPTIONS]

REQUIRED ARGUMENTS:
    --namespace, -n     Kubernetes namespace containing the Target CRs
    --targets, -t       Target name(s) - single name or comma-separated list

OPTIONS:
    --verbose, -v       Enable verbose logging
    --timeout           Timeout in seconds (default: 300)
    --interval          Check interval in seconds (default: 10)
    --help, -h          Show this help message

EXAMPLES:
    # Check single target status
    $SCRIPT_NAME --namespace default --targets target10

    # Check multiple targets with verbose logging
    $SCRIPT_NAME -n default -t target10,target11 --verbose

    # Custom timeout and interval
    $SCRIPT_NAME -n default -t target10 --timeout 600 --interval 5

SUCCESS CRITERIA:
    - Status.Status = "Succeeded"
    - TargetStatuses contains component with name "staging-status"
    - Component status indicates successful update

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
    local verbose_str
    verbose_str=$(echo "$json_content" | python3 -c "import json, sys; data=json.load(sys.stdin); print(data.get('verbose', 'false'))")
    if [[ "$verbose_str" == "true" ]]; then
        VERBOSE=true
    fi
    
    # Parse optional settings
    local timeout_str
    timeout_str=$(echo "$json_content" | python3 -c "import json, sys; data=json.load(sys.stdin); print(data.get('timeout', '$TIMEOUT_SECONDS'))")
    TIMEOUT_SECONDS="$timeout_str"
    
    local interval_str
    interval_str=$(echo "$json_content" | python3 -c "import json, sys; data=json.load(sys.stdin); print(data.get('interval', '$CHECK_INTERVAL'))")
    CHECK_INTERVAL="$interval_str"
    
    # Validate required arguments
    if [[ -z "$NAMESPACE" ]]; then
        log_error "Namespace is required in JSON input"
        exit 1
    fi

    if [[ -z "$TARGETS" ]]; then
        log_error "Target name(s) required in JSON input"
        exit 1
    fi

    log_debug "JSON parsed: namespace=$NAMESPACE, targets=$TARGETS, verbose=$VERBOSE, timeout=$TIMEOUT_SECONDS"
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
            --verbose|-v)
                VERBOSE=true
                shift
                ;;
            --timeout)
                TIMEOUT_SECONDS="$2"
                shift 2
                ;;
            --interval)
                CHECK_INTERVAL="$2"
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

    log_debug "Arguments parsed: namespace=$NAMESPACE, targets=$TARGETS, timeout=$TIMEOUT_SECONDS"
}

# Check if target exists
target_exists() {
    local target_name="$1"
    kubectl get target "$target_name" -n "$NAMESPACE" &> /dev/null
}

# Check target status using pure bash/kubectl (no Python dependency)
check_target_status() {
    local target_name="$1"
    
    log_debug "Checking status for target: $target_name"
    
    # Get overall status using kubectl jsonpath
    local overall_status
    overall_status=$(kubectl get target "$target_name" -n "$NAMESPACE" -o jsonpath='{.status.status}' 2>/dev/null || echo "")
    
    log_debug "Overall Status: $overall_status"
    
    # Check if overall status is Succeeded
    if [[ "$overall_status" != "Succeeded" ]]; then
        log_debug "Overall status is not Succeeded: $overall_status"
        return 1
    fi
    
    # Get component names using kubectl jsonpath
    local component_names
    component_names=$(kubectl get target "$target_name" -n "$NAMESPACE" -o jsonpath='{.status.targetStatuses[*].componentStatuses[*].name}' 2>/dev/null || echo "")
    
    log_debug "Component names found: $component_names"
    
    # Check if staging-status component exists
    if [[ ! "$component_names" =~ staging-status ]]; then
        log_debug "staging-status component not found in components: $component_names"
        return 1
    fi
    
    # Get the staging-status component status using kubectl jsonpath
    local staging_status
    staging_status=$(kubectl get target "$target_name" -n "$NAMESPACE" -o jsonpath='{.status.targetStatuses[*].componentStatuses[?(@.name=="staging-status")].status}' 2>/dev/null || echo "")
    
    log_debug "staging-status component status: $staging_status"
    
    # Check if staging-status indicates success (contains both "Updated" and "Success":true)
    if [[ "$staging_status" =~ Updated ]] && [[ "$staging_status" =~ \"Success\":true ]]; then
        log_debug "✅ staging-status component found and successful!"
        return 0
    else
        log_debug "❌ staging-status found but not successful: $staging_status"
        return 1
    fi
}

# Monitor target status with timeout
monitor_target_status() {
    local target_name="$1"
    local start_time
    start_time=$(date +%s)
    local end_time
    end_time=$((start_time + TIMEOUT_SECONDS))
    
    log_info "Monitoring target $target_name for up to $TIMEOUT_SECONDS seconds"
    
    while true; do
        local current_time
        current_time=$(date +%s)
        
        if [[ $current_time -gt $end_time ]]; then
            log_error "Timeout reached while waiting for target $target_name to succeed"
            return 1
        fi
        
        log_info "Checking target $target_name status ($(( (current_time - start_time) )) seconds elapsed)"
        
        # Capture check output
        local check_output
        if check_output=$(check_target_status "$target_name" 2>&1); then
            log_info "Target $target_name status check PASSED"
            log_debug "Status details: $check_output"
            return 0
        else
            log_info "Target $target_name status check FAILED - waiting $CHECK_INTERVAL seconds..."
            log_debug "Failure details: $check_output"
            sleep "$CHECK_INTERVAL"
        fi
    done
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
    
    # Convert comma-separated targets to array
    IFS=',' read -ra TARGET_ARRAY <<< "$TARGETS"
    
    local success_count=0
    local total_count=${#TARGET_ARRAY[@]}
    
    log_info "Monitoring $total_count target(s) in namespace $NAMESPACE"
    
    # Check each target
    for target in "${TARGET_ARRAY[@]}"; do
        # Trim whitespace
        target=$(echo "$target" | xargs)
        
        # Check if target exists
        if ! target_exists "$target"; then
            log_error "Target $target not found in namespace $NAMESPACE"
            continue
        fi
        
        if monitor_target_status "$target"; then
            ((success_count++))
            log_info "✅ Target $target status verification PASSED"
        else
            log_error "❌ Target $target status verification FAILED"
        fi
    done

    # Summary
    echo "========================================"
    log_info "Summary: $success_count/$total_count targets passed status verification"
    
    # Create JSON output for Symphony script provider
    if [[ $# -eq 1 && -f "$1" ]]; then
        local inputs_file="$1"
        local output_file="${inputs_file%.*}-output.${inputs_file##*.}"
        
        local status_code=200
        if [[ "$success_count" -ne "$total_count" ]]; then
            status_code=500
        fi
        
        echo "{\"status\":$status_code,\"message\":\"Status verification: $success_count/$total_count targets passed\",\"targets_verified\":$success_count,\"total_targets\":$total_count}" > "$output_file"
        log_info "JSON output written to: $output_file"
    fi
    
    if [[ "$success_count" -eq "$total_count" ]]; then
        log_info "🎉 All targets passed status verification!"
        exit 0
    else
        log_error "❌ Some targets failed status verification"
        exit 1
    fi
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
