#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

GENERIC_ONLY=false
SCAN_PATH="$ROOT"
PATTERN_FILE="${FWLAB_NEUTRAL_PATTERNS:-$HOME/.config/fwlab/neutral-patterns.txt}"
PATTERNS=()
FOUND=0
INCOMPLETE=0
SCANNED=0

usage() {
  printf 'Uso: ./scripts/check-neutral.sh [--generic-only] [raiz de uma cópia do repositório]\n'
  printf 'Saída: 0 = nenhum achado · 1 = achados · 2 = verificação incompleta ou configuração inválida\n'
}

report() {
  local file="$1" line="$2" reason="$3"
  printf '%s:%s: %s\n' "${file#"$SCAN_PATH"/}" "$line" "$reason"
  FOUND=1
}

# Arquivo que não foi lido não foi verificado: o gate reprova em vez de pular.
unreadable() {
  printf '%s: leitura falhou (grep saiu com %s)\n' "${1#"$SCAN_PATH"/}" "$2"
  INCOMPLETE=1
}

is_allowed_email_domain() {
  local email="${1,,}" domain
  domain="${email##*@}"
  [[ "$domain" == "exemplo.com" || "$domain" == "example.com" || "$domain" == "users.noreply.github.com" ]]
}

allow_guid() {
  [[ "${1,,}" == "00000000-0000-0000-0000-000000000000" ]]
}

# Caminhos relativos à raiz verificada: a mesma lista serve para o repositório e para a cópia de publicação.
allow_generic_hit() {
  local file="${1#"$SCAN_PATH"/}" line="$2" reason="$3"
  case "$reason:$file:$line" in
    "diretório .lab referenciado:.gitignore:.lab/"*) return 0 ;;
    "diretório .lab referenciado:scripts/lib/common.sh:"*) return 0 ;;
    "diretório .lab referenciado:scripts/check-neutral.sh:"*) return 0 ;;
    "diretório .lab referenciado:scripts/package.sh:"*) return 0 ;;
    "diretório .lab referenciado:guide/src/03-ex0.html:"*) return 0 ;;
    "diretório .lab referenciado:guide/src/12-troubleshooting.html:"*) return 0 ;;
    "diretório .lab referenciado:docs/index.html:"*) return 0 ;;
    "diretório .lab referenciado:tests/test_scripts.py:"*) return 0 ;;
    # Só a atribuição da senha gerada em tempo de execução; qualquer outro "password = …" no arquivo continua reportado.
    "password= com valor:tests/test_scripts.py:"*"password = strong_password()") return 0 ;;
    "token SAS em query string:scripts/check-neutral.sh:"*) return 0 ;;
    "token GitHub:scripts/check-neutral.sh:"*) return 0 ;;
    "password= com valor:scripts/check-neutral.sh:"*) return 0 ;;
    "AccountKey em texto:scripts/check-neutral.sh:"*) return 0 ;;
    "chave privada:scripts/check-neutral.sh:"*) return 0 ;;
  esac
  return 1
}

scan_line_generic() {
  local file="$1" number="$2" line="$3" match lower
  while [[ "$line" =~ ([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}) ]]; do
    match="${BASH_REMATCH[1]}"
    allow_guid "$match" || report "$file" "$number" "GUID real"
    line="${line#*"${match}"}"
  done

  local rest="$line"
  while [[ "$rest" =~ ([[:alnum:]._%+-]+@[[:alnum:].-]+\.[[:alpha:]]{2,}) ]]; do
    match="${BASH_REMATCH[1]}"
    is_allowed_email_domain "$match" || report "$file" "$number" "e-mail não neutro"
    rest="${rest#*"${match}"}"
  done

  rest="$line"
  while [[ "$rest" =~ (([0-9]{1,3}\.){3}[0-9]{1,3}) ]]; do
    match="${BASH_REMATCH[1]}"
    public_ipv4_ok "$match" && report "$file" "$number" "IPv4 público"
    rest="${rest#*"${match}"}"
  done

  if [[ "$line" == *".lab/"* ]] && ! allow_generic_hit "$file" "$line" "diretório .lab referenciado"; then
    report "$file" "$number" "diretório .lab referenciado"
  fi
  if [[ "$line" =~ -----BEGIN[[:space:]][A-Z[:space:]]*PRIVATE[[:space:]]KEY----- ]] && ! allow_generic_hit "$file" "$line" "chave privada"; then
    report "$file" "$number" "chave privada"
  fi
  lower="${line,,}"
  if [[ "$lower" =~ accountkey=[^\;\&[:space:]]+ ]] && ! allow_generic_hit "$file" "$line" "AccountKey em texto"; then
    report "$file" "$number" "AccountKey em texto"
  fi
  if [[ "$line" =~ (^|[\?\&])sig=[^\&[:space:]]+ ]] && ! allow_generic_hit "$file" "$line" "token SAS em query string"; then
    report "$file" "$number" "token SAS em query string"
  fi
  if [[ "$line" =~ ghp_[A-Za-z0-9_]{20,} ]] && ! allow_generic_hit "$file" "$line" "token GitHub"; then
    report "$file" "$number" "token GitHub"
  fi
  if [[ "$lower" =~ (^|[^[:alnum:]_])password[[:space:]]*=[[:space:]]*[\"\']?[a-z0-9_@#%+=:.,/-]{4,} ]] && ! allow_generic_hit "$file" "$line" "password= com valor"; then
    report "$file" "$number" "password= com valor"
  fi
}

load_patterns() {
  local pattern status number=0
  if [[ ! -f "$PATTERN_FILE" ]]; then
    fail "Arquivo de padrões de cliente ausente: $PATTERN_FILE"
    printf 'Use --generic-only para rodar apenas os padrões genéricos.\n' >&2
    exit 2
  fi
  while IFS= read -r pattern || [[ -n "$pattern" ]]; do
    number=$((number + 1))
    [[ -z "$pattern" || "$pattern" =~ ^[[:space:]]*# ]] && continue
    status=0
    grep -qE -e "$pattern" /dev/null || status=$?
    if (( status > 1 )); then
      fail "Padrão inválido na linha $number de $PATTERN_FILE."
      exit 2
    fi
    PATTERNS+=("$pattern")
  done <"$PATTERN_FILE"
  if (( ${#PATTERNS[@]} == 0 )); then
    fail "Nenhum padrão em $PATTERN_FILE: o modo completo não verificaria os nomes do cliente."
    exit 2
  fi
}

allow_custom_hit() {
  local file="${1#"$SCAN_PATH"/}" number="$2" line="$3" digest
  [[ "$file" == "LICENSE" && "$number" == 3 ]] || return 1
  # Exceção autorizada: copyright de LICENSE:3 no commit inicial 16bfee8.
  # SHA-256 do conteúdo exato, incluindo espaço final e sem LF; não duplica o nome no código.
  need_cmd shasum
  digest="$(printf '%s' "$line" | shasum -a 256)" || die "Falha ao verificar o copyright de LICENSE:3."
  [[ "${digest%% *}" == "a0b0f2326787d57866f4a6a9677c2c3773ba4cd3cae2c9d0d64d21f27c95039c" ]]
}

scan_custom_patterns() {
  local file="$1" pattern matches hit number line status
  for pattern in "${PATTERNS[@]}"; do
    status=0
    matches="$(grep -nE -e "$pattern" -- "$file")" || status=$?
    case "$status" in
      0)
        while IFS= read -r hit; do
          number="${hit%%:*}"
          line="${hit#*:}"
          if allow_custom_hit "$file" "$number" "$line"; then
            info "LICENSE:3: atribuição legal original permitida (16bfee8)."
          else
            report "$file" "$number" "padrão de cliente: $pattern"
          fi
        done <<<"$matches"
        ;;
      1) ;;
      *) unreadable "$file" "$status"; return 0 ;;
    esac
  done
}

scan_file() {
  local file="$1" number=0 line status=0
  grep -Iq -e . -- "$file" || status=$?
  case "$status" in
    0) ;;
    1) return 0 ;; # binário ou vazio
    *) unreadable "$file" "$status"; return 0 ;;
  esac
  SCANNED=$((SCANNED + 1))
  scan_custom_patterns "$file"
  # shellcheck disable=SC2094
  while IFS= read -r -u 3 line || [[ -n "$line" ]]; do
    number=$((number + 1))
    scan_line_generic "$file" "$number" "$line"
  done 3<"$file"
}

main() {
  local -a files=()
  local file
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --generic-only) GENERIC_ONLY=true ;;
      -h|--help) usage; exit 0 ;;
      -*) usage >&2; exit 2 ;;
      *) SCAN_PATH="$1" ;;
    esac
    shift
  done
  if [[ ! -d "$SCAN_PATH" ]]; then
    fail "Diretório não encontrado: $SCAN_PATH"
    exit 2
  fi
  SCAN_PATH="$(cd -- "$SCAN_PATH" && pwd)"
  [[ "$GENERIC_ONLY" == "true" ]] || load_patterns
  if [[ -d "$SCAN_PATH/.lab" ]]; then
    report "$SCAN_PATH/.lab" 1 "diretório .lab presente"
  fi
  mapfile -d '' -t files < <(find "$SCAN_PATH" \
    -path '*/.git' -prune -o \
    -path '*/.git/*' -prune -o \
    -type f -print0)
  if ! wait "$!"; then
    fail "Não foi possível listar todos os arquivos de $SCAN_PATH."
    exit 2
  fi
  for file in "${files[@]}"; do
    scan_file "$file"
  done
  if (( INCOMPLETE )); then
    fail "Verificação incompleta: há arquivos que não foram lidos."
    exit 2
  fi
  if (( SCANNED == 0 )); then
    fail "Nenhum arquivo de texto verificado em $SCAN_PATH."
    exit 2
  fi
  if (( FOUND )); then
    exit 1
  fi
  ok "Neutralidade: nenhum achado."
}

main "$@"
