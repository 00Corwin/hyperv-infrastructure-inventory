<#
.SYNOPSIS
    Collects CPU, memory and logical-disk inventory from Hyper-V hosts.

.PARAMETER CsvPath
    CSV containing a host-name column. Accepted names include Name,
    ComputerName, Server and Hostname.

.PARAMETER OutputDirectory
    Directory for generated CSV reports.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$CsvPath,

    [string]$OutputDirectory = ".\HyperV_Inventory_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
)

function Get-RowValue {
    param(
        [object]$Row,
        [string[]]$Names
    )

    foreach ($Name in $Names) {
        if ($Row.PSObject.Properties.Name -contains $Name) {
            return [string]$Row.$Name
        }
    }

    return $null
}

$Rows = Import-Csv -Path $CsvPath
$Hosts = foreach ($Row in $Rows) {
    $Name = Get-RowValue -Row $Row -Names @('Name','ComputerName','Server','Hostname','NAME')

    if (-not [string]::IsNullOrWhiteSpace($Name)) {
        $Name.Trim()
    }
}

$Hosts = @($Hosts | Sort-Object -Unique)

if ($Hosts.Count -eq 0) {
    throw 'No host names were found in the input CSV.'
}

New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

$Raw = foreach ($ComputerName in $Hosts) {
    try {
        Invoke-Command -ComputerName $ComputerName -ErrorAction Stop -ScriptBlock {
            $Computer = Get-CimInstance Win32_ComputerSystem
            $OS = Get-CimInstance Win32_OperatingSystem
            $Cpu = @(Get-CimInstance Win32_Processor)
            $Volumes = @(Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3")

            [PSCustomObject]@{
                RecordType         = 'Host'
                ComputerName       = $env:COMPUTERNAME
                Manufacturer       = $Computer.Manufacturer
                Model              = $Computer.Model
                OperatingSystem    = $OS.Caption
                CpuSockets         = $Cpu.Count
                CpuCores           = ($Cpu | Measure-Object NumberOfCores -Sum).Sum
                LogicalProcessors  = ($Cpu | Measure-Object NumberOfLogicalProcessors -Sum).Sum
                MemoryGB           = [math]::Round($Computer.TotalPhysicalMemory / 1GB, 2)
                Drive              = $null
                FileSystem         = $null
                SizeGB             = $null
                FreeGB             = $null
                PercentFree        = $null
            }

            foreach ($Volume in $Volumes) {
                [PSCustomObject]@{
                    RecordType         = 'Volume'
                    ComputerName       = $env:COMPUTERNAME
                    Manufacturer       = $null
                    Model              = $null
                    OperatingSystem    = $null
                    CpuSockets         = $null
                    CpuCores           = $null
                    LogicalProcessors  = $null
                    MemoryGB           = $null
                    Drive              = $Volume.DeviceID
                    FileSystem         = $Volume.FileSystem
                    SizeGB             = [math]::Round($Volume.Size / 1GB, 2)
                    FreeGB             = [math]::Round($Volume.FreeSpace / 1GB, 2)
                    PercentFree        = if ($Volume.Size) {
                        [math]::Round(($Volume.FreeSpace / $Volume.Size) * 100, 2)
                    } else { $null }
                }
            }
        }
    }
    catch {
        [PSCustomObject]@{
            RecordType         = 'Error'
            ComputerName       = $ComputerName
            Manufacturer       = $null
            Model              = $null
            OperatingSystem    = $null
            CpuSockets         = $null
            CpuCores           = $null
            LogicalProcessors  = $null
            MemoryGB           = $null
            Drive              = $null
            FileSystem         = $null
            SizeGB             = $null
            FreeGB             = $null
            PercentFree        = $null
            Error              = $_.Exception.Message
        }
    }
}

$Raw |
    Where-Object RecordType -eq 'Host' |
    Select-Object ComputerName, Manufacturer, Model, OperatingSystem,
        CpuSockets, CpuCores, LogicalProcessors, MemoryGB |
    Export-Csv -Path (Join-Path $OutputDirectory 'HostSummary.csv') -NoTypeInformation

$Raw |
    Where-Object RecordType -eq 'Volume' |
    Select-Object ComputerName, Drive, FileSystem, SizeGB, FreeGB, PercentFree |
    Export-Csv -Path (Join-Path $OutputDirectory 'Volumes.csv') -NoTypeInformation

$Raw |
    Where-Object RecordType -eq 'Error' |
    Select-Object ComputerName, Error |
    Export-Csv -Path (Join-Path $OutputDirectory 'Errors.csv') -NoTypeInformation

Write-Output "Inventory written to: $OutputDirectory"
