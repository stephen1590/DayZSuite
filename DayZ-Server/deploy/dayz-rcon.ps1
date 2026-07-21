#!/usr/bin/env pwsh
<#
.SYNOPSIS
    One-shot BattlEye RCon sender for DayZ restart notices — pure PowerShell/.NET, no modules.
.DESCRIPTION
    Reads RConIP/RConPort/RConPassword from <ServerDir>/battleye/beserver_x64.cfg,
    logs in over BattlEye's UDP RCon protocol, sends one command, and exits.
.EXAMPLE
    ./dayz-rcon.ps1 /home/ubuntu/servers/dayz-server "say -1 Restart in 5 minutes"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ServerDir,
    [Parameter(Mandatory, ValueFromRemainingArguments)][string[]]$Command
)
$ErrorActionPreference = 'Stop'
$cmd = $Command -join ' '

$cfg = Join-Path $ServerDir 'battleye/beserver_x64.cfg'
if (-not (Test-Path -LiteralPath $cfg)) { Write-Error "cannot read $cfg"; exit 2 }
$text = Get-Content -Raw -LiteralPath $cfg
$pw   = [regex]::Match($text, '(?m)^\s*RConPassword\s+(\S+)')
$port = [regex]::Match($text, '(?m)^\s*RConPort\s+(\d+)')
$ipm  = [regex]::Match($text, '(?m)^\s*RConIP\s+(\S+)')
if (-not $pw.Success -or -not $port.Success) { Write-Error "RConPassword/RConPort not set in $cfg"; exit 2 }
$rHost = if ($ipm.Success) { $ipm.Groups[1].Value } else { '127.0.0.1' }
$rPort = [int]$port.Groups[1].Value

# Standard CRC-32 (zlib / ISO-HDLC), reflected poly 0xEDB88320 — what BattlEye uses.
function Get-Crc32 {
    param([byte[]]$Data)
    [uint32]$crc  = [uint32]::MaxValue
    [uint32]$poly = [uint32]0xEDB88320L
    foreach ($b in $Data) {
        $crc = [uint32](($crc -bxor $b) -band [uint32]::MaxValue)
        for ($k = 0; $k -lt 8; $k++) {
            if (($crc -band 1) -eq 1) { $crc = [uint32]((($crc -shr 1) -bxor $poly) -band [uint32]::MaxValue) }
            else                      { $crc = [uint32](($crc -shr 1) -band [uint32]::MaxValue) }
        }
    }
    return [uint32](($crc -bxor [uint32]::MaxValue) -band [uint32]::MaxValue)
}

# BE packet: 'BE' + CRC32(payload, little-endian) + payload, where payload = 0xFF | type | data
function New-BePacket {
    param([byte]$Type, [byte[]]$Data = @())
    $body = [System.Collections.Generic.List[byte]]::new()
    $body.Add([byte]0xFF); $body.Add($Type)
    if ($Data.Length) { $body.AddRange($Data) }
    $bodyArr  = $body.ToArray()
    $crcBytes = [BitConverter]::GetBytes([uint32](Get-Crc32 $bodyArr))
    if (-not [BitConverter]::IsLittleEndian) { [array]::Reverse($crcBytes) }
    $pkt = [System.Collections.Generic.List[byte]]::new()
    $pkt.AddRange([byte[]]@(0x42, 0x45))    # 'BE'
    $pkt.AddRange($crcBytes)
    $pkt.AddRange($bodyArr)
    return $pkt.ToArray()
}

$udp = [System.Net.Sockets.UdpClient]::new()
try {
    $udp.Client.ReceiveTimeout = 3000
    $udp.Connect($rHost, $rPort)
    $ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)

    $login = New-BePacket -Type 0x00 -Data ([System.Text.Encoding]::ASCII.GetBytes($pw.Groups[1].Value))
    [void]$udp.Send($login, $login.Length)
    try { $resp = $udp.Receive([ref]$ep) }
    catch { Write-Error "RCon login timed out — is the server up and RCon enabled?"; exit 1 }
    if ($resp.Length -lt 9 -or $resp[6] -ne 0xFF -or $resp[7] -ne 0x00 -or $resp[8] -ne 0x01) {
        Write-Error "RCon login failed (check RConPassword/RConPort)"; exit 1
    }

    $data   = [byte[]](, [byte]0x00 + [System.Text.Encoding]::ASCII.GetBytes($cmd))
    $packet = New-BePacket -Type 0x01 -Data $data
    [void]$udp.Send($packet, $packet.Length)
    Write-Host "RCon sent: $cmd"

    # Read until the actual command reply arrives. BattlEye interleaves type-0x02
    # console broadcasts (e.g. "RCon admin #0 logged in" fires right after login) —
    # each must be ACKed and skipped, or the first Receive returns the broadcast
    # instead of the reply and the command output is lost. Packet layout after the
    # 7-byte header: [8]=sequence, [9..]=payload; a 0x00 lead byte in the payload
    # marks a multi-part reply ([10]=count, [11]=index) that needs reassembly.
    $done = $false; $text = ''; $parts = @{}; $total = -1
    $deadline = [DateTime]::UtcNow.AddSeconds(3)
    while (-not $done -and [DateTime]::UtcNow -lt $deadline) {
        try { $r = $udp.Receive([ref]$ep) } catch { break }   # socket timeout
        if ($r.Length -lt 9 -or $r[6] -ne 0xFF) { continue }
        switch ($r[7]) {
            0x02 {  # console broadcast — ack (echo its sequence back) and keep waiting
                $ack = New-BePacket -Type 0x02 -Data (, $r[8])
                [void]$udp.Send($ack, $ack.Length)
            }
            0x01 {  # command reply
                if ($r.Length -le 9) { $done = $true; break }                    # empty ack (normal for say/kick)
                if ($r[9] -eq 0x00 -and $r.Length -ge 12) {                      # multi-part
                    $total = $r[10]
                    $parts[[int]$r[11]] = [System.Text.Encoding]::ASCII.GetString($r[12..($r.Length - 1)])
                    if ($parts.Count -ge $total) {
                        $text = -join (0..($total - 1) | ForEach-Object { $parts[$_] })
                        $done = $true
                    }
                } else {                                                          # single-part
                    $text = [System.Text.Encoding]::ASCII.GetString($r[9..($r.Length - 1)])
                    $done = $true
                }
            }
        }
    }
    if ($done) {
        $text = ($text -replace '[^\x20-\x7E\r\n]', '').Trim()
        if ($text) { Write-Host "server reply:`n$text" }
        else       { Write-Host "server ack'd (no text output — normal for 'say')" }
    } else {
        Write-Host "(command delivered; no reply captured within 3s)"
    }
} finally {
    $udp.Close()
}
