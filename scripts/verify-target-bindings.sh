#!/bin/bash

# Symphony Target Bindings Verification Script
# Verifies that staging topology with bindings was added successfully

set -euo pipefail

# Script metadata
SCRIPT_NAME="verify-target-bindings.sh"
SCRIPT_VERSION="1.0.0"

# Default values
NAMESPACE=""
TARGETS=""
VERBOSE=false

# Logging functions (no colors for provider.target.script compatibility)
log_info() {
    echo "[INFO] $1"
}

log_error() {
    echo "[ERROR] $1" >&2
}

log_debug() {
    if [[ "$VERBOSE" == "true" ]]; then
        echo "[DEBUG] $1"
    fi
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
            *)
                log_error "Unknown argument: $1"
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
}

# Check if staging topology exists with both bindings
verify_staging_topology() {
    local target_name="$1"
    
    log_info "Verifying staging topology in target: $target_name"
    
    # Check if target exists
    if ! kubectl get target "$target_name" -n "$NAMESPACE" &> /dev/null; then
        log_error "Target $target_name not found in namespace $NAMESPACE"
        return 1
    fi
    
    # Get target YAML
    local target_yaml
    target_yaml=$(kubectl get target "$target_name" -n "$NAMESPACE" -o yaml)
    
    # Check for staging topology with 2 bindings including connected-registry-monitor
    local staging_topology_found
    staging_topology_found=$(echo "$target_yaml" | \
        yq eval '.spec.topologies[]? | select((.bindings | length) == 2 and (.bindings[0].role | contains("connected-registry-monitor"))) | length' | \
        wc -l)
    
    if [[ "$staging_topology_found" -gt 0 ]]; then
        log_info "✓ Staging topology with connected-registry-monitor binding found"
        
        # Verify staging-status-monitor binding also exists
        local staging_monitor_found
        staging_monitor_found=$(echo "$target_yaml" | \
            yq eval '.spec.topologies[].bindings[]? | select(.role | contains("staging-status-monitor")) | length' | \
            wc -l)
        
        if [[ "$staging_monitor_found" -gt 0 ]]; then
            log_info "✓ Staging status monitor binding found"
            log_info "✓ Target $target_name successfully updated with staging bindings"
            return 0
        else
            log_error "✗ Staging status monitor binding not found in $target_name"
            return 1
        fi
    else
        log_error "✗ Staging topology with connected-registry-monitor not found in $target_name"
        return 1
    fi
}

# Main function
main() {
    log_info "Starting $SCRIPT_NAME v$SCRIPT_VERSION"
    
    parse_args "$@"
    
    # Convert comma-separated targets to array
    IFS=',' read -ra TARGET_ARRAY <<< "$TARGETS"
    
    local success_count=0
    local total_count=${#TARGET_ARRAY[@]}
    
    log_info "Verifying $total_count target(s) in namespace $NAMESPACE"
    
    # Verify each target
    for target in "${TARGET_ARRAY[@]}"; do
        # Trim whitespace
        target=$(echo "$target" | xargs)
        
        if verify_staging_topology "$target"; then
            ((success_count++))
        fi
    done
    
    # Summary
    log_info "Verification summary: $success_count/$total_count targets verified successfully"
    
    if [[ "$success_count" -eq "$total_count" ]]; then
        log_info "All target bindings verified successfully!"
        exit 0
    else
        log_error "Some target verifications failed"
        exit 1
    fi
}

# Script entry point
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
