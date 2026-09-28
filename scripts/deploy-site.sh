#!/bin/bash
# Deploy the reviewed website to its one production project, from any checkout.
#
# The IDs pin less-go/workbench-mac, so an unlinked checkout can never create a
# new Vercel project, and no `vercel link` is needed (it downloads site/.env.local,
# which must not be read or published). Only a clean tree deploys.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ -n "$(git status --porcelain)" ]; then
  echo "Commit or discard local changes first: only reviewed source deploys." >&2
  exit 1
fi
export VERCEL_ORG_ID=team_XxcFs05VxGUFPpk92zDzLSmo      # less-go
export VERCEL_PROJECT_ID=prj_qpH9zHy7ufjCcSripTVkD7v0OL6E  # workbench-mac
exec vercel deploy --prod --yes --cwd site
