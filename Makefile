DESTDIR =

PLUGINDIR  = $(DESTDIR)/usr/share/perl5/PVE/Storage/Custom
SHAREDIR   = $(DESTDIR)/usr/share/pve-bcachefs
STATEDIR   = $(DESTDIR)/var/lib/pve-bcachefs

.PHONY: install
install:
	install -D -m 0644 src/PVE/Storage/Custom/BcachefsPlugin.pm $(PLUGINDIR)/BcachefsPlugin.pm
	install -D -m 0755 patches/patch-pve-container.pl $(SHAREDIR)/patch-pve-container.pl
	install -d -m 0755 $(STATEDIR)

.PHONY: deb
deb:
	dpkg-buildpackage -b -us -uc
	lintian ../pve-bcachefs_*_all.deb || true

.PHONY: clean
clean:
	rm -f ../pve-bcachefs_*.deb ../pve-bcachefs_*.buildinfo ../pve-bcachefs_*.changes
	rm -rf debian/pve-bcachefs debian/.debhelper debian/files debian/debhelper-build-stamp
