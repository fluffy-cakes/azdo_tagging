$PSVersionTable
$ErrorActionPreference = "Stop"

$branch  = $Env:BUILD_SOURCEBRANCHNAME
$headers = @{
    "Authorization" = "Bearer ${Env:SYSTEM_ACCESSTOKEN}"
    "Content-Type"  = "application/json"
}


# get list of commits
$url        = "${Env:SYSTEM_TEAMFOUNDATIONSERVERURI}${Env:SYSTEM_TEAMPROJECTID}/_apis/git/repositories/${Env:BUILD_REPOSITORY_NAME}/commits?searchCriteria.itemVersion.version=${branch}&api-version=7.1-preview.1"
$response   = Invoke-RestMethod -Uri $url -Method "GET" -Headers $headers
$lastCommit = $response.value[0].commitId
$pattern    = ($response.value[0].comment | Select-String -Pattern "^Merged PR \d+").Matches.Value


if(-not $pattern) {
    $prNotMergeBruv = "🤯 Last push was NOT a PR"
    throw $prNotMergeBruv
} else {
    $thisPr = ($pattern | Select-String -Pattern "\d+").Matches.Value
}


# get PR info
$url          = "${Env:SYSTEM_TEAMFOUNDATIONSERVERURI}${Env:SYSTEM_TEAMPROJECTID}/_apis/git/pullrequests/${thisPr}?api-version=7.1-preview.1"
$response     = Invoke-RestMethod -Uri $url -Method "GET" -Headers $headers
$lastPrCommit = $response.lastMergeCommit.commitId
$prUrl        = "$($response.repository.webUrl)/pullrequest/${thisPr}"
$sourceBranch = $response.sourceRefName


if($lastCommit -ne $lastPrCommit) {
    Write-Host "Last PR commit ID            : ${lastPrCommit}"
    Write-Host "Last Develop branch commit ID: ${lastCommit}"
    $commitValuesDifferBruv = "🤯 Commit values are different!"
    throw $commitValuesDifferBruv
}


if($branch -eq "develop") {

    # get labels from the PR
    $url        = "${Env:SYSTEM_TEAMFOUNDATIONSERVERURI}${Env:SYSTEM_TEAMPROJECTID}/_apis/git/repositories/${Env:BUILD_REPOSITORY_NAME}/pullRequests/${thisPr}/labels?api-version=7.1-preview.1"
    $response   = Invoke-RestMethod -Uri $url -Method "GET" -Headers $headers
    $listOfTags = @($response.value.name)


    # tag commits
    foreach($tag in $listOfTags) {
        if($null -eq $tag) { continue }

        # check if there isn't already a tag
        $url      = "${Env:SYSTEM_TEAMFOUNDATIONSERVERURI}${Env:SYSTEM_TEAMPROJECTID}/_apis/git/repositories/${Env:BUILD_REPOSITORY_NAME}/refs?filter=tags/&api-version=7.1-preview.1"
        $response = Invoke-RestMethod -Uri $url -Method "GET" -Headers $headers
        $objectId = $response.value |
            Where-Object {
                $_.name -eq "refs/tags/${tag}"
            } |
                Select-Object -ExpandProperty "objectId"


        if($objectId) {
            Write-Host "##[warning]❗ There's already tag named `"${tag}`""
            Write-Host "##vso[task.complete result=SucceededWithIssues;]Tag already exists"

            $url                = "${Env:SYSTEM_TEAMFOUNDATIONSERVERURI}${Env:SYSTEM_TEAMPROJECTID}/_apis/git/repositories/${Env:BUILD_REPOSITORY_NAME}/annotatedtags/${objectId}?api-version=7.1-preview.1"
            $response           = Invoke-RestMethod -Uri $url -Method "GET" -Headers $headers
            $currentTagCommitId = $response.taggedObject.objectId

            if($lastPrCommit -eq $currentTagCommitId) {
                Write-Host "##[warning]❗ ${lastPrCommit} already tagged with `"${tag}`""
                Write-Host "##vso[task.complete result=SucceededWithIssues;]Tag already exists"
            }

            continue
        }


        $body            = [PSObject]@{
            name         = $tag
            taggedObject = [PSObject]@{
                objectId = $lastPrCommit
            }
            message      = $tag
        } | ConvertTo-Json

        Write-Host "`n`n##[section] 🏷️ ${Env:BUILD_REPOSITORY_NAME} 👉 ${tag} 📎 ${lastPrCommit}"
        $url      = "${Env:SYSTEM_TEAMFOUNDATIONSERVERURI}${Env:SYSTEM_TEAMPROJECTID}/_apis/git/repositories/${Env:BUILD_REPOSITORY_NAME}/annotatedtags?api-version=7.1-preview.1"
        Invoke-RestMethod -Uri $url -Method "POST" -Headers $headers -Body $body
    }
}


if($branch -eq "main") {
    $version = $sourceBranch.Split("/")[-1]
    $tag     = "release-${version}"

    if($version -notmatch "v\d+\.\d+\.\d+") {
        $versionErrorBruv = "🤯 Version number does not match regex pattern"
        throw $versionErrorBruv
    }


    # check if there isn't already a tag
    $url      = "${Env:SYSTEM_TEAMFOUNDATIONSERVERURI}${Env:SYSTEM_TEAMPROJECTID}/_apis/git/repositories/${Env:BUILD_REPOSITORY_NAME}/refs?filter=tags&api-version=7.1-preview.1"
    $response = Invoke-RestMethod -Uri $url -Method "GET" -Headers $headers

    $objectId = $response.value |
        Where-Object {
            $_.name -eq "refs/tags/${tag}"
        }

    $latestTag = $response.value |
        Where-Object {
            $_.name -eq "refs/tags/latest"
        }


    if($objectId) {
        Write-Host "##[error]❗ There's already tag named `"${tag}`""
        Write-Host "##vso[task.complete result=Failed;]Tag already exists"
        exit 1
    }
    else {
        # remove LATEST tag from old commit and apply on new commit
        Write-Host "`n`n##[section] 🏷️ ${Env:BUILD_REPOSITORY_NAME} 👉 'latest' ❌ $($latestTag.objectId)"

        if($latestTag) {
            $body = @(
                @{
                    "name"        = "refs/tags/latest"
                    "newObjectId" = "0000000000000000000000000000000000000000"
                    "oldObjectId" = $latestTag.objectId
                }
            ) | ConvertTo-Json -AsArray

            $url      = "${Env:SYSTEM_TEAMFOUNDATIONSERVERURI}${Env:SYSTEM_TEAMPROJECTID}/_apis/git/repositories/${Env:BUILD_REPOSITORY_NAME}/refs?api-version=7.1-preview.1"
            Invoke-RestMethod -Uri $url -Method "POST" -Headers $headers -Body $body |
                ConvertTo-Json -Depth 99
        }


        # Apply new tags
        $body            = [PSObject]@{
            name         = "latest"
            taggedObject = [PSObject]@{
                objectId = $lastPrCommit
            }
            message      = $prUrl
        } | ConvertTo-Json

        Write-Host "`n`n##[section] 🏷️ ${Env:BUILD_REPOSITORY_NAME} 👉 'latest' 📎 ${lastPrCommit}"
        $url      = "${Env:SYSTEM_TEAMFOUNDATIONSERVERURI}${Env:SYSTEM_TEAMPROJECTID}/_apis/git/repositories/${Env:BUILD_REPOSITORY_NAME}/annotatedtags?api-version=7.1-preview.1"
        Invoke-RestMethod -Uri $url -Method "POST" -Headers $headers -Body $body |
            ConvertTo-Json -Depth 99


        $body            = [PSObject]@{
            name         = $tag
            taggedObject = [PSObject]@{
                objectId = $lastPrCommit
            }
            message      = $prUrl
        } | ConvertTo-Json

        Write-Host "`n`n##[section] 🏷️ ${Env:BUILD_REPOSITORY_NAME} 👉 ${tag} 📎 ${lastPrCommit}"
        $url      = "${Env:SYSTEM_TEAMFOUNDATIONSERVERURI}${Env:SYSTEM_TEAMPROJECTID}/_apis/git/repositories/${Env:BUILD_REPOSITORY_NAME}/annotatedtags?api-version=7.1-preview.1"
        Invoke-RestMethod -Uri $url -Method "POST" -Headers $headers -Body $body |
            ConvertTo-Json -Depth 99
    }
}
