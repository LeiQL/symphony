#!/bin/bash

# Test script for add-target-bindings.sh
# Creates a sample target and tests the binding addition

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_NAMESPACE="target-bindings-test"
TEST_TARGET="test-target-$(date +%s)"

# Logging functions (no colors for provider.target.script compatibility)
log_info() {
    echo "[INFO] $1"
}

log_warn() {
    echo "[WARN] $1"
}

log_error() {
    echo "[ERROR] $1" >&2
}

cleanup() {
    log_info "Cleaning up test resources..."
    kubectl delete target "$TEST_TARGET" -n "$TEST_NAMESPACE" --ignore-not-found=true
    kubectl delete namespace "$TEST_NAMESPACE" --ignore-not-found=true
}

create_test_target() {
    log_info "Creating test namespace and target..."
    
    kubectl create namespace "$TEST_NAMESPACE" || true
    
    cat << EOF | kubectl apply -f -
apiVersion: fabric.symphony/v1
kind: Target
metadata:
  name: $TEST_TARGET
  namespace: $TEST_NAMESPACE
spec:
  forceRedeploy: true
  topologies:
  - device: default
    bindings:
    - role: instance
      provider: providers.target.k8s
      config:
        inCluster: "true"
EOF
}

test_dry_run() {
    log_info "Testing dry-run mode..."
    
    if "$SCRIPT_DIR/add-target-bindings.sh" \
        --namespace "$TEST_NAMESPACE" \
        --targets "$TEST_TARGET" \
        --dry-run \
        --verbose; then
        log_info "Dry-run test passed"
    else
        log_error "Dry-run test failed"
        return 1
    fi
}

test_actual_run() {
    log_info "Testing actual binding addition..."
    
    if "$SCRIPT_DIR/add-target-bindings.sh" \
        --namespace "$TEST_NAMESPACE" \
        --targets "$TEST_TARGET" \
        --verbose; then
        log_info "Actual run test passed"
    else
        log_error "Actual run test failed"
        return 1
    fi
}

verify_bindings() {
    log_info "Verifying bindings were added..."
    
    local target_yaml
    target_yaml=$(kubectl get target "$TEST_TARGET" -n "$TEST_NAMESPACE" -o yaml)
    
    # Check for connected-registry-monitor binding
    if echo "$target_yaml" | grep -q "connected-registry-monitor"; then
        log_info "Connected registry monitor binding found"
    else
        log_error "Connected registry monitor binding not found"
        return 1
    fi
    
    # Check for staging-status-monitor binding
    if echo "$target_yaml" | grep -q "staging-status-monitor"; then
        log_info "Staging status monitor binding found"
    else
        log_error "Staging status monitor binding not found"
        return 1
    fi
    
    # Check binding count
    local binding_count
    binding_count=$(echo "$target_yaml" | yq eval '.spec.topologies[0].bindings | length' -)
    if [[ "$binding_count" -eq 3 ]]; then
        log_info "Correct number of bindings (3 total: 1 original + 2 added)"
    else
        log_error "Incorrect binding count: expected 3, got $binding_count"
        return 1
    fi
}

test_duplicate_prevention() {
    log_info "Testing duplicate prevention..."
    
    # Run the script again - should skip existing bindings
    if "$SCRIPT_DIR/add-target-bindings.sh" \
        --namespace "$TEST_NAMESPACE" \
        --targets "$TEST_TARGET" \
        --verbose; then
        log_info "Duplicate prevention test passed"
    else
        log_error "Duplicate prevention test failed"
        return 1
    fi
    
    # Verify still only 3 bindings
    local binding_count
    binding_count=$(kubectl get target "$TEST_TARGET" -n "$TEST_NAMESPACE" -o yaml | yq eval '.spec.topologies[0].bindings | length' -)
    if [[ "$binding_count" -eq 3 ]]; then
        log_info "Duplicate prevention working - still 3 bindings"
    else
        log_error "Duplicates were added - found $binding_count bindings"
        return 1
    fi
}

main() {
    log_info "Starting test suite for add-target-bindings.sh"
    
    # Set up cleanup trap
    trap cleanup EXIT
    
    # Check prerequisites
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is required for testing"
        exit 1
    fi
    
    if ! command -v yq &> /dev/null; then
        log_error "yq is required for testing"
        exit 1
    fi
    
    # Run tests
    create_test_target
    test_dry_run
    test_actual_run
    verify_bindings
    test_duplicate_prevention
    
    log_info "All tests passed!"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
