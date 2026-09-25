# Optional content packs

Workbench remains usable offline without an account. Packs add reusable company or team content through an optional GitHub connection. They do not upload sessions, screenshots or transcripts, run downloaded helpers, or change the installed application's identity.

## Colleague experience

1. Open the pack link shared by the team, or paste its GitHub repository address in **Packs**.
2. Connect GitHub using a device code. The account must already have repository access, and the Workbench GitHub App must be installed for that repository. Accepting an invitation is a GitHub action; an email domain alone does not grant access.
3. Add the pack. Choose a compatible skill or add a personal scene/persona copy. Optional workspace appearance changes the in-app label and logo.

The public installation link is `/packs/#source=OWNER/REPOSITORY`. Its fragment stays in the browser and pre-fills Workbench. Opening a link never installs content automatically. The app also accepts an ordinary `https://github.com/OWNER/REPOSITORY` address. Repository access controls future downloads; it cannot recall copies already downloaded or exported.

## Source and release contract

One repository publishes one pack. A root `catalog.json` lists immutable release manifests:

```json
{"formatVersion":1,"id":"example","name":"Example team","releases":[{"version":"1.0.0","minimumAppVersion":"2.2.0","manifestPath":"releases/1.0.0/pack.json","sha256":"MANIFEST_SHA256"}]}
```

A release manifest names every payload file and its exact size and SHA-256. Paths are relative to the manifest directory. Example:

```json
{
  "formatVersion":1,"id":"example","name":"Example team","version":"1.0.0","minimumAppVersion":"2.2.0",
  "entries":[{"id":"follow-up","kind":"skill","name":"Prepare follow-up","path":"skills/follow-up/SKILL.md","inputKinds":["transcripts"]}],
  "files":[{"path":"skills/follow-up/SKILL.md","size":123,"sha256":"FILE_SHA256"}],
  "branding":{"label":"Example team","logoPath":"artwork/logo.png"}
}
```

The example omits the logo file record for brevity; an actual manifest must list it. Stable versions use `major.minor.patch`, with no prerelease or build suffix. New content requires a new version. Changing the bytes of an installed version or downgrading the installed version is refused.

Supported entry kinds are `skill`, `scene`, `personas` and `resources`. A skill's complete directory subtree is copied; it must contain `SKILL.md`. Skills declare `inputKinds`: `snap-and-talk` for `session.json`, `transcripts` for `handoff.json`, or both only when they actually handle both formats. Undeclared skills cannot be selected for an incompatible handoff. A scene is a `.workbenchscene` package; a persona is one importable image with the entry name as its initial label. A resource saves an explicit personal file copy.

Limits: 512 files, 100 MiB per file, 256 MiB total, 64 entries, 200 releases, 1 MiB catalogue/manifest and 4 MiB skill entry point. Paths use conservative ASCII filenames, reject traversal, hidden components, symlinks, duplicate/case-colliding names and file/directory conflicts. Branding is inert content.

## Lifecycle and ownership

`PrivatePackKit` resolves the repository's default branch to a commit SHA, then fetches the catalogue, manifest and all files at that same SHA. Tokens go only to GitHub over HTTPS; redirects, response sizes and timeouts are bounded. Every file is checked against its published size and digest. Hashes establish consistency with the selected repository revision, not an independent signature or corporate endorsement.

The edition's Application Support `Packs` folder contains repository-qualified stores. Identically named packs from different repositories cannot replace each other. Updates reuse verified blobs, stage and validate the full next release, then atomically replace one active record. The last installed version remains active on failure or cancellation before activation. Three recent version directories are retained; their referenced blobs bound cache retention. Existing sessions and personal imports live outside this store.

Automatic checks run at startup, on foregrounding when due, and every six hours while Workbench is running. The person can disable them or check manually. Compatible versions are selected by the catalogue's minimum app version. Offline use of installed content continues; denied or expired access is shown when a download is attempted. Removing a pack stops its updates and removes only its owned download directory.

New Snap & Talk sessions copy their selected skill and immutable provenance into the session folder. Previously installed legacy packs remain readable, and older sessions are never migrated by opening them. Recent transcripts offer selected captures as either **My instructions** or **Reference material**, with optional explicitly chosen Snap & Talk evidence. The handoff folder contains `SKILL.md`, `handoff.json`, `inputs/` and `outputs/`. Only live referenced screen/narration pairs are copied; deleted sections and unrelated leftovers are excluded. The existing Hand off action copies a prompt and opens the chosen assistant. Workbench does not submit it or execute the skill.

## GitHub registration and credentials

Use a GitHub App with device flow enabled and repository Contents read-only access. Repository installations should select only pack repositories. GitHub's app/user permission intersection supplies access without a broad OAuth `repo` scope. Keep expiring user tokens enabled. Device-flow token refresh does not require a client secret; the app stores rotated access/refresh tokens together in its edition's Keychain. The public client ID belongs in `WorkbenchGitHubClientID` in the release's Info.plist. No client secret, personal access token or private key belongs in the application, repository or pack.

The public distribution uses [Workbench Packs](https://github.com/apps/workbench-packs). A repository owner installs it for the selected pack repositories; each colleague then connects their own GitHub account from Workbench. The app has read-only Contents and Metadata permissions, device flow enabled, and no webhook or client secret.

Contribution stays in the source repository: **Open source and contribute** leads to its normal branch and pull-request workflow. Maintainers review content and rendered examples before publishing a new version. A hosted workspace database, simultaneous session editing, custom merge editor, organisation discovery directory and installed-app renaming are outside this increment.
