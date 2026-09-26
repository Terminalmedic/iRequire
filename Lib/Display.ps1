# ==============================================================
#  Lib\Display.ps1 - naytot suurimmalle virkistystaajuudelle
#
#  Yleisin yksittainen pelikoneen virhe: 144/165/240 Hz -naytto pyorii
#  60 Hz:lla, koska Windows valitsi varman tilan ennen naytonohjaimen
#  ajuria. Tama nostaa jokaisen nayton suurimpaan taajuuteen, jonka
#  naytto itse ilmoittaa tukevansa (EDID), nykyisella tarkkuudella.
#
#  Ajetaan kayttajan istunnossa (ChangeDisplaySettingsEx ei vaikuta
#  tyopoytaan SYSTEM-palvelusta). Tilat testataan ensin CDS_TESTilla.
# ==============================================================

function Select-BestDisplayMode {
    <# Puhdas valintalogiikka: sama tarkkuus ja varisyvyys, ei lomitettuja
       tiloja, suurin taajuus. $null jos nykyinen on jo paras. #>
    param([Parameter(Mandatory)]$Current, [Parameter(Mandatory)]$Modes)
    $DM_INTERLACED = 2
    $best = $null
    foreach ($m in $Modes) {
        if ($m.Width -ne $Current.Width -or $m.Height -ne $Current.Height) { continue }
        if ($m.Bpp -ne $Current.Bpp) { continue }
        if (($m.Flags -band $DM_INTERLACED) -ne 0) { continue }
        if (-not $best -or $m.Hz -gt $best.Hz) { $best = $m }
    }
    if ($best -and $best.Hz -gt $Current.Hz) { return $best }
    return $null
}

function Initialize-DisplayApi {
    if ('IRequireDisplay' -as [type]) { return }
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class IRequireDisplay {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmDeviceName;
        public ushort dmSpecVersion; public ushort dmDriverVersion; public ushort dmSize; public ushort dmDriverExtra;
        public uint dmFields;
        public int dmPositionX; public int dmPositionY; public uint dmDisplayOrientation; public uint dmDisplayFixedOutput;
        public short dmColor; public short dmDuplex; public short dmYResolution; public short dmTTOption; public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string dmFormName;
        public ushort dmLogPixels; public uint dmBitsPerPel; public uint dmPelsWidth; public uint dmPelsHeight;
        public uint dmDisplayFlags; public uint dmDisplayFrequency;
        public uint dmICMMethod; public uint dmICMIntent; public uint dmMediaType; public uint dmDitherType;
        public uint dmReserved1; public uint dmReserved2; public uint dmPanningWidth; public uint dmPanningHeight;
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAY_DEVICE {
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceString;
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string DeviceKey;
    }
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool EnumDisplayDevices(string lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool EnumDisplaySettings(string deviceName, int modeNum, ref DEVMODE devMode);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int ChangeDisplaySettingsEx(string lpszDeviceName, ref DEVMODE lpDevMode, IntPtr hwnd, uint dwflags, IntPtr lParam);

    public static DEVMODE NewDevMode() {
        DEVMODE d = new DEVMODE();
        d.dmSize = (ushort)Marshal.SizeOf(typeof(DEVMODE));
        return d;
    }
    public static DISPLAY_DEVICE NewDisplayDevice() {
        DISPLAY_DEVICE d = new DISPLAY_DEVICE();
        d.cb = Marshal.SizeOf(typeof(DISPLAY_DEVICE));
        return d;
    }
}
"@
}

function Set-MaxRefreshRate {
    <# Palauttaa jokaisesta naytosta rivin: nimi, ennen, jalkeen, tulos. #>
    Initialize-DisplayApi
    $ENUM_CURRENT_SETTINGS = -1
    $DISPLAY_DEVICE_ATTACHED_TO_DESKTOP = 1
    $DM_DISPLAYFREQUENCY = [uint32]'0x400000'
    $CDS_UPDATEREGISTRY = [uint32]1
    $CDS_TEST = [uint32]2

    $results = New-Object System.Collections.Generic.List[object]
    for ($i = [uint32]0; $i -lt 16; $i++) {
        $dd = [IRequireDisplay]::NewDisplayDevice()
        if (-not [IRequireDisplay]::EnumDisplayDevices($null, $i, [ref]$dd, 0)) { break }
        if (($dd.StateFlags -band $DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) -eq 0) { continue }

        $cur = [IRequireDisplay]::NewDevMode()
        if (-not [IRequireDisplay]::EnumDisplaySettings($dd.DeviceName, $ENUM_CURRENT_SETTINGS, [ref]$cur)) { continue }
        $current = [pscustomobject]@{ Width = $cur.dmPelsWidth; Height = $cur.dmPelsHeight; Bpp = $cur.dmBitsPerPel; Hz = $cur.dmDisplayFrequency; Flags = $cur.dmDisplayFlags }

        $modes = New-Object System.Collections.Generic.List[object]
        for ($n = 0; $n -lt 4096; $n++) {
            $m = [IRequireDisplay]::NewDevMode()
            if (-not [IRequireDisplay]::EnumDisplaySettings($dd.DeviceName, $n, [ref]$m)) { break }
            $modes.Add([pscustomobject]@{ Width = $m.dmPelsWidth; Height = $m.dmPelsHeight; Bpp = $m.dmBitsPerPel; Hz = $m.dmDisplayFrequency; Flags = $m.dmDisplayFlags })
        }

        $best = Select-BestDisplayMode -Current $current -Modes $modes.ToArray()
        $row = [pscustomobject]@{
            Naytto = ('{0} ({1})' -f $dd.DeviceName, $dd.DeviceString)
            Tarkkuus = ('{0}x{1}' -f $current.Width, $current.Height)
            EnnenHz = [int]$current.Hz
            JalkeenHz = [int]$current.Hz
            Tulos = 'jo suurin taajuus'
        }
        if ($best) {
            $cur.dmDisplayFrequency = $best.Hz
            $cur.dmFields = $DM_DISPLAYFREQUENCY
            $test = [IRequireDisplay]::ChangeDisplaySettingsEx($dd.DeviceName, [ref]$cur, [IntPtr]::Zero, $CDS_TEST, [IntPtr]::Zero)
            if ($test -ne 0) {
                $row.Tulos = "tila $($best.Hz) Hz hylattiin testissa (koodi $test)"
            } else {
                $r = [IRequireDisplay]::ChangeDisplaySettingsEx($dd.DeviceName, [ref]$cur, [IntPtr]::Zero, $CDS_UPDATEREGISTRY, [IntPtr]::Zero)
                if ($r -eq 0) { $row.JalkeenHz = [int]$best.Hz; $row.Tulos = 'nostettu' }
                else { $row.Tulos = "vaihto epaonnistui (koodi $r)" }
            }
        }
        $results.Add($row)
    }
    return ,$results
}
