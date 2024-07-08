<#
.SYNOPSIS
Append log message with timestamp to log file

.DESCRIPTION
Prepends a provided message with a timestamp of the format "yyyy-MM-dd HH:mm:ss.fff", then adds 
that to the specified file. Creates the file if it does not exist.

.PARAMETER Message
Parameter description

.PARAMETER Path
Parameter description

.EXAMPLE
Write-Log -Message "Entering the fire swamp" -Path "./Adventures/Florin"

.NOTES
Duplicate of a version found in my other packages, though this may grow apart from the general use function.
#>
function Write-Log {
    param (
        $Message,
        $Path
    )

    if (!$PSBoundParameters.ContainsKey("Path")) {
        Write-Error "Specify a path"
        return
    }

    #Prepend a timestamp
    $Message = (Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff") + " " + $Message

    #Append to file
    $Message | Out-File $Path -Append
}