    use strict;
    use warnings;
    use autodie;

    use Data::Dumper;

    use lib 'lib';
    use XUtil 'fasync';

    use Fcntl ':flock';
    flock(DATA, LOCK_EX|LOCK_NB) or die "$0 already running!\n";

    STDOUT->autoflush();
    STDERR->autoflush();

    # use Mojo::Base -strict;
    use Mojo::Redis2;
    #  use JSON::XS; # imports encode_json, decode_json

    my $cfg = do "server.conf";

    sub connectRedis {
        return Mojo::Redis2
            ->new(url => $cfg->{"Mojo::Redis2"})
            ->protocol_class("Protocol::Redis::XS")
        ;
    }
    
    # use File::Basename;
    $0 = "nodeWatcher"; nodeWatcher();
    # my $file = dirname(__FILE__) ."/". __FILE__;
    # exec "perl", $file; exit;

    # END
    # --------
    
sub nodeWatcher {
    my $redis;
    my @queue;
    my (%seenh, @seena);


    open my $log, ">", "$ENV{HOME}/.bitcoin/debug.log";
    my $pid = open my $fh, "-|", qw(
        ./bitcoind -minrelaytxfee=0.00000001 -debug=mempool -debug=mempoolrej -debug=zmq -printtoconsole -logips
        -maxconnections=3000 -prune=4000 -server -zmqpubhashtx=tcp://127.0.0.1:28332 -zmqpubhashblock=tcp://127.0.0.1:28332
    );
    $log->autoflush();

    while (my $line = <$fh>) {
        $redis ||= connectRedis();
        
        my @r = $line =~ /(accepted|hashtx|hashblock) \s+ (\w{64})/x;
        if (!@r) {
            print $log $line;
            next;
        }

        push @queue, \@r;
        #
        while (@queue) {
            my $v = shift @queue;
            
            my ($list, $val) = @$v;
            if ($list ne "hashblock") {
                $list = "hashtx";
                my $isSeen = $seenh{$val}++ or push @seena, $val;
                delete $seenh{ shift(@seena) } if @seena >50_000;
                next if $isSeen;
            }

            my $ok = eval {
                $redis->lpush("in:$list", $val);
                $redis->ltrim("in:$list", 0, 50_000);
                1;
            };
            if (!$ok) {
                warn "redis lpush failed\n";
                unshift @queue, $v;
                $redis = undef;
                # sleep 1;
                last;
            }
        }
    }
}

__DATA__
44
