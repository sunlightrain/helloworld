# ==========================================
# 变量声明区
# ==========================================
$vCenter = "vcsa.example.com"
$Datacenter = "Datacenter-Name"
$Cluster = "Cluster-Name"
$VMTemplate = "Oracle-Linux-Template"
$VMNames = @("Oracle-RAC-Node1", "Oracle-RAC-Node2")
$Datastore = "vSAN-or-Shared-Storage"

# 磁盘配置定义 (SizeGB, ControllerKey)
$DiskConfigs = @()
for ($i=1; $i -le 3; $i++) { $DiskConfigs += @{Size=10;  Ctrl=1} } # 3个10GB (OCR/Vote)
for ($i=1; $i -le 8; $i++) { $DiskConfigs += @{Size=32;  Ctrl=2} } # 8个32GB (Data)
for ($i=1; $i -le 8; $i++) { $DiskConfigs += @{Size=128; Ctrl=3} } # 8个128GB (Flash/Archive)

# ==========================================
# 逻辑执行区
# ==========================================

# 1. 连接 vCenter
Connect-VIServer -Server $vCenter

# 2. 批量从模板创建虚拟机
foreach ($vmName in $VMNames) {
    Write-Host "正在从模板创建虚拟机: $vmName..." -ForegroundColor Cyan
    New-VM -Name $vmName -Template $VMTemplate -ResourcePool $Cluster -Datastore $Datastore
    
    # 为每个 VM 添加 3 个额外的 SCSI 控制器 (SCSI 1, 2, 3)
    # 类型设为 VMwareParavirtual，总线共享设为 Physical (RAC跨主机共享必选)
    1..3 | ForEach-Object {
        Write-Host "正在为 $vmName 添加 SCSI 控制器 $_..."
        New-ScsiController -VM $vmName -Type VMwareParavirtual -BusSharingMode Physical
    }
}

$VM1 = Get-VM -Name $VMNames[0]
$VM2 = Get-VM -Name $VMNames[1]

# 3. 循环创建并挂载磁盘
Write-Host "开始配置共享磁盘..." -ForegroundColor Yellow

foreach ($config in $DiskConfigs) {
    $size = $config.Size
    $ctrlIndex = $config.Ctrl
    
    # 获取 VM1 的对应控制器
    $ctrl = Get-ScsiController -VM $VM1 | Where-Object { $_.UnitNumber -eq $ctrlIndex }
    
    # 在第一个节点创建磁盘
    Write-Host "在 $VM1 上创建 ${size}GB 磁盘 (控制器 $ctrlIndex)..."
    $newDisk = New-HardDisk -VM $VM1 -CapacityGB $size -Datastore $Datastore -Controller $ctrl -Persistence IndependentPersistent
    
    # 获取 VM2 的对应控制器并挂载同一个 VMDK
    $ctrlVM2 = Get-ScsiController -VM $VM2 | Where-Object { $_.UnitNumber -eq $ctrlIndex }
    Write-Host "在 $VM2 上挂载该磁盘..."
    New-HardDisk -VM $VM2 -DiskPath $newDisk.FileName -Controller $ctrlVM2 -Persistence IndependentPersistent
}

# 4. 开启 Multi-Writer 多写模式
# 注意：必须在虚拟机关机状态下执行或重新配置高级参数
Write-Host "正在配置 Multi-Writer 参数..." -ForegroundColor Green
foreach ($vmName in $VMNames) {
    $vmView = Get-VM $vmName | Get-View
    $vmConfigSpec = New-Object VMware.Vim.VirtualMachineConfigSpec
    
    # 筛选出控制器 1, 2, 3 上的所有硬盘
    $disks = $vmView.Config.Hardware.Device | Where-Object { $_.Backing -is [VMware.Vim.VirtualDiskFlatVer2BackingInfo] -and $_.ControllerKey -ge 1 }
    
    foreach ($disk in $disks) {
        $extraConfig = New-Object VMware.Vim.OptionValue
        $extraConfig.Key = "scsi$($disk.ControllerKey):$($disk.UnitNumber).sharing"
        $extraConfig.Value = "multi-writer"
        $vmConfigSpec.ExtraConfig += $extraConfig
    }
    $vmView.ReconfigVM($vmConfigSpec)
}

Write-Host "任务完成！请检查虚拟机的存储控制器总线共享模式是否为 '物理'。" -ForegroundColor White
