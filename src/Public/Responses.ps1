<#
.SYNOPSIS
Attaches a file onto the Response for downloading.

.DESCRIPTION
Attaches a file from the "/public", and static Routes, onto the Response for downloading.

.PARAMETER Path
The path to a static file relative to the "/public" directory, or a static Route.

.EXAMPLE
# attaches the "/public/downloads/installer.exe" file
Set-PodeResponseAttachment -Path 'downloads/installer.exe'

.EXAMPLE
# attaches the "/content/assets/images/icon.png" file from a static Route
route static '/assets' './content/assets'
Set-PodeResponseAttachment -Path '/assets/images/icon.png'
#>
function Set-PodeResponseAttachment
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]
        $Path
    )

    # only attach files from public/static-route directories when path is relative
    $Path = (Get-PodeStaticRoutePath -Route $Path).Path

    # test the file path, and set status accordingly
    if (!(Test-PodePath $Path)) {
        return
    }

    $filename = Get-PodeFileName -Path $Path
    $ext = Get-PodeFileExtension -Path $Path -TrimPeriod

    try {
        # setup the content type and disposition
        $WebEvent.Response.ContentType = (Get-PodeContentType -Extension $ext)
        Set-PodeHeader -Name 'Content-Disposition' -Value "attachment; filename=$($filename)"

        # if serverless, get the content raw and return
        if ($PodeContext.Server.IsServerless) {
            if (Test-IsPSCore) {
                $content = (Get-Content -Path $Path -Raw -AsByteStream)
            }
            else {
                $content = (Get-Content -Path $Path -Raw -Encoding byte)
            }

            $WebEvent.Response.Body = $content
        }

        # else if normal, stream the content back
        else {
            # setup the response details and headers
            $WebEvent.Response.ContentLength64 = $fs.Length
            $WebEvent.Response.SendChunked = $false

            # set file as an attachment on the response
            $buffer = [byte[]]::new(64 * 1024)
            $read = 0

            # open up the file as a stream
            $fs = (Get-Item $Path).OpenRead()

            while (($read = $fs.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $WebEvent.Response.OutputStream.Write($buffer, 0, $read)
            }
        }
    }
    finally {
        dispose $fs
    }
}

<#
.SYNOPSIS
Writes a String a Byte[] to the Response.

.DESCRIPTION
Writes a String a Byte[] to the Response, as some specified content type. This value can also be cached.

.PARAMETER Value
A String value to write.

.PARAMETER Bytes
An array of Bytes to write.

.PARAMETER ContentType
The content type of the data being written.

.PARAMETER MaxAge
The maximum age to cache the value on the browser, in seconds.

.PARAMETER Cache
Should the value be cached by browsers, or not?

.EXAMPLE
Write-PodeTextResponse -Value 'Leeeeeerrrooooy Jeeeenkiiins!'

.EXAMPLE
Write-PodeTextResponse -Value '{"name": "Rick"}' -ContentType 'application/json'

.EXAMPLE
$bytes = Get-Content -Path ./some/image.png -Raw -AsByteStream
Write-PodeTextResponse -Bytes $bytes -Cache -MaxAge 1800
#>
function Write-PodeTextResponse
{
    [CmdletBinding(DefaultParameterSetName='String')]
    param (
        [Parameter(ParameterSetName='String')]
        [string]
        $Value,

        [Parameter(ParameterSetName='Bytes')]
        [byte[]]
        $Bytes,

        [Parameter()]
        [string]
        $ContentType = 'text/plain',

        [Parameter()]
        [int]
        $MaxAge = 3600,

        [switch]
        $Cache
    )

    $isStringValue = ($PSCmdlet.ParameterSetName -ieq 'string')
    $isByteValue = ($PSCmdlet.ParameterSetName -ieq 'bytes')

    # if there's nothing to write, return
    if ($isStringValue -and [string]::IsNullOrWhiteSpace($Value)) {
        return
    }

    if ($isByteValue -and (($null -eq $Bytes) -or ($Bytes.Length -eq 0))) {
        return
    }

    # if the response stream isn't writable, return
    $res = $WebEvent.Response
    if (($null -eq $res) -or (!$PodeContext.Server.IsServerless -and (($null -eq $res.OutputStream) -or !$res.OutputStream.CanWrite))) {
        return
    }

    # set a cache value
    if ($Cache) {
        Set-PodeHeader -Name 'Cache-Control' -Value "max-age=$($MaxAge), must-revalidate"
        Set-PodeHeader -Name 'Expires' -Value ([datetime]::UtcNow.AddSeconds($MaxAge).ToString("ddd, dd MMM yyyy HH:mm:ss 'GMT'"))
    }

    # specify the content-type if supplied (adding utf-8 if missing)
    if (![string]::IsNullOrWhiteSpace($ContentType)) {
        $charset = 'charset=utf-8'
        if ($ContentType -inotcontains $charset) {
            $ContentType = "$($ContentType); $($charset)"
        }

        $res.ContentType = $ContentType
    }

    # if we're serverless, set the string as the body
    if ($PodeContext.Server.IsServerless) {
        if ($isStringValue) {
            $res.Body = $Value
        }
        else {
            $res.Body = $Bytes
        }
    }

    else {
        # convert string to bytes
        if ($isStringValue) {
            $Bytes = ConvertFrom-PodeValueToBytes -Value $Value
        }

        # write the content to the response stream
        $res.ContentLength64 = $Bytes.Length

        try {
            $ms = New-Object -TypeName System.IO.MemoryStream
            $ms.Write($Bytes, 0, $Bytes.Length)
            $ms.WriteTo($res.OutputStream)
        }
        catch {
            if ((Test-PodeValidNetworkFailure $_.Exception)) {
                return
            }

            $_.Exception | Out-Default
            throw
        }
        finally {
            if ($null -ne $ms) {
                $ms.Close()
            }
        }
    }
}

function Write-PodeFileResponse
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [ValidateNotNull()]
        [string]
        $Path,

        [Parameter()]
        $Data = @{},

        [Parameter()]
        [string]
        $ContentType = $null,

        [Parameter()]
        [int]
        $MaxAge = 3600,

        [switch]
        $Cache
    )

    # test the file path, and set status accordingly
    if (!(Test-PodePath $Path -FailOnDirectory)) {
        return
    }

    # are we dealing with a dynamic file for the view engine? (ignore html)
    $mainExt = Get-PodeFileExtension -Path $Path -TrimPeriod

    # generate dynamic content
    if (![string]::IsNullOrWhiteSpace($mainExt) -and (($mainExt -ieq 'pode') -or ($mainExt -ieq $PodeContext.Server.ViewEngine.Extension))) {
        $content = Get-PodeFileContentUsingViewEngine -Path $Path -Data $Data

        # get the sub-file extension, if empty, use original
        $subExt = Get-PodeFileExtension -Path (Get-PodeFileName -Path $Path -WithoutExtension) -TrimPeriod
        $subExt = (coalesce $subExt $mainExt)

        $ContentType = (coalesce $ContentType (Get-PodeContentType -Extension $subExt))
        Write-PodeTextResponse -Value $content -ContentType $ContentType
    }

    # this is a static file
    else {
        if (Test-IsPSCore) {
            $content = (Get-Content -Path $Path -Raw -AsByteStream)
        }
        else {
            $content = (Get-Content -Path $Path -Raw -Encoding byte)
        }

        $ContentType = (coalesce $ContentType (Get-PodeContentType -Extension $mainExt))
        Write-PodeTextResponse -Bytes $content -ContentType $ContentType -MaxAge $MaxAge -Cache:$Cache
    }
}

function Write-PodeCsvResponse
{
    [CmdletBinding(DefaultParameterSetName='Value')]
    param (
        [Parameter(Mandatory=$true, ParameterSetName='Value')]
        $Value,

        [Parameter(Mandatory=$true, ParameterSetName='File')]
        [string]
        $Path
    )

    switch ($PSCmdlet.ParameterSetName.ToLowerInvariant()) {
        'file' {
            if (Test-PodePath $Path) {
                $Value = Get-PodeFileContent -Path $Path
            }
        }

        'value' {
            if ($Value -isnot 'string') {
                $Value = @(foreach ($v in $Value) {
                    New-Object psobject -Property $v
                })

                if (Test-IsPSCore) {
                    $Value = ($Value | ConvertTo-Csv -Delimiter ',' -IncludeTypeInformation:$false)
                }
                else {
                    $Value = ($Value | ConvertTo-Csv -Delimiter ',' -NoTypeInformation)
                }

                $Value = ($Value -join ([environment]::NewLine))
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($Value)) {
        $Value = [string]::Empty
    }

    Write-PodeTextResponse -Value $Value -ContentType 'text/csv'
}

function Write-PodeHtmlResponse
{
    [CmdletBinding(DefaultParameterSetName='Value')]
    param (
        [Parameter(Mandatory=$true, ParameterSetName='Value')]
        $Value,

        [Parameter(Mandatory=$true, ParameterSetName='File')]
        [string]
        $Path
    )

    switch ($PSCmdlet.ParameterSetName.ToLowerInvariant()) {
        'file' {
            if (Test-PodePath $Path) {
                $Value = Get-PodeFileContent -Path $Path
            }
        }

        'value' {
            if ($Value -isnot 'string') {
                $Value = ($Value | ConvertTo-Html)
                $Value = ($Value -join ([environment]::NewLine))
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($Value)) {
        $Value = [string]::Empty
    }

    Write-PodeTextResponse -Value $Value -ContentType 'text/html'
}

function Write-PodeJsonResponse
{
    [CmdletBinding(DefaultParameterSetName='Value')]
    param (
        [Parameter(Mandatory=$true, ParameterSetName='Value')]
        $Value,

        [Parameter(Mandatory=$true, ParameterSetName='File')]
        [string]
        $Path
    )

    switch ($PSCmdlet.ParameterSetName.ToLowerInvariant()) {
        'file' {
            if (Test-PodePath $Path) {
                $Value = Get-PodeFileContent -Path $Path
            }
        }

        'value' {
            if ($Value -isnot 'string') {
                $Value = ($Value | ConvertTo-Json -Depth 10 -Compress)
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($Value)) {
        $Value = '{}'
    }

    Write-PodeTextResponse -Value $Value -ContentType 'application/json'
}

function Write-PodeXmlResponse
{
    [CmdletBinding(DefaultParameterSetName='Value')]
    param (
        [Parameter(Mandatory=$true, ParameterSetName='Value')]
        $Value,

        [Parameter(Mandatory=$true, ParameterSetName='File')]
        [string]
        $Path
    )

    switch ($PSCmdlet.ParameterSetName.ToLowerInvariant()) {
        'file' {
            if (Test-PodePath $Path) {
                $Value = Get-PodeFileContent -Path $Path
            }
        }

        'value' {
            if ($Value -isnot 'string') {
                $Value = @(foreach ($v in $Value) {
                    New-Object psobject -Property $v
                })
        
                $Value = ($Value | ConvertTo-Xml -Depth 10 -As String -NoTypeInformation)
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($Value)) {
        $Value = [string]::Empty
    }

    Write-PodeTextResponse -Value $Value -ContentType 'text/xml'
}

function Write-PodeViewResponse
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]
        $Path,

        [Parameter()]
        [hashtable]
        $Data = @{},

        [switch]
        $FlashMessages
    )

    # default data if null
    if ($null -eq $Data) {
        $Data = @{}
    }

    # add path to data as "pagename" - unless key already exists
    if (!$Data.ContainsKey('pagename')) {
        $Data['pagename'] = $Path
    }

    # load all flash messages if needed
    if ($FlashMessages -and ($null -ne $WebEvent.Session.Data.Flash)) {
        $Data['flash'] = @{}

        foreach ($name in (Get-PodeFlashMessageNames)) {
            $Data.flash[$name] = (Get-PodeFlashMessage -Name $name)
        }
    }
    elseif ($null -eq $Data['flash']) {
        $Data['flash'] = @{}
    }

    # add view engine extension
    $ext = Get-PodeFileExtension -Path $Path
    if ([string]::IsNullOrWhiteSpace($ext)) {
        $Path += ".$($PodeContext.Server.ViewEngine.Extension)"
    }

    # only look in the view directory
    $Path = (Join-Path $PodeContext.Server.InbuiltDrives['views'] $Path)

    # test the file path, and set status accordingly
    if (!(Test-PodePath $Path)) {
        return
    }

    # run any engine logic and render it
    Write-PodeHtmlResponse -Value (Get-PodeFileContentUsingViewEngine -Path $Path -Data $Data)
}

function Set-PodeResponseStatus
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [int]
        $Code,

        [Parameter()]
        [string]
        $Description,

        [Parameter()]
        $Exception,

        [Parameter()]
        [string]
        $ContentType = $null,

        [switch]
        $NoErrorPage
    )

    # set the code
    $WebEvent.Response.StatusCode = $Code

    # set an appropriate description (mapping if supplied is blank)
    if ([string]::IsNullOrWhiteSpace($Description)) {
        $Description = (Get-PodeStatusDescription -StatusCode $Code)
    }

    if (!$PodeContext.Server.IsServerless -and ![string]::IsNullOrWhiteSpace($Description)) {
        $WebEvent.Response.StatusDescription = $Description
    }

    # if the status code is >=400 then attempt to load error page
    if (!$NoErrorPage -and ($Code -ge 400)) {
        Show-PodeErrorPage -Code $Code -Description $Description -Exception $Exception -ContentType $ContentType
    }
}

function Move-PodeResponseUrl
{
    [CmdletBinding(DefaultParameterSetName='Url')]
    param (
        [Parameter(Mandatory=$true, ParameterSetName='Url')]
        [string]
        $Url,

        [Parameter(ParameterSetName='Components')]
        [int]
        $Port = 0,

        [Parameter(ParameterSetName='Components')]
        [ValidateSet('', 'HTTP', 'HTTPS')]
        [string]
        $Protocol,

        [Parameter(ParameterSetName='Components')]
        [string]
        $Domain,

        [switch]
        $Moved
    )

    if ($PSCmdlet.ParameterSetName -ieq 'components') {
        $uri = $WebEvent.Request.Url

        # set the protocol
        $Protocol = $Protocol.ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($Protocol)) {
            $Protocol = $uri.Scheme
        }

        # set the domain
        if ([string]::IsNullOrWhiteSpace($Domain)) {
            $Domain = $uri.Host
        }

        # set the port
        if ($Port -le 0) {
            $Port = $uri.Port
        }

        $PortStr = [string]::Empty
        if (@(80, 443) -notcontains $Port) {
            $PortStr = ":$($Port)"
        }

        # combine to form the url
        $Url = "$($Protocol)://$($Domain)$($PortStr)$($uri.PathAndQuery)"
    }

    Set-PodeHeader -Name 'Location' -Value $Url

    if ($Moved) {
        Set-PodeResponseStatus -Code 301 -Description 'Moved'
    }
    else {
        Set-PodeResponseStatus -Code 302 -Description 'Redirect'
    }
}

function Write-PodeTcpClient
{
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $Message,

        [Parameter()]
        $Client
    )

    # error if serverless
    Test-PodeIsServerless -FunctionName 'Write-PodeTcpClient' -ThrowError

    # use the main client if one isn't supplied
    if ($null -eq $Client) {
        $Client = $TcpEvent.Client
    }

    $encoder = New-Object System.Text.ASCIIEncoding
    $buffer = $encoder.GetBytes("$($Message)`r`n")
    $stream = $Client.GetStream()
    await $stream.WriteAsync($buffer, 0, $buffer.Length)
    $stream.Flush()
}

function Read-PodeTcpClient
{
    [CmdletBinding()]
    param (
        [Parameter()]
        $Client
    )

    # error if serverless
    Test-PodeIsServerless -FunctionName 'Read-PodeTcpClient' -ThrowError

    # use the main client if one isn't supplied
    if ($null -eq $Client) {
        $Client = $TcpEvent.Client
    }

    $bytes = New-Object byte[] 8192
    $encoder = New-Object System.Text.ASCIIEncoding
    $stream = $Client.GetStream()
    $bytesRead = (await $stream.ReadAsync($bytes, 0, 8192))
    return $encoder.GetString($bytes, 0, $bytesRead)
}

function Save-PodeResponseFile
{
    [CmdletBinding()]
    param (
        [Parameter(Mandatory=$true)]
        [string]
        $ParameterName,

        [Parameter()]
        [string]
        $Path = '.'
    )

    # if path is '.', replace with server root
    $Path = Get-PodeRelativePath -Path $Path -JoinRoot

    # ensure the parameter name exists in data
    $fileName = $WebEvent.Data[$ParameterName]
    if ([string]::IsNullOrWhiteSpace($fileName)) {
        throw "A parameter called '$($ParameterName)' was not supplied in the request"
    }

    # ensure the file data exists
    if (!$WebEvent.Files.ContainsKey($fileName)) {
        throw "No data for file '$($fileName)' was uploaded in the request"
    }

    # if the path is a directory, add the filename
    if (Test-PodePathIsDirectory -Path $Path) {
        $Path = Join-Path $Path $fileName
    }

    # save the file
    [System.IO.File]::WriteAllBytes($Path, $WebEvent.Files[$fileName].Bytes)
}

function Set-PodeViewEngine
{
    [CmdletBinding()]
    param (
        [Parameter()]
        [string]
        $Type,

        [Parameter()]
        [scriptblock]
        $ScriptBlock = $null,

        [Parameter()]
        [string]
        $Extension
    )

    if ([string]::IsNullOrWhiteSpace($Extension)) {
        $Extension = $Type.ToLowerInvariant()
    }

    $PodeContext.Server.ViewEngine.Type = $Type.ToLowerInvariant()
    $PodeContext.Server.ViewEngine.Extension = $Extension
    $PodeContext.Server.ViewEngine.Script = $ScriptBlock
    $PodeContext.Server.ViewEngine.IsDynamic = ($Type -ine 'html')
}