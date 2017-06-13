function SelectSubscription($subId){
    # switch to another subscription assuming it's not the one we're already on
    if((Get-AzureRmContext).Subscription.SubscriptionId -ne $subId){
        Write-Output "Switching to subscription $subId"
        Select-AzureRmSubscription -SubscriptionId $subId | Out-Null
    }
}

function GetLab()
{
    param(
        [string]$subscriptionId,
        [string]$LabName
    )

     # Attempt to locate the ImageFactory Lab
    SelectSubscription $subscriptionId
    $factoryLab = Find-AzureRmResource -ResourceType 'Microsoft.DevTestLab/labs' | Where-Object { $_.Name -eq $LabName}

    if (-not $factoryLab){
        Write-Error "Failed to locate lab with name [$LabName]"
    }

    return $factoryLab
}

function GetVmName()
{
    param(
        $startingName,
        $takenNames,
        $vmNameSuffix
    )

    function withsuffix($vmName, $suffix)
    {
        if ($suffix){
            return "$vmName-$suffix"
        }
        return $vmName
    }

    $vmName = $startingName.Replace("_", "").Replace(" ", "");
    if((withsuffix $vmName $vmNameSuffix).Length -gt 15){
        $shortenedName = $vmName.Substring(0, (15 - ((withsuffix $vmName $vmNameSuffix).Length - $vmName.Length)))
        Write-Host "VM name $vmName is too long. Shortening to $shortenedName"
        $vmName = $shortenedName
    }

    while ($takenNames.Contains((withsuffix $vmName $vmNameSuffix))){
        $nameRoot = $vmName
        if((withsuffix $vmName $vmNameSuffix).Length -gt 12){
            $nameRoot = $vmName.Substring(0, (12 - ((withsuffix $vmName $vmNameSuffix).Length - $vmName.Length)))
        }
        $updatedName = $nameRoot + (Get-Random -Minimum 1 -Maximum 999).ToString("000")
        Write-Host "VM name $vmName has already been used. Reassigning to $updatedName"
        $vmName = $updatedName
    }

    return (withsuffix $vmName $vmNameSuffix)
}

function SaveProfile {
    $profilePath = Join-Path $PSScriptRoot "profile.json"

    If (Test-Path $profilePath){
	    Remove-Item $profilePath
    }
    
    Save-AzureRmProfile -Path $profilePath
}

function LoadProfile {
    $scriptFolder = Split-Path $Script:MyInvocation.MyCommand.Path
    Select-AzureRmProfile -Path (Join-Path $scriptFolder "profile.json") | Out-Null
}

function GetDynamicParameters($arguments){
    $DynamicParams = @{}
    switch -Regex ($arguments) {
        '^-' {
            # Parameter name
            if ($name) {
                $DynamicParams[$name] = $value
                $name = $value = $null
            }
            $name = $_ -replace '^-'

            # Remove any trailing colons (from splatting)
            if ($name.substring($name.Length -1, 1) -eq ":"){
                $name = $name.Substring(0,$name.Length -1)
            }
        }
        '^[^-]' {
            # Value
            $value = $_
        }
    }
    if ($name) {
        $DynamicParams[$name] = $value
        $name = $value = $null
    }
    return $DynamicParams
}

function getTagValue($resource, $tagName){
    $result = $null
    if ($resource.Tags){
        $result = $resource.Tags | Where-Object {$_.Name -eq $tagName}
        if($result){
            $result = $result.Value
        }
        else {
            $result = $resource.Tags[$tagName]
        }
    }
    $result
}

function IsVirtualMachineReady ($vmName, $status)
{
    $retval = $false

    if ($status.Count -lt 1) {
        Write-Host ($vmName + " current has no status provided")
    }
    elseif ($status.Count -eq 1) {
        Write-Host ($vmName + " currently has status of " +  $status[0].Code)
    }
    elseif ($status.Count -gt 1) {
        Write-Host ($vmName + " currently has status of " +  $status[0].Code + " and " + $status[1].Code)
    }
    
    if ($status.Count -gt 1) {
        # We have both parameters (provisioning state + power state) - this is the default case
        if (($status[0].Code -eq "ProvisioningState/succeeded") -and ($status[1].Code -eq "PowerState/running")) {
            $retval = $true
        }
        elseif (($status[1].Code -eq "ProvisioningState/succeeded") -and ($status[0].Code -eq "PowerState/running")) {
            $retval = $true
        }
    }

    return $retval
}

function GetTemplateFiles()
{
    param(
        $GoldenImagesPath,
        $Template
    )

    $templatePath = Join-Path $GoldenImagesPath $template.TemplatePath
            
    return @(Get-ChildItem $templatePath -Recurse -Filter "*.json" -Exclude "*.parameters.json")
}

function GetTemplateByTag()
{
    param(
        $ConfigToProcess,
        $GoldenImagesPath,
        $Tag
    ) 

    $matchedTemplate = $null

    foreach($template in $ConfigToProcess.Templates){
        $templateFiles = GetTemplateFiles -GoldenImagesPath $GoldenImagesPath -Template $template

        foreach($templateFile in $templateFiles){
            $ImagePath = $templateFile.FullName.Substring($GoldenImagesPath.Length + 1)

            if ($ImagePath -eq $Tag){
                $matchedTemplate = $template
            }
        }
    }
    return $matchedTemplate
}

function ShouldCopyImageToLab()
{
    param(
        $configToProcess,
        $image,
        $destinationLabName
    )

    $retval = $false

    $matchedLab = $null
    foreach($lab in $configToProcess.DistributionSettings.Labs){
        if ($lab.LabName -eq $destinationLabName){
            $matchedLab = $lab.LabName
        }
    }

    if ($matchedLab -eq $null){
        Write-Host "Failed to find distribution settings for lab [$destinationLabName]"
        return $retval
    }

    $imagePathTag = getTagValue $image 'ImagePath'
    if(!$imagePathTag) {
        #this image does not have the ImagePath tag. Dont copy it
        $retval = $false
    }
    else
    {        
        # Need to check if the lab is allowed
        
        foreach ($template in $configToProcess.Templates) {
            if ($imagePathTag.StartsWith($template.TemplatePath.Replace("/", "\"))) {
                $retVal = $true;
                break;
            }
        }
    }
    $retval
}

function deleteImage ($resourceGroupName, $resourceName)
{
    Write-Output "##[section]Deleting Image: $resourceName"
    Remove-AzureRmResource -ResourceName $resourceName -ResourceGroupName $resourceGroupName -ResourceType 'Microsoft.DevTestLab/labs/customImages' -ApiVersion '2017-04-26-preview' -Force
    Write-Output "##[section]Completed deleting $resourceName"
}

function GetImageTagsThatShouldBeInLab()
{
    param(
        $Configuration,
        $LabName,
        $GoldenImagesPath
    )
    $templatesThatShouldBeInLab = @()

    # Build a list of images that should be in this lab
    Write-Host "Building a list of images that should be in this lab."
    foreach($config in $Configuration){

        if ($config.ImageFactoryLab.LabName -eq $LabName -or @($config.DistributionSettings.Labs | Where-Object {$_.LabName -eq $LabName}).Count -gt 0){
            foreach($templateForLab in $config.Templates){
                $templateFilesForLab = GetTemplateFiles -GoldenImagesPath $goldenImagesPath -Template $templateForLab
                foreach($templateFileForLab in $templateFilesForLab){
                    $imagePath = $templateFileForLab.FullName.Substring($goldenImagesPath.Length + 1)
                    Write-Host "[$imagePath] should be included."
                    $templatesThatShouldBeInLab += $imagePath
                }
            }
        }
    }

    return $templatesThatShouldBeInLab
}