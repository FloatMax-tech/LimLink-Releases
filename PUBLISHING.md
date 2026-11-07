# Release checklist

This repository is the public release hub for LimLink. Source code lives in
[`source/`](source/). Never commit signing keys, certificates, credentials,
private build logs, or personal machine paths.

## Before making the repository public

- The owner confirms that two-factor authentication is enabled on the company
  GitHub account.
- The owner confirms that `source/` is intended for public release under the
  PolyForm Noncommercial 1.0.0 license.
- Check the complete commit history for personal email addresses, local machine
  paths, private URLs and secrets. Use the company support address or a GitHub
  noreply address for commits.
- Immediately after the repository becomes public, protect `main`:
  - require a pull request before merging
  - require at least one approval
  - require status checks to pass
  - require conversation resolution and linear history
  - block force pushes and branch deletion
  - include administrators

Free private repositories cannot enable branch protection; enable it right
after changing visibility.

## Release procedure

1. Build from one approved source revision. Use one unified package per
   platform; the former CN/WD split is no longer part of the release process.
2. Keep the application identity and signing identity stable. Verify an in-place
   upgrade without uninstalling. Keep all signing material on the build machine.
3. Upload the verified installers to the official website:
   `/download/macos`, `/download/android`, `/download/windows`. The iOS version
   is distributed through the App Store.
4. Create or update the GitHub Release using the exact files downloaded from
   the official site. Attach `SHA256SUMS-*.txt`; never publish placeholder
   packages or fabricated checksums.
5. Update the website `version.json` only after the installers and signatures
   are verified. The copy in this repository is not the live endpoint.
6. Verify all nine language READMEs, download links, App Store link, checksums
   and copyright/legal notices.
7. Confirm that `source/` matches the release version. Update
   `source/TECHNICAL.md` and `source/README.md` when behavior changes.

## Source synchronization

- `source/` is a clean public snapshot, not the private development history.
- Do not copy branches, reflogs, build artifacts, signing files or internal
  review notes into this repository.
- Run a secret scan before each source update.
- Keep `source/LICENSE` and `source/NOTICE` in sync with the root copies.
- Source is source-available under PolyForm Noncommercial 1.0.0; commercial use
  requires a separate written license.
