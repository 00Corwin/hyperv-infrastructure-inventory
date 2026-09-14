<#
.SYNOPSIS
    Collects Dell/Hyper-V storage inventory, including Windows storage and
    optional local RACADM controller/physical-disk/virtual-disk output.

.DESCRIPTION
    Run against Dell Hyper-V hosts with PowerShell remoting enabled. If RACADM
    is available on the remote host, the script captures and parses the
    `racadm storage get ... -o` output. Hosts without RACADM still return the
    Windows/Hyper-V inventory.

.PARAMETER HostsPath
    Text file containing one host name per line.

.PARAMETER OutputDirectory
    Directory for CSV and text output.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$HostsPath,

    [string]$OutputDirectory = ".\DellHyperV_Storage_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
)

function ConvertFrom-RacadmObjectOutput {
    param(
        [string[]]$Lines,
        [string]$ComputerName,
        [string]$ObjectType
    )

    $Current = [ordered]@{}
    $Objects = @()

    foreach ($RawLine in $Lines) {
        $Line = [string]$RawLine

        if ([string]::IsNullOrWhiteSpace($Line)) {
            if ($Current.Count -gt 0) {
                $Current['ComputerName'] = $ComputerName
                $Current['ObjectType'] = $ObjectType
                $Objects += [PSCustomObject]$Current
                $Current = [ordered]@{}
            }
            continue
        }

        if ($Line -match '^\s*([^=]+?)\s*=\s*(.*)\s*$') {
            $Key = ($matches[1].Trim() -replace '[^A-Za-z0-9_]+','_').Trim('_')
            $Current[$Key] = $matches[2].Trim()
        }
        elseif ($Line -match '^\s*([^\s].*?)\s*$' -and -not $Current.Contains('Instance')) {
            $Current['Instance'] = $matches[1].Trim()
        }
    }

    if ($Current.Count -gt 0) {
        $Current['ComputerName'] = $ComputerName
        $Current['ObjectType'] = $ObjectType
        $Objects += [PSCustomObject]$Current
    }

    return $Objects
}

$Hosts = @(
    Get-Content -Path $HostsPath |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ -and -not $_.StartsWith('#') } |
        Sort-Object -Unique
)

if ($Hosts.Count -eq 0) {
    throw 'No hosts found.'
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$HostSummary = @()
$WindowsDisks = @()
$VirtualMachines = @()
$Vhds = @()
$RacadmControllers = @()
$RacadmPhysicalDisks = @()
$RacadmVirtualDisks = @()
$Errors = @()

foreach ($ComputerName in $Hosts) {
    try {
        $Data = Invoke-Command -ComputerName $ComputerName -ErrorAction Stop -ScriptBlock {
            $Computer = Get-CimInstance Win32_ComputerSystem
            $Cpu = @(Get-CimInstance Win32_Processor)

            $Summary = [PSCustomObject]@{
                ComputerName      = $env:COMPUTERNAME
                Manufacturer      = $Computer.Manufacturer
                Model             = $Computer.Model
                CpuSockets        = $Cpu.Count
                CpuCores          = ($Cpu | Measure-Object NumberOfCores -Sum).Sum
                LogicalProcessors = ($Cpu | Measure-Object NumberOfLogicalProcessors -Sum).Sum
                MemoryGB          = [math]::Round($Computer.TotalPhysicalMemory / 1GB, 2)
            }

            $Disks = @(Get-Disk -ErrorAction SilentlyContinue | ForEach-Object {
                [PSCustomObject]@{
                    ComputerName   = $env:COMPUTERNAME
                    Number         = $_.Number
                    FriendlyName   = $_.FriendlyName
                    SerialNumber   = $_.SerialNumber
                    BusType        = $_.BusType
                    PartitionStyle = $_.PartitionStyle
                    OperationalStatus = ($_.OperationalStatus -join ',')
                    HealthStatus   = $_.HealthStatus
                    SizeGB         = [math]::Round($_.Size / 1GB, 2)
                }
            })

            $VMs = @()
            $VhdInfo = @()

            if (Get-Command Get-VM -ErrorAction SilentlyContinue) {
                $VMs = @(Get-VM | ForEach-Object {
                    [PSCustomObject]@{
                        ComputerName = $env:COMPUTERNAME
                        VMName       = $_.Name
                        State        = $_.State
                        ProcessorCount = $_.ProcessorCount
                        MemoryAssignedGB = [math]::Round($_.MemoryAssigned / 1GB, 2)
                    }
                })

                foreach ($VM in Get-VM) {
                    foreach ($Disk in Get-VMHardDiskDrive -VM $VM -ErrorAction SilentlyContinue) {
                        try {
                            $Vhd = Get-VHD -Path $Disk.Path -ErrorAction Stop
                            $VhdInfo += [PSCustomObject]@{
                                ComputerName = $env:COMPUTERNAME
                                VMName       = $VM.Name
                                Path         = $Vhd.Path
                                VhdType      = $Vhd.VhdType
                                Format       = $Vhd.VhdFormat
                                SizeGB       = [math]::Round($Vhd.Size / 1GB, 2)
                                FileSizeGB   = [math]::Round($Vhd.FileSize / 1GB, 2)
                            }
                        }
                        catch {
                            $VhdInfo += [PSCustomObject]@{
                                ComputerName = $env:COMPUTERNAME
                                VMName       = $VM.Name
                                Path         = $Disk.Path
                                VhdType      = $null
                                Format       = $null
                                SizeGB       = $null
                                FileSizeGB   = $null
                            }
                        }
                    }
                }
            }

            $RacadmPath = (Get-Command racadm.exe -ErrorAction SilentlyContinue).Source
            if (-not $RacadmPath) {
                $RacadmPath = (Get-Command racadm -ErrorAction SilentlyContinue).Source
            }

            $Racadm = [PSCustomObject]@{
                Available   = [bool]$RacadmPath
                Controllers = @()
                PhysicalDisks = @()
                VirtualDisks  = @()
            }

            if ($RacadmPath) {
                $Racadm.Controllers = @(& $RacadmPath storage get controllers -o 2>&1)
                $Racadm.PhysicalDisks = @(& $RacadmPath storage get pdisks -o 2>&1)
                $Racadm.VirtualDisks = @(& $RacadmPath storage get vdisks -o 2>&1)
            }

            [PSCustomObject]@{
                HostSummary = $Summary
                WindowsDisks = $Disks
                VMs = $VMs
                Vhds = $VhdInfo
                Racadm = $Racadm
            }
        }

        $HostSummary += $Data.HostSummary
        $WindowsDisks += $Data.WindowsDisks
        $VirtualMachines += $Data.VMs
        $Vhds += $Data.Vhds

        if ($Data.Racadm.Available) {
            $RacadmControllers += ConvertFrom-RacadmObjectOutput `
                -Lines $Data.Racadm.Controllers `
                -ComputerName $ComputerName `
                -ObjectType 'Controller'

            $RacadmPhysicalDisks += ConvertFrom-RacadmObjectOutput `
                -Lines $Data.Racadm.PhysicalDisks `
                -ComputerName $ComputerName `
                -ObjectType 'PhysicalDisk'

            $RacadmVirtualDisks += ConvertFrom-RacadmObjectOutput `
                -Lines $Data.Racadm.VirtualDisks `
                -ComputerName $ComputerName `
                -ObjectType 'VirtualDisk'
        }
    }
    catch {
        $Errors += [PSCustomObject]@{
            ComputerName = $ComputerName
            Error = $_.Exception.Message
        }
    }
}

$HostSummary | Export-Csv (Join-Path $OutputDirectory '01-HostSummary.csv') -NoTypeInformation
$WindowsDisks | Export-Csv (Join-Path $OutputDirectory '02-WindowsDisks.csv') -NoTypeInformation
$RacadmControllers | Export-Csv (Join-Path $OutputDirectory '03-RACADM-Controllers.csv') -NoTypeInformation
$RacadmPhysicalDisks | Export-Csv (Join-Path $OutputDirectory '04-RACADM-PhysicalDisks.csv') -NoTypeInformation
$RacadmVirtualDisks | Export-Csv (Join-Path $OutputDirectory '05-RACADM-VirtualDisks.csv') -NoTypeInformation
$VirtualMachines | Export-Csv (Join-Path $OutputDirectory '06-VirtualMachines.csv') -NoTypeInformation
$Vhds | Export-Csv (Join-Path $OutputDirectory '07-VHDs.csv') -NoTypeInformation
$Errors | Export-Csv (Join-Path $OutputDirectory '99-Errors.csv') -NoTypeInformation

Write-Output "Dell/Hyper-V inventory written to: $OutputDirectory"
