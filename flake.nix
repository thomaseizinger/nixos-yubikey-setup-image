{
  description = "A Nix Flake for a GNOME-based system with YubiKey setup";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-23.11";
    drduhYubiKeyGuide.url = "github:drduh/YubiKey-Guide";
    drduhYubiKeyGuide.flake = false;
    drduhConfig.url = "github:drduh/config";
    drduhConfig.flake = false;
  };

  outputs = { self, nixpkgs, drduhYubiKeyGuide, drduhConfig, ... }:
    {
      nixosConfigurations.yubikeyLive = nixpkgs.lib.nixosSystem {
        system = "x86_64-linux";
        modules = [
          "${nixpkgs}/nixos/modules/profiles/all-hardware.nix"
          "${nixpkgs}/nixos/modules/installer/cd-dvd/iso-image.nix"
          ({ pkgs, lib, config, ... }:
            let
              src = drduhYubiKeyGuide;
              guide = "${src}/README.md";
              contrib = "${src}/contrib";
              gpgConf = "${drduhConfig}/gpg.conf";
              gpgAgentConf = pkgs.runCommand "gpg-agent.conf" { } ''
                sed '/pinentry-program/d' ${drduhConfig}/gpg-agent.conf > $out
                echo "pinentry-program ${pkgs.pinentry.gnome3}/bin/pinentry" >> $out
              '';
              viewYubikeyGuide = pkgs.writeShellScriptBin "view-yubikey-guide" ''
                viewer="$(type -P xdg-open || true)"
                if [ -z "$viewer" ]; then
                  viewer="${pkgs.glow}/bin/glow -p"
                fi
                exec $viewer "${guide}"
              '';
              shortcut = pkgs.makeDesktopItem {
                name = "yubikey-guide";
                icon = "${pkgs.yubikey-manager-qt}/share/ykman-gui/icons/ykman.png";
                desktopName = "drduh's YubiKey Guide";
                genericName = "Guide to using YubiKey for GPG and SSH";
                comment = "Open the guide in a reader program";
                categories = [ "Documentation" ];
                exec = "${viewYubikeyGuide}/bin/view-yubikey-guide";
              };
              yubikeyGuide = pkgs.symlinkJoin {
                name = "yubikey-guide";
                paths = [ viewYubikeyGuide shortcut ];
              };
            in
            {
              nixpkgs.overlays = [
                # waiting for https://github.com/NixOS/nixpkgs/pull/275209
                # to be merged & backported to 23.11
                (final: prev: {
                  haskellPackages = prev.haskellPackages.override {
                    overrides = hsFinal: hsPrev:
                      let
                        hopenpgp-tools =
                          (final.haskell.lib.overrideCabal hsPrev.hopenpgp-tools
                            (oldAttrs: {
                              broken = false;
                            })).override {
                              optparse-applicative = hsPrev.optparse-applicative_0_18_1_0;
                            };
                      in
                      { inherit hopenpgp-tools; };
                  };
                })
              ];

              isoImage.isoName = "yubikeyLive.iso";
              isoImage.makeEfiBootable = true; # EFI booting
              isoImage.makeUsbBootable = true; # USB booting

              swapDevices = [ ];

              # Always copytoram so that, if the image is booted from, e.g., a
              # USB stick, nothing is mistakenly written to persistent storage.
              boot.kernelParams = [ "copytoram" ];
              # Secure defaults
              boot.tmp.cleanOnBoot = true;
              boot.kernel.sysctl = { "kernel.unprivileged_bpf_disabled" = 1; };

              services.xserver.enable = true;
              services.xserver.desktopManager.gnome.enable = true;
              services.xserver.displayManager = {
                gdm.enable = true;
                autoLogin = {
                  enable = true;
                  user = "nixos";
                };
              };
              services.pcscd.enable = true;
              services.udev.packages = [ pkgs.yubikey-personalization ];

              programs = {
                ssh.startAgent = false;
                gnupg.agent = {
                  enable = true;
                  enableSSHSupport = true;
                };
              };

              # Use less privileged nixos user
              users.users.nixos = {
                isNormalUser = true;
                extraGroups = [ "wheel" "networkmanager" "video" ];
                initialHashedPassword = ""; # Allow the graphical user to login without password
              };
              users.users.root.initialHashedPassword = ""; # Allow the user to log in as root without a password.

              security.sudo = {
                enable = true;
                wheelNeedsPassword = false;
              };

              services.getty.autologinUser = "nixos"; # Automatically log in at the virtual consoles.

              environment.systemPackages = with pkgs; [
                # Tools for backing up keys
                paperkey
                pgpdump
                parted
                cryptsetup

                # Yubico's official tools
                yubikey-manager
                yubikey-manager-qt
                yubikey-personalization
                yubikey-personalization-gui
                yubico-piv-tool
                yubioath-flutter

                # Testing
                ent
                (haskell.lib.justStaticExecutables haskellPackages.hopenpgp-tools)

                # Password generation tools
                diceware
                pwgen

                # Miscellaneous tools that might be useful beyond the scope of the guide
                cfssl
                pcsctools

                # This guide itself (run `view-yubikey-guide` on the terminal to open it
                # in a non-graphical environment).
                yubikeyGuide
              ];

              # Disable networking so the system is air-gapped
              # Comment all of these lines out if you'll need internet access
              boot.initrd.network.enable = false;
              networking.dhcpcd.enable = false;
              networking.dhcpcd.allowInterfaces = [ ];
              networking.interfaces = { };
              networking.firewall.enable = true;
              networking.useDHCP = false;
              networking.useNetworkd = false;
              networking.wireless.enable = false;
              networking.networkmanager.enable = lib.mkForce false;

              # Unset history so it's never stored
              # Set GNUPGHOME to an ephemeral location and configure GPG with the
              # guide's recommended settings.
              environment.interactiveShellInit = ''
                unset HISTFILE
                export GNUPGHOME="/run/user/$(id -u)/gnupg"
                if [ ! -d "$GNUPGHOME" ]; then
                  echo "Creating \$GNUPGHOME…"
                  install --verbose -m=0700 --directory="$GNUPGHOME"
                fi
                [ ! -f "$GNUPGHOME/gpg.conf" ] && cp --verbose ${gpgConf} "$GNUPGHOME/gpg.conf"
                [ ! -f "$GNUPGHOME/gpg-agent.conf" ] && cp --verbose ${gpgAgentConf} "$GNUPGHOME/gpg-agent.conf"
                echo "\$GNUPGHOME is \"$GNUPGHOME\""
              '';

              # Copy the contents of contrib to the home directory, add a shortcut to
              # the guide on the desktop, and link to the whole repo in the documents
              # folder.
              system.activationScripts.yubikeyGuide =
                let
                  homeDir = "/home/nixos/";
                  desktopDir = homeDir + "Desktop/";
                  documentsDir = homeDir + "Documents/";
                in
                ''
                  mkdir -p ${desktopDir} ${documentsDir}
                  chown nixos ${homeDir} ${desktopDir} ${documentsDir}

                  cp -R ${contrib}/* ${homeDir}
                  ln -sf ${yubikeyGuide}/share/applications/yubikey-guide.desktop ${desktopDir}
                  ln -sfT ${src} ${documentsDir}/YubiKey-Guide
                '';
              system.stateVersion = "23.11";
            })
        ];
      };
    };
}
