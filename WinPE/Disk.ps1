# ==============================================================
#  WinPE\Disk.ps1 - levyjen tunnistus, tyhjennys ja varmistus
#
#  WinPE:ssa ei ole C#-kaantajaa, joten Add-Type ei toimi. Win32-kutsut
#  maaritellaan siksi Reflection.Emitilla ajonaikaisesti.
#
#  Tyhjennysmenetelmat:
#   - SSD/NVMe: laitteen oma tyhjennys (IOCTL_STORAGE_REINITIALIZE_MEDIA,
#     NVMe:lla kryptografinen tyhjennys). Tulos varmistetaan aina
#     lukemalla; jos laite ei tukenut komentoa tai varmistus ei mene
#     lapi, siirrytaan ylikirjoitukseen.
#   - HDD (ja SSD:n varamenetelma): koko levy nollilla + lukuvarmistus.
#     SSD:lle ajetaan lisaksi TRIM koko levylle.
# ==============================================================

$script:Native = $null

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
       avaamaan \\.\PhysicalDriveN -polkuja, joten kahva haetaan CreateFileW:lla. #>
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

# ==============================================================
#  Tunnistus
# ==============================================================

function Get-UsbBootDiskNumber {
    param([Parameter(Mandatory)][string]$UsbRoot)
    $letter = $UsbRoot.Substring(0, 1)
    try { return (Get-Partition -DriveLetter $letter -ErrorAction Stop).DiskNumber } catch { return -1 }
}

function Get-InternalDisks {
    <# Kaikki levyt paitsi tikku, USB-levyt ja virtuaalilevyt. #>
    param([int]$ExcludeNumber = -1)

    $physical = @{}
    foreach ($p in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) { $physical[[string]$p.DeviceId] = $p }

    $result = New-Object System.Collections.Generic.List[object]
    foreach ($d in @(Get-Disk | Sort-Object Number)) {
        if ($d.Number -eq $ExcludeNumber) { continue }
        if ($d.BusType -in @('USB', 'SD', 'MMC', 'Virtual', 'File Backed Virtual')) { continue }
        if ($d.Size -le 0) { continue }

        $pd = $physical[[string]$d.Number]
        $media = if ($pd) { [string]$pd.MediaType } else { 'Unspecified' }
        $kind = if ($d.BusType -eq 'NVMe') { 'NVMe' }
                elseif ($media -eq 'SSD') { 'SSD' }
                elseif ($media -eq 'HDD') { 'HDD' }
                else { 'Tuntematon' }

        $result.Add([pscustomobject]@{
            Number    = [int]$d.Number
            Model     = ([string]$d.FriendlyName).Trim()
            Serial    = ([string]$d.SerialNumber).Trim()
            Size      = [int64]$d.Size
            Bus       = [string]$d.BusType
            Kind      = $kind
            Partition = [string]$d.PartitionStyle
            Sector    = [int]$d.LogicalSectorSize
        })
    }
    return ,$result
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
        $lines.Add(('osio {0}: {1} {2} {3}' -f $p.PartitionNumber, (Format-Size $p.Size), $fs, $label).TrimEnd())

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

$script:SampleBytes = 65536

function Get-SampleOffsets {
    <# Alku, loppu ja satunnaiset kohdat 4 KiB:n rajoille tasattuna. #>
    param([Parameter(Mandatory)][int64]$Size, [int]$Count = 256)
    $max = [int64](($Size - $script:SampleBytes) / 4096)
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
    param([Parameter(Mandatory)][int]$Number, [Parameter(Mandatory)][int64[]]$Offsets)
    $sha = [System.Security.Cryptography.SHA256]::Create()
    $buf = New-Object byte[] $script:SampleBytes
    # Nollatarkistus tiivisteella: tavu kerrallaan PowerShellissa olisi hidas.
    $zeroHash = [BitConverter]::ToString($sha.ComputeHash((New-Object byte[] $script:SampleBytes)))
    $out = New-Object System.Collections.Generic.List[object]
    $fs = Open-RawDisk -Number $Number
    try {
        foreach ($o in $Offsets) {
            [void]$fs.Seek($o, 'Begin')
            $read = 0
            while ($read -lt $buf.Length) {
                $n = $fs.Read($buf, $read, $buf.Length - $read)
                if ($n -le 0) { break }
                $read += $n
            }
            if ($read -ne $buf.Length) { throw "Levyn $Number lukeminen kohdasta $o jai vajaaksi ($read tavua)" }
            $hash = [BitConverter]::ToString($sha.ComputeHash($buf))
            $out.Add([pscustomobject]@{
                Offset = $o
                Hash   = $hash
                Zero   = ($hash -eq $zeroHash)
            })
        }
    } finally {
        $fs.Dispose()
    }
    return ,$out
}

function Test-WipeResult {
    <# Overwrite: jokaisen nayteen on oltava nollaa.
       Firmware: jokaisen ennen tyhjennysta ei-tyhjan nayteen on muututtava. #>
    param(
        [Parameter(Mandatory)]$Before,
        [Parameter(Mandatory)]$After,
        [ValidateSet('Overwrite', 'Firmware')][string]$Method
    )
    $bad = 0
    for ($i = 0; $i -lt $After.Count; $i++) {
        if ($Method -eq 'Overwrite') {
            if (-not $After[$i].Zero) { $bad++ }
        } elseif (-not $Before[$i].Zero -and $Before[$i].Hash -eq $After[$i].Hash) {
            $bad++
        }
    }
    $hadData = @($Before | Where-Object { -not $_.Zero }).Count
    return [pscustomobject]@{
        Ok          = ($bad -eq 0)
        Samples     = $After.Count
        Failed      = $bad
        HadData     = $hadData
    }
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

function Invoke-ZeroOverwrite {
    <# Kirjoittaa koko levyn nollilla 4 MiB:n paloina ja nayttaa edistymisen. #>
    param([Parameter(Mandatory)][int]$Number, [Parameter(Mandatory)][int64]$Size)

    $chunk = 4MB
    $buf = New-Object byte[] $chunk
    $fs = Open-RawDisk -Number $Number -Write
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $lastShown = -10.0
    try {
        [void]$fs.Seek(0, 'Begin')
        $done = [int64]0
        while ($done -lt $Size) {
            $n = [int][Math]::Min([int64]$chunk, $Size - $done)
            $fs.Write($buf, 0, $n)
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
    return $sw.Elapsed
}

function Invoke-FullDiskTrim {
    <# SSD:n varamenetelman viimeistely: NTFS-pikaalustus lahettaa TRIMin
       koko osion alueelle, jolloin ohjain vapauttaa myos varatilan lohkot. #>
    param([Parameter(Mandatory)][int]$Number)
    try {
        Initialize-Disk -Number $Number -PartitionStyle GPT -ErrorAction Stop
        $p = New-Partition -DiskNumber $Number -UseMaximumSize -ErrorAction Stop
        $p | Format-Volume -FileSystem NTFS -Confirm:$false -ErrorAction Stop | Out-Null
        Clear-Disk -Number $Number -RemoveData -RemoveOEM -Confirm:$false
        return $true
    } catch {
        Write-Log ("TRIM epaonnistui levylla {0}: {1}" -f $Number, $_.Exception.Message) 'Varoitus'
        return $false
    }
}

function Invoke-DiskWipe {
    <# Tyhjentaa yhden levyn ja palauttaa todistustietueen. #>
    param([Parameter(Mandatory)]$Disk, [int]$SampleCount = 256)

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
        Varmistus    = 'EI TEHTY'
    }

    Write-Log ("Levy {0}: {1} {2} ({3}, {4})" -f $Disk.Number, $Disk.Model, $Disk.Serial, $Disk.Kind, (Format-Size $Disk.Size))
    Clear-DiskLayout -Number $Disk.Number

    $offsets = Get-SampleOffsets -Size $Disk.Size -Count $SampleCount
    $before = Read-DiskSamples -Number $Disk.Number -Offsets $offsets
    $attempts = New-Object System.Collections.Generic.List[string]

    if ($Disk.Kind -in @('NVMe', 'SSD')) {
        Write-Log ("Levy {0}: laitteen oma tyhjennys..." -f $Disk.Number)
        $fw = Invoke-FirmwareErase -Number $Disk.Number -Kind $Disk.Kind
        if ($fw.Ok) {
            Update-Disk -Number $Disk.Number -ErrorAction SilentlyContinue
            $after = Read-DiskSamples -Number $Disk.Number -Offsets $offsets
            $check = Test-WipeResult -Before $before -After $after -Method Firmware
            if ($check.Ok) {
                $attempts.Add('Laitteen tyhjennys (IOCTL_STORAGE_REINITIALIZE_MEDIA): OK')
                $record.Menetelma = if ($Disk.Kind -eq 'NVMe') { 'NVMe Sanitize / kryptografinen tyhjennys' } else { 'Laitteen oma tyhjennys' }
                $record.Naytteita = $check.Samples
                $record.NaytteitaJoissaDataa = $check.HadData
                $record.Varmistus = 'HYVAKSYTTY'
                $record.Yritykset = $attempts.ToArray()
                $record.Paattyi = (Get-Date).ToString('s')
                Write-Log ("Levy {0}: tyhjennetty ja varmistettu ({1} naytetta)" -f $Disk.Number, $check.Samples) 'Ok'
                return [pscustomobject]$record
            }
            $attempts.Add(("Laitteen tyhjennys: komento meni lapi mutta {0}/{1} naytetta ennallaan" -f $check.Failed, $check.Samples))
            Write-Log ("Levy {0}: laitteen tyhjennys ei varmistunut, ylikirjoitetaan" -f $Disk.Number) 'Varoitus'
        } else {
            $attempts.Add('Laitteen tyhjennys: ei tuettu (' + $fw.Error + ')')
            Write-Log ("Levy {0}: laitteen tyhjennys ei tuettu ({1}), ylikirjoitetaan" -f $Disk.Number, $fw.Error) 'Varoitus'
        }
    }

    $elapsed = Invoke-ZeroOverwrite -Number $Disk.Number -Size $Disk.Size
    $after = Read-DiskSamples -Number $Disk.Number -Offsets $offsets
    $check = Test-WipeResult -Before $before -After $after -Method Overwrite
    $attempts.Add(('Ylikirjoitus nollilla: {0:hh\:mm\:ss}, {1} virheellista naytetta' -f $elapsed, $check.Failed))
    $record.Menetelma = 'Ylikirjoitus nollilla (1 kierros)'

    if ($Disk.Kind -in @('NVMe', 'SSD')) {
        if (Invoke-FullDiskTrim -Number $Disk.Number) {
            $attempts.Add('TRIM koko levylle: OK')
            $record.Menetelma += ' + TRIM'
        }
    }

    $record.Naytteita = $check.Samples
    $record.NaytteitaJoissaDataa = $check.HadData
    $record.Varmistus = if ($check.Ok) { 'HYVAKSYTTY' } else { 'HYLATTY' }
    $record.Yritykset = $attempts.ToArray()
    $record.Paattyi = (Get-Date).ToString('s')
    $level = if ($check.Ok) { 'Ok' } else { 'Virhe' }
    Write-Log ("Levy {0}: {1}, varmistus {2}" -f $Disk.Number, $record.Menetelma, $record.Varmistus) $level
    return [pscustomobject]$record
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
        Kone    = $Machine
        Levyt   = @($Records)
    }
    $doc | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath "$base.json" -Encoding UTF8

    $t = New-Object System.Collections.Generic.List[string]
    $t.Add('TYHJENNYSTODISTUS - iRequire')
    $t.Add('Luotu: ' + $doc.Luotu)
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
        foreach ($a in $r.Yritykset) { $t.Add('    - ' + $a) }
        $t.Add('')
    }
    $t | Set-Content -LiteralPath "$base.txt" -Encoding UTF8
    return "$base.txt"
}
