#!/usr/bin/env bash
# lint-doc-permissions.sh — validate the permissions blocks customers copy.
#
# The README yaml blocks are what customers paste into their workflows, and a
# `permissions:` map is closed — any scope it does not list is revoked — so a
# single block that omits a required scope ships a broken job to everyone who
# copies it. File-level checks are not enough: a scope present in ONE block
# does not make a DIFFERENT block that omits it correct. Each fenced yaml
# block is therefore validated independently:
#
#   * a block that uses macroscope-actions/run@ must grant `id-token: write`
#     — without it the action cannot mint the OIDC token that authenticates
#     to Macroscope
#   * no block may grant any `checks:` scope (a negated mention such as
#     "no checks: scope" in a comment is the documented prohibition, not a
#     grant) — the workflow job is itself the check run, concluded by GitHub,
#     so no action reads or writes the Checks API
#
# Usage: lint-doc-permissions.sh FILE.md [FILE.md ...]
# Exits nonzero if any block fails, with a ::error:: line naming the file and
# the block's starting line.
set -euo pipefail

# check_block validates one fenced yaml block's content, given the file and the
# line number the block started on (for error annotations). Returns nonzero on
# any violation.
# permissions_grants_id_token_write reports whether the block's permissions:
# mapping grants id-token: write, in block style or as an inline map. The
# grant must live INSIDE the mapping: the same text under env: or any other
# key is not a permission, and counting it would pass a block whose OIDC mint
# fails at runtime. A full-comment line grants nothing (and does not end the
# mapping's scope); a trailing comment after a real entry is fine.
permissions_grants_id_token_write() {
  local block=$1 line in_perms=0 perm_indent=0 entry_indent="" indent
  while IFS= read -r line; do
    # Every line whose first token starts with # is a YAML comment — with or
    # without a space after the # — and must be skipped BEFORE indentation
    # tracking: a deeper comment as the mapping's first line would otherwise
    # seed entry_indent at nested depth and admit a nested grant as direct.
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    if [ "$in_perms" = 1 ]; then
      # The mapping extends over lines indented deeper than the permissions:
      # key; the first non-blank line at or above that indentation ends it.
      [[ "$line" =~ ^[[:space:]]*$ ]] && continue
      indent="${line%%[![:space:]]*}"
      if [ "${#indent}" -le "$perm_indent" ]; then
        in_perms=0
      else
        # Only DIRECT entries of the mapping grant anything: the first entry
        # line fixes the mapping's entry indentation, and a deeper line is a
        # nested value, not a permission — counting it would pass a block
        # whose id-token grant is not actually a grant.
        [ -z "$entry_indent" ] && entry_indent=${#indent}
        if [ "${#indent}" -eq "$entry_indent" ] \
          && [[ "$line" =~ ^[[:space:]]*id-token:[[:space:]]*write([[:space:]]*(#.*)?)?$ ]]; then
          return 0
        fi
      fi
    fi
    if [ "$in_perms" = 0 ]; then
      if [[ "$line" =~ ^([[:space:]]*)permissions:[[:space:]]*$ ]]; then
        perm_indent=${#BASH_REMATCH[1]}
        entry_indent=""
        in_perms=1
      elif [[ "$line" =~ ^[[:space:]]*permissions:[[:space:]]*\{(.*)\} ]]; then
        # Only entries at the OUTER depth of the inline map grant: nested
        # flow maps ({ nested: { id-token: write } }) are values, not
        # permissions, so their content is removed before matching. Entries
        # are comma-separated at the outer depth.
        local inline="${BASH_REMATCH[1]}"
        # Innermost brace groups are stripped repeatedly, so deeper nesting
        # collapses outward; an unmatched brace just stops matching, ending
        # the strip.
        inline=$(awk '{ while (gsub(/\{[^{}]*\}/, "")) { } print }' <<<"$inline")
        [[ "$inline" =~ (^|,)[[:space:]]*id-token:[[:space:]]*write[[:space:]]*(,|$) ]] && return 0
      fi
    fi
  done <<<"$block"
  return 1
}

check_block() {
  local file=$1 start=$2 block=$3 rc=0
  # The required scope must be an uncommented entry of the permissions:
  # mapping itself: "# id-token: write" in a comment grants nothing, and the
  # same text outside the mapping is not a permission — either way the block
  # ships a broken OIDC mint to whoever copies it.
  if grep -q "macroscope-actions/run@" <<<"$block" \
    && ! permissions_grants_id_token_write "$block"; then
    echo "::error file=${file},line=${start}::yaml block uses run without 'id-token: write' in its permissions: map — the map is closed, so a customer copying this block cannot mint the OIDC token" >&2
    rc=1
  fi
  local line
  while IFS= read -r line; do
    # A full-comment line grants nothing in YAML — the documented
    # "no checks: scope" prohibition lives on one — but a grant with a
    # trailing comment ("checks: write  # NOT a grant") is still a grant,
    # so only lines that are entirely comments are exempt.
    if [[ "$line" =~ ^[[:space:]]*# ]]; then
      continue
    fi
    # Matched anywhere on the line, not only as a block-style entry, so the
    # inline-map form (permissions: { checks: write }) is caught too. Quoted
    # key spellings ("checks": / 'checks':) are valid YAML and equally a
    # grant, so they are banned alike.
    # YAML permits whitespace between a key and its colon, so the ban allows
    # it too — "checks : write" is the same grant as "checks: write".
    local checks_re='("checks"|'\''checks'\''|checks)[[:space:]]*:[[:space:]]*(read|write)'
    if [[ "$line" =~ $checks_re ]]; then
      echo "::error file=${file},line=${start}::yaml block grants a 'checks:' scope — no action needs it; the workflow job is itself the check run, concluded by GitHub" >&2
      rc=1
    fi
    # Both blanket forms grant a checks: scope (write-all includes
    # checks: write, read-all includes checks: read).
    local blanket_re='permissions[[:space:]]*:[[:space:]]*["'\'']?(read-all|write-all)'
    if [[ "$line" =~ $blanket_re ]]; then
      echo "::error file=${file},line=${start}::yaml block grants blanket 'permissions: ${BASH_REMATCH[1]}', which includes a checks: scope — grant scopes explicitly" >&2
      rc=1
    fi
  done <<<"$block"
  return "$rc"
}

# lint_file walks a markdown file's fenced ```yaml blocks and validates each
# independently. Returns nonzero if any block fails; every failing block is
# reported, not just the first.
lint_file() {
  local file=$1 rc=0 in_block=0 block="" lineno=0 block_start=0 line fence="" close_run
  # CommonMark fences: a run of THREE OR MORE backticks or tildes, up to three
  # leading spaces. The whole opening run is captured because the close must
  # match it: a ````yaml block is just as copyable as a ```yaml one, and a
  # three-character match would skip it — or close it early — silently
  # exempting its permission checks. The info string matches every spelling
  # GitHub renders as YAML: leading whitespace is stripped per CommonMark, and
  # the language name is case-insensitive with the yml alias — a block opened
  # with "``` yml" or "```YAML" is exactly as copyable as "```yaml", so an
  # exact-lowercase match would exempt it from every check.
  local open_re='^[[:space:]]{0,3}(`{3,}|~{3,})[[:space:]]*[Yy][Aa]?[Mm][Ll]'
  # A yaml fence inside a blockquote also renders as a copyable block, but its
  # content lines carry "> " prefixes this line-oriented lint cannot see
  # through — so it is refused outright (fail closed) rather than skipped.
  local quoted_re='^[[:space:]]*>[[:space:]>]*(`{3,}|~{3,})[[:space:]]*[Yy][Aa]?[Mm][Ll]'
  # A closing fence is a run of the SAME character, AT LEAST as long as the
  # opening run, with nothing but whitespace after it. A shorter run, a
  # different character, or trailing text is content, not a close.
  local close_re='^[[:space:]]{0,3}(`{3,}|~{3,})[[:space:]]*$'
  # shellcheck disable=SC2094 # false positive: check_block only interpolates
  # the filename into its ::error:: annotation; nothing writes to the file.
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    if [ "$in_block" = 0 ]; then
      if [[ "$line" =~ $quoted_re ]]; then
        echo "::error file=${file},line=${lineno}::yaml block inside a blockquote — the lint cannot validate it; move the example out of the blockquote" >&2
        rc=1
        continue
      fi
      [[ "$line" =~ $open_re ]] || continue
      fence="${BASH_REMATCH[1]}"
      in_block=1
      block=""
      block_start=$lineno
      continue
    fi
    if [[ "$line" =~ $close_re ]]; then
      close_run="${BASH_REMATCH[1]}"
      if [ "${close_run:0:1}" = "${fence:0:1}" ] && [ "${#close_run}" -ge "${#fence}" ]; then
        in_block=0
        check_block "$file" "$block_start" "$block" || rc=1
        continue
      fi
    fi
    block+="$line"$'\n'
  done <"$file" || {
    # A missing or unreadable file must fail the lint, not pass it: the failed
    # redirection does not run the loop, so without this the function would
    # return rc=0 having checked nothing.
    echo "::error file=${file}::lint-doc-permissions could not read the file" >&2
    return 1
  }
  # CommonMark runs an unclosed fence to the end of the document, so a block
  # still open at EOF is real, copyable content and is validated like any
  # closed one.
  if [ "$in_block" = 1 ]; then
    check_block "$file" "$block_start" "$block" || rc=1
  fi
  return "$rc"
}

lint_main() {
  [ "$#" -ge 1 ] || {
    echo "usage: $0 FILE.md [FILE.md ...]" >&2
    exit 2
  }
  local rc=0 f
  for f in "$@"; do
    lint_file "$f" || rc=1
  done
  exit "$rc"
}

# Main guard: execute only when run directly, so bats can `source` this file
# and unit-test the functions above.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  lint_main "$@"
fi
