<#
.SYNOPSIS
    Collects extended Hyper-V host, storage, VM and VHD capacity inventory.

.DESCRIPTION
    Requires PowerShell remoting to the target hosts. Hyper-V cmdlets are used
    on each remote host so the collector does not require direct VHD access.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$HostsPath,

    [string]$OutputDirectory = ".\HyperV_Capacity_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
)

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
$Volumes = @()
$PhysicalDisks = @()
$StoragePools = @()
$VirtualDisks = @()
$VirtualMachines = @()
$Vhds = @()
$Errors = @()

foreach ($ComputerName in $Hosts) {
    try {
        $Data = Invoke-Command -ComputerName $ComputerName -ErrorAction Stop -ScriptBlock {
            $Computer = Get-CimInstance Win32_ComputerSystem
            $Cpu = @(Get-CimInstance Win32_Processor)

            $HostSummary = [PSCustomObject]@{
                ComputerName      = $env:COMPUTERNAME
                Manufacturer      = $Computer.Manufacturer
                Model             = $Computer.Model
                CpuSockets        = $Cpu.Count
                CpuCores          = ($Cpu | Measure-Object NumberOfCores -Sum).Sum
                LogicalProcessors = ($Cpu | Measure-Object NumberOfLogicalProcessors -Sum).Sum
                MemoryGB          = [math]::Round($Computer.TotalPhysicalMemory / 1GB, 2)
            }

            $Volumes = @(Get-Volume -ErrorAction SilentlyContinue | ForEach-Object {
                [PSCustomObject]@{
                    ComputerName = $env:COMPUTERNAME
                    DriveLetter  = $_.DriveLetter
                    FileSystem   = $_.FileSystem
                    FileSystemLabel = $_.FileSystemLabel
                    HealthStatus = $_.HealthStatus
                    SizeGB       = [math]::Round($_.Size / 1GB, 2)
                    FreeGB       = [math]::Round($_.SizeRemaining / 1GB, 2)
                }
            })

            $PhysicalDisks = @(Get-PhysicalDisk -ErrorAction SilentlyContinue | ForEach-Object {
                [PSCustomObject]@{
                    ComputerName = $env:COMPUTERNAME
                    FriendlyName = $_.FriendlyName
                    SerialNumber = $_.SerialNumber
                    MediaType    = $_.MediaType
                    BusType      = $_.BusType
                    HealthStatus = $_.HealthStatus
                    OperationalStatus = ($_.OperationalStatus -join ',')
                    SizeGB       = [math]::Round($_.Size / 1GB, 2)
                }
            })

            $StoragePools = @(Get-StoragePool -ErrorAction SilentlyContinue | ForEach-Object {
                [PSCustomObject]@{
                    ComputerName = $env:COMPUTERNAME
                    FriendlyName = $_.FriendlyName
                    HealthStatus = $_.HealthStatus
                    OperationalStatus = ($_.OperationalStatus -join ',')
                    SizeGB       = [math]::Round($_.Size / 1GB, 2)
                    AllocatedGB  = [math]::Round($_.AllocatedSize / 1GB, 2)
                }
            })

            $VirtualDisks = @(Get-VirtualDisk -ErrorAction SilentlyContinue | ForEach-Object {
                [PSCustomObject]@{
                    ComputerName = $env:COMPUTERNAME
                    FriendlyName = $_.FriendlyName
                    ResiliencySettingName = $_.ResiliencySettingName
                    ProvisioningType = $_.ProvisioningType
                    HealthStatus = $_.HealthStatus
                    SizeGB       = [math]::Round($_.Size / 1GB, 2)
                    FootprintGB  = [math]::Round($_.FootprintOnPool / 1GB, 2)
                }
            })

            $VirtualMachines = @()
            $Vhds = @()

            if (Get-Command Get-VM -ErrorAction SilentlyContinue) {
                $VirtualMachines = @(Get-VM | ForEach-Object {
                    [PSCustomObject]@{
                        ComputerName = $env:COMPUTERNAME
                        VMName       = $_.Name
                        State        = $_.State
                        Generation   = $_.Generation
                        ProcessorCount = $_.ProcessorCount
                        MemoryAssignedGB = [math]::Round($_.MemoryAssigned / 1GB, 2)
                        MemoryDemandGB = [math]::Round($_.MemoryDemand / 1GB, 2)
                        Uptime       = $_.Uptime
                    }
                })

                foreach ($VM in Get-VM) {
                    foreach ($Disk in Get-VMHardDiskDrive -VM $VM -ErrorAction SilentlyContinue) {
                        try {
                            $Vhd = Get-VHD -Path $Disk.Path -ErrorAction Stop
                            $Vhds += [PSCustomObject]@{
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
                            $Vhds += [PSCustomObject]@{
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

            [PSCustomObject]@{
                HostSummary    = $HostSummary
                Volumes        = $Volumes
                PhysicalDisks  = $PhysicalDisks
                StoragePools   = $StoragePools
                VirtualDisks   = $VirtualDisks
                VirtualMachines= $VirtualMachines
                Vhds           = $Vhds
            }
        }

        $HostSummary += $Data.HostSummary
        $Volumes += $Data.Volumes
        $PhysicalDisks += $Data.PhysicalDisks
        $StoragePools += $Data.StoragePools
        $VirtualDisks += $Data.VirtualDisks
        $VirtualMachines += $Data.VirtualMachines
        $Vhds += $Data.Vhds
    }
    catch {
        $Errors += [PSCustomObject]@{
            ComputerName = $ComputerName
            Error = $_.Exception.Message
        }
    }
}

$HostSummary | Export-Csv (Join-Path $OutputDirectory '01-HostSummary.csv') -NoTypeInformation
$Volumes | Export-Csv (Join-Path $OutputDirectory '02-Volumes.csv') -NoTypeInformation
$PhysicalDisks | Export-Csv (Join-Path $OutputDirectory '03-PhysicalDisks.csv') -NoTypeInformation
$StoragePools | Export-Csv (Join-Path $OutputDirectory '04-StoragePools.csv') -NoTypeInformation
$VirtualDisks | Export-Csv (Join-Path $OutputDirectory '05-VirtualDisks.csv') -NoTypeInformation
$VirtualMachines | Export-Csv (Join-Path $OutputDirectory '06-VirtualMachines.csv') -NoTypeInformation
$Vhds | Export-Csv (Join-Path $OutputDirectory '07-VHDs.csv') -NoTypeInformation
$Errors | Export-Csv (Join-Path $OutputDirectory '99-Errors.csv') -NoTypeInformation

Write-Output "Capacity inventory written to: $OutputDirectory"
