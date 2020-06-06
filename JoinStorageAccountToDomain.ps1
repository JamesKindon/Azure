<#
.SYNOPSIS
    Automates the Download of the AzureFilesHyrbid Module for Domain Joining Storage Accuonts
    Automates the Domain Join tasks for the Storage Accounts
    Automates the deployment of relevant IAM roles 
.DESCRIPTION
    Leverages the scripts provided by Microsoft
    https://docs.microsoft.com/en-us/azure/storage/files/storage-files-identity-auth-active-directory-enable
.NOTES
#>

#Change the execution policy to unblock importing AzFilesHybrid.psm1 module
Set-ExecutionPolicy -ExecutionPolicy Unrestricted -Scope CurrentUser

# ============================================================================
# Variables - change these per subscription (remove the "--")
# ============================================================================
$SubscriptionId = "--SubscriptionID--" #subscription Id
$ResourceGroupName = "--Resource Group--" #resource group name
$StorageAccountName = "--storage account name--" #storage account name
$ShareName = "--fslogix--" #storege account share name
$DomainAccountType = "ServiceLogonAccount" #-DomainAccountType "<ComputerAccount|ServiceLogonAccount>"
$OU = "--OU=Azure FIles,DC=Domain,DC=com--" #-OrganizationalUnitDistinguishedName "<ou-distinguishedname-here>"
$FSContributorGroups = @("WVD Users") # Array of groups to Assign Storage File Data SMB Share Contributor
$FSAdminUsers = @("Jkindon@domain.com") # Array of Admins to assign Storage File Data SMB Share Contributor and Storage File Data SMB Share Elevated Contributor roles
$DownloadUrl = "https://github.com/Azure-Samples/azure-files-samples/releases/download/v0.1.3/AzFilesHybrid.zip"
$ModulePath = "C:\temp\AzFilesHybrid" #Output path for modules

# ============================================================================
# Download and Import Module
# ============================================================================
$OutFile = $ModulePath + "\" + ($DownloadUrl | Split-Path -Leaf)

if (!(Test-Path -Path $ModulePath)) {
    New-Item -Path $ModulePath -ItemType Directory | Out-Null
}
try {
    Write-Host "Downloading AZFilesHybrid PowerShell Module" -ForegroundColor Cyan
    Invoke-WebRequest -Uri $DownloadUrl -OutFile $OutFile -ErrorAction Stop
    Expand-Archive -Path $OutFile -DestinationPath $ModulePath -Force
}
catch {
    Write-Warning "Failed to Download AZ Files Hyrbid Module. Exiting"
    Exit 1
}

# Navigate to where AzFilesHybrid is unzipped and stored and run to copy the files into your path
Push-Location $ModulePath
.\CopyToPSPath.ps1
#Import AzFilesHybrid module
Write-Host "Importing AZFilesHybrid Module" -ForegroundColor Cyan
try {
    Import-Module -Name AzFilesHybrid -Force -ErrorAction Stop
}
catch {
    Write-Warning "Failed to Import Module. Exiting"
    Exit 1
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

# ============================================================================
# Debug if required
# ============================================================================
#You can run the Debug-AzStorageAccountAuth cmdlet to conduct a set of basic checks on your AD configuration with the logged on AD user. 
#This cmdlet is supported on AzFilesHybrid v0.1.2+ version. For more details on the checks performed in this cmdlet, go to Azure Files FAQ.
#Debug-AzStorageAccountAuth -StorageAccountName $StorageAccountName -ResourceGroupName $ResourceGroupName -Verbose

# ============================================================================
# Assign Roles
# ============================================================================
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

Exit 0

