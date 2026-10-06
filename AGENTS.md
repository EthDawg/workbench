# Working on Workbench

The active project is `Ship-Work/workbench`, with contributions branching from and returning to `main`. Voice and StageKit are modules here; the old StageMark repository is an archive. Use this repository's issues and PRs for all new work. Preserve historical names in module identifiers and data-migration paths.

**Current scope is Mac desktop quality. iOS, iPadOS and the Chrome extension are paused until explicitly resumed after the [Mac release gate](https://github.com/Ship-Work/workbench/issues/7).** Retain their source and history; do not treat older proposals as active requirements. The public product is Workbench; Workbench Preview is the internal development edition.

Before adding or renaming anything a person can click, read the [Grammar](docs/workbench.md#grammar); CI's surface check compares every entry point with [the surface registry](docs/surfaces.json).

Read [the product contract](docs/workbench.md), [the source map](docs/design.md) and [CONTRIBUTING](CONTRIBUTING.md) before changing behavior. Inspect current source and release state; an illustration, passing build or another agent's answer is not proof of a working feature.

The [focused Mac foundation](docs/mac-foundation.md) decides the current refinement scope and complete-journey acceptance. Apply [Value before scope](docs/workbench.md#value-before-scope) to every contribution, including CI, updates, permissions, settings and marketing. Exploratory prompts are problem evidence; use research and judgment before turning them into features. Read the owning issue and current work before implementing a slice. Every changed journey needs a usable result, unavailable-dependency path, preserved work and clear exit; retired doors must retain recovery. Keep native/device acceptance separate from source checks, and update the owning contract instead of adding a competing roadmap.

For Mac wallpaper and presentation, [the structured experience contract](site/handbook/contract.json) owns capability status, lifecycle and acceptance scenarios. The website generates its human and agent records from it. For the separate iOS target, [the mobile specification](docs/ios-preview.md) owns scope, platform limits and acceptance. For selected-photo iPhone/Mac transfer, [the photo handoff contract](docs/photo-handoff.md) owns account, transport, deletion and delivery evidence. Mobile image export does not change the status of a Mac desktop capability. Update the owning record when the implemented contract changes; use GitHub issues for agreed work rather than creating another backlog.

Choose one user outcome, its state owner and a bounded change. Preserve originals, later manual desktop choices and independent jobs. Validate with synthetic data and report the tests actually run, screenshots, source revision and hardware/receiver limits. Do not replace live user data for tests.

Keep private records and credentials out of code, images and public evidence. Do not read or publish `site/.env.local`. Apple submission, notarization, public binary publication and external communications require their applicable task authority; documentation does not grant it.

For every Mac change, follow [the shared install/update workflow](docs/updating.md). For development, use the existing Preview identity and signed installer, never a new staging identity or privacy-permission reset. One integration owner controls the shared installed Preview. Verify the running build with Copy build details before claiming installed acceptance. Publishing must verify the released archive and promote its signed feed and website link together.
