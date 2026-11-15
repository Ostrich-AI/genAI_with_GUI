# genAI_with_GUI handover guide

## Purpose and source

Public generative AI UI demonstration containing a source archive.

Reviewed source ref: `8ec1f27cc86014136bdb99186ec76615f195d239`; default branch: `main`. No staging image-to-source mapping was established for this repository.

## Prerequisites and setup

Use the toolchain and entry point listed in the reviewed source files below.

Read the source/release inventory before running a binary or script. If the repository holds an archive, unpack it in an isolated workspace and inspect the contained manifest before installation.

## Configuration

The following setting names were observed in selected code. Obtain values through the approved secret/configuration process; this list may omit settings in unread modules.

- `OPENAI_API_KEY`
- `QDRANT_URL`

## Tests and verification

Test dependencies or files in source are not evidence of a passing run. See source test folders/workflows for declared commands.

Run appropriate tests in an isolated environment with approved configuration and keep the run URL, source ref and results. Some declared lint/test scripts modify files or clean caches; inspect before executing.

## Deployment and rollback

Review Dockerfiles, workflows and the owner-confirmed GitOps/IaC source. Record image digest, environment, migration revision, smoke checks and rollback limitation. Deployment credentials, cloud state and data restoration are outside a Git-only source checkout. Do not run reset/drop/re-index actions against live systems from a copied example.

## Recovery and continuity

Before handover acceptance, verify source/dependency availability, company administration, secret custody, data/config backups and a tested restore. A new engineer must demonstrate setup and a representative journey without undocumented vendor assistance. Record unresolved steps with named owner/date.

## Exact questions to close

1. Is the source/ref above the correct supported version? If different, provide its repository and commit.
2. Which configured image is running now? Provide the image digest and environment.
3. Which documented setup/rollback/restore step has been demonstrated most recently? Link the existing evidence.
4. Which dependencies or accounts remain under vendor control?

## Existing evidence

- [README.md](https://github.com/Ostrich-AI/genAI_with_GUI/blob/8ec1f27cc86014136bdb99186ec76615f195d239/README.md)
