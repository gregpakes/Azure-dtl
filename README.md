# Image Factory

This is an extension of the Image Factory found here https://github.com/Azure/azure-devtestlab/tree/master/Scripts.  I used the image factory above as a base and then extended it to have more features.
 
## Getting Started

The concept here is to have a Dev Test Lab that creates, distributes and retires images based on a configuration file.

The sample config file shows three different image factory configs:

```
{
  "Config": [
    {
      "Name": "Base",
      "AzureTimeoutInMinutes": 60,
      "ImageFactoryLab": {
        "SubscriptionId": "c629991b-869a-43aa-aa02-acfe4cda7627",
        "LabName": "ImageFactory"
      },      
      "Templates":[
        {
          "TemplatePath": "Base"
        }
      ],
      "MakeImage": true,
      "DistributionSettings":{
        "MaxConcurrentJobs": 20,        
        "ImagesToSave": 5,
        "Labs":[
          {
            "SubscriptionId": "c629991b-869a-43aa-aa02-acfe4cda7627",
            "LabName": "ImageFactory"          
          }
        ]
      }
    },
    {
      "Name": "Staging",
      "AzureTimeoutInMinutes": 60,
      "ImageFactoryLab": {
        "SubscriptionId": "c629991b-869a-43aa-aa02-acfe4cda7627",
        "LabName": "StagingLab"
      },
      "MakeImage": false,
      "Templates":[
        {
          "BaseImageIdentifier": "other\\weekly.json",
          "TemplatePath":"other\\final.json",
          "NewVMName": "Win2016"
        }
      ],
      "DistributionSettings":{
        "MaxConcurrentJobs": 20,
        "ImagesToSave": 5,
        "Labs": [
          {
            "SubscriptionId": "c629991b-869a-43aa-aa02-acfe4cda7627",
            "LabName": "StagingLab"
          }   
        ]
      }
    },
    {
      "Name": "WeeklyImage",
      "AzureTimeoutInMinutes": 60,
      "ImageFactoryLab": {
        "SubscriptionId": "c629991b-869a-43aa-aa02-acfe4cda7627",
        "LabName": "ImageFactory"
      },
      "MakeImage": true,
      "Templates":[
        {
          "BaseImageIdentifier": "Base\\w2016_sql2016.json",
          "TemplatePath":"other\\weekly.json",
          "NewVMName": "Img"
        }
      ],
      "DistributionSettings":{
        "MaxConcurrentJobs": 20,
        "ImagesToSave": 5,
        "Labs": [
          {
            "SubscriptionId": "c629991b-869a-43aa-aa02-acfe4cda7627",
            "LabName": "StagingLab"
          }   
        ]
      }
    }
  ]
}
```

Each config behaves slightly differently.

The **Base** configuration shows a basic usage where images are created for all template files (*.json) below the "Base" folder.  These images are not distributed to any other labs.

The **WeeklyImage** configuration shows building an image from another image (namely the base image above).  These images are then distributed to a different DevTestLab called **Staging**.

The **Staging** configuration builds a virtual machine based on an existing image (WeeklyImage).  The big difference here is that it is set to not create an image.  This configuration will leave the VM running.  This can be useful for test/staging environments.

### Executing the tasks

The task execution order is:

- StartImageFactory.ps1
    - Creates the VMs based on the configuration
- SnapImagesFromVms.ps1
    - Snaps images of the running VMs
- DistributeImages.ps1
    - Distributes the images based on the passed in configuration
- CleanUpFactory.ps1
    - Cleans up the factory lab
- RetireImages.ps1
    - Retires images based on the retirement settings in the configuration file.