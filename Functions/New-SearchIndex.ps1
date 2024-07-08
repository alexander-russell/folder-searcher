function New-SearchIndex {
    param (
        $Path = "C:\Users\alexa\Desktop"
    )
    #Set paths
    $ModulePath = $MyInvocation.MyCommand.Module.ModuleBase
    $DataPath = "$ModulePath\data"
    
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

        #Get all files and directories
        $Items = Get-ChildItem -Path $Path -Recurse

        #Iterate through items, calculate score and assign to variable ItemsScored
        $ItemsScored = foreach ($Item in $Items) {
            #Calculate depth score
            $Depth = [Math]::Max($Item.FullName.Split("\").Count - 6, 0)
            $DepthScoreRaw = 1 - [Math]::Pow($Depth, [Math]::e)
            $DepthScore = $DepthScoreRaw / 1600

            #Calculate type score
            $TypeScore = $Item.Extension -in @(".bin") ?  -1 : $Item.Extension -in @(".txt", ".docx", ".pdf") ? 1 : 0

            #Calculate recency score
            $TicksPerDay = 1e7 * 60 * 60 * 24
            $RecencyScore = [Math]::Min(1 / (([datetime]::Now.Ticks / $TicksPerDay) - ($Item.LastWriteTime.Ticks / $TicksPerDay)), 1)

            #Calculate gap between creation and write
            $WriteGapScore = ($Item.LastWriteTime - $Item.CreationTime).TotalDays -lt 1 -and $Item.CreationTime -lt [datetime]::Now.AddDays(-3) -and $Item.Extension -ne ".pdf" ? -1 : 0

            #Calculate name score (points for nospaces, starting with ISO Reverse Date)
            $NameScore = 0
            $NameScore += ($Item.Name.IndexOf(" ") -eq -1) ? 1 : -1
            $NameScore += ($Item.Name.Substring(0, [Math]::Min(10, $Item.Name.Length)) -match "\d{4}-\d{2}-\d{2}") ? 1 : 0

            #Calculate sibling count
            $SiblingCount = [System.IO.Directory]::GetFiles($Item.FullName.Substring(0, $Item.FullName.LastIndexOf("\")).Trim()).Count
            $SiblingLower = 5
            $SiblingUpper = 25
            $SiblingScore = ($SiblingCount -lt $SiblingLower) ? ($SiblingCount - $SiblingLower) / ($SiblingLower - 1) : ($SiblingCount -gt $SiblingUpper) ? [Math]::Max( - [Math]::Pow((($SiblingCount - $SiblingUpper) / (4 * $SiblingUpper)), 2), -1) : 0

            #Calculate selected count score
            $LookupCountIndex = $LookupCountData.FullName.IndexOf($Item.FullName)
            $SelectedScore = $LookupCountIndex -ne -1 ? [Math]::Min($LookupCountData[$LookupCountIndex].Count, 5) : 0

            #Put together into relevance score
            $RelevanceScore = $DepthScore * 10 + $TypeScore + $RecencyScore + $WriteGapScore + $SelectedScore + $SiblingScore

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