    use strict;
    use warnings;
    use Data::Dumper;

    use lib 'lib';
    use XUtil 'fasync';

    use Fcntl ':flock';
    flock(DATA, LOCK_EX|LOCK_NB) or die "$0 already running!\n";

    use ZMQ::FFI;
    use ZMQ::FFI::Constants qw(ZMQ_SUB);
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
    
    {
    my $context;
    sub connectZMQ {
        my ($filter) = @_;
        $filter //= "";
        #
        $context = ZMQ::FFI->new();
        my $subscriber = $context->socket(ZMQ_SUB);
        # $subscriber->connect("tcp://127.0.0.1:28332");
        $subscriber->connect($cfg->{bitcoind}{ZMQ});

        $subscriber->subscribe($filter);
        return $subscriber;
    }}

    use File::Basename;
    if (1) {
        $0 = "zmqWatcher"; zmqWatcher();
        my $file = dirname(__FILE__) ."/". __FILE__;
        exec "perl", $file;
        exit;
    }

    my $zmqw;
    my $txcatchup;
    while (1) {
        # fork worker
        if (!$zmqw) {
            warn "ide novi zmq watcher\n";
            $zmqw = fasync { $0 = "zmqWatcher"; zmqWatcher(); };
            # TODO: fork to catchup with TX
        }
        $zmqw->() or $zmqw = undef;
        #print Dumper $zmqw->();

        sleep 1;
    }

    # END
    # --------
    
sub zmqWatcher {
    my $redis;
    my $zmq;
    my @queue;

    # $redis ||= connectRedis();

    my %counter;
    while (1) {
        $redis ||= connectRedis();
        $zmq ||= connectZMQ();

        my @r;
        my $ok = eval {
            @r = $zmq->recv_multipart();
            1;
        };
        if (!$ok) {
            warn "zmq to bitcoin node failed\n";
            $zmq = undef;
            select(undef, undef, undef, 0.15); redo;
        }
        # $_ = unpack('H*', $_) for @r[1, 2];
        $r[1] = unpack('H*', $r[1]);
        $r[2] = unpack('I', $r[2]);
        if ($counter{$r[0]} and $counter{$r[0]}+1 != $r[2]) {
            warn "I've missed at least one $r[0] => [$counter{$r[0]} != $r[2]]\n";
            # catch up with tx
            $redis->lpush("zmqrestart", time() ."-". ($r[2] - $counter{$r[0]}));
            # $redis->ltrim("zmqrestart", 0, 0);

            # $zmq->close; $zmq = undef;
            return;
        }
        $counter{$r[0]} = $r[2];

        push @queue, \@r;
        # print Dumper \@r;

        #
        while (@queue) {
            my $v = shift @queue;
            
            my ($list, $val) = @$v;
            my $ok = eval {
                $redis->lpush("in:$list", $val);
                $redis->ltrim("in:$list", 0, 10_000);
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