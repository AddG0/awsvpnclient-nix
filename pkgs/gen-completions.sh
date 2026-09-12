#!/usr/bin/env bash
# Derive bash and zsh completions from the CLI's own --help, so a release that adds a
# subcommand or flag is picked up on the next build instead of drifting. Upstream
# links clap without clap_complete, so the binary cannot generate these itself.
set -euo pipefail

exe="$1"
out="$2"

subcommands() {
  "$exe" --help | awk '/^Commands:/ {f = 1; next} /^Options:/ {f = 0} f && NF > 1 {print $1}'
}

described() {
  "$exe" --help | awk '/^Commands:/ {f = 1; next} /^Options:/ {f = 0} f && NF > 1 {
    name = $1
    sub(/^[[:space:]]+[^[:space:]]+[[:space:]]+/, "")
    print name "\t" $0
  }'
}

flags() {
  "$exe" "$1" --help | grep -oE '\-\-[a-z][a-z-]*' | sort -u
}

commands=$(subcommands)
[ -n "$commands" ] || {
  echo "aws-vpn-client: no subcommands found in --help; the output format changed." >&2
  exit 1
}

mkdir -p "$out/share/bash-completion/completions" "$out/share/zsh/site-functions"

{
  echo "_aws_vpn_client_profiles() {"
  echo "  aws-vpn-client list-profiles 2>/dev/null |"
  echo "    grep -o '\"profile-name\": *\"[^\"]*\"' | sed 's/.*\"\\(.*\\)\"\$/\\1/'"
  echo "}"
  echo
  echo "_aws_vpn_client() {"
  echo "  local cur prev sub"
  echo '  cur="${COMP_WORDS[COMP_CWORD]}"'
  echo '  prev="${COMP_WORDS[COMP_CWORD-1]}"'
  echo '  sub="${COMP_WORDS[1]}"'
  echo
  echo '  if [ "$COMP_CWORD" -eq 1 ]; then'
  echo "    mapfile -t COMPREPLY < <(compgen -W \"$(echo $commands)\" -- \"\$cur\")"
  echo "    return"
  echo "  fi"
  echo
  echo '  case "$prev" in'
  echo "    --profile-name)"
  echo '      mapfile -t COMPREPLY < <(compgen -W "$(_aws_vpn_client_profiles)" -- "$cur")'
  echo "      return ;;"
  echo "    --config-path)"
  echo '      mapfile -t COMPREPLY < <(compgen -f -- "$cur")'
  echo "      return ;;"
  echo "  esac"
  echo
  echo '  case "$sub" in'
  for c in $commands; do
    [ "$c" = "help" ] && continue
    echo "    $c) mapfile -t COMPREPLY < <(compgen -W \"$(flags "$c" | tr '\n' ' ')\" -- \"\$cur\") ;;"
  done
  echo "  esac"
  echo "}"
  echo "complete -F _aws_vpn_client aws-vpn-client"
} >"$out/share/bash-completion/completions/aws-vpn-client"

{
  echo "#compdef aws-vpn-client"
  echo
  echo "_aws_vpn_client_profiles() {"
  echo "  local -a profiles"
  echo "  profiles=(\${(f)\"\$(aws-vpn-client list-profiles 2>/dev/null |"
  echo "    grep -o '\"profile-name\": *\"[^\"]*\"' | sed 's/.*\"\\(.*\\)\"\$/\\1/')\"})"
  echo "  _describe 'profile' profiles"
  echo "}"
  echo
  echo "_aws_vpn_client() {"
  echo "  local -a commands"
  echo "  commands=("
  described | while IFS=$'\t' read -r name desc; do
    [ "$name" = "help" ] && continue
    echo "    '$name:${desc//\'/}'"
  done
  echo "  )"
  echo
  echo "  if (( CURRENT == 2 )); then"
  echo "    _describe 'command' commands"
  echo "    return"
  echo "  fi"
  echo
  echo "  case \$words[CURRENT-1] in"
  echo "    --profile-name) _aws_vpn_client_profiles; return ;;"
  echo "    --config-path) _files; return ;;"
  echo "  esac"
  echo
  echo "  case \$words[2] in"
  for c in $commands; do
    [ "$c" = "help" ] && continue
    echo "    $c) _values 'flag' $(flags "$c" | sed "s/^/'/;s/\$/'/" | tr '\n' ' ') ;;"
  done
  echo "  esac"
  echo "}"
  echo
  echo "_aws_vpn_client \"\$@\""
} >"$out/share/zsh/site-functions/_aws-vpn-client"
