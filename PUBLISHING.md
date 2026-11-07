# Release checklist

This repository is the public release hub for LimLink. Never copy private source history, signing keys, or internal build logs into this repository.

1. Build both CN and WD from the same approved source revision. Android assets end in -CN.apk / -WD.apk; Windows installers end in -CN.exe / -WD.exe. Keep application identity stable and use the existing signing identity. Verify in-place upgrade without uninstalling.
2. Host the CN packages on /download/android-cn and /download/windows-cn; WD on /download/android and /download/windows, under https://limlink.floatmax-tech.com.
3. CN only opens its download page in the system browser. WD manually reads https://limlink.floatmax-tech.com/version.json. Neither channel reads GitHub metadata. GitHub may be used as artifact storage only when publication is authorized.
4. Deploy version.json to the WEBSITE root after installer verification. This repository copy is not the live endpoint. Empty channels means no official package yet. Do not publish placeholder releases.
5. Schema: schemaVersion=1; channels.android requires version (3 numeric components), versionCode (positive monotonically increasing integer), notes; channels.windows requires version (4 numeric components matching AssemblyVersion), notes. Notes are plain text, max 8000 characters; JSON max 128 KiB. No url field is needed; clients use fixed official download pages. Preserve the other platform when updating one.
6. Verify CN opens only the browser, WD newer/current/missing/offline handling, all nine languages, actual package signatures and installation.
7. The verified App Store link (`https://apps.apple.com/jp/app/limlink/id6826498808`) is live in all nine READMEs. Keep the nine language pages in sync; do not invent or use a search-result URL.

Update the website privacy information to describe the WD request (IP address and standard request data only, no files, device names or bindings) and CN browser-only access.
