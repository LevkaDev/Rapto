#!/bin/bash
# Repository hygiene check: keeps build output, local configuration, secrets and
# personal data out of the repository.
#
#   scripts/check-repo.sh            check every tracked file (CI, before a release)
#   scripts/check-repo.sh --staged   check only staged files (pre-commit hook)
#   scripts/check-repo.sh --message FILE   check a commit message (commit-msg hook)
#
# It checks: files and folders that never belong here, anything new at the top level
# (see allowed_top below), documents outside the fixed set, files over 2 MB, and text
# that must not be published (home paths, non-English text, credentials, e-mail
# addresses). For a commit message it also checks the subject format.
#
# Extra patterns that must not be published (for example your own name or e-mail)
# can be listed one per line, as Perl regular expressions, in
# .git/info/check-repo-patterns. That file is never committed.

set -u
cd "$(git rev-parse --show-toplevel)" || exit 2

mode="all"
message_file=""
case "${1:-}" in
  --staged) mode="staged" ;;
  --message) mode="message"; message_file="${2:?commit message file required}" ;;
  "") ;;
  *) echo "usage: $0 [--staged | --message FILE]" >&2; exit 2 ;;
esac

local_patterns="$(git rev-parse --git-path info/check-repo-patterns)"
failed=0
fail() { echo "check-repo: $1" >&2; failed=1; }

# Text that must never appear: home folder paths, non-English text, credentials, and a
# development team in the Xcode project (it belongs in Config/Signing.local.xcconfig).
content_regex='/Users/[A-Za-z0-9._-]+/|/home/[A-Za-z0-9._-]+/|[\x{0400}-\x{04FF}]|-----BEGIN [A-Z ]*PRIVATE KEY-----|\bpolar_(oat|sk|at)_\w+|\bgh[pousr]_[A-Za-z0-9]{30,}|\bgithub_pat_\w{20,}|\bAKIA[0-9A-Z]{16}\b|\bsk_live_\w+|\bxox[abprs]-[\w-]+|DEVELOPMENT_TEAM(\[[^\]]*\])?"? = "?[A-Z0-9]{10}\b'

# E-mail addresses are personal data unless they are on this list: the project's public
# address, no-reply addresses, documentation examples and the addresses agents sign their
# commits with. Add an address here only with the maintainer's agreement.
allowed_email='^(support@rapto\.app|git@github\.com|[^@]*@users\.noreply\.github\.com|(noreply|no-reply)@[^@]+|[^@]+@example\.(com|org|net)|cursoragent@cursor\.com)$'

scan() { # scan FILE... ; prints file:line: text for every match
  perl -CSD -ne '
    BEGIN {
      $re = shift @ARGV;
      $allowed = shift @ARGV;
      @extra = ();
      $pf = shift @ARGV;
      if (-f $pf && open(my $fh, "<:encoding(UTF-8)", $pf)) {
        while (<$fh>) { chomp; next if /^\s*(#|$)/; push @extra, $_; }
      }
    }
    my $hit = /$re/o;
    for my $p (@extra) { $hit ||= /$p/; }
    while (/([A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,})/g) {
      my $address = $1;
      next if $address =~ /\@[0-9]x\./;          # image names such as icon@2x.png
      $hit ||= $address !~ /$allowed/io;
    }
    if ($hit) { s/\s+$//; print "$ARGV:$.: ", substr($_, 0, 160), "\n"; }
    close ARGV if eof;
  ' "$content_regex" "$allowed_email" "$local_patterns" "$@"
}

if [ "$mode" = "message" ]; then
  hits="$(grep -v '^#' "$message_file" | scan /dev/stdin)"
  [ -n "$hits" ] && fail "commit message contains text that must not be published:
$hits"

  # Subject format (CONTRIBUTING.md → Commits). Merge, revert, fixup and squash subjects
  # are written by git and are left alone.
  subject="$(grep -v '^#' "$message_file" | sed -n '/[^[:space:]]/{p;q;}')"
  case "$subject" in
    "Merge "*|"Revert "*|"fixup! "*|"squash! "*|"amend! "*) ;;
    *)
      [ ${#subject} -gt 72 ] && fail "commit subject is ${#subject} characters; the limit is 72"
      printf '%s' "$subject" | grep -Eq '\.$' && fail "commit subject ends with a period"
      printf '%s' "$subject" | grep -Eq '^[a-z]+(\([^)]*\))?!?: ' \
        && fail "commit subject has a prefix (\"fix:\", \"feat(x):\"); write a plain sentence"
      case "$subject" in
        "Release "*) ;;
        *) printf '%s' "$subject" | grep -Eq '\(?v[0-9]+\.[0-9]+(\.[0-9]+)?\)?[[:space:]]*$' \
             && fail "commit subject ends with a version number; versions go only in \"Release X.Y\" commits and tags" ;;
      esac ;;
  esac
  exit $failed
fi

if [ "$mode" = "staged" ]; then
  files="$(git diff --cached --name-only --diff-filter=ACMR)"
else
  # Tracked files, minus those already deleted in the working tree.
  files="$(git ls-files | grep -vxF -f <(git ls-files --deleted; echo /dev/null))"
fi
[ -z "$files" ] && exit 0

# Files and folders that never belong in the repository.
blocked='(^|/)(build[^/]*|DerivedData|\.derivedData|xcuserdata|\.build|node_modules|out|\.next|\.worktrees|worktrees)/'
blocked="$blocked"'|(^|/)(\.DS_Store|release\.local\.env|\.env(\..*)?|\.mcp\.json|skills-lock\.json|CLAUDE\.md|CLAUDE\.local\.md|AGENTS\.override\.md|GEMINI\.md|\.cursorrules|\.cursorignore|\.cursorindexingignore|\.clinerules|\.roomodes|\.windsurfrules|copilot-instructions\.md)$'
blocked="$blocked"'|(^|/)\.aider[^/]*$|\.local\.xcconfig$'
blocked="$blocked"'|(^|/)(\.claude|\.cursor|\.specstory|\.kiro|\.agents|\.aider[^/]*|\.continue|\.clinerules|\.roo|\.gemini|\.codex|\.junie|\.zed|\.windsurf|\.idea|\.vscode)/'
blocked="$blocked"'|^\.github/instructions/'
blocked="$blocked"'|(^|/)(WARP[^/]*|PLAN_[^/]*|NOTES[^/]*|TODO[^/]*)\.md$'
blocked="$blocked"'|\.(profraw|p8|p12|cer|mobileprovision|provisionprofile|dmg|zip|xcarchive|ipa|dSYM|log)$'
blocked="$blocked"'|_backup\.|\.orig$|\.bak$'

# .gitignore must cover what is blocked, so that `git add -A` does not pick it up even
# where the hooks are not installed. One sample path per blocked kind.
ignore_samples='build/x DerivedData/x .derivedData/x xcuserdata/x .worktrees/x worktrees/x
.DS_Store release.local.env .env .env.local .mcp.json skills-lock.json CLAUDE.local.md
AGENTS.override.md GEMINI.md .cursorrules .cursorignore .cursorindexingignore .clinerules
.roomodes .windsurfrules .github/copilot-instructions.md .github/instructions/x
.aider.chat.history.md .aider.conf.yml a.local.xcconfig .claude/x .cursor/x .specstory/x
.kiro/x .agents/x .continue/x .clinerules/x .roo/x .gemini/x .codex/x .junie/x .zed/x
.windsurf/x .idea/x .vscode/x WARP.md PLAN_x.md NOTES.md TODO.md a.p8 a.p12 a.cer
a.mobileprovision a.dmg a.zip a.log a.orig a.bak'
not_ignored=""
for sample in $ignore_samples; do
  git check-ignore -q --no-index "$sample" || not_ignored="$not_ignored $sample"
done
[ -n "$not_ignored" ] && fail ".gitignore does not cover:$not_ignored"

bad_paths="$(printf '%s\n' "$files" | grep -iE "$blocked" | grep -v -x -e 'release\.local\.env\.example' -e 'CLAUDE\.md')"

# Everything at the top level is listed here. A new file or folder at the top level, or
# a renamed one, is added to this list in the same commit, with the maintainer's
# agreement: that is what keeps stray files out, whatever they are called.
allowed_top='.githooks .github .gitignore AGENTS.md Animations CHANGELOG.md CLAUDE.md
Config CONTRIBUTING.md Rapto Rapto.xcodeproj RaptoTests RaptoUITests LICENSE README.md
RELEASE_NOTES.md SECURITY.md THIRD_PARTY_NOTICES.md build.sh dmg-resources
release.local.env.example release.sh scripts'
new_top="$(printf '%s\n' "$files" | cut -d/ -f1 | sort -u | grep -vxF -f <(printf '%s\n' $allowed_top))"
[ -n "$new_top" ] && fail "new at the top level (add to allowed_top in scripts/check-repo.sh if it belongs here):
$new_top"

# Documents live at the top level (the list above) or in .github/. Notes, plans and
# write-ups anywhere else do not belong in the repository.
stray_docs="$(printf '%s\n' "$files" | grep -iE '\.(md|markdown|txt|rtf|pdf|docx?|pages)$' | grep -E '/' | grep -vE '^\.github/')"
[ -n "$stray_docs" ] && fail "documents outside the top level and .github/:
$stray_docs"
# The root CLAUDE.md may exist only as a pointer to AGENTS.md: agent rules live in one place.
if printf '%s\n' "$files" | grep -qx 'CLAUDE\.md' && [ -f CLAUDE.md ] && [ "$(cat CLAUDE.md)" != "@AGENTS.md" ]; then
  fail "CLAUDE.md must contain only the line @AGENTS.md; put agent rules in AGENTS.md"
fi
[ -n "$bad_paths" ] && fail "files that must not be committed:
$bad_paths"

# Large files: everything over 2 MB needs a deliberate decision.
large=""
while IFS= read -r f; do
  [ -f "$f" ] || continue
  size=$(stat -f %z "$f" 2>/dev/null || stat -c %s "$f")
  [ "$size" -gt 2097152 ] && large="$large$f ($((size / 1024)) KB)
"
done <<< "$files"
[ -n "$large" ] && fail "files over 2 MB:
$large"

# Content of text files (binary files are skipped).
text_files=()
while IFS= read -r f; do
  [ -f "$f" ] || continue
  [ "$f" = "scripts/check-repo.sh" ] && continue
  grep -Iq . "$f" 2>/dev/null && text_files+=("$f")
done <<< "$files"
if [ ${#text_files[@]} -gt 0 ]; then
  hits="$(scan "${text_files[@]}")"
  [ -n "$hits" ] && fail "text that must not be published (home paths, non-English text, credentials, an e-mail address outside allowed_email, or a local pattern):
$hits"
fi

[ $failed -eq 0 ] || echo "check-repo: fix the above, or see AGENTS.md → Repository hygiene" >&2
exit $failed
