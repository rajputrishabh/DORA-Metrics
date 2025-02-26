﻿param
(
$PAT = <Azure DevOps PAT token>,
$org = "<Azure Devops Organisation name,
$project = <Azure DevOps Project name>,
# Replace with your Workspace ID
$CustomerId = <Azure LogAnalytics Workspace ID>,  
# Replace with your Primary Key
$SharedKey = <Azure LogAnalytics Primary Key> ,

# Specify the name of the record type that you'll be creating
$LogType = "DoraMetricsDFRelease",
$noofdays=543,
#stage name for which DORA metrics needs to be calculated
[String[]]$stgnames=('deploy to dev','prod','uat')
)
# Optional name of a field that includes the timestamp for the data. If the time field is not specified, Azure Monitor assumes the time is the message ingestion time
$TimeStampField = (Get-Date).DateTime

# Create the function to create the authorization signature
Function Build-Signature ($customerId, $sharedKey, $date, $contentLength, $method, $contentType, $resource)
{
    $xHeaders = "x-ms-date:" + $date
    $stringToHash = $method + "`n" + $contentLength + "`n" + $contentType + "`n" + $xHeaders + "`n" + $resource

    $bytesToHash = [Text.Encoding]::UTF8.GetBytes($stringToHash)
    $keyBytes = [Convert]::FromBase64String($sharedKey)

    $sha256 = New-Object System.Security.Cryptography.HMACSHA256
    $sha256.Key = $keyBytes
    $calculatedHash = $sha256.ComputeHash($bytesToHash)
    $encodedHash = [Convert]::ToBase64String($calculatedHash)
    $authorization = 'SharedKey {0}:{1}' -f $customerId,$encodedHash
    return $authorization
}

# Create the function to create and post the request
Function Post-LogAnalyticsData($customerId, $sharedKey, $body, $logType)
{
    $method = "POST"
    $contentType = "application/json"
    $resource = "/api/logs"
    $rfc1123date = [DateTime]::UtcNow.ToString("r")
    $contentLength = $body.Length
    $signature = Build-Signature `
        -customerId $customerId `
        -sharedKey $sharedKey `
        -date $rfc1123date `
        -contentLength $contentLength `
        -method $method `
        -contentType $contentType `
        -resource $resource
    $uri = "https://" + $customerId + ".ods.opinsights.azure.com" + $resource + "?api-version=2016-04-01"

    $headers = @{
        "Authorization" = $signature;
        "Log-Type" = $logType;
        "x-ms-date" = $rfc1123date;
        "time-generated-field" = $TimeStampField;
    }

    $response = Invoke-WebRequest -Uri $uri -Method $method -ContentType $contentType -Headers $headers -Body $body -UseBasicParsing
    return $response.StatusCode

}

$header = @{Authorization = 'Basic ' + [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($PAT)")) }
$url = "https://vsrm.dev.azure.com/$($org)/"
$expand='$expand'
$urlpipelines=$url + "$project/_apis/release/definitions?includeAllProperties=True&$expand=Environments&api-version=6.0"
$pipelines = (Invoke-RestMethod -Method Get -Uri $urlpipelines -Headers $header -ContentType "applicationType/json").value
$pipelines=$pipelines|Where-Object{$_.process.yamlFilename -eq $null}
$requiredrange=(Get-Date).AddDays(-$($noofdays))
$requiredrange =$requiredrange.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
#multistage run for metrics calculation
foreach($stgname in $stgnames)
{
foreach($pipeline in $pipelines)
{
$id=$pipeline.id
$urlreleases=$url + "$project/_apis/release/deployments?includeAllProperties=True&$expand=Environments&definitionId=$($id)&latestAttemptsOnly=true&api-version=6.0"
$releases = (Invoke-RestMethod -Method Get -Uri $urlreleases -Headers $header -ContentType "applicationType/json").value
if($stgname -icontains "*ProdDeploy*" -or $stgname -icontains "*DeployPROD*" -or $stgname -icontains "*prod*")
{
$releases=$releases|Where-Object{$_.deploymentStatus -ieq "succeeded" -and $_.releaseEnvironment.name -ilike "*prod*" -or $_.releaseEnvironment.name -ilike "*DeployPROD*" -or $_.releaseEnvironment.name -ilike "*ProdDeploy*"  -and $_.startedOn -ge $requiredrange}
}
else
{
$releases=$releases|Where-Object{$_.deploymentStatus -ieq "succeeded" -and $_.releaseEnvironment.name -iin $($stgname) -and $_.startedOn -ge $requiredrange}
}

if($releases -ne $null)
{
$releasetotal=0
$timedifference=0
$uniquereleases=($releases.release.name|Select-Object -Unique).count
$releasetotal=$uniquereleases
$latestreleasestart=$releases[0].startedOn
$earliestreleasestart=$releases[$releases.Length-1].startedOn
$timedifference=(New-TimeSpan -End $latestreleasestart -Start $earliestreleasestart).Days
if($timedifference -eq 0)
{
$timedifference=1
}
foreach($releaseid in $releases)
{
$releasestart=$releaseid.startedOn
$releasemonth=(Get-Culture).DateTimeFormat.GetMonthName(($releasestart -split('-'))[1])
$pipelinename=$releaseid.releaseDefinition.name
$relid=$releaseid.release.id
$Releasestatus=$releaseid.deploymentStatus
$stagename=$releaseid.releaseEnvironment.name
$stageid=$releaseid.releaseEnvironment.id

  #calculate DF per day
  $deploymentsperday=0
  if($releasetotal -gt 0 -and $noofdays -gt 0)
  {
   $deploymentsperday=$timedifference/$releasetotal
  }
  $dailyDeployment=1
  $weeklyDeployment=(1/7)
  $monthlyDeployment=(1/30)
  $everysixmonthDeployment=(1/(6*30))
  $yearlyDeployment=(1/365)
  
  #calculate Maturity
  
  $rating=""
  if($deploymentsperday -eq 0)
  {
   $rating="NA"
  }
 elseif($deploymentsperday -lt $dailyDeployment)
  {
   $rating="Elite"
  }
  elseif($deploymentsperday -ge $dailyDeployment -and $deploymentsperday -gt $weeklyDeployment)
  {
   $rating="High"
  }
  elseif($deploymentsperday -ge $weeklyDeployment -and $deploymentsperday -gt $monthlyDeployment)
  {
   $rating ="Medium"
  }
  elseif($deploymentsperday -ge $monthlyDeployment -and $deploymentsperday -ge $everysixmonthDeployment)
  {
  $rating="Low"
  }
  
  #calculate metric and unit
  
 if($deploymentsperday -gt 0 -and $deploymentsperday -lt 1)
 {
   $displaymetric=[math]::Round($deploymentsperday,2)
 
 }
 else
 {
  $displaymetric=[math]::Round($deploymentsperday,0)
 }
 $displayunit="Days"
 if($releasetotal -gt 0 -and $noofdays -gt 0)
  {
   Write-Output "Deployment frequency of $($pipelinename) for $($stgname)  for release id $($relid) over last $($noofdays) days, is $($displaymetric) $($displayunit), with DORA rating of '$rating'"
  }
  else
  {
   Write-Output "Deployment frequency of $($pipelinename)  for $($stgname)  for release id $($relid) over last $($noofdays) days, is $($displaymetric) $($displayunit), with DORA rating of '$rating'"
  }
  $metrics=@"
{
"DeploymentFrequency_d":$($displaymetric),
"DisplayUnits":"$($displayunit)",
"Rating":"$($rating)",
"ProjectName":"$($project)",
"OrganisationName":"$($org)",
"PipelineName":"$($pipelinename)",
"StageName": "$($stagename)",
"StageID": "$($stageid)",
"Status": "$($Releasestatus)",
"releaseMonth_t":"$($releasemonth)",
"ReleaseTimeWindow":"$($noofdays)"
}
"@
 Post-LogAnalyticsData -customerId $customerId -sharedKey $sharedKey -body ([System.Text.Encoding]::UTF8.GetBytes($metrics)) -logType $logType 
}
}
}
}

