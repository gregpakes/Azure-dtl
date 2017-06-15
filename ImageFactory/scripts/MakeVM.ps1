param
(
    [Parameter(Mandatory=$true, HelpMessage="The full path to the module to import")]
    [string] $ModulePath,
    
    [Parameter(Mandatory=$true, HelpMessage="The full path of the template file")]
    [string] $TemplateFilePath,
    
    [Parameter(Mandatory=$true, HelpMessage="The name of the lab")]
    [string] $DevTestLabName,
    
    [Parameter(Mandatory=$true, HelpMessage="The name of the VM to create")]
    [string] $VmName,
    
    [Parameter(Mandatory=$true, HelpMessage="The vms unique identifier")]
    [string] $ImagePath,

    [Parameter(Mandatory=$false, HelpMessage="The base image identifier")]
    [string] $BaseImageIdentifier,

    [Parameter(Mandatory=$false, HelpMessage="VmPassword")]
    [securestring]$password,

    [Parameter(Mandatory=$false, HelpMessage="The base image identifier")]
    [string] $customImageId,

    [Parameter(ValueFromRemainingArguments=$true)]
    [string[]]$args
)

Import-Module $ModulePath
LoadProfile

# Pull in any other parameters that we may want to pass on through to the makevm.ps1
$dynamicParameters = GetDynamicParameters $args

Write-Output "------------"
Write-Output "Starting Deploy for $VmName"
Write-Output "ModulePath: $ModulePath"
Write-Output "VM Name: $VmName"
Write-Output "TemplateFilePath: $TemplateFilePath"
Write-Output "DevTestLabName: $DevTestLabName"
Write-Output "ImagePath: $ImagePath"
Write-Output "CustomImageId: $customImageId"
foreach ($key in $dynamicParameters.Keys) {    
  Write-Output "$key`: $($dynamicParameters[$key])"
}
Write-Output ""

#if the VM already exists then we fail out.
$existingVms = Find-AzureRmResource -ResourceType "Microsoft.DevTestLab/labs/virtualMachines" -ResourceNameContains $DevTestLabName | Where-Object { $_.Name -eq "$DevTestLabName/$vmName"}
if($existingVms.Count -ne 0){

    # Get the resource
    $vm = (Get-AzureRmResource -Id $existingVms[0].ResourceId)
    Write-Warning "VM already exists - Continue"

    # We should start the VM

    return (New-Object PSObject |
        Add-Member -PassThru NoteProperty VMName $vm.Name |
        Add-Member -PassThru NoteProperty VMResourceId $vm.ResourceId |
        Add-Member -PassThru NoteProperty VMFqdn $vm.Properties.fqdn
 	)
}
else
{

 	# Look for parameters file
 	$templatefolder = Split-Path $TemplateFilePath 
    $templateFileName = Get-ChildItem $TemplateFilePath | % {$_.BaseName}
 	$templateParameterFile = Join-Path $templatefolder "$templateFileName.parameters.json"
    Write-Output "Looking for parameters file at [$templateParameterFile]"
 	if (!(Test-Path ($templateParameterFile))){
 		$templateParameterFile = $null
 	}

    # Get the resource group name
    $ResourceGroupName = (Find-AzureRmResource -ResourceType 'Microsoft.DevTestLab/labs' | Where-Object { $_.Name -eq $DevTestLabName}).ResourceGroupName

    $arguments = @{
        Name = "Deploy-$vmName" 
        ResourceGroupName = $ResourceGroupName
        TemplateFile = $TemplateFilePath
        LabName = $DevTestLabName
        NewVMname = $vmName       
    }

    if ($customImageId -ne $null -and $customImageId -ne ""){
        $arguments.Add("CustomImageId", $customImageId)
    }

    if ($password -ne $null -and $password -ne ""){
        $arguments.Add("Password", $password)
    }

    foreach ($key in $dynamicParameters.Keys) {
        $arguments.Add($key, $dynamicParameters[$key])         
    }

 	if ($templateParameterFile -eq $null){
        $vmDeployResult = New-AzureRmResourceGroupDeployment @arguments
 		#$vmDeployResult = New-AzureRmResourceGroupDeployment -Name "Deploy-$vmName" -ResourceGroupName $ResourceGroupName -TemplateFile $TemplateFilePath -labName $DevTestLabName -newVMName $vmName  -userName $machineUserName -password $machinePassword -size $vmSize -
 	}else{
 		Write-Output "Starting deployment with parameters file [$templateParameterFile]"
        $arguments.Add("TemplateParameterFile", $templateParameterFile)
        $vmDeployResult = New-AzureRmResourceGroupDeployment @arguments
 		#$vmDeployResult = New-AzureRmResourceGroupDeployment -Name "Deploy-$vmName" -ResourceGroupName $ResourceGroupName -TemplateFile $TemplateFilePath -TemplateParameterFile $templateParameterFile -labName $DevTestLabName -newVMName $vmName  -userName $machineUserName -password $machinePassword -size $vmSize
 	}

     if($vmDeployResult.ProvisioningState -eq "Succeeded"){
         Write-Output "##[section]Successfully deployed $vmName from $imagePath"

         #set the imagePath tag on the VM
         Write-Output "Stamping the VM $vmName with originalImageFile $imagePath"
         $existingVm = Find-AzureRmResource -ResourceType "Microsoft.DevTestLab/labs/virtualMachines" -ResourceNameContains $DevTestLabName | Where-Object { $_.Name -eq "$DevTestLabName/$vmName"}

         #Determine if artifacts succeeded
         Write-Output "Determining artifact status."
         $filter = '$expand=Properties($expand=ComputeVm,NetworkInterface,Artifacts)'
 		 $existingVmDetails = Get-AzureRmResource -ResourceType 'Microsoft.DevTestLab/labs/virtualmachines' -Name $existingVm.Name -ResourceGroupName $existingVm.ResourceGroupName -ODataQuery $filter
         $existingVmArtStatus = $existingVmDetails.Properties.ArtifactDeploymentStatus
         if ($existingVmArtStatus.totalArtifacts -eq 0 -or $existingVmArtStatus.deploymentStatus -eq "Succeeded")
         {
             Write-Output "##[section]Successfully deployed $vmName from $imagePath"
            
             $tags = $existingVm.Tags
             if((get-command -Name 'New-AzureRmResourceGroup').Parameters["Tag"].ParameterType.FullName -eq 'System.Collections.Hashtable'){
                 # Azure Powershell version 2.0.0 or greater - https://github.com/Azure/azure-powershell/blob/v2.0.1-August2016/documentation/release-notes/migration-guide.2.0.0.md#change-of-tag-parameters
                 $tags += @{ImagePath=$imagePath}
             }
             else {
                 # older versions of the cmdlets use a hashtable array to represent the Tags
                 $tags += @{Name="ImagePath";Value="$imagePath"}
             }

             Write-Output "Getting resource ID from Existing Vm"
             $vmResourceId = $existingVm.ResourceId 
             Write-Output "Resource ID: $vmResourceId"
 			 $vmFqdn = $existingVmDetails.Properties.fqdn
 			 Write-Output "Resource FQDN: $vmFqdn"
             Set-AzureRmResource -ResourceId $vmResourceId -Tag $tags -Force
         }
         else
         {
             if ($existingVmArtStatus.deploymentStatus -ne "Succeeded")
             {
                 Write-Error ("##[error]Artifact deployment status is: " + $existingVmArtStatus.deploymentStatus)
             }
             Write-Error "##[error]Deploying VM artifacts failed. $vmName from $TemplateFilePath. Failure details follow:"
             $failedArtifacts = ($existingVmDetails.Properties.Artifacts | Where-Object {$_.status -eq 'failed'})
             if($failedArtifacts -ne $null)
             { 
                 foreach($failedArtifact in $failedArtifacts)
                 {
                     Write-Output ('Failed Artifact ID: ' + $failedArtifact.artifactId)
                     Write-Output ('   ' + $failedArtifact.deploymentStatusMessage)
                     Write-Output ('   ' + $failedArtifact.vmExtensionStatusMessage)
                     Write-Output ''
                 }
             }

             Write-Output "Deleting VM $vmName after failed artifact deployment"
             Remove-AzureRmResource -ResourceId $existingVm.ResourceId -ApiVersion "2017-04-26-preview" -Force
         }
     }
     else {
         Write-Error "##[error]Deploying VM failed:  $vmName from $TemplateFilePath"
     }
	
 	return (New-Object PSObject |
 		   Add-Member -PassThru NoteProperty VMName $vmName |
 		   Add-Member -PassThru NoteProperty VMResourceId $vmResourceId |
 		   Add-Member -PassThru NoteProperty VMFqdn $vmFqdn
 	)
}