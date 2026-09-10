# vim: set ft=make :

# Install and configure Decky Loader from the AeroCore mirror. Options: status | install | install-prerelease | uninstall
[group("gaming")]
setup-decky-mirror ACTION="":
    #!/usr/bin/bash
    set -euo pipefail

    if [[ $(id -u) -eq 0 ]]; then
        echo >&2 "ERROR: Do not run this with sudo"
        exit 1
    fi

    source /usr/lib/ujust/ujust.sh

    if [[ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]]; then
      SUDO_PREFIX=(sudo -A)
      HAS_GRAPHICAL_SESSION=1
    else
      SUDO_PREFIX=(sudo)
      HAS_GRAPHICAL_SESSION=0
    fi

    run_as_root() {
      "${SUDO_PREFIX[@]}" "$@"
    }

    DECKY_MIRROR_HOST="${AEROCORE_DECKY_MIRROR_HOST:-decky.mirror.aerocore.com.cn}"
    DECKY_INSTALLER_BASE="https://${DECKY_MIRROR_HOST}/SteamDeckHomebrew/decky-installer/releases/latest/download"
    DECKY_PLUGIN_MIRROR_HOST="${AEROCORE_DECKY_PLUGIN_MIRROR_HOST:-plugins.decky.mirror.aerocore.com.cn}"
    DECKY_PLUGIN_STORE_URL="https://${DECKY_PLUGIN_MIRROR_HOST}/plugins"

    get_status_token() {
      local decky_service="/etc/systemd/system/plugin_loader.service"
      if [[ ! -f /etc/systemd/system/multi-user.target.wants/plugin_loader.service ]]; then
        echo "uninstall"
      elif [[ -r "$decky_service" ]] && grep -q 'Environment=LOG_LEVEL=DEBUG' "$decky_service"; then
        echo "install-prerelease"
      elif [[ -r "$decky_service" ]]; then
        echo "install"
      else
        return 1
      fi
    }

    DECKY_STATE="${b}${red}Not Installed${n}"
    case "$(get_status_token)" in
      install)
        DECKY_STATE="${b}${green}Installed${n}"
        ;;
      install-prerelease)
        DECKY_STATE="${b}${yellow}Installed (Prerelease)${n}"
        ;;
      uninstall)
        DECKY_STATE="${b}${red}Not Installed${n}"
        ;;
    esac

    setup_home_deck_compat() {
      export HOME
      HOME="$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)"
      if [[ ! -L "/home/deck" && ! -e "/home/deck" && "$HOME" != "/home/deck" ]]; then
        echo "Making a /home/deck symlink to fix plugins that do not use environment variables."
        run_as_root ln -sf "$HOME" /home/deck
      fi
    }

    configure_plugin_store() {
      echo "Configuring Decky plugin store: ${DECKY_PLUGIN_STORE_URL}"
      local settings_file="$HOME/homebrew/settings/loader.json"
      local settings_dir="$(dirname "$settings_file")"
      local temporary_file
      mkdir -p "$settings_dir"
      temporary_file="$(mktemp "${settings_dir}/.loader.XXXXXX")"
      if [[ -f "$settings_file" ]]; then
        jq --arg store_url "$DECKY_PLUGIN_STORE_URL" '.store = 2 | ."store-url" = $store_url' "$settings_file" > "$temporary_file"
      else
        jq -n --arg store_url "$DECKY_PLUGIN_STORE_URL" '{store: 2, "store-url": $store_url}' > "$temporary_file"
      fi
      chmod --reference="$settings_file" "$temporary_file" 2>/dev/null || chmod 0644 "$temporary_file"
      mv -f "$temporary_file" "$settings_file"
    }

    install_release() {
      setup_home_deck_compat
      if [[ "$HAS_GRAPHICAL_SESSION" -eq 1 ]]; then
        curl -L "${DECKY_INSTALLER_BASE}/install_release.sh" |
          sed 's|sudo|sudo -A |g' | sh
      else
        curl -L "${DECKY_INSTALLER_BASE}/install_release.sh" | sh
      fi
      run_as_root chcon -R -t bin_t "$HOME/homebrew/services/PluginLoader"
      run_as_root systemctl stop plugin_loader.service 2>/dev/null || true
      configure_plugin_store
      run_as_root systemctl start plugin_loader.service 2>/dev/null || true
    }

    install_prerelease() {
      setup_home_deck_compat
      if [[ "$HAS_GRAPHICAL_SESSION" -eq 1 ]]; then
        curl -L "${DECKY_INSTALLER_BASE}/install_prerelease.sh" |
          sed 's|sudo|sudo -A |g' | sh
      else
        curl -L "${DECKY_INSTALLER_BASE}/install_prerelease.sh" | sh
      fi
      run_as_root chcon -R -t bin_t "$HOME/homebrew/services/PluginLoader"
      run_as_root systemctl stop plugin_loader.service 2>/dev/null || true
      configure_plugin_store
      run_as_root systemctl start plugin_loader.service 2>/dev/null || true
    }

    uninstall() {
      echo "Uninstalling Decky Loader..."
      if [[ "$HAS_GRAPHICAL_SESSION" -eq 1 ]]; then
        curl -L "${DECKY_INSTALLER_BASE}/uninstall.sh" |
          sed 's|sudo|sudo -A |g' | sh
      else
        curl -L "${DECKY_INSTALLER_BASE}/uninstall.sh" | sh
      fi
      echo "Decky Loader has been uninstalled."
    }

    OPTION="{{ ACTION }}"
    if [[ "$OPTION" == "help" ]]; then
      echo "Usage: ujust setup-decky-mirror <option>"
      echo "  <option>: Specify the quick option to skip the prompt"
      echo "  Use 'status' to print the current portal token"
      echo "  Use 'install' to select Install Decky from the AeroCore mirror"
      echo "  Use 'install-prerelease' to select Install Decky Prerelease from the AeroCore mirror"
      echo "  Use 'uninstall' to uninstall Decky Loader using the AeroCore mirror"
      exit 0
    elif [[ "$OPTION" == "status" ]]; then
      get_status_token
      exit $?
    elif [[ "$OPTION" == "" ]]; then
      if [[ "$HAS_GRAPHICAL_SESSION" -eq 0 ]]; then
        echo "No graphical session detected. Use 'ujust setup-decky-mirror install' from a TTY, or run this command in KDE/Steam Gaming Mode."
        exit 2
      fi
      echo "${bold}Decky Loader setup and configuration${normal}"
      echo "Decky is $DECKY_STATE"
      OPTION="$(ugum choose "Install Decky from AeroCore Mirror" "Install Decky Prerelease from AeroCore Mirror" "Uninstall Decky" "Exit")"
      case "$OPTION" in
        "Install Decky from AeroCore Mirror")
          install_release
          ;;
        "Install Decky Prerelease from AeroCore Mirror")
          install_prerelease
          ;;
        "Uninstall Decky")
          uninstall
          ;;
        *)
          echo "No changes were made."
          ;;
      esac
    elif [[ "$OPTION" == "install" ]]; then
      install_release
      exit 0
    elif [[ "$OPTION" == "install-prerelease" || "$OPTION" == "prerelease" ]]; then
      install_prerelease
      exit 0
    elif [[ "$OPTION" == "uninstall" ]]; then
      uninstall
      exit 0
    fi
