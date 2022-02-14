<#
.SYNOPSIS
    Shrinks an Azure Managed Disk via a resize process. Insipiration is to enable Ephemeral Disk use post image builds (if the OS disk is too big for the instance size)
    Similar to how Nerdio, Project Hydra and WVD Admin handle the exercise
.DESCRIPTION
    Shrinks an Azure Managed Disk via a resize process. Original source code basis here https://jrudlin.github.io/2019-08-27-shrink-azure-vm-osdisk/
    Additional snippets of code borrowed from Nerdio (for in guest partition shrink) https://github.com/Get-Nerdio/NMW/blob/main/scripted-actions/azure-runbooks/Shrink%20OS%20Disk.ps1
    Updated code, added error handling, simplified and added logic
.PARAMETER LogPath
    Logpath output for all operations
.PARAMETER LogRollover
    Number of days before logfiles are rolled over. Default is 5
.PARAMETER VMName
    Name of which to target
.PARAMETER SubscriptionID
    Subscription ID (not name) of the VM
.PARAMETER ResourceGroup
    Resource Group of the VM
.PARAMETER DiskSizeGB
    Size to set the new disk too (integer)
.PARAMETER Cleanup
    If set, will remove all non critical components. Will NOT delete snapshot and source OS disk
.PARAMETER TakeSnapshot
    Will create a snapshot prior to any work
.PARAMETER PartitionGuestOSDisk
    Will attempt to repartition the OS disk within the guest

.EXAMPLE
    Will target the VM named VMName in Resource Group RGName in Subscription SubID. Will resize the guest partition to 63 GiB, shrink the disk to 64 GiB, and cleanup after itself
    .\ShrinkAzureOSDisk.ps1 -VMName "VMName" -ResourceGroup "RGName" -SubscriptionID "SubID" -DiskSizeGB "64" -Cleanup -PartitionGuestOSDisk
#>

#region Params
# ============================================================================
# Parameters
# ============================================================================
Param(
    [Parameter(Mandatory = $false)]
    [string]$LogPath = "C:\Logs\ShrinkAzureOSDisk.log", 

    [Parameter(Mandatory = $false)]
    [int]$LogRollover = 5, # number of days before logfile rollover occurs

    [Parameter(Mandatory = $true)]
    [string]$SubscriptionID = "",

    [Parameter(Mandatory = $true)]
    [string]$VMName = "",

    [Parameter(Mandatory = $true)]
    [string]$ResourceGroup = "",

    [Parameter(Mandatory = $true)]
    [int]$DiskSizeGB = "64",

    [Parameter(Mandatory = $false)]
    [switch]$Cleanup,

    [Parameter(Mandatory = $false)]
    [switch]$TakeSnapshot,

    [Parameter(Mandatory = $false)]
    [switch]$PartitionGuestOSDisk

)
#endregion

#region Functions
# ============================================================================
# Functions
# ============================================================================
function Write-Log {
    [CmdletBinding()]
    Param
    (
        [Parameter(Mandatory = $true,
            ValueFromPipelineByPropertyName = $true)]
        [ValidateNotNullOrEmpty()]
        [Alias("LogContent")]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [Alias('LogPath')]
        [string]$Path = $LogPath,
        
        [Parameter(Mandatory = $false)]
        [ValidateSet("Error", "Warn", "Info")]
        [string]$Level = "Info",
        
        [Parameter(Mandatory = $false)]
        [switch]$NoClobber
    )

    Begin {
        # Set VerbosePreference to Continue so that verbose messages are displayed.
        $VerbosePreference = 'Continue'
    }
    Process {
        
        # If the file already exists and NoClobber was specified, do not write to the log.
        if ((Test-Path $Path) -AND $NoClobber) {
            Write-Error "Log file $Path already exists, and you specified NoClobber. Either delete the file or specify a different name."
            Return
        }

        # If attempting to write to a log file in a folder/path that doesn't exist create the file including the path.
        elseif (!(Test-Path $Path)) {
            Write-Verbose "Creating $Path."
            $NewLogFile = New-Item $Path -Force -ItemType File
        }

        else {
            # Nothing to see here yet.
        }

        # Format Date for our Log File
        $FormattedDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"

        # Write message to error, warning, or verbose pipeline and specify $LevelText
        switch ($Level) {
            'Error' {
                Write-Error $Message
                $LevelText = 'ERROR:'
            }
            'Warn' {
                Write-Warning $Message
                $LevelText = 'WARNING:'
            }
            'Info' {
                Write-Verbose $Message
                $LevelText = 'INFO:'
            }
        }
        
        # Write log entry to $Path
        "$FormattedDate $LevelText $Message" | Out-File -FilePath $Path -Append
    }
    End {
    }
}

function Start-Stopwatch {
    Write-Log -Message "Starting Timer" -Level Info
    $Global:StopWatch = [System.Diagnostics.Stopwatch]::StartNew()
}

function Stop-Stopwatch {
    Write-Log -Message "Stopping Timer" -Level Info
    $StopWatch.Stop()
    if ($StopWatch.Elapsed.TotalSeconds -le 1) {
        Write-Log -Message "Script processing took $($StopWatch.Elapsed.TotalMilliseconds) ms to complete." -Level Info
    }
    else {
        Write-Log -Message "Script processing took $($StopWatch.Elapsed.TotalSeconds) seconds to complete." -Level Info
    }
}

function RollOverlog {
    $LogFile = $LogPath
    $LogOld = Test-Path $LogFile -OlderThan (Get-Date).AddDays(-$LogRollover)
    $RolloverDate = (Get-Date -Format "dd-MM-yyyy")
    if ($LogOld) {
        Write-Log -Message "$LogFile is older than $LogRollover days, rolling over" -Level Info
        $NewName = [io.path]::GetFileNameWithoutExtension($LogFile)
        $NewName = $NewName + "_$RolloverDate.log"
        Rename-Item -Path $LogFile -NewName $NewName
        Write-Log -Message "Old logfile name is now $NewName" -Level Info
    }    
}

function StartIteration {
    Write-Log -Message "--------Starting Iteration--------" -Level Info
    RollOverlog
    Start-Stopwatch
}

function StopIteration {
    Stop-Stopwatch
    Write-Log -Message "--------Finished Iteration--------" -Level Info
}

#endregion

#region Variables
# ============================================================================
# Variables
# ============================================================================
# Set Variables
#endregion

#Region Execute
# ============================================================================
# Execute
# ============================================================================
StartIteration

#region Azure prep
#----------------------------------------------------------------------------
# Handle Modules
#----------------------------------------------------------------------------
If (Get-Module -ListAvailable -Name "Az.Storage") {
    Write-Log -Message "Az.Storage module present, continuing" -Level Info
} else {
    try {
        Write-Log -Message "Az.Storage module not present. Attempting import of Az Module" -Level Warn
        Import-Module -name Az -force -ErrorAction Stop
        Write-Log -Message "Sucess: Az Module Imported"
    }
    catch {
        Write-Log -Message "Cannot import Az Module. Exit script"
        Write-Log -Message $_ -Level Warn
        StopIteration
        Exit 1
    }
}

# Provide Azure admin credentials
#----------------------------------------------------------------------------
# Connect to Azure
#----------------------------------------------------------------------------
write-Log -Message "Connecting to Azure Account" -Level Info
try {
    Connect-AzAccount -ErrorAction Stop | Out-Null
    Write-Log -Message "Success: connected to Azure" -Level Info
}
catch {
    Write-Log -Message "Failed to connect to Azure. Exit script" -Level Warn
    Write-Log -Message $_ -Level Warn
    StopIteration
    Exit 1
}

# Provide the subscription Id of the subscription
Write-Log -Message "Setting Azure Subscription to: $($SubscriptionID)" -Level Info
try {
    Select-AzSubscription -Subscription $SubscriptionID -ErrorAction Stop | Out-Null
}
catch {
    Write-Log -Message "Failed to connect to Azure. Exit script" -Level Warn
    Write-Log -Message $_ -Level Warn
    StopIteration
    Exit 1
}
#endregion

#region PartitionOSDisk
#----------------------------------------------------------------------------
# Partition Disk within guest sourced from Nerdio Library 
# https://github.com/Get-Nerdio/NMW/blob/main/scripted-actions/azure-runbooks/Shrink%20OS%20Disk.ps1
#----------------------------------------------------------------------------
if ($PartitionGuestOSDisk.IsPresent) {
    Write-Log -Message "PartitionGuestOSDisk is present. Attempting to resize partition in guest" -Level Info
    $NewPartitionSize = $DiskSizeGB - 1
$PartitionScriptBlock = @"
if ((Get-Service -Name defragsvc).Status -eq "Stopped") {
    write-output "Defragsvc started"
    Set-Service -Name defragsvc -Status Running -StartupType Manual
}
`$Partition = get-partition | Where-Object isboot -eq `$true 
`$Disk = Get-CimInstance -ClassName Win32_LogicalDisk | Where-Object DeviceID -eq `$(`$partition.DriveLetter + ':') 
`$DiskUsed = `$Disk.Size - `$Disk.FreeSpace
write-output ("Disk space used: " + `$DiskUsed / 1GB + "GB")
if (`$DiskUsed / 1GB -lt $NewPartitionSize) {
    `$Partition | Resize-Partition -Size $NewPartitionSize`GB
}
else {
    Throw "Not enough free space to resize partition"
}
"@ 
    $PartitionScriptBlock | Out-File .\partitionscriptblock.ps1

    try {
        Write-Log -Message "Attempting to start VM $($VMName)"
        Start-AzVM -ResourceGroupName $ResourceGroup -Name $VMName -ErrorAction Stop | Out-Null
        Write-Log -Message "Attempting to re-partition OS disk within the VM $($VMName)" -Level Info
        $Result = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroup -VMName $VMName -ScriptPath .\partitionscriptblock.ps1 -CommandId runpowershellscript -ErrorAction Stop
        if ($Result.Value[1].Message -match "Not enough free space") {
            Write-Log -Message "Not enough free space to resize partition" -Level Warn
            Write-Log -Message $Result.Value[1].Message -Level Warn
        }
        if ($Result.Value[1].Message -match "The partition is already the requested size") {
            Write-Log -Message "The partition is already the requested size." -Level Info
            Write-Log -Message $Result.Value[1].Message -Level Info
        }
        Write-Log -Message $Result.Value[0].Message -Level Info
        Write-Log -Message "Attempting to Stop VM $($VMName)"
        Stop-AzVM -ResourceGroupName $ResourceGroup -Name $VMName -Force -ErrorAction Stop | Out-Null
        Write-Log -Message "Success: Stopped VM $($VMName)"
    }
    catch {
        Write-Log -Message $_ -Level Warn
        StopIteration
        Exit 1
    }
}
#endregion

#region Machine power and snapshots
#----------------------------------------------------------------------------
# Check Machine
#----------------------------------------------------------------------------
Write-Log -Message "Checking source VM: $($VMName) power state" -Level Info
if (((Get-AzVM -Name $VMName -ResourceGroupName $ResourceGroup -Status).Statuses[1].DisplayStatus) -eq "VM running") {
    Write-Log -Message "VM: $($VMName) is running, powering off" -Level Info
    try {
        Stop-AzVM -Name $VMName -ResourceGroupName $ResourceGroup -force -ErrorAction Stop | Out-Null
        Write-Log -Message "Success: stopped VM: $($VMName)" -Level Info
    }
    catch {
        Write-Log -Message "Failed to power off VM: $($VMName). Exit script" -Level Warn
        Write-Log -Message $_ -Level Warn
        StopIteration
        Exit 1
    }
}
else {
    Write-Log -Message "VM: $($VMName) is in state $((Get-AzVM -Name $VMName -ResourceGroupName $ResourceGroup -Status).Statuses[1].DisplayStatus). Proceeding"
}

#----------------------------------------------------------------------------
# Snapshot
#----------------------------------------------------------------------------
if ($TakeSnapshot.IsPresent) {
    Write-Log -Message "TakeSnapshot has been selected. A snapshot of the OS Disk will be created, and not cleaned up" -Level Info
    try {
        Write-Log -message "Get VM: $($VMName) details for snapshot"
        $VM = Get-AzVM -Name $VMName -ResourceGroupName $ResourceGroup -ErrorAction Stop
        Write-Log -Message "Create Snapshot config" -Level Info
        $Snap = New-AzSnapshotConfig -SourceUri ($VM.StorageProfile.OsDisk.ManagedDisk.Id) -Location $VM.Location -CreateOption "Copy" -ErrorAction Stop
        Write-Log -Message "Attempting to create snapshot" -Level Info
        $NewSnap = New-AzSnapshot -Snapshot $Snap -SnapshotName ("snap-" + $VM.StorageProfile.OsDisk.Name) -ResourceGroupName $ResourceGroup -ErrorAction Stop
        Write-Log -Message "Success: Snapshot created: $($NewSnap.Name)"
    }
    catch {
        Write-Log -Message "Failed to create snapshot. Exit script" -Level Warn
        Write-Log -Message $_
        StopIteration
        Exit 1
    }
}
else {
    Write-Log -message "Takesnapshot is not present, no snapshot will be created" -Level Warn
}
#endregion

#region VM Spec and OS Disk details
#----------------------------------------------------------------------------
# Get VM Details
#----------------------------------------------------------------------------
try {
    Write-Log -Message "Getting VM details for VM: $($VMName)"
    $VM = Get-AzVM -Name $VMName -ResourceGroupName $ResourceGroup -ErrorAction Stop
    # Get OS Disk Details and check size
    $CurrentDiskSize = (Get-AzDisk -Name ($VM.StorageProfile.OsDisk.Name) -ResourceGroupName $VM.ResourceGroup).DiskSizeGB
    if ($CurrentDiskSize -lt $DiskSizeGB) {
        Write-Log -Message "Source Disk is already smaller than the target disk size. Cannot continue. Exit script" -Level Warn
        StopIteration
        Exit 0
    }
    else {
        Write-Log -message "Source Disk is $($CurrentDiskSize) GiB and will be resized to $($DiskSizeGB) GiB" -Level Info
    }

    Write-Log -Message "Getting OS disk details" -Level Info
    $Disk = Get-AzDisk -DiskName ($VM.StorageProfile.OsDisk.Name) -ErrorAction Stop
    # Get SAS URI for the Managed disk
    Write-Log -Message "Attempting to create and retrieve SAS URI for disk $($Disk.Name)" -Level Info
    $SAS = Grant-AzDiskAccess -ResourceGroupName $ResourceGroup -DiskName $Disk.Name -Access "Read" -DurationInSecond 600000 -ErrorAction Stop
    Write-Log -Message "Success: SAS URI is $($SAS.AccessSAS) " -Level Info
}
catch {
    Write-Log "Could not retrieve VM Details for VM: $($VMName), disk details or create a SAS URI for the OS disk: $($VM.StorageProfile.OsDisk.Name). Exit script"
    Write-Log -Message $_ -Level Warn
    StopIteration
    Exit 1
}
#endregion

#region storage accounts
#----------------------------------------------------------------------------
# Handle Storage Accounts
#----------------------------------------------------------------------------
# Provide Temp storage account details for transfer
Write-Log -Message "Setting storage account details" -Level Info
$StorageAccountName = "shrink" + [system.guid]::NewGuid().tostring().replace('-', '').substring(1, 18)
Write-Log -Message "Storage account name is: $($StorageAccountName)" -Level Info
# Name of the storage container where the temp disk will be stored
$StorageContainerName = $StorageAccountName
Write-Log -Message "Storage account container name is: $($StorageAccountName)" -Level Info
# Provide the temp name of the VHD file
$DestinationVHDFileName = "$($VM.StorageProfile.OsDisk.Name).vhd"
Write-Log -Message "Destination VHD file name is: $($DestinationVHDFileName)" -Level Info

try {
    # Create the context for the storage account which will be used to copy the disk to the storage account 
    Write-Log -Message "Attempting to create storage account: $($StorageAccountName)" -Level Info
    $StorageAccount = New-AzStorageAccount -ResourceGroupName $ResourceGroup -Name $StorageAccountName -SkuName "Standard_LRS" -Location $VM.Location -ErrorAction Stop
    $DestinationContext = $StorageAccount.Context
    Write-Log -Message "Attempting to create storage account container: $($StorageAccountName)" -Level Info
    $Container = New-AzStorageContainer -Name $StorageContainerName -Permission "Off" -Context $DestinationContext -ErrorAction Stop
    Write-Log -Message "Success: created storage account: $($StorageAccountName) and container: $($StorageAccountName)" -Level Info
}
catch {
    Write-Log -Message "Failed to create storage account for transfer. Exit script" -Level Warn
    Write-Log -Message $_ -Level Warn
    StopIteration
    Exit 1
}
#endregion

#region copy source data
#----------------------------------------------------------------------------
# Copy the OS disk to the storage account
#----------------------------------------------------------------------------
try {
    Write-Log -Message "Attempting disk transfer for: $($VM.StorageProfile.OsDisk.Name) to storage account container" -Level Info
    Start-AzStorageBlobCopy -AbsoluteUri $SAS.AccessSAS -DestContainer $StorageContainerName -DestBlob $DestinationVHDFileName -DestContext $DestinationContext -ErrorAction Stop | Out-null
    $Sleep = "30"
    while (($State = Get-AzStorageBlobCopyState -Context $DestinationContext -Blob $DestinationVHDFileName -Container $StorageContainerName).Status -ne "Success") { 
        Write-Log -Message "Copy status is $($State.Status), Bytes copied: $($State.BytesCopied) of: $($State.TotalBytes). Sleeping for $($Sleep) seconds" -Level Info
        Start-Sleep -Seconds $Sleep 
    }
    Write-Log -Message "Copy status is $($State.Status). disk transfer to storage account container complete" -Level Info
}
catch {
    Write-Log -Message "Failed to transfer disk: $($VM.StorageProfile.OsDisk.Name). Exit script" -Level Warn
    Write-Log -Message $_ -Level Warn
    StopIteration
    Exit 1
}

#----------------------------------------------------------------------------
# Revoke SAS token
#----------------------------------------------------------------------------
try {
    Write-Log -Message "Attempting to revoke disk access for disk $($Disk.Name)" -Level Info
    Revoke-AzDiskAccess -ResourceGroupName $ResourceGroup -DiskName $Disk.Name | Out-Null
    Write-Log -Message "Success: revoked disk access for disk $($Disk.Name)" -Level Info
}
catch {
    Write-Log -Message "Failed to remove SAS Token" -Level Warn
    Write-Log -Message $_ -Level Warn
    StopIteration
    Exit 1
}
#endregion

#region empty disk prep and transfer
#----------------------------------------------------------------------------
# Create empty disk to get footer
#----------------------------------------------------------------------------
$Emptydiskforfootername = "$($VM.StorageProfile.OsDisk.Name)-empty.vhd"
Write-Log -Message "Diskname for empty disk is: $($Emptydiskforfootername)" -Level Info
# Empty disk URI
Write-Log -Message "Attempting to create empty disk: $($Emptydiskforfootername)" -Level Info
try {
    $DiskConfig = New-AzDiskConfig -Location $VM.Location -CreateOption "Empty" -DiskSizeGB $DiskSizeGB -HyperVGeneration $Disk.HyperVGeneration
    $DataDisk = New-AzDisk -ResourceGroupName $ResourceGroup -DiskName $Emptydiskforfootername -Disk $DiskConfig
    Write-Log -Message "Succesfully created empty disk: $($Emptydiskforfootername)" -Level Info
}
catch {
    Write-Log -Message "Failed to create disk" -Level Warn
    Write-Log -Message $_ -Level Warn
    StopIteration
    Exit 1
}

#----------------------------------------------------------------------------
# Add disk to VM
#----------------------------------------------------------------------------
Write-Log -Message "Attempting to attach empty disk: $($Emptydiskforfootername) to VM: $($VMName)" -Level Info
try {
    Add-AzVMDataDisk -VM $VM -Name $Emptydiskforfootername -CreateOption "Attach" -ManagedDiskId $DataDisk.Id -Lun "63" | Out-Null
    Update-AzVM -ResourceGroupName $ResourceGroup -VM $VM | Out-Null
    Write-Log -Message "Success: attached empty disk: $($Emptydiskforfootername) to VM: $($VMName)" -Level Info
}
catch {
    Write-Log -Message "Failed to attach disk" -Level Warn
    Write-Log -Message $_ -Level Warn
    StopIteration
    Exit 1
}

#----------------------------------------------------------------------------
# Get SAS token for the empty disk
#----------------------------------------------------------------------------
try {
    Write-Log -Message "Attempting to create and retrieve SAS URI for disk $($Emptydiskforfootername)" -Level Info
    $SAS = Grant-AzDiskAccess -ResourceGroupName $ResourceGroup -DiskName $Emptydiskforfootername -Access 'Read' -DurationInSecond 600000
    Write-Log -Message "Success: SAS URI is $($SAS.AccessSAS) " -Level Info
}
catch {
    Write-Log -Message "Failed to get SAS URI for disk $($Emptydiskforfootername)" -Level Warn
    Write-Log -Message $_ -Level Warn
    StopIteration
    Exit 1
}

#----------------------------------------------------------------------------
# Copy the empty disk to blob storage
#----------------------------------------------------------------------------
try {
    Write-Log -Message "Attempting disk transfer for: $($Emptydiskforfootername) to storage account container" -Level Info
    Start-AzStorageBlobCopy -AbsoluteUri $SAS.AccessSAS -DestContainer $storageContainerName -DestBlob $Emptydiskforfootername -DestContext $DestinationContext -ErrorAction Stop | Out-Null
    $Sleep = "30"
    while (($state = Get-AzStorageBlobCopyState -Context $destinationContext -Blob $emptydiskforfootername -Container $storageContainerName).Status -ne "Success") { 
        Write-Log -Message "Copy status is $($State.Status), Bytes copied: $($State.BytesCopied) of: $($State.TotalBytes). Sleeping for $($Sleep) seconds" -Level Info
        Start-Sleep -Seconds $Sleep
    }
    Write-Log -Message "Copy status is $($State.Status). disk transfer to storage account container complete" -Level Info
}
catch {
    Write-Log -Message "Failed to transfer disk: $($Emptydiskforfootername). Exit script" -Level Warn
    Write-Log -Message $_ -Level Warn
    StopIteration
    Exit 1
}

#----------------------------------------------------------------------------
# Revoke SAS token
#----------------------------------------------------------------------------
try {
    Write-Log -Message "Attempting to revoke Disk Access for disk $($Emptydiskforfootername)" -Level Info
    Revoke-AzDiskAccess -ResourceGroupName $resourceGroup -DiskName $Emptydiskforfootername | Out-Null
    Write-Log -Message "Success: Revoked Disk Access for disk $($Emptydiskforfootername)" -Level Info
}
catch {
    Write-Log -Message "Failed to remove SAS Token" -Level Warn
    Write-Log -Message $_ -Level Warn
    StopIteration
    Exit 1
}

#----------------------------------------------------------------------------
# Remove temp empty disk from VM
#----------------------------------------------------------------------------
try {
    Write-Log -Message "Attempting to removing temp disk $($Emptydiskforfootername) from VM: $($VMName)" -Level Info
    Remove-AzVMDataDisk -VM $VM -DataDiskNames $Emptydiskforfootername -ErrorAction Stop | Out-Null
    Update-AzVM -ResourceGroupName $resourceGroup -VM $VM -ErrorAction Stop | Out-Null
    Write-Log -Message "Success: Removed temp disk $($Emptydiskforfootername) from VM: $($VMName)" -Level Info
}
catch {
    Write-Log -Message "Failed to remove temp disk $($Emptydiskforfootername) from VM: $($VMName)" -Level Warn
    Write-Log -Message $_ -Level Warn
    StopIteration
    Exit 1
}

#----------------------------------------------------------------------------
# Delete temp disk
#----------------------------------------------------------------------------
try {
    Write-Log -Message "Attempting to delete temp disk $($Emptydiskforfootername)" -Level Info
    Remove-AzDisk -ResourceGroupName $resourceGroup -DiskName $Emptydiskforfootername -Force -ErrorAction Stop | Out-Null
    Write-Log -Message "Success: deleted temp disk $($Emptydiskforfootername)" -Level Info
}
catch {
    Write-Log -Message "Failed to delete temp disk $($Emptydiskforfootername)" -Level Warn
    Write-Log -Message $_ -Level Warn
    StopIteration
    Exit 1
}
#endregion

#region footer management
#----------------------------------------------------------------------------
# Get Blobs
#----------------------------------------------------------------------------
try {
    Write-Log -Message "Attempting to get blob info" -Level Info
    $EmptyDiskblob = Get-AzStorageBlob -Context $DestinationContext -Container $StorageContainerName -Blob $Emptydiskforfootername -ErrorAction Stop
    $OsDisk = Get-AzStorageBlob -Context $DestinationContext -Container $StorageContainerName -Blob $DestinationVHDFileName
    Write-Log -Message "Get footer details for empty disk" -Level Info
    $Footer = New-Object -TypeName byte[] -ArgumentList 512
    $Downloaded = $EmptyDiskblob.ICloudBlob.DownloadRangeToByteArray($Footer, 0, $EmptyDiskblob.Length - 512, 512)
    $OsDisk.ICloudBlob.Resize($EmptyDiskblob.Length)
    $footerStream = New-Object -TypeName System.IO.MemoryStream -ArgumentList (, $Footer)
    Write-Log -Message "Write footer of empty disk to OSDisk" -Level Info
    $OsDisk.ICloudBlob.WritePages($FooterStream, $EmptyDiskblob.Length - 512)
    Write-Log -Message "Removing empty disk blobs" -Level Info
    $EmptyDiskblob | Remove-AzStorageBlob -Force
    Write-Log -Message "Success: Footers written and blobs cleaned" -Level Info
}
catch {
    Write-Log -Message "Failed to manage blob info and set footers" -Level Warn
    Write-Log -Message $_ -Level Warn
    StopIteration
    Exit 1
}
#endregion

#region new disk
#----------------------------------------------------------------------------
# New Managed Disk
#----------------------------------------------------------------------------
$NewDiskName = $Disk.Name + "_" + $DiskSizeGB
Write-Log -Message "New disk name: $($NewDiskName)" -Level Info

# Create the new disk with the same SKU as the current one
# Get the new disk URI
$vhdUri = $OsDisk.ICloudBlob.Uri.AbsoluteUri
Write-Log -Message "VHD URI is: $($vhdUri)" -Level Info

#----------------------------------------------------------------------------
# Disk Options
#----------------------------------------------------------------------------
try {
    Write-Log -Message "Attempting to create new disk: $($NewDiskName)" -Level Info
    # Handle zones
    if ($null -eq $Disk.zones) {
        Write-Log -Message "Zone configuration not found on source disk" -Level Info
        $DiskConfig = New-AzDiskConfig -AccountType $Disk.Sku.Name -Location $VM.location -DiskSizeGB $DiskSizeGB -SourceUri $vhdUri -CreateOption "Import" -StorageAccountId $StorageAccount.Id -HyperVGeneration $Disk.HyperVGeneration -ErrorAction Stop
    } else {
        Write-Log -Message "Zone configuration found on source disk" -Level Info
        $DiskConfig = New-AzDiskConfig -Zone $Disk.zones -AccountType $Disk.Sku.Name -Location $VM.location -DiskSizeGB $DiskSizeGB -SourceUri $vhdUri -CreateOption "Import" -StorageAccountId $StorageAccount.Id -HyperVGeneration $Disk.HyperVGeneration -ErrorAction Stop
    }

    # Create Managed disk
    $NewManagedDisk = New-AzDisk -DiskName $NewDiskName -Disk $DiskConfig -ResourceGroupName $ResourceGroup -ErrorAction Stop
    Write-Log -Message "Success: created new disk: $($NewDiskName)" -Level Info
}
catch {
    Write-Log -Message "Failed to create new disk: $($NewDiskName)" -Level Warn
    Write-Log -Message $_ -Level Warn
    StopIteration
    Exit 1
}
#endregion

#region VM update
#----------------------------------------------------------------------------
# Set the new OS disk for the VM
#----------------------------------------------------------------------------
try {
    Write-Log -Message "Attempting to set OS disk to: $($NewManagedDisk.Name) for VM: $($VMName)" -Level Info
    Set-AzVMOSDisk -VM $VM -ManagedDiskId $NewManagedDisk.Id -Name $NewManagedDisk.Name | Out-Null
    # Update the VM with the new OS disk
    Update-AzVM -ResourceGroupName $ResourceGroup -VM $VM | Out-Null
    Write-Log -Message "Success: set OS disk to: $($NewManagedDisk.Name) for VM: $($VMName)" -Level Info
    try {
        Write-Log -Message "Attempting to start VM $($VMName)" -Level Info
        $VM | Start-AzVM | Out-null
        Write-Log -Message "Success: Started VM $($VMName)" -Level Info
    }
    catch {
        Write-Log -Message "Failed to Started VM $($VMName)" -Level Warn
        Write-Log -Message $_ -Level Warn
        StopIteration
        #Exit 1    
    }
}
catch {
    Write-Log -Message "Failed to set OS disk to: $($NewManagedDisk.Name) for VM: $($VMName)" -Level Warn
    Write-Log -Message $_ -Level Warn
    StopIteration
    Exit 1
}

#----------------------------------------------------------------------------
# Wait for VM to boot
#----------------------------------------------------------------------------
Write-Log -Message "Starting to sleep for 90 seconds to allow VM boot"
start-sleep 90
Write-Log -Message "Attempting VM tests for $($VMName)"

#----------------------------------------------------------------------------
# Post switch boot tests
#----------------------------------------------------------------------------
$VmTestScriptBlock = @'
$env:ComputerName
'@ 
$VmTestScriptBlock | Out-File .\vmtestscriptblock.ps1

Try {
    $Result = Invoke-AzVMRunCommand -ResourceGroupName $ResourceGroup -VMName $VMName  -ScriptPath .\vmtestscriptblock.ps1 -CommandId runpowershellscript 

    if ($Result.Status -eq 'Succeeded') {
        Write-Log -Message "Success: $($VMName) booted with new disk $($NewManagedDisk.Name)" -Level Info
    }
    else {
        Write-Log -Message "Fail: $($VMName) did not boot with new disk $($NewManagedDisk.Name). Attempting to revert disks" -Level Warn
        try {
            Write-Log -Message "Attempting stop VM $($VMName)" -Level Info
            $VM | Stop-AzVM -Force -ErrorAction Stop | Out-Null
            Write-Log -Message "Attempting to revert OS disk to $($VM.StorageProfile.OsDisk.Name)" -Level Info
            Set-AzVMOSDisk -VM $VM -ManagedDiskId ($VM.StorageProfile.OsDisk.ManagedDisk.Id) -Name ($VM.StorageProfile.OsDisk.Name) -ErrorAction Stop
            Write-Log -Message "Attempting to update VM" -Level Info
            Update-AzVM -ResourceGroupName $ResourceGroup -VM $VM -ErrorAction Stop
        }
        catch {
            Write-Log -Message $_ -Level Warn
            #StopIteration
        }
    }
}
Catch {
    Write-Log -Message "Fail: $($VMName) did not boot with new disk $($NewManagedDisk.Name). Attempting to revert disks" -Level Warn
    Write-Log -Message "Attempting stop VM $($VMName)" -Level Info
    $VM | Stop-AzVM -Force -ErrorAction Stop | Out-Null
    Write-Log -Message "Attempting to revert OS disk to $($VM.StorageProfile.OsDisk.Name)" -Level Info
    Set-AzVMOSDisk -VM $VM -ManagedDiskId ($VM.StorageProfile.OsDisk.ManagedDisk.Id) -Name ($VM.StorageProfile.OsDisk.Name) -ErrorAction Stop
    Write-Log -Message "Attempting to update VM" -Level Info
    Update-AzVM -ResourceGroupName $ResourceGroup -VM $VM -ErrorAction Stop | Out-Null
}

#endregion

#region cleanup
#----------------------------------------------------------------------------
# Cleanup everything except OS disk and snapshot
#----------------------------------------------------------------------------
if ($Cleanup.IsPresent) {
    Write-Log -Message "Cleanup switch is present. Deleting temp blobs and temp storage accounts" -Level Warn
    try {
        Write-Log -Message "Attempting to remove storage blob: $($OSDisk.Name)" -Level Info
        # Delete old blob storage
        $OsDisk | Remove-AzStorageBlob -Force -ErrorAction Stop
        Write-Log -Message "Success: removed blob: $($OSDisk.Name)" -Level Info
    }
    catch {
        Write-Log -Message "Failed to remove storage blob: $($OSDisk.Name)" -Level Warn
        Write-Log -Message $_ -Level Warn
    }
    try {
        Write-Log -Message "Attempting to remove storage account: $($StorageAccount.StorageAccountName)" -Level Info
        # Delete temp storage account
        $StorageAccount | Remove-AzStorageAccount -Force -ErrorAction Stop
        Write-Log -Message "Success: removed storage account: $($StorageAccount.StorageAccountName)" -Level Info
    }
    catch {
        Write-Log -Message "Failed to remove storage account: $($StorageAccount.StorageAccountName)" -Level Warn
        Write-Log -Message $_ -Level Warn
    }
}
else {
    Write-Log -Message "Cleanup switch not present. Manual cleanup required of temp blobs and storage accounts" -Level Warn
}
#endregion
StopIteration
Exit 0
#endregion