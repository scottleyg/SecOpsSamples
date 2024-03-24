[CmdletBinding]
function Get-InvestigationResources { 
    param(
        [Parameter(Mandatory = $true)]
        [string]$caseNumber,
        [Parameter(Mandatory = $false)]
        [string[]]$resourceTypes
    )
    if($resourceTypes.Length -eq 0) {
        Get-AzResource -Tag @{ CaseNumber = $caseNumber }
    } else { 
        $resourceTypes | 
            ForEach-Object {
                Get-AzResource -Tag @{ CaseNumber = $caseNumber } -ResourceType $_
            }
    }
    
}

[CmdletBinding]
function Get-InvestigationVmSshInfo { 
    param(
        [Parameter(Mandatory = $true)]
        [string]$caseNumber
    )
    $investigationResources = Get-InvestigationResources $caseNumber
    $vm = $investigationResources |
            Where-Object ResourceType -eq microsoft.compute/virtualmachines | 
            Get-AzVm     
    $pip = $investigationResources | 
            Where-Object ResourceType -eq microsoft.network/publicipaddresses;
    $pip = Get-AzPublicIpAddress -ResourceGroupName $pip.ResourceGroupName -Name $pip.Name    
    New-Object PSObject -Property @{ 
        VmPublicIP = $pip.IpAddress
        VmAdminUsername = $vm.OSProfile.AdminUsername
        SshCommand = "ssh -i <your-private-key-file> $($vm.OSProfile.AdminUsername)@$($pip.IPAddress)"
    } 
}

[CmdletBinding]
function Get-InvestigationKeyVaultInfo {
    param(
        [Parameter(Mandatory = $true)]
        [string]$caseNumber
    )    
    $investigationResources = Get-InvestigationResources $caseNumber
    $vault = $investigationResources |
            Where-Object ResourceType -eq Microsoft.KeyVault/vaults | 
            ForEach-Object { Get-AzKeyVault -VaultName $_.Name }
    $vault
}

[CmdletBinding]
function Get-InvestigationSasTokens {
    param(
        [Parameter(Mandatory = $true)]
        [string]$caseNumber
    )     
    Get-InvestigationResources $caseNumber microsoft.keyvault/vaults | 
      ForEach-Object { 
        Get-AzKeyVaultSecret -VaultName $_.Name
      } |
      ForEach-Object {
        Get-AzKeyVaultSecret -VaultName $_.VaultName -Name $_.Name | 
          ForEach-Object { 
            $secret = $_ 
             New-Object PSObject -Property @{ 
               VaultName = $secret.VaultName 
               SecretName = $secret.Name 
               SecretValue = (ConvertFrom-SecureString -AsPlainText $secret.SecretValue) 
             } 
           } 
      }
}