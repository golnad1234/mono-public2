#!/usr/bin/env bash
set -euo pipefail

# === Настройки по умолчанию ===
# ЧИТАЕМ ПУТЬ ИЗ 1‑ГО АРГУМЕНТА, иначе дефолт
CSV_FILE="${1:-mono-public/PT/sites.csv}"          # <— фикс: раньше игнорировался аргумент
PUBLIC_ROOT="${PUBLIC_ROOT:-PT}"                   # логический корень папок (из CSV)
CONTENT_BASE="${CONTENT_BASE:-mono-public}"        # физический префикс, где лежит контент
NETLIFY_AUTH_TOKEN="${NETLIFY_AUTH_TOKEN:?NETLIFY_AUTH_TOKEN is required}"
INDEXNOW_KEY="${INDEXNOW_KEY:-}"                   # опционально

# --- зависимости ---
if ! command -v jq >/dev/null 2>&1; then
  echo "Installing jq..."
  sudo apt-get update -y && sudo apt-get install -y jq
fi

# --- утилиты ---
trim() {
  local s="${1:-}"
  s="${s#"${s%%[![:space:]]*}"}"
  printf '%s' "${s%"${s##*[![:space:]]}"}"
}

# CSV безопасно парсим Python'ом (folder,site_name,domain,sitemap)
python_rows() {
  python3 - "$CSV_FILE" <<'PY'
import csv, sys
with open(sys.argv[1], newline='', encoding='utf-8') as f:
    r = csv.reader(f)
    for row in r:
        row = (row + ["", "", "", ""])[:4]
        folder, site_name, domain, sitemap = row
        if not folder.strip():
            continue
        if folder.strip().lower() == "folder":
            continue
        if folder.strip().startswith("#"):
            continue
        print("|".join([folder, site_name, domain, sitemap]))
PY
}

# Получить site_id по имени сайта (slug)
get_site_id_by_name() {
  local slug="$1"
  netlify sites:list --auth="$NETLIFY_AUTH_TOKEN" --json 2>/dev/null \
  | jq -r --arg n "$slug" 'map(select(.name == $n)) | (.[0].id // .[0].site_id // "")'
}

failures=()
deployed=0

echo "CSV: $CSV_FILE"
echo "CONTENT: ${CONTENT_BASE}/${PUBLIC_ROOT}/<folder>"

while IFS='|' read -r folder site_name domain sitemap; do
  folder="$(trim "$folder")"
  site_name="$(trim "$site_name")"
  domain="$(trim "$domain")"
  sitemap="$(trim "$sitemap")"

  # slug из site_name: lower, '.' и пробелы -> '-'
  base="${site_name,,}"
  base="${base//./-}"
  base="${base// /-}"
  slug="$base"

  if [[ -z "$slug" ]]; then
    echo "ERROR: empty site_name for folder='$folder' — skipping"
    failures+=("${folder}:no-site-name")
    continue
  fi

  site_id="$(get_site_id_by_name "$slug" || true)"
  if [[ -z "$site_id" ]]; then
    echo "ERROR: Netlify site not found by name='${slug}' — skipping"
    failures+=("${slug}:no-site-id")
    continue
  fi

# --- аккуратная сборка пути без дубликатов ---
# 1) нормализуем folder
clean="${folder#./}"         # убрать ./ в начале
clean="${clean%/}"           # убрать / в конце

# 2) если folder уже начинается с PUBLIC_ROOT (например, "PT/…") — не добавляем его второй раз
if [[ "$clean" == "${PUBLIC_ROOT}/"* ]]; then
  rel_path="$clean"
else
  rel_path="${PUBLIC_ROOT}/${clean}"
fi

# 3) CONTENT_BASE делаем опциональным; если не задан, не добавляем
CONTENT_BASE="${CONTENT_BASE:-}"

# 4) выбираем первый существующий вариант:
abs_path=""
for cand in \
  "${GITHUB_WORKSPACE:-$PWD}/${rel_path}" \
  "${GITHUB_WORKSPACE:-$PWD}/${CONTENT_BASE:+${CONTENT_BASE}/}${rel_path}" \
  "${GITHUB_WORKSPACE:-$PWD}/mono-public/${rel_path}"
do
  if [[ -d "$cand" ]]; then
    abs_path="$cand"
    break
  fi
done

# если ни один не найден — оставим первый (для понятной ошибки)
: "${abs_path:=${GITHUB_WORKSPACE:-$PWD}/${rel_path}}"

echo "SRC resolved: ${abs_path}" >&2


  echo ""
  echo "=== site='${slug}' (id=${site_id}) | SRC=${CONTENT_BASE}/${rel_path} | domain='${domain}' | sitemap='${sitemap}'"

  if [[ ! -d "$abs_path" ]]; then
    echo "ERROR: dir not found: $abs_path"
    failures+=("${slug}:no-dir")
    continue
  fi

  echo "--- ls -la ${CONTENT_BASE}/${rel_path}"
  ls -la "$abs_path" || true

  files_cnt=$(find "$abs_path" -type f | wc -l | tr -d ' ')
  if [[ "$files_cnt" -eq 0 ]]; then
    echo "ERROR: ${CONTENT_BASE}/${rel_path} is empty (0 files) — skipping"
    failures+=("${slug}:empty-dir")
    continue
  fi
  [[ -f "$abs_path/index.html" ]] || echo "WARN: no ${CONTENT_BASE}/${rel_path}/index.html — Netlify may return 404"

  echo "--- Deploying to site_id=${site_id}..."
  DEPLOY_JSON="$(netlify deploy \
      --auth="$NETLIFY_AUTH_TOKEN" \
      --dir="$abs_path" \
      --site="$site_id" \
      --prod \
      --message "CI: deploy ${folder} -> ${site_id}" \
      --json)"

  echo "$DEPLOY_JSON" | jq -r '{state, deploy_id: .id, deploy_url, logs: .log_access_attributes.url}'
  state="$(echo "$DEPLOY_JSON" | jq -r '.state')"
  deploy_url="$(echo "$DEPLOY_JSON" | jq -r '.deploy_url')"

  case "$state" in
    ready|new|uploaded) : ;;
    *) echo "ERROR: unexpected deploy state: $state"
       failures+=("${slug}:deploy-$state")
       continue ;;
  esac

  echo "Published: ${deploy_url}"
  deployed=$((deployed+1))

  if [[ -n "${domain:-}" && -n "${INDEXNOW_KEY:-}" ]]; then
    url="https://${domain}/"
    [[ -n "${sitemap:-}" ]] && url="https://${domain}/${sitemap}"
    echo "Pinging IndexNow → $url"
    curl -s -o /dev/null -w "IndexNow HTTP %{http_code}\n" \
      -H 'Content-Type: application/json' \
      -d "{\"host\":\"${domain}\",\"key\":\"${INDEXNOW_KEY}\",\"keyLocation\":\"https://${domain}/${INDEXNOW_KEY}.txt\",\"urlList\":[\"${url}\"]}" \
      https://api.indexnow.org/submit || true
  fi

  echo "=== Done: ${slug}"
done < <(python_rows)

echo
echo "Deployed sites: ${deployed}"
if (( ${#failures[@]} )); then
  echo "Some sites failed: ${failures[*]}"
  exit 1
else
  echo "All sites deployed successfully."
fi