
<#
.SYNOPSIS
    Script to move an existing VM out of an existing Availability Set
.DESCRIPTION
    Moves an existing VM out of an Availability Set
.PARAMETER LogPath
    Logpath output for all operations
.PARAMETER LogRollover
    Number of days before logfiles are rolled over. Default is 5
.PARAMETER ResourceGroup
    Name of the Resource Group for the VM
.PARAMETER VMName
    Name of the target VM
.EXAMPLE
    .\RemoveVMAvailabilitySet.ps1 -ResourceGroup RG-DEMO -VMName VM1 
#>

#region Params
# ============================================================================
# Parameters
# ============================================================================
Param(
    [Parameter(Mandatory = $false)]
    [string]$LogPath = "C:\Logs\RemoveVMAvailabilitySet.log", 

    [Parameter(Mandatory = $false)]
    [int]$LogRollover = 5, # number of days before logfile rollover occurs

    [Parameter(Mandatory = $True)]
    [string]$ResourceGroup, 

    [Parameter(Mandatory = $True)]
    [string]$VMName
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

function RecreateSourceVM {
    try {
        # Create the basic configuration for the replacement VM
        Write-Log -Message "Creating new configuration for replacement VM $($RestoreVM.Name)" -Level Info
        if ($null -eq $RestoreVM.Zones) {
            $NewVM = New-AzVMConfig -VMName $RestoreVM.Name -VMSize $RestoreVM.HardwareProfile.VmSize -AvailabilitySetId $RestoreVM.AvailabilitySetReference.Id -ErrorAction Stop  #Need to grab old AS ID
        }
        else {
            $NewVM = New-AzVMConfig -VMName $RestoreVM.Name -VMSize $RestoreVM.HardwareProfile.VmSize -Zone $RestoreVM.Zones -ErrorAction Stop  
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
        foreach ($Disk in $RestoreVM.StorageProfile.DataDisks) {
            Write-Log -Message "Adding Data Disk for VM $($VMName)" -Level Info 
            Add-AzVMDataDisk -VM $NewVM -Name $Disk.Name -ManagedDiskId $Disk.ManagedDisk.Id -Caching $Disk.Caching -Lun $Disk.Lun -DiskSizeInGB $Disk.DiskSizeGB -CreateOption Attach -ErrorAction Stop | Out-Null
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
        if ($null -ne $RestoreVM.Plan) {
            Write-Log -Message "Using the following plan information" -Level Info
            Write-Log -Message "----Plan Name: $($RestoreVM.Plan.Name)" -Level Info
            Write-Log -Message "----Plan Product: $($RestoreVM.Plan.Product)" -Level Info
            Write-Log -Message "----Plan Publisher: $($RestoreVM.Plan.Publisher)" -Level Info
            $NewVM | Set-AzVMPlan -Name $RestoreVM.Plan.Name -Product $RestoreVM.Plan.Product -Publisher $RestoreVM.Plan.Publisher | Out-Null
        }

        # Handle boot diagnostics
        $BootDiagsStorageAccount = $RestoreVM.DiagnosticsProfile.BootDiagnostics.StorageUri
        $BootDiagsStorageAccount = $BootDiagsStorageAccount -replace "https://",""
        $BootDiagsStorageAccount = $BootDiagsStorageAccount -replace ".blob.core.windows.net/",""

        if ($null -ne $RestoreVM.DiagnosticsProfile.BootDiagnostics.StorageUri -and $RestoreVM.DiagnosticsProfile.BootDiagnostics.Enabled) {
            # retain existing boot diagnostics storage account
            $NewVM | Set-AzVMBootDiagnostic -Enable -ResourceGroupName $RestoreVM.ResourceGroupName -StorageAccountName $BootDiagsStorageAccount | Out-Null
        } elseif ($null -eq $RestoreVM.DiagnosticsProfile.BootDiagnostics.StorageUri -and $RestoreVM.DiagnosticsProfile.BootDiagnostics.Enabled) {
            # use system managed boot diagnostics
            $NewVM | Set-AzVMBootDiagnostic -Enable -ResourceGroupName $RestoreVM.ResourceGroupName | Out-Null
        } elseif (-not $RestoreVM.DiagnosticsProfile.BootDiagnostics.Enabled) {
            # disable diagnostics
            $NewVM | Set-AzVMBootDiagnostic -Disable | Out-Null
        }

        # Recreate the VM
        New-AzVM -ResourceGroupName $RestoreVM.ResourceGroupName -Location $RestoreVM.Location -VM $NewVM -DisableBginfoExtension -ErrorAction Stop | Out-Null

        # Handle VM Licensing
        if ($RestoreVM.LicenseType -ne "None") {
            $VMDetail = Get-AzVM -ResourceGroupName $ResourceGroup -Name $RestoreVM.Name
            Write-Log -Message "Setting VM Licensing Detail: $($RestoreVM.LicenseType)" -Level Info
            $VMDetail.LicenseType = $RestoreVM.LicenseType
            Update-AzVM -ResourceGroupName $ResourceGroup -VM $VMDetail | Out-Null
        }

        Write-Log -Message "Restored VM: $($RestoreVM.Name)" -Level Info

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

Write-Log -Message "IMPORTANT: If backups are enabled for this VM, they must be disabled before running this script. Soft delete should be disabled on the vault and all backups removed prior to migration" -Level Warn

$BackupRemovalConfirmation = Read-Host "Has backup been removed for this VM? Y, N or Q (Quit)"
while ("Y", "N", "Q" -notcontains $BackupRemovalConfirmation) {
    $BackupRemovalConfirmation = Read-Host "Enter Y, N or Q (Quit)"
}
if ($BackupRemovalConfirmation -eq "Y") {
    Write-Log -Message "Backup confirmation received. Proceeding with migration" -Level Info

    # Get the details of the VM to be moved to the Availability Set
    try {
        Write-Log -Message "Getting Source VM details for $($VMName)" -Level Info
        $SourceVM = Get-AzVM -ResourceGroupName $ResourceGroup -Name $VMName -ErrorAction Stop
        $RestoreVM = $SourceVM
        Write-Log -Message "Getting OS Disk Details for $($VMName)" -Level Info
        $OriginalOSDisk = $SourceVM.StorageProfile.OsDisk
        Write-Log -Message "Getting Data Disk Details for $($VMName)" -Level Info
        $OriginalDataDisks = $SourceVM.StorageProfile.DataDisks
        Write-Log -Message "There are $($OriginalDataDisks.Count) data disks for $($VMName)" -Level Info

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
        foreach ($Interface in $SourceVM.NetworkProfile.NetworkInterfaces){
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
        Write-Log -Message "Source VM Name = $($SourceVM.Name)" -Level Info
        Write-Log -Message "Source VM Resource Group = $($SourceVM.ResourceGroupName)" -Level Info
        Write-Log -Message "Source VM Location = $($SourceVM.Location)" -Level Info
        Write-Log -Message "Source VM Availability Set = $($SourceVM.AvailabilitySetReference.Id)" -Level Info
        Write-Log -Message "Source VM Hardware Profile Size = $($SourceVM.HardwareProfile.VmSize)" -Level Info
        Write-Log -Message "Source VM OSType = $($SourceVM.StorageProfile.OsDisk.OsType)" -Level Info
        Write-Log -Message "Source VM OS Disk Name = $($SourceVM.StorageProfile.OsDisk.Name)" -Level Info
        Write-Log -Message "Source VM OS Disk ID = $((Get-AzDisk -Name $SourceVM.StorageProfile.OsDisk.Name).Id)" -Level Info
        if ($null -ne $SourceVM.Zones) {
            Write-Log -Message "Source VM Zone = $($SourceVM.Zones)" -Level Info
        }
        foreach ($DataDisk in $SourceVM.StorageProfile.DataDisks) {
            Write-Log -Message "Source VM Data Disk Name = $($DataDisk.Name)" -Level Info
            Write-Log -Message "Source VM Data Disk ID = $((Get-AzDisk -Name $DataDisk.Name).Id)" -Level Info
        }
        foreach ($Interface in $SourceVM.NetworkProfile.NetworkInterfaces) {
            Write-Log -Message "Source VM Interface Primary = $($Interface.Primary)" -Level Info
            Write-Log -Message "Source VM Interface = $($Interface.Id)" -Level Info
        }

        if ($null -ne $SourceVM.Plan) {
            Write-Log -Message "Source VM Plan Name = $($SourceVM.Plan.Name)" -Level Info
            Write-Log -Message "Source VM Plan Product = $($SourceVM.Plan.Product)" -Level Info
            Write-Log -Message "Source VM Plan Publisher = $($SourceVM.Plan.Publisher)" -Level Info
        }

        if ($null -ne $SourceVM.DiagnosticsProfile.BootDiagnostics.StorageUri -and $SourceVM.DiagnosticsProfile.BootDiagnostics.Enabled) {
            Write-Log -Message "Source VM Diagnostics Account = $($SourceVM.DiagnosticsProfile.BootDiagnostics.StorageUri)" -Level Info
        } elseif ($null -eq $SourceVM.DiagnosticsProfile.BootDiagnostics.StorageUri -and $SourceVM.DiagnosticsProfile.BootDiagnostics.Enabled) {
            Write-Log -Message "Source VM Diagnostics = Managed" -Level Info
        } elseif (-not $SourceVM.DiagnosticsProfile.BootDiagnostics.Enabled) {
            Write-Log -Message "Source VM Diagnostics = Disabled" -Level Info
        }

        Write-Log -Message "Source VM Hybrid Licensing = $($SourceVM.LicenseType)"

        Write-Log -Message "-----------------------Config Backup End------------------------------------------" -Level Info
        #endregion
    }
    catch {
        Write-Log -Message $_ -Level Warn
        Write-Log -Message "Failed to retrieve VM details for $($VMName). Exiting Script"
        StopIteration
        Exit 1
    }

    if ($null -ne $SourceVM.Zones) {
        Write-Log -Message "Source VM is zone based in zone: $($SourceVM.Zones). Recreating Disks" -Level Warn

        # Create a SnapShot of the OS disk and then, create an Azure Disk
        try {
            Write-Log -Message "Creating OS Disk Snapshot for $($OriginalOSDisk.Name)" -Level Info
            $DiskDetailsOS = Get-AzDisk -ResourceGroupName $SourceVM.ResourceGroupName -DiskName $OriginalOSDisk.Name-ErrorAction Stop
            $SnapshotOSConfig = New-AzSnapshotConfig -SourceUri $SourceVM.StorageProfile.OsDisk.ManagedDisk.Id -Location $SourceVM.location -CreateOption copy -SkuName "Standard_LRS" -ErrorAction Stop
            $OSSnapshot = New-AzSnapshot -Snapshot $snapshotOSConfig -SnapshotName ($SourceVM.StorageProfile.OsDisk.Name + "-snapshot") -ResourceGroupName $ResourceGroup -ErrorAction Stop
            Write-Log -Message "Created OS Disk Snapshot: $($OSSnapshot.Name)" -Level Info

            #Create the Disk
            Write-Log -Message "Creating OS Disk" -Level Info
            $DiskConfig = New-AzDiskConfig -Location $OSSnapshot.Location -SourceResourceId $OSSnapshot.Id -CreateOption Copy -SkuName $DiskDetailsOS.Sku.Name -ErrorAction Stop
            $CleansedOSDiskName = $SourceVM.StorageProfile.OsDisk.Name
            $CleansedOSDiskName = $CleansedOSDiskName -replace "_z_*",""
            $OSDisk = New-AzDisk -Disk $diskConfig -ResourceGroupName $ResourceGroup -DiskName ($CleansedOSDiskName) -ErrorAction Stop
            Write-Log -Message "Created OS Disk $($OSDisk.Name)" -Level Info
        }
        catch {
            Write-Log -Message $_ -Level Warn
            StopIteration
            Exit 1
        }

        # Create a Snapshot from the Data Disks and the Azure Disks
        try {
            Write-Log -Message "Creating Data Disk Snapshots" -Level Info
            foreach ($disk in $SourceVM.StorageProfile.DataDisks) {
                # Create the Snapshot
                Write-Log -Message "Getting Disk details for $($Disk.Name)" -Level Info
                $DiskDetails = Get-AzDisk -ResourceGroupName $SourceVM.ResourceGroupName -DiskName $disk.Name -ErrorAction Stop
        
                Write-Log -Message "Creating snapshot for $($Disk.Name)" -Level Info
                $SnapshotDataConfig = New-AzSnapshotConfig -SourceUri $disk.ManagedDisk.Id -Location $SourceVM.location -CreateOption copy -SkuName "Standard_LRS" -ErrorAction Stop
                $DataSnapshot = New-AzSnapshot -Snapshot $SnapshotDataConfig -SnapshotName ($disk.Name + '-snapshot') -ResourceGroupName $ResourceGroup -ErrorAction Stop
                Write-Log -Message "Created Snapshot: $($DataSnapshot.Name)" -Level Info
        
                #Create the Disk
                Write-Log -Message "Creating Data Disk" -Level Info
                $DataDiskConfig = New-AzDiskConfig -Location $DataSnapshot.Location -SourceResourceId $DataSnapshot.Id -CreateOption Copy -SkuName $DiskDetails.Sku.Name
                $CleansedDataDiskName = $Disk.Name
                $CleansedDataDiskName = $CleansedDataDiskName -replace "_z_*",""
                $DataDisk = New-AzDisk -Disk $DataDiskConfig -ResourceGroupName $ResourceGroup -DiskName ($CleansedDataDiskName) -ErrorAction Stop
                Write-Log -Message "Created Data Disk: $($DataDisk.Name)" -Level Info
            }
        }
        catch {
            Write-Log -Message $_ -Level Warn
            StopIteration
            Exit 1
        }
    }

    # Remove the original VM
    try {
        Write-Log -Message "Removing Source VM $($VMName)" -Level Info
        Remove-AzVM -ResourceGroupName $ResourceGroup -Name $VMName -Force -ErrorAction Stop | out-Null
        Write-Log -Message "Source VM $($VMName) removed" -Level Info
    }
    catch {
        Write-Log -Message $_ -Level Warn
        Write-Log -Message "Failed to remove VM $($VMName). Exiting Script"
        StopIteration
        Exit 1
    }

    # Create the basic configuration for the replacement VM.
    try {
        Write-Log -Message "Creating new configuration for replacement VM $($VMName)" -Level Info
        $NewVM = New-AzVMConfig -VMName $SourceVM.Name -VMSize $SourceVM.HardwareProfile.VmSize -ErrorAction Stop
        
        # Handling OS disks
        Write-Log -Message "Setting Data Disk configuration for replacement VM $($VMName)" -Level Info
        if ($SourceVM.StorageProfile.OsDisk.OsType -eq "Windows") {
            if ($null -ne $SourceVM.Zones) {
                Set-AzVMOSDisk -VM $NewVM -CreateOption Attach -ManagedDiskId $OSDisk.Id -Name $OSDisk.Name -Windows | Out-Null
            }
            else {
                Set-AzVMOSDisk -VM $NewVM -CreateOption Attach -ManagedDiskId $SourceVM.StorageProfile.OsDisk.ManagedDisk.Id -Name $SourceVM.StorageProfile.OsDisk.Name -Windows | Out-Null
            }
        }
        if ($SourceVM.StorageProfile.OsDisk.OsType -eq "Linux") {
            if ($null -ne $SourceVM.Zones) {
                Set-AzVMOSDisk -VM $NewVM -CreateOption Attach -ManagedDiskId $OSDisk.Id -Name $OSDisk.Name -Linux | Out-Null
            }
            else {
                Set-AzVMOSDisk -VM $NewVM -CreateOption Attach -ManagedDiskId $SourceVM.StorageProfile.OsDisk.ManagedDisk.Id -Name $SourceVM.StorageProfile.OsDisk.Name -Linux | Out-Null
            }
        }

        # Add Data Disks
        foreach ($Disk in $SourceVM.StorageProfile.DataDisks) {
            Write-Log -Message "Adding Data Disk for replacement VM $($VMName)" -Level Info
            if ($null -ne $SourceVM.Zones) {
                $DataDiskOriginalName = $Disk.Name
                $DataDiskCleansedName = $DataDiskOriginalName -replace "_z_*",""
                $CleansedDataDisk = Get-AzDisk -ResourceGroupName $SourceVM.ResourceGroupName -DiskName $DataDiskCleansedName -ErrorAction Stop
                Add-AzVMDataDisk -VM $NewVM -Name $CleansedDataDisk.Name -ManagedDiskId $CleansedDataDisk.Id -Caching $Disk.Caching -Lun $Disk.Lun -DiskSizeInGB $Disk.DiskSizeGB -CreateOption Attach -ErrorAction Stop | Out-Null
                
            }
            else {
                Add-AzVMDataDisk -VM $NewVM -Name $Disk.Name -ManagedDiskId $Disk.ManagedDisk.Id -Caching $Disk.Caching -Lun $Disk.Lun -DiskSizeInGB $Disk.DiskSizeGB -CreateOption Attach -ErrorAction Stop | Out-Null
            }
        }

        # Add NIC(s) and keep the same NIC as primary
        foreach ($nic in $SourceVM.NetworkProfile.NetworkInterfaces) {
            Write-Log -Message "Adding NIC: $($nic.Id | split-Path -leaf) to VM config: $($SourceVM.Name)" -Level Info	
            if ($nic.Primary -eq "True") {
                Add-AzVMNetworkInterface -VM $NewVM -Id $nic.Id -Primary -ErrorAction Stop | Out-Null
            }
            else {
                Add-AzVMNetworkInterface -VM $NewVM -Id $nic.Id -ErrorAction Stop | Out-Null
            }
        }

        # Grab Sku 
        if ($null -ne $SourceVM.Plan) {
            Write-Log -Message " Using the following plan information" -Level Info
            Write-Log -Message "----Plan Name: $($SourceVM.Plan.Name)" -Level Info
            Write-Log -Message "----Plan Product: $($SourceVM.Plan.Product)" -Level Info
            Write-Log -Message "----Plan Publisher: $($SourceVM.Plan.Publisher)" -Level Info
            $NewVM | Set-AzVMPlan -Name $SourceVM.Plan.Name -Product $SourceVM.Plan.Product -Publisher $SourceVM.Plan.Publisher | Out-Null
        }

        # Handle boot diagnostics
        $BootDiagsStorageAccount = $SourceVM.DiagnosticsProfile.BootDiagnostics.StorageUri
        $BootDiagsStorageAccount = $BootDiagsStorageAccount -replace "https://",""
        $BootDiagsStorageAccount = $BootDiagsStorageAccount -replace ".blob.core.windows.net/",""

        if ($null -ne $SourceVM.DiagnosticsProfile.BootDiagnostics.StorageUri -and $SourceVM.DiagnosticsProfile.BootDiagnostics.Enabled) {
            # retain existing boot diagnostics storage account
            $NewVM | Set-AzVMBootDiagnostic -Enable -ResourceGroupName $SourceVM.ResourceGroupName -StorageAccountName $BootDiagsStorageAccount | Out-Null
        } elseif ($null -eq $SourceVM.DiagnosticsProfile.BootDiagnostics.StorageUri -and $SourceVM.DiagnosticsProfile.BootDiagnostics.Enabled) {
            # use system managed boot diagnostics
            $NewVM | Set-AzVMBootDiagnostic -Enable -ResourceGroupName $SourceVM.ResourceGroupName | Out-Null
        } elseif (-not $SourceVM.DiagnosticsProfile.BootDiagnostics.Enabled) {
            # disable diagnostics
            $NewVM | Set-AzVMBootDiagnostic -Disable | Out-Null
        }

        # Recreate the VM
        Write-Log -Message "Creating the VM $($VMName)" -Level Info
        New-AzVM -ResourceGroupName $ResourceGroup -Location $SourceVM.Location -VM $NewVM -DisableBginfoExtension -ErrorAction Stop | Out-Null

        # Handle VM Licensing
        if ($SourceVM.LicenseType -ne "None") {
            $VMDetail = Get-AzVM -ResourceGroupName $ResourceGroup -Name $SourceVM.Name
            Write-Log -Message "Setting VM Licensing Detail: $($SourceVM.LicenseType)" -Level Info
            $VMDetail.LicenseType = $SourceVM.LicenseType
            Update-AzVM -ResourceGroupName $ResourceGroup -VM $VMDetail | Out-Null
        }
        
        Write-Log -Message "VM Creation complete. If backups are required, enroll this machine for VM backups" -Level Info

    }
    catch {
        Write-Log -Message $_ -Level Warn

        # If VM in failed stated, delete failed VM and start again
        if ((Get-AzVM -ResourceGroupName $ResourceGroup -Name $SourceVM.Name).ProvisioningState -eq "Failed") {
            Write-Log -Message "$($SourceVM.Name) is in a failed provisioning state. Deleting prior to recreating the source VM" -Level Warn
            Remove-AzVM -ResourceGroupName $ResourceGroup -Name $SourceVM.Name -Force | Out-Null
        }

        Write-Log -Message "Failed to create VM $($VMName). Attempting to recreate source VM"
        RecreateSourceVM
        StopIteration
        Exit 1
    }
}

elseif ($BackupRemovalConfirmation -eq "N") { 
    Write-Log -Message "Backup removed not confirmed. Exiting Script" -Level Info
    StopIteration
    exit 0
}

elseif ($BackupRemovalConfirmation -eq "Q") {
    Write-Log -Message "Quit Selected. Exiting Script" -Level Info
    StopIteration
    exit 0
}

StopIteration
Exit 0
#endregion