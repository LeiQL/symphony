# Test script for add-target-bindings.ps1
# Creates a sample target and tests the binding addition

param(
    [switch]$Help = $false
)

$ErrorActionPreference = "Stop"

$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path
$TEST_NAMESPACE = "target-bindings-test"
$TEST_TARGET = "test-target-$(Get-Date -Format 'yyyyMMddHHmmss')"

# Logging functions
function Write-LogInfo {
    param([string]$Message)
    Write-Host "[INFO] $Message" -ForegroundColor Green
}

function Write-LogWarn {
    param([string]$Message)
    Write-Host "[WARN] $Message" -ForegroundColor Yellow
}

function Write-LogError {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
}

function Cleanup {
    Write-LogInfo "Cleaning up test resources..."
    kubectl delete target $TEST_TARGET -n $TEST_NAMESPACE --ignore-not-found=true 2>$null
    kubectl delete namespace $TEST_NAMESPACE --ignore-not-found=true 2>$null
}

function New-TestTarget {
    Write-LogInfo "Creating test namespace and target..."
    
    kubectl create namespace $TEST_NAMESPACE 2>$null
    
    $targetYaml = @"
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
"@

    $targetYaml | kubectl apply -f -
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to create test target"
    }
}

function Test-DryRun {
    Write-LogInfo "Testing dry-run mode..."
    
    $scriptPath = Join-Path $SCRIPT_DIR "add-target-bindings.ps1"
    if (-not (Test-Path $scriptPath)) {
        Write-LogError "PowerShell script not found at $scriptPath"
        return $false
    }
    
    try {
        & $scriptPath -Namespace $TEST_NAMESPACE -Targets $TEST_TARGET -DryRun -Verbose
        if ($LASTEXITCODE -eq 0) {
            Write-LogInfo "Dry-run test passed"
            return $true
        } else {
            Write-LogError "Dry-run test failed with exit code $LASTEXITCODE"
            return $false
        }
    }
    catch {
        Write-LogError "Dry-run test failed with exception: $($_.Exception.Message)"
        return $false
    }
}

function Test-ActualRun {
    Write-LogInfo "Testing actual binding addition..."
    
    $scriptPath = Join-Path $SCRIPT_DIR "add-target-bindings.ps1"
    
    try {
        & $scriptPath -Namespace $TEST_NAMESPACE -Targets $TEST_TARGET -Verbose
        if ($LASTEXITCODE -eq 0) {
            Write-LogInfo "Actual run test passed"
            return $true
        } else {
            Write-LogError "Actual run test failed with exit code $LASTEXITCODE"
            return $false
        }
    }
    catch {
        Write-LogError "Actual run test failed with exception: $($_.Exception.Message)"
        return $false
    }
}

function Test-Bindings {
    Write-LogInfo "Verifying bindings were added..."
    
    try {
        $targetJson = kubectl get target $TEST_TARGET -n $TEST_NAMESPACE -o json
        if ($LASTEXITCODE -ne 0) {
            Write-LogError "Failed to get target"
            return $false
        }
        
        $targetData = $targetJson | ConvertFrom-Json
        $topologies = $targetData.spec.topologies
        
        # Find the staging topology
        $stagingTopology = $null
        foreach ($topology in $topologies) {
            if ($topology.bindings) {
                foreach ($binding in $topology.bindings) {
                    if ($binding.role -and $binding.role.Contains("connected-registry-monitor")) {
                        $stagingTopology = $topology
                        break
                    }
                }
            }
        }
        
        if (-not $stagingTopology) {
            Write-LogError "Staging topology not found"
            return $false
        }
        
        # Check for connected-registry-monitor binding
        $hasConnectedRegistry = $false
        $hasStagingStatus = $false
        
        foreach ($binding in $stagingTopology.bindings) {
            if ($binding.role -eq "connected-registry-monitor") {
                $hasConnectedRegistry = $true
                Write-LogInfo "Connected registry monitor binding found"
            }
            if ($binding.role -eq "staging-status-monitor") {
                $hasStagingStatus = $true
                Write-LogInfo "Staging status monitor binding found"
            }
        }
        
        if (-not $hasConnectedRegistry) {
            Write-LogError "Connected registry monitor binding not found"
            return $false
        }
        
        if (-not $hasStagingStatus) {
            Write-LogError "Staging status monitor binding not found"
            return $false
        }
        
        # Check binding count in staging topology
        $bindingCount = $stagingTopology.bindings.Count
        if ($bindingCount -eq 2) {
            Write-LogInfo "Correct number of bindings in staging topology (2 total)"
        } else {
            Write-LogError "Incorrect binding count in staging topology: expected 2, got $bindingCount"
            return $false
        }
        
        return $true
    }
    catch {
        Write-LogError "Failed to verify bindings: $($_.Exception.Message)"
        return $false
    }
}

function Test-DuplicatePrevention {
    Write-LogInfo "Testing duplicate prevention..."
    
    $scriptPath = Join-Path $SCRIPT_DIR "add-target-bindings.ps1"
    
    try {
        # Run the script again - should skip existing bindings
        & $scriptPath -Namespace $TEST_NAMESPACE -Targets $TEST_TARGET -Verbose
        if ($LASTEXITCODE -eq 0) {
            Write-LogInfo "Duplicate prevention test passed"
        } else {
            Write-LogError "Duplicate prevention test failed"
            return $false
        }
        
        # Verify still correct number of topologies
        $targetJson = kubectl get target $TEST_TARGET -n $TEST_NAMESPACE -o json
        $targetData = $targetJson | ConvertFrom-Json
        $topologies = $targetData.spec.topologies
        
        if ($topologies.Count -eq 2) {
            Write-LogInfo "Duplicate prevention working - still 2 topologies (original + staging)"
            return $true
        } else {
            Write-LogError "Duplicates were added - found $($topologies.Count) topologies"
            return $false
        }
    }
    catch {
        Write-LogError "Duplicate prevention test failed with exception: $($_.Exception.Message)"
        return $false
    }
}

function Show-Usage {
    @"
Test script for add-target-bindings.ps1

DESCRIPTION:
    Creates a sample target and tests the binding addition functionality.

USAGE:
    .\test-add-target-bindings.ps1 [-Help]

OPTIONS:
    -Help    Show this help message

PREREQUISITES:
    - kubectl must be installed and configured
    - add-target-bindings.ps1 must exist in the same directory

"@
}

function Main {
    if ($Help) {
        Show-Usage
        exit 0
    }
    
    Write-LogInfo "Starting test suite for add-target-bindings.ps1"
    
    # Check prerequisites
    try {
        kubectl version --client | Out-Null
    }
    catch {
        Write-LogError "kubectl is required for testing"
        exit 1
    }
    
    $scriptPath = Join-Path $SCRIPT_DIR "add-target-bindings.ps1"
    if (-not (Test-Path $scriptPath)) {
        Write-LogError "PowerShell script not found at $scriptPath"
        Write-LogInfo "Please ensure add-target-bindings.ps1 exists in the same directory"
        exit 1
    }
    
    # Set up cleanup
    try {
        # Run tests
        New-TestTarget
        
        if (-not (Test-DryRun)) {
            throw "Dry-run test failed"
        }
        
        if (-not (Test-ActualRun)) {
            throw "Actual run test failed"
        }
        
        if (-not (Test-Bindings)) {
            throw "Binding verification failed"
        }
        
        if (-not (Test-DuplicatePrevention)) {
            throw "Duplicate prevention test failed"
        }
        
        Write-LogInfo "All tests passed!"
    }
    catch {
        Write-LogError "Test suite failed: $($_.Exception.Message)"
        exit 1
    }
    finally {
        Cleanup
    }
}

# Script entry point
Main
