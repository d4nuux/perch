# Hosts MediaRemoteHelper.dylib inside Apple's perl, which is allowed to read Now Playing.
use strict;
use DynaLoader;
my $lib = DynaLoader::dl_load_file($ARGV[0], 0) or die DynaLoader::dl_error();
my $sym = DynaLoader::dl_find_symbol($lib, "notchapp_media_stream") or die DynaLoader::dl_error();
DynaLoader::dl_install_xsub("main::stream", $sym);
stream();
