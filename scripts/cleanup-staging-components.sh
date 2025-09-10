#!/bin/bash

# Cleanup Targets Script
# Removes solution entries from imageList and resets reconciliation policy for specified targets

# Script metadata
SCRIPT_NAME="cleanup-staging-components.sh"
SCRIPT_VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Default values
NAMESPACE=""
TARGETS=""
SOLUTION_IMAGES=""
OUTPUT_FILE="${SCRIPT_DIR}/cleanup-debug-output.txt"

# Logging functions
log_info() {
    local msg="[INFO] $1"
    echo "$msg"
    echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" >> "$OUTPUT_FILE"
}

log_error() {
    local msg="[ERROR] $1"
    echo "$msg" >&2
    echo "$(date '+%Y-%m-%d %H:%M:%S') $msg" >> "$OUTPUT_FILE"
}

log_warn() {
    local msg="[WARN] $1"
    echo "$msg"
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
$SCRIPT_NAME v$SCRIPT_VERSION - Cleanup Targets Script

DESCRIPTION:
    Cleans up solution entries from imageList and resets reconciliation policy for specified targets.

USAGE:
    $SCRIPT_NAME --namespace <namespace> --targets <target1,target2> --solution-images <solution:images,...>

REQUIRED ARGUMENTS:
    --namespace, -n         Kubernetes namespace containing the Target CRs
    --targets, -t           Target name(s) - single name or comma-separated list
    --solution-images, -s   List of solutions named using target as prefix (e.g., "target1-sol1,target2-sol2")

EXAMPLES:
    $SCRIPT_NAME --namespace default --targets target1,target2 --solution-images "sol1,sol2"

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
    log_info "Raw JSON input content:"
    echo "$json_content" | jq '.'
    
    NAMESPACE=$(echo "$json_content" | jq -r '.namespace // "default"')
    TARGETS=$(echo "$json_content" | jq -r '.targets // ""')
    SOLUTION_IMAGES=$(echo "$json_content" | jq -r '.solution_images // ""')
    
    log_info "Parsed values:"
    log_info "  namespace: $NAMESPACE"
    log_info "  targets: $TARGETS" 
    log_info "  solution_images: $SOLUTION_IMAGES"
    
    log_debug "JSON parsed: namespace=$NAMESPACE, targets=$TARGETS, solution_images=$SOLUTION_IMAGES"
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
            --solution-images|-s)
                SOLUTION_IMAGES="$2"
                shift 2
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *.json)
                # Handle JSON files that might be passed as arguments
                if [[ -f "$1" ]]; then
                    log_info "Found JSON file in arguments, switching to JSON input mode: $1"
                    parse_json_input "$1"
                    return 0
                else
                    log_error "JSON file not found: $1"
                    exit 1
                fi
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

    if [[ -z "$SOLUTION_IMAGES" ]]; then
        log_error "Solution to images mapping required (--solution-images)"
        exit 1
    fi
}

# Main cleanup logic
cleanup_target() {
    local target_name="$1"

    log_info "Cleaning up target: $target_name for all solutions"
    log_debug "Fetching target JSON for $target_name"

    # Get the target as JSON
    local target_json
    log_info "Running command: kubectl get target $target_name -n $NAMESPACE -o json"
    log_debug "Executing: kubectl get target $target_name -n $NAMESPACE -o json"
    local raw_kubectl_output
    kubectl config use-context lyaks3
    raw_kubectl_output=$(kubectl get target "$target_name" -n "$NAMESPACE" -o json)
    echo "Raw kubectl output: $raw_kubectl_output"
    log_debug "Raw kubectl output: $raw_kubectl_output"
    echo "$(date '+%Y-%m-%d %H:%M:%S') [DEBUG] Raw kubectl output: $raw_kubectl_output" >> cleanup-debug-output.txt
    target_json="$raw_kubectl_output"
    log_debug "Processed target JSON: $target_json"
    # Sanitize JSON output
    target_json=$(echo "$target_json" | tr -d '\r' | sed 's/\\n//g')
    log_debug "Sanitized target JSON: $target_json"
    mkdir -p D:/tmp
    echo "$target_json" > D:/tmp/target_json_debug.json
    log_debug "Saved raw JSON to D:/tmp/target_json_debug.json for inspection"
    log_debug "Sanitized JSON output: $target_json"
    if ! echo "$target_json" | jq empty &>/dev/null; then
        log_error "Sanitized JSON is invalid for target $target_name. Raw output: $target_json"
        echo "$target_json" > D:/tmp/invalid_target_json_${target_name}.txt
        log_debug "Invalid JSON saved to D:/tmp/invalid_target_json_${target_name}.txt"
        return 1
    fi
    log_debug "kubectl output: $target_json"

    if [[ $? -ne 0 ]]; then
        log_error "Failed to get target $target_name"
        return 1
    fi

    # Extract and modify the imageList
    local image_list
    image_list=$(echo "$target_json" | jq -r ".spec.components[] | select(.name == \"staging-component\") | .properties.imageList")
    log_debug "Raw imageList content: $image_list"
    if [[ -z "$image_list" || "$image_list" == "null" ]]; then
        log_info "No valid imageList found for target $target_name. Skipping."
        return 0
    fi

    if [[ "$image_list" == "null" ]]; then
        log_info "No imageList found for target $target_name. Skipping."
        log_debug "Target JSON: $target_json"
        return 0
    fi

    # Debug: Show what's actually in the imageList vs what we're trying to remove
    log_info "Current imageList keys: $(echo "$image_list" | jq -r 'keys[]' | tr '\n' ', ' | sed 's/,$//')"
    log_info "Solutions to remove: ${SOLUTION_IMAGES_ARRAY[*]}"
    
    # Get all existing solution keys from imageList
    local existing_solutions
    existing_solutions=($(echo "$image_list" | jq -r 'keys[]'))
    
    # Remove all specified solution entries from imageList with flexible matching
    local jq_del_args=""
    local found_solutions=()
    
    for solution_name in "${SOLUTION_IMAGES_ARRAY[@]}"; do
        # First try exact match
        if echo "$image_list" | jq -e ".\"$solution_name\"" > /dev/null 2>&1; then
            if [[ -z "$jq_del_args" ]]; then
                jq_del_args=".\"$solution_name\""
            else
                jq_del_args+=", .\"$solution_name\""
            fi
            found_solutions+=("$solution_name")
            log_info "Found exact match '$solution_name' in imageList, will remove it"
        else
            # Try prefix matching for same target but different versions
            local target_prefix="${target_name}-"
            for existing_solution in "${existing_solutions[@]}"; do
                if [[ "$existing_solution" == "$target_prefix"* ]]; then
                    log_info "Found target-related solution '$existing_solution' in imageList (prefix match for $target_name)"
                    if [[ ! " ${found_solutions[*]} " =~ " ${existing_solution} " ]]; then
                        if [[ -z "$jq_del_args" ]]; then
                            jq_del_args=".\"$existing_solution\""
                        else
                            jq_del_args+=", .\"$existing_solution\""
                        fi
                        found_solutions+=("$existing_solution")
                        log_info "Will remove '$existing_solution' (target-based cleanup)"
                    fi
                fi
            done
            
            if [[ ${#found_solutions[@]} -eq 0 ]]; then
                log_warn "Solution '$solution_name' not found in imageList, and no target-prefix matches found"
            fi
        fi
    done
    
    # Construct proper jq deletion command
    if [[ -n "$jq_del_args" ]]; then
        jq_del_args="del($jq_del_args)"
    fi

    if [[ -n "$jq_del_args" && ${#found_solutions[@]} -gt 0 ]]; then
        log_info "Removing solutions (${found_solutions[*]}) from imageList in target $target_name"
        log_debug "Current imageList: $image_list"
        log_info "JQ deletion command: $jq_del_args"
        
        local updated_image_list
        updated_image_list=$(echo "$image_list" | jq "$jq_del_args" 2>&1)
        local jq_exit_code=$?
        
        if [[ $jq_exit_code -ne 0 ]]; then
            log_error "JQ deletion failed with exit code $jq_exit_code"
            log_error "JQ output: $updated_image_list"
            log_info "Falling back to individual deletions"
            
            # Fallback: delete solutions one by one
            updated_image_list="$image_list"
            for solution_to_remove in "${found_solutions[@]}"; do
                log_info "Individually removing solution: $solution_to_remove"
                updated_image_list=$(echo "$updated_image_list" | jq "del(.\"$solution_to_remove\")")
                log_info "After removing $solution_to_remove: $(echo "$updated_image_list" | jq -r 'keys[]' | tr '\n' ', ' | sed 's/,$//')"
            done
        fi
        
        log_debug "Updated imageList after bulk deletion: $updated_image_list"
        log_info "ImageList keys after removal: $(echo "$updated_image_list" | jq -r 'keys[]' | tr '\n' ', ' | sed 's/,$//')"
        
        # Update imageList in target_json
        target_json=$(echo "$target_json" | jq ".spec.components[] |= if .name == \"staging-component\" then .properties.imageList = $updated_image_list else . end")
        image_list="$updated_image_list"
    else
        log_info "No matching solutions found for removal from imageList for target $target_name."
    fi

    # Check if imageList is empty
    if [[ "$(echo "$image_list" | jq 'keys | length')" -eq 0 ]]; then
        log_info "Removing staging component from target $target_name as no images are staged."
        log_debug "Updated target JSON: $(echo "$target_json" | jq -c .)"
        target_json=$(echo "$target_json" | jq "del(.spec.components[] | select(.name == \"staging-component\"))")
    fi

    # Reset reconciliation policy if no images are staged
    if [[ "$(echo "$image_list" | jq 'keys | length')" -eq 0 ]]; then
        log_info "Resetting reconciliation policy for target $target_name."
        target_json=$(echo "$target_json" | jq "del(.spec.reconciliationPolicy)")
    fi

    # Apply the updated target JSON
    log_info "Applying updated target JSON for $target_name"
    log_debug "Final target JSON being applied for $target_name: $(echo "$target_json" | jq -c .)"
    echo "$target_json" > D:/tmp/final_target_json_${target_name}.json
    log_debug "Saved final target JSON to D:/tmp/final_target_json_${target_name}.json"
    if ! echo "$target_json" | kubectl apply -f - 2> D:/tmp/kubectl_apply_error_${target_name}.txt; then
        log_error "Failed to apply updated target JSON for $target_name"
        log_error "kubectl error output saved to D:/tmp/kubectl_apply_error_${target_name}.txt"
        return 1
    fi
    
    log_info "Successfully completed cleanup for target $target_name"
    return 0
}

# Main function
main() {
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

    # Convert comma-separated targets to array
    IFS=',' read -ra TARGET_ARRAY <<< "$TARGETS"

    # Convert solution-images mapping to array
    IFS=',' read -ra SOLUTION_IMAGES_ARRAY <<< "$SOLUTION_IMAGES"

    log_debug "Parsed TARGET_ARRAY: ${TARGET_ARRAY[*]}"
    log_debug "Parsed SOLUTION_IMAGES_ARRAY: ${SOLUTION_IMAGES_ARRAY[*]}"
    local success_count=0
    local total_count=${#TARGET_ARRAY[@]}
    log_info "Processing cleanup for ${#TARGET_ARRAY[@]} targets with ${#SOLUTION_IMAGES_ARRAY[@]} solutions to clean"
    
    for target in "${TARGET_ARRAY[@]}"; do
        log_info "Processing cleanup for target: $target"
        if cleanup_target "$target"; then
            ((success_count++))
            log_info "Successfully cleaned up target: $target"
        else
            log_error "Failed to clean up target: $target"
        fi
    done

    # Create JSON output for Symphony script provider
    if [[ $# -eq 1 && -f "$1" ]]; then
        local inputs_file="$1"
        local output_file="${inputs_file%.*}-output.${inputs_file##*.}"

        local status_code=200
        if [[ "$success_count" -ne "$total_count" ]]; then
            status_code=500
        fi

        echo "{\"status\":$status_code,\"message\":\"Processed $success_count/$total_count cleanup targets\",\"targets_processed\":$success_count,\"total_targets\":$total_count}" > "$output_file"
        log_info "JSON output written to: $output_file"
    fi
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
