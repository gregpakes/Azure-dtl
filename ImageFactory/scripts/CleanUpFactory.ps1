param
(
    [Parameter(Mandatory=$true, HelpMessage="The location of the factory configuration files")]
    [string] $ConfigurationFileLocation,

    [Parameter(Mandatory=$true, HelpMessage="The name of the configuration to process")]
    [string] $ConfigurationName
)

Write-Output "ConfigurationFileLocation: $ConfigurationFileLocation"
Write-Output "ConfigurationName: $ConfigurationName"
Write-Output ""

#resolve any relative paths in ConfigurationLocation 
$ConfigurationFileLocation = (Resolve-Path $ConfigurationFileLocation).Path
$goldenImagesPath = Join-Path (Split-Path $ConfigurationFileLocation) "GoldenImages"

$modulePath = Join-Path (Split-Path ($Script:MyInvocation.MyCommand.Path)) "helpers.psm1"
Import-Module $modulePath
SaveProfile

# Parse the config file
$config = (ConvertFrom-Json -InputObject (gc $ConfigurationFileLocation -Raw)).Config
$configsToProcess = @($config | Where-Object { $_.Name -eq $ConfigurationName})
Write-Output "Found [$($configsToProcess.Length)] configuration(s) to process."

foreach($configToProcess in $configsToProcess){

    $allVms = Find-AzureRmResource -ResourceType "Microsoft.DevTestLab/labs/virtualMachines" -ResourceNameContains $configToProcess.ImageFactoryLab.LabName
    $jobs = @()

    $deleteVmBlock = {
        Param($modulePath, $vmName, $resourceId)
        Import-Module $modulePath
        LoadProfile
        Write-Output "##[section]Deleting VM: $vmName"
        Remove-AzureRmResource -ResourceId $resourceId -ApiVersion 2017-04-26-preview -Force
        Write-Output "##[section]Completed deleting $vmName"
    }

    # Script block for deleting images
    $deleteImageBlock = {
        Param($modulePath, $imageResourceName, $resourceGroupName)
        Import-Module $modulePath
        LoadProfile
        deleteImage $resourceGroupName $imageResourceName
    }

    Write-Output "Getting list of templates that should have been created as a part of this lab [$($configToProcess.ImageFactoryLab.LabName)]."

    $templatesCreatedForThisConfig = @()
    # We need to get a list of templates that would have been created as a part of the selected configuration
    foreach($template in $configToProcess.Templates){
        $templateFilesForLab = GetTemplateFiles -GoldenImagesPath $goldenImagesPath -Template $template

        foreach($templateFile in $templateFilesForLab){
            $imagePath = $templateFile.FullName.Substring($goldenImagesPath.Length + 1)
            Write-Host "[$imagePath] should be included."
            $templatesCreatedForThisConfig += $imagePath
        }
    }


    # Iterate over all the VMs and delete any that we created
    foreach ($currentVm in $allVms){
        $ignoreTagName = 'FactoryIgnore'
        $factoryIgnoreTag = getTagValue $currentVm $ignoreTagName
        $imagePathTag = getTagValue $currentVm 'ImagePath'
        $vmName = $currentVm.ResourceName
        $provisioningState = (Get-AzureRmResource -ResourceId $currentVm.ResourceId).Properties.ProvisioningState

        if(($provisioningState -ne "Succeeded") -and ($provisioningState -ne "Creating")){
            #these VMs failed to provision. log an error to make sure they get attention from the lab owner then delete them
            Write-Error "$vmName failed to provision properly. Deleting it from Factory"
            $jobs += Start-Job -ScriptBlock $deleteVmBlock -ArgumentList $modulePath, $vmName, $currentVm.ResourceId
        }
        elseif(!$factoryIgnoreTag -and !$imagePathTag){
            #if a VM has neither the ignore or imagePath then log an error
            Write-Error "VM named $vmName is not recognized in the lab. Please add the $ignoreTagName tag to the VM if it belongs here"
        }
        elseif($factoryIgnoreTag){
            Write-Output "Ignoring VM $vmName because it has the $ignoreTagName tag"
        }
        else {
            if (($templatesCreatedForThisConfig | Where-Object {$_ -eq $imagePathTag}).Count -gt 0)
            {
                Write-Output "Starting job to delete VM $vmName"
                $jobs += Start-Job -ScriptBlock $deleteVmBlock -ArgumentList $modulePath, $vmName, $currentVm.ResourceId
            }else{
                Write-Output "VM [$vmName] was not created as a part of this configuration... skipping"
            }
        }
    }

     # Get the resource group name
    $SelectedLabResourceGroupName = (Find-AzureRmResource -ResourceType 'Microsoft.DevTestLab/labs' | Where-Object { $_.Name -eq $configToProcess.ImageFactoryLab.LabName}).ResourceGroupName

    # Find any custom images that failed to provision and delete those
    $bustedLabCustomImages = Get-AzureRmResource -ResourceName $configToProcess.ImageFactoryLab.LabName -ResourceGroupName $SelectedLabResourceGroupName -ResourceType 'Microsoft.DevTestLab/labs/customImages' -ApiVersion '2017-04-26-preview' | Where-Object {($_.Properties.ProvisioningState -ne "Succeeded") -and ($_.Properties.ProvisioningState -ne "Creating")}

    # Delete the custom images we found in the search above
    foreach ($imageToDelete in $bustedLabCustomImages) {
        $jobs += Start-Job -Name $imageToDelete.ResourceName -ScriptBlock $deleteImageBlock -ArgumentList $modulePath, $imageToDelete.ResourceName, $imageToDelete.ResourceGroupName
    }

}

if($jobs.Count -ne 0)
{
    try{
        Write-Output "Waiting for VM Delete jobs to complete"
        foreach ($job in $jobs){
            Receive-Job $job -Wait | Write-Output
        }
    }
    finally{
        Remove-Job -Job $jobs
    }
}
else 
{
    Write-Output "No VMs to delete"
}

Write-Output "Cleanup complete"