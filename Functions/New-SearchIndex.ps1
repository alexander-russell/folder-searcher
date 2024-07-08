<#
.SYNOPSIS
Create search index for selected Path

.DESCRIPTION
Asynchronously crawls the selected Path and generates a Relevance score for each item, both files and 
directories, based on a variety of criteria described below. Saves the resulting file index in the Data 
subfolder in the FolderSearcher module root folder.

.PARAMETER Path
Parameter description

.EXAMPLE
New-SearchIndex C:\Users\<user>\Desktop

.NOTES
The function validates settings and then starts a ThreadJob to run the actual indexing operation. 
Progress of this can be checked with Get-Job -Name SearchIndexCrawl. The command stops existing 
SearchIndexCrawl jobs before starting a new one. Therefore, calling this function again before the 
operation is completed will restart from scratch.

The items found by the function are sorted by a relevance score, which is the linear combination of 
several scores, the Ranking Criteria below. The name is followed by the range of the score after 
scaling.

Ranking Criteria:
- DepthScore [~-20..0]: Indicates the depth of the item within the root Path, calculated by the number of backslashes in the file path. 
  - Implemented relative to the depth of the root Path, and files within 2 layers of the root Path are not penalised (DepthScore=0)
- TypeScore [-1,1,0]: Penalises files of type .bin, rewards files of types [.txt, .docx, .pdf]. Zero for all others
- RecencyScore [0..1]: Rewards recently written to files, with a fast drop off rate. 1 if written today, 0.2 for 5 days old
- WriteGapScore [-1,0]: excludes pdf and files less than 3 days old
- NameScore [-1,0,1,2]: Rewards filenames without spaces and penalises ones with them. Rewards files that begin with an ISO formatted daye (yyyy-MM-dd), no penalty if not. 
- SiblingCount [-1..0]: Based on how many items share the same parent folder. No penalty between 5 and 25 children. Up to penalty of -1 for no siblings or beyond 124 siblings. Piecewise non-linear, see distribution in Images/SiblingScoreFunction.png
- LookupCountScore [0..5]: How many times item has been looked up, capped at 5.



#>
function New-SearchIndex {
    param (
        $Path
    )
    #Set paths
    $ModulePath = $MyInvocation.MyCommand.Module.ModuleBase
    $DataPath = "$ModulePath\data"

    #Validate parameter
    if (![System.IO.Directory]::Exists($Path)) {
        Write-Error "Bad path: $Path"
        return
    }

    #If crawl already in progress, cancel it
    $ExistingJob = Get-Job -Name "SearchIndexCrawl" -ErrorAction SilentlyContinue
    if ($ExistingJob) {
        Stop-Job $ExistingJob
    }

    #Start new crawl, always asynchronously
    Start-ThreadJob -Name "SearchIndexCrawl" -ArgumentList @($Path, $DataPath) -ScriptBlock {
        param (
            $Path, 
            $DataPath
        )

        #Set paths
        Push-Location $DataPath

        #Read additional data
        if (![System.IO.File]::Exists("$DataPath\LookupCount.csv")) {
            [System.IO.File]::Create("$DataPath\LookupCount.csv").Close()
        }
        $LookupCountData = Import-Csv "LookupCount.csv"

        #Calculate depth of root Path, to standardise depth scores
        $RootPathDepth = $Path.Split('\').Count

        #Get all files and directories
        $Items = Get-ChildItem -Path $Path -Recurse

        #Iterate through items, calculate score and assign to variable ItemsScored
        $ItemsScored = foreach ($Item in $Items) {
            #Calculate depth score
            $Depth = [Math]::Max($Item.FullName.Split("\").Count - ($RootPathDepth + 2), 0)
            $DepthScoreRaw = 1 - [Math]::Pow($Depth, [Math]::e)
            $DepthScore = $DepthScoreRaw / 1600

            #Calculate type score
            $TypeScore = $Item.Extension -in @(".bin") ?  -1 : $Item.Extension -in @(".txt", ".docx", ".pdf") ? 1 : 0

            #Calculate recency score
            $RecencyScore = [Math]::Min(1 / ([datetime]::Now - $Item.LastWriteTime).TotalDays, 1)

            #Calculate gap between creation and write
            $WriteGapScore = ($Item.LastWriteTime - $Item.CreationTime).TotalDays -lt 1 -and $Item.CreationTime -lt [datetime]::Now.AddDays(-3) -and $Item.Extension -ne ".pdf" ? -1 : 0

            #Calculate name score (points for nospaces, starting with ISO Reverse Date)
            $NameScore = 0
            $NameScore += ($Item.Name.IndexOf(" ") -eq -1) ? 1 : -1
            $NameScore += ($Item.Name.Substring(0, [Math]::Min(10, $Item.Name.Length)) -match "\d{4}-\d{2}-\d{2}") ? 1 : 0

            #Calculate sibling count (Non-linear piecewise. From 1-5: linear from -1 to 0, from 5-25: linear 0, from 25-124: decreasing at increasing rate, from >125: -1)
            $SiblingCount = [System.IO.Directory]::GetFiles($Item.FullName.Substring(0, $Item.FullName.LastIndexOf("\")).Trim()).Count
            $SiblingLower = 5
            $SiblingUpper = 25
            $SiblingScore = ($SiblingCount -lt $SiblingLower) ? ($SiblingCount - $SiblingLower) / ($SiblingLower - 1) : ($SiblingCount -gt $SiblingUpper) ? [Math]::Max( - [Math]::Pow((($SiblingCount - $SiblingUpper) / (4 * $SiblingUpper)), 2), -1) : 0

            #Calculate selected count score
            $LookupCountIndex = $LookupCountData.FullName.IndexOf($Item.FullName)
            $LookupCountScore = $LookupCountIndex -ne -1 ? [Math]::Min($LookupCountData[$LookupCountIndex].Count, 5) : 0

            #Put together into relevance score
            $RelevanceScore = $DepthScore * 10 + $TypeScore + $RecencyScore + $WriteGapScore + $SiblingScore + $LookupCountScore

            #Assemble object and collect in $ItemsScored
            [pscustomobject]@{
                FullName       = $Item.FullName
                Name           = $Item.Name
                Folder         = $Item.PSIsContainer
                RelevanceScore = $RelevanceScore
                #Include a placeholder to be calculated at search time
                FinalScore     = -1
            }
        }

        #Sort
        $ItemsSorted = $ItemsScored | Sort-Object RelevanceScore -Descending

        #Write to file
        $ItemsSorted | Export-Csv "Index.csv"

        #Record most recent crawl
        [datetime]::Now.ToString("yyyy-MM-dd") | Out-File IndexLastCrawlDate.txt

        Pop-Location
    } | Out-Null
}