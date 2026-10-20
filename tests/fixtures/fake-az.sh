#!/usr/bin/env bash
# Azure CLI falso para os testes offline de scripts/ (tests/test_scripts.py).
# Os testes copiam este arquivo como `az` para um diretório temporário no início do PATH.
#
# Variáveis:
#   FAKE_CONTRACT  caminho do lab.contract.json (nomes e prioridades vêm dele)
#   FAKE_SCENARIO  good (ambiente correto) | bad (cada checkpoint tem ao menos um ❌)
#   FAKE_STATE     diretório onde o falso grava argv, KQL e o ambiente do deploy
#   FAKE_RG_EXISTS true|false (sobrescreve o cenário para `az group exists`; `group delete` vira false)
#   FAKE_RG_STATE  provisioningState do RG (padrão Succeeded); Deleting simula exclusão já em andamento
#   FAKE_FAIL      subcomando que deve falhar com erro não transitório (ex.: "group exists")
#   FAKE_FAIL_AFTER_DELETE  idem, mas só depois de `group delete` (polling do cleanup)
#   FAKE_TRANSIENT_ONCE  subcomando que devolve 429 uma única vez (testa o retry)
#   FAKE_MISSING_RCG     nome de RCG que responde NotFound
#   FAKE_INELIGIBLE_REGIONS  regiões (separadas por espaço) em que o validate devolve RequestDisallowedByAzure
set -uo pipefail

scen="${FAKE_SCENARIO:-good}"
state="${FAKE_STATE:?FAKE_STATE ausente}"
contract="${FAKE_CONTRACT:?FAKE_CONTRACT ausente}"
args="$*"
printf '%s\n' "$args" >>"$state/argv.log"

name=""
prev=""
body=""
for a in "$@"; do
  [[ "$prev" == "--name" || "$prev" == "-n" ]] && name="$a"
  [[ "$a" == @* ]] && body="${a#@}"
  prev="$a"
done

c() { jq -r "$1" "$contract"; }
zero="00000000-0000-0000-0000-000000000000"
rg="$(c .names.rg)"

if [[ -n "${FAKE_FAIL:-}" && "$args" == "${FAKE_FAIL}"* ]]; then
  echo "ERROR: (AuthorizationFailed) simulated failure" >&2
  exit 1
fi

# Falha só depois do `group delete`: exercita o polling do cleanup (a primeira consulta passa).
if [[ -n "${FAKE_FAIL_AFTER_DELETE:-}" && "$args" == "${FAKE_FAIL_AFTER_DELETE}"* && -e "$state/rg-deleted" ]]; then
  echo "ERROR: (AuthorizationFailed) simulated failure after delete" >&2
  exit 1
fi

# Falha transitória uma única vez: prova que o retry acontece e que o aviso não contamina o stdout capturado.
if [[ -n "${FAKE_TRANSIENT_ONCE:-}" && "$args" == "${FAKE_TRANSIENT_ONCE}"* && ! -e "$state/transient-done" ]]; then
  : >"$state/transient-done"
  echo "ERROR: (TooManyRequests) simulated throttling" >&2
  exit 1
fi

rcg_json() {
  jq -c --arg n "$1" --arg scen "$scen" '
    . as $c
    | ([$c.rcg | to_entries[] | select(.value.name == $n)][0]) as $g
    | if $g == null then null else
        {name: $n,
         priority: (if $scen == "bad" and ($g.value.e2Priority != null) then $g.value.e2Priority else $g.value.priority end),
         ruleCollections: [
           $c.rc | to_entries[] | select(.value.rcg == $g.key)
           | select($scen == "bad" or ((.value.createdBy | test("E3|E4")) | not))
           | {name: .value.name,
              rules: (if .key == "netCorpGuardrail" and $scen == "good" then [{name: $c.rules.denyRdpEw}]
                      elif .key == "appBaseline" and $scen == "bad" then [{name: $c.rules.allowMicrosoft}]
                      else [] end)}
         ]}
      end' "$contract"
}

case "$args" in
  "account show"*)
    echo "$zero" ;;
  "group exists"*)
    if [[ -e "$state/rg-deleted" ]]; then echo false
    elif [[ "${FAKE_RG_STATE:-}" == Deleting ]]; then
      # Exclusão já em andamento: a primeira consulta ainda vê o RG; as seguintes, não.
      if [[ -e "$state/rg-seen" ]]; then echo false; else : >"$state/rg-seen"; echo true; fi
    elif [[ -n "${FAKE_RG_EXISTS:-}" ]]; then echo "$FAKE_RG_EXISTS"
    elif [[ "$scen" == bad ]]; then echo true
    else echo false; fi ;;
  "group show"*)
    if [[ "$args" == *provisioningState* ]]; then echo "${FAKE_RG_STATE:-Succeeded}"; else echo "centralus"; fi ;;
  "group delete"*)
    : >"$state/rg-deleted" ;;
  "provider show"*)
    echo "Registered" ;;
  "bicep version"*)
    echo "Bicep CLI version 0.0.0" ;;
  "extension list"*)
    jq -r '.cliExtensions[]' "$contract" ;;
  "vm list-usage"*)
    echo '[{"name":{"value":"cores"},"limit":20,"currentValue":0},{"name":{"value":"standardBSv2Family"},"limit":20,"currentValue":0}]' ;;
  "network list-usages"*)
    echo '[{"name":{"value":"PublicIPAddresses"},"limit":20,"currentValue":0}]' ;;
  "rest"*Microsoft.Authorization/permissions*)
    echo '{"value":[{"actions":["*"],"notActions":[]}]}' ;;
  "rest"*Microsoft.Compute/skus*)
    # Só as regiões do contrato têm catálogo; qualquer outra devolve lista vazia, como uma região inexistente.
    re="location%20eq%20'([a-z0-9]+)'"
    region=""
    [[ "$args" =~ $re ]] && region="${BASH_REMATCH[1]}"
    if jq -e --arg r "$region" '.regions | index($r) != null' "$contract" >/dev/null; then
      # FAKE_SKU_RESTRICTION=zone|location restringe todos os SKUs da 1ª região do contrato.
      restriction="${FAKE_SKU_RESTRICTION:-}"
      jq -c --arg r "$region" --arg kind "$restriction" '
        (if $kind != "" and $r == .regions[0]
         then [{type: (if $kind == "zone" then "Zone" else "Location" end), reasonCode: "NotAvailableForSubscription", values: [$r]}]
         else [] end) as $restr
        | {value: [.vmSizes[] | {name: ., resourceType: "virtualMachines", family: "standardBSv2Family", restrictions: $restr,
        capabilities: [{name: "vCPUs", value: "2"}, {name: "MemoryGB", value: "4"}, {name: "HyperVGenerations", value: "V1,V2"}, {name: "CpuArchitectureType", value: "x64"}]}]}' "$contract"
    else
      echo '{"value":[]}'
    fi ;;
  "keyvault purge"*)
    : ;;
  "deployment sub create"*)
    printf '%s' "${LAB_ADMIN_PASSWORD-__UNSET__}" >"$state/password"
    printf '%s' "${LAB_EXPIRES_ON-}" >"$state/expires"
    printf '%s|%s|%s\n' "${LAB_REGION-}" "${LAB_VM_SIZE-}" "${LAB_TRUSTED_LAUNCH-}" >"$state/deploy-env" ;;
  "deployment sub validate"*)
    loc=""; p2=""
    for a in "$@"; do [[ "$p2" == "-l" || "$p2" == "--location" ]] && loc="$a"; p2="$a"; done
    printf '%s\n' "$loc" >>"$state/validated"
    if [[ " ${FAKE_INELIGIBLE_REGIONS:-} " == *" $loc "* ]]; then
      echo "ERROR: InvalidTemplateDeployment: RequestDisallowedByAzure: The selected region is currently not accepting new customers: https://aka.ms/locationineligible" >&2
      exit 1
    fi ;;
  "deployment sub list"*)
    echo "Succeeded" ;;
  "network firewall policy rule-collection-group show"*)
    json="$(rcg_json "$name")"
    if [[ "$json" == "null" || "$name" == "${FAKE_MISSING_RCG:-}" ]]; then echo "ERROR: (ResourceNotFound) $name" >&2; exit 3; fi
    echo "$json" ;;
  "network firewall policy show"*)
    if [[ "$scen" == good ]]; then
      parent="/subscriptions/$zero/resourceGroups/$rg/providers/Microsoft.Network/firewallPolicies/$(c .names.polParent)"
      law="/subscriptions/$zero/resourceGroups/$rg/providers/Microsoft.OperationalInsights/workspaces/$(c .names.law)"
      jq -cn --arg id "$parent" --arg law "$law" '{basePolicy: {id: $id}, intrusionDetection: {mode: "Deny"}, transportSecurity: {certificateAuthority: {name: "ca"}}, insights: {isEnabled: true, retentionDays: 30, logAnalyticsResources: {defaultWorkspaceId: {id: $law}}}}'
    else
      echo '{"intrusionDetection":{"mode":"Alert"}}'
    fi ;;
  "network firewall show"*)
    if [[ "$name" == "$(c .names.fwNs)" ]]; then
      echo '{"provisioningState":"Succeeded","ipConfigurations":[{"privateIPAddress":"10.130.0.4"}]}'
    else
      echo '{"provisioningState":"Succeeded","hubIPAddresses":{"privateIPAddress":"10.100.64.132"}}'
    fi ;;
  "resource show"*routingIntent*)
    jq -cn --arg fw "$(c .names.fwEw)" '{properties: {routingPolicies: [{name: "p", destinations: ["PrivateTraffic"], nextHop: ("/subscriptions/x/providers/Microsoft.Network/azureFirewalls/" + $fw)}]}}' ;;
  "resource show"*)
    if [[ "$scen" == bad ]]; then echo "ERROR: (ResourceNotFound)" >&2; exit 3; fi
    echo '{}' ;;
  "network vhub connection show"*)
    echo "Succeeded" ;;
  "network nic show-effective-route-table"*)
    if [[ "$scen" == good ]]; then
      cat <<'JSON'
{"value":[
 {"addressPrefix":["10.110.0.0/16"],"nextHopIpAddress":[],"nextHopType":"VnetLocal","source":"Default","state":"Active"},
 {"addressPrefix":["10.130.0.0/16"],"nextHopIpAddress":[],"nextHopType":"VNetPeering","source":"Default","state":"Active"},
 {"addressPrefix":["10.0.0.0/8"],"nextHopIpAddress":["10.100.64.132"],"nextHopType":"VirtualNetworkGateway","source":"VirtualNetworkGateway","state":"Active"},
 {"addressPrefix":["0.0.0.0/0"],"nextHopIpAddress":[],"nextHopType":"Internet","source":"Default","state":"Invalid"},
 {"addressPrefix":["0.0.0.0/0"],"nextHopIpAddress":["10.130.0.4"],"nextHopType":"VirtualAppliance","source":"User","state":"Active"}]}
JSON
    else
      # A rota 10/8 existe, mas não prova o E-W: uma aponta para outro IP, a outra (com o IP do FW) está Invalid.
      cat <<'JSON'
{"value":[
 {"addressPrefix":["10.110.0.0/16"],"nextHopIpAddress":[],"nextHopType":"VnetLocal","source":"Default","state":"Active"},
 {"addressPrefix":["10.0.0.0/8"],"nextHopIpAddress":["10.100.64.200"],"nextHopType":"VirtualNetworkGateway","source":"VirtualNetworkGateway","state":"Active"},
 {"addressPrefix":["10.0.0.0/8"],"nextHopIpAddress":["10.100.64.132"],"nextHopType":"VirtualNetworkGateway","source":"VirtualNetworkGateway","state":"Invalid"},
 {"addressPrefix":["0.0.0.0/0"],"nextHopIpAddress":["10.130.0.4"],"nextHopType":"VirtualAppliance","source":"User","state":"Active"}]}
JSON
    fi ;;
  "vm get-instance-view"*)
    jq -cn --arg cse "$(c .names.cse)" --arg marker "$(c .vm.bootstrapMarker)" \
      '{instanceView: {extensions: [{name: $cse, statuses: [{displayStatus: "Provisioning succeeded"}], substatuses: [{message: ($marker + " host=lab")}]}]}}' ;;
  "vm run-command invoke"*)
    # Formato real: StdOut com o resultado e StdErr vazio, nesta ordem.
    echo '{"value":[{"code":"ComponentStatus/StdOut/succeeded","message":"200"},{"code":"ComponentStatus/StdErr/succeeded","message":""}]}' ;;
  "monitor log-analytics workspace show"*)
    echo "$zero" ;;
  "monitor diagnostic-settings list"*)
    # Formato do az atual (AAZ): array achatado, sem envelope {value: ...}.
    if [[ "$scen" == good ]]; then
      jq -cn --arg law "$(c .names.law)" --arg rg "$rg" '[{name: "diag", workspaceId: ("/subscriptions/x/resourceGroups/" + $rg + "/providers/Microsoft.OperationalInsights/workspaces/" + $law), logAnalyticsDestinationType: "Dedicated"}]'
    else
      jq -cn --arg law "$(c .names.law)" '[{name: "diag", workspaceId: ("/x/workspaces/" + $law), logAnalyticsDestinationType: null}]'
    fi ;;
  "network ip-group show"*)
    if [[ "$scen" == good ]] || [[ "$name" == "$(c .names.ipgWlA)" ]]; then
      if [[ " $* " == *" --query name "* ]]; then printf '%s\n' "$name"; else jq -cn --arg n "$name" '{name: $n}'; fi
    else
      printf 'ERROR: (ResourceNotFound) %s not found\n' "$name" >&2
      exit 3
    fi ;;
  "network ip-group list"*)
    if [[ "$scen" == good ]]; then
      jq -c '[.names.ipgWlA, .names.ipgWlB, .names.ipgSpokes | {name: .}]' "$contract"
    else
      jq -c '[{name: .names.ipgWlA}]' "$contract"
    fi ;;
  "monitor action-group show"*|"monitor metrics alert show"*)
    echo '{}' ;;
  "rest"*api.loganalytics.io*)
    [[ -n "$body" ]] && jq -r .query "$body" >>"$state/kql.log"
    count=3
    [[ "$scen" == bad ]] && count=0
    echo "{\"tables\":[{\"name\":\"PrimaryResult\",\"columns\":[{\"name\":\"Count\",\"type\":\"long\"}],\"rows\":[[$count]]}]}" ;;
  "rest"*AlertsManagement*)
    if [[ "$scen" == good ]]; then
      jq -cn --arg a "$(c .names.alertAppDeny)" '{value: [{properties: {essentials: {alertRule: ("/subscriptions/x/providers/microsoft.insights/metricAlerts/" + $a), monitorCondition: "Resolved"}}}]}'
    else
      jq -cn --arg a "$(c .names.alertHealthNs)" '{value: [{properties: {essentials: {alertRule: ("/subscriptions/x/providers/microsoft.insights/metricAlerts/" + $a), monitorCondition: "Fired"}}}]}'
    fi ;;
  "resource list"*)
    if [[ "$scen" == good ]]; then echo '[]'; else echo '[{"name":"leftover"}]'; fi ;;
  "keyvault list-deleted"*)
    if [[ "$scen" == good ]]; then echo '[]'; else jq -c '[{name: (.names.kvPrefix + "abc"), properties: {location: .regions[0], vaultId: ("/subscriptions/x/resourceGroups/" + .names.rg + "/providers/Microsoft.KeyVault/vaults/" + .names.kvPrefix + "abc")}}, {name: (.names.kvPrefix + "other"), properties: {location: .regions[0], vaultId: ("/subscriptions/x/resourceGroups/rg-other/providers/Microsoft.KeyVault/vaults/" + .names.kvPrefix + "other")}}]' "$contract"; fi ;;
  *)
    echo "FAKE-AZ unhandled: $args" >&2
    exit 3 ;;
esac
