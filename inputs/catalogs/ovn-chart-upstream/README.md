# Standalone upstream OVN chart catalog

Owns one producer, `ovn-kubernetes-chart`: the upstream `helm/ovn-kubernetes` chart at the pinned
`v1.4.0` tree, plus a generated `values-nke.yaml`. It has no image, CNI package or node-image producers.

- Source: `https://github.com/ovn-kubernetes/ovn-kubernetes`, `v1.4.0`, commit
  `d6a3812d1bc1c36bf24c7eda0e86e9b13d84907d`. The lock is generated with
  `bin/nvkr catalog pin --dir inputs/catalogs/ovn-chart-upstream --tag v1.4.0 --timeout 5m ovn-kubernetes`.
- The chart's default image is `ghcr.io/ovn-kubernetes/ovn-kubernetes/ovn-kube-ubuntu:release-1.4`. No image is
  bound to a Build Digest; this is not the digest-bound chart in [`../ovn-upstream`](../ovn-upstream/registry.yaml).
- Toolchain images are full golang digests, so no toolchain-substitution overlay is needed.
- [`../node-images/release`](../node-images/release/registry.yaml) keeps its own copy of this producer because
  `nvke-cni-ovn` consumes it. A chart version or values change must be made in both catalogs.
