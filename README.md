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

3. Continue to setup below


## Setup

After you have followed the above steps to install the package, you will need to set it up. To get it working, you'll need to choose a path that you want to search in. For example, I use `C:\Users\<user>\Desktop`.

With that path determined, 
