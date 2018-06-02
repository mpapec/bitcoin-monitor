    use strict;
    use warnings;
    use Data::Dumper;

    use ZMQ::FFI;
    use ZMQ::FFI::Constants qw(ZMQ_SUB);
    STDOUT->autoflush();
    STDERR->autoflush();

    use Mojo::Base -strict;
    use Mojo::Redis2;
    #  use JSON::XS; # imports encode_json, decode_json

    my $cfg = do "server.conf";

    sub fasync(&) {
      my ($worker) = @_;

      my $pid = fork() // die "can't fork!";

      if (!$pid) {
        $worker->();
        exit(0);
      }

      return sub {
        my ($flags) = @_;
        return waitpid($pid, $flags // 0);
      }
    }

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
        ##$subscriber->connect("tcp://192.168.192.223:28332");
        $subscriber->connect("tcp://127.0.0.1:28332");

        $subscriber->subscribe($filter);
        return $subscriber;
    }}

    # fork worker
    my $worker =  fasync { queueWatcher(); };

    zmqWatcher();
    # END
    # --------
    
sub zmqWatcher {
    my $redis;
    my $zmq;
    my @queue;

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
        $_ = unpack('H*', $_) for @r[1, 2];
        push @queue, \@r;
        print Dumper \@r;

        #
        while (@queue) {
            my $v = shift @queue;
            
            my ($list, $val) = @$v;
            my $ok = eval {
                $redis->lpush("in:$list", $val);
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

sub queueWatcher {

    my @keys = qw(in:hashtx in:hashblock);
    my %get = (
        # 478bfb2f2a1f0ac5a0e6bdd565973540eef84a0ce4b6ec35bc6990f24f395a05
        "in:hashtx"    => sub { return tx => Bitcoind::post(getrawtransaction => @_ , 1) },
        "in:hashblock" => sub { return block => Bitcoind::post(getblock => @_) },
    );

    my $redis;
    my @queue;
    while (1) {
        $redis ||= connectRedis();
        # print Dumper
        my ($aref, $err) = @queue ? @{ shift(@queue) } : eval { $redis->brpop(@keys, 0) };
        if ($err or !defined($aref)) {
            warn "redis brpop failed\n";
            $redis = undef;
            sleep 1; redo;
        }
        
        my ($list, $val) = @$aref;
        # print Dumper [$list, $val]; exit;

        my ($prefix, $result, $errcode) = $get{ $list }->($val);
        if ($errcode) {
            warn "bitcoin rpc query failed ($errcode)\n", Dumper $aref;
            next if $errcode == 500;
            push @queue, [ $aref ];
            sleep 1; redo;
        }
        # $result or next;

        my $ok = eval {
            $redis->setex("$prefix:$val", 15*60, $result);
            $redis->publish("bch.$prefix", $result);
            1;
        };
        if (!$ok) {
            warn "redis publish failed\n";
            push @queue, [ $aref ];
            $redis = undef;
            sleep 1; redo;
            # sleep 1;
            # $redis = connectRedis();
            # redo;
        }
        # print Dumper \@r;
    }
}


BEGIN {
package Bitcoind;
    use strict;
    use Mojo::UserAgent;

    our %CFG = (
          # agent => "Apache-HttpClient/4.1.1 (java 1.5)",
          tx_param => [
            # 'http://bch:C4Z5CHVtGmlzwX8-M-iAQ4C5whL_YGnfVN5A3zCvS14=@192.168.192.223:8332',
            'http://bch:C4Z5CHVtGmlzwX8-M-iAQ4C5whL_YGnfVN5A3zCvS14=@127.0.0.1:8332',
            {
                'Content-Type' => 'application/json',
            },
          ],
    );

    sub post {
        my $method = shift;

        my $ua = Mojo::UserAgent->new();
        # $ua->transactor->name($cfg->{agent});
        my $tx = $ua->post(
            @{ $CFG{tx_param} },
            json => {method => $method, params => \@_ }
        );
        my $res = $tx->success;

        return $res ? ($res->body, undef) : (undef, $tx->error->{code});
        # if (!$res) { warn "$_->{message} ($_->{code})" for $tx->error; return undef }
        # warn Dumper $res->to_string if $Debug;

        # return $res->to_string;
        #return $res->body;
        # return $res->json->{result};
    }
}
