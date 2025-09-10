# Symphony Target Bindings Manager (PowerShell Version)
# Adds connected registry monitor and staging status monitor bindings to Target CRs
# Based on C# BindingSpec logic for Symphony orchestration
# Uses only kubectl and standard PowerShell tools

param(
    [string]$Namespace = "",
    [string]$Targets = "",
    [switch]$DryRun = $false,
    [switch]$Verbose = $false,
    [string]$BackupDir = "",
    [string]$TopologyName = "staging-topology",
    [string]$OutputFile = "",
    [switch]$AddComponents = $false,
    [string]$ImageList = "demo-image-05:latest",
    [string]$ImageRefKey = "demo-image-05:latest",
    [string]$ImageRefValue = "lcc2-solution2-1.0.0.1",
    [switch]$Help = $false
)

# Script metadata
$SCRIPT_NAME = "add-target-bindings.ps1"
$SCRIPT_VERSION = "2.0.0"
$SCRIPT_DIR = Split-Path -Parent $MyInvocation.MyCommand.Path

# Initialize default values if not provided
if ([string]::IsNullOrEmpty($BackupDir)) {
    $BackupDir = Join-Path $SCRIPT_DIR "backups"
}

if ([string]::IsNullOrEmpty($OutputFile)) {
    $OutputFile = Join-Path $SCRIPT_DIR "target-bindings-output6.txt"
}

# Logging functions
function Write-LogInfo {
    param([string]$Message)
    $logMsg = "[INFO] $Message"
    Write-Host $logMsg
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp $logMsg" | Out-File -FilePath $OutputFile -Append -Encoding UTF8
}

function Write-LogWarn {
    param([string]$Message)
    $logMsg = "[WARN] $Message"
    Write-Host $logMsg -ForegroundColor Yellow
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp $logMsg" | Out-File -FilePath $OutputFile -Append -Encoding UTF8
}

function Write-LogError {
    param([string]$Message)
    $logMsg = "[ERROR] $Message"
    Write-Host $logMsg -ForegroundColor Red
    # Write to stderr for Go to capture
    [System.Console]::Error.WriteLine($logMsg)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    "$timestamp $logMsg" | Out-File -FilePath $OutputFile -Append -Encoding UTF8
}

function Write-LogDebug {
    param([string]$Message)
    if ($Verbose) {
        $logMsg = "[DEBUG] $Message"
        Write-Host $logMsg -ForegroundColor Gray
        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "$timestamp $logMsg" | Out-File -FilePath $OutputFile -Append -Encoding UTF8
    }
}

# Print usage information
function Show-Usage {
    @"
$SCRIPT_NAME v$SCRIPT_VERSION - Symphony Target Bindings Manager

DESCRIPTION:
    Adds connected registry monitor and staging status monitor bindings to Symphony Target CRs.
    Converts C# BindingSpec logic to Kubernetes Custom Resource updates.

USAGE:
    .\$SCRIPT_NAME -Namespace <namespace> -Targets <target1,target2> [OPTIONS]

REQUIRED PARAMETERS:
    -Namespace          Kubernetes namespace containing the Target CRs
    -Targets            Target name(s) - single name or comma-separated list

OPTIONS:
    -DryRun             Preview changes without applying them
    -Verbose            Enable verbose logging
    -TopologyName       Topology name to add bindings to (default: 'staging-topology')
    -BackupDir          Directory for CR backups (default: ./backups)
    -AddComponents      Also add components section alongside topologies
    -ImageList          Image list for staging-status component (default: 'demo-image-05:latest')
    -ImageRefKey        Image reference key (default: 'demo-image-05:latest')
    -ImageRefValue      Image reference value (default: 'lcc2-solution2-1.0.0.1')
    -Help               Show this help message

EXAMPLES:
    # Add bindings to a single target
    .\$SCRIPT_NAME -Namespace symphony-system -Targets my-target

    # Add bindings to multiple targets with dry-run
    .\$SCRIPT_NAME -Namespace symphony-system -Targets target1,target2 -DryRun

    # Add both topologies and components with custom image settings
    .\$SCRIPT_NAME -Namespace default -Targets target03 -AddComponents -ImageList "my-image:v1.0" -Verbose

    # Verbose mode with custom topology
    .\$SCRIPT_NAME -Namespace symphony-system -Targets my-target -Verbose -TopologyName staging-topology

SECTIONS ADDED:
    1. Topologies: Connected Registry Monitor and Staging Status Monitor bindings
    2. Components (optional): Connection string and staging status components with image references

PREREQUISITES:
    - Target CRs must exist in the specified namespace
    - kubectl must be installed and configured

"@
}

# Parse JSON input from Symphony script provider
function Read-JsonInput {
    param([string]$JsonFilePath)
    
        if ([string]::IsNullOrEmpty($JsonFilePath)) {
        Write-LogError "No JSON input file provided"
        throw "No JSON input file provided"
    }
    
    if (-not (Test-Path $JsonFilePath)) {
        Write-LogError "JSON input file not found: $JsonFilePath"
        throw "JSON input file not found: $JsonFilePath"
    }
    
    Write-LogDebug "Reading JSON input from: $JsonFilePath"
    
    try {
        $jsonContent = Get-Content $JsonFilePath -Raw | ConvertFrom-Json
        
        # Extract values from JSON
        $script:Namespace = if ($jsonContent.namespace) { $jsonContent.namespace } else { "default" }
        $script:Targets = if ($jsonContent.targets) { $jsonContent.targets } else { "" }
        
        # Parse optional flags
        if ($jsonContent.add_components -eq "true" -or $jsonContent.add_components -eq $true) {
            $script:AddComponents = $true
        }
        
        if ($jsonContent.verbose -eq "true" -or $jsonContent.verbose -eq $true) {
            $script:Verbose = $true
        }
        
        # Parse component-specific settings
        if ($jsonContent.image_list) { $script:ImageList = $jsonContent.image_list }
        if ($jsonContent.image_ref_key) { $script:ImageRefKey = $jsonContent.image_ref_key }
        if ($jsonContent.image_ref_value) { $script:ImageRefValue = $jsonContent.image_ref_value }
        
        # Validate required arguments
        if ([string]::IsNullOrEmpty($script:Namespace)) {
            Write-LogError "Namespace is required in JSON input"
            throw "Namespace is required in JSON input"
        }

        if ([string]::IsNullOrEmpty($script:Targets)) {
            Write-LogError "Target name(s) required in JSON input"
            throw "Target name(s) required in JSON input"
        }

        Write-LogDebug "JSON parsed: namespace=$($script:Namespace), targets=$($script:Targets), add_components=$($script:AddComponents), verbose=$($script:Verbose)"
    }
    catch {
        Write-LogError "Failed to parse JSON input: $($_.Exception.Message)"
        throw "Failed to parse JSON input: $($_.Exception.Message)"
    }
}

# Create backup directory
function New-BackupDirectory {
    if (-not (Test-Path $BackupDir)) {
        New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
        Write-LogDebug "Created backup directory: $BackupDir"
    }
}

# Backup original Target CR
function Backup-Target {
    param([string]$TargetName)
    
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $backupFile = Join-Path $BackupDir "${TargetName}_${timestamp}.yaml"

    Write-LogDebug "Backing up target $TargetName to $backupFile"
    
    try {
        $result = kubectl get target $TargetName -n $Namespace -o yaml 2>$null
        if ($LASTEXITCODE -eq 0) {
            $result | Out-File -FilePath $backupFile -Encoding UTF8
            Write-LogInfo "Backup created: $backupFile"
            return $backupFile
        } else {
            Write-LogError "Failed to backup target $TargetName"
            return $null
        }
    }
    catch {
        Write-LogError "Failed to backup target ${TargetName}: $($_.Exception.Message)"
        return $null
    }
}

# Check if target exists
function Test-TargetExists {
    param([string]$TargetName)
    
    try {
        kubectl get target $TargetName -n $Namespace 2>$null | Out-Null
        return $LASTEXITCODE -eq 0
    }
    catch {
        return $false
    }
}

# Check if staging topology already exists
function Test-StagingTopologyExists {
    param([string]$TargetName)
    
    try {
        $jsonOutput = kubectl get target $TargetName -n $Namespace -o json 2>$null
        if ($LASTEXITCODE -ne 0) {
            return $false
        }
        
        $targetData = $jsonOutput | ConvertFrom-Json
        $topologies = $targetData.spec.topologies
        
        if ($topologies) {
            foreach ($topology in $topologies) {
                $bindings = $topology.bindings
                if ($bindings -and $bindings.Count -eq 2) {
                    foreach ($binding in $bindings) {
                        if ($binding.role -and $binding.role.Contains("connected-registry-monitor")) {
                            return $true
                        }
                    }
                }
            }
        }
        
        return $false
    }
    catch {
        Write-LogDebug "Error checking staging topology: $($_.Exception.Message)"
        return $false
    }
}

# Generate new topology object
function New-StagingTopology {
    return @{
        device = $TopologyName
        bindings = @(
            @{
                role = "connected-registry-monitor"
                provider = "providers.target.script"
                config = @{
                    applyScript = "get-connected-registry.sh"
                    removeScript = "mock-remove.sh"
                    getScript = "target-get.sh"
                    scriptFolder = "external_distribution/staging"
                }
            },
            @{
                role = "staging-status-monitor"
                provider = "providers.target.script"
                config = @{
                    applyScript = "get-staging-status.sh"
                    removeScript = "mock-remove.sh"
                    getScript = "target-get.sh"
                    scriptFolder = "external_distribution/staging"
                }
            }
        )
    }
}

# Generate components array
function New-Components {
    $imageRefObject = @{}
    $imageRefObject[$ImageRefKey] = @($ImageRefValue)
    
    return @(
        @{
            name = "connection-string"
            type = "connected-registry-monitor"
        },
        @{
            name = "staging-status"
            type = "staging-status-monitor"
            properties = @{
                imageList = @($ImageList)
                imageRef = $imageRefObject
            }
        }
    )
}

# Add bindings to target using kubectl patch
function Add-BindingsToTarget {
    param([string]$TargetName)
    
    Write-LogInfo "Processing target: $TargetName"

    # Check if target exists
    if (-not (Test-TargetExists $TargetName)) {
        Write-LogError "Target $TargetName not found in namespace $Namespace"
        return $false
    }

    # Check if staging topology already exists 
    if (Test-StagingTopologyExists $TargetName) {
        Write-LogWarn "Staging topology with 2 bindings including connected-registry-monitor already exists in $TargetName, skipping"
        return $true
    }

    # Backup original target
    $backupFile = Backup-Target $TargetName
    if (-not $backupFile) {
        return $false
    }

    Write-LogInfo "Adding new staging topology '$TopologyName' with 2 bindings to $TargetName"
    
    # Generate the new topology
    $newTopology = New-StagingTopology
    
    Write-LogDebug "Generated topology object"

    # Create patch operation to add the topology
    $patchOperation = @{
        op = "add"
        path = "/spec/topologies/-"
        value = $newTopology
    }

    # Apply changes using kubectl patch
    if ($DryRun) {
        Write-LogInfo "DRY-RUN: Would add the following topology to ${TargetName}:"
        Write-Host "----------------------------------------"
        $newTopology | ConvertTo-Json -Depth 10
        Write-Host "----------------------------------------"
        
        # Show components if enabled
        if ($AddComponents) {
            Write-LogInfo "DRY-RUN: Would also add the following components:"
            Write-Host "----------------------------------------"
            New-Components | ConvertTo-Json -Depth 10
            Write-Host "----------------------------------------"
        }
    } else {
        try {
            Write-LogInfo "Patching target $TargetName with new topology"
            
            # Force array format for JSON patch - kubectl expects an array even for single operations
            $patchArray = @($patchOperation)
            $patchJson = "[$($patchOperation | ConvertTo-Json -Depth 10 -Compress)]"
            Write-LogDebug "Patch JSON: $patchJson"
            
            # Write patch to temp file to avoid escaping issues
            $tempPatchFile = [System.IO.Path]::GetTempFileName()
            $patchJson | Out-File -FilePath $tempPatchFile -Encoding UTF8 -NoNewline
            
            kubectl patch target $TargetName -n $Namespace --type='json' --patch-file="$tempPatchFile" 2>$null
            $patchResult = $LASTEXITCODE
            
            # Clean up temp file
            Remove-Item -Path $tempPatchFile -Force -ErrorAction SilentlyContinue
            
            if ($LASTEXITCODE -eq 0) {
                Write-LogInfo "Successfully updated target $TargetName with topology"
                Write-LogDebug "About to check ADD_COMPONENTS flag: $AddComponents"
                
                # Add components if enabled
                if ($AddComponents) {
                    Write-LogInfo "Adding components to $TargetName"
                    $componentsArray = New-Components
                    Write-LogDebug "Generated components array"
                    
                    # Create patch for components
                    $componentsPatchOperation = @{
                        op = "add"
                        path = "/spec/components"
                        value = $componentsArray
                    }
                    Write-LogDebug "Created components patch"
                    
                    # Force array format for JSON patch
                    $componentsPatchJson = "[$($componentsPatchOperation | ConvertTo-Json -Depth 10 -Compress)]"
                    
                    # Write components patch to temp file
                    $tempComponentsFile = [System.IO.Path]::GetTempFileName()
                    $componentsPatchJson | Out-File -FilePath $tempComponentsFile -Encoding UTF8 -NoNewline
                    
                    kubectl patch target $TargetName -n $Namespace --type='json' --patch-file="$tempComponentsFile" 2>$null
                    
                    # Clean up temp file
                    Remove-Item -Path $tempComponentsFile -Force -ErrorAction SilentlyContinue
                    
                    if ($LASTEXITCODE -eq 0) {
                        Write-LogInfo "Successfully added components to $TargetName"
                    } else {
                        Write-LogWarn "Failed to add components to $TargetName, but topology was added successfully"
                    }
                } else {
                    Write-LogDebug "ADD_COMPONENTS is false, skipping components"
                }
                Write-LogDebug "Finished topology processing for $TargetName"
                return $true
            } else {
                Write-LogError "Failed to update target $TargetName"
                Write-LogInfo "Restore from backup: kubectl apply -f $backupFile"
                return $false
            }
        }
        catch {
            Write-LogError "Exception during patch operation: $($_.Exception.Message)"
            Write-LogInfo "Restore from backup: kubectl apply -f $backupFile"
            return $false
        }
    }

    Write-LogDebug "Completed processing target: $TargetName"
    Write-LogDebug "About to return from Add-BindingsToTarget function"
    return $true
}

# Main function
function Main {
    param([string[]]$Arguments)
    
    Write-LogInfo "Starting $SCRIPT_NAME v$SCRIPT_VERSION"
    
    # Debug logging - log all parameters and arguments
    Write-LogInfo "=== DEBUG INFORMATION ==="
    Write-LogInfo "Script Arguments Count: $($Arguments.Count)"
    Write-LogInfo "Script Arguments: $($Arguments -join ', ')"
    Write-LogInfo "All Parameters Passed:"
    Write-LogInfo "  -Namespace: '$Namespace'"
    Write-LogInfo "  -Targets: '$Targets'"
    Write-LogInfo "  -DryRun: $DryRun"
    Write-LogInfo "  -Verbose: $Verbose"
    Write-LogInfo "  -TopologyName: '$TopologyName'"
    Write-LogInfo "  -BackupDir: '$BackupDir'"
    Write-LogInfo "  -OutputFile: '$OutputFile'"
    Write-LogInfo "  -AddComponents: $AddComponents"
    Write-LogInfo "  -ImageList: '$ImageList'"
    Write-LogInfo "  -ImageRefKey: '$ImageRefKey'"
    Write-LogInfo "  -ImageRefValue: '$ImageRefValue'"
    Write-LogInfo "  -Help: $Help"
    Write-LogInfo "PowerShell Version: $($PSVersionTable.PSVersion)"
    Write-LogInfo "=== END DEBUG INFORMATION ==="
    
    # Show help if requested
    if ($Help) {
        Show-Usage
        exit 0
    }
    
    # Check if this is being called by Symphony script provider (JSON input)
    # Symphony may pass JSON file path as -Namespace parameter or as positional argument
    $jsonFilePath = $null
    
    if ($Arguments.Count -eq 1 -and (Test-Path $Arguments[0])) {
        # Standard case: JSON file passed as positional argument
        $jsonFilePath = $Arguments[0]
        Write-LogDebug "Symphony mode (positional): parsing JSON input from $jsonFilePath"
    } elseif ($Namespace -and $Namespace.EndsWith('.json') -and (Test-Path $Namespace)) {
        # Symphony passing JSON file path as -Namespace parameter
        $jsonFilePath = $Namespace
        Write-LogDebug "Symphony mode (namespace param): parsing JSON input from $jsonFilePath"
    }
    
    if ($jsonFilePath) {
        Read-JsonInput $jsonFilePath
    } else {
        Write-LogDebug "Command-line mode: using parameters"
        
        # Validate required arguments
        if ([string]::IsNullOrEmpty($Namespace)) {
            Write-LogError "Namespace is required (-Namespace)"
            Show-Usage
            throw "Namespace is required (-Namespace)"
        }

        if ([string]::IsNullOrEmpty($Targets)) {
            Write-LogError "Target name(s) required (-Targets)"
            Show-Usage
            throw "Target name(s) required (-Targets)"
        }

        Write-LogDebug "Parameters: namespace=$Namespace, targets=$Targets, dry-run=$DryRun"
    }
    
    New-BackupDirectory

    # Convert comma-separated targets to array
    $targetArray = $Targets -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }
    
    $successCount = 0
    $totalCount = $targetArray.Count
    
    Write-LogInfo "Processing $totalCount target(s) in namespace $Namespace"
    
    # Process each target
    foreach ($target in $targetArray) {
        Write-LogDebug "About to process target: $target"
        
        if (Add-BindingsToTarget $target) {
            $successCount++
            Write-LogDebug "Successfully processed target: $target (count: $successCount)"
        } else {
            Write-LogDebug "Failed to process target: $target"
        }
        Write-Host "" # Add spacing between targets
    }

    Write-LogDebug "Completed processing all targets. Success: $successCount, Total: $totalCount"
    
    # Summary
    Write-Host "========================================"
    Write-LogInfo "Summary: $successCount/$totalCount targets processed successfully"
    
    # Create JSON output for Symphony script provider
    if ($jsonFilePath) {
        # Extract the file ID from the input JSON path
        $inputFileName = Split-Path -Leaf $jsonFilePath
        $fileId = $inputFileName -replace '\.json$', ''
        $outputFile = "${fileId}-output.json"
        
        Write-LogDebug "Creating output file: $outputFile for input: $inputFileName"
        
        $statusCode = if ($successCount -eq $totalCount) { 200 } else { 500 }
        
        $outputData = @{
            status = $statusCode
            message = "Processed $successCount/$totalCount targets"
            targets_processed = $successCount
            total_targets = $totalCount
        }
        
        $outputData | ConvertTo-Json | Out-File -FilePath $outputFile -Encoding UTF8
        Write-LogInfo "JSON output written to: $outputFile"
    }
    
    if ($DryRun) {
        Write-LogInfo "DRY-RUN completed. No changes were applied."
        Write-LogInfo "Remove -DryRun flag to apply changes."
    } else {
        if ($successCount -eq $totalCount) {
            Write-LogInfo "All targets updated successfully!"
        } else {
            $errorMsg = "Some targets failed to update. Check logs above for details."
            Write-LogWarn $errorMsg
            # Write detailed error to stderr for Go to capture
            [System.Console]::Error.WriteLine("SCRIPT_ERROR: $errorMsg")
            exit 1
        }
    }
}

# Global error handler for Go integration
trap {
    $errorMsg = "UNHANDLED_EXCEPTION: $($_.Exception.Message)"
    Write-LogError $errorMsg
    [System.Console]::Error.WriteLine($errorMsg)
    exit 1
}

# Script entry point
if ($MyInvocation.InvocationName -ne '.') {
    try {
        Main $args
    }
    catch {
        $errorMsg = "MAIN_EXCEPTION: $($_.Exception.Message)"
        Write-LogError $errorMsg
        [System.Console]::Error.WriteLine($errorMsg)
        exit 1
    }
}
