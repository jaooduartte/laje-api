#!/usr/bin/env bash
set -euo pipefail

API_URL="${1:-${API_URL:-}}"
if [[ -z "${API_URL}" ]]; then
  echo "Usage: $0 <api-url> or set API_URL." >&2
  exit 2
fi
API_URL="${API_URL%/}"

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

request_json() {
  local path="$1"
  curl --fail --silent --show-error "${API_URL}${path}"
}

championships_file="${tmp_dir}/championships.json"
request_json "/api/v1/championships" > "${championships_file}"

championship_count="$(jq '.data | length' "${championships_file}")"
if [[ "${championship_count}" -lt 1 ]]; then
  echo "No championships returned by staging API." >&2
  exit 1
fi

match_count=0
scored_match_count=0
walkover_match_count=0
walkover_contract_count=0
standings_count=0
bracket_competition_count=0
bracket_edition_count=0

while IFS=$'\t' read -r championship_id season_year championship_code; do
  [[ -z "${championship_id}" || -z "${season_year}" ]] && continue

  page=1
  total_pages=1
  while [[ "${page}" -le "${total_pages}" ]]; do
    matches_file="${tmp_dir}/matches-${championship_id}-${page}.json"
    request_json "/api/v1/matches?championshipId=${championship_id}&seasonYear=${season_year}&page=${page}&pageSize=100" > "${matches_file}"

    current_count="$(jq '.data | length' "${matches_file}")"
    match_count=$((match_count + current_count))
    scored_match_count=$((scored_match_count + $(jq '[.data[] | select(.homeScore != null and .awayScore != null)] | length' "${matches_file}")))
    walkover_match_count=$((walkover_match_count + $(jq '[.data[] | select(.isWalkover == true or .isDoubleWalkover == true)] | length' "${matches_file}")))
    walkover_contract_count=$((walkover_contract_count + $(jq '[.data[] | select(has("isWalkover") and has("isDoubleWalkover") and has("walkoverLoserTeamId"))] | length' "${matches_file}")))

    total_pages="$(jq -r '.meta.totalPages // 1' "${matches_file}")"
    page=$((page + 1))
  done

  standings_file="${tmp_dir}/standings-${championship_id}.json"
  request_json "/api/v1/championships/${championship_id}/standings?seasonYear=${season_year}&pageSize=100" > "${standings_file}"
  standings_count=$((standings_count + $(jq '.data | length' "${standings_file}")))

  bracket_file="${tmp_dir}/bracket-${championship_id}.json"
  request_json "/api/v1/championships/${championship_id}/bracket?seasonYear=${season_year}" > "${bracket_file}"
  if jq -e '.data.edition != null' "${bracket_file}" >/dev/null; then
    bracket_edition_count=$((bracket_edition_count + 1))
    bracket_competition_count=$((bracket_competition_count + $(jq '.data.competitions | length' "${bracket_file}")))
  fi

  echo "checked_championship=${championship_code:-unknown} season=${season_year}"
done < <(jq -r '.data[] | [.id, .currentSeasonYear, .code] | @tsv' "${championships_file}")

if [[ "${match_count}" -lt 1 ]]; then
  echo "Staging API returned no matches for current championship seasons." >&2
  exit 1
fi
if [[ "${scored_match_count}" -lt 1 ]]; then
  echo "Staging API returned no match with persisted scoreboard data." >&2
  exit 1
fi
if [[ "${walkover_contract_count}" -lt 1 ]]; then
  echo "Match payload does not expose the W.O. contract fields." >&2
  exit 1
fi
if [[ "${standings_count}" -lt 1 ]]; then
  echo "Staging API returned no standings rows." >&2
  exit 1
fi
if [[ "${bracket_edition_count}" -lt 1 || "${bracket_competition_count}" -lt 1 ]]; then
  echo "Staging API returned no generated bracket edition/competition." >&2
  exit 1
fi

echo "championships=${championship_count}"
echo "matches=${match_count}"
echo "scored_matches=${scored_match_count}"
echo "walkover_matches=${walkover_match_count}"
echo "walkover_contract_rows=${walkover_contract_count}"
echo "standings_rows=${standings_count}"
echo "bracket_editions=${bracket_edition_count}"
echo "bracket_competitions=${bracket_competition_count}"
