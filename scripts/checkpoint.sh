#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

PASS=0
TOTAL=0

check() {
  local label="$1"
  shift
  TOTAL=$((TOTAL + 1))
  if "$@"; then
    PASS=$((PASS + 1))
    ok "$label"
  else
    fail "$label"
    return 0
  fi
}

query_true() {
  local json="$1" filter="$2"
  jq -e "$filter" <<<"$json" >/dev/null
}

show_fw() {
  retry_az az network firewall show --resource-group "$(rg_name)" --name "$1" -o json
}

show_policy() {
  retry_az az network firewall policy show --resource-group "$(rg_name)" --name "$1" -o json
}

show_rcg() {
  retry_az az network firewall policy rule-collection-group show \
    --resource-group "$(rg_name)" --policy-name "$1" --name "$2" -o json
}

exists_resource() {
  retry_az az resource show --ids "$1" --api-version "$2" -o none >/dev/null 2>&1
}

kql_count_positive() {
  local query="$1" customer_id result
  customer_id="$(workspace_customer_id)"
  result="$(kql_query "$customer_id" "$query")"
  jq -e '[.. | numbers] | any(. > 0)' <<<"$result" >/dev/null
}

fw_succeeded() {
  [[ "$(show_fw "$1" | jq -r '.provisioningState')" == "Succeeded" ]]
}

deployment_succeeded() {
  [[ "$(latest_subscription_deployment_state)" == "Succeeded" ]]
}

routing_intent_ok() {
  local rg vhub intent fw id payload
  rg="$(rg_name)"
  vhub="$(contract_name vhub)"
  intent="$(contract_name routingIntent)"
  fw="$(contract_name fwEw)"
  id="/subscriptions/$(subscription_id)/resourceGroups/${rg}/providers/Microsoft.Network/virtualHubs/${vhub}/routingIntent/${intent}"
  payload="$(retry_az az resource show --ids "$id" --api-version 2023-09-01 -o json)"
  jq -e --arg fw "$fw" '[.properties.routingPolicies[]? | select((.destinations[]? // "") == "PrivateTraffic" and (.nextHop // "" | contains($fw)))] | length > 0' <<<"$payload" >/dev/null
}

vhub_connection_ok() {
  retry_az az network vhub connection show \
    --resource-group "$(rg_name)" --vhub-name "$(contract_name vhub)" --name "$1" \
    --query 'provisioningState' -o tsv | grep -q '^Succeeded$'
}

effective_routes_ok() {
  local nic routes ns_ip ew_ip
  nic="$(contract_name nicA)"
  ns_ip="$(show_fw "$(contract_name fwNs)" | jq -r '((.ipConfigurations // .properties.ipConfigurations // [])[0] // {}) | (.privateIPAddress // .properties.privateIPAddress // empty)')"
  ew_ip="$(show_fw "$(contract_name fwEw)" | jq -r '(.hubIPAddresses // .properties.hubIPAddresses // {}) | (.privateIPAddress // empty)')"
  [[ -n "$ns_ip" && -n "$ew_ip" ]] || return 1
  warn "Consulta de rotas efetivas é lenta; isso leva ~1 min."
  routes="$(retry_az az network nic show-effective-route-table --resource-group "$(rg_name)" --name "$nic" -o json)"
  # Prova pelo IP do próximo salto, não pelo tipo. O tipo da rota do Routing Intent aparece como VirtualNetworkGateway.
  jq -e --arg ns "$ns_ip" --arg ew "$ew_ip" '
    [.value[]? | select((.state // "Active") == "Active")] as $r
    | any($r[]; ((.addressPrefix // []) | index("0.0.0.0/0")) != null and ((.nextHopIpAddress // []) | index($ns)) != null)
      and any($r[]; ((.addressPrefix // []) | index("10.0.0.0/8")) != null and ((.nextHopIpAddress // []) | index($ew)) != null)
  ' <<<"$routes" >/dev/null
}

cse_marker_ok() {
  local vm="$1" marker cse payload
  marker="$(contract_get '.vm.bootstrapMarker')"
  cse="$(contract_name cse)"
  payload="$(retry_az az vm get-instance-view --resource-group "$(rg_name)" --name "$vm" -o json)"
  jq -e --arg cse "$cse" --arg marker "$marker" '
    [.instanceView.extensions[]? | select(.name == $cse)][0] as $ext
    | ($ext.statuses[]?.displayStatus // "" | contains("succeeded"))
      and ([ $ext.substatuses[]?.message // "" ] | join("\n") | contains($marker))
  ' <<<"$payload" >/dev/null
}

iis_local_ok() {
  local vm="$1" output ps_script
  # shellcheck disable=SC2016
  ps_script='try { (Invoke-WebRequest -UseBasicParsing http://localhost).StatusCode } catch { "ERR: $($_.Exception.Message)" }'
  output="$(retry_az az vm run-command invoke --resource-group "$(rg_name)" --name "$vm" \
    --command-id RunPowerShellScript \
    --scripts "$ps_script" \
    -o json)"
  # Run Command returns StdOut and StdErr entries; only StdOut carries the status code.
  jq -e '[.value[]? | select((.code // "") | contains("StdOut")) | .message // ""] | any(contains("200"))' <<<"$output" >/dev/null
}

diag_ok() {
  local fw="$1" id payload law
  id="$(firewall_id "$fw")"
  law="$(contract_name law)"
  payload="$(retry_az az monitor diagnostic-settings list --resource "$id" -o json)"
  # O az atual (AAZ) devolve o array já achatado; versões antigas devolviam {value: [...]} com properties aninhadas.
  jq -e --arg law "$law" '
    [(if type == "array" then . else (.value // []) end)[]
      | select(((.workspaceId // .properties.workspaceId // "") | ascii_downcase | contains($law | ascii_downcase))
        and ((.logAnalyticsDestinationType // .properties.logAnalyticsDestinationType // "") == "Dedicated"))]
    | length > 0
  ' <<<"$payload" >/dev/null
}

ip_groups_ok() {
  # Consulta cada IP Group pelo nome, sem passar a lista inteira pelo jq: no piloto (06/10) a saída
  # do `ip-group list` no Cloud Shell chegou ao jq como texto não-JSON e o check falhou com os grupos criados.
  local rg key name found missing=()
  rg="$(rg_name)"
  for key in ipgWlA ipgWlB ipgSpokes; do
    name="$(contract_name "$key")"
    found="$(retry_az az network ip-group show --resource-group "$rg" --name "$name" --query name -o tsv | tr -d '\r')" || found=""
    [[ "$found" == "$name" ]] || missing+=("$name")
  done
  if ((${#missing[@]})); then
    printf '   IP Groups não encontrados em %s: %s\n' "$rg" "${missing[*]}" >&2
    return 1
  fi
}

rcg_exists() {
  show_rcg "$1" "$2" >/dev/null
}

rcg_priority_is() {
  [[ "$(show_rcg "$1" "$2" | jq -r '.priority')" == "$3" ]]
}

rc_absent() {
  local policy="$1" rcg="$2" rc="$3" payload
  # Sem ler o RCG não há prova de ausência: payload vazio faria o `!` virar ✅.
  payload="$(show_rcg "$policy" "$rcg")" || return 1
  ! jq -e --arg rc "$rc" '[.ruleCollections[]? | select(.name == $rc)] | length > 0' <<<"$payload" >/dev/null
}

rule_absent_or_collection_absent() {
  local policy rcg rc rule payload err_file
  policy="$(contract_name polNs)"
  rcg="$(contract_get '.rcg.baselineNs.name')"
  rc="$(contract_get '.rc.appBaseline.name')"
  rule="$(contract_get '.rules.allowMicrosoft')"
  err_file="$(mktemp "${TMPDIR:-/tmp}/fwlab-ckpt.XXXXXX")"
  if ! payload="$(show_rcg "$policy" "$rcg" 2>"$err_file")"; then
    # Só NotFound prova que o RCG saiu; erro de login ou permissão não prova nada.
    if ! grep -qi 'NotFound' "$err_file"; then
      cat "$err_file" >&2
      rm -f "$err_file"
      return 1
    fi
    payload='{}'
  fi
  rm -f "$err_file"
  jq -e --arg rc "$rc" --arg rule "$rule" '
    ([.ruleCollections[]? | select(.name == $rc)] | length == 0)
    or
    ([.ruleCollections[]? | select(.name == $rc) | .rules[]? | select(.name == $rule)] | length == 0)
  ' <<<"$payload" >/dev/null
}

children_have_parent() {
  local parent_id ns ew
  parent_id="$(policy_id "$(contract_name polParent)")"
  ns="$(show_policy "$(contract_name polNs)")"
  ew="$(show_policy "$(contract_name polEw)")"
  jq -e --arg id "$parent_id" '(.basePolicy.id // "") == $id' <<<"$ns" >/dev/null &&
    jq -e --arg id "$parent_id" '(.basePolicy.id // "") == $id' <<<"$ew" >/dev/null
}

action_group_ok() {
  retry_az az monitor action-group show --resource-group "$(rg_name)" --name "$(contract_name ag)" -o none >/dev/null
}

metric_alert_ok() {
  retry_az az monitor metrics alert show --resource-group "$(rg_name)" --name "$1" -o none >/dev/null
}

app_deny_fired() {
  local sub rg alert payload
  sub="$(subscription_id)"
  rg="$(rg_name)"
  alert="$(contract_name alertAppDeny)"
  # Alerts - Get All (API GA 2019-03-01). Toda instância, Fired ou já Resolved, prova o disparo; o filtro pelo nome da regra fica no jq.
  payload="$(retry_az az rest --method get --url "https://management.azure.com/subscriptions/${sub}/providers/Microsoft.AlertsManagement/alerts?api-version=2019-03-01&targetResourceGroup=${rg}&timeRange=1d" -o json)"
  jq -e --arg alert "$alert" '[.value[]? | select((.properties.essentials.alertRule // "") | ascii_downcase | endswith("/" + ($alert | ascii_downcase)))] | length > 0' <<<"$payload" >/dev/null
}

tls_ok() {
  # A CA fica no pai; a filha só tem transportSecurity se alguém marcou o override.
  local policy
  for policy in "$(contract_name polParent)" "$(contract_name polNs)"; do
    if show_policy "$policy" | jq -e '(.transportSecurity.certificateAuthority // .properties.transportSecurity.certificateAuthority // null) != null' >/dev/null; then
      return 0
    fi
  done
  return 1
}

policy_analytics_ok() {
  local law
  law="$(contract_name law)"
  show_policy "$(contract_name polNs)" | jq -e --arg law "$law" '
    (.insights // .properties.insights // {}) as $i
    | ($i.isEnabled == true)
      and (($i.logAnalyticsResources.defaultWorkspaceId.id // "") | ascii_downcase | endswith("/workspaces/" + ($law | ascii_downcase)))
  ' >/dev/null
}

idps_ok() {
  show_policy "$(contract_name polNs)" | jq -e '(.intrusionDetection.mode // .properties.intrusionDetection.mode // "") == "Deny"' >/dev/null
}

rg_absent() {
  local exists
  # Falha fechada: erro do az (sessão expirada, sem login) não pode virar "RG inexistente".
  exists="$(retry_az az group exists --name "$(rg_name)" -o tsv)" || return 1
  [[ "$exists" == "false" ]]
}

tag_scan_empty() {
  retry_az az resource list --tag "workshop=$(contract_tag workshop)" -o json | jq -e 'length == 0' >/dev/null
}

kv_deleted_empty() {
  local prefix
  prefix="$(contract_name kvPrefix)"
  # O prefixo é o padrão do Portal; só conta vault que veio do RG do lab.
  retry_az az keyvault list-deleted -o json 2>/dev/null | jq -e --arg prefix "$prefix" --arg rg "$(rg_name)" \
    '[.[]? | select((.name | startswith($prefix)) and ((.properties.vaultId // "") | ascii_downcase | contains("/resourcegroups/" + ($rg | ascii_downcase) + "/")))] | length == 0' >/dev/null
}

run_checkpoint() {
  local checkpoint="$1" rg pol_ns pol_ew
  rg="$(rg_name)"
  pol_ns="$(contract_name polNs)"
  pol_ew="$(contract_name polEw)"
  case "$checkpoint" in
    C0)
      check "Deployment concluído" deployment_succeeded
      check "Firewall N-S Succeeded" fw_succeeded "$(contract_name fwNs)"
      check "Firewall E-W Succeeded" fw_succeeded "$(contract_name fwEw)"
      check "Routing intent PrivateTraffic → FW E-W" routing_intent_ok
      check "Conexão A Succeeded" vhub_connection_ok "$(contract_name connA)"
      check "Conexão B Succeeded" vhub_connection_ok "$(contract_name connB)"
      check "Rotas efetivas da NIC A coerentes" effective_routes_ok
      check "CSE VM-A Succeeded + marcador" cse_marker_ok "$(contract_name vmA)"
      check "CSE VM-B Succeeded + marcador" cse_marker_ok "$(contract_name vmB)"
      check "IIS local VM-A responde" iis_local_ok "$(contract_name vmA)"
      check "IIS local VM-B responde" iis_local_ok "$(contract_name vmB)"
      ;;
    C1)
      check "Diagnostic setting no FW N-S" diag_ok "$(contract_name fwNs)"
      check "Diagnostic setting no FW E-W" diag_ok "$(contract_name fwEw)"
      check "3 IP Groups principais existem" ip_groups_ok
      check "RCG baseline na policy N-S" rcg_exists "$pol_ns" "$(contract_get '.rcg.baselineNs.name')"
      check "RCG baseline na policy E-W" rcg_exists "$pol_ew" "$(contract_get '.rcg.baselineEw.name')"
      check "Policy Analytics habilitado na policy N-S" policy_analytics_ok
      check "KQL tem Allow recente" kql_count_positive 'union isfuzzy=true AZFWNetworkRule, AZFWApplicationRule | where TimeGenerated > ago(30m) | where Action == "Allow" | count'
      check "KQL tem Deny recente" kql_count_positive 'union isfuzzy=true AZFWNetworkRule, AZFWApplicationRule | where TimeGenerated > ago(30m) | where Action == "Deny" | count'
      ;;
    C2)
      check "RCG wl-a em 200" rcg_priority_is "$pol_ns" "$(contract_get '.rcg.wlA.name')" "$(contract_get '.rcg.wlA.priority')"
      check "RCG wl-b de volta em 300" rcg_priority_is "$pol_ns" "$(contract_get '.rcg.wlB.name')" "$(contract_get '.rcg.wlB.priority')"
      check "Collection temporária $(contract_get '.rc.netWlBTemp.name') ausente" rc_absent "$pol_ns" "$(contract_get '.rcg.wlB.name')" "$(contract_get '.rc.netWlBTemp.name')"
      check "Collection temporária $(contract_get '.rc.appWlBDeny.name') ausente" rc_absent "$pol_ns" "$(contract_get '.rcg.wlB.name')" "$(contract_get '.rc.appWlBDeny.name')"
      ;;
    C3)
      check "Policy pai existe" exists_resource "$(policy_id "$(contract_name polParent)")" "2023-09-01"
      check "Filhas apontam para o pai" children_have_parent
      check "$(contract_get '.rules.allowMicrosoft') removida ou $(contract_get '.rc.appBaseline.name') ausente na filha" rule_absent_or_collection_absent
      ;;
    C4)
      check "Policy Analytics habilitado na policy N-S" policy_analytics_ok
      check "KQL tem dados agregados do Policy Analytics" kql_count_positive 'union isfuzzy=true AZFWApplicationRuleAggregation, AZFWNetworkRuleAggregation | where TimeGenerated > ago(6h) | count'
      ;;
    C5)
      check "Action Group existe" action_group_ok
      check "Alerta app deny existe" metric_alert_ok "$(contract_name alertAppDeny)"
      check "Alerta health N-S existe" metric_alert_ok "$(contract_name alertHealthNs)"
      check "$(contract_name alertAppDeny) teve ≥ 1 disparo" app_deny_fired
      ;;
    C6)
      check "TLS inspection habilitado" tls_ok
      check "IDPS em Alert and Deny" idps_ok
      check "RCG TLS existe" rcg_exists "$pol_ns" "$(contract_get '.rcg.tls.name')"
      check "KQL mostra TLS inspecionado" kql_count_positive 'AZFWApplicationRule | where TimeGenerated > ago(2h) | where IsTlsInspected == true | count'
      check "KQL mostra assinatura IDPS" kql_count_positive "AZFWIdpsSignature | where TimeGenerated > ago(2h) | where SignatureId == '$(contract_get '.targets.idpsSignatureId')' | count"
      ;;
    CX)
      check "Resource group $rg inexistente" rg_absent
      check "Nenhum recurso com tag workshop" tag_scan_empty
      check "Nenhum Key Vault $(contract_name kvPrefix)* em soft-delete" kv_deleted_empty
      ;;
    *)
      die "Checkpoint inválido: $checkpoint" "Use C0, C1, C2, C3, C4, C5, C6 ou CX."
      ;;
  esac
}

main() {
  cd "$ROOT"
  az_required
  [[ $# -eq 1 ]] || die "Uso inválido." "Uso: ./scripts/checkpoint.sh <C0|C1|C2|C3|C4|C5|C6|CX>"
  local checkpoint="${1^^}"
  run_checkpoint "$checkpoint"
  printf '\nResumo: %d/%d verificações passaram.\n' "$PASS" "$TOTAL"
  (( PASS == TOTAL ))
}

main "$@"
