output "namespaces" {
  value = sort([for ns in kubernetes_namespace_v1.ns : ns.metadata[0].name])
}
