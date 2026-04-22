output "talosconfig" {
  value       = data.talos_client_configuration._.talos_config
  description = "The talosconfig (in raw text format) of the provisioned cluster."
  sensitive   = true
}

output "kubeconfig" {
  value       = talos_cluster_kubeconfig._.kubeconfig_raw
  description = "The kubeconfig (in raw text format) of the provisioned cluster."
  sensitive   = true
}
