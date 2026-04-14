# PowerCLI Script to Deploy 2-Node Oracle RAC VMs with Shared Disks
# This script deploys two virtual machines for Oracle RAC and adds shared disks with independent controllers.

# Prerequisites:
# - PowerCLI module installed
# - Connected to vCenter Server
# - Appropriate permissions
# - Shared datastore available

# Connect to vCenter Server (replace with your server details)
# Connect-VIServer -Server "your-vcenter-server" -User "username" -Password "password"

# Define variables
$vCenterServer = "your-vcenter-server"  # Replace with your vCenter server
$username = "your-username"            # Replace with your username
$password = "your-password"            # Replace with your password
$datastoreName = "your-datastore"       # Replace with your datastore name
$clusterName = "your-cluster"           # Replace with your cluster name
$vmHost = Get-VMHost | Select-Object -First 1  # Select first available host
$networkName = "VM Network"             # Replace with your network name
$guestId = "rhel7_64Guest"              # Guest OS ID for RHEL 7 (adjust as needed)

# VM specifications
$vmName1 = "OracleRAC-Node1"
$vmName2 = "OracleRAC-Node2"
$numCpu = 4
$memoryGB = 8
$osDiskGB = 50  # OS disk size

# Connect to vCenter
Connect-VIServer -Server $vCenterServer -User $username -Password $password

# Get datastore and cluster
$datastore = Get-Datastore -Name $datastoreName
$cluster = Get-Cluster -Name $clusterName

# Create VM1
Write-Host "Creating VM: $vmName1"
$vm1 = New-VM -Name $vmName1 -VMHost $vmHost -Datastore $datastore -NumCpu $numCpu -MemoryGB $memoryGB -DiskGB $osDiskGB -NetworkName $networkName -GuestId $guestId -Location $cluster

# Create VM2
Write-Host "Creating VM: $vmName2"
$vm2 = New-VM -Name $vmName2 -VMHost $vmHost -Datastore $datastore -NumCpu $numCpu -MemoryGB $memoryGB -DiskGB $osDiskGB -NetworkName $networkName -GuestId $guestId -Location $cluster

# Add additional SCSI controllers (VMware allows up to 4 per VM)
# Controller 1 for 10G disks
$controller1_vm1 = New-ScsiController -VM $vm1 -Type ParaVirtual
$controller1_vm2 = New-ScsiController -VM $vm2 -Type ParaVirtual

# Controller 2 for 32G disks
$controller2_vm1 = New-ScsiController -VM $vm1 -Type ParaVirtual
$controller2_vm2 = New-ScsiController -VM $vm2 -Type ParaVirtual

# Controller 3 for 128G disks
$controller3_vm1 = New-ScsiController -VM $vm1 -Type ParaVirtual
$controller3_vm2 = New-ScsiController -VM $vm2 -Type ParaVirtual

# Add 3 x 10G shared disks
Write-Host "Adding 3 x 10G shared disks"
for ($i = 1; $i -le 3; $i++) {
    $diskName = "RAC_Shared_10G_$i.vmdk"
    $hd = New-HardDisk -VM $vm1 -CapacityGB 10 -StorageFormat Thin -Controller $controller1_vm1 -MultiWriter:$true -Filename $diskName
    New-HardDisk -VM $vm2 -CapacityGB 10 -StorageFormat Thin -Controller $controller1_vm2 -MultiWriter:$true -DiskPath $hd.Filename
}

# Add 8 x 32G shared disks
Write-Host "Adding 8 x 32G shared disks"
for ($i = 1; $i -le 8; $i++) {
    $diskName = "RAC_Shared_32G_$i.vmdk"
    $hd = New-HardDisk -VM $vm1 -CapacityGB 32 -StorageFormat Thin -Controller $controller2_vm1 -MultiWriter:$true -Filename $diskName
    New-HardDisk -VM $vm2 -CapacityGB 32 -StorageFormat Thin -Controller $controller2_vm2 -MultiWriter:$true -DiskPath $hd.Filename
}

# Add 8 x 128G shared disks
Write-Host "Adding 8 x 128G shared disks"
for ($i = 1; $i -le 8; $i++) {
    $diskName = "RAC_Shared_128G_$i.vmdk"
    $hd = New-HardDisk -VM $vm1 -CapacityGB 128 -StorageFormat Thin -Controller $controller3_vm1 -MultiWriter:$true -Filename $diskName
    New-HardDisk -VM $vm2 -CapacityGB 128 -StorageFormat Thin -Controller $controller3_vm2 -MultiWriter:$true -DiskPath $hd.Filename
}

# Power on VMs (optional)
# Start-VM -VM $vm1
# Start-VM -VM $vm2

# Disconnect from vCenter
Disconnect-VIServer -Server $vCenterServer -Confirm:$false

Write-Host "Deployment completed. Please configure Oracle RAC software on the VMs."
