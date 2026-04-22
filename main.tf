locals {
  first_node_id      = [for k, v in local.kubernetes_nodes : k if v.machine_type == "controlplane"][0]
  first_node         = local.kubernetes_nodes[local.first_node_id]
  first_node_addr    = split("/", local.first_node.networking[0].ipv4_address)[0]
  kubernetes_version = data.talos_machine_configuration._[local.first_node_id].kubernetes_version
  proxmox_nodes      = toset([for k, v in local.kubernetes_nodes : v.hypervisor])
}

# Note: do not specify talos_version in there!
# Otherwise, when the talos_version gets updated (which could happen
# automatically, since the default value is computed dynamically)
# this will cause a replacement of that resource, which will invalidate
# all cluster secrets (and generally break everything).
resource "talos_machine_secrets" "_" {
}

data "talos_client_configuration" "_" {
  cluster_name         = local.talos_cluster_name
  client_configuration = talos_machine_secrets._.client_configuration
  nodes                = [for k, v in local.kubernetes_nodes : split("/", v.networking[0].ipv4_address)[0]]
  endpoints            = [for k, v in local.kubernetes_nodes : split("/", v.networking[0].ipv4_address)[0] if v.machine_type == "controlplane"]
}

data "talos_machine_configuration" "_" {
  for_each         = local.kubernetes_nodes
  cluster_name     = local.talos_cluster_name
  cluster_endpoint = local.kubernetes_api_endpoint
  talos_version    = local.talos_version
  machine_type     = each.value.machine_type
  machine_secrets  = talos_machine_secrets._.machine_secrets
}

resource "proxmox_virtual_environment_vm" "_" {
  for_each    = local.kubernetes_nodes
  node_name   = each.value.hypervisor
  name        = each.value.hostname
  description = "Talos ${each.value.machine_type} node for cluster ${local.talos_cluster_name}"
  tags        = [local.talos_cluster_name]
  on_boot     = true
  vm_id       = each.key

  # We use OVMF instead of the default (SeaBIOS), because this gives us a
  # high resolution text console. Normally we wouldn't care *at all* about
  # the text console; but Talos spawns a dashboard on the console, and it's
  # nice to have that dashboard in high resolution to see logs when things
  # go sideways.
  bios = "ovmf"
  efi_disk {
    datastore_id = "local-zfs"
  }

  # There seems to be a bug either in Proxmox or the Proxmox Terraform provider.
  # Sometimes it detects the architecture has having changed, which causes
  # an update to the VM, which in turn causes a reboot. Let's ignore that field.
  lifecycle {
    ignore_changes = [cpu[0].architecture]
  }

  cpu {
    cores = each.value.cpu_cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = each.value.memory_mb
  }

  disk {
    datastore_id = "local-zfs"
    interface    = "virtio0"
    discard      = "on"
    size         = each.value.disk_gb
  }

  cdrom {
    file_id = proxmox_virtual_environment_download_file.talos_disk_image["${each.value.hypervisor}"].id
  }

  boot_order = ["virtio0", "ide3"]

  operating_system {
    type = "l26"
  }

  dynamic "network_device" {
    for_each = each.value.networking
    content {
      bridge = network_device.value.bridge
    }
  }

  initialization {
    datastore_id = "local-zfs"
    dns {
      servers = ["1.0.0.1", "1.1.1.1"]
    }
    dynamic "ip_config" {
      for_each = each.value.networking
      content {
        ipv4 {
          address = ip_config.value.ipv4_address
          gateway = lookup(ip_config.value, "ipv4_gateway", null)
        }
        ipv6 {
          address = ip_config.value.ipv6_address
        }
      }
    }
  }
}

resource "talos_machine_configuration_apply" "_" {
  depends_on                  = [proxmox_virtual_environment_vm._]
  for_each                    = local.kubernetes_nodes
  node                        = split("/", each.value.networking[0].ipv4_address)[0]
  client_configuration        = talos_machine_secrets._.client_configuration
  machine_configuration_input = data.talos_machine_configuration._[each.key].machine_configuration
  config_patches = [
    # Since we boot from an ISO image, we need to install Talos on a disk.
    yamlencode({
      machine = {
        install = {
          disk  = "/dev/vda"
          image = data.talos_image_factory_urls._.urls.installer
        }
      }
    }),
    # This is the "magic" that enables dual stack on the Kubernetes cluster.
    # Note: it's also necessary that the CNI configuration+plugin that we use supports it!
    yamlencode({
      cluster = {
        controllerManager = {
          extraArgs = {
            "node-cidr-mask-size-ipv4" = local.kubernetes_ipv4_cidrsize
            "node-cidr-mask-size-ipv6" = local.kubernetes_ipv6_cidrsize
          }
        }
        network = {
          podSubnets     = [local.kubernetes_ipv6_podcidr, local.kubernetes_ipv4_podcidr]
          serviceSubnets = [local.kubernetes_ipv6_svccidr, local.kubernetes_ipv4_svccidr]
        }
      }
    }),
    # Disable the default CNI, as we're going to use Cilium instead.
    yamlencode({
      cluster = {
        network = {
          cni = {
            name = "none"
          }
        }
      }
    }),
    # Disable kube-proxy; we're also going to use Cilium there.
    # The kubePrism bit is here to allow Cilium to contact the k8s API server
    # (since we obviously can't use kube-proxy for that purpose).
    yamlencode({
      cluster = {
        proxy = {
          disabled = true
        }
      }
      machine = {
        features = {
          kubePrism = {
            enabled = true
            port    = 7445
          }
        }
      }
    }),
    # This is required by the Proxmox CSI plugin.
    yamlencode({
      machine = {
        nodeLabels = {
          "topology.kubernetes.io/region" = local.proxmox_cluster_name
          "topology.kubernetes.io/zone"   = each.value.hypervisor
        }
      }
    }),
    # And this is how we preload Cilium and a few other things.
    # Note: if you're adding new manifests here to an existing cluster,
    # they will be applied immediately by Talos; however, if you update
    # or remove manifests, the changes will be applied only when you
    # run 'talosctl upgrade-k8s'.
    yamlencode({
      cluster = {
        inlineManifests = [
          {
            name     = "cilium"
            contents = data.helm_template.cilium.manifest
          },
          {
            name     = "proxmox-csi-plugin"
            contents = data.helm_template.proxmox-csi-plugin.manifest
          },
          {
            name     = "metrics-server"
            contents = data.helm_template.metrics-server.manifest
          },
        ]
      }
    })
  ]
}

# Note: this merely sends a request to the Talos API running on the first node,
# but it doesn't wait for completion; so Terraform/Tofu will report that the
# configuration has been applied, but the cluster will take a minute or so to
# become truly available.
resource "talos_machine_bootstrap" "_" {
  depends_on           = [talos_machine_configuration_apply._]
  node                 = local.first_node_addr
  client_configuration = talos_machine_secrets._.client_configuration
}

resource "proxmox_virtual_environment_role" "csi" {
  role_id = "csi-${local.talos_cluster_name}"
  privileges = [
    "VM.Audit",
    "VM.Config.Disk",
    "Datastore.Allocate",
    "Datastore.AllocateSpace",
    "Datastore.Audit"
  ]
}

resource "proxmox_virtual_environment_user" "csi" {
  user_id = "csi-${local.talos_cluster_name}@pve"
  acl {
    path      = "/"
    propagate = true
    role_id   = proxmox_virtual_environment_role.csi.role_id
  }
}

resource "proxmox_virtual_environment_user_token" "csi" {
  token_name            = "csi"
  user_id               = proxmox_virtual_environment_user.csi.user_id
  privileges_separation = false
}

resource "talos_cluster_kubeconfig" "_" {
  client_configuration = talos_machine_secrets._.client_configuration
  node                 = local.first_node_addr
}

# By default, the Cilium Helm chart generates a key and self-signed cert
# for Cilium's internal CA. This is fine when using a "normal" Helm workflow
# (with 'helm install' and then 'helm upgrade'), but it doesn't work anymore
# when using infra-as-code or gitops tools that render the Helm template
# like we do here, because each time we re-evaluate the template, it will
# generate a new key and certificate.
# To avoid that, we generate that key and certificate ourselves, and then
# pass them as Helm values when rendering the template.

resource "tls_private_key" "cilium" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "cilium" {
  private_key_pem = tls_private_key.cilium.private_key_pem

  subject {
    common_name = "Cilium CA (managed by Terrafu)"
  }

  validity_period_hours = 24 * 365

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

data "helm_template" "cilium" {
  namespace    = "kube-system"
  name         = "cilium"
  repository   = "https://helm.cilium.io"
  chart        = "cilium"
  version      = "1.19.2"
  kube_version = local.kubernetes_version
  values = [
    <<-YAML
    autoDirectNodeRoutes: true
    cgroup:
      autoMount:
        enabled: false
    cgroup:
      hostRoot: /sys/fs/cgroup
    hubble:
      tls:
        auto:
          method: cronjob
    clustermesh:
      apiserver:
        tls:
          auto:
            method: cronjob
    k8sServiceHost: localhost
    k8sServicePort: 7445
    ipam:
      mode: cluster-pool
      operator:
        clusterPoolIPv4MaskSize: ${local.kubernetes_ipv4_cidrsize}
        clusterPoolIPv4PodCIDRList: ${local.kubernetes_ipv4_podcidr}
        clusterPoolIPv6MaskSize: ${local.kubernetes_ipv6_cidrsize}
        clusterPoolIPv6PodCIDRList: ${local.kubernetes_ipv6_podcidr}
    ipv4NativeRoutingCIDR: ${local.kubernetes_ipv4_podcidr}
    ipv6NativeRoutingCIDR: ${local.kubernetes_ipv6_podcidr}
    ipv6:
      enabled: true
    l2announcements:
      enabled: true
    kubeProxyReplacement: true
    routingMode: native
    securityContext:
      capabilities:
        ciliumAgent: [CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID]
        cleanCiliumState: [NET_ADMIN,SYS_ADMIN,SYS_RESOURCE]
    tls:
      ca:
        cert: ${base64encode(tls_self_signed_cert.cilium.cert_pem)}
        key: ${base64encode(tls_self_signed_cert.cilium.private_key_pem)}
    YAML
  ]
}

data "helm_template" "proxmox-csi-plugin" {
  namespace  = "kube-system"
  name       = "proxmox-csi-plugin"
  repository = "oci://ghcr.io/sergelogvinov/charts"
  chart      = "proxmox-csi-plugin"
  version    = "0.5.6"
  values = [
    <<-YAML
    config:
      clusters:
        - url: "${local.proxmox_api_endpoint}"
          insecure: true
          token_id: "${proxmox_virtual_environment_user_token.csi.id}"
          token_secret: "${split("=", proxmox_virtual_environment_user_token.csi.value)[1]}"
          region: "${local.proxmox_cluster_name}"
    storageClass:
      - name: local-zfs
        storage: local-zfs
        fstype: xfs
        annotations:
          storageclass.kubernetes.io/is-default-class: "true"
      - name: ceph
        storage: ceph
        fstype: xfs
    YAML
  ]
}

data "helm_template" "metrics-server" {
  namespace  = "kube-system"
  name       = "metrics-server"
  repository = "https://kubernetes-sigs.github.io/metrics-server/"
  chart      = "metrics-server"
  version    = "3.13.0"
  values = [
    <<-YAML
    args:
      - --kubelet-insecure-tls
    YAML
  ]
}
