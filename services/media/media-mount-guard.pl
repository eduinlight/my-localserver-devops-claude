#!/usr/bin/perl
# pre-start guard for LXC 104 (media).
#
# /mnt/media/data inside the container is a bind mount of /mnt/media-8tb on the
# host. The fstab entry is nofail and pve-guests.service has no local-fs
# ordering, so without this guard a boot that races the disk would bind-mount an
# EMPTY directory. Sonarr/Radarr would then scan an empty library and mark the
# whole collection as missing. Refusing to start is far cheaper to recover from.
use strict;
use warnings;

my ($vmid, $phase) = @ARGV;
$phase = '' unless defined $phase;
exit 0 unless $phase eq 'pre-start';

my $mnt = '/mnt/media-8tb';

if (system('/usr/bin/mountpoint', '-q', $mnt) != 0) {
    die "media-mount-guard: $mnt is NOT mounted - refusing to start CT $vmid.\n"
      . "  The media library lives there; starting without it would show the\n"
      . "  arr apps an empty library. Fix with: mount $mnt\n";
}

opendir(my $dh, $mnt) or die "media-mount-guard: cannot read $mnt: $!\n";
my @entries = grep { $_ ne '.' && $_ ne '..' && $_ ne 'lost+found' } readdir($dh);
closedir($dh);

unless (@entries) {
    die "media-mount-guard: $mnt is mounted but EMPTY - refusing to start CT $vmid.\n";
}

print "media-mount-guard: $mnt OK (" . scalar(@entries) . " entries)\n";
exit 0;
