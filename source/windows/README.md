# LimLink Windows

Windows 11 desktop client and reusable .NET 10 core for nearby file transfers. Choose one or more files, choose a discovered device, then send; every file goes to each chosen device in turn. The receiver sees the sender's device name and explicitly accepts or rejects each file. Custom device names are saved locally; renaming is blocked during incoming approval or transfer. No manual fingerprint comparison or remote-link flow is exposed.

- Each file: **0–5,000,000,000 bytes** (decimal 5 GB). Several files can be queued and sent to several devices.
- Private sender snapshot and incremental SHA-256; file blocks are at most 1,048,576 bytes.
- TLS 1.3 mutual certificates and SPKI SHA-256 pinning to the selected discovery record; one TLS/HTTP 1.1 connection per transfer.
- `_limlink._tcp.local` DNS-SD with Swift-compatible `pv=1.0`, `fp`, `dt=windows`, `app=limlink`; self and invalid identities are filtered. Discovery currently uses IPv4 multicast on active LAN interfaces.
- Per-file asynchronous consent uses the name from that same connection's hello. Session ownership includes both its connection ID and certificate fingerprint.
- Exact offset ACKs, bounded Content-Length messages, strict integer manifest fields, incremental receive hashing, atomic publication without overwriting an existing file.
- Sender requests normally have a 120-second deadline. Only `POST /limlink/v1/sessions/{sid}/files/{fid}/complete` allows up to 30 minutes for receiver verification and durable publication; caller cancellation still interrupts the wait immediately.
- Pending consent and idle receive expire after 120 seconds. At most four inbound TLS connections and four retained sessions. Cancellation/disconnect/rejection removes private partial files; startup reclaims abandoned receive staging.
- Received files are saved directly in `Downloads` (earlier builds used `Downloads\LimLink`; that saved setting is migrated). Staging lives in a hidden `.limlink-staging` folder inside the receive folder. Identity and device name are under `%LOCALAPPDATA%\LimLink`. Production PFX files use DPAPI CurrentUser; the plaintext test protector exists only in the test project.

## Run the desktop app

Use Windows 11 (build 22000+) with TLS 1.3 enabled. The self-contained ZIP produced below includes the .NET runtime: extract the entire folder and run `LimLink.exe`. This is an unsigned build, not an installer. Allow the Windows firewall prompt for your private network so nearby devices can reach the listener; UDP 5353 is used for discovery. The listener prefers TCP 52470–52479 and falls back to an OS-assigned port if necessary.

Build and run with the .NET 10 SDK:

```powershell
cd windows
dotnet run --project src/LimLink.Desktop/LimLink.Desktop.csproj
```

Build the per-user installer (Inno Setup 6, no administrator rights; Start-menu shortcut carries the `LimLink.Desktop` AppUserModelID used by notifications):

```powershell
dotnet publish src/LimLink.Desktop/LimLink.Desktop.csproj -c Release -r win-x64 --self-contained true -o C:\Temp\LimLink-win-x64
ISCC.exe /DSourceDir=C:\Temp\LimLink-win-x64 /DAppVersion=0.3.0 installer\LimLink.iss
```

Build a standalone x64 release:

```powershell
dotnet publish src/LimLink.Desktop/LimLink.Desktop.csproj -c Release -r win-x64 --self-contained true -o C:\Temp\LimLink-win-x64
```

Completion means the receiver verified and published the file and returned a matching final report.

### Desktop UI

The desktop app is WPF (it still cross-builds on macOS with `EnableWindowsTargeting`) and follows the shared five-platform design: black/white palette, one signal green for live states, and the LimLink ring as the progress indicator.

- Two columns: file on the left (drop zone → selected file → progress ring with speed, time left and the connect / accept / transfer / verify steps → delivered or failed), nearby devices on the right with a Send button per row. Below 900 px the device list moves under the file.
- Choose one or more files with the button, Ctrl+O, drag and drop onto the window, or `LimLink.exe <file>` (also forwarded to an already running instance). The file picker and drop target append to a queue; every queued file is sent to each chosen device.
- Incoming files: an in-window consent dialog with sender, file, size, save location and the 120 s countdown; when the window is hidden or inactive, a Windows notification with Accept / Decline buttons is shown as well. Active receives show their own progress ring.
- Settings: device name, receive folder (default `Downloads`, changeable) and whether closing the window keeps LimLink running in the notification area. Name and folder changes restart the listener and are refused while a transfer or consent is active.
- Mica backdrop on Windows 11 22H2+ (solid fallback otherwise), light/dark follows the system, taskbar progress, single instance, recent transfers with a right-click menu (open, show in folder, delete to the Recycle Bin, remove from list).
- Motion: entrance and state transitions, gliding progress, ring draw-in, delivered burst, failure shake, spring button presses, staggered device rows, fading dialogs. All motion is disabled when Windows "Animation effects" is off.
- Nine UI languages (Simplified/Traditional Chinese, English, Japanese, Korean, French, German, Spanish, Italian). Settings has a language picker; the default follows the system. Strings live in `src/LimLink.Desktop/Localization/Strings.<tag>.json` and are embedded in the executable, so language changes apply immediately without a restart.
- Settings, recent transfers and `crash.log` live in `%LOCALAPPDATA%\LimLink`.

## Console host

The console host uses the same production core and DPAPI identity on Windows:

```powershell
dotnet run --project src/LimLink.Harness -- serve --name "Office PC"
dotnet run --project src/LimLink.Harness -- send --file C:\Files\report.pdf --name "Office PC"
```

`send` discovers receivers, prints a numbered list, and uses the selected discovery fingerprint automatically. `serve` asks for `yes` for each incoming file. `--receive DIR`, `--data DIR`, and `--port N` override the directories/port. Stop with Ctrl+C.

For disposable interoperability tests only, `--ephemeral-probe` uses an in-memory identity that is never persisted. `--accept-probe` is accepted only with that flag. Normal hosts always require consent. The probe emits a machine-readable `READY` line:

```sh
dotnet run --project src/LimLink.Harness -- serve --ephemeral-probe --accept-probe --receive /tmp/limlink-probe/received --data /tmp/limlink-probe/profile --port 0
```

Probe sending additionally supports `send --ephemeral-probe --file PATH --host HOST --peer-port PORT --fingerprint PIN` to exercise a known disposable test listener. These endpoint flags are not used by the desktop or normal console sending flow.

## Verification

Run from `windows` so `global.json` selects Microsoft.Testing.Platform:

```sh
dotnet build LimLink.slnx --artifacts-path /tmp/limlink-windows-artifacts
dotnet test --project tests/LimLink.Core.Tests/LimLink.Core.Tests.csproj --artifacts-path /tmp/limlink-windows-artifacts
```

Portable protocol/storage validation on a non-Windows host:

```sh
dotnet build tests/LimLink.Core.Tests/LimLink.Core.Tests.csproj -m:1
dotnet tests/LimLink.Core.Tests/bin/Debug/net10.0/LimLink.Core.Tests.dll -class- '*NodeTests' -class- '*OpenSslTlsTests' -maxThreads 1
```

The direct xUnit runner above includes binding, transfer, discovery, identity and sender-validation tests. Windows-only DPAPI and live-transfer cases report skips on macOS; the excluded Node/OpenSSL classes require a host capable of this application's mandatory TLS 1.3. Check the executed test count: an unsupported filter can otherwise select zero tests.

Tests cover immutable snapshots, the 5 GB metadata boundary and 5 GB+1 rejection, consent and same-connection sender names, connection/certificate ownership, exact offsets, bounded chunks, malformed JSON/HTTP frames, duplicate manifest keys, hash retry and failure, empty files, cancellation/disconnect/timeout cleanup, collision-safe publication, final reports, completion-only publication deadlines and cancellation, discovery filters and app policy. The Windows-only integration test transfers 2 MiB+17 bytes over real pinned mutual TLS and verifies that file bytes are not published before consent. Original TLS downgrade/pinning/resumption tests and DPAPI tests remain enabled for Windows.

Windows 11 25H2 validation of the WPF desktop: solution build with zero warnings; 76 of 80 tests pass (the three OpenSSL tests need `openssl` on PATH, and `NodeTests.App_mismatch_returns_403_and_does_not_pass_the_invite_gate` fails independently of the UI because the mismatch error is reported as retryable); self-contained win-x64 publish; real-LAN discovery of an Android phone; a 1.5 GB send from the app to a local `LimLink.Harness serve` and a 1.5 GB receive from `LimLink.Harness send`, both verified, including collision-safe naming.

Earlier validation performed on macOS: both core targets and the WinForms desktop cross-build; standalone win-x64 publish; portable tests. **macOS .NET SslStream cannot negotiate the required TLS 1.3**, so original live TLS tests fail on this host and the independent Python-to-.NET probe receives a TLS protocol-version alert. TLS was not downgraded. Windows UI operation, Windows DNS-SD/firewall behavior, physical cross-device transfers, and a complete Windows 5 GB payload transfer still need Windows runtime verification. Accepting 5 GB metadata is not a 5 GB payload benchmark.

2026-10-19 macOS check: .NET 10.0.402 cross-build with zero warnings, 66 of 69 portable tests passed and 3 Windows-only tests were skipped, and the self-contained win-x64 ZIP was produced. The WPF language picker and each translated layout still need a Windows runtime pass.

### Independent device binding

Use the separate **Device Binding** button beside Settings to choose a device without selecting a file. Bind buttons are confined to that picker and no longer appear in the main send list. The initiator's Bind action grants consent; only the recipient confirms. Bound devices can be unbound locally even while the peer is offline. Both apps must be running for automatic reception. Device names are display labels, not proof of ownership.

Binding uses the selected device's pinned mutual TLS key and the `binding-v1` control protocol. Windows protects its atomic binding store with CurrentUser DPAPI under the existing app-private LocalAppData directory. Each file connection must advertise the matching binding ID for its actual TLS peer and current own identity; absent or unilateral records, old clients, storage failures, and changed identities retain per-file consent. Unbinding does not retract saved files or cancel an already accepted transfer.

macOS can cross-compile Core and WPF, but .NET's native macOS SslStream cannot execute this app's mandatory TLS 1.3 network tests. The Windows-only `Real_pair_connection_and_matching_hello_enable_auto_receive_then_unbind_restores_prompt` test exercises production DPAPI storage, dedicated pinned pair connection, recipient consent, file hello, automatic receive, and authenticated revoke. Run on Windows for runtime acceptance; passing in-process handler/receiver tests on macOS does not establish network interoperability.

2026-10-24: Offline legal windows now show the confirmed company and `.com` support email, with an optional button opening the matching company webpage. Nine UI catalogs remain aligned. Release cross-build has zero warnings/errors, and the self-contained win-x64 package is verified; this package has not been installed or checked in a Windows UI session.

Later on 2026-10-24, all 18 published policy pages were checked. Legal links now resolve through the current UI language at click time; sections 8 and 10 are available as offline excerpts in all nine languages. Release build and self-contained packaging passed; this update has not been installed on Windows.

2026-10-23 macOS binding check: the entire solution (both Core targets, WPF and Harness) cross-builds with zero warnings or errors. The portable suite executes 87 cases: 83 passed and four Windows-only cases skipped. Binding checks cover recipient-only consent, actual certificate/connection ownership, deadlines and rate limits, durable completion, cancellation/revocation, storage failures, per-connection hello and app-scoped authorization. A matching LimLink binding does not grant automatic reception to CaseCheck, even though the ordinary app interoperability registry allows manually approved transfers. This is not Windows runtime or physical cross-platform acceptance.

### Native preview and received pictures (source update, 2026-10-25)

Selected file names and recent-file names open an offline preview. Images, bounded text, one PDF page at a time and native video/audio playback are supported; installed Windows codecs determine media and some image-format availability. Office documents offer an explicit Open With action. Executables, scripts, shortcuts, HTML and SVG are not launched by the fallback. The preview window has separate Open With, Photos and containing-folder actions where appropriate. A queued selection opens a list with an action for each file.

After verified receive publication, images are also copied to the user's Pictures/LimLink folder by default. Settings can disable future automatic copies. An export failure retains the verified download and offers retry in the recent-file menu. A separate durable receipt ledger and deterministic destination avoid duplicate copies on retry/restart; removing history or deleting the downloaded original does not remove the Pictures copy. Both send acknowledgement and verified receive publication show a ring that becomes a checkmark; full byte progress alone never does.

Discovery refreshes multicast memberships after network-address changes and periodically, sends only the relevant interface's address in each advertisement, continues after one interface fails, and retains multiple peer IPv4 candidates with same-subnet preference and connection fallback. It sets the multicast TTL option explicitly. No firewall rules or Windows network profiles are changed. Ethernet/Wi-Fi and Private/Public behavior still depend on the actual network and effective OS rules.

These are source changes. Windows-native compile/tests, PDF/media/Photos UI checks, restart/export permission checks and physical Ethernet/Wi-Fi discovery remain required; see `docs/verification/windows-preview-discovery-2026-10-25.md` for the actual validation record.
