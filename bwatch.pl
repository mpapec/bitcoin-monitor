    use strict;
    use warnings;
    use Data::Dumper;

    use ZMQ::FFI;
    use ZMQ::FFI::Constants qw(ZMQ_SUB);
    $| =1;

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

    # fork worker
    my $worker =  fasync {
        queueWatcher();
    };

    my $redis = connectRedis();

    #
    my $context = ZMQ::FFI->new();
    my $subscriber = $context->socket(ZMQ_SUB);
    $subscriber->connect("tcp://192.168.192.223:28332");

    my $filter = "";
    $subscriber->subscribe($filter);

    while (1) {
        my @r = $subscriber->recv_multipart();
        $r[1] = unpack('H*', $r[1]);

        my ($list, $val) = @r;
        $redis->lpush("in:$list", $val);

        push @r, unpack('H*', $r[-1]);
        print Dumper \@r;
    }

    # END
    # --------


sub queueWatcher {
    my $redis = connectRedis();

    my @keys = qw(in:hashtx in:hashblock);
    my %get = (
        # 478bfb2f2a1f0ac5a0e6bdd565973540eef84a0ce4b6ec35bc6990f24f395a05
        "in:hashtx"    => sub { return tx => Bitcoind::post(getrawtransaction => @_ , 1) },
        "in:hashblock" => sub { return block => Bitcoind::post(getblock => @_) },
    );
    while (1) {
        my ($aref, $err) = $redis->brpop(@keys, 0);
        my ($list, $val) = @$aref;
        # print Dumper [$list, $val];

        my ($prefix, $result) = $get{ $list }->($val);
        $redis->setex("$prefix:$val", 15*60, $result);
        $redis->publish("bch.$prefix", $result);
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
            'http://bch:C4Z5CHVtGmlzwX8-M-iAQ4C5whL_YGnfVN5A3zCvS14=@192.168.192.223:8332',
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
        my $res = $tx->success or return undef;
        # if (!$res) { die "$_->{message} ($_->{code})" for $tx->error }
        # warn Dumper $res->to_string if $Debug;

        # return $res->to_string;
        return $res->body;
        # return $res->json->{result};
    }
}
