param(
    [Parameter(Mandatory=$true, HelpMessage="The location of the factory configuration file")]
    [string] $ConfigurationFileLocation,

    [Parameter(Mandatory=$true, HelpMessage="The name of the configuration to process")]
    [string] $ConfigurationName,

    [Parameter(Mandatory=$false, HelpMessage="Password for the virtual machine")]
    [System.Security.SecureString] $password,

    [Parameter(Mandatory=$false, HelpMessage="Suffix for the VM Name")]
    [string] $vmNameSuffix,
    
    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$args
)

# Import the helpers Module
$modulePath = Join-Path (Split-Path ($Script:MyInvocation.MyCommand.Path)) "helpers.psm1"
Import-Module $modulePath -force

# Pull in any other parameters that we may want to pass on through to the makevm.ps1
$dynamicParameters = GetDynamicParameters $args

Write-Output "ConfigurationFileLocation: $ConfigurationFileLocation"
Write-Output "ConfigurationName: $ConfigurationName"
foreach ($key in $dynamicParameters.Keys) {
  Write-Output "$key`: $($dynamicParameters[$key])"
}

Write-Output ""

#resolve any relative paths in ConfigurationLocation 
$scriptFolder = Split-Path $Script:MyInvocation.MyCommand.Path
$makeVmScriptLocation = Join-Path $scriptFolder "MakeVM.ps1"
$ConfigurationFileLocation = (Resolve-Path $ConfigurationFileLocation).Path
$goldenImagesPath = Join-Path (Split-Path $ConfigurationFileLocation) "GoldenImages"
$createdVms = New-Object System.Collections.ArrayList
$createdFqdns = New-Object System.Collections.ArrayList
$createdVmResourceIds = New-Object System.Collections.ArrayList

# Parse the config file
$config = (ConvertFrom-Json -InputObject (gc $ConfigurationFileLocation -Raw)).Config

$configsToProcess = @($config | Where-Object { $_.Name -eq $ConfigurationName})

Write-Output "Found [$($configsToProcess.Length)] configuration(s) to process."
Write-Output ""

$jobs = @()
SaveProfile

foreach($configToProcess in $configsToProcess)
{

    # Set variables from the config
    $AzureTimeoutInMinutes = if ($configToProcess.$AzureTimeoutInMinutes) { $configToProcess.$AzureTimeoutInMinutes } else { 60 }

    $templatesToProcess = @($configToProcess.Templates)

    if ($configToProcess.ImageFactoryLab -ne $null){
        $factoryLab = GetLab -SubscriptionId $configToProcess.ImageFactoryLab.SubscriptionId -LabName $configToProcess.ImageFactoryLab.LabName
    }else{
        Write-Error "Failed to locate the ImageFactoryLab element in the configuration."
    }

    $factoryLabResourceGroupName = $factoryLab.ResourceGroupName
   
    $factoryLabImages = Get-AzureRmResource -ResourceName $configToProcess.ImageFactoryLab.LabName -ResourceGroupName $factoryLabResourceGroupName -ResourceType 'Microsoft.DevTestLab/labs/customImages' -ApiVersion '2017-04-26-preview'

    # Get the latest of each image
    $imagesToCreate = $factoryLabImages | ?{$_.Tags} | ForEach-Object { New-Object -TypeName PSObject -Prop @{
        ResourceId=$_.ResourceId
        ResourceName=$_.ResourceName
        ResourceGroupName=$_.ResourceGroupName
        SubscriptionId=$_.SubscriptionId
        CreationDate=$_.Properties.CreationDate
        ImagePath=getTagValue $_ 'ImagePath'
    }} | 
    Group-Object {$_.ImagePath} |
    ForEach-Object {$_.Group | Sort-Object CreationDate -Descending | Select-Object -First 1}
        
    $usedVmNames = @()  
    
    # Look for templates
    foreach($template in $templatesToProcess){
        
        $templateFiles = GetTemplateFiles -GoldenImagesPath $goldenImagesPath -Template $template
       
        Write-Output "Looking for templates in TemplatePath [$($template.TemplatePath)]. Found [$($templateFiles.count)] template(s)."     

        if ($template.BaseImageIdentifier -ne $null){
            $baseImage = $imagesToCreate | Where-Object {$_.ImagePath -eq $template.BaseImageIdentifier}

            if (!($baseImage)){
                Write-Warning "Failed to find image for vm config [$($template.BaseImageIdentifier)] - skipping"
                Continue        
            }
        }     
            
        foreach($file in $templateFiles)
        {
            #grab the image path relative to the GoldenImages folder
            $ImagePath = $file.FullName.Substring($goldenImagesPath.Length + 1)
            $baseImageIdentifier = $null

            if ($template.BaseImageIdentifier -ne $null)
            {
                $baseImageIdentifier = $template.BaseImageIdentifier                
            }

            #determine a VM name for each file.  Replace with config vm name if specified
            if ($template.NewVMName -ne $null){
                $startingVmName = $template.NewVMName               
            }else{
                $startingVmName = $file.BaseName
            }

            $vmName = GetVmName -startingName $startingVmName -takenNames $usedVmNames -vmNameSuffix $vmNameSuffix
            $usedVmNames += $vmName

            if ($baseImageIdentifier -eq $null){
                Write-Output "Starting job to create a VM named [$vmName] for [$ImagePath]"
            }else{
                Write-Output "Starting job to create a VM named [$vmName] for [$ImagePath] from base image identifier [$baseImageIdentifier]"
            }

            $params = @{
                ModulePath = $modulePath
                TemplateFilePath = $file.FullName
                DevTestLabName = $configToProcess.ImageFactoryLab.LabName
                VmName = $vmName
                ImagePath = $ImagePath
                CustomImageId = $baseImage.ResourceId
            }

            if ($baseImageIdentifier){
                $params.Add("BaseImageIdentifier", $baseImageIdentifier)
            }

            if ($password){
                $params.Add("Password", $password)
            }
                
            # Add the dynamic parameters to the $params hashtable
            foreach ($key in $dynamicParameters.Keys) {                
                $params.Add($key, $dynamicParameters[$key])
            }

            $jobs += Start-Job -Name $vmName -ScriptBlock {param($script, $passedArgs); & "$script" @passedArgs} -ArgumentList $makeVmScriptLocation, $params         
            Write-Output ""
        }
    }    
    
}


try{
    $jobCount = $jobs.Count
    Write-Output "Waiting for $jobCount VM creation jobs to complete"
    foreach ($job in $jobs){
        $jobOutput = Receive-Job $job -Wait
        if ($jobOutput){
            Write-Output $jobOutput
            $createdVMName = $jobOutput[$jobOutput.Length - 1].VMName
            $createdVMFqdn = $jobOutput[$jobOutput.Length - 1].VMFqdn
            $createdVmResourceId = $jobOutput[$jobOutput.Length - 1].VMResourceId
            if($createdVMName){
                $createdVms.Add($createdVMName)
            }
            if ($createdVMFqdn){
                $createdFqdns.Add($createdVMFqdn)
            }
            if ($createdVmResourceId){
                $createdVmResourceIds.Add($createdVmResourceId)
            }
        }else{
            Write-Error "Job had no output"
        }
    }
}
finally{
    Remove-Job -Job $jobs -force
}

#get machines that show up in the VM blade so we can apply the GoldenImage Tag
$allVms = Find-AzureRmResource -ResourceType "Microsoft.Compute/virtualMachines"

$fqdns = @()

for ($index = 0; $index -lt $createdVms.Count; $index++){
    $currentVmName = $createdVms[$index]
    $currentVmValue = $allVms | Where-Object {$_.Name -eq $currentVmName -and $_.ResourceGroupName.StartsWith($DevTestLabName)}
    if(!$currentVmValue){
        Write-Error "##[error]$currentVmName was not created successfully. It does not appear in the VM blade"
        continue;
    }

    #wait for the machine to get to the correct state
    $stopWaiting = $false
    $stopTime = Get-Date
    $stopTime = $stopTime.AddMinutes($AzureTimeoutInMinutes);

    while ($stopWaiting -eq $false) {
         
        $vm = Get-AzureRmVM -ResourceGroupName $currentVmValue.ResourceGroupName -Name $currentVmValue.ResourceName -Status
        $currentTime = Get-Date

        if (IsVirtualMachineReady -vmName $vm.Name -status $vm.Statuses) {
            $stopWaiting = $true;
        }
        elseif ($currentTime -gt $stopTime){
            $stopWaiting = $true;
            Write-Error "##[error]Creation of $CurrentVmName has timed out"
        }
        else {
            #pause a bit before we try again
            if ($vm.Statuses.Count -eq 0) {
                Write-Output ($vm.Name + " has no status listed. Sleeping before checking again")
            }
            elseif ($vm.Statuses.Count -eq 1) {
                Write-Output ($vm.Name + " currently has status of " +  $vm.Statuses[0].Code + ". Sleeping before checking again")
            }
            else {
                Write-Output ($vm.Name + " currently has status of " +  $vm.Statuses[0].Code + " and " + $vm.Statuses[1].Code + ". Sleeping before checking again")
            }

            Start-Sleep -Seconds 30
        }
    }
}

$joinedFqdns = ($createdFqdns -join ',')
$joinedVms = $createdVms -join ','
$joinedResourceIds = $createdVmResourceIds -join ','

Write-Output "##vso[task.setvariable variable=CreatedVmsFqdns;]$joinedFqdns"
Write-Output "##vso[task.setvariable variable=CreatedVmsNames;]$joinedVms"
Write-Output "##vso[task.setvariable variable=CreatedVmsResourceIds;]$joinedResourceIds"
    
#sleep a bit to make sure the VM creation and tagging is complete
Start-Sleep -Seconds 10