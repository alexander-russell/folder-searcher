# FolderSearcher

## About

This is a PowerShell module that provides an interactive menu to search files in a configured folder. It handles creating an index of the contents of the chosen folder and ranking them. When the main function `Search-Folder` is called, the index is used to present the most relevant files/directories for a given query. I wrote this because I found the built-in Windows search to be slow and often fail to locate the item I was looking for. Though this doesn't fully replace the advanced capabilities of Windows search, it does handle looking for any files and folders.

I use it to search through my Desktop directory, where I keep all of my files.

## Features

Here's a couple quick ones I think are neat:

* Maintains interactivity with asynchronous threads

* Continual refresh of results on query change

* Search by regular expressions

* Search history

* Use cached results

## Install

As mentioned above, this is a PowerShell module. It can therefore by installed in the standard manner for a PowerShell module. All you should need to do is put it where PowerShell can find it.

1. Find your PowerShell module path

    a. Open PowerShell

    b. Enter `$env:PSModulePath`

2. The above command will give you a list of folders, separated by a semicolon. Clone this repository into any of these directories. For example, I use `C:\Users\<user>\Documents\PowerShell\Modules`.

3. Rename the cloned folder from `folder-searcher` to `FolderSearcher`.

3. Continue to setup below

## Setup

After you have followed the above steps to install the package, you will need to set it up. To get it working, you'll need to choose a path that you want to search in. For example, I use `C:\Users\<user>\Desktop`.

With that path in mind:

1. Run `Search-Folder`. It will exit with an error, this is what we want.
2. Go to the .json file specified in the error message
3. Change the value of Path from `"PATH_TO_YOUR_FOLDER"` to your chosen folder path. Like the error code says, make sure you escape backslashes, as .json will try to interpret them. For example, my path is `C:\Users\<user>\Desktop`, so in my Config.json file I write `"C:\\Users\\<user>\\Desktop"` as the value for the `Path` property.

Thats all you need to do to get it running. To use it, run `Search-Folder`. It should start building the index. When the "REBUILDING" status disappears, it's ready to use and results should start to appear. There's some more configuration you could do in Advanced Setup below.

## Usage

Once installed and set up, to use the module you just need to run the command `Search-Folder` to open the search dialogue. You can optionally start it with an initial query like `Search-Folder -QueryContent "my search query"`, but this isn't necessary. If no initial query is provided, the program will open in *Insert Mode*, ready to get the query from keyboard input.

Once the dialogue is open, basic usage involves:

* Enter *Insert Mode* by pressing "I". A cursor should appear in the search box, you can now edit your query. Navigate with the left and right arrow keys and exit *Insert Mode* with `Enter` or `Escape`. You can access recent searches (only searches that ended in opening an item) with the up and down arrow keys.

* Navigate results with the up and down arrow keys, open the selected result with `Enter`. If you hold `Shift`, you'll open the parent folder of the selected item. If you hold `Ctrl`, the search dialogue will stay open, otherwise it will close.

For more information on usage (there's several more keybindings, and a small command interface for extra function), see the built-in help page in PowerShell. If available, you can access it with `Get-Help Search-Folder`. 

## Advanced setup

To make frequent use of this module more convenient for myself, I've configured a couple of extra things.

### Shortcut

Included in the module is the file `Search.lnk`. This is a shortcut that will run PowerShell with the `Search-Folder` command. If you're interested in having a shortcut, try double clicking it. If the `Search-Folder` dialogue doesn't launch, you may need to adjust the path to your PowerShell executable file. Right click on the shortcut and select "Properties", then check that the executable mentioned at the start of the `Target` field is correct.

I keep this shortcut on my taskbar. To do this, right click on the shortcut, select "Show more options" and then select "Pin to taskbar". You can now launch it directly from your task bar. 

**Note:** If you're not already aware, shortcuts on the taskbar can be launched with a  keyboard shortcut based on their position. The first shortcut on your taskbar is launched with `Win+1`, the second with `Win+2` and so on.

### Index rebuild on opening PowerShell

So that the index is ready to go when I search for something, I have configured my PowerShell profile to run the indexer if it hasn't yet run that day.

To do so, follow these steps:

1. Open your PowerShell profile: Go to PowerShell and enter the command `notepad $PROFILE` (If the file doesn't yet exist, create it then try again)
2. Wherever you like within the file, add the following, replacing PATH_TO_THE_MODULE with the path to your FolderSearcher directory on your PSModulePath, as set up above:

```{PowerShell}
$LastCrawlDate = Get-Content "PATH_TO_THE_MODULE\Data\IndexLastCrawlDate.txt"
if ($LastCrawlDate -ne [DateTime]::Now.ToString("yyyy-MM-dd")) {
    $Config = Get-Content  "PATH_TO_THE_MODULE\Data\Config.json" | ConvertFrom-Json
    $FolderSearcherModule = Get-Module -Name FolderSearcher
    & $FolderSearcherModule { New-SearchIndex -Path $Config.Path }
}
```

**Note:** The above code works by sneakily accessing an unexported function from this module. I have chosen not to export it to avoid duplicating some of the Config file setup code in both places and because the function shouldn't be used directly outside of this usecase. The index can be rebuilt from the `Search-Folder` function via the `:RebuildIndex` command.

## Contact

This project is maintained by Alexander Russell. If you have any problems with the above, please either send me an email or create an issue in this repository - your preference.