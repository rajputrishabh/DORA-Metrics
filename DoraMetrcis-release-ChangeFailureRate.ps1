param
(
$PAT = "6xjvxhif56xgy5cr2xrsroo2niuuvobfalghrcuimqlmdpglm7ia",
$org = "kantarware",
$project="KT-RIO",
# Replace with your Workspace ID
$CustomerId = "1e8eb880-1f5b-477d-aa77-35c12a9183e1",  
# Replace with your Primary Key
$SharedKey = "PKadb1uaovMMFLV2AJeyvvhxIY9KeORmsPhj98NylDHv5Wkj28FPM2DnHi56kGIX/DRbIrVA5pOPR29T5XOPLw==",     
# Specify the name of the record type that you'll be creating
$LogType = "DoraMetricsCFRRelease",
$noofdays=543,
#stage name for which DORA metrics needs to be calculated
[String[]]$stgnames=('deploy to prod','deploydev','devdeploy','prod')
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
$urlpipelines=$url + "$project/_apis/release/definitions?includeAllProperties=True&api-version=6.0"
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
$expand='$expand'
$urlreleases=$url + "$project/_apis/release/deployments?includeAllProperties=True&$expand=Environments&definitionId=$($id)&latestAttemptsOnly=true&api-version=6.0"
$releases = (Invoke-RestMethod -Method Get -Uri $urlreleases -Headers $header -ContentType "applicationType/json").value

if($stgname -icontains "*ProdDeploy*" -or $stgname -icontains "*DeployPROD*" -or $stgname -icontains "*prod*")
{
$failedreleases=$releases|Where-Object{$_.deploymentStatus -ine "succeeded"  -and $_.releaseEnvironment.name -ilike "*prod*" -or $_.releaseEnvironment.name -ilike "*ProdDeploy*" -or $_.releaseEnvironment.name -ilike "*DeployPROD*"  -and $_.startedOn -gt $requiredrange}
$releases=$releases|Where-Object{$_.releaseEnvironment.name -ilike "*prod*" -or $_.releaseEnvironment.name -ilike "*ProdDeploy*" -or $_.releaseEnvironment.name -ilike "*DeployPROD*"  -and $_.startedOn -gt $requiredrange}
}
else
{
$failedreleases=$releases|Where-Object{$_.deploymentStatus -ine "succeeded"  -and $_.releaseEnvironment.name -iin $($stgname)  -and $_.startedOn -gt $requiredrange}
$releases=$releases|Where-Object{$_.releaseEnvironment.name -iin $($stgname)  -and $_.startedOn -gt $requiredrange}
}

$releasetotal=0
$failureCount=0
$changeFailureRate=0
if($releases -eq $null -and $releasetotal -eq 0)
  {
   $changeFailureRate=-1
  }
else
{
 foreach($failedrelease in $failedreleases)
 {
  $uniquefailedreleases=($failedreleases.release.name|Select-Object -Unique).count
  $failureCount=$uniquefailedreleases
 }
 foreach($releaseid in $releases)
 {
$uniquereleases=($releases.release.name|Select-Object -Unique).count
$releasetotal=$uniquereleases
$releasestart=$releaseid.startedOn
$releasemonth=(Get-Culture).DateTimeFormat.GetMonthName(($releasestart -split('-'))[1])
$pipelinename=$releaseid.releaseDefinition.name
$relid=$releaseid.release.id
$Releasestatus=$releaseid.deploymentStatus
$stagename=$releaseid.releaseEnvironment.name
$stageid=$releaseid.releaseEnvironment.id

  #calculate CFR per day
  
 
  if($releasetotal -gt 0 -and $noofdays -gt 0)
  {
   $changeFailureRate=($failureCount/$releasetotal)*100
  }
  
  #calculate Maturity
  
  $rating=""
  if($changeFailureRate -eq 0)
  {
   $rating="NA"
  }
  elseif($changeFailureRate -le 15)
  {
   $rating="Elite"
  }
  elseif($changeFailureRate -le 30)
  {
   $rating="High"
  }
  elseif($changeFailureRate -lt 46)
  {
   $rating ="Medium"
  }
  elseif($changeFailureRate -ge 46)
  {
  $rating="Low"
  }
  
  #calculate metric and unit
  
  
    if($changeFailureRate -gt 0 -and $changeFailureRate -lt 1)
  {
    $displaymetric=[math]::Round($changeFailureRate,2) 
  
  }
  else
  {
   $displaymetric=[math]::Round($changeFailureRate,0)
  }

    $displayunit="%"
  
  if($releasetotal -gt 0 -and $noofdays -gt 0)
  {
   Write-Output "Change Failure Rate of $($pipelinename) for $($stgname)  for release id $($relid) over last $($noofdays) days, is $($displaymetric) $($displayunit), with DORA rating of '$rating'"
  }
  else
  {
   Write-Output "Change Failure Rate of $($pipelinename) for $($stgname)  for release id $($relid) over last $($noofdays) days, is $($displaymetric) $($displayunit), with DORA rating of '$rating'"
  }
  $metrics=@"
{
"ChangeFailureRate_d":$($displaymetric),
"DisplayUnits":"$($displayunit)",
"Rating":"$($rating)",
"ProjectName":"$($project)",
"OrganisationName":"$($org)",
"PipelineName":"$($pipelinename)",
"SourceBranch":"$($sourcebranch)",
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

