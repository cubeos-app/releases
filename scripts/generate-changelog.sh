#!/bin/bash
# =============================================================================
# CubeOS Changelog Generator
# =============================================================================
# Generates a Markdown changelog by comparing commits between version tags
# across user-facing CubeOS repositories using the GitLab Compare API.
#
# Usage:
#   CUBEOS_VERSION=0.2.0-beta.04 bash scripts/generate-changelog.sh
#   CUBEOS_VERSION=0.2.0-beta.04 PREV_TAG=v0.2.0-beta.03 bash scripts/generate-changelog.sh
#   CUBEOS_VERSION=0.2.0-beta.04 bash scripts/generate-changelog.sh --full
#
# Modes:
#   (default)  — outputs a single version entry to stdout
#   --full     — outputs complete CHANGELOG.md with all beta versions
#
# Required env vars:
#   CUBEOS_VERSION   — Target version (e.g., 0.2.0-beta.04)
#   GITLAB_TOKEN     — GitLab API token with read_repository scope
#
# Optional env vars:
#   PREV_TAG         — Previous version tag (auto-detected if omitted)
#   GITLAB_URL       — GitLab instance URL (default: https://gitlab.nuclearlighters.net)
# =============================================================================

set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────────────────

VERSION="${CUBEOS_VERSION:?ERROR: CUBEOS_VERSION is required}"
TOKEN="${GITLAB_TOKEN:?ERROR: GITLAB_TOKEN is required}"
GITLAB_URL="${GITLAB_URL:-https://gitlab.nuclearlighters.net}"
API_URL="${GITLAB_URL}/api/v4"
FULL_MODE=false

for arg in "$@"; do
  case "$arg" in
    --full) FULL_MODE=true ;;
  esac
done

# ─── Helpers ────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
NC='\033[0m'

info()  { echo -e "${BOLD}[INFO]${NC}  $*" >&2; }
ok()    { echo -e "${GREEN}[OK]${NC}    $*" >&2; }
warn()  { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# User-facing repos: name → GitLab project ID
declare -A REPOS=(
  ["API"]=13
  ["Dashboard"]=14
  ["HAL"]=22
  ["Releases"]=20
  ["Core Apps"]=19
)

# Ordered list for consistent output
REPO_ORDER=("API" "Dashboard" "HAL" "Core Apps" "Releases")

# GitHub mirror slugs (repo display name → GitHub repo slug)
# Links point to public GitHub mirrors since GitLab is self-hosted/private
declare -A GITHUB_SLUGS=(
  ["API"]="cubeos-app/api"
  ["Dashboard"]="cubeos-app/dashboard"
  ["HAL"]="cubeos-app/hal"
  ["Core Apps"]="cubeos-app/coreapps"
  ["Releases"]="cubeos-app/releases"
)

# Commit type labels (conventional commit prefix → display name)
declare -A TYPE_LABELS=(
  ["feat"]="Features"
  ["fix"]="Fixes"
  ["refactor"]="Refactoring"
  ["perf"]="Performance"
  ["docs"]="Documentation"
  ["test"]="Tests"
  ["ci"]="CI/CD"
)

# Priority order for commit types
TYPE_ORDER=("feat" "fix" "refactor" "perf" "docs" "test" "ci")

# ─── Functions ──────────────────────────────────────────────────────────────

# Detect the previous tag for a given version
detect_prev_tag() {
  local version="$1"

  # Fetch all tags sorted by version, find the one before current
  local tags
  tags=$(curl -sf --header "PRIVATE-TOKEN: ${TOKEN}" \
    "${API_URL}/projects/20/repository/tags?per_page=100" \
    | jq -r '.[].name' | sort -V)

  local prev=""
  while IFS= read -r tag; do
    if [ "$tag" = "v${version}" ]; then
      if [ -n "$prev" ]; then
        echo "$prev"
        return 0
      else
        return 1
      fi
    fi
    prev="$tag"
  done <<< "$tags"

  return 1
}

# Fetch commits between two tags for a project
fetch_commits() {
  local project_id="$1" from_tag="$2" to_tag="$3"

  local response
  response=$(curl -sf --header "PRIVATE-TOKEN: ${TOKEN}" \
    "${API_URL}/projects/${project_id}/repository/compare?from=${from_tag}&to=${to_tag}&per_page=100" 2>/dev/null) || {
    echo "[]"
    return 0
  }

  echo "$response" | jq -r '.commits // []'
}

# Parse a conventional commit message into type and description
parse_commit() {
  local message="$1"
  local first_line
  first_line=$(echo "$message" | head -1)

  # Skip merge commits
  if echo "$first_line" | grep -qE '^Merge branch'; then
    return 1
  fi

  # Skip version bump noise
  if echo "$first_line" | grep -qE '^chore: bump version'; then
    return 1
  fi

  # Skip plain "chore:" commits (release housekeeping)
  if echo "$first_line" | grep -qE '^chore(\(.*\))?:'; then
    return 1
  fi

  # Parse conventional commit: type(scope): description
  if echo "$first_line" | grep -qE '^[a-z]+(\(.*\))?:'; then
    local type scope desc
    type=$(echo "$first_line" | sed -E 's/^([a-z]+)(\(.*\))?: .*/\1/')
    scope=$(echo "$first_line" | sed -nE 's/^[a-z]+\(([^)]+)\): .*/\1/p')
    desc=$(echo "$first_line" | sed -E 's/^[a-z]+(\([^)]+\))?: //')

    # Validate type is known
    if [ -z "${TYPE_LABELS[$type]:-}" ]; then
      type="refactor"  # Default unknown types to refactoring
    fi

    if [ -n "$scope" ]; then
      echo "${type}|**${scope}**: ${desc}"
    else
      echo "${type}|${desc}"
    fi
    return 0
  fi

  # Non-conventional commit — treat as refactoring
  echo "refactor|${first_line}"
  return 0
}

# Generate changelog entry for a single version
generate_version_entry() {
  local version="$1" prev_tag="$2"
  local to_tag="v${version}"
  local release_date

  # Get release date from the tag
  release_date=$(curl -sf --header "PRIVATE-TOKEN: ${TOKEN}" \
    "${API_URL}/projects/20/repository/tags/${to_tag}" 2>/dev/null \
    | jq -r '.commit.created_at // empty' | cut -dT -f1) || true

  if [ -z "$release_date" ]; then
    release_date=$(date +%Y-%m-%d)
  fi

  echo "## ${to_tag} — ${release_date}"
  echo ""

  local has_entries=false

  for repo_name in "${REPO_ORDER[@]}"; do
    local project_id="${REPOS[$repo_name]}"

    local commits
    commits=$(fetch_commits "$project_id" "$prev_tag" "$to_tag")

    if [ "$commits" = "[]" ] || [ -z "$commits" ]; then
      continue
    fi

    # Parse commits into typed entries
    declare -A typed_entries
    for t in "${TYPE_ORDER[@]}"; do
      typed_entries[$t]=""
    done

    local commit_count
    commit_count=$(echo "$commits" | jq 'length')

    local github_slug="${GITHUB_SLUGS[$repo_name]}"

    for i in $(seq 0 $(( commit_count - 1 ))); do
      local message short_id
      message=$(echo "$commits" | jq -r ".[$i].message")
      short_id=$(echo "$commits" | jq -r ".[$i].short_id")

      local parsed
      parsed=$(parse_commit "$message") || continue

      local ctype entry_text commit_url
      ctype=$(echo "$parsed" | cut -d'|' -f1)
      entry_text=$(echo "$parsed" | cut -d'|' -f2-)

      # Link to public GitHub mirror (GitLab is self-hosted, not internet-accessible)
      commit_url="https://github.com/${github_slug}/commit/${short_id}"
      entry_text="${entry_text} ([${short_id}](${commit_url}))"

      if [ -n "${typed_entries[$ctype]:-}" ]; then
        typed_entries[$ctype]="${typed_entries[$ctype]}"$'\n'"- ${entry_text}"
      else
        typed_entries[$ctype]="- ${entry_text}"
      fi
    done

    # Check if this repo has any entries
    local repo_has_entries=false
    for t in "${TYPE_ORDER[@]}"; do
      if [ -n "${typed_entries[$t]:-}" ]; then
        repo_has_entries=true
        break
      fi
    done

    if [ "$repo_has_entries" = true ]; then
      has_entries=true
      echo "### ${repo_name}"
      echo ""

      for t in "${TYPE_ORDER[@]}"; do
        if [ -n "${typed_entries[$t]:-}" ]; then
          echo "${typed_entries[$t]}"
        fi
      done

      echo ""
    fi

    unset typed_entries
  done

  if [ "$has_entries" = false ]; then
    echo "*No user-facing changes in this release.*"
    echo ""
  fi
}

# ─── Main ───────────────────────────────────────────────────────────────────

if [ "$FULL_MODE" = true ]; then
  info "Generating full CHANGELOG.md"

  echo "# Changelog"
  echo ""
  echo "All notable changes to CubeOS are documented here."
  echo "This changelog is generated from conventional commits across all CubeOS repositories."
  echo ""

  # Get all beta tags in reverse order
  BETA_TAGS=$(curl -sf --header "PRIVATE-TOKEN: ${TOKEN}" \
    "${API_URL}/projects/20/repository/tags?per_page=100" \
    | jq -r '.[].name' | grep '^v0\.2\.0-beta\.' | sort -Vr)

  prev_for_next=""
  # Process in reverse version order (newest first)
  while IFS= read -r tag; do
    ver="${tag#v}"
    prev=$(detect_prev_tag "$ver") || prev="v0.2.0-alpha.01"
    info "Generating entry: ${tag} (from ${prev})"
    generate_version_entry "$ver" "$prev"
    echo "---"
    echo ""
  done <<< "$BETA_TAGS"

  echo "## Earlier Releases"
  echo ""
  echo "Alpha releases (v0.1.0-alpha.01 through v0.2.0-alpha.01) are documented in"
  echo "[GitHub Release History](https://github.com/cubeos-app/releases/releases)."

else
  # Single version mode
  if [ -n "${PREV_TAG:-}" ]; then
    info "Using specified PREV_TAG: ${PREV_TAG}"
  else
    PREV_TAG=$(detect_prev_tag "$VERSION") || error "Could not detect previous tag for v${VERSION}"
    info "Auto-detected previous tag: ${PREV_TAG}"
  fi

  info "Generating changelog: ${PREV_TAG} → v${VERSION}"
  generate_version_entry "$VERSION" "$PREV_TAG"
fi

ok "Changelog generation complete"
