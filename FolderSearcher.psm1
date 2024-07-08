# Include files
. "$PSScriptRoot\functions\Write-Log.ps1"
. "$PSScriptRoot\functions\New-SearchIndex.ps1"
. "$PSScriptRoot\functions\Search-Folder.ps1"
. "$PSScriptRoot\functions\EnumSearchCommand.ps1"

# Functions to export
$FunctionsToExport = @(
	'Search-Folder',
	'New-SearchIndex'
)


# Cmdlets to export
$CmdletsToExport = @()


# Variables to export
$VariablesToExport = @()


# Aliases to export
$AliasesToExport = @()


# Export the members
$moduleMembers = @{
	Function = $FunctionsToExport
	Cmdlet   = $CmdletsToExport
	Variable = $VariablesToExport
	Alias    = $AliasesToExport
}
Export-ModuleMember @moduleMembers
