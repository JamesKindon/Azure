<#
.SYNOPSIS
    Automates the download of the AzureFilesHyrbid Module for Domain Joining Storage Accuonts
    Automates the Domain Join tasks for the Storage Accounts
    Automates the deployment of relevant IAM roles
    Automates the configuration of NTFS permissions for FSLogix Containers 
.DESCRIPTION
    Leverages the scripts provided by Microsoft
    https://docs.microsoft.com/en-us/azure/storage/files/storage-files-identity-auth-active-directory-enable
.PARAMETER JoinStorageAccountToDomain
    If set, will join the storage account to the domain
.PARAMETER ConfigIAMRoles
    Will configure Azure IAM roles
.PARAMETER ConfigNTFSPermissions
    Will configure NTFS permissions for FSLogix Containers
.PARAMETER DebugStorageAccountDomainJoin
    Will debug join issues
.EXAMPLE
    JoinStorageAccountToDomain.ps1 -JoinStorageAccountToDomain -ConfigIAMRoles -ConfigNTFSPermissions
    Will join the specified Storage account to the domain, configure IAM roles and configure NTFS permissions for Containers
.EXAMPLE
    JoinStorageAccountToDomain.ps1 -ConfigIAMRoles -ConfigNTFSPermissions
    Will configure IAM roles and configure NTFS permissions for Containers
.NOTES
#>

#region Params
# ============================================================================
# Parameters
# ============================================================================
Param(
    # You may want to change this list below if you don't want to use parameters and simply accept defaults
    [Parameter(Mandatory = $false)]
    [Switch]$JoinStorageAccountToDomain,

    [Parameter(Mandatory = $false)]
    [Switch]$ConfigIAMRoles,

    [Parameter(Mandatory = $false)]
    [Switch]$ConfigNTFSPermissions,

    [Parameter(Mandatory = $false)]
    [Switch]$DebugStorageAccountDomainJoin
)
#endregion

#Change the execution policy to unblock importing AzFilesHybrid.psm1 module
Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope CurrentUser

#region variables
# ============================================================================
# Variables - change these per subscription (remove the "--")
# ============================================================================
$SubscriptionId = "--SubscriptionID--" #subscription Id
$ResourceGroupName = "--Resource Group--" #resource group name
$StorageAccountName = "--storage account name--" #storage account name
$ShareName = "--fslogix--" #storage account share name
$DomainAccountType = "ServiceLogonAccount" #-DomainAccountType "<ComputerAccount|ServiceLogonAccount>"
$OU = "--OU=Azure FIles,DC=Domain,DC=com--" #-OrganizationalUnitDistinguishedName "<ou-distinguishedname-here>"
$FSContributorGroups = @("WVD Users") # Array of groups to Assign Storage File Data SMB Share Contributor
$FSAdminUsers = @("Jkindon@domain.com") # Array of Admins to assign Storage File Data SMB Share Contributor and Storage File Data SMB Share Elevated Contributor roles
$DownloadUrl = "https://github.com/Azure-Samples/azure-files-samples/releases/download/v0.1.3/AzFilesHybrid.zip"
$ModulePath = "C:\temp\AzFilesHybrid" #Output path for modules
$DriveLetter = "X" # Letter used to map drive and set ACLs
#endregion

#region functions
# ============================================================================
# Functions
# ============================================================================
function JoinStorageAccountToDomain {
    # -OrganizationalUnitName "Azure Files"
    # If you don't provide the OU name as an input parameter, the AD identity that represents the storage account will be created under the root directory.
    Write-host "Attempting to Join Storage Account $StorageAccountName to Domain in OU $OU" -ForegroundColor Cyan

    $JoinParams = @{
        ResourceGroupName                   = $ResourceGroupName
        Name                                = $StorageAccountName 
        DomainAccountType                   = $DomainAccountType
        OrganizationalUnitDistinguishedName = $OU
        ErrorAction                         = "Stop"
    }

    try {
        Join-AzStorageAccountForAuth @JoinParams
        Write-Host "Successfully Joined Domain" -ForegroundColor Cyan
    }
    catch {
        Write-Warning "Failed to Join Domain"
        Write-Warning $Error[0].Exception
        Exit 1
    }
}

function DebugStorageAccount {
    #You can run the Debug-AzStorageAccountAuth cmdlet to conduct a set of basic checks on your AD configuration with the logged on AD user. 
    #This cmdlet is supported on AzFilesHybrid v0.1.2+ version. For more details on the checks performed in this cmdlet, go to Azure Files FAQ.
    Debug-AzStorageAccountAuth -StorageAccountName $StorageAccountName -ResourceGroupName $ResourceGroupName -Verbose    
}

function AssignIAMRoles {
    #Get the name of the custom role
    $FileShareReaderRole = Get-AzRoleDefinition "Storage File Data SMB Share Reader" # not required for the most part, but added to admin account anyway to save on complexity
    $FileShareContributorRole = Get-AzRoleDefinition "Storage File Data SMB Share Contributor" # used for share access to the storage account - NTFS leveraged for fine grained controls
    $FileShareElevatedContributorRole = Get-AzRoleDefinition "Storage File Data SMB Share Elevated Contributor" # used to set the admin accounts with permissions to manage NTFS

    #Constrain the scope to the target file share
    $scope = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Storage/storageAccounts/$StorageAccountName/fileServices/default/fileshares/$ShareName"

    #Assign the custom role to the target identity with the specified scope.
    foreach ($Admin in $FSAdminUsers) {
        Write-Host "Assigning Admin ID $Admin to Role $($FileShareReaderRole.Name)" -ForegroundColor Cyan
        try {
            $ReaderRole = @{
                SignInName         = $Admin
                RoleDefinitionName = $FileShareReaderRole.Name
                Scope              = $scope
                ErrorAction        = "Stop"
            }
            New-AzRoleAssignment @ReaderRole
            Write-Host "Successfully added role assignment" -ForegroundColor Cyan
        }
        catch {
            Write-Warning "Failed to assign role"
            Write-Warning $Error[0].Exception
        }

        Write-Host "Assigning Admin ID $Admin to Role $($FileShareContributorRole.Name)" -ForegroundColor Cyan
        try {
            $ContributorRole = @{
                SignInName         = $Admin
                RoleDefinitionName = $FileShareContributorRole.Name
                Scope              = $scope
                ErrorAction        = "Stop"
            }
            New-AzRoleAssignment @ContributorRole
            Write-Host "Successfully added role assignment" -ForegroundColor Cyan
        }
        catch {
            Write-Warning "Failed to assign role"
            Write-Warning $Error[0].Exception
        }

        Write-Host "Assigning Admin ID $Admin to Role $($FileShareElevatedContributorRole.Name)" -ForegroundColor Cyan
        try {
            $ElevatedContributorRole = @{
                SignInName         = $Admin
                RoleDefinitionName = $FileShareElevatedContributorRole.Name
                Scope              = $scope
                ErrorAction        = "Stop"
            }
            New-AzRoleAssignment @ElevatedContributorRole
            Write-Host "Successfully added role assignment" -ForegroundColor Cyan
        }
        catch {
            Write-Warning "Failed to assign role"
            Write-Warning $Error[0].Exception
        }
    }

    # Add Groups to Roles
    foreach ($Group in $FSContributorGroups) {
        Write-Host "Assigning Group $Group to Role $($FileShareContributorRole.Name)" -ForegroundColor Cyan
        try {
            $ContributorRoleGroup = @{
                ObjectId           = (Get-AzADGroup -SearchString $Group).Id
                RoleDefinitionName = $FileShareContributorRole.Name
                ResourceGroupName  = $ResourceGroupName
                ErrorAction        = "Stop"
            }
            New-AzRoleAssignment @ContributorRoleGroup
            Write-Host "Successfully added role assignment" -ForegroundColor Cyan
        }
        catch {
            Write-Warning "Failed to assign role"
            Write-Warning $Error[0].Exception
        }
    }
}

function ConfigureNTFSPermissions {
    $StorageAcccount = Get-AzStorageAccount -Name $StorageAccountName -ResourceGroupName $ResourceGroupName
    $Key = Get-AzStorageAccountKey -ResourceGroupName $ResourceGroupName $StorageAcccount.StorageAccountName | Where-Object { $_.KeyName -eq "Key1" }
    $Path = "\\" + $StorageAccountName + ".file.core.windows.net" + "\" + $ShareName
    $DriveLetter = ($DriveLetter + ":")
    
    $connectTestResult = Test-NetConnection -ComputerName ($StorageAccountName + ".file.core.windows.net") -Port 445
    if ($connectTestResult.TcpTestSucceeded) {
        try {
            $DriveParams = @{
                LocalPath = $DriveLetter
                RemotePath = $Path
                UserName = ("Azure\" + $StorageAccountName)
                Password = $Key.Value
                ErrorAction = "Stop"
            }
            New-SmbMapping @DriveParams | Out-Null
        }
        catch {
            Write-Warning "Drive Failed to map. Exiting"
            Write-Warning $Error[0].Exception
            Exit 1
        }
    }
    else {
        Write-Warning -Message "Unable to reach the Azure storage account via port 445"
        Exit 1
    }
    
    Write-Host "Existing NTFS permissions are:" -ForegroundColor Cyan
    icacls $DriveLetter
    
    Write-Host "Setting new NTFS permissions:" -ForegroundColor Cyan
    icacls $DriveLetter /remove "Authenticated Users"
    icacls $DriveLetter /grant '"Authenticated Users":(M)'
    icacls $DriveLetter /grant '"Creator Owner":(OI)(CI)(IO)(M)'
    icacls $DriveLetter /remove "Builtin\Users"
    
    Write-Host "New permissions are:" -ForegroundColor Cyan
    icacls $DriveLetter
    
    Write-host "Removing mapped drive" -ForegroundColor Cyan
    Remove-SmbMapping -LocalPath $DriveLetter -Force
}

function ImportModule {
    Write-Host "Importing $ModuleName Module" -ForegroundColor Cyan
    try {
        Import-Module -Name $ModuleName -Force -ErrorAction Stop
    }
    catch {
        Write-Warning "Failed to Import $ModuleName Module. Exiting"
        Exit 1
    }
}
#endregion

#region execute
# ============================================================================
# Download and Import Module
# ============================================================================
$OutFile = $ModulePath + "\" + ($DownloadUrl | Split-Path -Leaf)
$ModuleName = "AZFilesHybrid"

$AZFilesHybrid = (Get-Module -Name $ModuleName)
if ($null -ne $AZFilesHybrid) {
    Write-Host "$($ModuleName) version $($AZFilesHybrid.Version) is installed"
    #Import AzFilesHybrid module
    ImportModule
}
else {
    if (!(Test-Path -Path $ModulePath)) {
        New-Item -Path $ModulePath -ItemType Directory | Out-Null
    }
    try {
        Write-Host "Downloading $ModuleName PowerShell Module" -ForegroundColor Cyan
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $OutFile -ErrorAction Stop
        Expand-Archive -Path $OutFile -DestinationPath $ModulePath -Force
        # Navigate to where AzFilesHybrid is unzipped and stored and run to copy the files into your path
        Push-Location $ModulePath
        .\CopyToPSPath.ps1
        #Import AzFilesHybrid module
        ImportModule
    }
    catch {
        Write-Warning "Failed to Download $ModuleName Module. Exiting"
        Exit 1
    }    
}

# ============================================================================
# Select Azure Subscription
# ============================================================================
#Login with an Azure AD credential that has either storage account owner or contributer RBAC assignment
Write-Host "Connecting to Azure" -ForegroundColor Cyan
try {
    Connect-AzAccount -ErrorAction Stop
    Select-AzSubscription -SubscriptionId $SubscriptionId -ErrorAction Stop
}
catch {
    Write-Warning "Failed to set Azure Subscription. Exiting"
    Exit 1    
}

# ============================================================================
# Join Storage Account
# ============================================================================
if ($JoinStorageAccountToDomain.IsPresent) {
    JoinStorageAccountToDomain
}

# ============================================================================
# Debug if required
# ============================================================================
if ($DebugStorageAccountDomainJoin.IsPresent) {
    DebugStorageAccount
}

# ============================================================================
# Assign Roles
# ============================================================================
if ($ConfigIAMRoles.IsPresent) {
    AssignIAMRoles
}

# ============================================================================
# Set NTFS permissions for Containers
# ============================================================================
if ($ConfigNTFSPermissions.IsPresent) {
    ConfigureNTFSPermissions
}

Push-Location ..
Exit 0
#endregion