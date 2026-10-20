#!/usr/bin/env bash

if [[ -z "${BASH_VERSION:-}" || "${BASH_VERSINFO[0]}" -lt 5 ]]; then
  echo "❌ Bash 5+ é obrigatório. Use o Cloud Shell em Bash." >&2
  exit 2
fi

set -euo pipefail

COMMON_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd -- "$COMMON_DIR/../.." && pwd)"
CONTRACT="$ROOT/lab.contract.json"
LAB_DIR="$ROOT/.lab"
ENV_FILE="$LAB_DIR/env"

if [[ ! -f "$CONTRACT" ]]; then
  echo "❌ Contrato não encontrado: $CONTRACT" >&2
  exit 2
fi

if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'
  C_RED=$'\033[31m'
  C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'
  C_BLUE=$'\033[34m'
else
  C_RESET=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
fi

info() { printf '%s⏳ %s%s\n' "$C_BLUE" "$*" "$C_RESET"; }
ok() { printf '%s✅ %s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
warn() { printf '%s⚠️  %s%s\n' "$C_YELLOW" "$*" "$C_RESET"; }
fail() { printf '%s❌ %s%s\n' "$C_RED" "$*" "$C_RESET"; }
die() {
  # stderr: die também é chamado dentro de $(...), onde o stdout seria capturado e a mensagem sumiria.
  fail "$1" >&2
  if [[ $# -gt 1 ]]; then
    printf '   Dica: %s\n' "$2" >&2
  fi
  exit "${3:-1}"
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Comando obrigatório não encontrado: $1" "Instale/abra o Cloud Shell e tente novamente."
}

contract_get() {
  jq -er "$1" "$CONTRACT"
}

contract_get_opt() {
  jq -er "$1 // empty" "$CONTRACT" 2>/dev/null || true
}

contract_array() {
  jq -er "$1[]" "$CONTRACT"
}

contract_name() {
  contract_get ".names.$1"
}

contract_tag() {
  contract_get ".tags.$1"
}

contract_version() {
  contract_get '.version'
}

rg_name() {
  contract_name rg
}

az_required() {
  need_cmd az
  need_cmd jq
}

json_escape() {
  jq -Rs .
}

is_retryable_text() {
  grep -Eqi '(^|[^[:alnum:]])(429|TooManyRequests|AnotherOperationInProgress)([^[:alnum:]]|$)' "$1"
}

retry_az() {
  local attempt=1 max_attempts=6 delay=4 out err status
  out="$(mktemp "${TMPDIR:-/tmp}/fwlab-az-out.XXXXXX")"
  err="$(mktemp "${TMPDIR:-/tmp}/fwlab-az-err.XXXXXX")"
  while true; do
    # Capturar o código no próprio comando: depois de um `if` sem ramo executado, $? fica 0 e a falha viraria sucesso.
    status=0
    "$@" >"$out" 2>"$err" || status=$?
    if (( status == 0 )); then
      cat "$out"
      rm -f "$out" "$err"
      return 0
    fi
    if (( attempt >= max_attempts )) || ! is_retryable_text "$err"; then
      cat "$err" >&2
      rm -f "$out" "$err"
      return "$status"
    fi
    # stderr: o stdout de retry_az é a saída do az e costuma ser capturado como JSON.
    warn "Azure retornou condição transitória; nova tentativa em ${delay}s (tentativa $attempt/$max_attempts)." >&2
    sleep "$delay"
    attempt=$((attempt + 1))
    delay=$((delay * 2))
  done
}

retry_az_json() {
  retry_az "$@" -o json
}

ensure_lab_dir() {
  mkdir -p "$LAB_DIR"
  chmod 700 "$LAB_DIR"
}

write_env_file() {
  local region="$1" vm_size="$2" trusted_launch="$3"
  ensure_lab_dir
  umask 077
  {
    printf 'LAB_REGION=%q\n' "$region"
    printf 'LAB_VM_SIZE=%q\n' "$vm_size"
    printf 'LAB_TRUSTED_LAUNCH=%q\n' "$trusted_launch"
  } >"$ENV_FILE"
  ok "Arquivo gravado: $ENV_FILE"
}

load_env_file_if_needed() {
  if [[ -z "${LAB_REGION:-}" || -z "${LAB_VM_SIZE:-}" || -z "${LAB_TRUSTED_LAUNCH:-}" ]]; then
    if [[ -f "$ENV_FILE" ]]; then
      local region="${LAB_REGION:-}" size="${LAB_VM_SIZE:-}" trusted="${LAB_TRUSTED_LAUNCH:-}"
      # shellcheck disable=SC1090
      source "$ENV_FILE"
      # O que o aluno exportou vence o arquivo do preflight; o arquivo só completa o que faltou.
      LAB_REGION="${region:-${LAB_REGION:-}}"
      LAB_VM_SIZE="${size:-${LAB_VM_SIZE:-}}"
      LAB_TRUSTED_LAUNCH="${trusted:-${LAB_TRUSTED_LAUNCH:-}}"
    fi
  fi
}

subscription_id() {
  retry_az az account show --query id -o tsv
}

rg_exists() {
  local rg exists
  rg="$(rg_name)"
  # Falha fechada: erro do az não pode virar "RG inexistente" (o deploy.sh usa isto para proteger o basePolicy do Ex3).
  exists="$(retry_az az group exists --name "$rg" -o tsv)" \
    || die "Não foi possível consultar o resource group $rg." "Confira o login com 'az account show' e tente novamente."
  [[ "$exists" == "true" ]]
}

rg_location() {
  local rg
  rg="$(rg_name)"
  retry_az az group show --name "$rg" --query location -o tsv
}

resource_id() {
  local type="$1" name="$2" rg sub
  rg="$(rg_name)"
  sub="$(subscription_id)"
  printf '/subscriptions/%s/resourceGroups/%s/providers/%s/%s' "$sub" "$rg" "$type" "$name"
}

firewall_id() {
  resource_id "Microsoft.Network/azureFirewalls" "$1"
}

policy_id() {
  resource_id "Microsoft.Network/firewallPolicies" "$1"
}

workspace_customer_id() {
  local rg law
  rg="$(rg_name)"
  law="$(contract_name law)"
  retry_az az monitor log-analytics workspace show --resource-group "$rg" --workspace-name "$law" --query customerId -o tsv
}

kql_query() {
  local customer_id="$1" query="$2" body_file status=0
  body_file="$(mktemp "${TMPDIR:-/tmp}/fwlab-kql.XXXXXX.json")"
  jq -n --arg query "$query" '{query: $query}' >"$body_file"
  retry_az az rest \
    --resource "https://api.loganalytics.io" \
    --method post \
    --url "https://api.loganalytics.io/v1/workspaces/${customer_id}/query" \
    --headers "Content-Type=application/json" \
    --body @"$body_file" \
    -o json || status=$?
  rm -f "$body_file"
  return "$status"
}

latest_subscription_deployment_state() {
  local prefix
  prefix="$(contract_name deploymentPrefix)"
  retry_az az deployment sub list \
    --query "[?starts_with(name, '${prefix}-')] | sort_by(@, &properties.timestamp)[-1].properties.provisioningState" \
    -o tsv
}

public_ipv4_ok() {
  local ip="$1"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  local a b c d
  IFS=. read -r a b c d <<<"$ip"
  for octet in "$a" "$b" "$c" "$d"; do
    [[ "$octet" =~ ^[0-9]+$ && "$octet" -le 255 ]] || return 1
  done
  [[ "$a" -eq 10 ]] && return 1
  [[ "$a" -eq 172 && "$b" -ge 16 && "$b" -le 31 ]] && return 1
  [[ "$a" -eq 192 && "$b" -eq 168 ]] && return 1
  [[ "$a" -eq 127 ]] && return 1
  [[ "$a" -eq 0 ]] && return 1
  [[ "$a" -eq 100 && "$b" -ge 64 && "$b" -le 127 ]] && return 1
  [[ "$a" -eq 169 && "$b" -eq 254 ]] && return 1
  [[ "$a" -eq 224 || "$a" -ge 240 ]] && return 1
  [[ "$a" -eq 192 && "$b" -eq 0 && "$c" -eq 2 ]] && return 1
  [[ "$a" -eq 198 && "$b" -eq 51 && "$c" -eq 100 ]] && return 1
  [[ "$a" -eq 203 && "$b" -eq 0 && "$c" -eq 113 ]] && return 1
  [[ "$ip" == "168.63.129.16" ]] && return 1
  return 0
}

print_kv() {
  printf '%-22s %s\n' "$1" "$2"
}
