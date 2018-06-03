    use strict;
    use warnings;
    use Data::Dumper;

    # use ZMQ::FFI;
    # use ZMQ::FFI::Constants qw(ZMQ_SUB);
    STDOUT->autoflush();
    STDERR->autoflush();

    use Mojo::Base -strict;
    use Mojo::Redis2;
    #  use JSON::XS; # imports encode_json, decode_json

    my $cfg = do "server.conf";
    $Bitcoind::CFG{tx_param} = $cfg->{bitcoind}{RPC};
    # print Dumper \%Bitcoind::CFG; exit;

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
    
    while (1) {
        # fork worker
        my $worker =  fasync { $0 = "queueWatcher"; queueWatcher(); };
        $worker->();
    }
    # END
    # --------
    
sub queueWatcher {

    my @keys = qw(in:hashtx in:hashblock);
    my %get = (
        # 478bfb2f2a1f0ac5a0e6bdd565973540eef84a0ce4b6ec35bc6990f24f395a05
        "in:hashtx"    => sub { return tx => Bitcoind::post(getrawtransaction => @_ , 1) },
        "in:hashblock" => sub { return block => Bitcoind::post(getblock => @_) },
    );

    my $redis;
    my @queue;
    for (1 .. 1000) {
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

        my ($prefix, $res, $errcode) = $get{ $list }->($val);
        if ($errcode) {
            warn "bitcoin rpc query failed ($errcode)\n", Dumper $aref;
            next if $errcode == 500;
            push @queue, [ $aref ];
            sleep 1; redo;
        }
        # $result or next;
        my $result = $res->body;

        my $ok = eval {
            $redis->publish("bch.$prefix", $result);
            $redis->setex("$prefix:$val", 15*60, $result);
            # del hset on new block
            $redis->del("confirmations") if $list =~ /block/;
            1;
        };
        if (!$ok) {
            warn "redis publish failed\n";
            push @queue, [ $aref ];
            $redis = undef;
            sleep 1; redo;
        }

        # print Dumper
        my $href = $res->json->{result};
        my $vout = $href->{vout} or next;
        my $txid = $val;
        for my $out (@$vout) {

            my $arr = $out->{scriptPubKey}{addresses} or next;
            my ($addr) = @$arr;
            $addr =~ s/^ \w+://x;

     $redis->hset("watching:xpub", $addr, 44);
     $redis->zadd("watching:addr", time(), $addr);

            checkIncomingOutputAddress($redis, $txid, $addr, $out);
#            my $xpub_sha = $redis->hget("watching:xpub", $addr) or next;
#print Dumper [ $xpub_sha ];
#            my $idx = $out->{n};
#            my $value = $out->{value};

#            my $multi = $redis->multi;
#            $multi->hdel("watching:xpub", $addr);
#            $multi->zrem("watching:addr", $addr);
#            $redis->hset("confirmations", $addr, 0);

#            $multi->hincrbyfloat("xpub:$xpub_sha", balance => $value);
            #
#            $multi->lpush("watch:$addr", "$txid:$idx:$value");
#            $multi->expire("watch:$addr", 24*3600);
#print Dumper
#            $multi->exec;
        }
        # print Dumper \@r;
    }
}

sub checkIncomingOutputAddress {
    my ($redis, $txid, $addr, $out) = @_;

            my $xpub_sha = $redis->hget("watching:xpub", $addr) or return;
print Dumper [ $xpub_sha ];
            my $idx = $out->{n};
            my $value = $out->{value};

            my $multi = $redis->multi;
            $multi->hdel("watching:xpub", $addr);
            $multi->zrem("watching:addr", $addr);
            $redis->hset("confirmations", $addr, 0);

            $multi->hincrbyfloat("xpub:$xpub_sha", balance => $value);
            #
            $multi->lpush("watch:$addr", "$txid:$idx:$value");
            $multi->expire("watch:$addr", 24*3600);
print Dumper
            $multi->exec;
}

BEGIN {
package Bitcoind;
    use strict;
    use Mojo::UserAgent;

    our %CFG = (
          # agent => "Apache-HttpClient/4.1.1 (java 1.5)",
          tx_param => [
            # 'http://bch:C4Z5CHVtGmlzwX8-M-iAQ4C5whL_YGnfVN5A3zCvS14=@192.168.192.223:8332',
            # 'http://bch:C4Z5CHVtGmlzwX8-M-iAQ4C5whL_YGnfVN5A3zCvS14=@127.0.0.1:8332',
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

        # return $res ? ($res->body, undef) : (undef, $tx->error->{code});
        return $res ? ($res, undef) : (undef, $tx->error->{code});
        # if (!$res) { warn "$_->{message} ($_->{code})" for $tx->error; return undef }
        # warn Dumper $res->to_string if $Debug;

        # return $res->to_string;
        #return $res->body;
        # return $res->json->{result};
    }
}
