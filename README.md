# 1Password Flatpak Browser Integration

This script will automatically add support for 1Password to integrate with Flatpak web browsers on Linux. I haven't tested every browser, so add a comment if it doesn't work for your browser.

Note: The 1Password app itself needs to be installed as a native package.

To use this script, follow these steps:
1. Download the script (right-click on "Raw" and click "Save Link As").
2. Open your terminal in the directory that you downloaded the script to. For example, if it's in your Downloads folder, run `cd Downloads` after opening your terminal.
3. Mark the script as executable using the command `chmod +x 1password-flatpak-browser-integration.sh`.
4. Run the script using the command `./1password-flatpak-browser-integration.sh`.
5. When it asks, enter the Flatpak application ID of your browser, then press Enter. If it's not listed, the easiest way to find it is to run `flatpak list --app --columns=application | grep -i <browser name>`, replacing `<browser name>` with the name of your browser.
6. Restart both 1Password and your browser.

This is generally made following [this guide](https://www.1password.community/discussions/1password/flatpak-browser-and-native-desktop-app/108438), but I'll add some further explanation as to how it works here.

# Native Messaging Hosts

Web browsers communicate with native applications using something called "Native Messaging" ([Firefox](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Native_messaging), [Chrome](https://developer.chrome.com/docs/extensions/develop/concepts/native-messaging)). This has three components:
1. The extension specifies what native application it wants to communicate with. For example, the 1Password extension says that it supports the com.1password.1password native host.
2. The application places a JSON file in a specific directory of the browser (`~/.config/google-chrome/NativeMessagingHosts` for a native installation of Chrome and `~/.mozilla/native-messaging-hosts` for native Firefox). This JSON file tells the browser what to do when the extension calls that native host, and it specifies a list of extension IDs so that only certain extensions can use it. This is what it looks like for 1Password:
<details>
    <summary>1Password Native Host JSON</summary>

  ### Chrome
  ```json
{
    "name": "com.1password.1password",
    "description": "1Password BrowserSupport",
    "path": "/usr/lib/opt/1Password/1Password-BrowserSupport",
    "type": "stdio",
    "allowed_origins": [
        "chrome-extension://hjlinigoblmkhjejkmbegnoaljkphmgo/",
        "chrome-extension://gejiddohjgogedgjnonbofjigllpkmbf/",
        "chrome-extension://khgocmkkpikpnmmkgmdnfckapcdkgfaf/",
        "chrome-extension://aeblfdkhhhdcdjpifhhbdiojplfjncoa/",
        "chrome-extension://dppgmdbiimibapkepcbdbmkaabgiofem/"
    ]
}
  ```

  ### Firefox
  ```json
{
    "name": "com.1password.1password",
    "description": "1Password BrowserSupport",
    "path": "/usr/lib/opt/1Password/1Password-BrowserSupport",
    "type": "stdio",
    "allowed_extensions": [
        "{0a75d802-9aed-41e7-8daa-24c067386e82}",
        "{25fc87fa-4d31-4fee-b5c1-c32a7844c063}",
        "{d634138d-c276-4fc8-924b-40a0ea21d284}"
    ]
}
  ```
</details>
3. That JSON file specifies an executable file on the host system, which the browser runs when the extension triggers it. This is usually `/usr/lib/opt/1Password/1Password-BrowserSupport` on Linux, which is inaccessible from Flatpaks.

This normally works well. The problem is that, since Flatpaks are sandboxed, they can't access either the JSON file or the executable on the host. To resolve that, we need to bypass the sandbox.

# Bypassing the Flatpak Sandbox

First, we need to allow the browser to access the JSON file. The easiest way is to just put the file inside the sandbox rather than allowing the browsers to bypass the sandbox, so that's what this script does in most cases (see Complications for when we don't). This just involves putting a JSON file in `~/.var/app/<browser ID>/config/<browser name>/NativeMessagingHosts` on Chromium and `~/.var/app/<browser ID>/.<browser name>/native-messaging-hosts` on Firefox (though every fork does things differently; see Complications).

Next, we need to allow the browser to run the host command. This has three parts:
1. To allow the app to run commands, we need to grant it permission to talk on the `org.freedesktop.Flatpak` bus using either Flatseal or this command: `flatpak override --user --talk-name=org.freedesktop.Flatpak <browser ID>`
2. Now, it can run terminal commands by prepending `flatpak spawn --host` to them. However, the JSON file that 1Password creates doesn't have that; it just runs `/opt/1Password/1Password-BrowserSupport`. To fix this, we need to create a custom shell script inside the Flatpak sandbox with these contents:
```bash
#!/bin/bash
flatpak-spawn --host /opt/1Password/1Password-BrowserSupport "$@"
```
3. We then need to tell the JSON file to run this script instead of the default 1Password-BrowserSupport binary. To do this, we just replace `/usr/lib/opt/1Password/1Password-BrowserSupport` with `<home directory>/.var/app/<browser ID>/data/bin/1password-wrapper.sh` (or wherever you put the script) in the JSON file.

# Complications

Firefox forks have several different places where the native-messaging-hosts directory needs to be located:
1. In the same directory where browser profiles are stored, such as `~/.var/app/io.gitlab.librewolf-community/.librewolf`
2. In the parent directory to the directory where profiles are stored, such as `~/.var/app/org.mozilla.firefox/.mozilla` (and profiles are stored in `~/.var/app/org.mozilla.firefox/.mozilla/firefox`)
3. In the `~/.mozilla` directory of the host

The first two places are somewhat annoying to find but not too difficult, but the third causes problems. Since it's on the host, the Flatpak doesn't naturally have access to it, so we need to give it permission to access the `~/.mozilla/native-messaging-hosts` directory. Then, since this would also be used by native installations of browsers like Firefox, the script needs to be reconfigured to detect if it's being run from a Flatpak container and choose whether or not to run `flatpak-spawn --host` accordingly. Finally, the JSON file would usually be overwritten by 1Password every time it starts, so we need to mark it as read-only using `chattr +i`.

Another difficulty is finding the directory where the native messaging host JSON should go. Chromium-based browsers put it in `~/.var/app/<browser ID>/config/<browser name>/NativeMessagingHosts` or `~/.var/app/<browser ID>/config/<company name>/<browser name>/NativeMessagingHosts`. Luckily, the NativeMessagingHosts directory is already created, so we just have to run a `find` command to locate it. Firefox-based browsers don't create their `native-messaging-hosts` folder automatically, so we need to locate the `profiles.ini` file and derive the location from there.

Then, on browsers like Floorp and Zen, which require the files be put in `~/.mozilla`, this custom JSON file would interere with the native version of Firefox (or Floorp or Zen) because the browser would be attempting to run `flatpak-spawn --host` without being in a Flatpak, which fails. To get around this, we need a slightly more complex script that runs `flatpak-spawn --host` if it's being run from a Flatpak and just runs the command normally otherwise. However, that normal command is being run by `bash`, not by the browser, which is a security risk, so I'm running it through `exec` instead.

<details>
    <summary>Curious about why it's a security risk?</summary>

1Password only lets certain apps integrate with it, as described below. If this were to run directly through Bash, that would mean that we'd need to allow 1Password to integrate with everything run by Bash, which is a lot. Basically everything running on your system would then have access to your 1Password vault. To get around this, we run `exec /opt/1Password/1Password-BrowserSupport "$@"` instead of just `/opt/1Password/1Password-BrowserSupport "$@"`. The `exec` command basically replaces the Bash shell with whatever command you ran, which means that `1Password-BrowserSupport`'s parent process is now your browser, not Bash.

</details>

# Telling 1Password that it can connect

On Linux, 1Password will only accept integration requests from processes in its internal list or in `/etc/1password/custom_allowed_browsers`. Flatpak browsers are not in the internal list, so we need to manually add them to `custom_allowed_browsers`. Luckily, every command run from a Flatpak is actually run by `flatpak-session-helper`, so just adding that to the list allows every Flatpak to integrate with 1Password. This does make it easier for a malicious Flatpak to integrate with it, however, so be mindful of that.
