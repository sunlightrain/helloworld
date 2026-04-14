# --- 基础配置 ---
$vm1Name = "RAC-Node1"
$vm2Name = "RAC-Node2"
$datastore = "Your_SAN_Datastore"

# 定义磁盘分布逻辑
$diskConfigs = @(
    @{Size = 10;  Count = 3; ControllerIndex = 1; Label = "OCR"},
    @{Size = 32;  Count = 8; ControllerIndex = 2; Label = "DATA"},
    @{Size = 128; Count = 8; ControllerIndex = 3; Label = "FRA"}
)

$vm1 = Get-VM $vm1Name
$vm2 = Get-VM $vm2Name

# 1. 创建并配置 SCSI 控制器 (1, 2, 3)
foreach ($idx in 1..3) {
    $ctrlName = "SCSI controller $idx"
    Write-Host "检查并配置 $ctrlName..." -ForegroundColor Cyan
    
    foreach ($vm in @($vm1, $vm2)) {
        $controller = Get-ScsiController -VM $vm -Name $ctrlName -ErrorAction SilentlyContinue
        if (-not $controller) {
            # 创建物理共享模式的准虚拟化控制器
            New-ScsiController -VM $vm -Type VMwareParavirtual -BusSharingMode Physical
        }
    }
}

# 2. 批量创建磁盘并交叉挂载
foreach ($config in $diskConfigs) {
    $ctrlName = "SCSI controller $($config.ControllerIndex)"
    $scsiCtrl1 = Get-ScsiController -VM $vm1 -Name $ctrlName
    
    for ($i = 1; $i -le $config.Count; $i++) {
        $sizeGB = $config.Size
        Write-Host "正在创建组 $($config.Label): 磁盘 $i ($sizeGB GB)..." -ForegroundColor Yellow

        # 在 VM1 上创建 EagerZeroedThick 磁盘
        $newDisk = New-HardDisk -VM $vm1 -CapacityGB $sizeGB -Datastore $datastore `
                   -StorageFormat EagerZeroedThick -Controller $scsiCtrl1
        
        # 获取磁盘文件路径并挂载到 VM2
        $diskPath = $newDisk.Filename
        New-HardDisk -VM $vm2 -DeviceName $diskPath -Controller (Get-ScsiController -VM $vm2 -Name $ctrlName)
    }
}

# 3. 启用 Multi-Writer (必须批量执行)
Write-Host "正在为所有共享磁盘开启 Multi-Writer 标志..." -ForegroundColor Green
$vms = $vm1, $vm2
foreach ($vm in $vms) {
    $spec = New-Object VMware.Vim.VirtualMachineConfigSpec
    # 筛选出控制器 1, 2, 3 下的所有磁盘
    $targetControllers = $vm.ExtensionData.Config.Hardware.Device | Where-Object { $_.DeviceInfo.Label -match "SCSI controller [1-3]" }
    $ctrlKeys = $targetControllers.Key
    
    $disks = $vm.ExtensionData.Config.Hardware.Device | Where-Object { $ctrlKeys -contains $_.ControllerKey -and $_ -is [VMware.Vim.VirtualDisk] }
    
    foreach ($disk in $disks) {
        $deviceConfig = New-Object VMware.Vim.VirtualDeviceConfigSpec
        $deviceConfig.Operation = "edit"
        $deviceConfig.Device = $disk
        $deviceConfig.Device.Backing.Sharing = "multiWriter"
        $spec.DeviceChange += $deviceConfig
    }
    $vm.ExtensionData.ReconfigVM($spec)
}

Write-Host "部署完成！请检查虚拟机的 SCSI 控制器设置和磁盘共享状态。" -ForegroundColor White
