#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

UPLOAD=false
STORAGE_ACCOUNT=""
CONTAINER=""

usage() {
  printf 'Uso: ./scripts/package.sh [--upload <storageAccount> <container>]\n'
}

add_if_exists() {
  local path="$1"
  [[ -e "$ROOT/$path" ]] && printf '%s\n' "$path"
}

build_manifest() {
  local manifest="$1"
  : >"$manifest"
  {
    add_if_exists README.md
    add_if_exists LICENSE
    add_if_exists NOTICE.md
    add_if_exists lab.contract.json
  } >>"$manifest"
  local dir
  for dir in docs guest scripts queries; do
    [[ -d "$ROOT/$dir" ]] && find "$ROOT/$dir" -type f -not -path '*/.lab/*' -not -name '.DS_Store' -print | sed "s#^$ROOT/##" >>"$manifest"
  done
  if [[ -d "$ROOT/infra" ]]; then
    find "$ROOT/infra" -type f \
      -not -name '*.json' \
      -not -name '.DS_Store' \
      -not -path '*/.lab/*' \
      -print | sed "s#^$ROOT/##" >>"$manifest"
    add_if_exists infra/bicepconfig.json >>"$manifest"
  fi
  sort -u "$manifest" -o "$manifest"
}

upload_zip() {
  local zip_path="$1" blob expiry sas
  az_required
  blob="$(basename "$zip_path")"
  info "Enviando ZIP para $STORAGE_ACCOUNT/$CONTAINER..."
  retry_az az storage blob upload \
    --account-name "$STORAGE_ACCOUNT" \
    --container-name "$CONTAINER" \
    --name "$blob" \
    --file "$zip_path" \
    --auth-mode login \
    --overwrite true >/dev/null
  expiry="$(date -u -d '+4 hours' '+%Y-%m-%dT%H:%MZ' 2>/dev/null || date -u -v+4H '+%Y-%m-%dT%H:%MZ')"
  # Requer --as-user habilitado no tenant e permissão para user delegation SAS.
  sas="$(retry_az az storage blob generate-sas \
    --account-name "$STORAGE_ACCOUNT" \
    --container-name "$CONTAINER" \
    --name "$blob" \
    --permissions r \
    --expiry "$expiry" \
    --auth-mode login \
    --as-user \
    -o tsv)"
  ok "Upload concluído. SAS de leitura expira em $expiry."
  printf 'https://%s.blob.core.windows.net/%s/%s?%s\n' "$STORAGE_ACCOUNT" "$CONTAINER" "$blob" "$sas"
}

main() {
  cd "$ROOT"
  need_cmd jq
  need_cmd zip
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --upload)
        UPLOAD=true
        STORAGE_ACCOUNT="${2:-}"
        CONTAINER="${3:-}"
        [[ -n "$STORAGE_ACCOUNT" && -n "$CONTAINER" ]] || die "Parâmetros de upload ausentes." "Uso: ./scripts/package.sh --upload <storageAccount> <container>"
        shift 3
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "Argumento inválido: $1" "Uso: ./scripts/package.sh [--upload <storageAccount> <container>]"
        ;;
    esac
  done

  local version dist zip_name manifest
  version="$(contract_version)"
  dist="$ROOT/dist"
  zip_name="azure-firewall-ops-lab-${version}.zip"
  manifest="$(mktemp "${TMPDIR:-/tmp}/fwlab-package.XXXXXX")"
  mkdir -p "$dist"
  # zip atualiza um arquivo existente em vez de recriá-lo; sem o rm, entradas removidas do repo continuariam no pacote.
  rm -f "$dist/$zip_name"
  build_manifest "$manifest"
  (cd "$ROOT" && zip -qr "$dist/$zip_name" -@ <"$manifest")
  rm -f "$manifest"
  ok "ZIP gerado: dist/$zip_name"
  if [[ "$UPLOAD" == "true" ]]; then
    upload_zip "$dist/$zip_name"
  fi
}

main "$@"
