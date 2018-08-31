use lib "lib";
use BitcoinCash;

#my $xpub = "xpub661MyMwAqRbcGC3A7zLijb5Vu1rGKVfLUD5217Z4meVmqvLTun5d7EpaVaqVE985tfbYHf2z497A3z4ZU5NjFKM7A83J7Mwtor3GgAQiq4m";
my $xpub = "xpub661MyMwAqRbcFdwc4qdfqUZKc7GELH7BA29CNWFzVpyFY5FnYWuSAJSdmXxybezU47kHsbVMgBwRQkynzKYHJ2R6vGnkKN4pcJas5c3n2WW";
eval {
    print BitcoinCash::getaddress($xpub, $_, old=>1), " $_\n" for 0 .. 10;
    1;
}
or print "Cought => $@";
