# Release checklist

1. Build the Android APK with the existing installed signing identity. Verify package name and increased versionCode. Never publish signing keys.
2. Build the Windows installer from the same approved source revision. Its four-part update version must match AssemblyVersion. Verify signing and in-place upgrade behavior.
3. Create a release tag and upload installers. Use simple ASCII tag and asset names (letters, numbers, dots, hyphens, underscores).
4. Verify the public release download links, file hashes and installation. Then update updates.json on main. Keep the previous platform channel when releasing only one platform.
5. Test the new-version, up-to-date and offline flows in both apps.

The schema is `schemaVersion: 1`, with an object `channels`. Omit a platform until a verified installer exists. Android requires `version` (three numeric components), `versionCode` (positive integer), `url`, `notes`. Windows requires `version` (four numeric components), `url`, `notes`. Notes are plain text, at most 8000 characters; the document is limited to 128 KiB. URLs must point to this repository's `https://github.com/FloatMax-tech/LimLink-Releases/releases/download/<tag>/<asset>` and end in `.apk` or `.exe` as appropriate. Do not put draft URLs or placeholders into the live index.

Only release materials belong in this repository. Do not push a private source checkout or its history here. Never publish tokens, keystores, certificates, device logs, personal information, or test fixtures.
