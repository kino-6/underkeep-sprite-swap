# Shared code for reading and writing Underkeep sprites. Dot-sourced by uksprite.ps1 and uksprite-web.ps1.
#
# Data folder (DataDir) layout:
#   staged\<name>.png            drafts, not yet written to the game
#   applied\<name>.png           images written to the game; used to re-apply after Steam verification etc.
#   backup\<atlas>.texture.png   original atlas, copied before the first write
#   backup\state.json            hash of each atlas right after our last write
Add-Type -AssemblyName System.Drawing

$script:Messages = @{
    ja = @{
        not_def         = '{0} は Def 形式ではない'
        bad_tag         = '{0}: 未知の型 0x{1:x2}（位置 {2}）'
        note_reset      = '{0} が元に戻っていた（Steam の検証など）。{1} 枚は反映し直せる'
        note_updated    = '{0} がゲーム側で更新されていたので、控えを今の atlas に取り替えた。{1} 枚は反映し直せる'
        bad_size        = '{0}: 大きさ {1}x{2} が元の {3}x{4} と違う'
        usage_export    = '使い方: export <名前の正規表現> <出力先>'
        usage_import    = '使い方: import <フォルダ>'
        no_match        = "'{0}' に合う sprite がない"
        exported        = '{0} 枚を {1} に書き出した'
        unknown_file    = '{0}: 同じ名前の sprite がないので飛ばす'
        skipped         = '{0}。飛ばす'
        staged          = '{0} 枚を下書きに置いた。commit でゲームに反映する'
        committed       = '{0} 枚をゲームに反映した'
        nothing         = '戻すものはない'
        restored        = '{0} 枚を元に戻した'
        listening       = 'http://localhost:{0}/ で待っている（{1} 枚）。Ctrl+C で止める'
        log_commit      = 'ゲームに反映: {0} 枚'
        log_restore     = '元に戻した: {0}'
        log_restore_all = '全部元に戻した: {0} 枚'
        no_sprite       = "sprite '{0}' がない"
    }
    en = @{
        not_def         = '{0} is not a Def database'
        bad_tag         = '{0}: unknown tag 0x{1:x2} at offset {2}'
        note_reset      = '{0} was reverted (e.g. by Steam file verification). {1} sprite(s) can be re-applied'
        note_updated    = '{0} was changed by a game update, so the backup now holds the new atlas. {1} sprite(s) can be re-applied'
        bad_size        = '{0}: size {1}x{2} does not match the original {3}x{4}'
        usage_export    = 'Usage: export <name regex> <output folder>'
        usage_import    = 'Usage: import <folder>'
        no_match        = "No sprite matches '{0}'"
        exported        = 'Exported {0} sprite(s) to {1}'
        unknown_file    = '{0}: no sprite with this name, skipped'
        skipped         = '{0}. Skipped'
        staged          = 'Staged {0} sprite(s). Run commit to write them to the game'
        committed       = 'Wrote {0} sprite(s) to the game'
        nothing         = 'Nothing to restore'
        restored        = 'Restored {0} sprite(s)'
        listening       = 'Listening on http://localhost:{0}/ ({1} sprites). Press Ctrl+C to stop'
        log_commit      = 'Committed {0} sprite(s)'
        log_restore     = 'Restored {0}'
        log_restore_all = 'Restored all: {0} sprite(s)'
        no_sprite       = "No sprite named '{0}'"
    }
}
$script:UkLang = if ((Get-Culture).Name -like 'ja*') { 'ja' } else { 'en' }

function T([string]$Key) {
    <# Returns the message for $Key in the current language, formatted with the remaining arguments. #>
    $f = $script:Messages[$script:UkLang][$Key]
    if ($args.Count) { return $f -f $args } else { return $f }
}

function Format-Note($Note) { T "note_$($Note.code)" $Note.atlas $Note.count }

function Read-DefDb([string]$Path) {
    <# Parses a ff 'Def' database file into PowerShell objects. #>
    $d = [IO.File]::ReadAllBytes($Path)
    if ($d[0] -ne 0xff -or [Text.Encoding]::ASCII.GetString($d, 1, 3) -ne 'Def') { throw (T not_def $Path) }
    $so = [BitConverter]::ToInt32($d, 5)
    $n = [BitConverter]::ToInt32($d, $so)
    $p = $so + 4
    $strs = [string[]]::new($n)
    for ($i = 0; $i -lt $n; $i++) {
        $ln = $d[$p]; $p++
        $strs[$i] = [Text.Encoding]::UTF8.GetString($d, $p, $ln); $p += $ln
    }
    $script:pos = 16
    function val {
        $t = $d[$script:pos]; $script:pos++
        switch ($t) {
            0x00 { return $null }
            0x01 { $v = $d[$script:pos]; $script:pos += 1; return [int]$v }
            0x02 { $v = [BitConverter]::ToInt16($d, $script:pos); $script:pos += 2; return [int]$v }
            0x03 { $v = [BitConverter]::ToInt32($d, $script:pos); $script:pos += 4; return $v }
            0x04 { $v = [BitConverter]::ToSingle($d, $script:pos); $script:pos += 4; return $v }
            0x05 { $v = $d[$script:pos]; $script:pos += 1; return $strs[$v] }
            0x06 {
                $v = 0; $sh = 0
                do { $b = $d[$script:pos]; $script:pos++; $v = $v -bor (($b -band 0x7f) -shl $sh); $sh += 7 } while ($b -ge 0x80)
                return $strs[$v]
            }
            0x07 {
                $c = [BitConverter]::ToInt32($d, $script:pos); $script:pos += 4
                $a = [object[]]::new($c)
                for ($k = 0; $k -lt $c; $k++) { $a[$k] = val }
                return , $a
            }
            0x08 {
                $c = [BitConverter]::ToInt32($d, $script:pos); $script:pos += 4
                $o = [ordered]@{}
                for ($k = 0; $k -lt $c; $k++) { $key = val; $o["$key"] = val }
                return $o
            }
            default { throw (T bad_tag $Path $t ($script:pos - 1)) }
        }
    }
    return , (val)
}

function Initialize-Uk([string]$GameDir, [string]$DataDir, [string]$Lang) {
    <# Loads the sprite table and our records, and reconciles them with the game's atlases.
       Each reconciliation is recorded in $Notes as @{ code; atlas; count }. #>
    if ($Lang) { $script:UkLang = $Lang }
    $script:Base = Join-Path $GameDir 'base'
    $script:StagedDir = Join-Path $DataDir 'staged'
    $script:AppliedDir = Join-Path $DataDir 'applied'
    $script:BackupDir = Join-Path $DataDir 'backup'
    $script:StatePath = Join-Path $script:BackupDir 'state.json'
    foreach ($d in $script:StagedDir, $script:AppliedDir, $script:BackupDir) { New-Item -ItemType Directory -Force $d | Out-Null }
    $script:AtlasCache = @{}
    $script:Notes = [Collections.Generic.List[object]]::new()
    $script:Sprites = foreach ($e in (Read-DefDb (Join-Path $script:Base '_sprite.db'))) {
        $m = $e['metadata']
        if (-not $m -or -not $m['rect'] -or -not $m['texture']) { continue }
        $r = $m['rect']
        if ($r[2] -le 0 -or -not (Test-Path (Join-Path $script:Base "$($m['texture']).texture.png"))) { continue }
        [pscustomobject]@{ Name = $e['name']; Texture = $m['texture']; X = [int]$r[0]; Y = [int]$r[1]; W = [int]$r[2]; H = [int]$r[3] }
    }
    $script:ByName = @{}
    foreach ($s in $script:Sprites) { $script:ByName[$s.Name] = $s }

    $script:State = @{}
    if (Test-Path $script:StatePath) { (Get-Content $script:StatePath -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $script:State[$_.Name] = $_.Value } }
    $script:Live = [Collections.Generic.HashSet[string]]::new()   # atlases that still contain our applied images
    foreach ($tex in @($script:State.Keys)) {
        $cur = AtlasPath $tex; $bak = BackupPath $tex
        $h = (Get-FileHash $cur).Hash
        if ($h -eq $script:State[$tex]) { [void]$script:Live.Add($tex); continue }
        $n = @(Get-Names $script:AppliedDir | Where-Object { $script:ByName[$_].Texture -eq $tex }).Count
        if ((Test-Path $bak) -and $h -eq (Get-FileHash $bak).Hash) {
            $script:Notes.Add(@{ code = 'reset'; atlas = $tex; count = $n })
        } else {
            # The game shipped a new atlas; restoring the old backup would break it.
            Copy-Item -LiteralPath $cur $bak -Force
            $script:Notes.Add(@{ code = 'updated'; atlas = $tex; count = $n })
        }
        $script:State.Remove($tex)
    }
    # Backups of atlases with no applied images are no longer needed.
    foreach ($bak in Get-ChildItem -LiteralPath $script:BackupDir -Filter *.texture.png) {
        $tex = $bak.Name -replace '\.texture\.png$'
        if (-not $script:Live.Contains($tex) -and -not (Get-Names $script:AppliedDir | Where-Object { $script:ByName[$_].Texture -eq $tex })) { Remove-Item -LiteralPath $bak.FullName }
    }
    Save-State
}

function AtlasPath([string]$Tex) { Join-Path $script:Base "$Tex.texture.png" }
function BackupPath([string]$Tex) { Join-Path $script:BackupDir "$Tex.texture.png" }
function Get-Names([string]$Dir) { Get-ChildItem -LiteralPath $Dir -Filter *.png | ForEach-Object BaseName | Where-Object { $script:ByName[$_] } }
function Save-State { ConvertTo-Json $script:State | Set-Content $script:StatePath -Encoding utf8 }

function Get-StatusMap {
    <# Returns name -> 'staged' | 'applied' | 'lost' for every changed sprite.
       'lost' means it was applied but the game's atlas no longer contains it. #>
    $map = @{}
    foreach ($n in Get-Names $script:AppliedDir) { $map[$n] = $(if ($script:Live.Contains($script:ByName[$n].Texture)) { 'applied' } else { 'lost' }) }
    foreach ($n in Get-Names $script:StagedDir) { $map[$n] = 'staged' }
    return $map
}

function Open-Bitmap([string]$Path) {
    <# Returns a copy of the image so the file is not kept locked. #>
    $img = [System.Drawing.Image]::FromFile($Path)
    try { return [System.Drawing.Bitmap]::new($img) } finally { $img.Dispose() }
}

function Copy-Pixels($Src, $SrcRect, $Dst, [int]$DstX, [int]$DstY) {
    <# Copies pixels as-is, alpha included (no blending). #>
    $g = [System.Drawing.Graphics]::FromImage($Dst)
    try {
        $g.CompositingMode = 'SourceCopy'
        $g.InterpolationMode = 'NearestNeighbor'
        $g.PixelOffsetMode = 'Half'
        $g.DrawImage($Src, [System.Drawing.Rectangle]::new($DstX, $DstY, $SrcRect.Width, $SrcRect.Height), $SrcRect, 'Pixel')
    } finally { $g.Dispose() }
}

function Get-Atlas([string]$Tex, [switch]$Original) {
    <# Loads and caches an atlas. -Original reads the backup when there is one. #>
    $path = if ($Original -and (Test-Path (BackupPath $Tex))) { BackupPath $Tex } else { AtlasPath $Tex }
    if (-not $script:AtlasCache[$path]) { $script:AtlasCache[$path] = Open-Bitmap $path }
    return $script:AtlasCache[$path]
}

function Get-SpriteBitmap($Sprite, [switch]$Original, [switch]$Game) {
    <# Returns one sprite as a Bitmap: the draft if there is one, otherwise what the game has.
       -Game skips the draft; -Original returns the unmodified image. #>
    $staged = Join-Path $script:StagedDir "$($Sprite.Name).png"
    if (-not $Original -and -not $Game -and (Test-Path $staged)) { return Open-Bitmap $staged }
    $bmp = [System.Drawing.Bitmap]::new($Sprite.W, $Sprite.H, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    Copy-Pixels (Get-Atlas $Sprite.Texture -Original:$Original) ([System.Drawing.Rectangle]::new($Sprite.X, $Sprite.Y, $Sprite.W, $Sprite.H)) $bmp 0 0
    return $bmp
}

function Set-Staged($Sprite, $Image) {
    <# Saves an image as a draft. Throws if its size differs from the sprite. #>
    if ($Image.Width -ne $Sprite.W -or $Image.Height -ne $Sprite.H) { throw (T bad_size $Sprite.Name $Image.Width $Image.Height $Sprite.W $Sprite.H) }
    $Image.Save((Join-Path $script:StagedDir "$($Sprite.Name).png"), [System.Drawing.Imaging.ImageFormat]::Png)
}

function Invoke-Commit {
    <# Writes all drafts and lost images into the game's atlases, backing up each atlas before its first write.
       Returns the number of sprites written. #>
    $st = Get-StatusMap
    $names = @($st.Keys | Where-Object { $st[$_] -ne 'applied' })
    foreach ($grp in $names | ForEach-Object { $script:ByName[$_] } | Group-Object Texture) {
        $tex = $grp.Name; $path = AtlasPath $tex
        if (-not (Test-Path (BackupPath $tex))) { Copy-Item -LiteralPath $path (BackupPath $tex) }
        $atlas = Get-Atlas $tex
        # When the atlas was reverted, put back every applied image of that atlas too.
        $all = @($grp.Group.Name)
        if (-not $script:Live.Contains($tex)) { $all += @(Get-Names $script:AppliedDir | Where-Object { $script:ByName[$_].Texture -eq $tex }) }
        foreach ($n in $all | Sort-Object -Unique) {
            $s = $script:ByName[$n]
            $staged = Join-Path $script:StagedDir "$n.png"; $applied = Join-Path $script:AppliedDir "$n.png"
            if (Test-Path $staged) { Move-Item -LiteralPath $staged $applied -Force }
            $img = Open-Bitmap $applied
            try { Copy-Pixels $img ([System.Drawing.Rectangle]::new(0, 0, $s.W, $s.H)) $atlas $s.X $s.Y } finally { $img.Dispose() }
        }
        $atlas.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        $script:State[$tex] = (Get-FileHash $path).Hash
        [void]$script:Live.Add($tex)
    }
    Save-State
    return $names.Count
}

function Restore-Sprites([string[]]$Names) {
    <# Discards drafts and puts the original pixels back for applied sprites.
       When an atlas has no changes left, the backup is copied back whole and removed. #>
    foreach ($n in $Names) { Remove-Item -LiteralPath (Join-Path $script:StagedDir "$n.png") -ErrorAction SilentlyContinue }
    $targets = @($Names | Where-Object { Test-Path (Join-Path $script:AppliedDir "$_.png") } | ForEach-Object { $script:ByName[$_] })
    foreach ($grp in $targets | Group-Object Texture) {
        $tex = $grp.Name; $path = AtlasPath $tex; $bak = BackupPath $tex
        foreach ($s in $grp.Group) { Remove-Item -LiteralPath (Join-Path $script:AppliedDir "$($s.Name).png") }
        $left = @(Get-Names $script:AppliedDir | Where-Object { $script:ByName[$_].Texture -eq $tex })
        if ($left.Count -eq 0) {
            if ($script:Live.Contains($tex)) { Copy-Item -LiteralPath $bak $path -Force }
            $script:AtlasCache.Remove($path); $script:AtlasCache.Remove($bak)
            Remove-Item -LiteralPath $bak -ErrorAction SilentlyContinue
            $script:State.Remove($tex); [void]$script:Live.Remove($tex)
        } elseif ($script:Live.Contains($tex)) {
            $atlas = Get-Atlas $tex; $orig = Get-Atlas $tex -Original
            foreach ($s in $grp.Group) { Copy-Pixels $orig ([System.Drawing.Rectangle]::new($s.X, $s.Y, $s.W, $s.H)) $atlas $s.X $s.Y }
            $atlas.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
            $script:State[$tex] = (Get-FileHash $path).Hash
        }
    }
    Save-State
}
