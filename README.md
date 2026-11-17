# FileSync

## What it is

FileSync is a small menu-bar app for macOS (macOS 15 or later) that backs up chosen folders on your Mac to your own Linux server with rsync over SSH, and to one or more external disks. It watches the folders, sends only what has changed, and moves what is deleted or overwritten aside instead of removing it. The server and the disk hold backups, not working copies: changes go only from the Mac to the destination, never back.

The app is in Swedish and English. It follows the Mac's language and uses English for every other language. Settings has a Language picker with the options Same as the system, Svenska and English. A change takes effect the next time FileSync starts.

## Build and install

```bash
scripts/build-app.sh --install
open /Applications/FileSync.app
```

The script builds `build/FileSync.app`, signs it and copies it to `/Applications`. Without `--install` it only builds `build/FileSync.app`. An older `Filsynk.app` in Applications is the same app under its old name; `--install` removes it, and if you install from a disk image you remove it by hand. A local build is not notarized and cannot be shared with others as it is; the release on GitHub does that, see below.

The app icon is in `Resources/AppIcon.icns` and is drawn by `swift scripts/make-icon.swift`. Run the script again if you change the drawing.

"Start at login" turns itself on at the first launch, but only if the app runs from `/Applications`. The notification prompt from macOS appears the first time a notification is about to be shown.

### Disk image

```bash
scripts/build-dmg.sh
```

The script builds the app and puts it in `build/FileSync-<version>.dmg` together with a shortcut to Applications. Open the file and drag FileSync to Applications.

### Release on GitHub

Every push to `main`, including every merge into it, runs the tests on GitHub, builds the disk image and publishes it as a release named `v<version>-<run number>`. If only documentation changes (`*.md`, `docs/` and `LICENSE`), nothing runs. The workflow is in `.github/workflows/release.yml`.

You can also start the workflow by hand, for example when the secrets have just been added: under Actions → Release → Run workflow, or with

```bash
gh workflow run release.yml
```

The workflow has two jobs:

1. **test** runs `swift test`. It has no access to any secrets.
2. **release** builds the app, signs it, builds the disk image, has Apple notarize it and creates the release. It runs in the `release` environment.

The version in the name comes from `CFBundleShortVersionString` in `Resources/Info.plist`. The disk image is built for Apple Silicon.

#### Signed and notarized release

If the certificate has been added, the app and the disk image are signed with it, and if the key for notarization has been added, Apple approves the disk image. The app then opens without a warning on any Mac, and the permissions stay in place between versions. If the certificate is missing, the app is signed without one, see Good to know below.

The certificate and the key are stored as secrets in the `release` environment on GitHub, never in the repo. Anyone who clones or forks the repo cannot get at them. The environment only accepts runs from `main`. The certificate is loaded only after the app has been built, and is removed again as soon as it has signed.

You need this once:

1. **A Developer ID Application certificate.** Easiest in Xcode: Settings → Accounts → select the team → Manage Certificates → **+** → Developer ID Application. Only the account holder can create it. An Apple Development certificate is not enough here.
2. **Export it** from Keychain Access: right-click the certificate under My Certificates → Export → file format `.p12`, and choose a password for the file.
3. **Add it** as secrets. The values are read from the file and from a hidden prompt, so they do not end up in the shell history:

   ```bash
   base64 -i DeveloperID.p12 | gh secret set SIGN_CERT_P12_BASE64 --env release
   ```

   ```bash
   gh secret set SIGN_CERT_PASSWORD --env release
   ```

4. **An API key for notarization.** App Store Connect → Users and Access → Integrations → App Store Connect API → create a team key with the Developer role. Download the file `AuthKey_<key-id>.p8`; you can only do this once. The key's ID and the Issuer ID are on the same page.
5. **Add it:**

   ```bash
   base64 -i AuthKey_<key-id>.p8 | gh secret set NOTARY_KEY_P8_BASE64 --env release
   ```

   ```bash
   gh secret set NOTARY_KEY_ID --env release
   ```

   ```bash
   gh secret set NOTARY_ISSUER_ID --env release
   ```

6. **Delete the files** `.p12` and `.p8` from the disk, or put them in the password manager.

Check a downloaded disk image:

```bash
spctl --assess --type open --context context:primary-signature --verbose=2 FileSync-<version>-<number>.dmg
```

The output should say `accepted` and `source=Notarized Developer ID`.

#### Approval before release

The `release` environment can require you to approve each release with a click before the job gets access to the secrets: Settings → Environments → release → Required reviewers. GitHub offers this for public repos, and for private ones only in the larger plans.

#### Keep the secrets safe

- **Read every change to `.github/` and `scripts/` before it is merged into `main`.** What runs in the release job runs on the same machine as the certificate.
- **Do not give anyone else write access to the repo.** Anyone who can push can change the workflow.
- **Never add a pull request trigger** to the workflow that has the secrets.
- **If the certificate leaks,** revoke it on developer.apple.com and create a new one.

#### Good to know about a release without a certificate

- **It is signed without a certificate and not notarized.** The first time, macOS refuses to open the app. Go to System Settings → Privacy & Security and choose **Open Anyway**.
- **The permissions are asked for again for every new version,** because every build without a certificate counts as a new app.

## Signing

The build script always signs the app. The only question is whether it does so with or without a certificate. The app works equally well in both cases.

### Why sign with a certificate

- **Without a certificate** macOS sees every new build as a new app. The permissions for notifications, start at login, the local network and protected folders such as Documents may then have to be granted again after every rebuild.
- **With a certificate** the permissions are tied to the team and the app's ID (`com.freberdev.filsynk`) instead of to the individual build, and stay in place between builds. Under Login Items the app appears with the developer's name.

The script does not notarize the app. So it cannot be shared with others as it is, with or without a certificate.

### Which certificate

- **Apple Development** is enough for your own Mac. Xcode creates it under Settings > Accounts > Manage Certificates > `+` > Apple Development. It is valid for one year.
- **Developer ID Application** is required to run the app on another computer without warnings, together with notarization. It requires a paid developer account, and only the account holder can create it.

### Find the certificate's name and hash

```bash
security find-identity -v -p codesigning
```

The output has one line per valid certificate:

```
  1) 0123456789ABCDEF0123456789ABCDEF01234567 "Apple Development: Your Name (ABCDE12345)"
     1 valid identities found
```

The 40 characters first are the hash, and the text in quotation marks is the name. You can use either.

If there are several certificates, for different teams, choose the team the app should belong to. Which team a certificate belongs to is shown in the fields `O` (organization) and `OU` (team ID):

```bash
security find-certificate -c "Apple Development: Your Name (ABCDE12345)" -p | openssl x509 -noout -subject
```

### Specify the certificate

There are two ways. The environment variable takes precedence over the file. No `.env` file is read.

**1. The file `.signing-identity`** in the project folder, that is, the same folder as `Package.swift`. The first line must be the certificate's name or hash, and nothing else. The file is ignored by git and never checked in.

```bash
echo "0123456789ABCDEF0123456789ABCDEF01234567" > .signing-identity
```

After that, `scripts/build-app.sh` signs with the certificate every time, with no further steps.

**2. The environment variable `FILSYNK_SIGN_IDENTITY`**, for a single build:

```bash
FILSYNK_SIGN_IDENTITY="Apple Development: Your Name (ABCDE12345)" scripts/build-app.sh --install
```

If it should always apply, add the line `export FILSYNK_SIGN_IDENTITY="…"` to `~/.zshrc`.

To go back to signing without a certificate, delete `.signing-identity`, or set `FILSYNK_SIGN_IDENTITY=-` for a single build.

**Name or hash?** The hash always points to exactly one certificate, but it changes when the certificate is renewed. The name usually survives a renewal, but it does not work if two certificates have the same name.

### Verify the signature

The build script ends with `(signed with a certificate)` or `(signed ad hoc)`. Check the installed app like this:

```bash
codesign -dv --verbose=2 /Applications/FileSync.app
```

- With a certificate: `Authority=Apple Development: …` and `TeamIdentifier=` followed by the team ID.
- Without a certificate: `Signature=adhoc` and `TeamIdentifier=not set`.

```bash
codesign --verify --strict /Applications/FileSync.app
```

No output means the signature is valid.

### After the first build with a certificate

The first time the app is signed with a certificate, macOS treats it as a new app. The same applies if you change the certificate, the team or the app's ID. Do this once:

1. Turn on "Start at login" in FileSync's settings. It only turns itself on at the very first launch.
2. Look under System Settings > General > Login Items and remove any older FileSync or Filsynk entry.
3. Allow notifications when macOS asks, which happens the first time a notification is about to be shown.

After that, the permissions stay in place between builds.

### Troubleshooting

| Message | Cause and fix |
|---|---|
| `no identity found` | The name or the hash is wrong, or the certificate has expired. Run `security find-identity -v -p codesigning` and correct `.signing-identity`. If the certificate has expired, renew it in Xcode. The build is aborted, and no unsigned app is installed instead. |
| `ambiguous (matches … and …)` | Several certificates match the name. Specify the hash instead. |
| macOS asks whether `codesign` may use the key | Choose Always Allow. |
| `errSecInternalComponent` | The keychain is locked, for example when logged in over SSH. Unlock it with `security unlock-keychain`. |

## Connection

The app logs in to the server with a key of its own and never handles the server's password. The key is set up once, in five steps. In the examples, `user@server` stands for your own address, for example `alice@192.168.1.10`.

### Prerequisites

- The server runs an SSH server and has rsync version 3 or later. On Ubuntu and Debian both are installed with `sudo apt install openssh-server rsync`.
- You can log in to the server from the Mac, with a password or with a key you already have.

### 1. Check that the server is reachable

```bash
ssh user@server 'echo connected; rsync --version | head -1'
```

The first time, `ssh` asks whether to accept the server's host key. Answer `yes`. Then type the password. The output should end like this:

```
connected
rsync  version 3.2.7  protocol version 31
```

If it says `openrsync` or a version below 3, the server does not work as a destination.

### 2. Create the key

```bash
ssh-keygen -t ed25519 -N "" -C filsynk -f ~/.ssh/filsynk_ed25519
```

- `-t ed25519` chooses the key type.
- `-N ""` gives a key without a passphrase, which is required for the sync to run unattended.
- `-C filsynk` sets a comment that makes the key easy to recognize on the server.
- `-f` says where the key is saved.

The command creates two files: the private key `~/.ssh/filsynk_ed25519`, which never leaves the Mac, and the public key `~/.ssh/filsynk_ed25519.pub`, which is put on the server. If the file already exists, `ssh-keygen` asks before overwriting anything; answer `n` and use the existing one.

The app creates the key itself when you press Test connection, if it is missing. So this step can be skipped.

### 3. Put the public key on the server

```bash
ssh-copy-id -i ~/.ssh/filsynk_ed25519.pub user@server
```

Here you type the server's password one last time, directly to `ssh`. The app never sees it. The command adds a line to `~/.ssh/authorized_keys` on the server.

If `ssh-copy-id` cannot be used, this does the same thing:

```bash
cat ~/.ssh/filsynk_ed25519.pub | ssh user@server 'mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys'
```

### 4. Check that the key works without prompts

This is the same login the app does:

```bash
ssh -i ~/.ssh/filsynk_ed25519 -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10 user@server 'echo connected; rsync --version | head -1'
```

The output should be the same as in step 1, without any password being asked for. `BatchMode=yes` makes `ssh` fail instead of asking, just as in the app.

### 5. Connect in the app

Type the server address in Settings and press **Test connection**. The test checks that the login works without a prompt and that the server's rsync is version 3 or later, and it creates and looks up the folders on the server. If it succeeds, it says `✓ Connected, rsync 3.x.y`.

- **Nothing is synced to a server until the test has succeeded against exactly that address.** If you change the address, you must test again. The test also saves the server's home directory, both with and without symlinks resolved (`verifiedHome` and `verifiedLogicalHome` in `config.json`).
- A folder on the server that is the home directory, `/` or anything above the home directory is refused, as are `~/.ssh` and everything under it and paths with `.` or `..`. This applies even if `config.json` is edited by hand.
- Unknown host keys are never accepted automatically. Step 1 makes the server known in the usual way.

### Other port, other name or access from outside

The app calls the ordinary `ssh`, which reads `~/.ssh/config`. Put the server there if it listens on a port other than 22, or if you want to reach it under the same name both at home and away:

```
Host myserver
    HostName 192.168.1.10
    User alice
    Port 2222
```

Then type `myserver` as the address in the app. First check with `ssh myserver` that the details are right.

Reaching a server on the home network from outside requires a VPN or similar, and that is outside the app. If the server cannot be reached, the changes are queued until it can.

### View, replace or revoke the key

See that the key is on the server:

```bash
ssh user@server 'grep filsynk ~/.ssh/authorized_keys'
```

See the key's fingerprint on the Mac:

```bash
ssh-keygen -lf ~/.ssh/filsynk_ed25519.pub
```

Revoke the key, so that it can no longer log in. The command removes the line on the server and saves the old file as `authorized_keys.bak`:

```bash
ssh user@server "sed -i.bak '/ filsynk\$/d' ~/.ssh/authorized_keys"
```

Then delete the key on the Mac:

```bash
rm ~/.ssh/filsynk_ed25519 ~/.ssh/filsynk_ed25519.pub
```

To replace the key, revoke the old one and go through steps 2 to 5 again.

### Troubleshooting the connection

| What happens | Cause and fix |
|---|---|
| The app shows "The server does not accept the key yet" | The public key is not on the server, or the user name in the address is wrong. Do steps 3 and 4. |
| Step 4 gives `Permission denied (publickey,password)` | The same thing. Also check the permissions on the server: `~/.ssh` must be `700` and `~/.ssh/authorized_keys` `600`, and the home directory must not be writable by others. |
| `Host key verification failed` | The server is unknown to the Mac, or has changed its host key after a reinstall. Log in once by hand with `ssh user@server`. If the server has changed its key, first remove the old one with `ssh-keygen -R server`. |
| The app shows "The server cannot be reached" | Wrong address, the server is switched off or you are on a different network. `nc -z -G 5 server 22` shows whether the port can be reached. |
| The app shows "The server needs rsync 3 or later" | Install rsync on the server, see Prerequisites. |
| Nothing helps | Add `-v` to the command in step 4. `ssh` then prints every step of the login. |

### Allowed characters

The path on the server and the server address are passed to the server's shell, so only harmless characters are accepted:

- **Path on the server:** letters (including å, ä, ö) and digits, and `. _ - / + @ , = %`. A `~` may only come first and be followed by `/` or nothing (`~/Backup-2026/Mac_1` is fine, `~/R&D` or `~/Photo*` is refused).
- **Server address:** the letters a–z, digits and `. _ - @ : [ ] %`, and it must not start with `-` (`user@192.168.1.10`, `server.example.com`, `user@[fe80::1%en0]`). A user name with å, ä or ö therefore does not work; `user@server` in the examples only stands for your own address.
- **The key file** must not contain spaces, quotation marks, `$`, `` ` `` or `\`, and the full path (with the home directory instead of `~`) must not contain spaces.
- **Exclusions** are ordinary patterns such as `node_modules` or `*.tmp`. An exclusion must not be empty or start with `!`, `+ `, `- `, `: ` or `. `, because rsync reads such lines as rules.
- **Folders on the Mac** must not contain FileSync's own files (`~/Library/Logs/Filsynk` and `~/Library/Application Support/Filsynk`); watching the whole home directory is therefore refused.

Trade-off: a key without a passphrase means that anyone who gets at your user account on the Mac can also log in to the server. That is the price of the sync running unattended. The key is dedicated to FileSync, so you can remove its line from `~/.ssh/authorized_keys` on the server without affecting anything else.

The configuration is in `~/Library/Application Support/Filsynk/config.json`. Each folder has a list `destinations` with one destination per entry: `{"kind":"server","path":…}` or `{"kind":"disk","volumeUUID":…,"volumeName":…,"path":…}`. An older file with `remotePath` is read and rewritten in the new form the next time something is saved. The log is in `~/Library/Logs/Filsynk/filsynk.log` ("Show log" in the menu). If `config.json` cannot be read, the app shows an error, leaves the file untouched and locks the settings until the file has been corrected or removed and the app has been restarted.

## Adding a folder

A folder can have several destinations: one on the server and any number of external disks. The table in Settings has one row per destination.

Press **+** in Settings. Under **Folder on the Mac** choose a folder that is already watched or **Choose folder…**. Under **Destination** choose **Server** or **External disk**:

- **Server:** enter where the folder should be on the server (pre-filled with `~/` and the folder's name).
- **External disk:** press **Choose folder on the disk…** and choose or create a new, empty folder on the disk. See External disk below.

Then press **Add**. A folder that is not already watched is inspected by the app before anything is saved. If there is anything to warn about, for example files that are only in iCloud (they are downloaded at the first sync), more than 100,000 files or a folder of its own called `Raderat` (Swedish for "deleted") at the top level, the warning is shown with the buttons **Add anyway** and **Cancel**. Nothing is saved and no sync starts until you have chosen. Without warnings, the destination is added directly.

**–** removes the selected destination from the app. Nothing is removed on the server or the disk. If a folder's last destination is removed, it is no longer watched.

## What it looks like on the server

The contents of the folder are mirrored as they are. `Raderat/` is at the top level of the destination folder:

```
/home/user/Sync/                  <- mirror of ~/Sync on the Mac
  report.docx
  Projects/
    notes.md
  Raderat/                        <- exists only on the server
    2026-11-17_143205/            <- one sync run (local time, start)
      report.docx                 <- previous version, overwritten
      Projects/
        old.txt                   <- deleted on the Mac
```

- `Raderat/` is only emptied by hand. The app never removes anything on the server.
- The name `Raderat` is reserved at the top level of every watched folder. If such a folder exists on the Mac, it is not backed up, and the app warns.

## Restoring

Fetch a file as it looks now:

```bash
rsync -a user@server:/home/user/Sync/report.docx ~/Restored/
```

Fetch an older version or a deleted file under `Raderat/`:

```bash
rsync -a user@server:/home/user/Sync/Raderat/2026-11-17_143205/report.docx ~/Restored/
```

`/home/user/Sync` stands for the folder's path on the server, that is, `path` in the folder's destination of kind `server` in `config.json`. It is a good idea to put the file somewhere other than the original so that you do not overwrite anything by mistake.

## External disk

The same folder can be mirrored to an external disk, alongside the server or instead of it. The disk works like the server: the contents are mirrored, and what is deleted or overwritten is moved to `Raderat/`.

### Adding

Settings → Folders → **+** → **External disk** → **Choose folder on the disk…**. The folder on the disk must be new and empty; Finder's own hidden files (`.DS_Store` and `._*`) do not count. Create it in the picker with **New Folder**. The disk itself, that is, its root, cannot be chosen.

The app puts a small file, `.filsynk`, in the folder. It says which folder on the Mac belongs to the folder on the disk. The app never syncs into a folder that lacks the file or whose file belongs to another folder, and a folder with contents is accepted only if its file belongs to this very folder. A folder that is renamed on the Mac counts as a different folder: it cannot reuse its old folder on the disk, so choose a new one.

The disk should be formatted as APFS, Mac OS Extended or exFAT.

### How the disk is identified

The disk is identified by its volume ID, never by its name. If you connect another disk with the same name, nothing happens. A disk that has been reformatted or replaced is a new disk, and the destination must be added again. The name in the table and in the menu is only a label.

### Connecting and ejecting

- When the chosen disk is connected, it is synced right away.
- While the disk is connected, it follows the same wait time as the server.
- When the disk is not connected, the row shows `Not connected · last synced <date>` and nothing is attempted. The menu-bar icon is not affected by an absent disk.
- On eject, a running sync is cancelled so that the disk can be ejected. If macOS refuses the eject, the app resumes the sync after about a minute.
- A watched folder that is itself on an external disk is not synced while that disk is disconnected.

### Format

- **APFS and Mac OS Extended** keep permissions and owners.
- **exFAT** does not keep permissions and owners. Symbolic links and all file names work. macOS creates a 4 kB file, `._<name>`, next to every file on exFAT. The app ignores them.

### Raderat on the disk

`Raderat/<timestamp>/` in the folder on the disk works as on the server: deleted and overwritten files are moved there, nothing is removed, and the folder is only emptied by hand. A file that is replaced by a folder or link with the same name is also moved there first. Limitation: a symbolic link whose target changes is replaced without the old link being saved.

### Permission

The first time the app reaches an external disk, macOS asks for permission for removable volumes. Answer Allow.

## Good to know

- **Renaming or moving a folder** inside a watched folder looks like a deletion plus new files. Everything under it is uploaded again and the old copy ends up in `Raderat/`. Nothing is lost, but it takes time and disk space. The same applies if you rename the folder on the server or on the disk, or on the Mac: it is a removal plus a new folder. If the folder is renamed on the Mac, the marker on the disk also belongs to the old folder, so a new destination on the disk must be added.
- **Files that change often** give one moved-aside copy per sync run, at most about one per minute with the default setting.
- **`Raderat/` grows,** on the server and on the disk, until you empty it by hand.
- **If the app quits, the sync stops.** What changes in the meantime is picked up at the next start.
- **macOS privacy protection:** `~/Sync` needs no permission. If Desktop, Documents or Downloads is added, macOS asks for permission once.
- **Unsigned app:** the app is built locally and signed without a developer certificate. That works on your own Mac but cannot be shared.
- **The first sync into a folder on the server that already has contents** moves those contents to `Raderat/`. Nothing disappears.
- **Expensive networks:** automatic sync waits until the network type is known at startup and is held when macOS marks the network as expensive or constrained (tethering from a phone, Low Data Mode). "Sync now" always runs. If the server cannot be reached, the changes are queued and retried (1, 2, 5, 15 minutes, then every 15th) and immediately when the network changes.
- **A denied login** gives a notification right away. After that, the app only retries every 15 minutes and not on a network change, so that the server does not see a stream of failed logins (fail2ban could otherwise lock the Mac out). "Sync now", "Resume" and a change in Settings retry right away.
- **Notifications:** if the sync fails at least three times in a row, a notification comes at the first real error in the series (for example a full disk), once per series. If a folder has not been synced to the server for more than a day, a notification comes, once a day. A disk that is not connected gives no such notification.
- **Changed settings** (for example exclusions) do not reset a folder's status. A sync that is running is allowed to finish if nothing that affects it has changed.
- **The status "Not set up"** is shown as long as any folder is not set up, even if other folders are synced.
- **A disconnected disk** gives the row `Not connected`. If the disk is the only thing left to sync, the menu shows "The disk is not connected"; if another destination is connected, the status for that one applies.

## Tests

```bash
swift test
```

The integration tests for the sync itself (`SyncIntegrationTests`) require rsync 3.x on the Mac (`brew install rsync`) and are otherwise skipped. The system's `/usr/bin/rsync` is `openrsync` and does not work as a receiver.

There is also a test all the way against the real server (`EndToEndTests`), which only runs when you point out the server and the key:

```bash
FILSYNK_E2E_SERVER=user@server FILSYNK_E2E_IDENTITY=~/.ssh/filsynk_ed25519 swift test --filter EndToEndTests
```

It uses a temporary local folder and a directory of its own, `~/filsynk-interop-e2e-<random-number>`, on the server, which is removed afterwards. `~/Sync` is never touched. The script `scripts/verify-rsync-interop.sh <server> <key>` only tries the rsync flags against the server.

Another test runs the whole chain against real volumes, without any physical disk (`DiskImageTests`). It creates its own disk images (APFS and exFAT, 40 MB) in a temporary directory, mounts them there with `hdiutil attach -mountrandom` and detaches them again afterwards. That way nothing ends up under `/Volumes` and a real external disk is never touched. It tests sync to both formats, that overwritten and deleted files end up in `Raderat/`, Swedish file names and symbolic links on exFAT, that a disk that is connected again catches up by itself, and that another image with the same name but a different ID is left alone. It only runs when you ask for it:

```bash
FILSYNK_DISK_IMAGE_TESTS=1 swift test --filter DiskImageTests
```

The images are mounted without `-nobrowse`, because FileSync does not see hidden volumes. It takes about a minute and an image may be visible in Finder for a while. If a run is interrupted before it has cleaned up: look for `filsynk-diskprov-` in the output from `hdiutil info` and detach exactly that device with `hdiutil detach <device>`.

## Checklist

Do this once. Note down anything that does not match. `user@server` and `/home/user` stand for your own server, `Backupdisk` for your own external disk.

1. **Install.** `scripts/build-app.sh --install`, then `open /Applications/FileSync.app`.

2. **Appearance.**
   - The icon is in the menu bar and no icon is in the Dock.
   - The menu has a status line at the top (for example "All synced · 14:32"), one row per destination (for example `~/Sync → Server: ~/Sync   ✓ 14:32`), and then Sync now, Pause (becomes Resume), Settings…, Show log and Quit FileSync.
   - "Show log" opens `~/Library/Logs/Filsynk/filsynk.log`.

3. **Settings** (first remove `~/Library/Application Support/Filsynk/config.json`):
   1. Settings opens by itself with one row in the table with `~/Sync` under On the Mac and `Server: ~/Sync` under Destination, an empty address and a short guide under Server.
   2. Type `user@server` and press Test connection: `✓ Connected, rsync 3.x.y`. `config.json` now has `/home/user/Sync` as `path` in the folder's destination of kind `server`, and `verifiedServer`, `verifiedHome` and `verifiedLogicalHome`. The Destination column shows `Server: ~/Sync`.
   3. Enter an address that does not exist (`x@192.0.2.1`): `The server cannot be reached.` within about 10 seconds. Enter `x@h;ls`: red error, nothing is saved.
   4. Add a folder that is inside `~/Sync`: red error, nothing is saved. Enter `~` or `~/R&D` as the folder on the server: refused.
   5. Add a folder with files that are only in iCloud (or a folder of its own called `Raderat` at the top level): the warning is shown with Add anyway and Cancel. Cancel saves nothing; Add anyway adds the folder and the sync only starts then.
   6. Type `node_modules, *.tmp` in Exclusions: `config.json` has `"exclude": ["node_modules", "*.tmp"]`. Type `!` in Exclusions: red error, nothing is saved.
   (Put the right server address back and test the connection again after item 3.)

4. **Test all the way** (the first time anything is written in `~/Sync` on the server). What is checked on the server is done with `ssh user@server 'ls -R ~/Sync'` or `cat`:

   | # | Do on the Mac | Expected |
   |---|---|---|
   | 1 | `echo v1 > ~/Sync/test.txt` | The icon shows pending and then synced within about 70 s. `test.txt` exists on the server |
   | 2 | `echo v2 > ~/Sync/test.txt` | On the server `test.txt` contains `v2` and `~/Sync/Raderat/<time>/test.txt` contains `v1` |
   | 3 | `rm ~/Sync/test.txt` | On the server `test.txt` is gone from `~/Sync` and is in a new `Raderat/<time>/` with `v2` |
   | 4 | Turn off wifi, `echo x > ~/Sync/offline.txt`, wait 90 s | The icon shows "Waiting for the server". No notification |
   | 5 | Turn on wifi | On the server `offline.txt` appears without anyone doing anything |
   | 6 | `Pause`, `echo y > ~/Sync/pause.txt`, wait 90 s, `Resume` | On the server there is no `pause.txt` during the pause. It appears right after `Resume` |
   | 7 | Tether from a phone, `echo z > ~/Sync/expensive.txt`, wait 90 s | On the server there is no `expensive.txt`. `Sync now` sends it |
   | 8 | `echo l > ~/Sync/lid.txt`, close the lid within 30 s, wait a few minutes, open it | On the server `lid.txt` appears within about a minute after the lid is opened |
   | 9 | On the server: move the line out of `~/.ssh/authorized_keys`, change a file on the Mac | Notification `FileSync: login denied`. Put the line back on the server and press `Sync now`; the sync succeeds |
   | 10 | Log out and in | FileSync starts by itself |
   | 11 | Leave the app untouched for 10 min, check in Activity Monitor | CPU 0.0% at idle, memory under 60 MB |

   Item 9 changes `authorized_keys` on the server and is done by hand there. Afterwards, delete the test files from `~/Sync` on the Mac; they end up in `Raderat/` on the server, which is intended.

5. **External disk** (a disk formatted as APFS, Mac OS Extended or exFAT; do this part with a new, empty folder on the disk):
   1. Add a destination: Settings → Folders → **+**, choose a new folder on the Mac, choose **External disk**, **Choose folder on the disk…** and create a new folder in `/Volumes/Backupdisk`. The text next to the button becomes `Backupdisk: <folder>`. The row appears in the table with the destination `Backupdisk: <folder>`, and the folder on the disk contains `.filsynk`. Choose a folder with contents instead: red error, nothing is saved.
   2. Watch the first sync: the row goes from `Waiting` to `Syncing…` and then `✓ <time of day>`, and the files are on the disk.
   3. Eject the disk in Finder: if a sync is running it is cancelled, the eject succeeds and the row shows `Not connected · last synced <date>`. The menu-bar icon shows no error.
   4. Change a file in the folder on the Mac while the disk is ejected: nothing is attempted.
   5. Connect the disk: the sync starts right away and the changed file catches up.
   6. Delete one file and overwrite another on the Mac: after the sync, the old versions are in `Raderat/<time>/` in the folder on the disk.
   7. Connect another disk, with the same name if possible: nothing happens, no prompt and no sync.

6. **Troubleshooting:**
   - If the app does not start at login: check under System Settings > General > Login Items that FileSync is there and turned on, and that the app is in `/Applications`. Turn "Start at login" in FileSync's settings off and on to register it again.
   - If the notifications are not shown: check that FileSync is allowed to show notifications under System Settings > Notifications. Every notification is also written in the log, so it can be read there via "Show log".

## License

FileSync is free software under the MIT license, see [LICENSE](LICENSE). The program is provided as is, without warranty: always keep more than one copy of what is important.
