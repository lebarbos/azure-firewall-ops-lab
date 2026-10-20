#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

required_vcpus=4
required_public_ips=3
provider_timeout_seconds=900

fetch_paged_skus() {
  local sub="$1" region="$2" url payload next values result
  result='[]'
  url="https://management.azure.com/subscriptions/${sub}/providers/Microsoft.Compute/skus?api-version=2021-07-01&\$filter=location%20eq%20'${region}'"
  while [[ -n "$url" ]]; do
    payload="$(retry_az az rest --method get --url "$url" -o json)" || return 1
    values="$(jq -c '.value // []' <<<"$payload")"
    result="$(jq -sc '.[0] + .[1]' <(printf '%s' "$result") <(printf '%s' "$values"))"
    next="$(jq -r '.nextLink // empty' <<<"$payload")"
    url="$next"
  done
  printf '%s\n' "$result"
}

sku_cap() {
  local sku_json="$1" cap="$2"
  jq -r --arg cap "$cap" '.capabilities[]? | select(.name == $cap) | .value' <<<"$sku_json" | head -n1
}

quota_free() {
  local usage_json="$1" key="$2"
  jq -er --arg key "$key" '
    [ .[] | select((.name.value // "" | ascii_downcase) == ($key | ascii_downcase)) ][0]
    | ((.limit | tonumber) - (.currentValue | tonumber))
  ' <<<"$usage_json"
}

public_ip_free() {
  local usage_json="$1"
  jq -er '
    [ .[] | select((.name.value // "" | ascii_downcase) as $n
      | ($n == "publicipaddresses" or $n == "standardpublicipaddresses" or $n == "public ip addresses")) ][0]
    | ((.limit | tonumber) - (.currentValue | tonumber))
  ' <<<"$usage_json" 2>/dev/null || printf '0\n'
}

sku_restriction_reason() {
  # Só restrição de região bloqueia: as VMs do lab não usam Availability Zone,
  # então uma restrição do tipo "Zone" não as impede.
  jq -r '
    [ .restrictions[]? | select((.type // "" | ascii_downcase) == "location") ][0]
    | if . == null then "" else (.reasonCode // .type // "restrito") end
  '
}

assess_region() {
  local region="$1" sub="$2" forced_sku="${LAB_VM_SIZE:-}" skus usage net_usage row_file err_file
  row_file="$3"
  # stderr separado do JSON: avisos de retry não podem contaminar a saída capturada.
  err_file="${row_file}.err"
  local chosen="" chosen_trusted="" chosen_reason="" status="fail" ip_note=""

  if ! skus="$(fetch_paged_skus "$sub" "$region" 2>"$err_file")"; then
    jq -n --arg region "$region" --arg status fail --arg reason "Falha ao consultar SKUs: $(tail -n 3 "$err_file")" \
      '{region:$region,status:$status,reason:$reason,sku:"",trusted:"false",ipNote:""}' >"$row_file"
    return 0
  fi
  if ! usage="$(retry_az az vm list-usage --location "$region" -o json 2>"$err_file")"; then
    jq -n --arg region "$region" --arg status fail --arg reason "Falha ao consultar quota de VM: $(tail -n 3 "$err_file")" \
      '{region:$region,status:$status,reason:$reason,sku:"",trusted:"false",ipNote:""}' >"$row_file"
    return 0
  fi
  if ! net_usage="$(retry_az az network list-usages --location "$region" -o json 2>/dev/null)"; then
    net_usage='[]'
    ip_note="quota de IP público não comprovada"
  fi
  local ip_free
  ip_free="$(public_ip_free "$net_usage")"
  if [[ "$ip_free" =~ ^-?[0-9]+$ && "$ip_free" -lt "$required_public_ips" ]]; then
    ip_note="⚠️ IP público Standard livre=${ip_free}, recomendado=${required_public_ips}"
  elif [[ -z "$ip_note" ]]; then
    ip_note="IP público livre=${ip_free}"
  fi

  local sku_list=()
  if [[ -n "$forced_sku" ]]; then
    sku_list=("$forced_sku")
  else
    mapfile -t sku_list < <(contract_array '.vmSizes')
  fi

  local sku raw family vcpus mem hyperv arch trusted_disabled restriction regional_free family_free reason
  # Mostra o motivo de cada SKU recusado, não só o do último.
  local skip_reasons=()
  for sku in "${sku_list[@]}"; do
    raw="$(jq -c --arg sku "$sku" '[.[] | select(.name == $sku and (.resourceType | ascii_downcase) == "virtualmachines")][0] // empty' <<<"$skus")"
    if [[ -z "$raw" ]]; then
      skip_reasons+=("${sku}: SKU ausente no catálogo da região")
      continue
    fi
    restriction="$(sku_restriction_reason <<<"$raw")"
    if [[ -n "$restriction" ]]; then
      skip_reasons+=("${sku}: restrita (${restriction})")
      continue
    fi
    vcpus="$(sku_cap "$raw" vCPUs)"
    mem="$(sku_cap "$raw" MemoryGB)"
    hyperv="$(sku_cap "$raw" HyperVGenerations)"
    arch="$(sku_cap "$raw" CpuArchitectureType || true)"
    family="$(jq -r '.family // empty' <<<"$raw")"
    if [[ "$vcpus" != "2" || "$mem" != "4" ]]; then
      skip_reasons+=("${sku}: requer 2 vCPU/4 GiB, catálogo retornou ${vcpus}/${mem}")
      continue
    fi
    if [[ ",${hyperv^^}," != *",V2,"* ]]; then
      skip_reasons+=("${sku}: sem Hyper-V Gen2")
      continue
    fi
    if [[ -n "$arch" && "${arch,,}" != "x64" && "${arch,,}" != "amd64" ]]; then
      skip_reasons+=("${sku}: arquitetura x64 não comprovada")
      continue
    fi
    regional_free="$(quota_free "$usage" cores 2>/dev/null || printf -- '-1')"
    family_free="$(quota_free "$usage" "$family" 2>/dev/null || printf -- '-1')"
    if (( regional_free < required_vcpus )); then
      skip_reasons+=("${sku}: quota regional livre=${regional_free}, necessária=${required_vcpus}")
      continue
    fi
    if (( family_free < required_vcpus )); then
      skip_reasons+=("${sku}: quota da família ${family} livre=${family_free}, necessária=${required_vcpus}")
      continue
    fi
    trusted_disabled="$(sku_cap "$raw" TrustedLaunchDisabled || true)"
    chosen="$sku"
    chosen_trusted="true"
    if [[ "${trusted_disabled,,}" == "true" ]]; then
      chosen_trusted="false"
      chosen_reason="${sku}: disponível; TrustedLaunchDisabled"
    else
      chosen_reason="${sku}: disponível"
    fi
    status="ok"
    break
  done
  if [[ "$status" != "ok" && ${#skip_reasons[@]} -gt 0 ]]; then
    chosen_reason="$(IFS=';'; printf '%s' "${skip_reasons[*]}")"
    chosen_reason="${chosen_reason//;/; }"
  fi

  jq -n --arg region "$region" --arg status "$status" --arg reason "$chosen_reason" \
    --arg sku "$chosen" --arg trusted "$chosen_trusted" --arg ipNote "$ip_note" \
    '{region:$region,status:$status,reason:$reason,sku:$sku,trusted:$trusted,ipNote:$ipNote}' >"$row_file"
}

register_provider_if_needed() {
  local namespace="$1" required="$2" state=""
  state="$(retry_az az provider show --namespace "$namespace" --query registrationState -o tsv 2>/dev/null || true)"
  if [[ "${state,,}" == "registered" ]]; then
    ok "Provider registrado: $namespace"
    return 0
  fi
  warn "Provider ausente ou pendente: $namespace (${state:-desconhecido}); registrando."
  if ! retry_az az provider register --namespace "$namespace" --only-show-errors >/dev/null; then
    if [[ "$required" == "false" ]]; then
      warn "Não foi possível registrar o provider opcional $namespace; o Ex6 pode precisar dele."
      return 0
    fi
    die "Não foi possível registrar o provider $namespace (mensagem acima)." "Registrar providers exige Owner ou Contributor na assinatura."
  fi
  if [[ "$required" == "false" ]]; then
    return 0
  fi
  local start now
  start="$(date +%s)"
  while true; do
    state="$(retry_az az provider show --namespace "$namespace" --query registrationState -o tsv 2>/dev/null || true)"
    if [[ "${state,,}" == "registered" ]]; then
      ok "Provider registrado: $namespace"
      return 0
    fi
    now="$(date +%s)"
    if (( now - start > provider_timeout_seconds )); then
      die "Timeout aguardando provider: $namespace" "Confira permissões na assinatura e tente novamente."
    fi
    info "Aguardando provider $namespace ($state)..."
    sleep 10
  done
}

check_permissions() {
  local sub permissions err_file
  sub="$1"
  err_file="$(mktemp "${TMPDIR:-/tmp}/fwlab-perm.XXXXXX")"
  if ! permissions="$(retry_az az rest --method get --url "https://management.azure.com/subscriptions/${sub}/providers/Microsoft.Authorization/permissions?api-version=2022-04-01" -o json 2>"$err_file")"; then
    warn "Não foi possível verificar permissões de deploy. Mensagem completa:"
    cat "$err_file" >&2
    rm -f "$err_file"
    return 0
  fi
  rm -f "$err_file"
  if jq -e '
    [.value[]?.actions[]?] as $a
    | ($a | index("*")) or ($a | index("Microsoft.Resources/deployments/*")) or ($a | index("Microsoft.Resources/deployments/write"))
  ' <<<"$permissions" >/dev/null; then
    ok "Permissão Microsoft.Resources/deployments/write detectada."
  else
    fail "Permissão Microsoft.Resources/deployments/write não detectada."
    printf '%s\n' "$permissions" >&2
    exit 1
  fi
}

validate_region() {
  # 0 = elegível · 10 = região recusa a assinatura · outro = falha diferente (stderr já impresso).
  local region="$1" sku="$2" trusted="$3" err status=0
  err="$(mktemp "${TMPDIR:-/tmp}/fwlab-validate.XXXXXX")"
  # Senha descartável só para o validate (nada é criado); a real é pedida pelo deploy.sh.
  LAB_ADMIN_PASSWORD="Vd1-$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')-Lab" \
    LAB_REGION="$region" LAB_VM_SIZE="$sku" LAB_TRUSTED_LAUNCH="$trusted" \
    retry_az az deployment sub validate -l "$region" -n "fwlab-preflight-$region" \
      --parameters infra/main.bicepparam -o none 2>"$err" >/dev/null || status=$?
  if ((status != 0)); then
    if grep -Eq 'RequestDisallowedByAzure|locationineligible|not accepting new customers' "$err"; then
      status=10
    else
      cat "$err" >&2
    fi
  fi
  rm -f "$err"
  return "$status"
}

main() {
  cd "$ROOT"
  az_required
  local rg sub
  rg="$(rg_name)"

  info "Confirmando assinatura atual..."
  sub="$(subscription_id)"
  print_kv "Subscription" "$sub"
  check_permissions "$sub"

  info "Registrando providers do contrato..."
  local p
  while IFS= read -r p; do
    register_provider_if_needed "$p" true
  done < <(contract_array '.requiredProviders')
  while IFS= read -r p; do
    register_provider_if_needed "$p" false
  done < <(contract_array '.optionalProviders')

  retry_az az bicep version >/dev/null || die "Bicep indisponível no Azure CLI." "Rode 'az bicep install' e repita o preflight."
  ok "Bicep disponível no Azure CLI."

  local installed_ext missing_ext=()
  installed_ext="$(retry_az az extension list --query '[].name' -o tsv 2>/dev/null || true)"
  while IFS= read -r p; do
    if ! grep -Fxq "$p" <<<"$installed_ext"; then
      missing_ext+=("$p")
    fi
  done < <(contract_array '.cliExtensions')
  if ((${#missing_ext[@]})); then
    warn "Extensões do Azure CLI ausentes (não serão instaladas automaticamente): ${missing_ext[*]}"
    for p in "${missing_ext[@]}"; do
      printf '   az extension add --name %q\n' "$p"
    done
  else
    ok "Extensões do Azure CLI exigidas pelo guia estão presentes."
  fi

  if rg_exists; then
    local existing_region selected_size trusted
    existing_region="$(rg_location)"
    selected_size="${LAB_VM_SIZE:-$(contract_get '.vmSizes[0]')}"
    trusted="${LAB_TRUSTED_LAUNCH:-true}"
    ok "Resource group existente detectado: $rg em $existing_region. Usando essa região; nada será reimplantado pelo preflight."
    write_env_file "$existing_region" "$selected_size" "$trusted"
    return 0
  fi

  local regions=()
  if [[ -n "${LAB_REGION:-}" ]]; then
    regions=("$LAB_REGION")
  else
    mapfile -t regions < <(contract_array '.regions')
  fi

  info "Avaliando regiões em paralelo..."
  local tmpdir pids=() files=() region i
  tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/fwlab-preflight.XXXXXX")"
  for i in "${!regions[@]}"; do
    region="${regions[$i]}"
    files+=("$tmpdir/$i.json")
    assess_region "$region" "$sub" "${files[$i]}" &
    pids+=("$!")
  done
  for p in "${pids[@]}"; do
    wait "$p"
  done

  printf '\n%-18s %-7s %-22s %s\n' "Região" "Status" "SKU" "Motivo"
  printf '%-18s %-7s %-22s %s\n' "------" "------" "---" "------"
  local chosen_region="" chosen_sku="" chosen_trusted="" row status icon reason ip_note candidates=()
  for i in "${!regions[@]}"; do
    row="$(cat "${files[$i]}")"
    status="$(jq -r '.status' <<<"$row")"
    icon="❌"
    [[ "$status" == "ok" ]] && icon="✅"
    reason="$(jq -r '.reason' <<<"$row")"
    ip_note="$(jq -r '.ipNote' <<<"$row")"
    printf '%-18s %-7s %-22s %s%s\n' \
      "$(jq -r '.region' <<<"$row")" "$icon" "$(jq -r '.sku // ""' <<<"$row")" "$reason" "${ip_note:+; $ip_note}"
    if [[ "$status" == "ok" ]]; then
      candidates+=("$(jq -r '[.region, .sku, (.trusted|tostring)] | join(" ")' <<<"$row")")
    fi
  done
  rm -rf "$tmpdir"

  # SKU e quota não revelam se a região aceita a assinatura: na trial, uma região pode recusar tudo
  # (RequestDisallowedByAzure, aka.ms/locationineligible). O validate do ARM não cria recursos.
  local cand c_region c_sku c_trusted rc
  for cand in "${candidates[@]}"; do
    read -r c_region c_sku c_trusted <<<"$cand"
    info "Validando o template em $c_region ($c_sku) com o ARM — não cria recursos..."
    rc=0
    validate_region "$c_region" "$c_sku" "$c_trusted" || rc=$?
    if ((rc == 0)); then
      chosen_region="$c_region"; chosen_sku="$c_sku"; chosen_trusted="$c_trusted"
      ok "$c_region aceita o deployment do lab."
      break
    elif ((rc == 10)); then
      warn "❌ $c_region: a região não aceita novos recursos nesta assinatura (RequestDisallowedByAzure · aka.ms/locationineligible). Tentando a próxima."
    else
      die "A validação do template falhou em $c_region por outro motivo (acima)." "Leia o erro; se for transitório, repita o preflight."
    fi
  done

  if [[ -z "$chosen_region" ]]; then
    die "Nenhuma combinação região × SKU atende ao contrato." "Tente definir LAB_REGION/LAB_VM_SIZE ou ajuste quota/região."
  fi
  write_env_file "$chosen_region" "$chosen_sku" "$chosen_trusted"
  ok "Selecionado: LAB_REGION=$chosen_region · LAB_VM_SIZE=$chosen_sku · LAB_TRUSTED_LAUNCH=$chosen_trusted"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
