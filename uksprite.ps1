<#
.SYNOPSIS
Export, replace and restore Underkeep sprites (character portraits etc. packed into texture atlases).

.DESCRIPTION
  list    <name regex>              Show matching sprites: name, atlas, position, size, status
  export  <name regex> <folder>     Save matching sprites as <name>.png
  import  <folder>                  Stage every <name>.png in the folder as a draft
  commit                            Write drafts (and images lost to Steam verification) into the game
  restore [name regex]              Undo matching changes (all changes when omitted)
  For the browser UI, run uksprite-web.ps1 instead.

.EXAMPLE
  .\uksprite.ps1 export '^face_100' .\work
  # edit .\work\face_100.png without changing its size
  .\uksprite.ps1 import .\work
  .\uksprite.ps1 commit
  .\uksprite.ps1 restore
#>
param(
    [Parameter(Mandatory, Position = 0)][ValidateSet('list', 'export', 'import', 'commit', 'restore')][string]$Command,
    [Parameter(Position = 1)][string]$Arg1,
    [Parameter(Position = 2)][string]$Arg2,
    [string]$GameDir = 'C:\Program Files (x86)\Steam\steamapps\common\Underkeep',
    [ValidateSet('ja', 'en')][string]$Lang
)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'uksprite-core.ps1')
Initialize-Uk $GameDir $PSScriptRoot $Lang
foreach ($n in $Notes) { Write-Warning (Format-Note $n) }

switch ($Command) {
    'list' {
        $st = Get-StatusMap
        $Sprites | Where-Object Name -Match $Arg1 | Format-Table Name, Texture, X, Y, W, H, @{ n = 'Status'; e = { $st[$_.Name] } } -AutoSize
    }
    'export' {
        if (-not $Arg1 -or -not $Arg2) { throw (T usage_export) }
        $sel = @($Sprites | Where-Object Name -Match $Arg1)
        if (-not $sel) { throw (T no_match $Arg1) }
        New-Item -ItemType Directory -Force $Arg2 | Out-Null
        foreach ($s in $sel) {
            $bmp = Get-SpriteBitmap $s
            $bmp.Save((Join-Path $Arg2 "$($s.Name).png"), [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
        }
        T exported $sel.Count $Arg2
    }
    'import' {
        if (-not $Arg1) { throw (T usage_import) }
        $n = 0
        foreach ($f in Get-ChildItem -LiteralPath $Arg1 -Filter *.png) {
            $s = $ByName[$f.BaseName]
            if (-not $s) { Write-Warning (T unknown_file $f.Name); continue }
            $img = Open-Bitmap $f.FullName
            try { Set-Staged $s $img; $n++ } catch { Write-Warning (T skipped $_.Exception.Message) } finally { $img.Dispose() }
        }
        T staged $n
    }
    'commit' {
        T committed (Invoke-Commit)
    }
    'restore' {
        $names = @((Get-StatusMap).Keys | Where-Object { -not $Arg1 -or $_ -match $Arg1 })
        if (-not $names) { T nothing; return }
        Restore-Sprites $names
        T restored $names.Count
    }
}
