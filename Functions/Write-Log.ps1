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