param(
    [string]$azureRegion,
    [string]$templateFile = ".\template.json",
    [string]$parametersFile = ".\parameters.json"
)

$script:ErrorActionPreference = 'Stop'
[int]$caseNumber = [int]::Parse((ConvertFrom-Json (Get-Content -Raw $parametersFile)).parameters.caseNumber.value)
[string]$rgName = "case-$caseNumber"
Write-Host "|-|> Creating Resource Group $rgName in $azureRegion"
New-AzResourceGroup -Name $rgName -Location $azureRegion -Tag @{ CaseNumber = $caseNumber }
Write-Host "|+|> Created ResourceGroup"

Write-Host "|-|> Deploying templated resources - deployment name is $caseNumber"
$deploymentResults = New-AzResourceGroupDeployment -Name $caseNumber -ResourceGroupName $rgName -TemplateFile $templateFile -TemplateParameterFile $parametersFile
Write-Host "|+|> Deployment of templated resources complete"

$storageAccountName = $deploymentResults.Outputs.storageAccountName.value
$rules = Get-AzStorageAccountNetworkRuleSet $rgName $storageAccountName

Write-Host "|-|> Setting Storage Container Legal Hold"
Get-AzStorageAccount -ResourceGroupName $rgName `
                     -AccountName $storageAccountName `
    | Add-AzRmStorageContainerLegalHold -ContainerName 'evidence' `
                                        -Tag $caseNumber `
                                        -AllowProtectedAppendWriteAll $true

Write-Host "|+|> Done setting Storage Container Legal Hold"

Write-Host "|-|> Updating Storage network ACLs"
# storage Account ACLs require Unique sets... Select -Unique ftw!
$allowedIpRules = $deploymentResults.outputs.ipsToAllowInStorage.value | Select-Object -Unique | ForEach-Object { 
    new-object -type Microsoft.Azure.Commands.Management.Storage.Models.PSIpRule -Property @{ Action= 'Allow' ; IpAddressOrRange = $_ } 
}

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
Write-Host "================================================================================================================="