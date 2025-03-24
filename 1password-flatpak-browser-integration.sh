#!/bin/bash
set -oue pipefail

INFO='\033[0;36m'    # Cyan for general information
SUCCESS='\033[0;32m' # Green for success messages
WARN='\033[0;33m'    # Yellow for warnings
ERROR='\033[0;31m'   # Red for errors
NC='\033[0m'         # No Color

echo "This script will help you set up 1Password in a Flatpak browser."
echo -e "${WARN}Note: It will make it possible for any Flatpak application to integrate, not just some. Consider if you find this worth the risk.${NC}"
echo

PACKAGE_LIST=$(flatpak list --app --columns=application)

ALLOWED_EXTENSIONS_FIREFOX='"allowed_extensions": [
        "{0a75d802-9aed-41e7-8daa-24c067386e82}",
        "{25fc87fa-4d31-4fee-b5c1-c32a7844c063}",
        "{d634138d-c276-4fc8-924b-40a0ea21d284}"
    ]'
ALLOWED_EXTENSIONS_CHROMIUM='"allowed_origins": [
        "chrome-extension://hjlinigoblmkhjejkmbegnoaljkphmgo/",
        "chrome-extension://gejiddohjgogedgjnonbofjigllpkmbf/",
        "chrome-extension://khgocmkkpikpnmmkgmdnfckapcdkgfaf/",
        "chrome-extension://aeblfdkhhhdcdjpifhhbdiojplfjncoa/",
        "chrome-extension://dppgmdbiimibapkepcbdbmkaabgiofem/"
    ]'

is_firefox_dir() {
    local dir="$1"

    # Skip if not a directory or if it's . or .. or .cache
    if [[ ! -d "$dir" ]] || [[ "$(basename "$dir")" = "." ]] || [[ "$(basename "$dir")" = ".." ]] || [[ "$(basename "$dir")" = "cache" ]] || [[ "$(basename "$dir")" = ".cache" ]]; then
        return 1
    elif [[ -f "$dir/profiles.ini" ]]; then
        return 0
    else
        return 1
    fi
}

list_flatpak_browsers() {
    BROWSER_ID_LIST=("$@")

    for BROWSER_ID in "${BROWSER_ID_LIST[@]}"; do
        if echo "$PACKAGE_LIST" | grep -q "$BROWSER_ID"; then
            MATCHING_BROWSERS=$(echo "$PACKAGE_LIST" | grep "$BROWSER_ID")
            while IFS= read -r BROWSER || [[ -n $BROWSER ]]; do
                echo -e "${INFO} - $BROWSER${NC}"
            done < <(printf '%s' "$MATCHING_BROWSERS") # https://superuser.com/questions/284187/how-to-iterate-over-lines-in-a-variable-in-bash
        fi
    done
}

get_native_messaging_hosts_json() {
    local WRAPPER_PATH="$1"
    local ALLOWED_EXTENSIONS="$2"

    cat <<EOF
{
    "name": "com.1password.1password",
    "description": "1Password BrowserSupport",
    "path": "$WRAPPER_PATH",
    "type": "stdio",
    $ALLOWED_EXTENSIONS
}
EOF
}

# Getting what browser to install for
echo -e "${INFO}Detected Chromium-based browsers (incomplete list):${NC}"
CHROMIUM_BROWSER_ID_LIST=("com.google.Chrome" "com.brave.Browser" "com.vivaldi.Vivaldi" "com.opera.Opera" "com.microsoft.Edge" "ru.yandex.Browser" "org.chromium.Chromium" "io.github.ungoogled_software.ungoogled_chromium")
list_flatpak_browsers "${CHROMIUM_BROWSER_ID_LIST[@]}"

echo -e "${INFO}Detected Firefox-based browsers (incomplete list):${NC}"
FIREFOX_BROWSER_ID_LIST=("org.mozilla.firefox" "one.ablaze.floorp" "io.gitlab.librewolf-community" "org.torproject.torbrowser-launcher" "app.zen_browser.zen" "org.garudalinux.firedragon" "net.mullvad.MullvadBrowser" "net.waterfox.waterfox")
list_flatpak_browsers "${FIREFOX_BROWSER_ID_LIST[@]}"

echo

echo -n "Enter the name of your browser's Flatpak application ID (e.g. com.google.Chrome): "
read -r FLATPAK_ID
if ! echo "$PACKAGE_LIST" | grep -q "$FLATPAK_ID"; then
    echo -e "${ERROR}ERROR: Could not find the specified browser${NC}"
    exit 1
fi
if [[ " ${FIREFOX_BROWSER_ID_LIST[*]} " =~ [[:space:]]${FLATPAK_ID}[[:space:]] ]]; then
    BROWSER_TYPE="firefox"
elif [[ " ${CHROMIUM_BROWSER_ID_LIST[*]} " =~ [[:space:]]${FLATPAK_ID}[[:space:]] ]]; then
    BROWSER_TYPE="chromium"
else
    echo "Could not determine browser type. Is your browser based on Chromium or Firefox?"
    echo -n "Enter 'chromium' or 'firefox': "
    read -r BROWSER_TYPE
fi
if [[ "$BROWSER_TYPE" != "chromium" ]] && [[ "$BROWSER_TYPE" != "firefox" ]]; then
    echo -e "${ERROR}ERROR: Invalid browser type \"$BROWSER_TYPE\"; expected either chromium or firefox${NC}"
    exit 1
fi

echo

# Giving the browser permission to bypass the sandbox
echo -e "${INFO}Giving your browser permission to run programs outside the sandbox${NC}"
flatpak override --user --talk-name=org.freedesktop.Flatpak "$FLATPAK_ID"

# Creating a wrapper script for 1Password in the browser's directory
echo -e "${INFO}Creating a wrapper script for 1Password${NC}"
mkdir -p "$HOME/.var/app/$FLATPAK_ID/data/bin"
cat <<EOF >"$HOME/.var/app/$FLATPAK_ID/data/bin/1password-wrapper.sh"
#!/bin/bash
if [ "\${container-}" = flatpak ]; then
    flatpak-spawn --host /opt/1Password/1Password-BrowserSupport "\$@"
else
    exec /opt/1Password/1Password-BrowserSupport "\$@"
fi
EOF
chmod +x "$HOME/.var/app/$FLATPAK_ID/data/bin/1password-wrapper.sh"

# Creating a Native Messaging Hosts file
echo -e "${INFO}Creating a Native Messaging Hosts file for the 1Password extension to tell the browser to use the wrapper script${NC}"

# Find the Native Messaging Hosts directory
if [[ "$BROWSER_TYPE" = "chromium" ]]; then
    NATIVE_MESSAGING_HOSTS_DIR=$(find "$HOME/.var/app/$FLATPAK_ID/config" -maxdepth 3 -type d -name "NativeMessagingHosts" 2>/dev/null)
elif [[ "$BROWSER_TYPE" = "firefox" ]]; then
    shopt -s dotglob
    for dir in "$HOME/.var/app/$FLATPAK_ID"/*; do
        if is_firefox_dir "$dir"; then
            NATIVE_MESSAGING_HOSTS_DIR="$dir"/native-messaging-hosts
            break
        fi

        for subdir in "$dir"/*; do
            if is_firefox_dir "$subdir"; then
                # Firefox, for example, puts profiles in .mozilla/firefox, but it puts native-messaging-hosts in .mozilla.
                NATIVE_MESSAGING_HOSTS_DIR="$dir"/native-messaging-hosts
                break
            fi
        done
    done
fi

if [[ ! -v NATIVE_MESSAGING_HOSTS_DIR ]] || [[ -z "$NATIVE_MESSAGING_HOSTS_DIR" ]]; then
    echo -e "${ERROR}ERROR: Could not find Native Messaging Hosts directory${NC}"
    exit 1
fi

add_native_messaging_host() {
    local WRAPPER_PATH="$1"
    local ALLOWED_EXTENSIONS="$2"
    local NATIVE_MESSAGING_HOSTS_DIR="$3"

    # Create the file
    if [[ ! -d $NATIVE_MESSAGING_HOSTS_DIR ]]; then
        echo -e "${INFO}Creating Native Messaging Hosts directory at $NATIVE_MESSAGING_HOSTS_DIR${NC}"
        mkdir -p "$NATIVE_MESSAGING_HOSTS_DIR"
    fi

    get_native_messaging_hosts_json "$WRAPPER_PATH" "$ALLOWED_EXTENSIONS" > "$NATIVE_MESSAGING_HOSTS_DIR/com.1password.1password.json"
}

is_native_messaging_host_correct() {
    local WRAPPER_PATH="$1"
    local ALLOWED_EXTENSIONS="$2"
    local NATIVE_MESSAGING_HOSTS_DIR="$3"
    local SHOULD_BE_IMMUTABLE="$4"

    FILE_CONTENTS=$(cat "$NATIVE_MESSAGING_HOSTS_DIR/com.1password.1password.json")
    CORRECT_CONTENTS=$(get_native_messaging_hosts_json "$WRAPPER_PATH" "$ALLOWED_EXTENSIONS")

    # check if the files exist
    if [[ ! -f "$NATIVE_MESSAGING_HOSTS_DIR/com.1password.1password.json" ]] || [[ ! -f "$WRAPPER_PATH" ]]; then
        return 1
    # if it is supposed to be immutable, check if it is immutable
    elif [[ -n "$SHOULD_BE_IMMUTABLE" ]] && [[ "$SHOULD_BE_IMMUTABLE" = "true" ]]; then
        # check if the file is immutable
        if [[ "$(lsattr "$NATIVE_MESSAGING_HOSTS_DIR/com.1password.1password.json" | cut -c 5)" != "i" ]]; then
            return 1
        fi
    # check if it has the correct contents
    elif [[ "$FILE_CONTENTS" != "$CORRECT_CONTENTS" ]]; then
        return 1
    fi

    return 0
}

WRAPPER_PATH="$HOME/.var/app/$FLATPAK_ID/data/bin/1password-wrapper.sh"
if [[ "$BROWSER_TYPE" = "chromium" ]]; then
    add_native_messaging_host "$WRAPPER_PATH" "$ALLOWED_EXTENSIONS_CHROMIUM" "$NATIVE_MESSAGING_HOSTS_DIR"
elif [[ "$BROWSER_TYPE" = "firefox" ]]; then
    add_native_messaging_host "$WRAPPER_PATH" "$ALLOWED_EXTENSIONS_FIREFOX" "$NATIVE_MESSAGING_HOSTS_DIR"
    BROWSERS_NOT_USING_MOZILLA=("org.mozilla.firefox" "io.gitlab.librewolf-community" "net.waterfox.waterfox")
    GLOBAL_WRAPPER_PATH="$HOME/.mozilla/native-messaging-hosts/1password-wrapper.sh"
    GLOBAL_NATIVE_MESSAGING_HOSTS_DIR="$HOME/.mozilla/native-messaging-hosts"
    if [[ " ${BROWSERS_NOT_USING_MOZILLA[*]} " =~ [[:space:]]${FLATPAK_ID}[[:space:]] ]]; then
        echo -e "${INFO}Skipping adding to $HOME/.mozilla/native-messaging-hosts/com.1password.1password.json${NC}"
    # if the file doesn't exist or the contents are wrong, then ask if it should be created
    elif ! is_native_messaging_host_correct "$GLOBAL_WRAPPER_PATH" "$ALLOWED_EXTENSIONS_FIREFOX" "$GLOBAL_NATIVE_MESSAGING_HOSTS_DIR" "true"; then
        echo "Some browsers, like Floorp and Zen, need the file in ~/.mozilla instead of in their own sandbox. This requires replacing the existing file $HOME/.mozilla/native-messaging-hosts/com.1password.1password.json with a custom one. Then, to prevent 1Password overwriting it, the file needs to be marked as read-only using chattr +i on it."
        echo -n "Do you want to continue? This will require sudo privileges. (Y/n) "
        read -r CONTINUE
        if [[ "$CONTINUE" = "N" ]] || [[ "$CONTINUE" = "n" ]]; then
            echo -e "${INFO}Skipping${NC}"
        else
            cp "$HOME/.var/app/$FLATPAK_ID/data/bin/1password-wrapper.sh" "$GLOBAL_WRAPPER_PATH"
            flatpak override --user --filesystem="$GLOBAL_NATIVE_MESSAGING_HOSTS_DIR" "$FLATPAK_ID"

            sudo chattr -i "$GLOBAL_NATIVE_MESSAGING_HOSTS_DIR/com.1password.1password.json" # Remove read-only flag if it exists
            add_native_messaging_host "$GLOBAL_WRAPPER_PATH" "$ALLOWED_EXTENSIONS_FIREFOX" "$GLOBAL_NATIVE_MESSAGING_HOSTS_DIR"

            echo -e "${INFO}Marking $GLOBAL_NATIVE_MESSAGING_HOSTS_DIR/com.1password.1password.json as read-only using chattr +i. To undo, run this command:${NC}"
            echo -e "${INFO}sudo chattr -i $GLOBAL_NATIVE_MESSAGING_HOSTS_DIR/com.1password.1password.json${NC}"
            sudo chattr +i "$GLOBAL_NATIVE_MESSAGING_HOSTS_DIR/com.1password.1password.json" # Prevent 1Password from overwriting the file
        fi
    else
        echo -e "${INFO}Already added to $GLOBAL_NATIVE_MESSAGING_HOSTS_DIR/com.1password.1password.json${NC}"
    fi
fi

echo

# Add flatpak-session-helper to custom_allowed_browsers list (needs root)
echo -e "${INFO}Adding Flatpaks to the list of supported browsers in 1Password${NC}"
echo "Note: This requires sudo permissions. If this doesn't work, append flatpak-session-helper to the file /etc/1password/custom_allowed_browsers"
if [[ ! -d /etc/1password ]]; then
    echo -e "${INFO}Creating directory /etc/1password${NC}"
    sudo mkdir /etc/1password
fi
if grep -q 'flatpak-session-helper' /etc/1password/custom_allowed_browsers; then
    echo -e "${INFO}Already added to allowed browsers${NC}"
else
    echo -e "${INFO}Adding to allowed browsers${NC}"
    echo -e 'flatpak-session-helper' | sudo tee -a /etc/1password/custom_allowed_browsers >/dev/null
fi

# Done
if grep -q 'flatpak-session-helper' /etc/1password/custom_allowed_browsers; then
    echo -e "${SUCCESS}Success! 1Password should now work in your Flatpak browser.${NC}"
    echo "Now, restart both your browser and 1Password."
else
    echo -e "${ERROR}ERROR: Could not add to allowed browsers${NC}"
    exit 1
fi
