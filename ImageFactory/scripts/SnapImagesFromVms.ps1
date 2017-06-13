param
(
    [Parameter(Mandatory=$true, HelpMessage="The location of the factory configuration files")]
    [string] $ConfigurationFileLocation,

    [Parameter(Mandatory=$true, HelpMessage="The name of the configuration to process")]
    [string] $ConfigurationName
)

$modulePath = Join-Path (Split-Path ($Script:MyInvocation.MyCommand.Path)) "helpers.psm1"
Import-Module $modulePath

Write-Output "ConfigurationFileLocation: $ConfigurationFileLocation"
Write-Output "ConfigurationName: $ConfigurationName"
Write-Output ""

#resolve any relative paths in ConfigurationLocation 
$ConfigurationFileLocation = (Resolve-Path $ConfigurationFileLocation).Path

$scriptFolder = Split-Path $Script:MyInvocation.MyCommand.Path
$goldenImagesPath = Join-Path (Split-Path $ConfigurationFileLocation) "GoldenImages"

# Parse the config file
$config = (ConvertFrom-Json -InputObject (gc $ConfigurationFileLocation -Raw)).Config
$configsToProcess = @($config | Where-Object { $_.Name -eq $ConfigurationName})
Write-Output "Found [$($configsToProcess.Length)] configuration(s) to process."

SaveProfile

$jobs = @()

# Script block for cr images
$createImageBlock = {
    Param($modulePath, $imageToCreate)
    Import-Module $modulePath
    LoadProfile

    $imageName = $imageToCreate.imagename 
    $deployName = "Deploy-$imagename".Replace(" ", "").Replace(",", "")
    Write-Output "Creating Image $imagename from template"
    $deployResult = New-AzureRmResourceGroupDeployment -Name $deployName -ResourceGroupName $imageToCreate.ResourceGroupName -TemplateFile $imageToCreate.templatePath -existingLabName $imageToCreate.DevTestLabName -existingVMResourceId $imageToCreate.vmResourceId -imageName $imagename -imageDescription $imageToCreate.imageDescription -imagePath $imageToCreate.imagePath -osType $imageToCreate.osType

    if($deployResult.ProvisioningState -eq "Succeeded"){
        Write-Output "Successfully deployed image"
        $foundimage = (Get-AzureRmResource -ResourceName $imageToCreate.DevTestLabName -ResourceGroupName $imageToCreate.ResourceGroupName -ResourceType 'Microsoft.DevTestLab/labs/customImages' -ApiVersion '2017-04-26-preview') | Where-Object {$_.name -eq $imagename}
        if($foundimage.Count -eq 0){
            Write-Warning "$imagename was not created successfully"
        }
    }

    if($deploySuccess -eq $false){
        Write-Error "Creation of Image $imageName failed"
    }
}

foreach($configToProcess in $configsToProcess)
{   

    if ($configsToProcess.MakeImage -ne $true){
        Write-Output "Config [$($configToProcess.Name)] is set to not make images.. skipping"
        continue
    }

    # Ensure we are on the right subscription
    SelectSubscription $configToProcess.ImageFactoryLab.SubscriptionId

    # Get the resource group name
    $FactoryLabResourceGroupName = (Find-AzureRmResource -ResourceType 'Microsoft.DevTestLab/labs' | Where-Object { $_.Name -eq $configToProcess.ImageFactoryLab.LabName}).ResourceGroupName

    # Get a pointer to all the VMs in the subscription
    $allVms = Get-AzureRmResource -ResourceGroupName $FactoryLabResourceGroupName -ResourceType Microsoft.DevTestLab/labs/virtualmachines -ResourceName $configToProcess.ImageFactoryLab.LabName -ApiVersion 2017-04-26-preview

    Write-Output "Found $($allVms.length) running Vms"

    foreach ($currentVm in $allVms){
        Write-Output "Inspecting [$($currentVm.Name)]..."
        #vms with the ImagePath tag are the ones we care about
        $imagePathValue = getTagValue $currentVm 'ImagePath'

        if($imagePathValue) {
            Write-Output "Looking in configuration for template with tag: [$imagePathValue]"            
            $matchedTemplate = GetTemplateByTag -ConfigToProcess $configToProcess -GoldenImagesPath $goldenImagesPath -Tag $imagePathValue
                        
            if ($matchedTemplate -ne $null){
                Write-Output "Found a matching template for VM"
            }else{
                Write-Output "Failed to find a matching template for VM, skipping"
                continue
            }

            Write-Output ("##[command] Found Virtual Machine Running, will snap image of " + $currentVm.Name)

            $splitImagePath = $imagePathValue.Split('\')
            if($splitImagePath.Length -eq 1){
                #the image is directly in the GoldenImages folder. Just use the file name as the image name.
                $newimagename = $splitImagePath[0]
            }
            else {
                #this image is in a folder within GoldenImages. Name the image <FolderName>  <fileName> with <FolderName> set to the name of the folder that contains the image
                $segmentCount = $splitImagePath.Length
                $newimagename = $splitImagePath[$segmentCount - 2] + "  " + $splitImagePath[$segmentCount - 1]
            }

            #clean up some special characters in the image name and stamp it with todays date
            $newimagename = $newimagename.Replace(".json", "").Replace(".", "_")
            $newimagename = $newimagename +  " (" + (Get-Date -Format 'MMM d, yyyy - HH mm').ToString() +  ")"

            $scriptFolder = Split-Path $Script:MyInvocation.MyCommand.Path
            $templatePath = Join-Path $scriptFolder "SnapImageFromVM.json"
            
            if($currentVm.Properties.OsType -eq "Windows") {
                $osType = "Windows"
            }
            else {
                $osType = "Linux"
            }

            $imageToCreate = @{
                ImageName = $newimagename
                ResourceGroupName = $FactoryLabResourceGroupName
                DevTestLabName = $configToProcess.ImageFactoryLab.LabName
                templatePath = $templatePath
                vmResourceId = $currentVm.ResourceId
                imageDescription = $currentVm.Properties.Notes 
                imagePath = $imagePathValue
                osType = $osType
            }

            $existingImage = Get-AzureRmResource -ResourceName $configToProcess.ImageFactoryLab.LabName -ResourceGroupName $FactoryLabResourceGroupName -ResourceType 'Microsoft.DevTestLab/labs/customImages' -ApiVersion '2017-04-26-preview' | Where-Object -FilterScript {$_.Name -eq $newImageName}
            if($existingImage){
                Write-Output "Skipping the creation of $newImageName becuse it already exists"
            }
            else{
                Write-Output "Starting job to create image $newimagename"
                $jobs += Start-Job -Name $imageToCreate.ImageName -ScriptBlock $createImageBlock -ArgumentList $modulePath, $imageToCreate
            }            
        }else{
            Write-Output "No ImagePath detected against VM."
        }
        Write-Output ""
    }

}

if($jobs.Count -ne 0)
{
    try{
        $jobCount = $jobs.Count
        Write-Output "Waiting for $jobCount Image creation jobs to complete"
        foreach ($job in $jobs){
            Receive-Job $job -Wait | Write-Output
        }
    }
    finally{
        Remove-Job -Job $jobs
    }

    Write-Output "Completed snapping images!"
}
else 
{
    Write-Output "No images to create!"
}