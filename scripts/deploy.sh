#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

validate_password() {
  local password="$1" username="$2" length classes=0 lower user_lower
  lower="${password,,}"
  user_lower="${username,,}"
  length="${#password}"
  (( length >= 12 && length <= 123 )) || return 1
  [[ "$password" != @* ]] || return 1
  [[ "$lower" != *"$user_lower"* ]] || return 1
  [[ "$password" =~ [[:lower:]] ]] && classes=$((classes + 1))
  [[ "$password" =~ [[:upper:]] ]] && classes=$((classes + 1))
  [[ "$password" =~ [[:digit:]] ]] && classes=$((classes + 1))
  [[ "$password" =~ [^[:alnum:]] ]] && classes=$((classes + 1))
  (( classes >= 3 )) || return 1
  local forbidden=(
    "password" "password1" "p@ssword" "p@ssw0rd" "p@ssw0rd123"
    "admin123" "admin@123" "azure123" "labadmin123" "labadmin@123"
  )
  local item
  for item in "${forbidden[@]}"; do
    [[ "$lower" != "$item" ]] || return 1
  done
  return 0
}

expires_tomorrow() {
  if date -u -d '+1 day' +%F >/dev/null 2>&1; then
    date -u -d '+1 day' +%F
  else
    date -u -v+1d +%F
  fi
}

read_password_twice() {
  local p1 p2 username
  username="$(contract_get '.vm.adminUsername')"
  read -rsp "Senha do usuário ${username}: " p1
  printf '\n' >&2
  read -rsp "Confirme a senha: " p2
  printf '\n' >&2
  if [[ "$p1" != "$p2" ]]; then
    die "As senhas não conferem." "Execute novamente o deploy."
  fi
  if ! validate_password "$p1" "$username"; then
    die "Senha rejeitada pela validação local." "Use 12–123 caracteres, 3 de 4 classes, sem o usuário, sem @ inicial e sem senhas comuns."
  fi
  printf '%s' "$p1"
}

main() {
  cd "$ROOT"
  az_required
  local force=false
  if [[ "${1:-}" == "--force" ]]; then
    force=true
    shift
  fi
  [[ $# -eq 0 ]] || die "Argumento inválido: $*" "Uso: ./scripts/deploy.sh [--force]"

  load_env_file_if_needed
  if [[ -z "${LAB_REGION:-}" ]]; then
    die "LAB_REGION ausente." "Rode ./scripts/preflight.sh antes do deploy."
  fi
  LAB_VM_SIZE="${LAB_VM_SIZE:-$(contract_get '.vmSizes[0]')}"
  LAB_TRUSTED_LAUNCH="${LAB_TRUSTED_LAUNCH:-true}"

  if rg_exists && [[ "$force" == "false" ]]; then
    die "O resource group $(rg_name) já existe; deploy recusado." "Reexecutar o deploy desfaz o basePolicy do Ex3. Use --force só se quiser reconstruir a base."
  fi

  local password expires deployment_name prefix deploy_region deploy_size deploy_trusted
  password="$(read_password_twice)"
  expires="$(expires_tomorrow)"
  prefix="$(contract_name deploymentPrefix)"
  deployment_name="${prefix}-$(date -u +%Y%m%d%H%M%S)"
  deploy_region="$LAB_REGION"
  deploy_size="$LAB_VM_SIZE"
  deploy_trusted="$LAB_TRUSTED_LAUNCH"

  info "Disparando deploy assíncrono na região $deploy_region..."
  set +e
  # Atribuições prefixadas: o bash exporta só para os filhos de retry_az; a senha não entra em argv nenhum.
  LAB_ADMIN_PASSWORD="$password" \
  LAB_REGION="$deploy_region" \
  LAB_VM_SIZE="$deploy_size" \
  LAB_TRUSTED_LAUNCH="$deploy_trusted" \
  LAB_EXPIRES_ON="$expires" \
    retry_az az deployment sub create \
      --location "$deploy_region" \
      --name "$deployment_name" \
      --parameters infra/main.bicepparam \
      --no-wait
  local status=$?
  set -e
  unset password LAB_ADMIN_PASSWORD
  if (( status != 0 )); then
    die "Falha ao iniciar o deployment. A mensagem completa do Azure foi exibida acima." "Corrija a causa e execute novamente."
  fi
  ok "Deployment iniciado: $deployment_name"
  printf 'Portal: Subscription › Deployments › %s\n' "$deployment_name"
  printf 'CLI: az deployment sub show --name %q\n' "$deployment_name"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
