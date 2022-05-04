<#
.SYNOPSIS
    Moves a selected VM and its disks to a target availability zone
.DESCRIPTION
    Moves a selected VM and its disks to a target availability zone
.PARAMETER LogPath
    Logpath output for all operations
.PARAMETER LogRollover
    Number of days before logfiles are rolled over. Default is 5
.PARAMETER subscriptionId
    Sets the Subscription ID for the operation
.PARAMETER ResourceGroup
    Sets the Resource Group Name for the operations
.PARAMETER Location
    Sets the Azure Location
.PARAMETER Zone
    Sets the desired Availability Zone
.PARAMETER CleanupSnapshots
    Cleans up Snapshots after migration (deletes!)
.PARAMETER CleanupSourceDisks
    Cleans up source disks after migration (deletes!)
.PARAMETER IsADC
    Sets Citrix ADC mode - will obtain plan, product, and publisher information for the new machines
    WARNING: You MUST have the supporting LB and IPs at Standard SKU. Basic is NOT supported
.EXAMPLE
  .\ChangeVMAz.ps1 -subscriptionId "89745-888-9978" -ResourceGroup "RG-AE-TEST" -vmName "MyVM" -Location "australiaeast" -Zone 1 -CleanupSnapshots -CleanupSourceDisks 
  Moves the desired VM to AZ1 and cleans up snapshots and source disks. Outputs to C:\Logs\ZoneMigrate_VMName.log
.EXAMPLE
  .\ChangeVMAz.ps1 -subscriptionId "89745-888-9978" -ResourceGroup "RG-AE-TEST" -vmName "MyVM" -Location "australiaeast" -Zone 1 -CleanupSnapshots -CleanupSourceDisks -IsADC
  Moves a Citrix ADC VM to AZ1 and cleans up snapshots and source disks. Outputs to C:\Logs\ZoneMigrate_VMName.log
#>

#region Params
# ============================================================================
# Parameters
# ============================================================================
Param(
    [Parameter(Mandatory = $false)]
    [string]$LogPath = "C:\Logs\ZoneMigrate_$vmName.log", 

    [Parameter(Mandatory = $false)]
    [int]$LogRollover = 5, # number of days before logfile rollover occurs

    [Parameter(Mandatory = $True)]
    [string]$SubscriptionId = "", # subscription ID

    [Parameter(Mandatory = $True)]
    [string]$ResourceGroup = "", # Resource Group Name

    [Parameter(Mandatory = $True)]
    [string]$vmName = "", # VM Name

    [Parameter(Mandatory = $True)]
    [string]$Location = "", # Azure Location

    [Parameter(Mandatory = $True)]
    [ValidateSet("1","2","3")]
    [string]$Zone = "", # Target Zone

    [Parameter(Mandatory = $false)]
    [switch]$CleanupSnapshots, # Cleanup Snapshots

    [Parameter(Mandatory = $false)]
    [switch]$CleanupSourceDisks, # Cleanup Source Disks

    [Parameter(Mandatory = $false)]
    [switch]$IsADC # For Citrix ADC Migrations

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

function ImportModule {
    param (
        [Parameter(Mandatory = $True)]
        [String]$ModuleName
    )
    Write-Log -Message "Importing $ModuleName Module" -Level Info
    try {
        Import-Module -Name $ModuleName -Force -ErrorAction Stop
    }
    catch {
        Write-Log -Message "Failed to Import $ModuleName Module. Exiting" -Level Warn
        StopIteration
        Exit 1
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

function RecreateSourceVM {
    try {
        # Create the basic configuration for the replacement VM
        Write-Log -Message "Creating new configuration for replacement VM $($RestoreVM.Name)" -Level Info
        if ($null -eq $RestoreVM.Zones) {
            $NewVM = New-AzVMConfig -VMName $RestoreVM.Name -VMSize $RestoreVM.HardwareProfile.VmSize -ErrorAction Stop  #Check Zones
        }
        else {
            $NewVM = New-AzVMConfig -VMName $RestoreVM.Name -VMSize $RestoreVM.HardwareProfile.VmSize -Zone $RestoreVM.Zones -ErrorAction Stop  #Check Zones
        }

        # Add the OS disk 
        Write-Log -Message "Adding OS Disk $($RestoreVM.StorageProfile.OsDisk.Name) to VM config: $($RestoreVM.Name)" -Level Info
        if ($RestoreVM.StorageProfile.OsDisk.OsType -eq "Windows") {
            Set-AzVMOSDisk -VM $NewVM -CreateOption Attach -ManagedDiskId $RestoreVM.StorageProfile.OsDisk.ManagedDisk.Id -Name $RestoreVM.StorageProfile.OsDisk.Name -Windows -ErrorAction Stop | Out-Null
        }
        if ($RestoreVM.StorageProfile.OsDisk.OsType -eq "Linux") {
            Set-AzVMOSDisk -VM $NewVM -CreateOption Attach -ManagedDiskId $RestoreVM.StorageProfile.OsDisk.ManagedDisk.Id -Name $RestoreVM.StorageProfile.OsDisk.Name -Linux -ErrorAction Stop | Out-Null
        }

        # Add Data Disks
        foreach ($disk in $RestoreVM.StorageProfile.DataDisks) {
            Write-Log -Message "Adding Data Disk for VM $($VMName)" -Level Info 
            Add-AzVMDataDisk -VM $NewVM -Name $disk.Name -ManagedDiskId $disk.ManagedDisk.Id -Caching $disk.Caching -Lun $disk.Lun -DiskSizeInGB $disk.DiskSizeGB -CreateOption Attach -ErrorAction Stop | Out-Null
        }

        # Add NIC(s) and keep the same NIC as primary
        foreach ($nic in $RestoreVM.NetworkProfile.NetworkInterfaces) {	
            if ($nic.Primary -eq "True") {
                Add-AzVMNetworkInterface -VM $NewVM -Id $nic.Id -Primary -ErrorAction Stop | Out-Null
             }
             else {
                Add-AzVMNetworkInterface -VM $NewVM -Id $nic.Id -ErrorAction Stop | Out-Null
             }
        }

        # Grab Sku for ADC
        if ($IsADC.IsPresent) {
            Write-Log -Message "Citrix ADC switch is present. Using the following plan information" -Level Info
            Write-Log -Message "----Plan Name: $($RestoreVM.Plan.Name)" -Level Info
            Write-Log -Message "----Plan Product: $($RestoreVM.Plan.Product)" -Level Info
            Write-Log -Message "----Plan Publisher: $($RestoreVM.Plan.Publisher)" -Level Info
            $NewVM | Set-AzVMPlan -Name $RestoreVM.Plan.Name -Product $RestoreVM.Plan.Product -Publisher $RestoreVM.Plan.Publisher | Out-Null
        }

        # Handle boot diagnostics
        $BootDiagsStorageAccount = $RestoreVM.DiagnosticsProfile.BootDiagnostics.StorageUri
        $BootDiagsStorageAccount = $BootDiagsStorageAccount -replace "https://",""
        $BootDiagsStorageAccount = $BootDiagsStorageAccount -replace ".blob.core.windows.net/",""

        if ($null -ne $BootDiagsStorageAccount) {
            $NewVM | Set-AzVMBootDiagnostic -Enable -ResourceGroupName $RestoreVM.ResourceGroupName -StorageAccountName $BootDiagsStorageAccount | Out-Null
        }

        # Recreate the VM
        $NewVM | Set-AzVMPlan -Name $RestoreVM.Plan.Name -Product $RestoreVM.Plan.Product -Publisher $RestoreVM.Plan.Publisher | Out-Null

        New-AzVM -ResourceGroupName $RestoreVM.ResourceGroupName -Location $RestoreVM.Location -VM $NewVM -DisableBginfoExtension -ErrorAction Stop | Out-Null

    }
    catch {
        Write-Log -Message "$_" -Level Warn
        Write-Log -Message "Failed to restore source VM. Review logs and build the VM manually" -Level Warn
        Exit 1
    }
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

Write-Log -Message "Setting Azure Subscription to: $($SubscriptionId)" -Level Info

try {
    Select-AzSubscription -Subscriptionid $SubscriptionId -ErrorAction Stop | Out-Null
}
catch {
    Write-Log -Message $_ -Level Warn
    break
}

# Get the VM and Disks
Write-Log -Message "Getting Virtual Machine Details for $($vmName)" -Level Info

try {
    $SourceVM = Get-AzVM -ResourceGroupName $ResourceGroup -Name $vmName -ErrorAction Stop
    $RestoreVM = $SourceVM
    Write-Log -Message "Retrieved Virtual Machine Details for $($vmName)" -Level Info
    Write-Log -Message "Getting OS Disk Details for $($vmName)" -Level Info
    $OriginalOSDisk = $SourceVM.StorageProfile.OsDisk
    Write-Log -Message "Getting Data Disk Details for $($vmName)" -Level Info
    $OriginalDataDisks = $SourceVM.StorageProfile.DataDisks
    Write-Log -Message "There are $($OriginalDataDisks.Count) data disks for $($vmName)" -Level Info

    # Check for OS Disk deletion type
    if ($SourceVM.StorageProfile.OsDisk.DeleteOption -eq "Delete") {
        Write-Log -Message "VM OS disk delete option is set to Delete"  -Level Warn
        Write-Log -Message "This is a migration exercise and the disk MUST be retained"  -Level Warn
        Write-Log -Message "VM OS disk delete option will be set to detach"  -Level Warn
        try {
            $SourceVM | Set-AzVMOSDisk -DeleteOption Detach -ErrorAction Stop | Out-Null
            $SourceVM | Update-AzVM -ErrorAction Stop | Out-Null
            Write-Log -Message "Successfully set OS disk delete option to Detach" -Level Info
        }
        catch {
            Write-Log -Message "$_" -Level Warn
            Write-Log -Message "Failed to alter OS disk. Terminating script to avoid data loss" -Leve Warn
            StopIteration
            Exit 1
        }
    }
    else {
        Write-Log -Message "VM OS disk delete option is set to Detach. OK"
    }

    # Check for NIC deletion type
    foreach ($Interface in $SourceVM.NetworkProfile.NetworkInterfaces) {
        if ($Interface.DeleteOption -eq "Delete") {
            Write-Log -Message "VM Network Interfaces delete option is set to Delete"  -Level Warn
            Write-Log -Message "This is a migration exercise and the NIC MUST be retained"  -Level Warn
            Write-Log -Message "VM Network delete should be set to detach"  -Level Warn
  
            Write-Log -Message "Cannot alter Network Interfaces via PowerShell. Terminating script to avoid data loss" -Leve Warn
            StopIteration
            Exit 1
        }
        else {
            Write-Log -Message "VM Network Interfaces delete option is set to Detach or undefined. OK"
        }
    }

    #region config logging
    Write-Log -Message "-----------------------Config Backup Start------------------------------------------" -Level Info
    
    Write-Log -Message "Backing Up Source VM Details to File" -Level Info
    Write-Log -Message "VM Name = $($SourceVM.Name)" -Level Info
    Write-Log -Message "VM Resource Group = $($SourceVM.ResourceGroupName)" -Level Info
    Write-Log -Message "VM Location = $($SourceVM.Location)" -Level Info
    Write-Log -Message "VM Hardware Profile Size = $($SourceVM.HardwareProfile.VmSize)" -Level Info
    Write-Log -Message "VM OSType = $($SourceVM.StorageProfile.OsDisk.OsType)" -Level Info
    Write-Log -Message "OS Disk Name = $($SourceVM.StorageProfile.OsDisk.Name)" -Level Info
    if ($null -ne $SourceVM.Zones) {
        Write-Log -Message "VM Zone = $($SourceVM.Zones)" -Level Info
    }
    foreach ($DataDisk in $SourceVM.StorageProfile.DataDisks) {
        Write-Log -Message "Data Disk Name = $($DataDisk.Name)" -Level Info
    }
    foreach ($Interface in $SourceVM.NetworkProfile.NetworkInterfaces) {
        Write-Log -Message "Interface Primary = $($Interface.Primary)" -Level Info
        Write-Log -Message "Interface = $($Interface.Id)" -Level Info
    }
    Write-Log -Message "Source VM Plan Name = $($SourceVM.Plan.Name)" -Level Info
    Write-Log -Message "Source VM Plan Product = $($SourceVM.Plan.Product)" -Level Info
    Write-Log -Message "Source VM Plan Publisher = $($SourceVM.Plan.Publisher)" -Level Info
    Write-Log -Message "Source VM Diagnostics Account = $($SourceVM.DiagnosticsProfile.BootDiagnostics.StorageUri)" -Level Info

    Write-Log -Message "-----------------------Config Backup End------------------------------------------" -Level Info
    #endregion
}
catch {
    Write-Log -Message $_ -Level Warn
    break
}

# Stop the VM to take snapshot
try {
    Write-Log -Message "Stopping VM: $($vmName)" -Level Info
    Stop-AzVM -ResourceGroupName $ResourceGroup -Name $vmName -Force -ErrorAction Stop | out-Null
    Write-Log -Message "Stopped VM: $($vmName)" -Level Info
}
catch {
    Write-Log -Message $_ -Level Warn
    break
}

# Create a SnapShot of the OS disk and then, create an Azure Disk with Zone information
try {
    # Create the Snapshot
    Write-Log -Message "Creating OS Disk Snapshot for $($OriginalOSDisk.Name)" -Level Info
    $DiskDetailsOS = Get-AzDisk -ResourceGroupName $SourceVM.ResourceGroupName -DiskName $OriginalOSDisk.Name -ErrorAction Stop
    $snapshotOSConfig = New-AzSnapshotConfig -SourceUri $SourceVM.StorageProfile.OsDisk.ManagedDisk.Id -Location $location -CreateOption copy -SkuName Standard_ZRS -ErrorAction Stop
    $OSSnapshot = New-AzSnapshot -Snapshot $snapshotOSConfig -SnapshotName ($SourceVM.StorageProfile.OsDisk.Name + "-snapshot") -ResourceGroupName $ResourceGroup -ErrorAction Stop
    Write-Log -Message "Created OS Disk Snapshot: $($OSSnapshot.Name)" -Level Info
    
    #Create the Disk
    Write-Log -Message "Creating OS Disk in zone: $($Zone)" -Level Info
    $diskConfig = New-AzDiskConfig -Location $OSSnapshot.Location -SourceResourceId $OSSnapshot.Id -CreateOption Copy -SkuName $DiskDetailsOS.Sku.Name -Zone $zone -ErrorAction Stop
    $CleansedOSDiskName = $SourceVM.StorageProfile.OsDisk.Name
    $CleansedOSDiskName = $CleansedOSDiskName -replace "_z_*",""
    $OSdisk = New-AzDisk -Disk $diskConfig -ResourceGroupName $ResourceGroup -DiskName ($CleansedOSDiskName + "_z_$Zone") -ErrorAction Stop
    #$OSdisk = New-AzDisk -Disk $diskConfig -ResourceGroupName $ResourceGroup -DiskName ($SourceVM.StorageProfile.OsDisk.Name + "_z_$Zone") -ErrorAction Stop
    Write-Log -Message "Created OS Disk $($OSDisk.Name) in zone: $($Zone)" -Level Info
}
catch {
    Write-Log -Message $_ -Level Warn
    break
}

# Create a Snapshot from the Data Disks and the Azure Disks with Zone information
try {
    Write-Log -Message "Creating Data Disk Snapshots" -Level Info
    foreach ($disk in $SourceVM.StorageProfile.DataDisks) {
        # Create the Snapshot
        Write-Log -Message "Getting Disk details for $($Disk.Name)" -Level Info
        $DiskDetails = Get-AzDisk -ResourceGroupName $SourceVM.ResourceGroupName -DiskName $disk.Name -ErrorAction Stop

        Write-Log -Message "Creating snapshot for $($Disk.Name)" -Level Info
        $snapshotDataConfig = New-AzSnapshotConfig -SourceUri $disk.ManagedDisk.Id -Location $location -CreateOption copy -SkuName Standard_ZRS -ErrorAction Stop
        $DataSnapshot = New-AzSnapshot -Snapshot $snapshotDataConfig -SnapshotName ($disk.Name + '-snapshot') -ResourceGroupName $ResourceGroup -ErrorAction Stop
        Write-Log -Message "Created Snapshot: $($DataSnapshot.Name)" -Level Info

        #Create the Disk
        Write-Log -Message "Creating Data Disk $($disk.Name + "_z_$Zone") in zone: $($Zone)" -Level Info
        $datadiskConfig = New-AzDiskConfig -Location $DataSnapshot.Location -SourceResourceId $DataSnapshot.Id -CreateOption Copy -SkuName $DiskDetails.Sku.Name -Zone $zone
        $CleansedDataDiskName = $Disk.Name
        $CleansedDataDiskName = $CleansedDataDiskName -replace "_z_*",""
        $datadisk = New-AzDisk -Disk $datadiskConfig -ResourceGroupName $ResourceGroup -DiskName ($CleansedDataDiskName + "_z_$Zone") -ErrorAction Stop
        #$datadisk = New-AzDisk -Disk $datadiskConfig -ResourceGroupName $ResourceGroup -DiskName ($disk.Name + "_z_$Zone")
        Write-Log -Message "Created Data Disk: $($datadisk.Name) in zone: $($Zone)" -Level Info
    }
}
catch {
    Write-Log -Message $_ -Level Warn
    break
}

# Remove the original VM
try {
    Write-Log -Message "Removing original VM: $($SourceVM.Name)" -Level Info
    Remove-AzVM -ResourceGroupName $ResourceGroup -Name $vmName -Force -ErrorAction Stop | Out-Null
    Write-Log -Message "Removed original VM: $($SourceVM.Name)" -Level Info
}
catch {
    Write-Log -Message $_ -Level Warn
    break
}

# Create the basic configuration for the replacement VM
try {
    Write-Log -Message "Building New VM config: $($SourceVM.Name)" -Level Info
    $NewVM = New-AzVMConfig -VMName $SourceVM.Name -VMSize $SourceVM.HardwareProfile.VmSize -Zone $zone -ErrorAction Stop

    # Add the pre-created OS disk 
    Write-Log -Message "Adding OS Disk $($OSdisk.Name) to VM config: $($SourceVM.Name)" -Level Info
    if ($SourceVM.StorageProfile.OsDisk.OsType -eq "Windows") {
        Set-AzVMOSDisk -VM $NewVM -CreateOption Attach -ManagedDiskId $OSdisk.Id -Name $OSdisk.Name -Windows -ErrorAction Stop | Out-Null
    }
    if ($SourceVM.StorageProfile.OsDisk.OsType -eq "Linux") {
        Set-AzVMOSDisk -VM $NewVM -CreateOption Attach -ManagedDiskId $OSdisk.Id -Name $OSdisk.Name -Linux -ErrorAction Stop | Out-Null
    }
    
    if (($SourceVM.StorageProfile.DataDisks).Count -ne 0) {
        # Add the pre-created data disks
        foreach ($disk in $SourceVM.StorageProfile.DataDisks) { 
            Write-Log -Message "Adding Data Disk $($disk.Name + "_z_$Zone") to VM config: $($SourceVM.Name)" -Level Info
            $DataDiskDetails = Get-AzDisk -ResourceGroupName $ResourceGroup -DiskName ($disk.Name + "_z_$Zone") -ErrorAction Stop
            Add-AzVMDataDisk -VM $NewVM -Name $DataDiskDetails.Name -ManagedDiskId $DataDiskDetails.Id -Caching $disk.Caching -Lun $disk.Lun -DiskSizeInGB $disk.DiskSizeGB -CreateOption Attach -ErrorAction Stop | Out-Null
            Write-Log -Message "Added Data Disk $($disk.Name + "_z_$Zone") to VM config: $($SourceVM.Name)" -Level Info
        }
    }

    # Add NIC(s) and keep the same NIC as primary
    Write-Log -Message "Adding NIC: $($SourceVM.NetworkProfile.NetworkInterfaces.Id | split-Path -leaf) to VM config: $($SourceVM.Name)" -Level Info
    try {
        foreach ($nic in $SourceVM.NetworkProfile.NetworkInterfaces) {	
            if ($nic.Primary -eq "True") {
                Add-AzVMNetworkInterface -VM $NewVM -Id $nic.Id -Primary -ErrorAction Stop | Out-Null
            }
            else {
                Add-AzVMNetworkInterface -VM $NewVM -Id $nic.Id -ErrorAction Stop | Out-Null
            }
        }
    }
    catch {
        Write-Log -Message $_ -Level Warn
    }

    # Handle ADC
    if ($IsADC.IsPresent) {
        Write-Log -Message "Citrix ADC switch is present. Using the following plan information" -Level Info
        Write-Log -Message "----Plan Name: $($SourceVM.Plan.Name)" -Level Info
        Write-Log -Message "----Plan Product: $($SourceVM.Plan.Product)" -Level Info
        Write-Log -Message "----Plan Publisher: $($SourceVM.Plan.Publisher)" -Level Info
        $NewVM | Set-AzVMPlan -Name $SourceVM.Plan.Name -Product $SourceVM.Plan.Product -Publisher $SourceVM.Plan.Publisher | Out-Null
    }

    # Handle boot diagnostics
    $BootDiagsStorageAccount = $SourceVM.DiagnosticsProfile.BootDiagnostics.StorageUri
    $BootDiagsStorageAccount = $BootDiagsStorageAccount -replace "https://",""
    $BootDiagsStorageAccount = $BootDiagsStorageAccount -replace ".blob.core.windows.net/",""

    if ($null -ne $BootDiagsStorageAccount) {
        $NewVM | Set-AzVMBootDiagnostic -Enable -ResourceGroupName $SourceVM.ResourceGroupName -StorageAccountName $BootDiagsStorageAccount | Out-Null
    }

    # Recreate the VM
    Write-Log -Message "Building New VM: $($SourceVM.Name) in zone $($Zone)" -Level Info
    New-AzVM -ResourceGroupName $ResourceGroup -Location $SourceVM.Location -VM $NewVM -ErrorAction Stop | Out-Null

    Write-Log -Message "Created New VM: $($SourceVM.Name) in zone $($Zone)" -Level Info

}
catch {
    Write-Log -Message $_ -Level Warn
    Write-Log -Message "Failed to create VM $($VMName). Attempting to recreate source VM"
    RecreateSourceVM
    StopIteration
    Exit 1
}

#Cleanup Snapshots
if ($CleanupSnapshots.IsPresent) {
    Write-Log -Message "Removing Snapshot: $($SourceVM.StorageProfile.OsDisk.Name + "-snapshot")" -Level Info

    try {
        Remove-AzSnapshot -ResourceGroupName $ResourceGroup -SnapshotName ($SourceVM.StorageProfile.OsDisk.Name + "-snapshot") -Force -ErrorAction Stop | Out-Null
        foreach ($disk in $SourceVM.StorageProfile.DataDisks) {
            Write-Log -Message "Removing Snapshot: $($disk.Name + "-snapshot")" -Level Info
            Remove-AzSnapshot -ResourceGroupName $ResourceGroup -SnapshotName ($disk.Name + "-snapshot") -Force -ErrorAction Stop | out-Null
        }    
    }
    catch {
        Write-Log -Message $_ -Level Warn
    }
}

#Cleanup Old Disks
if ($CleanupSourceDisks.IsPresent) {
    Write-Log -Message "Removing Original Disk: $($SourceVM.StorageProfile.OsDisk.Name)" -Level Info
    try {
        Remove-AzDisk -ResourceGroupName $ResourceGroup -DiskName ($SourceVM.StorageProfile.OsDisk.Name) -Force -ErrorAction Stop | Out-Null

        foreach ($disk in $SourceVM.StorageProfile.DataDisks) {
            Write-Log -Message "Removing Original Disk: $($disk.Name)" -Level Info
            Remove-AzDisk -ResourceGroupName $ResourceGroup -DiskName $disk.Name -Force -ErrorAction Stop | Out-Null
        }
    }
    catch {
        Write-Log -Message $_ -Level Warn
    }
}

StopIteration
Exit 0
#endregion
