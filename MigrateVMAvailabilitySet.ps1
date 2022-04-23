
<#
.SYNOPSIS
    Script to move an existing VM to a different Availability Set
.DESCRIPTION
    Moves an existing VM to a different Availability Set
.PARAMETER LogPath
    Logpath output for all operations
.PARAMETER LogRollover
    Number of days before logfiles are rolled over. Default is 5
.PARAMETER ResourceGroup
    Name of the Resource Group for the VM
.PARAMETER VMName
    Name of the target VM
.PARAMETER AvailabilitySetName
    Name of the target Availability Set
.PARAMETER OSType
    Specifies either Windows or Linux OS type. Defaults to Windows
.EXAMPLE
    .\MigrateVMAvailabilitySet.ps1 -ResourceGroup RG-DEMO -VMName VM1 -AvailabilitySetName AS-DEMO
#>

#region Params
# ============================================================================
# Parameters
# ============================================================================
Param(
    [Parameter(Mandatory = $false)]
    [string]$LogPath = "C:\Logs\ChangeVMAvailabilitySet.log", 

    [Parameter(Mandatory = $false)]
    [int]$LogRollover = 5, # number of days before logfile rollover occurs

    [Parameter(Mandatory = $True)]
    [string]$ResourceGroup, 

    [Parameter(Mandatory = $True)]
    [string]$VMName, 

    [Parameter(Mandatory = $True)]
    [string]$AvailabilitySetName,

    [Parameter(Mandatory = $False)]
    [ValidateSet("Windows","Linux")]
    [String]$OSType = "Windows" # Windows or Linux

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

#ENTER A WARNING HERE ABOUT BACKUP DATA BEFORE PROCEEDING!
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
        $SourceVM = Get-AzVM -ResourceGroupName $ResourceGroup -Name $VMName
    }
    catch {
        Write-Log -Message $_ -Level Warn
        Write-Log -Message "Failed to retrieve VM details for $($VMName). Exiting Script"
        StopIteration
        Exit 1
    }

    # Create new availability set if it does not exist
    Write-Log -Message "Getting Availability Set details for $($AvailabilitySetName)" -Level Info
    $AvailabilitySet = Get-AzAvailabilitySet -ResourceGroupName $ResourceGroup -Name $AvailabilitySetName -ErrorAction Ignore

    if (-Not $AvailabilitySet) {
        try {
            Write-Log -Message "Availability Set $($AvailabilitySetName) does not exist. Attempting to create" -level Info
            $AvailabilitySet = New-AzAvailabilitySet -Location $SourceVM.Location -Name $AvailabilitySetName -ResourceGroupName $ResourceGroup -PlatformFaultDomainCount 2 -PlatformUpdateDomainCount 5 -Sku Aligned -ErrorAction Stop
            Write-Log -Message "Availability Set $($AvailabilitySetName) created successfully"
        }
        catch {
            Write-Log -Message $_ -Level Warn
            Write-Log -Message "Failed to create Availability Set. Exiting Script"
            StopIteration
            Exit 1
        }
    }

    # Remove the original VM
    try {
        Write-Log -Message "Removing Source VM $($VMName)" -Level Info
        $null = Remove-AzVM -ResourceGroupName $ResourceGroup -Name $VMName -ErrorAction Stop
        Write-Log -Message "Source VM $($VMName) removed" -Level Info
    }
    catch {
        Write-Log -Message $_ -Level Warn
        Write-Log -Message "Failed to remove VM $($VMName). Exiting Script"
        StopIteration
        Exit 1
    }

    # Create the basic configuration for the replacement VM. 
    Write-Log -Message "Creating new configuration for replacement VM $($VMName)" -Level Info
    $NewVM = New-AzVMConfig -VMName $SourceVM.Name -VMSize $SourceVM.HardwareProfile.VmSize -AvailabilitySetId $AvailabilitySet.Id

    # Handling Datadisks
    Write-Log -Message "Setting Data Disk configuration for replacement VM $($VMName)" -Level Info
    if ($OSType -eq "Windows") {
        $null = Set-AzVMOSDisk -VM $NewVM -CreateOption Attach -ManagedDiskId $SourceVM.StorageProfile.OsDisk.ManagedDisk.Id -Name $SourceVM.StorageProfile.OsDisk.Name -Windows
    }
    if ($OSType -eq "Linux") {
        $null = Set-AzVMOSDisk -VM $NewVM -CreateOption Attach -ManagedDiskId $SourceVM.StorageProfile.OsDisk.ManagedDisk.Id -Name $SourceVM.StorageProfile.OsDisk.Name -Linux
    }

    # Add Data Disks
    foreach ($disk in $SourceVM.StorageProfile.DataDisks) {
        Write-Log -Message "Adding Data Disk for replacement VM $($VMName)" -Level Info 
        $null = Add-AzVMDataDisk -VM $NewVM -Name $disk.Name -ManagedDiskId $disk.ManagedDisk.Id -Caching $disk.Caching -Lun $disk.Lun -DiskSizeInGB $disk.DiskSizeGB -CreateOption Attach
    }

    # Add NIC(s) and keep the same NIC as primary
    Write-Log -Message "Setting Network Interfaces for replacement VM $($VMName)" -Level Info
    foreach ($nic in $SourceVM.NetworkProfile.NetworkInterfaces) {	
        if ($nic.Primary -eq "True") {
            $null = Add-AzVMNetworkInterface -VM $NewVM -Id $nic.Id -Primary
        }
        else {
            $null = Add-AzVMNetworkInterface -VM $NewVM -Id $nic.Id 
        }
    }

    # Recreate the VM
    try {
        Write-Log -Message "Creating the VM $($VMName)" -Level Info
        $null = New-AzVM -ResourceGroupName $ResourceGroup -Location $SourceVM.Location -VM $NewVM -DisableBginfoExtension -ErrorAction Stop
        Write-Log -Message "VM Creation complete. If backups are required, enroll this machine for VM backups" -Level Info
    }
    catch {
        Write-Log -Message $_ -Level Warn
        Write-Log -Message "Failed to create VM $($VMName). Exiting Script"
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