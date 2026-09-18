#!/usr/bin/env bash
set -euo pipefail

readonly TARGETS=("1.35" "1.36")
readonly ADDONS=("vpc-cni" "coredns" "kube-proxy")

: "${CLUSTER_NAME:?Set CLUSTER_NAME}"
: "${AWS_REGION:?Set AWS_REGION}"
: "${TERRAGRUNT_DIR:?Set TERRAGRUNT_DIR}"

TG_BIN="${TG_BIN:-terragrunt}"
DRY_RUN="${DRY_RUN:-false}"
TIMEOUT="${TIMEOUT:-3600}"
AMI_RELEASES=("${AMI_RELEASE_135:-}" "${AMI_RELEASE_136:-}")

error() { echo "ERROR: $*" >&2; exit 1; }
eks() { aws --region "$AWS_REGION" eks "$@"; }

command -v aws >/dev/null || error "AWS CLI is required"
command -v "$TG_BIN" >/dev/null || error "$TG_BIN is required"
[[ -d "$TERRAGRUNT_DIR" ]] || error "Invalid TERRAGRUNT_DIR: $TERRAGRUNT_DIR"

cluster_version() {
  eks describe-cluster --name "$CLUSTER_NAME" --query cluster.version --output text
}

minor() {
  [[ "$1" =~ ^1\.([0-9]+)$ ]] || error "Invalid Kubernetes version: $1"
  printf '%d' "${BASH_REMATCH[1]}"
}

addon_version() {
  eks describe-addon-versions +    --addon-name "$1" +    --kubernetes-version "$2" +    --query 'addons[0].addonVersions[0].addonVersion' +    --output text
}

wait_for_cluster() {
  local deadline=$((SECONDS + TIMEOUT)) status=""
  until [[ "$status" == "ACTIVE" ]]; do
    (( SECONDS < deadline )) || error "Timed out waiting for cluster"
    status="$(eks describe-cluster --name "$CLUSTER_NAME" +      --query cluster.status --output text)"
    [[ "$status" == "FAILED" ]] && error "Cluster upgrade failed"
    [[ "$status" == "ACTIVE" ]] || sleep 30
  done
}

validate() {
  local target="$1" addon status version expected nodegroup
  [[ "$(cluster_version)" == "$target" ]] || error "Control plane is not on $target"

  for addon in "${ADDONS[@]}"; do
    read -r status version < <(eks describe-addon +      --cluster-name "$CLUSTER_NAME" +      --addon-name "$addon" +      --query 'addon.[status,addonVersion]' --output text)
    expected="$(addon_version "$addon" "$target")"
    [[ "$status" == "ACTIVE" && "$version" == "$expected" ]] ||
      error "$addon validation failed: $status, $version"
  done

  for nodegroup in $(eks list-nodegroups --cluster-name "$CLUSTER_NAME" +    --query 'nodegroups[]' --output text); do
    read -r status version < <(eks describe-nodegroup +      --cluster-name "$CLUSTER_NAME" +      --nodegroup-name "$nodegroup" +      --query 'nodegroup.[status,version]' --output text)
    [[ "$status" == "ACTIVE" && "$version" == "$target" ]] ||
      error "$nodegroup validation failed: $status, $version"
  done
}

upgrade() {
  local target="$1" ami="$2" current plan
  current="$(cluster_version)"

  (( $(minor "$current") >= $(minor "$target") )) && {
    echo "Skipping $target; current version is $current"
    return
  }
  (( $(minor "$target") == $(minor "$current") + 1 )) ||
    error "Non-sequential upgrade blocked: $current -> $target"

  export TF_VAR_eks_version="$target"
  export TF_VAR_cluster_version="$target"
  export TF_VAR_vpc_cni_version="$(addon_version vpc-cni "$target")"
  export TF_VAR_coredns_version="$(addon_version coredns "$target")"
  export TF_VAR_kube_proxy_version="$(addon_version kube-proxy "$target")"
  [[ -n "$ami" ]] && export TF_VAR_ami_release_version="$ami" ||
    unset TF_VAR_ami_release_version

  plan="${TMPDIR:-/tmp}/${CLUSTER_NAME}-${target}.tfplan"
  echo "Planning $current -> $target"
  "$TG_BIN" plan --terragrunt-working-dir "$TERRAGRUNT_DIR" -out="$plan"
  [[ "$DRY_RUN" == "true" ]] && return

  echo "Applying $current -> $target"
  "$TG_BIN" apply --terragrunt-working-dir "$TERRAGRUNT_DIR" +    -auto-approve "$plan"
  wait_for_cluster
  validate "$target"
  echo "Upgrade to $target completed"
}

aws sts get-caller-identity >/dev/null
[[ "$(cluster_version)" =~ ^1\.(34|35|36)$ ]] ||
  error "Expected EKS 1.34, 1.35, or 1.36"

for i in "${!TARGETS[@]}"; do
  upgrade "${TARGETS[$i]}" "${AMI_RELEASES[$i]}"
  [[ "$DRY_RUN" == "true" ]] && break
done

echo "$CLUSTER_NAME is running Kubernetes $(cluster_version)"
