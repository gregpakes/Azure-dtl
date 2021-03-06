param
(
    [Parameter(Mandatory=$true, HelpMessage="The location of the factory configuration files")]
    [string] $ConfigurationFileLocation,

    [Parameter(Mandatory=$true, HelpMessage="The name of the configuration to process")]
    [string] $ConfigurationName
)

$modulePath = Join-Path (Split-Path ($Script:MyInvocation.MyCommand.Path)) "helpers.psm1"
Import-Module $modulePath -force

Write-Output "ConfigurationFileLocation: $ConfigurationFileLocation"
Write-Output "ConfigurationName: $ConfigurationName"
Write-Output ""

#resolve any relative paths in ConfigurationLocation 
$ConfigurationFileLocation = (Resolve-Path $ConfigurationFileLocation).Path
$goldenImagesPath = Join-Path (Split-Path $ConfigurationFileLocation) "GoldenImages"


SaveProfile

$jobs = @()

# Script block for deleting images
$deleteImageBlock = {
    Param($modulePath, $imageToDelete)
    Import-Module $modulePath
    LoadProfile

    SelectSubscription $imageToDelete.SubscriptionId
    deleteImage $imageToDelete.ResourceGroupName $imageToDelete.ResourceName
}

# Parse the config file
$config = (ConvertFrom-Json -InputObject (gc $ConfigurationFileLocation -Raw)).Config
$configsToProcess = @($config | Where-Object { $_.Name -eq $ConfigurationName})
Write-Output "Found [$($configsToProcess.Length)] configuration(s) to process."

foreach($configToProcess in $configsToProcess)
{
    Write-Output "##[command] Processing configuration [$($configToProcess.Name)]"
    Write-Output ""

    # Get the resource group name
    $FactoryLabResourceGroupName = (Find-AzureRmResource -ResourceType 'Microsoft.DevTestLab/labs' | Where-Object { $_.Name -eq $configToProcess.ImageFactoryLab.LabName}).ResourceGroupName

    # Add our 'current' lab (the factory lab) to the list of labs we're going to iterate through
    $factorylabInfo = (New-Object PSObject |
        Add-Member -PassThru NoteProperty ResourceGroup $FactoryLabResourceGroupName |
        Add-Member -PassThru NoteProperty SubscriptionId $configToProcess.ImageFactoryLab.SubscriptionId |
        Add-Member -PassThru NoteProperty Labname $configToProcess.ImageFactoryLab.LabName
    )

    

    # Iterate through all the labs
    foreach ($selectedLab in $configToProcess.DistributionSettings.Labs){
       
        Write-Output "Processing lab [$($selectedLab.LabName)]"

         # Get the resource group name
        $SelectedLabResourceGroupName = (Find-AzureRmResource -ResourceType 'Microsoft.DevTestLab/labs' | Where-Object { $_.Name -eq $selectedLab.LabName}).ResourceGroupName

        # Get the list of images in the current lab
        SelectSubscription $selectedLab.SubscriptionId
        $allImages = Get-AzureRmResource -ResourceName $selectedLab.LabName -ResourceGroupName $SelectedLabResourceGroupName -ResourceType 'Microsoft.DevTestLab/labs/customImages' -ApiVersion '2017-04-26-preview'

        # Get the images to delete (generated by factory + only old images for each group based on retention policy)
        $imageObjectsToDelete = $allImages | ?{$_.Tags } | ForEach-Object { New-Object -TypeName PSObject -Prop @{
                                        ResourceName=$_.ResourceName
                                        ResourceGroupName=$_.ResourceGroupName
                                        SubscriptionId=$_.SubscriptionId
                                        CreationDate=$_.Properties.CreationDate
                                        ImagePath=getTagValue $_ 'ImagePath'
                                    }} | 
                                    Group-Object {$_.ImagePath} |
                                    ForEach-Object {$_.Group | Sort-Object CreationDate -Descending | Select-Object -Skip $configToProcess.DistributionSettings.ImagesToSave}

        # Retention policy for images
        foreach($template in $configToProcess.Templates){
            $templateFiles = GetTemplateFiles -GoldenImagesPath $goldenImagesPath -Template $template
       
            Write-Output "Looking for templates in TemplatePath [$($template.TemplatePath)]. Found [$($templateFiles.count)] template(s)."  

            foreach($templateFile in $templateFiles){
                $tag = $templateFile.FullName.Substring($GoldenImagesPath.Length + 1)
                
                # Delete any old images for this lab
                foreach ($imageToDelete in $imageObjectsToDelete) {
                    if ($tag -eq $imageToDelete.ImagePath){
                        Write-Output "Creating job to delete images in line with retention policy [$($configToProcess.DistributionSettings.ImagesToSave)] for tag [$tag]"
                        $jobs += Start-Job -Name $imageToDelete.ResourceName -ScriptBlock $deleteImageBlock -ArgumentList $modulePath, $imageToDelete
                    }
                }
            }
        }


        # look for removed images for this lab across the whole configuration.
        # We want to remove images that have been removed from being distributed to this lab.
        # This requires that we look across all configs and this lab may appear in other configs 
        # and we don't want to remove images that are still used in other configs.

        $templatesThatShouldBeInLab = @()

        $templatesThatShouldBeInLab = GetImageTagsThatShouldBeInLab -Configuration $config -LabName $selectedLab.LabName -GoldenImagesPath $goldenImagesPath

        # Loop through the images and remove any that should not be there
        foreach($image in $allImages){
            #If this image is for an ImagePath that no longer exists then delete it. They must have removed this image from the factory
             $imagePath = getTagValue $image 'ImagePath'
             $resName = $image.ResourceName

             if ($imagePath)
             {
                 $isImageValidForLab = $false

                foreach($validTemplate in $templatesThatShouldBeInLab){
                    if ($validTemplate -eq $imagePath){
                        Write-Output "Existing Image [$imagePath] is valid for lab [$($selectedLab.LabName)]"
                        $isImageValidForLab = $true
                        break
                    }
                }

                if ($isImageValidForLab -eq $false){
                    Write-Output "Image [$imagePath] is not valid for lab [$($selectedLab.LabName)], deleting..."
                    $jobs += Start-Job -Name $image.ResourceName -ScriptBlock $deleteImageBlock -ArgumentList $modulePath, $image
                }
             }else{
                Write-Warning "Image $resName is being ignored because it does not have the ImagePath tag"
             }

        }





        # $goldenImagesFolder = Join-Path $ConfigurationLocation "GoldenImages"
        # $goldenImageFiles = Get-ChildItem $goldenImagesFolder -Recurse -Filter "*.json" | Select-Object FullName
        # foreach($image in $allImages){
        #     #If this image is for an ImagePath that no longer exists then delete it. They must have removed this image from the factory
        #     $imagePath = getTagValue $image 'ImagePath'
        #     $resName = $image.ResourceName

        #     if($imagePath) {
        #         $filePath = Join-Path $goldenImagesFolder $imagePath
        #         $existingFile = $goldenImageFiles | Where-Object {$_.FullName -eq $filePath}
        #         if(!$existingFile){
        #             #The GoldenImage template for this image has been deleted. We should delete this image (unless we are already deleting it from previous check)
        #             $alreadyDeletingImage = $imageObjectsToDelete | Where-Object {$_.ResourceName -eq $resName }
        #             if($alreadyDeletingImage){
        #                 Write-Output "Image $resName is for a removed GoldenImage and has also been expired"
        #             }
        #             else {
        #                 Write-Output "Image $resName is for a removed GoldenImage. Starting job to remove the image."
        #                 #$jobs += Start-Job -Name $image.ResourceName -ScriptBlock $deleteImageBlock -ArgumentList $modulePath, $image
        #             }
        #         }
        #         else{
        #             #if this is an image from a target lab, make sure it has not been removed from the labs.json file
        #             $labName = $selectedLab.LabName
        #             if($labName -ne $DevTestLabName){
        #                 $shouldCopyToLab = ShouldCopyImageToLab -lab $selectedLab -image $image
        #                 if(!$shouldCopyToLab){
        #                     Write-Output "Image $resName is has been removed from Labs.json for $labName. Starting job to remove the image."
        #                     #$jobs += Start-Job -Name $image.ResourceName -ScriptBlock $deleteImageBlock -ArgumentList $modulePath, $image
        #                 }
        #             }
        #         }
        #     }
        #     else{
        #         Write-Warning "Image $resName is being ignored because it does not have the ImagePath tag"
        #     }
        # }

        Write-Output ""
    }

}

# Look for images that have been removed from the factory completely



if($jobs.Count -ne 0)
{
    try{
        Write-Output "Waiting for Image deletion jobs to complete"
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
    Write-Output "No images to delete!"
}