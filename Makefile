include $(TOPDIR)/rules.mk

PKG_NAME:=norypt-ghost
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_MAINTAINER:=Norypt Team
PKG_LICENSE:=GPL-2.0-only

include $(INCLUDE_DIR)/package.mk

define Package/norypt-ghost
	SECTION:=utils
	CATEGORY:=Utilities
	EXTRA_DEPENDS:=luci-base, lua, luabitop
	TITLE:=Anonymity Enhancements for GL-iNet GL-E5800 Mudi 7
endef

define Package/norypt-ghost/description
	norypt-ghost enhances anonymity and reduces forensic traceability of the
	GL-iNet GL-E5800 (Mudi 7) 5G mobile Wi-Fi router by randomizing IMEI,
	MAC addresses, SSID, hostname, and Wi-Fi password on every boot or on demand.
endef

# Local source package — no PKG_SOURCE tarball, so stage src/ into the
# build dir ourselves before compiling the touchscreen daemon.
define Build/Prepare
	mkdir -p $(PKG_BUILD_DIR)
	$(CP) ./src/* $(PKG_BUILD_DIR)/
endef

define Build/Configure
endef

# Compile the norypt-ghost-touch evdev daemon for the target arch (statically
# linked, matching the prebuilt binary build-ipk.sh bundles). The daemon is
# multi-file: the state machine plus the fb/menu/screens/imei/fbdev modules.
# Keep this source list in sync with tools/build-touch.sh and sdk-build.yml.
define Build/Compile
	$(TARGET_CC) $(TARGET_CFLAGS) $(TARGET_LDFLAGS) -O2 -static \
		-I $(PKG_BUILD_DIR) \
		-o $(PKG_BUILD_DIR)/norypt-ghost-touch \
		$(PKG_BUILD_DIR)/norypt-ghost-touch.c \
		$(PKG_BUILD_DIR)/fb.c \
		$(PKG_BUILD_DIR)/menu.c \
		$(PKG_BUILD_DIR)/screens.c \
		$(PKG_BUILD_DIR)/imei.c \
		$(PKG_BUILD_DIR)/fbdev.c
endef

define Package/norypt-ghost/install
	$(INSTALL_DIR) $(1)/lib/norypt-ghost
	$(INSTALL_DATA) ./files/lib/norypt-ghost/functions.sh        $(1)/lib/norypt-ghost/functions.sh
	$(INSTALL_DATA) ./files/lib/norypt-ghost/imei_generate.lua   $(1)/lib/norypt-ghost/imei_generate.lua
	$(INSTALL_DATA) ./files/lib/norypt-ghost/luhn.lua            $(1)/lib/norypt-ghost/luhn.lua
	$(INSTALL_DATA) ./files/lib/norypt-ghost/profile.sh          $(1)/lib/norypt-ghost/profile.sh
	$(INSTALL_DATA) ./files/lib/norypt-ghost/identity.sh         $(1)/lib/norypt-ghost/identity.sh
	$(INSTALL_DATA) ./files/lib/norypt-ghost/clean.sh            $(1)/lib/norypt-ghost/clean.sh

	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/norypt-ghost                  $(1)/usr/bin/norypt-ghost
	$(INSTALL_BIN) $(PKG_BUILD_DIR)/norypt-ghost-touch           $(1)/usr/bin/norypt-ghost-touch

	$(INSTALL_DIR) $(1)/usr/libexec
	$(INSTALL_BIN) ./files/usr/libexec/norypt-ghost              $(1)/usr/libexec/norypt-ghost

	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/norypt-ghost-wireless      $(1)/etc/init.d/norypt-ghost-wireless
	$(INSTALL_BIN) ./files/etc/init.d/norypt-ghost-sim-swap      $(1)/etc/init.d/norypt-ghost-sim-swap
	$(INSTALL_BIN) ./files/etc/init.d/norypt-ghost-clean      $(1)/etc/init.d/norypt-ghost-clean
	$(INSTALL_BIN) ./files/etc/init.d/norypt-ghost-touch         $(1)/etc/init.d/norypt-ghost-touch
	$(INSTALL_BIN) ./files/etc/init.d/norypt-ghost-ttl           $(1)/etc/init.d/norypt-ghost-ttl

	$(INSTALL_DIR) $(1)/usr/share/norypt-ghost
	$(INSTALL_DATA) ./files/usr/share/norypt-ghost/tac_pool.json $(1)/usr/share/norypt-ghost/tac_pool.json
	$(INSTALL_DATA) ./files/usr/share/norypt-ghost/oui_pool.json $(1)/usr/share/norypt-ghost/oui_pool.json
	$(INSTALL_DATA) ./files/usr/share/norypt-ghost/profiles.json $(1)/usr/share/norypt-ghost/profiles.json

	$(INSTALL_DIR) $(1)/usr/share/norypt-ghost/screens
	$(INSTALL_DATA) ./files/usr/share/norypt-ghost/screens/*.rgb565 $(1)/usr/share/norypt-ghost/screens/

	$(INSTALL_DIR) $(1)/usr/share/luci/menu.d
	$(INSTALL_DATA) ./files/usr/share/luci/menu.d/luci-app-norypt-ghost.json \
		$(1)/usr/share/luci/menu.d/luci-app-norypt-ghost.json

	$(INSTALL_DIR) $(1)/usr/share/rpcd/acl.d
	$(INSTALL_DATA) ./files/usr/share/rpcd/acl.d/luci-app-norypt-ghost.json \
		$(1)/usr/share/rpcd/acl.d/luci-app-norypt-ghost.json

	$(INSTALL_DIR) $(1)/www/luci-static/resources/view
	$(INSTALL_DATA) ./files/www/luci-static/resources/view/norypt_ghost.js \
		$(1)/www/luci-static/resources/view/norypt_ghost.js
endef

define Package/norypt-ghost/preinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0

_require_tty() {
	if [ ! -t 0 ]; then
		echo "Non-interactive install — cannot confirm. Re-run 'opkg install' from an SSH shell."
		exit 1
	fi
}

_abort_model() {
	echo ""
	echo "Norypt Ghost is designed for the GL-iNet GL-E5800 (Mudi 7)."
	if [ -f /tmp/sysinfo/model ]; then
		echo "Detected device: $$(cat /tmp/sysinfo/model)"
	fi
	_require_tty
	printf "Continue installation on unsupported device? (y/N): "
	read -r answer
	case "$$answer" in
		[yY]*) ;;
		*) exit 1 ;;
	esac
}

_abort_version() {
	echo ""
	echo "Norypt Ghost has been tested on GL-E5800 firmware 4.8.3 and 4.8.5 only."
	if [ -f /etc/glversion ]; then
		echo "Detected firmware: $$(cat /etc/glversion)"
	fi
	echo "Newer firmware versions may have changed the AT interface or UCI layout."
	_require_tty
	printf "Continue installation on untested firmware? (y/N): "
	read -r answer
	case "$$answer" in
		[yY]*) ;;
		*) exit 1 ;;
	esac
}

# Device model check
if ! grep -qi "E5800" /tmp/sysinfo/model 2>/dev/null; then
	_abort_model
fi

# Firmware version check
if [ -f /etc/glversion ]; then
	GL_VERSION="$$(cat /etc/glversion)"
	case "$$GL_VERSION" in
		4.8.3|4.8.5)
			echo "Firmware $$GL_VERSION confirmed supported."
			;;
		4.8.*)
			echo "Firmware $$GL_VERSION is newer than tested — probably compatible."
			_abort_version
			;;
		4.*)
			echo "Firmware $$GL_VERSION has not been tested with Norypt Ghost."
			_abort_version
			;;
		*)
			echo "Unrecognised firmware version: $$GL_VERSION"
			_abort_version
			;;
	esac
fi

# Stop gl_clients before norypt-ghost-clean mounts tmpfs over its database directory.
[ -x /etc/init.d/gl_clients ] && /etc/init.d/gl_clients stop 2>/dev/null

exit 0
endef

define Package/norypt-ghost/postinst
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0

# Disable GL-iNet's BSSID randomization — norypt-ghost owns MAC rotation.
for _radio in wifi0 wifi1 wifi2; do
	uci -q set "wireless.$${_radio}.random_bssid=0" 2>/dev/null
done
uci -q commit wireless

# Enable all norypt-ghost init.d services.
/etc/init.d/norypt-ghost-clean enable
/etc/init.d/norypt-ghost-wireless enable
/etc/init.d/norypt-ghost-sim-swap enable
/etc/init.d/norypt-ghost-ttl enable

# Touchscreen trigger: respect a preference saved by a previous install
# (LuCI toggle persists it to UCI); default to enabled on fresh installs.
if [ "$$(uci -q get norypt-ghost.options.touch_enabled 2>/dev/null)" != "0" ]; then
	/etc/init.d/norypt-ghost-touch enable
	/etc/init.d/norypt-ghost-touch start
fi

# Start norypt-ghost-clean immediately so the client database moves to RAM.
/etc/init.d/norypt-ghost-clean start
/etc/init.d/norypt-ghost-ttl start

# Restart gl_clients against the now-tmpfs-backed database directory.
[ -x /etc/init.d/gl_clients ] && /etc/init.d/gl_clients start 2>/dev/null

# Setup only — no-retention model, no factory capture.
/usr/bin/norypt-ghost install

echo "norypt-ghost: installation complete. Rotate identity via: norypt-ghost rotate"
exit 0
endef

define Package/norypt-ghost/prerm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0

# Stop AND disable while the init scripts still exist — opkg deletes
# package files before postrm runs, so doing either there is a no-op.
/etc/init.d/norypt-ghost-touch stop 2>/dev/null
/etc/init.d/norypt-ghost-wireless stop 2>/dev/null
/etc/init.d/norypt-ghost-sim-swap stop 2>/dev/null
/etc/init.d/norypt-ghost-clean stop 2>/dev/null
/etc/init.d/norypt-ghost-ttl stop 2>/dev/null

/etc/init.d/norypt-ghost-touch disable 2>/dev/null
/etc/init.d/norypt-ghost-wireless disable 2>/dev/null
/etc/init.d/norypt-ghost-sim-swap disable 2>/dev/null
/etc/init.d/norypt-ghost-clean disable 2>/dev/null
/etc/init.d/norypt-ghost-ttl disable 2>/dev/null

echo "norypt-ghost: removed — device keeps its current identity (no-retention model)."
exit 0
endef

define Package/norypt-ghost/postrm
#!/bin/sh
[ -n "$${IPKG_INSTROOT}" ] && exit 0

# Re-enable GL-iNet's BSSID randomization now that norypt-ghost is removed.
for _radio in wifi0 wifi1 wifi2; do
	uci -q set "wireless.$${_radio}.random_bssid=1" 2>/dev/null
done
uci -q commit wireless

# Services were stopped/disabled in prerm (scripts are deleted by now);
# sweep any rc.d symlinks left behind so nothing dangles.
rm -f /etc/rc.d/S*norypt-ghost* /etc/rc.d/K*norypt-ghost*

# Clean up runtime state files.
rm -f /etc/norypt-ghost.last_imei_rotate \
      /etc/norypt-ghost.last_wireless_rotate \
      /etc/norypt-ghost.sim-swap-pending

echo "norypt-ghost: uninstalled."
exit 0
endef

$(eval $(call BuildPackage,norypt-ghost))
