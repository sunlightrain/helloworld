# 定义磁盘规格的变量，方便维护
locals {
  shared_disks = {
    "ctrl1" = { bus_number = 1, size = 10, count = 3,  start_unit = 0 }
    "ctrl2" = { bus_number = 2, size = 32, count = 8,  start_unit = 0 }
    "ctrl3" = { bus_number = 3, size = 128, count = 8, start_unit = 0 }
  }
}

# --- Node 1: 负责创建 VM 和所有共享 VMDK ---
resource "vsphere_virtual_machine" "rac_node_1" {
  name             = "Oracle-RAC-Node1"
  resource_pool_id = data.vsphere_resource_pool.pool.id
  datastore_id     = data.vsphere_datastore.ds.id
  
  num_cpus = 8
  memory   = 32768
  guest_id = "rhel8_64Guest"

  # 系统盘 (Controller 0)
  disk {
    label = "disk0"
    size  = 100
  }

  # 定义三个额外的 SCSI 控制器，必须开启总线共享 (Physical 适用于跨宿主机集群)
  scsi_type = "lsilogic-sas"
  scsi_bus_sharing = "physicalSharing" 

  # 配置三个独立控制器（控制器 0 是系统默认的，这里添加 1, 2, 3）
  # 注意：在 vSphere 8.0 中，控制器会自动根据 disk 块中的 bus_number 创建
  
  # 动态生成所有共享磁盘
  dynamic "disk" {
    for_each = flatten([
      for key, config in locals.shared_disks : [
        for i in range(config.count) : {
          label       = "shared-${key}-${i}"
          size        = config.size
          bus_number  = config.bus_number
          unit_number = i < 7 ? i : i + 1 # 避开 SCSI ID 7 (控制器占用)
        }
      ]
    ])
    
    content {
      label            = disk.value.label
      size             = disk.value.size
      unit_number      = disk.value.unit_number
      bus_number       = disk.value.bus_number
      # RAC 必须参数：厚盘置零 + 多写入者
      eagerly_scrub    = true
      thin_provisioned = false
      shared           = true 
    }
  }
}

# --- Node 2: 仅引用 Node 1 已创建好的磁盘 ---
resource "vsphere_virtual_machine" "rac_node_2" {
  name       = "Oracle-RAC-Node2"
  depends_on = [vsphere_virtual_machine.rac_node_1] # 必须等 Node1 创建完磁盘

  resource_pool_id = data.vsphere_resource_pool.pool.id
  datastore_id     = data.vsphere_datastore.ds.id
  
  num_cpus = 8
  memory   = 32768
  guest_id = "rhel8_64Guest"

  # 系统盘
  disk {
    label = "disk0"
    size  = 100
  }

  # 挂载 Node 1 的共享磁盘
  dynamic "disk" {
    for_each = flatten([
      for key, config in locals.shared_disks : [
        for i in range(config.count) : {
          index       = i
          bus_number  = config.bus_number
          unit_number = i < 7 ? i : i + 1
          # 根据 Node1 的磁盘列表获取路径
          # 我们跳过 Node1 的第一个系统盘 (index 0)
          node1_disk_index = (key == "ctrl1" ? i + 1 : (key == "ctrl2" ? i + 4 : i + 12))
        }
      ]
    ])

    content {
      label        = "attached-${disk.value.node1_disk_index}"
      attach       = true
      path         = vsphere_virtual_machine.rac_node_1.disk[disk.value.node1_disk_index].path
      unit_number  = disk.value.unit_number
      bus_number   = disk.value.bus_number
      shared       = true # Node 2 也要开启 MultiWriter
    }
  }
}
