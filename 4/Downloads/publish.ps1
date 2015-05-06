
# publish.ps1
#
# Publishes a web site to an AWS stack. This web site may use a database.
# Ensures that all necessary servers are installed through use of a AWS Cloudformation template.
# If the stack already exists, it is updated.
#
# Installs the code of the web site on the EC2 web servers. Updates its web.config file with the server name of the
# provisioned RDS database server. 
#
# Note that this script does not set any parameters in the template, except for the Version parameter and
# the DeploymentBucketName parameter - both required to deploy the web site code. This means that for all
# other parameters the default values are used.

Param(
  [Parameter(Mandatory=$True, HelpMessage="Version name of this deployment. Typically the version number generated by for example TeamCity")]
  [string]$version,

  [Parameter(Mandatory=$True, HelpMessage="The name of the CloudFormation stack")]
  [string]$stackName,

  [Parameter(Mandatory=$True, HelpMessage="Domain of the web site, using Route 53")]
  [string]$websiteDomain,

  [Parameter(Mandatory=$True, HelpMessage="The name of the EC2 Key Pair to allow RDP access to the instances")]
  [string]$keyName,

  [Parameter(Mandatory=$True, HelpMessage="Cidr that is allowed to RDP to EC2 instances and SSMS into RDS instances")]
  [string]$adminCidr,

  [Parameter(Mandatory=$True, HelpMessage="The master user name for the database instance")]
  [string]$dbMasterUsername,

  [Parameter(Mandatory=$True, HelpMessage="The master password for the database instance")]
  [string]$dbMasterUserPassword,

  [Parameter(Mandatory=$True, HelpMessage="S3 bucket where the deployment files will be stored")]
  [string]$bucketName,

  [Parameter(Mandatory=$True, HelpMessage="Path of the template file")]
  [string]$templatePath,

  [Parameter(Mandatory=$True, HelpMessage="Path to the csproj file of the web site to be deployed")]
  [string]$csProjPath
)

Function exists-bucket([string]$bucketName)
{
	Return (Get-S3Bucket -BucketName $bucketName | measure).Count -ne 0
}

# Uploads a file to an S3 bucket.
Function upload-bucket-object([string]$bucketName, [string]$filePath, [string]$keyName)
{
	if (!(exists-bucket $bucketName)) 
    { 
        New-S3Bucket -BucketName $bucketName 
    }
	Write-S3Object -BucketName $bucketName -Key $keyName -File $filePath
}

Function get-stack-status([string]$stackName)
{
	Try
	{
        $stack = Get-CFNStack -StackName $stackName
        Return $stack.StackStatus
	}
	Catch
	{
        Return "DOES NOT EXIST"
	}
}

# Wait until the given stack has reached any of the given status'
# Returns the current status of the stack (which will be one of the status' passed in).
Function waitfor-stack-status([string]$stackName, [string[]]$stackStatuses)
{
    $stackStatus = get-stack-status($stackName)
    while ($stackStatuses -NotContains $stackStatus) 
    { 
        Start-Sleep -s 5 
        $stackStatus = get-stack-status $stackName
    }

    Return $stackStatus
}

Function exists-stack([string]$stackName)
{
	$found = $TRUE
	Try
	{
		# throws an exception when stack does not exist
		Get-CFNStack -StackName $stackName
	}
	Catch
	{
		$found = $FALSE
	}

	Return $found
}

Function create-parameter([string]$key, [string]$value)
{
	$p = new-object Amazon.CloudFormation.Model.Parameter    
	$p.ParameterKey = $key
	$p.ParameterValue = $value

    Return $p
}

# $stackName - name of the stack. You can use this function to both update a stack and to create a new one.
# $version - version of the web site
# $bucketName - S3 bucket where the deployment files will be stored
# $templatePath - path of the template file
Function launch-stack([string]$stackName, [string]$version, `
    [string]$websiteDomain, [string]$keyName, [string]$adminCidr, [string]$dbMasterUsername, [string]$dbMasterUserPassword, `
    [string]$bucketName, [string]$templatePath)
{
    $parameters = @( `
        create-parameter('DeploymentBucketName', $bucketName), `
        create-parameter('Version', $version), `
        create-parameter('WebsiteDomain', $websiteDomain), `
        create-parameter('KeyName', $keyName), `
        create-parameter('AdminCidr', $adminCidr), `
        create-parameter('DbMasterUsername', $dbMasterUsername), `
        create-parameter('DbMasterUserPassword', $dbMasterUserPassword) )


	$template = [system.io.file]::ReadAllText($templatePath)
    $stackExistedPrior = exists-stack $stackName

	if ($stackExistedPrior)
	{
        Write-Host "Updating stack $stackName"
		Update-CFNStack `
			-StackName $stackName `
			-Capability @( "CAPABILITY_IAM" ) `
			-Parameter $parameters `
			-TemplateBody $template
	}
	else
	{
        Write-Host "Creating new stack $stackName"
		New-CFNStack `
			-StackName $stackName `
			-Capability @( "CAPABILITY_IAM" ) `
			-Parameter $parameters `
			-TemplateBody $template
	}

    # Wait until the stack operation is finished (whether succeeded or failed)
    $successStatuses = "CREATE_COMPLETE", "UPDATE_COMPLETE", "UPDATE_COMPLETE_CLEANUP_IN_PROGRESS"
    $failStatuses = "CREATE_FAILED", "ROLLBACK_COMPLETE", "ROLLBACK_FAILED", "UPDATE_ROLLBACK_COMPLETE", `
                        "UPDATE_ROLLBACK_COMPLETE_CLEANUP_IN_PROGRESS", "UPDATE_ROLLBACK_FAILED", "UPDATE_ROLLBACK_IN_PROGRESS"
    $finalStackStatuses = $successStatuses + $failStatuses

    $stackStatus = waitfor-stack-status $stackName $finalStackStatuses
    $success = ($successStatuses -contains $stackStatus)

    Return $success
}


# $stackName - the name of the CloudFormation stack
# $templatePath - path of the template file
# $csProjPath - path to the csproj file of the web site to be deployed
# $version - version of the web site
# $bucketName - S3 bucket where the deployment files will be stored
#
# Returns $True if deployment went good, $False otherwise
Function upload-deployment([string]$version, [string]$stackName, `
    [string]$websiteDomain, [string]$keyName, [string]$adminCidr, [string]$dbMasterUsername, [string]$dbMasterUserPassword, `
    [string]$templatePath, [string]$csProjPath, [string]$bucketName)
{
	$tempDir = $env:temp + '\' + [system.guid]::newguid().tostring()
	$releaseZip = "$tempDir\Release.zip"

	msbuild $csProjPath /t:Package /p:Configuration=Release /p:PackageLocation=$releaseZip /p:AutoParameterizationWebConfigConnectionStrings=False

    # If the last command failed (that is, msbuild), return $False
    # See http://stackoverflow.com/questions/4010763/msbuild-in-a-powershell-script-how-do-i-know-if-the-build-succeeded
    if (! $?) { Return $False }

    Try {
	    # Specify that commands in this script will use credentials from credential store "mycredentials" and apply to us-east-1
	    # See http://docs.aws.amazon.com/powershell/latest/userguide/specifying-your-aws-credentials.html
	    Initialize-AWSDefaults -ProfileName mycredentials -Region us-east-1

	    # Upload deployment file to S3 bucket where it will be picked up by CloudFormation template
	    upload-bucket-object $bucketName $releaseZip "$version.zip"

        $success = launch-stack $stackName $version $websiteDomain $keyName $adminCidr $dbMasterUsername $dbMasterUserPassword $bucketName $templatePath
        Return $success
    }
    Finally {
	    # Remove the temp dir and everything in it
	    Get-ChildItem $tempDir -Recurse | Remove-Item -force -Recurse
    }
}

set-strictmode -version Latest
Add-Type -Path "C:\Program Files (x86)\AWS SDK for .NET\bin\Net45\AWSSDK.dll"
upload-deployment $version $stackName $websiteDomain $keyName $adminCidr $dbMasterUsername $dbMasterUserPassword $templatePath $csProjPath $bucketName










