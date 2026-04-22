variable "talos_cluster_name" {
  type        = string
  default     = null
  description = <<-EOT
  Short, unique, alphanumeric identifier for the cluster.
  
  This will be used to name some Proxmox resources (like
  the user and token ID used by the Proxmox CSI plugin),
  which is why it should be unique and not contain fancy
  characters.

  If you don't specify one, a 4-lowercase-letter random
  string will be generated.
  EOT
}

resource "random_string" "talos_cluster_name" {
  length  = 4
  lower   = true
  upper   = false
  numeric = false
  special = false
}

locals {
  talos_cluster_name = coalesce(
    var.talos_cluster_name,
    random_string.talos_cluster_name.result
  )
}

variable "talos_version" {
  type        = string
  default     = null
  description = <<-EOT
  Talos version to use, for instance "v1.12.6".
  (Make sure to have the "v" prefix in the beginning.)

  If you don't specify one, it will use the latest stable
  version available.
  EOT
}

data "talos_image_factory_versions" "_" {
  filters = {
    stable_versions_only = true
  }
}

locals {
  talos_version = coalesce(
    var.talos_version,
    element(data.talos_image_factory_versions._.talos_versions, -1)
  )
}

variable "talos_extensions" {
  type        = list(string)
  default     = []
  description = <<-EOT
  List of talos extensions to include in the images, for instance:
  
  [ "siderolabs/amd-ucode", "siderolabs/amdgpu", "siderolabs/zfs" ]

  By default, no extension will be included.
  EOT
}

variable "kubernetes_version" {
  type        = string
  default     = null
  description = <<-EOT
  Kubernetes version to install, for instance v1.35.2 (don't forget the 'v').

  If none is specified, we will retrieve https://dl.k8s.io/release/stable.txt
  to know what's the latest stable release.
  EOT
}

data "http" "latest_stable_kubernetes_version" {
  url = "https://dl.k8s.io/release/stable.txt"
}

locals {
  kubernetes_version = coalesce(
    var.kubernetes_version,
    data.http.latest_stable_kubernetes_version.response_body
  )
}

variable "kubernetes_nodes" {
  # Note: the key in the map will be the Proxmox VM ID.
  type = map(object({
    hostname     = string,
    hypervisor   = string,
    memory_mb    = number,
    cpu_cores    = number,
    disk_gb      = number,
    machine_type = string,
    networking = list(object({
      bridge       = string,
      ipv4_address = string,
      ipv4_gateway = optional(string),
      ipv6_address = string,
    }))
  }))
  description = <<-EOT
  Map of Kubernetes nodes (=Proxmox virtual machines) to create.

  The *key* should be the Proxmox VM ID.
  The *value* is an object describing the VM.
  'hostname' is the hostname of the Kubernetes node.
  'hypervisor' is the name of the Proxmox node where to create that VM.
  'machine_type' should be 'worker' or 'controlplane'.
  The VM will have one network interface for each element in the 'networking' list.
  'ipv4_address' and 'ipv6_address' need to include the subnet netmask size, for instance
  '192.168.1.55/24' or 'fd7e:295a::3/64'.
  EOT
}

variable "kubernetes_api_endpoint" {
  type        = string
  default     = null
  description = <<-EOT
  URL of the Kubernetes API endpoint, for instance https://k8s-api-lb:6443.

  If it's not set, we'll just use the IPV4 address of the first controlplane node.
  Note: if you set this field, then you will have to set up something outside of
  the control of this module; like an API load balancer, DNS entries, etc.

  This will not be used by this module (in other words: if you put a bogus value,
  it should still work) but it will be included in the generated 'kubeconfig'
  output, and the relevant SAN will be included in the certificate of the API
  server of the provisioned cluster.
  EOT
}

locals {
  kubernetes_api_endpoint = coalesce(
    var.kubernetes_api_endpoint,
    "https://${local.first_node_addr}:6443"
  )
}

variable "proxmox_api_endpoint" {
  type        = string
  description = <<-EOT
  URL of the Proxmox API endpoint that will be used by the Proxmox CSI plugin,
  for instance https://192.168.1.11:8006/api2/json.
  EOT
}

variable "proxmox_cluster_name" {
  type        = string
  default     = "pve"
  description = <<-EOT
  Name of the Proxmox cluster. This will be added as the topology.kubernetes.io/region
  label, and it will be used by the CSI driver. Since this module doesn't support
  Kubernetes clusters spanning multiple Proxmox clusters, this has only cosmetic purposes.
  You can set it to anything you like (as long as it's a valid Kubernetes label value),
  or leave the default value.
  EOT
}

variable "kubernetes_ipv4_svccidr" {
  type        = string
  default     = null
  description = <<-EOT
  IPV4 CIDR to use for Kubernetes services, for instance 10.96.0.0/12.

  If you don't specify a value, a random /16 will be picked within 10.0.0.0/8.
  EOT
}

variable "kubernetes_ipv4_podcidr" {
  type        = string
  default     = null
  description = <<-EOT
  IPV4 CIDR to use for Kubernetes pods, for instance 10.244.0.0/16.

  If you don't specify a value, a random /16 will be picked within 10.0.0.0/8.
  EOT
}

variable "kubernetes_ipv4_cidrsize" {
  type        = number
  default     = 24
  description = <<-EOT
  Size of the IPV4 CIDR allocated to each Kubernetes node.
  EOT
}

variable "kubernetes_ipv6_svccidr" {
  type        = string
  default     = null
  description = <<-EOT
  IPV6 CIDR to use for Kubernetes services, for instance fd96::/112.

  If you don't specify a value, a random /112 will be picked within fddf::/16.
  EOT
}

variable "kubernetes_ipv6_podcidr" {
  type        = string
  default     = null
  description = <<-EOT
  IPV6 CIDR to use for Kubernetes pods, for instance fd44::/112.

  If you don't specify a value, a random /112 will be picked within fddf::/16.
  EOT
}

variable "kubernetes_ipv6_cidrsize" {
  type        = number
  default     = 120
  description = <<-EOT
  Size of the IPV6 CIDR allocated to each Kubernetes node.
  EOT
}

resource "random_integer" "cidr_base" {
  min = 1
  max = 128
}

locals {
  kubernetes_ipv4_svccidr = coalesce(
    var.kubernetes_ipv4_svccidr,
    "10.${2 * random_integer.cidr_base.result - 1}.0.0/16"
  )
  kubernetes_ipv4_podcidr = coalesce(
    var.kubernetes_ipv4_svccidr,
    "10.${2 * random_integer.cidr_base.result}.0.0/16"
  )
  kubernetes_ipv4_cidrsize = var.kubernetes_ipv4_cidrsize
  kubernetes_ipv6_svccidr = coalesce(
    var.kubernetes_ipv6_svccidr,
    "fddf:${2 * random_integer.cidr_base.result - 1}::/112"
  )
  kubernetes_ipv6_podcidr = coalesce(
    var.kubernetes_ipv6_podcidr,
    "fddf:${2 * random_integer.cidr_base.result}::/112"
  )
  kubernetes_ipv6_cidrsize = var.kubernetes_ipv6_cidrsize
}

# And all the stuff that gets passed "as-is".

locals {
  talos_extensions     = var.talos_extensions
  kubernetes_nodes     = var.kubernetes_nodes
  proxmox_api_endpoint = var.proxmox_api_endpoint
  proxmox_cluster_name = var.proxmox_cluster_name
}
