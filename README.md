# Hyper-V Infrastructure Inventory

PowerShell inventory scripts for collecting Hyper-V host hardware and capacity
data from a list of servers.

## Included

- `Get-HyperVHardwareInventory.ps1` accepts a CSV and exports CPU, memory and
  logical-volume data.
- `Get-HyperVCapacityInventory.ps1` collects host summary, Windows volumes,
  physical disks, storage pools, virtual disks, VMs and VHD capacity into
  separate CSV files.
- `Get-HyperVDellStorageInventory.ps1` adds optional Dell RACADM controller,
  physical-disk and virtual-disk inventory when RACADM is present.

The project was sanitised for public use. Hostnames in the examples are
synthetic and no infrastructure addresses, organisation names, credentials or
internal paths are embedded.

## Requirements

- PowerShell remoting to target hosts.
- Administrative rights for the required WMI/CIM and storage information.
- Hyper-V module on the target hosts for VM/VHD inventory.

## Examples

```powershell
.\scripts\Get-HyperVHardwareInventory.ps1 `
    -CsvPath .\examples\hosts.example.csv

.\scripts\Get-HyperVCapacityInventory.ps1 `
    -HostsPath .\examples\hosts.example.txt

.\scripts\Get-HyperVDellStorageInventory.ps1 `
    -HostsPath .\examples\hosts.example.txt
```
