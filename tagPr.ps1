$PSVersionTable
$ErrorActionPreference = "Stop"


$sourceBranch = $(${Env:SYSTEM_PULLREQUEST_SOURCEBRANCH} -split "refs/heads/")[-1]


# We need to checkout the branch in order to compare the differences in files changed from develop branch
Set-Location -Path "${Env:SYSTEM_DEFAULTWORKINGDIRECTORY}/${Env:BUILD_REPOSITORY_NAME}"
git checkout $sourceBranch



Write-Host  "##[debug]🐞`tModifed files are"
git diff origin/develop $sourceBranch --name-only



$myList = @()
git diff origin/develop $sourceBranch --name-only |
    Select-String -Pattern "^bicep/\w+/" -Raw |
        ForEach-Object {
            $thisValue = $_.Split("/")[1]

            if($thisValue -notin $myList) {
                $myList += $thisValue
            }
        }



Write-Host  "##[debug]🐞`tBicep modified folders"
$myList



$myTagList = @()
foreach($item in $myList) {
    # we need to build the Bicep files in order to pull out the template name and version
    Write-Host  "`n##[debug]🐞`tCurrent bicep folder is ${item}"
    Set-Location -Path "${Env:SYSTEM_DEFAULTWORKINGDIRECTORY}/${Env:BUILD_REPOSITORY_NAME}/bicep/${item}"
    az bicep build --file main.bicep

    $myPsObject = Get-Content -Path "main.json" | ConvertFrom-Json
    $myTagList += "$($myPsObject.variables.v_templateName)-v$($myPsObject.variables.v_templateVersion)"
}

Write-Host  "`n##[debug]🐞`tThe tag list is:"
$myTagList



$apiUrl   = "${Env:SYSTEM_TEAMFOUNDATIONSERVERURI}${Env:SYSTEM_TEAMPROJECTID}/_apis/git/repositories/${Env:BUILD_REPOSITORY_NAME}/pullRequests/${Env:SYSTEM_PULLREQUEST_PULLREQUESTID}/labels"
$headers  = @{ Authorization = "Bearer ${Env:SYSTEM_ACCESSTOKEN}" }
Write-Host "API URL = ${apiURL}"



$url      = "${apiUrl}?api-version=7.1-preview.1"
$response = Invoke-RestMethod -uri $url -Method "GET" -Headers $headers
$tagids   = $response.value.id

Write-Host  "`n##[debug]🐞`tTag IDs are:"
$tagids



if($null -ne $tagids) {
    foreach($tagid in $tagids) {
        Write-Host  "`n##[debug]🐞`tDeleting tag id `"${tagid}`""
        $url      = "${apiUrl}/${tagid}?api-version=7.1-preview.1"
        $response = Invoke-RestMethod -uri $url -Method "DELETE" -Headers $headers
    }
}



foreach($tag in $myTagList) {
    Write-Host  "`n##[debug]🐞`tTagging PR with tag `"${tag}`""
    $body    = @{
        name = "${tag}"
    } | ConvertTo-Json

    $url      = "${apiUrl}?api-version=7.1-preview.1"
    $response = Invoke-RestMethod -uri $url -Method "POST" -ContentType "application/json" -Headers $headers -body $body
}
