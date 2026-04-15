<#
.SYNOPSIS
使用 PowerCLI 创建两个 Oracle RAC 虚拟机（基于 vSphere 模板），并为两个节点创建并挂载共享磁盘。
磁盘要求：
- Controller 1（SCSI Bus 1）：3 个 10GB 共享盘
- Controller 2（SCSI Bus 2）：8 个 32GB 共享盘
- Controller 3（SCSI Bus 3）：8 个 128GB 共享盘
所有共享盘均为：Thick Eager Zeroed + Independent Persistent + Multi-Writer
脚本高度可复用，所有关键参数均在顶部声明，修改变量即可重复使用。
#>

# ====================== 可复用变量声明区（修改此处即可） ======================
$vCenterServer   = "你的vCenter地址或FQDN"          # 如 vcenter.example.com
$vcUser          = "administrator@vsphere.local"     # vCenter 用户名
$vcPass          = "你的vCenter密码"                 # 生产环境建议使用 Get-Credential

$templateName    = "Oracle-RAC-Template"             # vSphere 模板名称
$clusterName     = "你的集群名称"                    # 集群名称
$datastoreName   = "RAC-Shared-Datastore"           # 必须是两个节点所在主机都能访问的共享存储
$vmFolderName    = "Oracle-RAC"                      # vCenter 中的文件夹（不存在则自动使用 vm 文件夹）
$resourcePoolName= $null                             # 如有专用 ResourcePool 则填写名称，否则留空使用集群

# 两个 RAC 节点名称
$vm1Name         = "racnode01"
$vm2Name         = "racnode02"

# 网络（可选，如果模板已配置正确可留空）
$networkName     = $null                             # 如需指定网络适配器名称，请填写

# 共享磁盘配置（高度可复用，可自行增删或修改大小/数量）
$diskConfig = @(
    @{ ControllerBus = 1; Count = 3;  SizeGB = 10;  NamePrefix = "Shared-10GB-" }   # Controller1
    @{ ControllerBus = 2; Count = 8;  SizeGB = 32;  NamePrefix = "Shared-32GB-" }   # Controller2
    @{ ControllerBus = 3; Count = 8;  SizeGB = 128; NamePrefix = "Shared-128GB-" }  # Controller3
)

# SCSI 控制器类型（推荐 PVSCSI 以获得最佳性能）
$scsiControllerType = "ParaVirtualSCSI"
# =============================================================================

# ====================== 脚本主体（无需修改） ======================
# 导入 PowerCLI 模块（如果未自动加载）
Import-Module VMware.PowerCLI -ErrorAction SilentlyContinue

# 连接 vCenter
Write-Host "正在连接 vCenter: $vCenterServer" -ForegroundColor Green
Connect-VIServer -Server $vCenterServer -User $vcUser -Password $vcPass -WarningAction SilentlyContinue | Out-Null

# 获取必要对象
$template     = Get-Template -Name $templateName
$cluster      = Get-Cluster -Name $clusterName
$datastore    = Get-Datastore -Name $datastoreName
$folder       = Get-Folder -Name $vmFolderName -ErrorAction SilentlyContinue
if (-not $folder) { $folder = Get-Folder -Name "vm" }
$resourcePool = if ($resourcePoolName) { 
                    Get-ResourcePool -Name $resourcePoolName -Location $cluster 
                } else { 
                    $cluster 
                }

# --------------------- 创建第一个节点 VM1 并添加共享磁盘 ---------------------
Write-Host "正在基于模板创建 VM1: $vm1Name" -ForegroundColor Green
$vm1 = New-VM -Name $vm1Name `
              -Template $template `
              -ResourcePool $resourcePool `
              -Datastore $datastore `
              -Location $folder `
              -PowerOn:$false

# 可选：指定网络
if ($networkName) {
    $vm1 | Get-NetworkAdapter | Set-NetworkAdapter -NetworkName $networkName -Confirm:$false | Out-Null
}

# 添加 3 个 PVSCSI 控制器（Bus 1、2、3）
Write-Host "为 $vm1Name 添加 3 个 PVSCSI 控制器..." -ForegroundColor Yellow
for ($i = 1; $i -le 3; $i++) {
    New-ScsiController -VM $vm1 -Type $scsiControllerType -BusSharing NoSharing -Confirm:$false | Out-Null
}

# 获取所有控制器（按 BusNumber 排序）
$controllersVM1 = $vm1 | Get-ScsiController | Sort-Object BusNumber

# 存放共享磁盘信息（用于后续挂载到 VM2）
$sharedDiskInfo = @()
$sharedDisksVM1 = @()   # 用于 VM1 的 Multi-Writer 设置

# 根据 $diskConfig 创建所有共享磁盘
foreach ($config in $diskConfig) {
    $bus        = $config.ControllerBus
    $controller = $controllersVM1 | Where-Object { $_.BusNumber -eq $bus }
    
    if (-not $controller) {
        Write-Error "未找到 Bus $bus 的控制器！"
        continue
    }
    
    for ($j = 0; $j -lt $config.Count; $j++) {
        \( diskName = " \)(\( config.NamePrefix) \)($j+1)"
        Write-Host "  创建共享磁盘: \( diskName ( \){config.SizeGB}GB) → Controller Bus $bus" -ForegroundColor Cyan
        
        $hardDisk = New-HardDisk -VM $vm1 `
                    -CapacityGB $config.SizeGB `
                    -StorageFormat ThickEagerZeroed `
                    -Persistence IndependentPersistent `
                    -Controller $controller `
                    -Confirm:$false
        
        $sharedDiskInfo += [PSCustomObject]@{
            Filename   = $hardDisk.Filename
            BusNumber  = $bus
        }
        $sharedDisksVM1 += $hardDisk
    }
}

# --------------------- 为 VM1 的所有共享磁盘开启 Multi-Writer ---------------------
function Set-MultiWriter {
    param(
        [Parameter(Mandatory=$true)]$VM,
        [Parameter(Mandatory=$true)]$HardDisk
    )
    $vmView = $VM | Get-View
    $device = $vmView.Config.Hardware.Device | Where-Object { $_.Key -eq $HardDisk.ExtensionData.Key }
    
    if ($device) {
        $spec = New-Object VMware.Vim.VirtualMachineConfigSpec
        $devSpec = New-Object VMware.Vim.VirtualDeviceConfigSpec
        $devSpec.Operation = [VMware.Vim.VirtualDeviceConfigSpecOperation]::edit
        $devSpec.Device = $device
        $devSpec.Device.Sharing = "multiWriter"   # 关键：Multi-Writer 设置
        $spec.DeviceChange = @($devSpec)
        
        $vmView.ReconfigVM($spec)
        Write-Host "  已为 $($HardDisk.Name) 启用 Multi-Writer" -ForegroundColor Green
    } else {
        Write-Warning "无法为 $($HardDisk.Name) 找到设备"
    }
}

Write-Host "为 VM1 的所有共享磁盘启用 Multi-Writer..." -ForegroundColor Yellow
foreach ($disk in $sharedDisksVM1) {
    Set-MultiWriter -VM $vm1 -HardDisk $disk
}

# --------------------- 创建第二个节点 VM2 并挂载相同共享磁盘 ---------------------
Write-Host "正在基于模板创建 VM2: $vm2Name" -ForegroundColor Green
$vm2 = New-VM -Name $vm2Name `
              -Template $template `
              -ResourcePool $resourcePool `
              -Datastore $datastore `
              -Location $folder `
              -PowerOn:$false

# 可选：指定网络
if ($networkName) {
    $vm2 | Get-NetworkAdapter | Set-NetworkAdapter -NetworkName $networkName -Confirm:$false | Out-Null
}

# 为 VM2 添加相同的 3 个 PVSCSI 控制器
Write-Host "为 $vm2Name 添加 3 个 PVSCSI 控制器..." -ForegroundColor Yellow
for ($i = 1; $i -le 3; $i++) {
    New-ScsiController -VM $vm2 -Type $scsiControllerType -BusSharing NoSharing -Confirm:$false | Out-Null
}
$controllersVM2 = $vm2 | Get-ScsiController | Sort-Object BusNumber

# 将共享磁盘挂载到 VM2（保持与 VM1 相同的 Controller Bus）
Write-Host "正在将共享磁盘挂载到 VM2 并启用 Multi-Writer..." -ForegroundColor Yellow
foreach ($info in $sharedDiskInfo) {
    $controller = $controllersVM2 | Where-Object { $_.BusNumber -eq $info.BusNumber }
    $hardDiskVM2 = New-HardDisk -VM $vm2 `
                   -DiskPath $info.Filename `
                   -Persistence IndependentPersistent `
                   -Controller $controller `
                   -Confirm:$false
    
    # 立即为 VM2 的该磁盘启用 Multi-Writer
    Set-MultiWriter -VM $vm2 -HardDisk $hardDiskVM2
}

# ====================== 完成 ======================
Write-Host "`n=== 操作完成！===" -ForegroundColor Green
Write-Host "已成功创建两个 Oracle RAC 节点：" -ForegroundColor Green
Write-Host "  • $vm1Name" -ForegroundColor White
Write-Host "  • $vm2Name" -ForegroundColor White
Write-Host "`n共享磁盘配置如下：" -ForegroundColor Green
Write-Host "  • Controller 1 (Bus 1): 3 个 10GB" -ForegroundColor White
Write-Host "  • Controller 2 (Bus 2): 8 个 32GB" -ForegroundColor White
Write-Host "  • Controller 3 (Bus 3): 8 个 128GB" -ForegroundColor White
Write-Host "`n所有共享盘已设置为：Independent Persistent + Multi-Writer" -ForegroundColor Green
Write-Host "两个 VM 当前为 PowerOff 状态，可直接启动并进行 Oracle RAC 配置。" -ForegroundColor Yellow

# 断开 vCenter 连接（可选）
# Disconnect-VIServer -Server $vCenterServer -Confirm:$false