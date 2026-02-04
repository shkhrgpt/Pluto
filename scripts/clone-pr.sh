#!/bin/bash
# clone-pr.sh - Clone a PR from upstream to personal fork
# Creates a PR with the same diff as the original by using the original base commit
#
# Usage:
#   ./scripts/clone-pr.sh PR_LINK [BRANCH_NAME]
#
# Examples:
#   ./scripts/clone-pr.sh https://github.com/PlutoLang/Pluto/pull/1337
#   ./scripts/clone-pr.sh https://github.com/PlutoLang/Pluto/pull/1337 os-dnsresolve

set -e

PR_LINK=${1:?Usage: clone-pr.sh PR_LINK [BRANCH_NAME]}
BRANCH_NAME=${2:-""}

# Parse PR link: https://github.com/owner/repo/pull/123
if [[ "$PR_LINK" =~ github\.com/([^/]+/[^/]+)/pull/([0-9]+) ]]; then
  SOURCE_REPO="${BASH_REMATCH[1]}"
  PR_NUMBER="${BASH_REMATCH[2]}"
else
  echo "Error: Invalid PR link format. Expected: https://github.com/owner/repo/pull/123"
  exit 1
fi

# Default branch name if not provided
BRANCH_NAME=${BRANCH_NAME:-"pr-$PR_NUMBER"}
BASE_BRANCH="base-$BRANCH_NAME"

echo "Cloning PR #$PR_NUMBER from $SOURCE_REPO..."

# Stash any local changes (including untracked files) to avoid checkout conflicts
echo "Stashing local changes..."
git stash --include-untracked

# Get all PR data in one call
PR_DATA=$(gh pr view "$PR_NUMBER" --repo "$SOURCE_REPO" --json commits,title,body,closingIssuesReferences)

# Extract fields
TITLE=$(echo "$PR_DATA" | jq -r '.title')
BODY=$(echo "$PR_DATA" | jq -r '.body')
ISSUE=$(echo "$PR_DATA" | jq -r '.closingIssuesReferences[0].url // empty')

# Get all commit SHAs (in order)
COMMITS=()
while IFS= read -r line; do
  [ -n "$line" ] && COMMITS+=("$line")
done < <(echo "$PR_DATA" | jq -r '.commits[].oid')
FIRST_COMMIT="${COMMITS[0]}"
COMMIT_COUNT=${#COMMITS[@]}

echo "Title: $TITLE"
echo "Commits: $COMMIT_COUNT"

# Fail if no commits
if [ "$COMMIT_COUNT" -eq 0 ]; then
  echo "Error: PR has no commits to cherry-pick"
  exit 1
fi

# Fetch upstream and PR head ref to get commits locally
echo "Fetching upstream and PR commits..."
git fetch upstream
git fetch upstream "pull/$PR_NUMBER/head:temp-pr-$PR_NUMBER"

# Find the parent of the first PR commit (the base the PR was applied to)
BASE_COMMIT="${FIRST_COMMIT}^"
echo "Base commit: $BASE_COMMIT"

# Create base branch at the parent commit
echo "Creating base branch '$BASE_BRANCH' at $BASE_COMMIT..."
git branch -D "$BASE_BRANCH" 2>/dev/null || true
git checkout -b "$BASE_BRANCH" "$BASE_COMMIT"

# Push base branch to origin
git push -u origin "$BASE_BRANCH" --force

# Create feature branch from base
echo "Creating feature branch '$BRANCH_NAME'..."
git branch -D "$BRANCH_NAME" 2>/dev/null || true
git checkout -b "$BRANCH_NAME"

# Cherry-pick all commits in order
for commit in "${COMMITS[@]}"; do
  echo "Cherry-picking $commit..."
  if ! git cherry-pick "$commit"; then
    echo "Error: Merge conflict detected. Aborting and cleaning up..."
    git cherry-pick --abort
    git checkout -f main
    git branch -D "$BRANCH_NAME" 2>/dev/null || true
    git branch -D "$BASE_BRANCH" 2>/dev/null || true
    git push origin --delete "$BASE_BRANCH" 2>/dev/null || true
    git stash pop 2>/dev/null || true
    exit 1
  fi
done

# Push feature branch
git push -u origin "$BRANCH_NAME" --force

# Build PR body from original description
PR_BODY="$BODY"

if [ -n "$ISSUE" ]; then
  PR_BODY="$PR_BODY

Original issue: $ISSUE"
fi

# Get the fork repo from origin remote
FORK_REPO=$(git remote get-url origin | sed -E 's|.*github\.com[:/]||' | sed 's|\.git$||')

# Create label if it doesn't exist
LABEL="pr-$PR_NUMBER"
gh label create "$LABEL" --repo "$FORK_REPO" --color "0052CC" 2>/dev/null || true

# Create PR targeting the base branch (not main)
NEW_PR_URL=$(gh pr create --repo "$FORK_REPO" --base "$BASE_BRANCH" --title "$TITLE" --body "$PR_BODY" --label "$LABEL")

# Verify diff matches original PR
echo "Verifying diff matches original PR..."
ORIGINAL_DIFF=$(gh pr diff "$PR_NUMBER" --repo "$SOURCE_REPO")
NEW_DIFF=$(gh pr diff "$NEW_PR_URL")

if [ "$ORIGINAL_DIFF" = "$NEW_DIFF" ]; then
  echo "✓ Diff verification passed - new PR matches original"
else
  echo "✗ Warning: Diff mismatch detected!"
  echo "  This may indicate cherry-pick issues."
fi

# Close the PR and add comment for e2e testing
gh pr close "$NEW_PR_URL"
gh pr comment "$NEW_PR_URL" --body "@violetnspct e2e-test"

# Cleanup: switch back to main and delete all temp branches
git checkout -f main
git branch -D "temp-pr-$PR_NUMBER" 2>/dev/null || true
git branch -D "$BRANCH_NAME" 2>/dev/null || true
git branch -D "$BASE_BRANCH" 2>/dev/null || true

# Delete remote branches
echo "Cleaning up remote branches..."
git push origin --delete "$BRANCH_NAME" 2>/dev/null || true
git push origin --delete "$BASE_BRANCH" 2>/dev/null || true

# Restore stashed changes
echo "Restoring local changes..."
git stash pop 2>/dev/null || true

echo ""
echo "Done! Cloned $COMMIT_COUNT commit(s)."
echo "PR created and closed: $NEW_PR_URL"
