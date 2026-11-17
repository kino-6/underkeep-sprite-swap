<#
.SYNOPSIS
Local-only web server for replacing Underkeep sprites in the browser.

.EXAMPLE
  .\uksprite-web.ps1            # opens http://localhost:18093/ ; press Ctrl+C to stop
  .\uksprite-web.ps1 -NoOpen -Port 18094 -Lang en
#>
param(
    [string]$GameDir = 'C:\Program Files (x86)\Steam\steamapps\common\Underkeep',
    [int]$Port = 18093,
    [switch]$NoOpen,
    [ValidateSet('ja', 'en')][string]$Lang
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'uksprite-core.ps1')
Initialize-Uk $GameDir $PSScriptRoot $Lang
foreach ($n in $Notes) { Write-Warning (Format-Note $n) }
$html = [IO.File]::ReadAllBytes((Join-Path $PSScriptRoot 'web\index.html'))

function Send($ctx, [byte[]]$Body, [string]$Type, [int]$Status = 200) {
    $res = $ctx.Response
    $res.StatusCode = $Status
    $res.ContentType = $Type
    $res.Headers['Cache-Control'] = 'no-store'
    $res.ContentLength64 = $Body.Length
    $res.OutputStream.Write($Body, 0, $Body.Length)
    $res.Close()
}
function SendJson($ctx, $Obj, [int]$Status = 200) {
    Send $ctx ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $Obj -Depth 4 -Compress))) 'application/json; charset=utf-8' $Status
}
function SendPng($ctx, $Bmp) {
    $ms = [IO.MemoryStream]::new()
    $Bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png); $Bmp.Dispose()
    Send $ctx $ms.ToArray() 'image/png'
}
function Find-Sprite([string]$Name) {
    $Name = [Uri]::UnescapeDataString($Name)
    $s = $ByName[$Name]
    if (-not $s) { throw [Collections.Generic.KeyNotFoundException]::new((T no_sprite $Name)) }
    return $s
}

$listener = [Net.HttpListener]::new()
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
T listening $Port $Sprites.Count
if (-not $NoOpen) { Start-Process "http://localhost:$Port/" }

try {
    while ($listener.IsListening) {
        # Poll so that Ctrl+C can interrupt between requests.
        $task = $listener.GetContextAsync()
        while (-not $task.Wait(300)) { }
        $ctx = $task.Result
        $method = $ctx.Request.HttpMethod
        $path = $ctx.Request.Url.AbsolutePath
        try {
            switch -Regex ("$method $path") {
                '^GET /$' { Send $ctx $html 'text/html; charset=utf-8'; break }
                '^GET /api/sprites$' {
                    $st = Get-StatusMap
                    SendJson $ctx @{
                        notes   = @($Notes)
                        backups = @(Get-ChildItem -LiteralPath $BackupDir -Filter *.texture.png | ForEach-Object { $_.Name -replace '\.texture\.png$' })
                        sprites = @($Sprites | ForEach-Object { @{ n = $_.Name; w = $_.W; h = $_.H; s = $st[$_.Name] } })
                    }
                    break
                }
                '^GET /img/(.+)$' { SendPng $ctx (Get-SpriteBitmap (Find-Sprite $Matches[1])); break }
                '^GET /orig/(.+)$' { SendPng $ctx (Get-SpriteBitmap (Find-Sprite $Matches[1]) -Original); break }
                '^POST /api/stage/(.+)$' {
                    $s = Find-Sprite $Matches[1]
                    $ms = [IO.MemoryStream]::new(); $ctx.Request.InputStream.CopyTo($ms); $ms.Position = 0
                    $img = [System.Drawing.Bitmap]::new($ms)
                    try { Set-Staged $s $img } finally { $img.Dispose() }
                    SendJson $ctx @{ ok = $true }
                    break
                }
                '^POST /api/commit$' {
                    $n = Invoke-Commit; $Notes.Clear()
                    T log_commit $n
                    SendJson $ctx @{ ok = $true; count = $n }
                    break
                }
                '^POST /api/restore/(.+)$' {
                    $s = Find-Sprite $Matches[1]; Restore-Sprites @($s.Name)
                    T log_restore $s.Name
                    SendJson $ctx @{ ok = $true }
                    break
                }
                '^POST /api/restore-all$' {
                    $names = @((Get-StatusMap).Keys); Restore-Sprites $names; $Notes.Clear()
                    T log_restore_all $names.Count
                    SendJson $ctx @{ ok = $true; count = $names.Count }
                    break
                }
                default { SendJson $ctx @{ error = 'not found' } 404 }
            }
        } catch [Collections.Generic.KeyNotFoundException] {
            SendJson $ctx @{ error = $_.Exception.Message } 404
        } catch {
            Write-Warning "$method $path : $($_.Exception.Message)"
            try { SendJson $ctx @{ error = $_.Exception.Message } 500 } catch { }
        }
    }
} finally {
    $listener.Stop(); $listener.Close()
}
