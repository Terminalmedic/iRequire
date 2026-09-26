# ==============================================================
#  WinPE\Disk.ps1 - levyjen tunnistus, tyhjennys ja varmistus
#
#  WinPE:ssa ei ole C#-kaantajaa, joten Add-Type ei toimi. Win32-kutsut
#  maaritellaan siksi Reflection.Emitilla ajonaikaisesti.
#
#  Tyhjennysmenetelmat:
#   - Flash (NVMe, SSD, eMMC): ensin laitteen oma tyhjennys
#     (IOCTL_STORAGE_REINITIALIZE_MEDIA, NVMe:lla kryptografinen).
#     Tulos varmistetaan aina lukemalla. Jos laite ei tue komentoa tai
#     varmistus ei mene lapi, siirrytaan ylikirjoitukseen + TRIMiin.
#   - HDD: koko levy nollilla + lukuvarmistus.
#   - Tuntematon (virtuaalikoneet, osa RAID-ohjaimista): nollat + TRIM.
#
#  Varmistus: ennen tyhjennysta luetaan satunnaiset naytteet ja
#  tyhjennyksen jalkeen samat kohdat uudelleen. Valinnaisesti koko levy
#  luetaan takaisin (Tyhjennys.TaysiVarmistus).
# ==============================================================

$script:Native = $null
$script:SampleBytes = 65536

function Initialize-Native {
    if ($script:Native) { return $script:Native }

    $asmName = New-Object System.Reflection.AssemblyName 'iRequireNative'
    $asm = [AppDomain]::CurrentDomain.DefineDynamicAssembly($asmName, [System.Reflection.Emit.AssemblyBuilderAccess]::Run)
    $mod = $asm.DefineDynamicModule('iRequireNative')
    $tb = $mod.DefineType('iRequire.Native', 'Public, Class')

    $dllImportCtor = [System.Runtime.InteropServices.DllImportAttribute].GetConstructor([Type[]]@([string]))
    $setLastError = [System.Runtime.InteropServices.DllImportAttribute].GetField('SetLastError')

    $defs = @(
        @{ Name = 'CreateFileW'; Ret = [Microsoft.Win32.SafeHandles.SafeFileHandle]
           Args = [Type[]]@([string], [uint32], [uint32], [IntPtr], [uint32], [uint32], [IntPtr]) },
        @{ Name = 'DeviceIoControl'; Ret = [bool]
           Args = [Type[]]@([Microsoft.Win32.SafeHandles.SafeFileHandle], [uint32], [byte[]], [uint32],
                            [byte[]], [uint32], [uint32].MakeByRefType(), [IntPtr]) }
    )
    foreach ($d in $defs) {
        $m = $tb.DefinePInvokeMethod($d.Name, 'kernel32.dll',
            [System.Reflection.MethodAttributes]'Public, Static, PinvokeImpl',
            [System.Reflection.CallingConventions]::Standard, $d.Ret, $d.Args,
            [System.Runtime.InteropServices.CallingConvention]::Winapi,
            [System.Runtime.InteropServices.CharSet]::Unicode)
        $m.SetImplementationFlags('PreserveSig')
        $cab = New-Object System.Reflection.Emit.CustomAttributeBuilder($dllImportCtor, @('kernel32.dll'),
            [System.Reflection.FieldInfo[]]@($setLastError), [object[]]@($true))
        $m.SetCustomAttribute($cab)
    }
    $script:Native = $tb.CreateType()
    return $script:Native
}

function Open-RawDisk {
    <# Palauttaa FileStreamin suoraan fyysiseen levyyn. .NET ei itse suostu
       avaamaan \\.\PhysicalDriveN -polkuja, joten kahva haetaan CreateFileW:lla.
       Puskurikoko 1 = FileStream ei puskuroi, jokainen Write menee levylle. #>
    param([Parameter(Mandatory)][int]$Number, [switch]$Write)

    $native = Initialize-Native
    $GENERIC_READ = [uint32]'0x80000000'
    $GENERIC_WRITE = [uint32]'0x40000000'
    $FILE_FLAG_WRITE_THROUGH = [uint32]'0x80000000'
    $access = if ($Write) { $GENERIC_READ -bor $GENERIC_WRITE } else { $GENERIC_READ }
    $flags = if ($Write) { $FILE_FLAG_WRITE_THROUGH } else { [uint32]0 }

    $handle = $native::CreateFileW("\\.\PhysicalDrive$Number", $access, [uint32]3, [IntPtr]::Zero, [uint32]3, $flags, [IntPtr]::Zero)
    if ($handle.IsInvalid) {
        $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
        throw "Levyn $Number avaaminen epaonnistui (Win32-virhe $err)"
    }
    $mode = if ($Write) { [System.IO.FileAccess]::ReadWrite } else { [System.IO.FileAccess]::Read }
    return New-Object System.IO.FileStream($handle, $mode, 1)
}

function Read-Exact {
    <# Lukee tasmalleen $Count tavua tai heittaa poikkeuksen. #>
    param([Parameter(Mandatory)]$Stream, [Parameter(Mandatory)][byte[]]$Buffer, [int]$Count = $Buffer.Length)
    $read = 0
    while ($read -lt $Count) {
        $n = $Stream.Read($Buffer, $read, $Count - $read)
        if ($n -le 0) { throw "Levy loppui kesken lukemisen ($read/$Count tavua)" }
        $read += $n
    }
}

# ==============================================================
#  Tunnistus
# ==============================================================

function Get-UsbBootDiskNumber {
    param([Parameter(Mandatory)][string]$UsbRoot)
    $letter = $UsbRoot.Substring(0, 1)
    try { return (Get-Partition -DriveLetter $letter -ErrorAction Stop).DiskNumber } catch { return -1 }
}

function Get-DiskClass {
    <# Paattaa kuuluuko levy tyhjennettaviin ja minka tyyppinen se on.
       Puhdas funktio, jotta saannot voidaan testata ilman levyja.

       eMMC-levyt nakyvat vaylana SD tai MMC. Halvoissa lapareissa se on
       ainoa sisainen levy, joten se otetaan mukaan, jos Windows pitaa sita
       kiinteana. Muistikortit ja ulkoiset levyt jatetaan aina rauhaan. #>
    param(
        [string]$BusType,
        [string]$MediaType,
        [string]$DriveMediaType,
        [int64]$Size
    )
    if ($Size -le 0) { return [pscustomobject]@{ Include = $false; Kind = ''; Reason = 'ei tallennusmediaa' } }
    switch ($BusType) {
        'USB'                 { return [pscustomobject]@{ Include = $false; Kind = ''; Reason = 'ulkoinen USB-levy' } }
        '1394'                { return [pscustomobject]@{ Include = $false; Kind = ''; Reason = 'ulkoinen FireWire-levy' } }
        'iSCSI'               { return [pscustomobject]@{ Include = $false; Kind = ''; Reason = 'verkkolevy' } }
        'Virtual'             { return [pscustomobject]@{ Include = $false; Kind = ''; Reason = 'virtuaalilevy' } }
        'File Backed Virtual' { return [pscustomobject]@{ Include = $false; Kind = ''; Reason = 'virtuaalilevy' } }
    }
    if ($DriveMediaType -like 'External*' -or $DriveMediaType -like 'Removable*') {
        if ($BusType -in @('SD', 'MMC')) {
            return [pscustomobject]@{ Include = $false; Kind = ''; Reason = 'muistikortti' }
        }
        return [pscustomobject]@{ Include = $false; Kind = ''; Reason = 'irrotettava levy' }
    }
    if ($BusType -in @('SD', 'MMC')) {
        if ($DriveMediaType -like 'Fixed*') { return [pscustomobject]@{ Include = $true; Kind = 'eMMC'; Reason = '' } }
        return [pscustomobject]@{ Include = $false; Kind = ''; Reason = 'muistikortti' }
    }
    $kind = if ($BusType -eq 'NVMe') { 'NVMe' }
            elseif ($MediaType -eq 'SSD') { 'SSD' }
            elseif ($MediaType -eq 'HDD') { 'HDD' }
            else { 'Tuntematon' }
    return [pscustomobject]@{ Include = $true; Kind = $kind; Reason = '' }
}

function Test-FlashKind {
    param([string]$Kind)
    return ($Kind -in @('NVMe', 'SSD', 'eMMC'))
}

function Get-DiskInventory {
    <# Kaikki levyt luokiteltuina. Palauttaa seka tyhjennettavat etta
       rauhaan jatettavat, jotta laskuri voi nayttaa molemmat. #>
    param([int]$ExcludeNumber = -1)

    $physical = @{}
    foreach ($p in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) { $physical[[string]$p.DeviceId] = $p }
    $drives = @{}
    foreach ($w in @(Get-CimInstance Win32_DiskDrive -ErrorAction SilentlyContinue)) { $drives[[string]$w.Index] = $w }

    $internal = New-Object System.Collections.Generic.List[object]
    $skipped = New-Object System.Collections.Generic.List[object]
    foreach ($d in @(Get-Disk | Sort-Object Number)) {
        $pd = $physical[[string]$d.Number]
        $wd = $drives[[string]$d.Number]
        $info = [pscustomobject]@{
            Number    = [int]$d.Number
            Model     = ([string]$d.FriendlyName).Trim()
            Serial    = ([string]$d.SerialNumber).Trim()
            Size      = [int64]$d.Size
            Bus       = [string]$d.BusType
            Kind      = ''
            Partition = [string]$d.PartitionStyle
            Sector    = [int]$d.LogicalSectorSize
            Reason    = ''
        }
        if ($d.Number -eq $ExcludeNumber) {
            $info.Reason = 'iRequire-tikku'
            $skipped.Add($info)
            continue
        }
        $media = if ($pd) { [string]$pd.MediaType } else { '' }
        $driveMedia = if ($wd) { [string]$wd.MediaType } else { '' }
        $class = Get-DiskClass -BusType $info.Bus -MediaType $media -DriveMediaType $driveMedia -Size $info.Size
        if ($class.Include) {
            $info.Kind = $class.Kind
            $internal.Add($info)
        } else {
            $info.Reason = $class.Reason
            $skipped.Add($info)
        }
    }
    return [pscustomobject]@{ Internal = $internal.ToArray(); Skipped = $skipped.ToArray() }
}

function Get-DiskContentSummary {
    <# Kerrotaan laskurin aikana mita levylla on, jotta vaara kone
       tunnistetaan ennen kuin on myohaista. Paras yritys: virhe ei haittaa. #>
    param([Parameter(Mandatory)][int]$Number)

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($p in @(Get-Partition -DiskNumber $Number -ErrorAction SilentlyContinue)) {
        $vol = $null
        try { $vol = $p | Get-Volume -ErrorAction Stop } catch { }
        $fs = if ($vol -and $vol.FileSystem) { $vol.FileSystem } else { 'ei tunnistettu (salattu?)' }
        $label = if ($vol -and $vol.FileSystemLabel) { '"' + $vol.FileSystemLabel + '"' } else { '' }
        $used = ''
        if ($vol -and $vol.Size -gt 0) { $used = ('kaytossa {0}' -f (Format-Size ($vol.Size - $vol.SizeRemaining))) }
        $lines.Add(('osio {0}: {1} {2} {3} {4}' -f $p.PartitionNumber, (Format-Size $p.Size), $fs, $label, $used).TrimEnd())

        if ($p.DriveLetter -and [char]::IsLetter($p.DriveLetter)) {
            $root = "$($p.DriveLetter):\"
            $hive = Join-Path $root 'Windows\System32\config\SOFTWARE'
            if (Test-Path -LiteralPath $hive) {
                $lines.Add('   -> Windows-asennus: ' + (Get-OfflineWindowsInfo -Root $root))
            }
            $users = Join-Path $root 'Users'
            if (Test-Path -LiteralPath $users) {
                $names = @(Get-ChildItem -LiteralPath $users -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -notin @('Public', 'Default', 'Default User', 'All Users', 'defaultuser0') } |
                    ForEach-Object { $_.Name })
                if ($names.Count -gt 0) { $lines.Add('   -> kayttajat: ' + ($names -join ', ')) }
            }
        }
    }
    if ($lines.Count -eq 0) { $lines.Add('ei osioita (tyhja tai tuntematon levy)') }
    return ,$lines
}

function Get-OfflineWindowsInfo {
    param([Parameter(Mandatory)][string]$Root)
    $mount = 'HKLM\iRequireInfo'
    $info = 'tunnistamaton versio'
    try {
        & reg.exe load $mount (Join-Path $Root 'Windows\System32\config\SOFTWARE') 2>&1 | Out-Null
        $cv = Get-ItemProperty -LiteralPath 'Registry::HKEY_LOCAL_MACHINE\iRequireInfo\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
        $info = '{0} (koontiversio {1})' -f $cv.ProductName, $cv.CurrentBuild
        $cv = $null
    } catch {
    } finally {
        [GC]::Collect()
        & reg.exe unload $mount 2>&1 | Out-Null
    }
    try {
        & reg.exe load $mount (Join-Path $Root 'Windows\System32\config\SYSTEM') 2>&1 | Out-Null
        $cn = Get-ItemProperty -LiteralPath 'Registry::HKEY_LOCAL_MACHINE\iRequireInfo\ControlSet001\Control\ComputerName\ComputerName' -ErrorAction Stop
        if ($cn.ComputerName) { $info += ', koneen nimi ' + $cn.ComputerName }
        $cn = $null
    } catch {
    } finally {
        [GC]::Collect()
        & reg.exe unload $mount 2>&1 | Out-Null
    }
    return $info
}

# ==============================================================
#  Naytteet ja varmistus
# ==============================================================

function Get-SampleOffsets {
    <# Alku, loppu ja satunnaiset kohdat 4 KiB:n rajoille tasattuna. #>
    param([Parameter(Mandatory)][int64]$Size, [int]$Count = 256)
    $max = [int64][Math]::Floor(($Size - $script:SampleBytes) / 4096)
    $rnd = New-Object System.Random
    $set = New-Object 'System.Collections.Generic.SortedSet[int64]'
    [void]$set.Add(0)
    [void]$set.Add($max * 4096)
    while ($set.Count -lt [Math]::Min($Count, $max + 1)) {
        $block = [int64]($rnd.NextDouble() * $max)
        [void]$set.Add($block * 4096)
    }
    return [int64[]]@($set)
}

function Read-DiskSamples {
    <# Lukee naytteet. Lukuvirhe ei kaada: nayte merkitaan virheelliseksi,
       ja varmistus hylkaa sen myohemmin. #>
    param([Parameter(Mandatory)][int]$Number, [Parameter(Mandatory)][int64[]]$Offsets)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $buf = New-Object byte[] $script:SampleBytes
    # Nollatarkistus tiivisteella: tavu kerrallaan PowerShellissa olisi hidas.
    $zeroHash = [BitConverter]::ToString($sha.ComputeHash((New-Object byte[] $script:SampleBytes)))
    $out = New-Object System.Collections.Generic.List[object]
    $fs = Open-RawDisk -Number $Number
    try {
        foreach ($o in $Offsets) {
            try {
                [void]$fs.Seek($o, 'Begin')
                Read-Exact -Stream $fs -Buffer $buf
                $hash = [BitConverter]::ToString($sha.ComputeHash($buf))
                $out.Add([pscustomobject]@{ Offset = $o; Hash = $hash; Zero = ($hash -eq $zeroHash); Error = $false })
            } catch {
                $out.Add([pscustomobject]@{ Offset = $o; Hash = ''; Zero = $false; Error = $true })
            }
        }
    } finally {
        $fs.Dispose()
    }
    return ,$out
}

function Test-WipeResult {
    <# Overwrite: jokaisen nayteen on oltava luettavissa ja nollaa.
       Firmware: jokaisen nayteen on oltava luettavissa, ja jokaisen ennen
       tyhjennysta dataa sisaltaneen nayteen on oltava muuttunut. #>
    param(
        [Parameter(Mandatory)]$Before,
        [Parameter(Mandatory)]$After,
        [ValidateSet('Overwrite', 'Firmware')][string]$Method
    )
    $bad = 0
    $unreadable = 0
    for ($i = 0; $i -lt $After.Count; $i++) {
        if ($After[$i].Error) { $bad++; $unreadable++; continue }
        if ($Method -eq 'Overwrite') {
            if (-not $After[$i].Zero) { $bad++ }
        } elseif (-not $Before[$i].Error -and -not $Before[$i].Zero -and $Before[$i].Hash -eq $After[$i].Hash) {
            $bad++
        }
    }
    $hadData = @($Before | Where-Object { -not $_.Zero -and -not $_.Error }).Count
    return [pscustomobject]@{
        Ok         = ($bad -eq 0)
        Samples    = $After.Count
        Failed     = $bad
        Unreadable = $unreadable
        HadData    = $hadData
    }
}

function Wait-DiskReadable {
    <# NVMe Sanitize voi jatkua laitteen sisalla viela kun komento on
       palannut; sen aikana luku epaonnistuu. Odotetaan kunnes levy vastaa. #>
    param([Parameter(Mandatory)][int]$Number, [int]$TimeoutMinutes = 120)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $buf = New-Object byte[] 4096
    $first = $true
    while ((Get-Date) -lt $deadline) {
        try {
            $fs = Open-RawDisk -Number $Number
            try {
                Read-Exact -Stream $fs -Buffer $buf
                return $true
            } finally { $fs.Dispose() }
        } catch {
            if ($first) { Write-IRequireLog ("Levy {0}: tyhjennys kaynnissa laitteen sisalla, odotetaan..." -f $Number); $first = $false }
            Start-Sleep -Seconds 5
        }
    }
    return $false
}

function Test-DiskAllZero {
    <# Taysi takaisinluku: koko levy luetaan ja jokaisen palan on oltava nollaa. #>
    param([Parameter(Mandatory)][int]$Number, [Parameter(Mandatory)][int64]$Size)
    $chunk = 4MB
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $buf = New-Object byte[] $chunk
    $zeroHash = [BitConverter]::ToString($sha.ComputeHash((New-Object byte[] $chunk)))
    $nonZero = 0
    $errors = 0
    $done = [int64]0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastShown = -10.0
    $fs = Open-RawDisk -Number $Number
    try {
        while ($done -lt $Size) {
            $n = [int][Math]::Min([int64]$chunk, $Size - $done)
            try {
                [void]$fs.Seek($done, 'Begin')
                Read-Exact -Stream $fs -Buffer $buf -Count $n
                if ($n -eq $chunk) {
                    if ([BitConverter]::ToString($sha.ComputeHash($buf)) -ne $zeroHash) { $nonZero++ }
                } else {
                    $tailZero = [BitConverter]::ToString($sha.ComputeHash((New-Object byte[] $n)))
                    if ([BitConverter]::ToString($sha.ComputeHash($buf, 0, $n)) -ne $tailZero) { $nonZero++ }
                }
            } catch {
                $errors++
            }
            $done += $n
            $t = $sw.Elapsed.TotalSeconds
            if ($t - $lastShown -ge 2) {
                $lastShown = $t
                $pct = 100.0 * $done / $Size
                Write-Progress -Activity "Levy ${Number}: koko levyn takaisinluku" -Status ('{0:N1} %' -f $pct) -PercentComplete ([int]$pct)
            }
        }
    } finally {
        $fs.Dispose()
        Write-Progress -Activity "Levy ${Number}: koko levyn takaisinluku" -Completed
    }
    return [pscustomobject]@{ Ok = ($nonZero -eq 0 -and $errors -eq 0); NonZero = $nonZero; Errors = $errors }
}

# ==============================================================
#  Tyhjennys
# ==============================================================

function Clear-DiskLayout {
    param([Parameter(Mandatory)][int]$Number)
    $d = Get-Disk -Number $Number
    if ($d.IsReadOnly) { Set-Disk -Number $Number -IsReadOnly $false }
    if ($d.IsOffline) { Set-Disk -Number $Number -IsOffline $false }
    if ($d.PartitionStyle -ne 'RAW') {
        Clear-Disk -Number $Number -RemoveData -RemoveOEM -Confirm:$false
    }
}

function Invoke-FirmwareErase {
    <# IOCTL_STORAGE_REINITIALIZE_MEDIA. WinPE:ssa sallittu myos
       kaynnistyslevylle. NVMe:lla pyydetaan kryptografista tyhjennysta. #>
    param([Parameter(Mandatory)][int]$Number, [Parameter(Mandatory)][string]$Kind)

    $native = Initialize-Native
    $IOCTL_STORAGE_REINITIALIZE_MEDIA = [uint32]'0x002D9640'

    # STORAGE_REINITIALIZE_MEDIA: Version, Size, TimeoutInSeconds, SanitizeOption
    $inBuf = New-Object byte[] 16
    [BitConverter]::GetBytes([uint32]16).CopyTo($inBuf, 0)
    [BitConverter]::GetBytes([uint32]16).CopyTo($inBuf, 4)
    [BitConverter]::GetBytes([uint32]3600).CopyTo($inBuf, 8)
    $sanitize = if ($Kind -eq 'NVMe') { [uint32]2 } else { [uint32]0 }   # 2 = CryptoErase
    [BitConverter]::GetBytes($sanitize).CopyTo($inBuf, 12)

    $fs = Open-RawDisk -Number $Number -Write
    try {
        $returned = [uint32]0
        $ok = $native::DeviceIoControl($fs.SafeFileHandle, $IOCTL_STORAGE_REINITIALIZE_MEDIA,
            $inBuf, [uint32]$inBuf.Length, $null, [uint32]0, [ref]$returned, [IntPtr]::Zero)
        if (-not $ok) {
            # Vanhemmat ajurit eivat hyvaksy parametrirakennetta: yritetaan ilman.
            $ok = $native::DeviceIoControl($fs.SafeFileHandle, $IOCTL_STORAGE_REINITIALIZE_MEDIA,
                $null, [uint32]0, $null, [uint32]0, [ref]$returned, [IntPtr]::Zero)
        }
        if (-not $ok) {
            $err = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
            return [pscustomobject]@{ Ok = $false; Error = "Win32-virhe $err" }
        }
        return [pscustomobject]@{ Ok = $true; Error = '' }
    } finally {
        $fs.Dispose()
    }
}

function Write-ZeroRange {
    <# Kirjoittaa yhden alueen. Palauttaa $true jos onnistui. #>
    param($Stream, [byte[]]$Buffer, [int64]$Offset, [int]$Count)
    try {
        [void]$Stream.Seek($Offset, 'Begin')
        $Stream.Write($Buffer, 0, $Count)
        return $true
    } catch {
        return $false
    }
}

function Invoke-ZeroOverwrite {
    <# Kirjoittaa koko levyn nollilla 4 MiB:n paloina. Jos pala ei mene
       levylle, se yritetaan 64 KiB:n osissa; ne osat joita ei saada
       kirjoitettua kirjataan viallisiksi alueiksi. Viallisia alueita ei
       voi tyhjentaa, joten ne hylkaavat levyn varmistuksen. #>
    param([Parameter(Mandatory)][int]$Number, [Parameter(Mandatory)][int64]$Size, [int]$MaxBadRanges = 256)

    $chunk = 4MB
    $small = 64KB
    $buf = New-Object byte[] $chunk
    $bad = New-Object System.Collections.Generic.List[string]
    $fs = Open-RawDisk -Number $Number -Write
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastShown = -10.0
    try {
        $done = [int64]0
        while ($done -lt $Size) {
            $n = [int][Math]::Min([int64]$chunk, $Size - $done)
            if (-not (Write-ZeroRange -Stream $fs -Buffer $buf -Offset $done -Count $n)) {
                for ($o = [int64]0; $o -lt $n; $o += $small) {
                    $m = [int][Math]::Min([int64]$small, $n - $o)
                    if (-not (Write-ZeroRange -Stream $fs -Buffer $buf -Offset ($done + $o) -Count $m)) {
                        $bad.Add(('{0}-{1}' -f ($done + $o), ($done + $o + $m - 1)))
                        Write-IRequireLog ("Levy {0}: kirjoitusvirhe kohdassa {1}" -f $Number, ($done + $o)) 'Varoitus'
                        if ($bad.Count -ge $MaxBadRanges) {
                            throw "Levylla $Number on yli $MaxBadRanges viallista aluetta. Levy on hajoamassa."
                        }
                    }
                }
            }
            $done += $n
            $t = $sw.Elapsed.TotalSeconds
            if ($t - $lastShown -ge 2 -or $done -eq $Size) {
                $lastShown = $t
                $pct = 100.0 * $done / $Size
                $speed = if ($t -gt 0) { $done / $t } else { 0 }
                $eta = if ($speed -gt 0) { [TimeSpan]::FromSeconds(($Size - $done) / $speed) } else { [TimeSpan]::Zero }
                Write-Progress -Activity "Levy $Number ylikirjoitetaan nollilla" `
                    -Status ('{0:N1} %  {1}/s  jaljella {2:hh\:mm\:ss}' -f $pct, (Format-Size $speed), $eta) `
                    -PercentComplete ([int]$pct)
            }
        }
        $fs.Flush()
    } finally {
        $fs.Dispose()
        Write-Progress -Activity "Levy $Number ylikirjoitetaan nollilla" -Completed
    }
    return [pscustomobject]@{ Elapsed = $sw.Elapsed; BadRanges = $bad.ToArray() }
}

function Invoke-FullDiskTrim {
    <# Flash-levyn viimeistely: NTFS-pikaalustus lahettaa TRIMin koko osion
       alueelle, jolloin ohjain vapauttaa myos kayttajalle nakymattomia
       lohkoja. Lopuksi osiotaulu poistetaan. #>
    param([Parameter(Mandatory)][int]$Number)
    try {
        Initialize-Disk -Number $Number -PartitionStyle GPT -ErrorAction Stop
        $p = New-Partition -DiskNumber $Number -UseMaximumSize -ErrorAction Stop
        $p | Format-Volume -FileSystem NTFS -Confirm:$false -ErrorAction Stop | Out-Null
        Clear-Disk -Number $Number -RemoveData -RemoveOEM -Confirm:$false
        return $true
    } catch {
        Write-IRequireLog ("TRIM epaonnistui levylla {0}: {1}" -f $Number, $_.Exception.Message) 'Varoitus'
        try { Clear-Disk -Number $Number -RemoveData -RemoveOEM -Confirm:$false -ErrorAction SilentlyContinue } catch { }
        return $false
    }
}

function Invoke-DiskWipe {
    <# Tyhjentaa yhden levyn ja palauttaa todistustietueen. #>
    param([Parameter(Mandatory)]$Disk, [int]$SampleCount = 256, [switch]$FullVerify)

    $record = [ordered]@{
        Levy         = $Disk.Number
        Malli        = $Disk.Model
        Sarjanumero  = $Disk.Serial
        Koko         = $Disk.Size
        Vayla        = $Disk.Bus
        Tyyppi       = $Disk.Kind
        Alkoi        = (Get-Date).ToString('s')
        Paattyi      = ''
        Menetelma    = ''
        Yritykset    = @()
        Naytteita    = 0
        NaytteitaJoissaDataa = 0
        ViallisetAlueet = @()
        TaysiVarmistus = 'ei tehty'
        Varmistus    = 'EI TEHTY'
        Huomio       = ''
    }
    $attempts = New-Object System.Collections.Generic.List[string]
    $finish = {
        param($verdict, $note)
        $record.Varmistus = $verdict
        $record.Huomio = $note
        $record.Yritykset = $attempts.ToArray()
        $record.Paattyi = (Get-Date).ToString('s')
        $level = if ($verdict -eq 'HYVAKSYTTY') { 'Ok' } else { 'Virhe' }
        Write-IRequireLog ("Levy {0}: {1}, varmistus {2} {3}" -f $Disk.Number, $record.Menetelma, $verdict, $note) $level
        return [pscustomobject]$record
    }

    Write-IRequireLog ("Levy {0}: {1} {2} ({3}, {4})" -f $Disk.Number, $Disk.Model, $Disk.Serial, $Disk.Kind, (Format-Size $Disk.Size))
    Clear-DiskLayout -Number $Disk.Number

    $offsets = Get-SampleOffsets -Size $Disk.Size -Count $SampleCount
    $before = Read-DiskSamples -Number $Disk.Number -Offsets $offsets
    $unreadableBefore = @($before.ToArray() | Where-Object { $_.Error }).Count
    if ($unreadableBefore -eq $before.Count) {
        # Kokonaan lukukelvoton levy on lahes aina lukittu laitteistosalattu
        # (Opal/eDrive) levy tai hajonnut levy.
        Write-IRequireLog ("Levy {0}: yhtakaan kohtaa ei voi lukea" -f $Disk.Number) 'Varoitus'
    }

    if (Test-FlashKind $Disk.Kind) {
        Write-IRequireLog ("Levy {0}: laitteen oma tyhjennys..." -f $Disk.Number)
        $fw = Invoke-FirmwareErase -Number $Disk.Number -Kind $Disk.Kind
        if ($fw.Ok) {
            if (-not (Wait-DiskReadable -Number $Disk.Number)) {
                $attempts.Add('Laitteen tyhjennys: levy ei vastannut 120 minuuttiin')
            } else {
                Update-Disk -Number $Disk.Number -ErrorAction SilentlyContinue
                $after = Read-DiskSamples -Number $Disk.Number -Offsets $offsets
                $check = Test-WipeResult -Before $before -After $after -Method Firmware
                if ($check.Ok) {
                    $attempts.Add('Laitteen tyhjennys (IOCTL_STORAGE_REINITIALIZE_MEDIA): OK')
                    $record.Menetelma = if ($Disk.Kind -eq 'NVMe') { 'NVMe Sanitize, kryptografinen tyhjennys' } else { 'Laitteen oma tyhjennys' }
                    $record.Naytteita = $check.Samples
                    $record.NaytteitaJoissaDataa = $check.HadData
                    return (& $finish 'HYVAKSYTTY' '')
                }
                $attempts.Add(("Laitteen tyhjennys: komento meni lapi mutta {0}/{1} naytetta ennallaan tai lukukelvottomia" -f $check.Failed, $check.Samples))
            }
            Write-IRequireLog ("Levy {0}: laitteen tyhjennys ei varmistunut, ylikirjoitetaan" -f $Disk.Number) 'Varoitus'
        } else {
            $attempts.Add('Laitteen tyhjennys: ei tuettu (' + $fw.Error + ')')
            Write-IRequireLog ("Levy {0}: laitteen tyhjennys ei tuettu ({1}), ylikirjoitetaan" -f $Disk.Number, $fw.Error) 'Varoitus'
        }
    }

    $ow = Invoke-ZeroOverwrite -Number $Disk.Number -Size $Disk.Size
    $record.ViallisetAlueet = $ow.BadRanges
    $after = Read-DiskSamples -Number $Disk.Number -Offsets $offsets
    $check = Test-WipeResult -Before $before -After $after -Method Overwrite
    $attempts.Add(('Ylikirjoitus nollilla: {0:hh\:mm\:ss}, {1} viallista aluetta, {2} hylattya naytetta' -f $ow.Elapsed, $ow.BadRanges.Count, $check.Failed))
    $record.Menetelma = 'Ylikirjoitus nollilla (1 kierros)'
    $record.Naytteita = $check.Samples
    $record.NaytteitaJoissaDataa = $check.HadData

    $fullOk = $true
    if ($FullVerify) {
        $full = Test-DiskAllZero -Number $Disk.Number -Size $Disk.Size
        $record.TaysiVarmistus = if ($full.Ok) { 'OK' } else { ('{0} ei-nollaa palaa, {1} lukuvirhetta' -f $full.NonZero, $full.Errors) }
        $attempts.Add('Koko levyn takaisinluku: ' + $record.TaysiVarmistus)
        $fullOk = $full.Ok
    }

    if ($Disk.Kind -ne 'HDD') {
        if (Invoke-FullDiskTrim -Number $Disk.Number) {
            $attempts.Add('TRIM koko levylle: OK')
            $record.Menetelma += ' + TRIM'
        }
    }

    if ($ow.BadRanges.Count -gt 0) {
        return (& $finish 'HYLATTY' ("{0} aluetta ei voitu kirjoittaa. Levy on viallinen: tuhoa se fyysisesti." -f $ow.BadRanges.Count))
    }
    if (-not $check.Ok -or -not $fullOk) {
        $note = if ($unreadableBefore -eq $before.Count) {
            'Levya ei voi lukea eika kirjoittaa. Se on todennakoisesti laitteistosalattu ja lukittu (Opal/eDrive): palauta se valmistajan PSID-toiminnolla.'
        } else { 'Nollia ei loytynyt kaikista tarkistetuista kohdista.' }
        return (& $finish 'HYLATTY' $note)
    }
    return (& $finish 'HYVAKSYTTY' '')
}

function Write-WipeCertificate {
    <# Tyhjennystodistus seka koneluettavana etta tekstina. #>
    param([Parameter(Mandatory)]$Records, [Parameter(Mandatory)][string]$Directory, [string]$Machine = '')

    if (-not (Test-Path -LiteralPath $Directory)) { New-Item -ItemType Directory -Path $Directory -Force | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $base = Join-Path $Directory ("tyhjennystodistus-$stamp")

    $doc = [ordered]@{
        Tyokalu = 'iRequire'
        Luotu   = (Get-Date).ToString('s')
        Kello   = 'koneen oma kello (WinPE, ei aikavyohyketta)'
        Kone    = $Machine
        Levyt   = @($Records)
    }
    $doc | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$base.json" -Encoding UTF8

    $t = New-Object System.Collections.Generic.List[string]
    $t.Add('TYHJENNYSTODISTUS - iRequire')
    $t.Add('Luotu: ' + $doc.Luotu + ' (koneen kello)')
    if ($Machine) { $t.Add('Kone:  ' + $Machine) }
    $t.Add('')
    foreach ($r in $Records) {
        $t.Add(('Levy {0}: {1}' -f $r.Levy, $r.Malli))
        $t.Add(('  Sarjanumero:  {0}' -f $r.Sarjanumero))
        $t.Add(('  Koko:         {0} ({1} tavua)' -f (Format-Size $r.Koko), $r.Koko))
        $t.Add(('  Vayla/tyyppi: {0} / {1}' -f $r.Vayla, $r.Tyyppi))
        $t.Add(('  Menetelma:    {0}' -f $r.Menetelma))
        $t.Add(('  Aika:         {0} - {1}' -f $r.Alkoi, $r.Paattyi))
        $t.Add(('  Varmistus:    {0} ({1} satunnaista naytetta, joista {2} sisalsi dataa ennen tyhjennysta)' -f $r.Varmistus, $r.Naytteita, $r.NaytteitaJoissaDataa))
        $t.Add(('  Takaisinluku: {0}' -f $r.TaysiVarmistus))
        if ($r.Huomio) { $t.Add(('  HUOMIO:       {0}' -f $r.Huomio)) }
        foreach ($a in $r.Yritykset) { $t.Add('    - ' + $a) }
        $t.Add('')
    }
    $t | Set-Content -LiteralPath "$base.txt" -Encoding UTF8
    return "$base.txt"
}
