proxmox_api_endpoint = "https://192.168.1.201:8006/api2/json"
talos_cluster_name = "demo"
kubernetes_nodes = {
  131 = {
    hostname = "cp-1",
    hypervisor = "kansas",
    memory_mb = 2000,
    cpu_cores = 1,
    disk_gb = 50,
    machine_type = "controlplane",
    networking = [{
      bridge = "vmbr1",
      ipv4_address = "192.168.1.131/24",
      ipv6_address = "fd01::131/64",
      ipv4_gateway = "192.168.1.1",
    }],
  },
  132 = {
    hostname = "worker-1",
    hypervisor = "oregon",
    memory_mb = 4000,
    cpu_cores = 2,
    disk_gb = 100,
    machine_type = "worker",
    networking = [{
      bridge = "vmbr1",
      ipv4_address = "192.168.1.132/24",
      ipv6_address = "fd01::132/64",
      ipv4_gateway = "192.168.1.1",
    }],
  },
}
