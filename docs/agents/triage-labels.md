# Triage Labels

The skills speak in terms of five canonical triage roles. This file maps those roles to the actual label strings used in this repo's issue tracker.

| Label in mattpocock/skills | Label in our tracker | Meaning                                  |
| -------------------------- | -------------------- | ---------------------------------------- |
| `needs-triage`             | `needs-triage`       | Maintainer needs to evaluate this issue  |
| `needs-info`               | `needs-info`         | Waiting on reporter for more information |
| `ready-for-agent`          | `ready-for-agent`    | Fully specified, ready for an AFK agent  |
| `ready-for-human`          | `ready-for-human`    | Requires human implementation            |
| `wontfix`                  | `wontfix`            | Will not be actioned                     |

When a skill mentions a role (e.g. "apply the AFK-ready triage label"), use the corresponding label string from this table.

Edit the "Label in our tracker" column to match whatever vocabulary you actually use.

## Milestones

There is one milestone, `2.0`, for breaking changes. When triage decides an issue needs one (a change ADR 0080 says needs a major release, such as raising the minimum Nim version), put it in the `2.0` milestone. Its PR targets `next`, not `main` (see "Branches" in CLAUDE.md). A PR into `next` doesn't close its issue on merge, so close the issue by hand, saying it landed on `next` for 2.0.

1.x issues get no milestone: release-please picks the next 1.x version when a change merges, so there is nothing to plan a 1.x milestone against.
