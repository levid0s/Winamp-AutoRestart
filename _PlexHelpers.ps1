function Get-PlexApi {
    [CmdletBinding()]
    param(
        [string]$UrlRoot,
        [string]$Token,
        [string]$ApiPath,
        [string]$Method = 'GET'
    )

    if (-not $UrlRoot) {
        $UrlRoot = $env:PLEX_ADDR
    }

    if (-not $Token) {
        $Token = $env:PLEX_TOKEN
    }

    if (-not $UrlRoot) {
        Throw 'Plex UrlRoot is required.'
    }

    if (-not $Token) {
        Throw 'Plex Token is required.'
    }

    # Add trailing slash to UrlRoot if it's not there.
    if ($UrlRoot[-1] -ne '/') {
        $UrlRoot += '/'
    }

    if ($ApiPath[0] -eq '/') {
        $ApiPath = $ApiPath.Substring(1)
    }

    $Url = $UrlRoot + $ApiPath
    Write-Verbose "Plex API Url: $Url"

    $Headers = @{
        'X-Plex-Token' = $Token
        'Accept'       = 'application/json'
    }

    $Params = @{
        Uri     = $Url
        Headers = $Headers
        Method  = $Method
    }

    $Response = Invoke-RestMethod @Params

    return $Response
}

function Get-PlexStatusSessions {
    $ApiPath = '/status/sessions'

    $StatusSessions = Get-PlexApi -ApiPath $ApiPath

    return $StatusSessions
}

function Get-PlexLibraryMetadata {
    [CmdletBinding()]
    param(
        [string]$RatingKey
    )

    $ApiPath = "/library/metadata/$RatingKey"

    $LibraryMetadata = Get-PlexApi -ApiPath $ApiPath

    return $LibraryMetadata
}


function Get-PlexNowPlaying {
    param(
        [int]$UserId = 1
    )

    $StatusSessions = Get-PlexStatusSessions

    $NowPlayingFiltered = $StatusSessions.MediaContainer.Metadata | Where-Object {
        $_.User.id -eq $UserId -or [string]::IsNullOrEmpty($UserId)
    }

    if (!$NowPlayingFiltered) {
        return
    }

    if (!$NowPlayingFiltered.RatingKey) {
        return
    }

    $RatingKey = $NowPlayingFiltered.RatingKey

    $MediaMetadata = Get-PlexLibraryMetadata -RatingKey $RatingKey

    if (!$MediaMetadata) {
        return
    }

    if (!$MediaMetadata.MediaContainer.Metadata) {
        return
    }

    $MediaMetadta = $MediaMetadata.MediaContainer.Metadata[0]

    $NowPlaying = @{
        # Artist, Album, Year, Title, Rating
        Title  = $MediaMetadta.title
        Artist = $MediaMetadta.grandparentTitle
        Album  = $MediaMetadta.parentTitle
        Year   = $MediaMetadta.parentYear
        Rating = $MediaMetadta.userRating
    }

    return $NowPlaying
}
