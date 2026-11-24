# Contributing

1. Read the root README, architecture and configuration catalogue. Start from the reviewed implementation branch named there.
2. Create `feature/your-change` from that branch; use one bounded behavior per pull request.
3. Install the manifest-pinned dependencies. Configure isolated local/sandbox services and synthetic fixtures. Never run migrations or destructive tests on shared data.
4. Run the checks listed in the README and add a regression for behavior changes. Record commands, results and blocked dependencies explicitly; do not mark unrun checks as passed.
5. Update affected API schemas, migrations, events, authorization and setup instructions. Include compatibility/rollback details for state changes.
6. Open a pull request against the implementation branch. Include source SHA, verification evidence and any environment assumptions. Maintainer review precedes release/deployment.

## Release procedure

A documentation commit is not a release. Before a release, record source revision, lockfiles, image digest, API/schema versions, migration plan, test results and rollback artifact. Follow the existing deployment workflow only for the explicitly selected environment. Never infer a deployed version from a mutable branch or image tag.

## Documentation scope

Use Markdown headings, fenced language-tagged examples and relative links. Keep secrets and real customer data out of examples. Existing license and notices remain authoritative.
