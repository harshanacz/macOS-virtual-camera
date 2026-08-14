# Installing Fuzzcam

## The short version

1. Build the `Fuzzcam` scheme in Release.
2. Copy `Fuzzcam.app` to `/Applications`. **This is not optional** — macOS refuses
   to install a camera extension from anywhere else.
3. Launch Fuzzcam. It requests camera access and submits its camera extension for
   installation.
4. Approve the extension in **System Settings → General → Login Items &
   Extensions → Camera Extensions**.
5. Open Zoom / Meet / Teams and pick **Fuzzcam** as your camera.

Step 4 is where most of the difficulty lives. Read on.

---

## Requirement: the app must be notarized

macOS will only load a camera system extension when the containing app passes
Gatekeeper. This was determined empirically on this machine (macOS 26.6.1), not
assumed:

| Build | `spctl -a -t exec` | Extension installs? |
|---|---|---|
| Apple Development signed | `rejected` | **No** |
| Developer ID signed, **not** notarized | `rejected` — `source=Unnotarized Developer ID` | **No** |
| Developer ID signed **and notarized** | `accepted` | **Yes** — the supported path |

Developer ID signing alone is *not* sufficient. Notarization is the actual gate.

The failure is confusing, so know what to expect. The app reports:

```
OSSystemExtensionErrorDomain Code=4  "Extension not found in App bundle."
```

and the system log shows:

```
sysextd: attempting to realize extension with identifier com.harshanacz.Fuzzcam.Extension
sysextd: no policy, cannot allow apps outside /Applications
```

Both are misleading. The extension *is* in the bundle and the app *is* in
`/Applications`. `sysextd` returns code 4 for any refusal to realize the
extension, and the "policy" line is the generic result of looking for an MDM
policy that would relax the rules. The `sysextd` binary spells out the real
condition:

```
Failing to realize %s as the app requesting activation isn't in the
/Applications folder and developer/groundhog mode isn't on
```

Diagnose it in one command:

```bash
spctl -a -vvv -t exec /Applications/Fuzzcam.app
# "accepted"  -> trust is fine, look elsewhere
# "rejected"  -> the extension will not load, whatever else is true
```

---

## Path A — notarize (the supported path)

### One-time setup

The App ID `com.harshanacz.Fuzzcam` already has the **System Extension** and
**App Groups** capabilities enabled, and a Developer ID Application certificate
for team `C37NWJLS6S` is already in the keychain. The only missing piece is
notarization credentials.

Create an app-specific password at [appleid.apple.com](https://appleid.apple.com)
(Sign-In and Security → App-Specific Passwords), then:

```bash
xcrun notarytool store-credentials fuzzcam-notary \
  --apple-id "your-apple-id@example.com" \
  --team-id C37NWJLS6S \
  --password "xxxx-xxxx-xxxx-xxxx"
```

This is stored in your keychain once and never needs repeating.

### Each release

```bash
./scripts/release.sh
```

The script refuses to start without the certificate and the credentials, then
archives, exports with Developer ID, verifies the bundle, notarizes, staples,
and asserts `spctl` accepts the result. The finished app lands in
`build/export/Fuzzcam.app`.

---

## Path B — developer mode (requires disabling SIP)

**Not recommended.** Only worth considering if you are iterating on the
extension itself and accept running the machine with SIP disabled. Notarizing
once is easier and safer.

1. Reboot into Recovery (hold the power button on Apple Silicon).
2. Terminal → `csrutil disable` → reboot.
3. `systemextensionsctl developer on`
4. Build, copy to `/Applications`, launch.

Re-enable SIP (`csrutil enable`) when you are done. Fuzzcam does not need SIP off
to *run* — only to install an unnotarized extension.

---

## Approving the extension

On the first successful submission macOS posts a notification and the app's
onboarding window shows step 2 as pending. Approve it here:

**System Settings → General → Login Items & Extensions → Camera Extensions →
enable Fuzzcam**

Then confirm the system really has it:

```bash
systemextensionsctl list
# expect a row: C37NWJLS6S  com.harshanacz.Fuzzcam.Extension (1.0/1)  [activated enabled]
```

And that it registered as a camera:

```bash
system_profiler SPCameraDataType | grep -A2 Fuzzcam
```

---

## Using it

1. Keep **Fuzzcam running** — the menu-bar icon must be present. Closing the
   preview or settings window is fine; quitting stops the video.
2. Open your meeting app.
3. Camera settings → **Fuzzcam**.
4. Change quality from the Fuzzcam menu at any time; it takes effect on the next
   frame, with no need to reselect the camera.

Some apps cache the camera list. If Fuzzcam does not appear, quit and reopen that
app — browsers in particular only enumerate devices at page load.

### Verified selection points

| App | Where |
|---|---|
| QuickTime Player | File → New Movie Recording → chevron next to record |
| Google Meet / Chrome | Settings → Video → Camera |
| Zoom | Settings → Video → Camera |
| Microsoft Teams | Settings → Devices → Camera |
| FaceTime | Video menu |

---

## Uninstalling

```bash
# 1. Remove the extension (asks for your password)
systemextensionsctl uninstall C37NWJLS6S com.harshanacz.Fuzzcam.Extension

# 2. Remove the app and its settings
rm -rf /Applications/Fuzzcam.app
rm -rf ~/Library/Group\ Containers/C37NWJLS6S.com.harshanacz.Fuzzcam
```

---

## Troubleshooting

**"Extension not found in App bundle" / nothing appears in `systemextensionsctl list`**
Gatekeeper does not trust the build. See the requirement section above. Check
`spctl -a -vvv -t exec /Applications/Fuzzcam.app`.

**The extension installed but Fuzzcam says "Connecting…" forever**
The app found no sink stream. Check the extension is actually running:
`pgrep -fl FuzzcamExtension`. If it is not, look for a crash in
`~/Library/Logs/DiagnosticReports/`.

**Meeting apps show a "Fuzzcam" card instead of video**
That is the extension's placeholder: it means the Fuzzcam app is not running.
Launch it.

**Fuzzcam appears twice, or an old build keeps launching**
Stale LaunchServices records from build folders. Clean them:

```bash
LSR=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
"$LSR" -dump | grep -oE "/[^ ]*Fuzzcam\.app" | sort -u    # find strays
"$LSR" -u /path/to/stray/Fuzzcam.app                       # unregister each
"$LSR" -f /Applications/Fuzzcam.app                        # re-register the real one
```

**Camera permission was denied**
System Settings → Privacy & Security → Camera → enable Fuzzcam. The app's own
error message links straight there.
