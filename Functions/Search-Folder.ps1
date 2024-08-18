<#
.SYNOPSIS
Search through Path using a query string

.DESCRIPTION
An interactive dialogue that presents all the items contained in the index for a chosen directory that match the inputted Query. For detail on interactive usage, run Get-Help Search-Folder -Full.

.PARAMETER QueryContent
Optional parameter to initialise the program with a query. It can be edited during runtime

.PARAMETER Path
The folder to 

.EXAMPLE
Search-Folder
Search-Folder "my query"
#See Notes for description of interactive usage

.NOTES
General:
- The program is primarily interactive, usage is mostly not on the command line.
- To select the directory to use, modify the Path property of the Config.json file in the Data subfolder of the module root directory.

Modes:
- During operation, the program operates in 4 modes, each with designated keybindings and purposes:
  1. Insert: Modify search query and use search history.
  2. Select: Navigate results and configure search settings.
  3. Command: Enter specific commands, notably the RebuildIndex command among others.
  4. Sleep: Reduces response rate to ~1 second. Enabled after inactivity, reverts to Select mode on any keypress.

Insert Mode:
- As noted below, this is entered by typing 'I' while in Select Mode.
- Left/Right Arrow: Move cursor across query. Hold Ctrl to move by word.
- Up/Down Arrow: Use recent queries from Search History (a search is only added if used to open a resource).
- Backspace: Delete a character from query at position of cursor. Hold Ctrl to delete a word.
- Enter/Esc: Exit Insert Mode to Select Mode.
- Any character in $Query.AllowedCharacters: Add character to query at position of cursor.

Select Mode:
- 'I': Enter Insert Mode
- ':': Enter Command Mode
- 'Q': Quit the program
- Enter: Open the selected item. Hold Shift to open the selected item's parent. Hold Ctrl to keep search dialogue open. Hold both to do both!
- C: Copy the path to the selected item. Hold Shift to copy the path to the selected item's parent.
- Up/Down: Navigate through listed search results. If more results available, the list will scroll as you reach the bound.
- F: (FullName) Toggle display of the relative path (to main Path) to each listed result.
- P: (Parent) Toggle display of just the parent folder for each listed result. This is displayed automatically in the case of name clashes.
- A: (All) Toggle uncapped results length. Normally, the results job stops when it has 50, this setting ensures it finds every resource matching the query.
- D: (Directory) Toggle filtering results to only include folders.
- R: (Regex) Toggle using regex to match query. Default is a simple .contains($Query) check.

Command Mode:
- As noted above, this is opened by typing ':' while in Select Mode.
- Enter: Run the inputted command
- Backspace: Remove a character from the end of the inputted command
- Tab/Right Arrow: Use autocomplete command suggestion (It will be used when command is run regardless, but this allows you to shortcut to adding arguments)
- Any character in $Query.AllowedCharacters: Add character to command at position of cursor. (Ibid, I reused the list from $Query)

Using Commands:
- The syntax of any command is <CommandName> [<ArgName>=<ArgVal> ]*, where CommandName is PascalCase with no spaces, and commands take any number of arguments including 0.

Available Commands:
- RebuildIndex: Manually requests a new search crawl. Note that this will otherwise be triggered on the first use of Search-Folder each day.
- ToggleIncognito: Toggles whether to register search history. If incognito is on, it will display in status and searches will not be saved.
#>
function Search-Folder {
    param (
        [string]$QueryContent = ""
    )

    #########################################################################################################################################
    ################################################################ SETUP ##################################################################
    #########################################################################################################################################
    #Set paths
    $ModulePath = $MyInvocation.MyCommand.Module.ModuleBase
    $DataPath = "$ModulePath\data"
    $LogPath = "$DataPath\DebugLog.txt"
    $SearchHistoryPath = "$DataPath\SearchHistory.csv"
    $LookupCountPath = "$DataPath\LookupCount.csv"
    $IndexPath = "$DataPath\Index.csv"

    #Read config file
    if (![System.IO.File]::Exists("$DataPath\Config.json")) {
        [PSCustomObject]@{
            Path = "PATH_TO_YOUR_FOLDER"
        } | ConvertTo-Json | Out-File "$DataPath\Config.json"
    }
    $Config = Get-Content "$DataPath\Config.json" | ConvertFrom-Json

    #Determine search location
    if (!$PSBoundParameters.Keys.Contains("Path")) {
        if (!$Config.Path -or !(Test-Path $Config.Path)) {
            Write-Error "You need to set a valid path. `nOpen '$DataPath\Config.json' and edit the 'Path' property. `nSet it to the path to the folder you want to use this module to search through. If your path includes backslashes, escape them (I.e. instead of '\' write '\\')"
            return
        }
        $Path = $Config.Path
    }
    

    #Initialise keypress and mode
    $KeyPress = $null
    $Mode = "Select"    
    
    #Create container to store and track index results (loaded asynchronously below)
    $Index = [PSCustomObject]@{
        Data         = $null
        Job          = $null
        Loaded       = $false
        LoadActioned = $false
    }
    
    #Load search history
    if (![System.IO.File]::Exists($SearchHistoryPath)) {
        [System.IO.File]::Create($SearchHistoryPath).Close()
    }
    $SearchHistory = [pscustomobject]@{
        Data         = Import-Csv $SearchHistoryPath
        Cursor       = 0
        StashedQuery = ""
        Incognito    = $false
    }
    #Reverse records and initialise cursor (0 means most recent search)
    [array]::Reverse($SearchHistory.Data)
    $SearchHistory.Cursor = -1 #$SearchHistory.Data.Count
    
    #Load lookup count
    if (![System.IO.File]::Exists($LookupCountPath)) {
        [System.IO.File]::Create($LookupCountPath).Close()
    }
    $LookupCount = [pscustomobject]@{
        Data   = Import-Csv $LookupCountPath
        Cursor = 0
    }

    #Initialise results variable to store the results themselves and state variables
    $Results = [PSCustomObject]@{
        Data         = $null
        Job          = $null
        Cursor       = 0
        RefreshData  = $true
        Loaded       = $false
        LoadActioned = $false
        UseAll       = $false
        UseRegex     = $false
        RegexInvalid = $false
    }

    #Initialise timekeeping variable
    $Timekeeping = [pscustomobject]@{
        TimeToSleep         = 60 #Seconds
        TimeToShutdown      = 600 #Seconds
        SleepLength         = 1 #Seconds
        FrameInterval       = 20 #Milliseconds
        FrameCount          = 0
        Start               = [datetime]::Now
        End                 = $null
        Duration            = $null
        LastRun             = [datetime]::Now.AddMilliseconds(-$FrameInteral)
        LastKeyPress        = [datetime]::Now
        LastCopyPath        = $null
        LastCopyParentPath  = $null
        LastOpenInvalidItem = $null
        LastOpenNullItem    = $null
    }

    #Initialise variable to store information about display configuration and what needs updating
    $Display = [pscustomobject]@{
        RedrawTitle     = $true
        RedrawList      = $true
        RedrawStatus    = $true
        RedrawCommand   = $false
        RedrawEnd       = $false
        ListCountMax    = 10
        ListCount       = 10
        ListStart       = 0
        ListEnd         = 0
        ShowFullName    = $false
        ShowParent      = $false
        SearchBarString = "Search: "
        Position        = [PSCustomObject]@{
            MaxY    = 0
            Start   = $Host.UI.RawUI.CursorPosition
            Title   = [System.Management.Automation.Host.Coordinates]::new($Host.UI.RawUI.CursorPosition.X, $Host.UI.RawUI.CursorPosition.Y + 1)
            List    = [System.Management.Automation.Host.Coordinates]::new($Host.UI.RawUI.CursorPosition.X, $Host.UI.RawUI.CursorPosition.Y + 2)
            Sleep   = [System.Management.Automation.Host.Coordinates]::new($Host.UI.RawUI.CursorPosition.X, $Host.UI.RawUI.CursorPosition.Y + 2)
            Status  = $null
            Command = $null
            End     = $null
        }
    }

    #Initialise query object, use querycontent and set cursor to end of string
    $Query = [pscustomobject]@{
        Content           = $QueryContent
        AllowedCharacters = "[a-z\d!-_;{} ]"
        Cursor            = $QueryContent.Length
    }

    #Initialise command object to store commands passed from keypresses and direct from user
    $Command = [pscustomobject]@{
        Manual = ""
        Raw    = ""
        Ready  = $false
        Name   = $null
        Args   = $null
    }


    #Clear log
    $null | Out-File $LogPath

    #Hide cursor
    [Console]::CursorVisible = $false

    #Start asynchronous load of Index data
    $Index.Job = Start-ThreadJob -Name "LoadIndex" -ArgumentList @($Index) {
        param (
            $Index
        )
        if (![System.IO.File]::Exists($using:IndexPath)) {
            Write-Log -Message "CreatingNewBlankIndex" -Path $using:LogPath
            [System.IO.File]::Create($using:IndexPath).Close()
        }
        $Index.Data = Import-Csv $using:IndexPath
        $Index.Loaded = $true
    }

    #If index is out of date, asyncrhonously create a new one
    if ([System.IO.File]::Exists("$DataPath\IndexLastCrawlDate.txt")) {
        $LastCrawlDate = Get-Content "$DataPath\IndexLastCrawlDate.txt"
    }
    if ($LastCrawlDate -ne [DateTime]::Now.ToString("yyyy-MM-dd")) {
        New-SearchIndex -Path $Path
    }

    #If no query provided, start in insert mode
    if (!$PSBoundParameters.ContainsKey("QueryContent")) {
        Write-Log "Setup: NoQuery: StartInInsertMode" -Path $LogPath
        $Mode = "Insert"
    }

    #########################################################################################################################################
    ############################################################# INTERACTIVE ###############################################################
    #########################################################################################################################################
    Write-Log "Setup: EnteringLoop" -Path $LogPath
    while ($Mode -ne "Exit") {
        #########################################################################################################################################
        ############################################################### FRAMERATE ###############################################################
        #########################################################################################################################################
        # #Manage framerate with calculated delays
        $Timekeeping.FrameCount += 1
        $TimeSinceLastRun = ([datetime]::Now - $Timekeeping.LastRun).TotalMilliseconds
        if ($TimeSinceLastRun -lt $Timekeeping.FrameInterval) {
            [System.Threading.Thread]::Sleep($Timekeeping.FrameInterval - $TimeSinceLastRun)
        }
        $Timekeeping.LastRun = [datetime]::Now

        #########################################################################################################################################
        ################################################################ TIMEOUT ################################################################
        #########################################################################################################################################
        #After a short period of inactivity, sleep
        $InActiveUse = [datetime]::Now.AddSeconds(-$Timekeeping.TimeToSleep) - $Timekeeping.LastKeyPress -lt 0
        if (!$InActiveUse -and $Mode -ne "Sleep") {
            Write-Log "Timeout: Sleep: EnablingSleep" -Path $LogPath
            $Mode = "Sleep"
        }

        #Manage sleep activities
        if ($Mode -eq "Sleep") {
            #Wake up
            if ($InActiveUse) {
                Write-Log "Timeout: Sleep: DisablingSleep" -Path $LogPath
                $Mode = "Select"
                $Display.RedrawTitle = $true
                $Display.RedrawList = $true
            }
            #Suspend execution for 1 second (a while given this loop runs  ~8000 times per second)
            else {
                Start-Sleep -Seconds $Timekeeping.SleepLength
            }
        }

        #After a long period of inactivity, shutdown
        if ([datetime]::Now.AddSeconds(-$Timekeeping.TimeToShutdown) - $Timekeeping.LastKeyPress -gt 0) {
            Write-Log "Timeout: Shutdown: ShuttingDown" -Path $LogPath
            $Mode = "Exit"
        }
        #########################################################################################################################################
        ############################################################### KEYPRESS ################################################################
        #########################################################################################################################################
        if ([Console]::KeyAvailable) {
            $KeyPress = [Console]::ReadKey($true)
            $Timekeeping.LastKeyPress = [datetime]::Now
            Write-Log "KeyPress: Key=$($KeyPress.Key); KeyChar=$($KeyPress.KeyChar)" -Path $LogPath

            #Insert mode to modify search query, hopefully live updating results
            if ($Mode -eq "Insert") {
                #Remove chars from query on backspace
                if ($KeyPress.Key -eq "Backspace") {
                    #If Ctrl+Backspace, delete a whole word
                    if ($KeyPress.Modifiers -band [ConsoleModifiers]::Control) {
                        $NewCursor = [Math]::Max($Query.Content.Substring(0, $Query.Cursor).LastIndexOf(" "), 0)
                        $Query.Content = $Query.Content.Substring(0, $NewCursor) + $Query.Content.Substring($Query.Cursor)
                        $Query.Cursor = $NewCursor
                        $Display.RedrawTitle = $true
                        $Results.RefreshData = $true
                    }
                    #Otherwise, just remove a letter
                    else {
                        if ($Query.Cursor -gt 0) {
                            #Remove character and update cursor
                            $Query.Content = $Query.Content.Remove($Query.Cursor - 1, 1)
                            $Query.Cursor--

                            #Signal redraw of title and request new data
                            $Display.RedrawTitle = $true
                            $Results.RefreshData = $true
                        }
                    }
                }
                #Exit insert mode
                elseif ($KeyPress.Key -in @("Enter", "Escape")) {
                    Write-Log "KeyPress: Insert: Exiting: CurrentQuery=$($Query.Content);" -Path $LogPath
                    #Set new mode and signal redraw of title
                    $Mode = "Select"
                    $Display.RedrawTitle = $true
                }
                #Navigate search history
                elseif ($KeyPress.Key -in @("UpArrow", "DownArrow")) {
                    #Save current query, if not already using searchhistory
                    if ($SearchHistory.Cursor -eq -1) {
                        #$SearchHistory.Data.Count) {
                        $SearchHistory.StashedQuery = $Query.Content
                    }

                    #Increment/decrement index
                    if ($KeyPress.Key -eq "UpArrow") {
                        #If index not initialised, start it at the end
                        if ($SearchHistory.Cursor -eq -1 ) {
                            #$SearchHistory.Data.Count) {
                            $SearchHistory.Cursor = 0 #$SearchHistory.Data.Count - 1
                        }
                        else {
                            $SearchHistory.Cursor++ #--
                        }
                    }
                    elseif ($KeyPress.Key -eq "DownArrow") {
                        #If index not initialised, do nothing. Must initialise with UpArrow
                        if ($SearchHistory.Cursor -ne -1) {
                            #$SearchHistory.Data.Count) {
                            $SearchHistory.Cursor-- #++
                        }
                    }
                    
                    #Bounds check index
                    # $SearchHistory.Cursor = [Math]::Min([Math]::Max($SearchHistory.Cursor, 0), $SearchHistory.Data.Count)
                    $SearchHistory.Cursor = [Math]::Min([Math]::Max($SearchHistory.Cursor, -1), $SearchHistory.Data.Count - 1)

                    #If exiting SearchHistory, use stashed query from before entering SearchHistory
                    if ($SearchHistory.Cursor -eq -1) {
                        #$SearchHistory.Data.Count) {
                        $Query.Content = $SearchHistory.StashedQuery
                    }
                    #Otherwise Use SearchHistory item as query
                    else {
                        $Query.Content = $SearchHistory.Data[$SearchHistory.Cursor].Query
                    }

                    #Update insertcursor to end of new query
                    $Query.Cursor = $Query.Content.Length
    
                    #Signal redraw of title and request new data
                    $Display.RedrawTitle = $true
                    $Results.RefreshData = $true
                }
                #Move query cursor
                elseif ($KeyPress.Key -in @("LeftArrow", "RightArrow")) {
                    #If Ctrl+Arrow, move by a whole word
                    if ($KeyPress.Modifiers -band [ConsoleModifiers]::Control) {
                        if ($KeyPress.Key -eq "LeftArrow") {
                            #Adjust +1 so that cursor lands on the char after the space, adjust -1 so that lastindexof ignored the space it sits directly after
                            $Query.Cursor = $Query.Content.Substring(0, [Math]::Max($Query.Cursor - 1, 0)).LastIndexOf(" ") + 1
                        }
                        else {
                            #Calculate index of first space in the substring after the cursor, move cursor to following char or to end if none found
                            $CursorOffset = $Query.Content.Substring($Query.Cursor).IndexOf(" ")
                            $Query.Cursor = $CursorOffset -eq -1 ? $Query.Content.Length : $Query.Cursor + $CursorOffset + 1
                        }
                    }
                    else {
                        #Otherwise just move by 1 char
                        if ($KeyPress.Key -eq "LeftArrow") {
                            $Query.Cursor--
                        }
                        else {
                            $Query.Cursor++
                        }
                    }

                    #Bounds checking (more inbuilt above)
                    $Query.Cursor = [Math]::Max([Math]::Min($Query.Cursor, $Query.Content.Length), 0)

                    #Signal title redraw
                    $Display.RedrawTitle = $true
                }
                #If character is an allowed key, add this character to query
                elseif ($KeyPress.KeyChar -match $Query.AllowedCharacters) {
                    $Query.Content = $Query.Content.Insert($Query.Cursor, $KeyPress.KeyChar)
                    $Query.Cursor += 1
                
                    #Signal redraw of title and request new data
                    $Display.RedrawTitle = $true
                    $Results.RefreshData = $true
                }
            }
            elseif ($Mode -eq "Command") {
                #Finish entering command
                if ($KeyPress.Key -eq "Enter") {
                    #Exit command mode and mark command ready
                    $Mode = "Select"
                    $Command.Raw = $Command.Manual
                    $Command.Ready = $true
                }
                #Remove char from end of command (or exit command mode)
                elseif ($KeyPress.Key -eq "Backspace") {
                    #If still command to remove, remove the last character
                    if ($Command.Manual -ne "") {
                        $Command.Manual = $Command.Manual.Remove($Command.Manual.Length - 1)
                        $Display.RedrawCommand = $true
                    }
                    #Otherwise, exit command mode
                    else {
                        Write-Log "KeyPress: Command: Exiting" -Path $LogPath
                        $Mode = "Select"

                        #Redraw status (above command menu), it'll set the endposition and then RedrawEnd will clean up leftover chars from command menu
                        $Display.RedrawStatus = $true
                    }

                }
                #Use command autocomplete suggestion
                elseif ($KeyPress.Key -in @("Tab", "RightArrow")) {
                    #Attempt autocomplete
                    $AutocompleteCommandName = try { [SearchCommand]$Command.Manual }catch { $null };

                    #If suggestion found, use it
                    if ($null -ne $AutocompleteCommandName) {
                        $Command.Manual = $AutocompleteCommandName.ToString()
                        $Display.RedrawCommand = $true
                    }
                }
                #Otherwise, if the character is in the allowed set, add it to the command string
                elseif ($KeyPress.KeyChar -match $Query.AllowedCharacters) {
                    #Add the character and signal redraw of command window
                    $Command.Manual += $KeyPress.KeyChar
                    $Display.RedrawCommand = $true
                }
            }
            elseif ($Mode -eq "Select") {
                #Enter Insert mode
                if ($KeyPress.Key -eq "I") {
                    #Set mode to insert and redraw title (adds an underscore as a cursor)
                    Write-Log "KeyPress: EnteredInsertMode" -Path $LogPath
                    $Mode = "Insert"
                    $Display.RedrawTitle = $true
                }
                #Enter Command mode
                elseif ($KeyPress.KeyChar -eq ":") {
                    #Set mode to Command, clear previous command and redraw the command window
                    Write-Log "KeyPress: EnteredCommandMode" -Path $LogPath
                    $Mode = "Command"
                    $Command.Manual = ""
                    $Display.RedrawCommand = $true
                }
                #Exit search dialogue entirely
                elseif ($KeyPress.Key -eq "Q") {
                    Write-Log "KeyPress: ExitKeyRecieved: Key=Q" -Path $LogPath
                    $Mode = "Exit"
                    continue
                }
                #Open selection (or selection's parent)
                elseif ($KeyPress.Key -eq "Enter") {
                    #Check results have loaded
                    if ($Results.Data -and $Results.Data[$Results.Cursor]) {

                        #Save query and selection to search history
                        if (!$SearchHistory.Incognito) {
                            [PSCustomObject]@{
                                DateTime = [datetime]::Now
                                Query    = $Query.Content
                                FullName = $Results.Data[$Results.Cursor].FullName
                                Name     = $Results.Data[$Results.Cursor].Name
                            } | Export-Csv $SearchHistoryPath -Append
                        }

                        #Increment file lookup count
                        $LookupCount.Cursor = $LookupCount.Data.FullName.IndexOf($Results.Data[$Results.Cursor].FullName)
                        if ($LookupCount.Cursor -ne -1) {
                            #Increment, verbosely to convert from string
                            $LookupCount.Data[$LookupCount.Cursor].Count = 1 + $LookupCount.Data[$LookupCount.Cursor].Count
                        }
                        else {
                            $LookupCount.Data += [pscustomobject]@{FullName = $Results.Data[$Results.Cursor].FullName; Count = 1 }
                        }
                        $LookupCount.Data | Export-Csv $LookupCountPath

                        #If shift key, open parent instead
                        $OpenParent = $KeyPress.Modifiers -band [ConsoleModifiers]::Shift

                        #Check path is valid
                        $FullName = $Results.Data[$Results.Cursor].FullName
                        if (Test-Path -LiteralPath $FullName) {
                            #Open the chosen file (use job so weird apps like vscode that print verbose output to the console they're invoked from don't create clutter)
                            $InvokeJob = Start-Job -ArgumentList @($FullName, $OpenParent) -ScriptBlock {
                                param (
                                    $FullName,
                                    $OpenParent
                                )
                                if ($OpenParent) {
                                    if ($IsWindows) {
                                        #For windows only, explicitly invoke File Explorer with this file in focus
                                        explorer.exe /select,$FullName
                                    } else {
                                        #Otherwise just invoke parent path with default program
                                        $ParentPath = Split-Path $FullName -Parent
                                        Invoke-Item -LiteralPath $ParentPath
                                    }
                                } else {
                                    #Invoke item with default program
                                    Invoke-Item -LiteralPath $FullName
                                }
                            }
                    
                            #Unless Ctrl key held, close search dialogue entirely
                            if (($KeyPress.Modifiers -band [ConsoleModifiers]::Control) -eq 0) {
                                $Mode = "Exit"
                            }
                        }
                        else {
                            #If opening an invalid path, update timekeeping to display message in status bar
                            $Timekeeping.LastOpenInvalidItem = [datetime]::Now
                            $Display.RedrawStatus = $true
                        }
                    }
                    #If Enter pressed before results load, display status and carry on
                    else {
                        #Update timekeeping to display status
                        $Timekeeping.LastOpenNullItem = [datetime]::Now
                        $Display.RedrawStatus = $true
                    }

                }
                #Up down navigation
                elseif ($KeyPress.Key -in @("UpArrow", "DownArrow")) {
                    #Increment/decrement cursor
                    switch ($KeyPress.Key) {
                        "UpArrow" { $Results.Cursor-- }
                        "DownArrow" { $Results.Cursor++ }
                    }

                    #Enforce bounds on results cursor
                    $Results.Cursor = [Math]::Max([Math]::Min($Results.Cursor, $Results.Data.Count - 1), 0)

                    #Scroll list to keep selected in view
                    $Display.RedrawList = $true
                    if ($Results.Cursor + 2 -gt $Display.ListEnd) {
                        $Display.ListStart++
                    }
                    if ($Results.Cursor - 1 -lt $Display.ListStart) {
                        $Display.ListStart--
                    }

                }

                #Display fullnames
                elseif ($KeyPress.Key -eq "F") {
                    #Toggle display of fullnames and redraw list
                    Write-Log "KeyPress: Select: ToggleDisplayFullName" -Path $LogPath
                    $Display.ShowFullName = !$Display.ShowFullName
                    $Display.RedrawList = $true
                }
                #Display parent basename
                elseif ($KeyPress.Key -eq "P") {
                    #Toggle display of parent names and redraw list
                    Write-Log "KeyPress: Select: ToggleDisplayParentName" -Path $LogPath
                    $Display.ShowParent = !$Display.ShowParent
                    $Display.RedrawList = $true
                }
                #Use all results
                elseif ($KeyPress.Key -eq "A") {
                    #Toggle use of exhaustive results (normal cap is 50), redraw status and request new data
                    Write-Log "KeyPress: Select: ToggleAllResults" -Path $LogPath
                    $Results.UseAll = !$Results.UseAll
                    $Display.RedrawStatus = $true
                    $Results.RefreshData = $true
                }
                #Toggle filtering to only folders (d for directory)
                elseif ($KeyPress.Key -eq "D") {
                    #Toggle filtering to only folders, redraw status and request new data
                    Write-Log "KeyPress: Select: ShowOnlyDirectories" -Path $LogPath
                    $OnlyDirectories = !$OnlyDirectories
                    $Display.RedrawStatus = $true
                    $Results.RefreshData = $true
                }
                #Toggle regex
                elseif ($KeyPress.Key -eq "R") {
                    #Toggle use of regex for query matching, redraw status and request new data
                    Write-Log "KeyPress: Select: ToggleRegex" -Path $LogPath
                    $Results.UseRegex = !$Results.UseRegex
                    $Display.RedrawStatus = $true
                    $Results.RefreshData = $true
                }
                #Copy path to selected result
                elseif ($KeyPress.Key -eq "C") {
                    Write-Log "KeyPress: CopyPath" -Path $LogPath
                    #If shift, copy parent
                    $Display.RedrawStatus = $true
                    if ($KeyPress.Modifiers -band [ConsoleModifiers]::Shift) {
                        Set-Clipboard (Split-Path $Results.Data[$Results.Cursor].FullName -Parent)
                        $Timekeeping.LastCopyParentPath = [DateTime]::Now
                    }
                    else {
                        Set-Clipboard $Results.Data[$Results.Cursor].FullName
                        $Timekeeping.LastCopyPath = [DateTime]::Now
                    }
                }
            }
        }
        #########################################################################################################################################
        ######################################################### HANDLE COMMAND ################################################################
        #########################################################################################################################################
        if ($Command.Ready) {
            #Reset CommandReady indicator
            Write-Log "HandleCommand: CommandReady: Command=$($Command.Raw)" -Path $LogPath
            $Command.Ready = $false

            #Parse command (extract name and any args, store args as hashtable by argument name)
            $Command.Name = try { [SearchCommand]($Command.Raw.Split(" ", 2)[0]) } catch { $null };
            $Command.Args = ($null -eq $Command.Raw.Split(" ", 2)[1]) ? $null : $Command.Raw.Split(" ", 2)[1].Split(" ").ForEach{
                @{ $_.Split("=")[0] = $_.Split("=")[1] } 
            }

            #Clear command value
            $Command.Raw = ""

            #Run the parsed command
            switch ($Command.Name) {
                "RebuildIndex" { 
                    #Order a new index and signal it is being rebuilt
                    Write-Log "HandleCommand: CommandReady: RebuildIndex" -Path $LogPath
                    New-SearchIndex -Path $Path
                    $RebuildInProgress = $true
                }
                "ToggleIncognito" {
                    Write-Log "HandleCommand: CommandReady: ToggleIncognito" -Path $LogPath
                    $SearchHistory.Incognito = !$SearchHistory.Incognito
                }
                Default {
                    Write-Log "HandleCommand: CommandReady: UncaughtCommand" -Path $LogPath
                }
            }

            #Exit command mode and clean up command menu
            $Mode = "Select"
            $Display.RedrawStatus = $true
        }

        #########################################################################################################################################
        ########################################################## REFRESH DATA #################################################################
        #########################################################################################################################################
        #If this query is in search history, load the most recently selected result immediately (doesn't check whether still valid)
        if ($SearchHistory.Data) {
            $IndexOfQuery = $SearchHistory.Data.Query.IndexOf($Query.Content)
            if ($Results.RefreshData -and $Query.Content -ne "" -and $IndexOfQuery -ne -1) {
                #Check search history item still exists
                if (Test-Path -LiteralPath $SearchHistory.Data[$IndexOfQuery].FullName) {
                    #Use directly from search history
                    Write-Log "RefreshData: CacheResult: Found: Name=$($SearchHistory.Data[$IndexOfQuery].Name)" -Path $LogPath
                    $Results.Data = $SearchHistory.Data[$IndexOfQuery]
                    $Display.RedrawList = $true
                }
                else {
                    Write-Log "RefreshData: CacheResult: Found: FailedTestPath: Name=$($SearchHistory.Data[$IndexOfQuery].Name)" -Path $LogPath

                }
            }
        }

        #Check if index rebuild in progress: written this way to check more often if we think a rebuild is in progress
        $PossibleCrawlJob = Get-Job -Name "SearchIndexCrawl" -ErrorAction SilentlyContinue
        if ($PossibleCrawlJob) {
            #Only check when refreshing data
            if ($Results.RefreshData -and !$RebuildInProgress -and $PossibleCrawlJob -and $PossibleCrawlJob.State -ne "Completed") {
                $RebuildInProgress = $true
                $Display.RedrawStatus = $true
            }
            #Check whenever we think a rebuild is in progress
            if ($RebuildInProgress -and $PossibleCrawlJob.State -eq "Completed") {
                #Signal rebuilding (displays in status) and redraw status
                $RebuildInProgress = $false
                $Display.RedrawStatus = $true

                #Asynchronously reload index
                $Index.Job = Start-ThreadJob -Name "LoadIndex" -ArgumentList @($Index) {
                    param (
                        $Index
                    )
                    if (![System.IO.File]::Exists($using:IndexPath)) {
                        [System.IO.File]::Create($using:IndexPath).Close()
                    }
                    $Index.Data = Import-Csv $using:IndexPath
                    $Index.Loaded = $true
                    $Index.LoadActioned = $false
                }
            }
        }

        #Load index from job result if it is ready and not yet loaded
        if ($Index.Loaded -and !$Index.LoadActioned) {
            $Index.LoadActioned = $true
            $Results.RefreshData = $true
        }
        
        #If using regex, check that the regex is valid
        if ($Results.RefreshData -and $Results.UseRegex) {
            try {
                [regex]::new($Query.Content) | Out-Null
                Write-Log "RefreshData: RegexCheck: Valid" -Path $LogPath
                $Results.RegexInvalid = $false
            }
            catch {
                Write-Log "RefreshData: RegexCheck: Invalid" -Path $LogPath
                $Results.RegexInvalid = $true
            }
            
            #If invalid, don't fulfill requests for data and signal the problem to user via status
            if ($Results.RegexInvalid) {
                $Results.RefreshData = $false
                $Display.RedrawStatus = $true
            }
        }

        #If index hasn't loaded yet, don't fulfill requests for data
        if ($Results.RefreshData -and !$Index.Loaded) {
            Write-Log "RefreshData: NoIndex: CancelRequest" -Path $LogPath
            $Results.RefreshData = $false
        }

        #Get new data (results for query given all the other settings)
        if ($Results.RefreshData) {
            #Reset tracking variable
            $Results.RefreshData = $false

            #Stop existing job if any
            if ($Results.Job) {
                Write-Log "RefreshData: NewRequest: StopJob" -Path $LogPath
                Stop-Job -Job $Results.Job
            }

            #Start a new result fetch job
            Write-Log "RefreshData: NewRequest: StartJob: Query=$($Query.Content)" -Path $LogPath
            $Results.Job = Start-ThreadJob -Name "FetchResults" -ArgumentList @($Results) -ScriptBlock {
                param (
                    $Results
                )
                
                #Determine whether this query has been searched before, obtain the previously selected result
                if ($SearchHistory.Data) {
                    $IndexOfQuery = ($using:SearchHistory).Data.Query.IndexOf($using:Query)
                    if ($IndexOfQuery -ne -1) {
                        $MostRecentSelection = ($using:SearchHistory)[$IndexOfQuery].FullName
                    }
                    else {
                        $MostRecentSelection = $null
                    }
                }
                
                #Get matching results (written like this so Where-Object benefits from upstream pipelining (dunno the actual name))
                #i.e. If I got the results then conditionally subset the first n results, it would have to search exhaustively. 
                #     Done the way I have below, once Select-Object has n results, it will signal Where-Object to stop looking. Wild.
                $Criteria = { ($Results.UseRegex ? $_.Name -match ($using:Query).Content : $_.Name.toLower().Contains(($using:Query).Content.toLower())) -and (!$using:OnlyDirectories -or $_.Folder -eq "True") }
                $NumberOfResults = $Results.UseAll ? [int]::MaxValue : 50
                $ResultsUnsorted = ($using:Index).Data | Where-Object $Criteria | Select-Object -First $NumberOfResults
                
                #Do some final scoring calculations (FinalScore) for each result
                for ($i = 0; $i -lt $ResultsUnsorted.Length; $i++) {
                    #Calculate query match score, ratio of query length to result name length
                    $QueryMatchScore = ($using:Query).Content.Length / $ResultsUnsorted[$i].Name.Length
    
                    #Calculate search history score
                    if ($null -ne $MostRecentSelection -and $ResultsUnsorted[$i].FullName -eq $MostRecentSelection) {
                        $SearchHistoryScore = 1
                    }
                    else {
                        $SearchHistoryScore = 0
                    }
    
                    #Calculate FinalScore based on RelevanceScore, search history, and the specific query
                    $ResultsUnsorted[$i].FinalScore = $QueryMatchScore + $SearchHistoryScore * 4 + $ResultsUnsorted[$i].RelevanceScore
                }

                #Check paths still valid (Only if !UseAll, otherwise too time consuming)
                if (!$Results.UseAll) {
                    $ResultsUnsorted = $ResultsUnsorted | Where-Object { Test-Path -LiteralPath $_.FullName }
                }

                #Sort results by score and signal that they're loaded and need to be used
                $Results.Data = $ResultsUnsorted | Sort-Object FinalScore -Descending
                $Results.Loaded = $true
                $Results.LoadActioned = $false
            }

            #Because status is now "RUNNING", redraw status
            $Display.RedrawStatus = $true
        }

        #If new results are ready, update some variables. Vestigial, results are now read from job right away, but the job doesn't yet have access to $Display, so keeping this
        if ($Results.Loaded -and !$Results.LoadActioned) {
            #Signal actioned, reset index and redraw list
            Write-Log "RefreshData: Receive: Actioning: ResultsCount=$($Results.Data.Count)" -Path $LogPath
            $Results.LoadActioned = $true
            $Results.Cursor = 0
            $Display.RedrawList = $true
        }
        
        #########################################################################################################################################
        ############################################################## DRAW #####################################################################
        #########################################################################################################################################
        if ($Mode -eq "Sleep") {
            #Set position and write sleep text
            $Host.UI.RawUI.CursorPosition = $Display.Position.Sleep
            [Console]::WriteLine("  Sleeping. Press any key to wake.".PadRight([Console]::WindowWidth))

            #Disable drawing of other components (except end), update end position
            $Display.RedrawTitle = $false
            $Display.RedrawList = $false
            $Display.RedrawStatus = $false
            
            #Update end position
            $Display.RedrawEnd = $true
            $Display.Position.End = $Host.UI.RawUI.CursorPosition
        }

        #Write title
        if ($Display.RedrawTitle) {
            #Reset flag, set position
            $Display.RedrawTitle = $false
            $Host.UI.RawUI.CursorPosition = $Display.Position.Title

            #Calculate menu title
            $MenuColourCode = "`e[38;2;22;198;12m"
            $MenuTitle = $Display.SearchBarString + $Query.Content + " "
            if ($Mode -eq "Insert") {
                $MenuTitle = $MenuTitle.Insert([Math]::Min($Display.SearchBarString.Length + $Query.Cursor + 1, $MenuTitle.Length), "`e[0m$MenuColourCode").Insert($Display.SearchBarString.Length + $Query.Cursor, "`e[21m")
            }

            #Pad the title to ensure old titles are covered
            $MenuTitle = $MenuTitle.PadRight([Console]::WindowWidth)
            $MenuString = $MenuColourCode + $MenuTitle + "`e[0m"

            [Console]::WriteLine($MenuString)
        }

        #Write list
        if ($Display.RedrawList) {
            #Reset flag, set position
            $Display.RedrawList = $false
            $Host.UI.RawUI.CursorPosition = $Display.Position.List
            
            if ($Results.Data) {
                #Set list count
                $Display.ListCount = [Math]::Min($Results.Data.Count, $Display.ListCountMax)

                #Bounds check list start index
                $Display.ListStart = [Math]::Max($Display.ListStart, 0)
                $Display.ListStart = [Math]::Min($Display.ListStart, $Results.Data.Count - $Display.ListCount)
                $Display.ListStart = [Math]::Min($Display.ListStart, $Results.Cursor)

                #Set list end index
                $Display.ListEnd = $Display.ListStart + $Display.ListCount

                #Add ellipse if more results above
                if ($Display.ListStart -ne 0) {
                    [Console]::Write(" `e[38;2;58;150;221m--MORE--`e[0m")
                    $CurrentPosition = $Host.UI.RawUI.CursorPosition
                    [Console]::WriteLine("".PadRight([Console]::WindowWidth - $CurrentPosition.X))
                }

                for ($i = $Display.ListStart; $i -lt $Display.ListEnd; $i++) {
                    #Display index
                    $IndexFormat = "`e[38;2;$($i -eq $Results.Cursor ? "249;241;165" : "58;150;221")m"
                    $IndexString = " $IndexFormat[$(($i + 1).ToString("00"))] "
                    [Console]::Write($IndexString)

                    #Display name
                    $NameFormat = "$($i -eq $Results.Cursor ? '' : "`e[0m")"
                    $NameString = "$NameFormat$($Results.Data[$i].Name)"
                    [Console]::Write($NameString)

                    #Determine if theres a name clash, if so, display parent folder name
                    $InResultsBefore = ($i -ne $Display.ListStart -and $Results.Data[($Display.ListStart)..($i - 1)].Name.IndexOf($Results.Data[$i].Name) -ne -1)
                    $InResultsAfter = ($i -lt ($Display.ListEnd - 1) -and $Results.Data[($i + 1)..($Display.ListEnd)].Name.IndexOf($Results.Data[$i].Name) -ne -1)
                    if ($InResultsBefore -or $InResultsAfter) {
                        $DisplayThisParent = $true
                    }
                    else {
                        $DisplayThisParent = $false
                    }

                    #Flag shortcut files
                    if ($Results.Data[$i].Name.Contains(".lnk")) {
                        [Console]::Write(" `e[38;2;180;0;158mSHORTCUT`e[0m")
                    }

                    #Display fullname (option)
                    if ($Display.ShowFullName -or $Display.ShowParent -or $DisplayThisParent) {
                        #Determine how many characters remain unused on this line
                        $CurrentPosition = $Host.UI.RawUI.CursorPosition
                        $SpaceLeft = [Console]::WindowWidth - $CurrentPosition.X

                        #Concatenate the parent path of this file to fit the length constraint
                        $ParentPath = $Results.Data[$i].FullName.Substring(0, $Results.Data[$i].FullName.LastIndexOf("\")).Substring($Path.Length)
                        if (($Display.ShowParent -or $DisplayThisParent) -and !$Display.ShowFullName) {
                            $ParentPath = $ParentPath.Substring([Math]::Max($ParentPath.LastIndexOf("\"), 0))
                        }
                        $ShortParentPath = $ParentPath.Substring([Math]::Max($ParentPath.Length - $SpaceLeft, 0)).Split("\", 2)[1]
                        
                        #Assemble string and write it
                        $FullNameFormat = "`e[38;2;118;118;118m"
                        $FullNameString = " $FullNameFormat\$($ShortParentPath)"
                        [Console]::Write($FullNameString)
                    }

                    #Clear formatting
                    [Console]::Write("`e[0m")

                    #Clear to end of line
                    $CurrentPosition = $Host.UI.RawUI.CursorPosition
                    if ($CurrentPosition.X -lt [Console]::WindowWidth) {
                        [Console]::Write("".PadRight([Console]::WindowWidth - $CurrentPosition.X))
                    }

                    #End line
                    [Console]::WriteLine()
                }

                #Add ellipse if more results below
                if ($Display.ListEnd -lt $Results.Data.Count) {
                    [Console]::Write(" `e[38;2;58;150;221m--MORE--`e[0m")
                    $CurrentPosition = $Host.UI.RawUI.CursorPosition
                    [Console]::WriteLine("".PadRight([Console]::WindowWidth - $CurrentPosition.X))
                }
            }
            else {
                Write-Host " [empty]".PadRight([Console]::WindowWidth) -F DarkCyan
            }

            #Signal a redraw of status (possibly overwritten), update it's position
            $Display.RedrawStatus = $true
            $Display.Position.Status = $Host.UI.RawUI.CursorPosition
        }

        #Write status
        if ($Display.RedrawStatus) {
            #Reset flag, set position
            $Display.RedrawStatus = $false
            $Host.UI.RawUI.CursorPosition = $Display.Position.Status

            #Assemble status display string
            $StatusDetails = ""
            if ($Results.UseAll) { $StatusDetails += "ALLRESULTS " }
            if ($Results.UseRegex) { $StatusDetails += "REGEX " }
            if ($Results.RegexInvalid) { $StatusDetails += "`e[38;2;255;0;0mINVALIDREGEX`e[0m " }
            if ($OnlyDirectories) { $StatusDetails += "FOLDER " }
            if ($RebuildInProgress) { $StatusDetails += "`e[5mREBUILDING`e[0m " }
            if ($Results.Job.State -ne "Completed") { $StatusDetails += "`e[5mRUNNING`e[0m " }
            if ($Timekeeping.LastCopyPath -gt [datetime]::Now.AddSeconds(-2)) { $StatusDetails += "`e[38;2;0;255;0mCOPIED`e[0m " }
            if ($Timekeeping.LastCopyParentPath -gt [datetime]::Now.AddSeconds(-2)) { $StatusDetails += "`e[38;2;0;255;0mPARENTCOPIED`e[0m " }
            if ($Timekeeping.LastOpenInvalidItem -gt [datetime]::Now.AddSeconds(-2)) { $StatusDetails += "`e[38;2;255;0;0mINVALIDPATH`e[0m " }
            if ($Timekeeping.LastOpenNullItem -gt [datetime]::Now.AddSeconds(-1) -and !$Results.Data) { $StatusDetails += "`e[38;2;255;0;0mNORESULT`e[0m " }
            if ($SearchHistory.Incognito) { $StatusDetails += "INCOGNITO " }

            if ($StatusDetails -ne "") {
                #Add a blank line for some space
                [Console]::WriteLine(" " * [Console]::WindowWidth)

                #Write status details (no newline so line can be cleared below)
                [Console]::Write($StatusDetails)

                #Clear to end of line
                $CurrentPosition = $Host.UI.RawUI.CursorPosition
                if ($CurrentPosition.X -lt [Console]::WindowWidth) {
                    [Console]::Write("".PadRight([Console]::WindowWidth - $CurrentPosition.X))
                }
            
                #End line
                [Console]::WriteLine()
            }

            #Prepare for next section (either Command or End): update positions and signal redraw
            $Display.Position.Command = $Host.UI.RawUI.CursorPosition
            $Display.Position.End = $Host.UI.RawUI.CursorPosition
            if ($Mode -eq "Command") {
                #Signal redraw of command window
                $Display.RedrawCommand = $true
            }
            else {
                #Signal redraw of end (writes blanks over any previously used space)
                $Display.RedrawEnd = $true
            }
        }

        #If in command mode, draw command window
        if ($Display.RedrawCommand) {
            #Reset flag, set position
            $Display.RedrawCommand = $false
            $Host.UI.RawUI.CursorPosition = $Display.Position.Command

            #Write a blank line
            [Console]::WriteLine()

            #Display command
            [Console]::Write(":$($Command.Manual)")

            #Display command autocomplete
            try {
                $AutocompleteCommandName = [SearchCommand]$Command.Manual
                [Console]::Write("`e[38;2;128;128;128m$($AutocompleteCommandName.ToString().Substring($Command.Manual.Length))`e[0m")
            }
            catch {
                Write-Log "Draw: Command: Autocomplete: Fail" -Path $LogPath
            }

            #Clear to end of line
            $CurrentPosition = $Host.UI.RawUI.CursorPosition
            if ($CurrentPosition.X -lt [Console]::WindowWidth) {
                [Console]::Write("".PadRight([Console]::WindowWidth - $CurrentPosition.X))
            }

            #Finish line
            [Console]::WriteLine()

            #Update end position
            $Display.RedrawEnd = $true
            $Display.Position.End = $Host.UI.RawUI.CursorPosition
        }
        
        #Write end blanks
        if ($Display.RedrawEnd) {
            #Reset flag, set position
            $Display.RedrawEnd = $false
            $Host.UI.RawUI.CursorPosition = $Display.Position.End

            #Overwrite excess previously used lines with blanks
            if ($Display.Position.End.Y -le $Display.Position.MaxY) {
                while ($Host.UI.RawUI.CursorPosition.Y -lt $Display.Position.MaxY) {
                    [Console]::WriteLine(" " * [Console]::WindowWidth)
                }
            }
            #If already lower than MaxY, update MaxY
            else {
                $Display.Position.MaxY = $Host.UI.RawUI.CursorPosition.Y
            }
        }
    }
    #########################################################################################################################################
    ############################################################### CLEANUP #################################################################
    #########################################################################################################################################
    #Overwrite all previously used lines with blanks
    $Host.UI.RawUI.CursorPosition = $Display.Position.Start
    while ($Host.UI.RawUI.CursorPosition.Y -lt $Display.Position.MaxY) {
        [Console]::WriteLine(" " * [Console]::WindowWidth)
    }

    #Log framecount, runtime and average framerate
    $Timekeeping.End = [datetime]::Now
    $Timekeeping.Duration = ($TimeKeeping.End - $Timekeeping.Start).TotalSeconds
    Write-Log -Message "Cleanup: FrameCount=$($Timekeeping.FrameCount); RunDuration=$([Math]::Round($Timekeeping.Duration, 2)) sec; FrameRate=$([Math]::Round($Timekeeping.FrameCount / $Timekeeping.Duration)) fps" -Path $LogPath

    #Move cursor back up and unhide it
    $Host.UI.RawUI.CursorPosition = $Display.Position.Start
    [Console]::CursorVisible = $true

    #Ensure that any items scheduled to be opened are done
    if ($InvokeJob) {
        Wait-Job $InvokeJob | Out-Null
    }
}