param
(
$PAT = <Azure DevOps PAT token>,
$org = "<Azure Devops Organisation name,
$project = <Azure DevOps Project name>,
# Replace with your Workspace ID
$CustomerId = <Azure LogAnalytics Workspace ID>,  
# Replace with your Primary Key
$SharedKey = <Azure LogAnalytics Primary Key> ,
  
# Specify the name of the record type that you'll be creating
$LogType = "DoraMetricsLTCRelease",
$noofday=543,
#stage name for which DORA metrics needs to be calculated
[String[]]$stgnames=('deploy to dev','prod','uat')
)
# Optional name of a field that includes the timestamp for the data. If the time field is not specified, Azure Monitor assumes the time is the message ingestion time
$TimeStampField = (Get-Date).DateTime
#calculate LTC per day

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
$urlpipelines=$url + "$project/_apis/release/definitions?includeAllProperties=True&$expand=Artifacts&api-version=6.0"
$pipelines = (Invoke-RestMethod -Method Get -Uri $urlpipelines -Headers $header -ContentType "applicationType/json").value
$pipelines=$pipelines|Where-Object{$_.process.yamlFilename -eq $null}
$requiredrange=(Get-Date).AddDays(-$($noofday))
$requiredrange =$requiredrange.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'")
#multistage run for metrics calculation
foreach($stgname in $stgnames)
{
foreach($pipeline in $pipelines)
{
  $releasetotal=0
  $id=$pipeline.id
  $urlreleases=$url + "$project/_apis/release/deployments?includeAllProperties=True&definitionId=$($id)&latestAttemptsOnly=true&api-version=6.0"
  $releases = (Invoke-RestMethod -Method Get -Uri $urlreleases -Headers $header -ContentType "applicationType/json").value
  if($stgname -icontains "*ProdDeploy*" -or $stgname -icontains "*DeployPROD*" -or $stgname -icontains "*prod*")
  {
    $releases=$releases|Where-Object{$_.deploymentStatus -ieq "succeeded" -and $_.releaseEnvironment.name -ilike "*prod*" -or $_.releaseEnvironment.name -ilike "*DeployPROD*" -or $_.releaseEnvironment.name -ilike "*ProdDeploy*" -and $_.startedOn -ge $requiredrange}

  }
  else
  {
    $releases=$releases|Where-Object{$_.deploymentStatus -ieq "succeeded" -and $_.releaseEnvironment.name -iin $($stgname) -and $_.startedOn -ge $requiredrange}

  }
  if($releases -ne $null)
  {
     $uniquereleases=($releases.release.name|Select-Object -Unique).count
     $releasetotal=$uniquereleases
     $timedifference=0
     foreach($releaseid in $releases)
     {
     $relid=$releaseid.release.id
     $urlrel=$url + "$project/_apis/release/releases/$($relid)?api-version=6.0"
     $releasedetails = (Invoke-RestMethod -Method Get -Uri $urlrel -Headers $header -ContentType "applicationType/json")
     $timedifference+= (New-TimeSpan -Start $releasedetails.createdOn -End $releaseid.completedOn).Days
     $releasemonth=(Get-Culture).DateTimeFormat.GetMonthName(($releaseid.startedOn -split('-'))[1])
     $pipelinename=$releaseid.releaseDefinition.name
     $Releasestatus=$releaseid.deploymentStatus
     $stagename=$releaseid.releaseEnvironment.name
     $stageid=$releaseid.releaseEnvironment.id
  
          if($releasetotal -eq 0)
          {
           $releasetotal=1
          }
          if($timedifference -eq 0)
          {
           $timedifference=1
          }
          $LeadTimeForChangesInDays=($timedifference/$releasetotal)
          $dailyDeployment=1
          $weeklyDeployment=(1/7)
          $monthlyDeployment=(1/30)
          $everysixmonthDeployment=(1/(6*30))
          $yearlyDeployment=(1/365)

          #calculate Maturity

          $rating=""
          if($LeadTimeForChangesInDays -eq 0)
          {
           $rating="NA"
          }
          elseif($LeadTimeForChangesInDays -lt $dailyDeployment)
          {
           $rating="Elite"
          }
          elseif($LeadTimeForChangesInDays -ge  $dailyDeployment -and $LeadTimeForChangesInDays -gt $weeklyDeployment)
          {
           $rating="High"
          }
          elseif($LeadTimeForChangesInDays -ge $weeklyDeployment -and $LeadTimeForChangesInDays -gt $monthlyDeployment)
          {
           $rating ="Medium"
          }
          elseif($LeadTimeForChangesInDays -ge $monthlyDeployment -and $LeadTimeForChangesInDays -ge $everysixmonthDeployment)
          {
          $rating="Low"
          }
          
          #calculate metric and unit
          
             if($LeadTimeForChangesInDays -gt 0 -and $LeadTimeForChangesInDays -lt 1)
          {
            $displaymetric=[math]::Round($LeadTimeForChangesInDays,2) 
          
          }
          else
          {
           $displaymetric=[math]::Round($LeadTimeForChangesInDays,0)
          }
            $displayunit="Days"
    
         if($LeadTimeForChangesInDays -gt 0)
          {
           Write-Output "Lead Time for changes for $($pipelinename) for $($stgname) for release id $($relid) average over last $($noofday) days is $($displaymetric) $($displayunit),with a DORA rating of $($rating)"
          }
          else
          {
           Write-Output "Lead time for changes for $($pipelinename) for $($stgname) for release id $($relid) average over last $($noofday) days ,is $($displaymetric) $($displayunit), with DORA rating of '$rating'"
          }
          
          $metrics=@"
          {
          "LeadTimeToChange_d":$($displaymetric),
          "DisplayUnits":"$($displayunit)",
          "Rating":"$($rating)",
          "ProjectName":"$($project)",
          "OrganisationName":"$($org)",
          "PipelineName":"$($pipelinename)",
          "releaseId_s":"$($relid)",
          "StageName":"$($stagename)",
          "StageResult":"$($Releasestatus)",
          "releaseMonth_t":"$($releasemonth)",
          "ReleaseTimeWindow":"$($noofdays)"
          }
"@
          
        Post-LogAnalyticsData -customerId $customerId -sharedKey $sharedKey -body ([System.Text.Encoding]::UTF8.GetBytes($metrics)) -logType $logType 
        }
      
 }
 }
}
   
