#!/usr/bin/env bash
# Valida o nome da branch atual contra o padrão em CONTRIBUTING.md.
set -euo pipefail

branch="$(git rev-parse --abbrev-ref HEAD)"
protected_regex='^(main|master|develop)$'
pattern_regex='^(feat|fix|docs|style|refactor|perf|test|chore|ci|build|revert)\/[a-z0-9]+(-[a-z0-9]+)*$'

if [[ "$branch" =~ $protected_regex ]]; then
  exit 0
fi

if [[ ! "$branch" =~ $pattern_regex ]]; then
  echo "Nome de branch inválido: '$branch'" >&2
  echo "Use <tipo>/<slug-em-kebab-case>, ex.: feat/fase-2-fotos" >&2
  echo "Tipos válidos: feat fix docs style refactor perf test chore ci build revert" >&2
  echo "Padrão completo em CONTRIBUTING.md." >&2
  exit 1
fi
