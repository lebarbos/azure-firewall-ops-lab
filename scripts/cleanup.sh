#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

confirm_cleanup() {
  local rg answer
  rg="$(rg_name)"
  read -r -p "Excluir $rg e purgar Key Vaults do lab? Digite 'sim' para confirmar: " answer
  [[ "${answer,,}" == "sim" ]] || die "Cleanup cancelado." "Nada foi alterado."
}

poll_rg_deleted() {
  local rg="$1" timeout=1800 start now exists
  start="$(date +%s)"
  while true; do
    # Três estados: "false" encerra; "true" continua; erro do az interrompe (não pode virar "removido").
    exists="$(retry_az az group exists --name "$rg" -o tsv)" \
      || die "Não foi possível consultar o resource group $rg durante a exclusão." "Rode ./scripts/cleanup.sh de novo; ele retoma de onde parou."
    [[ "$exists" == "false" ]] && break
    now="$(date +%s)"
    if (( now - start > timeout )); then
      die "Timeout aguardando a exclusão do resource group." "A exclusão continua no Azure: rode ./scripts/cleanup.sh de novo para retomar a espera."
    fi
    info "Exclusão em andamento..."
    sleep 20
  done
  ok "Resource group removido."
}

purge_deleted_keyvaults() {
  local prefix payload count row name location
  prefix="$(contract_name kvPrefix)"
  if ! payload="$(retry_az az keyvault list-deleted -o json)"; then
    warn "Não foi possível listar Key Vaults em soft-delete; o checkpoint CX vai conferir de novo."
    return 0
  fi
  # O prefixo é o padrão do Portal para TLS auto-gerado; filtrar pelo RG evita purgar vault de outro projeto.
  payload="$(jq --arg prefix "$prefix" --arg rg "$(rg_name)" \
    '[.[]? | select((.name | startswith($prefix)) and ((.properties.vaultId // "") | ascii_downcase | contains("/resourcegroups/" + ($rg | ascii_downcase) + "/")))]' <<<"$payload")"
  count="$(jq 'length' <<<"$payload")"
  if (( count == 0 )); then
    ok "Nenhum Key Vault $prefix* em soft-delete."
    return 0
  fi
  while IFS= read -r row; do
    name="$(jq -r '.name' <<<"$row")"
    location="$(jq -r '.properties.location // .location' <<<"$row")"
    info "Purgando Key Vault em soft-delete: $name ($location). Aguarde a conclusão..."
    # Síncrono de propósito: com --no-wait, o CX rodado em seguida ainda veria o vault em soft-delete.
    retry_az az keyvault purge --name "$name" --location "$location" >/dev/null || warn "Purge falhou para $name; verifique permissões e purge protection."
  done < <(jq -c '.[]' <<<"$payload")
}

tag_sweep() {
  local payload
  payload="$(retry_az az resource list --tag "workshop=$(contract_tag workshop)" -o json)"
  if jq -e 'length == 0' <<<"$payload" >/dev/null; then
    ok "Varredura por tag sem recursos remanescentes."
  else
    fail "Ainda há recursos com a tag do workshop:"
    jq -r '.[] | " - \(.id)"' <<<"$payload"
    return 1
  fi
}

rg_state() {
  # O resource group em exclusão expõe provisioningState "Deleting".
  retry_az az group show --name "$1" --query properties.provisioningState -o tsv
}

main() {
  cd "$ROOT"
  az_required
  local yes=false rg state
  if [[ "${1:-}" == "--yes" ]]; then
    yes=true
    shift
  fi
  [[ $# -eq 0 ]] || die "Argumento inválido: $*" "Uso: ./scripts/cleanup.sh [--yes]"
  rg="$(rg_name)"

  if ! rg_exists; then
    ok "Resource group $rg já não existe."
    purge_deleted_keyvaults
    tag_sweep
    ok "Cleanup já está concluído. Sugestão: rode ./scripts/checkpoint.sh CX."
    return 0
  fi

  state="$(rg_state "$rg")" \
    || die "Não foi possível ler o estado do resource group $rg." "Confira o login com 'az account show' e rode o cleanup de novo."
  # O Cloud Shell encerra sessões sem interação após 20 min; rodar de novo retoma a espera em vez de pedir outro delete.
  if [[ "$state" == "Deleting" ]]; then
    info "A exclusão de $rg já está em andamento; retomando a espera."
  else
    [[ "$yes" == "true" ]] || confirm_cleanup
    info "Solicitando exclusão assíncrona do resource group $rg..."
    retry_az az group delete --name "$rg" --yes --no-wait >/dev/null \
      || die "O Azure recusou a exclusão de $rg (mensagem acima)." "Se a exclusão já estiver em andamento, aguarde o RG sumir no Portal e rode o cleanup de novo; senão, confira locks e permissões."
  fi
  info "A exclusão pode passar de 20 min. Se o Cloud Shell desconectar, abra de novo e rode ./scripts/cleanup.sh: ele retoma a espera."
  poll_rg_deleted "$rg"
  purge_deleted_keyvaults
  tag_sweep
  ok "Cleanup concluído. Rode ./scripts/checkpoint.sh CX para confirmar."
}

main "$@"
