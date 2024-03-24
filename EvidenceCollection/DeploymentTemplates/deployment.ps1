param(
    [string]$azureRegion,
    [string]$templateFile = ".\template.json",
    [string]$parametersFile = ".\parameters.json"    
)

$script:ErrorActionPreference = 'Stop'

#flatten the parameter file cuz we use it like an object...
[hashtable]$templateParameterFileObject = ConvertFrom-Json (Get-Content -Raw $parametersFile) -AsHashtable
[hashtable]$templateParametersObject = @{}
$templateParameterFileObject.parameters.Keys | ForEach-Object { $templateParametersObject.Add($_, $templateParameterFileObject.parameters[$_].value) }

# try to get the admin user object id from the parameters
[string]$adminUserObjectId = $templateParametersObject['adminUserObjectId']
if([string]::IsNullOrWhitespace($adminUserObjectId)) {
    $ctxAccountId = (Get-AzContext).Account.Id
    $adminUserObjectId = (Get-AzAdUser -Filter "mail eq '$ctxAccountId' or userprincipalname eq '$ctxAccountId'").Id
    if([string]::IsNullOrWhitespace($adminUserObjectId) -and -not $null -eq (Get-Command az)) {
        $adminUserObjectId= az ad signed-in-user show --query id --out tsv
    }
    $templateParametersObject['adminUserObjectId'] = $adminUserObjectId
}
if([string]::IsNullOrWhitespace($adminUserObjectId)){
    Write-Error "Unable to identify user principal for currently logged in user. Either add adminUserObjectId Paramter to your parameter file or please make sure you sign into Azure and Select the appropriate Subscription. If you're running in Cloud Shell, you will need to run:$([Environment]::NewLine)PS> Login-AzAccount -UseDeviceAuthentication"
}

Write-Host "|*|> Deployment Parameters"
$templateParametersObject

[string]$caseNumber = $templateParameterFileObject.parameters.caseNumber.value
[string]$rgName = "case-$caseNumber"

Write-Host "|-|> Creating Resource Group $rgName in $azureRegion"
New-AzResourceGroup -Name $rgName -Location $azureRegion -Tag @{ CaseNumber = $caseNumber } | Out-Null
Write-Host "|+|> Created ResourceGroup"

Write-Host "|-|> Deploying templated resources - deployment name is $caseNumber"
try {
    $deploymentResults = New-AzResourceGroupDeployment -Name $caseNumber -ResourceGroupName $rgName -TemplateFile $templateFile -TemplateParameterObject $templateParametersObject
} catch {
    if($_ -match 'Code:VirtualNetworkNotValid' -or $_ -match 'Code:PrincipalNotFound'){
        Write-Warning "|!|> Retry-able error during deployment, retrying the resource group deployment"
        $deploymentResults = New-AzResourceGroupDeployment -Name $caseNumber -ResourceGroupName $rgName -TemplateFile $templateFile -TemplateParameterObject $templateParametersObject
    } else { 
        throw
    }
}
Write-Host "|+|> Deployment of templated resources complete"

function getOrCreateKey([string]$keyVaultName) { 
    $storageCmkKey = Get-AzKeyVaultKey -VaultName $keyVaultName -Name storageCmk
    if($null -eq $storageCmkKey) {
        $storageCmkKey = Add-AzKeyVaultKey -VaultName $keyVaultName -Name storageCmk -Size 2048 -Destination Software
    }
    return $storageCmkKey
}
Write-Host "|-|> Creating Storage CMK key in $($deploymentResults.Outputs.keyVaultName.value)"
$keyVault = Get-AzKeyVault -VaultName $deploymentResults.Outputs.keyVaultName.value -ResourceGroupName $rgName
try {
    $roleAssignment = New-AzRoleAssignment -Scope $keyVault.ResourceId -objectId $adminUserObjectId -RoleDefinitionId "14b46e9e-c2b7-41b4-b07b-48a6ebf60603"
    $storageCmkKey = getOrCreateKey $deploymentResults.Outputs.keyVaultName.value
} catch {
    [Regex]$clientIpRegex = 'Client address:\s*([^\s+]+)[\s\r\n]*';
    $clientIpMatch = $clientIpRegex.Match($_);
    if($clientIpMatch.Success) {
        $clientIp = $clientIpMatch.Groups[1].Value
        Write-Warning "|!|> script host is not in IP Allow list in Key Vault... adding $clientIp to create CMK key... network rule will be removed... maybe..."
        $keyVault | Add-AzKeyVaultNetworkRule -IpAddressRange "$clientIp/32" -PassThru | Out-Null
        $storageCmkKey = getOrCreateKey $deploymentResults.Outputs.keyVaultName.value
        $keyVault | Remove-AzKeyVaultNetworkRule -IpAddressRange "$clientIp/32" -PassThru | Out-Null
    } else {
        throw
    }
} finally {
    if($null -ne $roleAssignment) {
        Remove-AzRoleAssignment $roleAssignment | Out-Null
    }
}

Write-Host "|+|> Done creating Storage CMK key $($storageCmkKey.Id)"

$storageAccountName = $deploymentResults.Outputs.storageAccountName.value
$uaid = $deploymentResults.Outputs.storageCmkIdentity.value

Write-Host "|-|> Setting the CMK for $storageAccountName"
Set-AzStorageAccount -ResourceGroupName $rgName `
    -AccountName $storageAccountName `
    -IdentityType SystemAssignedUserAssigned `
    -UserAssignedIdentityId $uaid `
    -KeyvaultEncryption `
    -KeyVaultUri $keyVault.VaultUri `
    -KeyName $storageCmkKey.Name `
    -KeyVersion "" `
    -KeyVaultUserAssignedIdentityId $deploymentResults.Outputs.storageCmkIdentity.value | Out-Null
Write-Host "|+|> Done setting CMK for $storageAccountName"    

while($caseNumber.Length -lt 4) { $caseNumber = "0$caseNumber" }
Write-Host "|-|> Setting Storage Container Legal Hold with tag $caseNumber"
$storageAccount = Get-AzStorageAccount -ResourceGroupName $rgName -AccountName $storageAccountName 
Add-AzRmStorageContainerLegalHold -StorageAccount $storageAccount `
                                  -ContainerName 'evidence' `
                                  -Tag $caseNumber `
                                  -AllowProtectedAppendWriteAll $true | Out-Null

Write-Host "|+|> Done setting Storage Container Legal Hold"

Write-Host "|-|> Updating Storage network ACLs"
# storage Account ACLs require Unique sets... Select -Unique ftw!
$allowedIpRules = $deploymentResults.outputs.ipsToAllowInStorage.value | Select-Object -Unique | ForEach-Object { 
    new-object -type Microsoft.Azure.Commands.Management.Storage.Models.PSIpRule -Property @{ Action= 'Allow' ; IpAddressOrRange = $_ } 
}

$rules = Get-AzStorageAccountNetworkRuleSet $rgName $storageAccountName
Update-AzStorageAccountNetworkRuleSet $rgName $storageAccountName `
            -Bypass $rules.Bypass `
            -DefaultAction $rules.DefaultAction `
            -IPRule $allowedIpRules `
            -ResourceAccessRule $rules.ResourceAccessRules `
            -VirtualNetworkRule $rules.VirtualNetworkRules `
    | Out-Null

Write-Host "|+|> Done updating Storage network ACLs"


Write-Host "======== Deployment Completed ==================================================================================="
Write-Host "Connection Info: "
Write-Host "VM Info:             $($deploymentResults.Outputs.sshConnectionCommand.value)"
Write-Host "Blob Container URI:  $($deploymentResults.Outputs.blobContainerUri.value)"
Write-Host "Key Vault URI:       $($deploymentResults.Outputs.keyVaultUri.value)"
Write-Host "  You may want to install AZ CLI on this VM - read the docs here: https://learn.microsoft.com/en-us/cli/azure/install-azure-cli-linux?pivots=apt"
Write-Host "   or just run: curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash"
Write-Host "    Reader and Writer SAS Tokens are stored in the above Key Vault"
Write-Host "    Secrets in the Key Vault are named reader- or writer- followed by the allowed IP Address (with . replaced as a - due to Key Vault secret naming restrictions)."
Write-Host "    Key Vault is set for private only access and is accessible by the reviewer VM Identity"
Write-Host "    Use AZ CLI from the VM to get SAS tokens by signing in with the VM identity and using az keyvault secrets commands like this: "
Write-Host "        bash$ az login --identity"
Write-Host "        bash$ az keyvault secret list --id $($deploymentResults.Outputs.keyVaultUri.value)"
Write-Host "        bash$ az keyvault secret show --id $($deploymentResults.Outputs.keyVaultUri.value)secrets/reader-100-200-30-40"
Write-Host "Cleanup Info:"
Write-Host " To remove Storage Accounts you must remove the legal hold, execute the following PowerShell to remove the hold:"
Write-Host " PS> `$acct=Get-AzStorageAccount | ? { `$_.Tags.CaseNumber -eq $caseNumber }  "
Write-Host " PS> Remove-AzRmStorageContainerLegalHold -ContainerName 'evidence' ``"
Write-Host "   -Tag $caseNumber -ResourceGroupName '$rgName' ``"
Write-Host "   -StorageAccountName `$acct.StorageAccountName"
Write-Host "================================================================================================================="
