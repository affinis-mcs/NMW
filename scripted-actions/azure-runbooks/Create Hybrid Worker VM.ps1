#description: Create a new vm in the specified vnet and enable is as a hybrid worker for the Nerdio automation account 
#tags: Nerdio, Preview

<# Notes:

Use this scripted action to create a new hybrid worker VM. This is necessary for the Azure runbooks
functionality when using private endpoints on Nerdio's scripted actions storage account. 

The hybrid worker can join either the runbooks automation account or the nerdio manager automation
account; use the "AutomationAccount" parameter to specify which automation account to join the
hybrid worker. After creating a hybrid worker for the Azure runbooks scripted actions, you will
need to go to Settings -> Nerdio Environment and select "enabled" under "Azure runbooks scripted 
actions" to tell Nerdio to use the new hybrid worker.

#>

<# Variables:
{
  "VnetName": {
    "Description": "VNet for the hybrind worker vm",
    "IsRequired": true
  },
  "VnetResourceGroup": {
    "Description": "Resource group of the VNet",
    "IsRequired": true
  },
  "SubnetName": {
    "Description": "Subnet for the hybrind worker vm",
    "IsRequired": true
  },
  "VMName": {
    "Description": "Name of new hybrid worker VM. Must be fewer than 15 characters, or will be truncated.",
    "IsRequired": true,
    "DefaultValue": "nerdio-hw-vm"
  },
  "VMResourceGroup": {
    "Description": "Resource group for the new vm. If not specified, rg of Nerdio Manager will be used.",
    "IsRequired": false
  },
  "VMSize": {
    "Description": "Size of hybrid worker VM",
    "IsRequired": false,
    "DefaultValue": "Standard_D2s_v3"
  },
  "UseAzureHybridBenefit": {
    "Description": "Use AHB if you have a Software Assurance-enabled Windows Server license",
    "IsRequired": false,
    "DefaultValue": "false"
  },
  "HybridWorkerGroupName": {
    "Description": "Name of new hybrid worker group created in the Azure automation account",
    "IsRequired": true,
    "DefaultValue": "nerdio-hybridworker-group"
  },
  "AutomationAccount": {
    "Description": "Which automation account will the hybrid worker be used with. Valid values are ScriptedActions or NerdioManager",
    "IsRequired": true,
    "DefaultValue": "ScriptedActions"
  }
}
#>

$ErrorActionPreference = 'Stop'

$Prefix = ($KeyVaultName -split '-')[0]
$NMEIdString = ($KeyVaultName -split '-')[3]
$NMEAppName = "$Prefix-app-$NMEIdString"
$AppServicePlanName = "$Prefix-app-plan-$NMEIdString"
$KeyVault = Get-AzKeyVault -VaultName $KeyVaultName
$Context = Get-AzContext
$NMESubscriptionName = $context.Subscription.Name
$NMESubscriptionId = $context.Subscription.Id
$NMEResourceGroupName = $KeyVault.ResourceGroupName
$NMERegionName = $KeyVault.Location



##### Optional Variables #####

#Define the following parameters for the temp vm
$vmAdminUsername = "LocalAdminUser"
$vmAdminPassword = ConvertTo-SecureString "LocalAdminP@sswordHere" -AsPlainText -Force
$vmComputerName = $vmname[0..14] -join '' 
 
#Define the following parameters for the Azure resources.
$azureVmOsDiskName = "$VMName-osdisk"
 
#Define the networking information.
$azureNicName = "$VMName-nic"
#$azurePublicIpName = "$VMName-IP"
 
 
#Define the VM marketplace image details.
$azureVmPublisherName = "MicrosoftWindowsServer"
$azureVmOffer = "WindowsServer"
$azureVmSkus = "2019-datacenter-core-g2"

$Vnet = Get-AzVirtualNetwork -Name $VnetName -ResourceGroupName $VnetResourceGroup

if ([string]::IsNullOrEmpty($VMResourceGroup)) {
    $VMResourceGroup = $vnet.ResourceGroupName
}

$azureLocation = $Vnet.Location

if ($UseAzureHybridBenefit -eq $true) {
    $LicenseType = 'Windows_Server'
}
else {
    $LicenseType = 'Windows_Client'
}

$LAW = Get-AzOperationalInsightsWorkspace -Name "$Prefix-app-law-$NMEIdString" -ResourceGroupName $NMEResourceGroupName


if ($AutomationAccount -eq 'ScriptedActions') {
  $AA = Get-AzAutomationAccount -ResourceGroupName $NMEResourceGroupName | Where-Object AutomationAccountName -Match 'runbooks'
}
elseif ($AutomationAccount -eq 'NerdioManager') {
  $AA = Get-AzAutomationAccount -ResourceGroupName $NMEResourceGroupName -Name "$Prefix-app-automation-$NMEIdString"
}
else {
  Throw "AutomationAccount parameter must be either 'ScriptedActions' or 'NerdioManager'"
}

##### Script Logic #####

try {


  #Get the subnet details for the specified virtual network + subnet combination.
  Write-Output "Getting subnet details"
  $Subnet = ($Vnet).Subnets | Where-Object {$_.Name -eq $SubnetName}
  
  #Create the public IP address.
  #Write-Output "Creating public ip"
  #$azurePublicIp = New-AzPublicIpAddress -Name $azurePublicIpName -ResourceGroupName $azureResourceGroup -Location $azureLocation -AllocationMethod Dynamic
  
  #Create the NIC and associate the public IpAddress.
  Write-Output "Creating NIC"
  $azureNIC = New-AzNetworkInterface -Name $azureNicName -ResourceGroupName $VMResourceGroup -Location $azureLocation -SubnetId $Subnet.Id 
  
  #Store the credentials for the local admin account.
  Write-Output "Creating VM credentials"
  $vmCredential = New-Object System.Management.Automation.PSCredential ($vmAdminUsername, $vmAdminPassword)
  
  #Define the parameters for the new virtual machine.
  Write-Output "Creating VM config"
  $VirtualMachine = New-AzVMConfig -VMName $VMName -VMSize $VMSize -LicenseType $LicenseType -IdentityType SystemAssigned
  $VirtualMachine = Set-AzVMOperatingSystem -VM $VirtualMachine -Windows -ComputerName $vmComputerName -Credential $vmCredential -ProvisionVMAgent -EnableAutoUpdate
  $VirtualMachine = Add-AzVMNetworkInterface -VM $VirtualMachine -Id $azureNIC.Id
  $VirtualMachine = Set-AzVMSourceImage -VM $VirtualMachine -PublisherName $azureVmPublisherName -Offer $azureVmOffer -Skus $azureVmSkus -Version "latest" 
  $VirtualMachine = Set-AzVMBootDiagnostic -VM $VirtualMachine -Disable
  $VirtualMachine = Set-AzVMOSDisk -VM $VirtualMachine -StorageAccountType "StandardSSD_LRS" -Caching ReadWrite -Name $azureVmOsDiskName -CreateOption FromImage
  
  #Create the virtual machine.
  Write-Output "Creating new VM"
  $VM = New-AzVM -ResourceGroupName $VMResourceGroup -Location $azureLocation -VM $VirtualMachine -Verbose -ErrorAction stop
  $VM = get-azvm -ResourceGroupName $VMResourceGroup -Name $VMName

  $azProfile = [Microsoft.Azure.Commands.Common.Authentication.Abstractions.AzureRmProfileProvider]::Instance.Profile
  $profileClient = New-Object -TypeName Microsoft.Azure.Commands.ResourceManager.Common.RMProfileClient -ArgumentList ($azProfile)
  $token = $profileClient.AcquireAccessToken($context.Subscription.TenantId)
  $authHeader = @{
    'Content-Type'='application/json'
    'Authorization'='Bearer ' + $token.AccessToken
  }

  write-output "Creating new hybrid worker group in automation account"

  $CreateWorkerGroup = Invoke-WebRequest `
                        -uri "https://$azureLocation.management.azure.com/subscriptions/$($context.subscription.id)/resourceGroups/$NMEResourceGroupName/providers/Microsoft.Automation/automationAccounts/$($AA.AutomationAccountName)/hybridRunbookWorkerGroups/$HybridWorkerGroupName`?api-version=2021-06-22" `
                        -Headers $authHeader `
                        -Method PUT `
                        -ContentType 'application/json' `
                        -Body '{}' `
                        -UseBasicParsing
                  

  $Body = "{ `"properties`": {`"vmResourceId`": `"$($vm.id)`"} }"

  $VmGuid = New-Guid

  write-output "Associating VM with automation account"
  $AddVmToAA = Invoke-WebRequest `
                  -uri "https://$azureLocation.management.azure.com/subscriptions/$($context.subscription.id)/resourceGroups/$NMEResourceGroupName/providers/Microsoft.Automation/automationAccounts/$($AA.AutomationAccountName)/hybridRunbookWorkerGroups/$HybridWorkerGroupName/hybridRunbookWorkers/$VmGuid`?api-version=2021-06-22" `
                  -Headers $authHeader `
                  -Method PUT `
                  -ContentType 'application/json' `
                  -Body $Body `
                  -UseBasicParsing


  write-output "Get automation hybrid service url"
  $Response = Invoke-WebRequest `
                -uri "https://westcentralus.management.azure.com/subscriptions/$($context.subscription.id)/resourceGroups/$NMEResourceGroupName/providers/Microsoft.Automation/automationAccounts/$($AA.AutomationAccountName)?api-version=2021-06-22" `
                -Headers $authHeader `
                -UseBasicParsing

  $AAProperties =  ($response.Content | ConvertFrom-Json).properties
  $AutomationHybridServiceUrl = $AAProperties.automationHybridServiceUrl

  $settings = @{
    "AutomationAccountURL"  = "$AutomationHybridServiceUrl"
  }

  Write-Output "Adding VM to hybrid worker group"
  $SetExtension = Set-AzVMExtension -ResourceGroupName $VMResourceGroup `
                    -Location $azureLocation `
                    -VMName $VMName `
                    -Name "HybridWorkerExtension" `
                    -Publisher "Microsoft.Azure.Automation.HybridWorker" `
                    -ExtensionType HybridWorkerForWindows `
                    -TypeHandlerVersion 0.1 `
                    -Settings $settings

  if ($SetExtension.StatusCode -eq 'OK') {
    write-output "VM successfully added to hybrid worker group"
  }
}
catch {
  write-output "Encountered error $_"
  write-output "Rolling back changes"

  write-output "Removing worker from hybrid worker group"
  if ($SetExtension) {
    $RemoveHybridRunbookWorker = Invoke-WebRequest `
                    -uri "https://$azureLocation.management.azure.com/subscriptions/$($context.subscription.id)/resourceGroups/$NMEResourceGroupName/providers/Microsoft.Automation/automationAccounts/$($AA.AutomationAccountName)/hybridRunbookWorkerGroups/$HybridWorkerGroupName/hybridRunbookWorkers/$VmGuid`?api-version=2021-06-22" `
                    -Headers $authHeader `
                    -Method Delete  `
                    -ContentType 'application/json' `
                    -UseBasicParsing `
                    -ErrorAction Continue
  }

  write-output "Removing hybrid worker group"
  if ($CreateWorkerGroup) {
    $RemoveWorkerGroup = Invoke-WebRequest `
                          -uri "https://$azureLocation.management.azure.com/subscriptions/$($context.subscription.id)/resourceGroups/$NMEResourceGroupName/providers/Microsoft.Automation/automationAccounts/$($AA.AutomationAccountName)/hybridRunbookWorkerGroups/$HybridWorkerGroupName`?api-version=2021-06-22" `
                          -Headers $authHeader `
                          -Method Delete `
                          -ContentType 'application/json' `
                          -UseBasicParsing `
                          -ErrorAction Continue
  }
  if ($VM) {
    write-output "removing VM $VMName"
    Remove-AzVM -Name $VMName -Force -ErrorAction Continue
  }
  if ($azureNIC) {
    write-output "removing NIC $azureNicName"
    Remove-AzNetworkInterface -Name $azureNicName -ResourceGroupName $VMResourceGroup -Force -ErrorAction Continue
  }
  $disk = Get-AzDisk -ResourceGroupName $VMResourceGroup -DiskName $azureVmOsDiskName -ErrorAction Continue
  if ($disk) {
    Remove-AzDisk -ResourceGroupName $AzureResourceGroupName -DiskName $azureVmOsDiskName -Force
  }
}
