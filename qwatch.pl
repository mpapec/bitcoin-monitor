    use strict;
    use warnings;
    use Data::Dumper;

    use lib 'lib';
    use XUtil 'fasync';
    use Digest::SHA 'sha256_hex';

    use Fcntl ':flock';
    flock(DATA, LOCK_EX|LOCK_NB) or die "$0 already running!\n";

    STDOUT->autoflush();
    STDERR->autoflush();

    use Mojo::Base -strict;
    use Mojo::Redis2;
    #  use JSON::XS; # imports encode_json, decode_json

    my $cfg = do "server.conf";
    $Bitcoind::CFG{tx_param} = $cfg->{bitcoind}{RPC};
    # print Dumper \%Bitcoind::CFG; exit;

    sub connectRedis {
        return Mojo::Redis2
            ->new(url => $cfg->{"Mojo::Redis2"})
            ->protocol_class("Protocol::Redis::XS")
        ;
    }

    $0 = __FILE__;

    #
    my ($txw, $xpw, $cuw, $zrw);
    while (1) {
        # watch incoming tx
        $txw ||=  fasync { $0 = "queueWatcher"; queueWatcher(); };
        $txw->() or $txw = undef;

        # watch for new xpub and generate addresses
        $xpw ||= fasync { $0 = "waitNewXpub"; waitNewXpub(); };
        $xpw->() or $xpw = undef;

        # watch existing unused xpub addresses and add when needed
        $cuw ||= fasync { $0 = "checkUnusedAddresses"; checkUnusedAddresses(); sleep 15; };
        $cuw->() or $cuw = undef;

        # watch if ZMQ for node is restarted
        ##$zrw ||= fasync { $0 = "zmqRestart"; zmqRestart(); };
        ##$zrw->() or $zrw = undef;

        sleep 1;
    }
    # END
    # --------

sub get {
    my $method = shift;
    my %get = (
        # 478bfb2f2a1f0ac5a0e6bdd565973540eef84a0ce4b6ec35bc6990f24f395a05
        "in:hashtx"     => sub { return tx => Bitcoind::post(getrawtransaction => @_ , 1) },
        "in:hashblock"  => sub { return block => Bitcoind::post(getblock => @_) },
        "getrawmempool" => sub { return Bitcoind::post(getrawmempool => @_) },
        "getinfo"       => sub { return Bitcoind::post(getinfo => @_) },
        "getblockhash"  => sub { return Bitcoind::post(getblockhash => @_) },
        "gettxout"      => sub { return Bitcoind::post(gettxout => @_) },
        # getblockheader "hash" ( verbose )
    );

    return $get{$method}->(@_);
}

sub queueWatcher {

    my @keys = qw(in:hashblock in:hashtx);

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
        my $isBlock = $list eq "in:hashblock";
        # print Dumper [$list, $val]; exit;

        my ($prefix, $res, $errcode) = $isBlock ? qw(block) : get( $list, $val );
        # if ($errcode or (!$isBlock and !$res)) {
        if ($errcode) {
            next if $errcode == 500;
            warn "bitcoin rpc query failed ($errcode)\n", Dumper $aref;
            push @queue, [ $aref ];
            sleep 1; redo;
        }
        # $result or next;
        my $result = $isBlock ? $val : $res->body;

        my $ok = eval {
            $redis->publish("bch.$prefix", $result);
            if ($isBlock) {
                # del hset on new block
                $redis->del("confirmations");
            }
            else {
                $redis->setex("$prefix:$val", 2*3600, 1);
            }
            1;
        };
        if (!$ok) {
            warn "redis publish failed\n";
            push @queue, [ $aref ];
            $redis = undef;
            sleep 1; redo;
        }

        # print Dumper
        next if $isBlock;
        my $href = $res->json->{result};
        # samo tx, bez blokova
        my $vout = $href->{vout} or next;
        my $txid = $val;

        my @outaddr; my $isMyAddr;
        for my $out (@$vout) {

            my $arr = $out->{scriptPubKey}{addresses} or next;
            push @outaddr, (join ",", sort @$arr) ." ". $out->{value};
            my ($addr) = @$arr;
            $addr =~ s/^ \w+://x;

            #  $redis->hset("watching:xpub", $addr, 44);
            #  $redis->zadd("watching:addr", time(), $addr);

            my $found = checkIncomingOutputAddress($redis, $txid, $addr, $out);
            $isMyAddr ||= !!$found;
        }
    next; # SKIP double spend check

        # monitor double spend
        my $outs_sha = sha256_hex( join ";", sort @outaddr );
        my $vin = $href->{vin};
# print Dumper
        my $multi = $redis->multi;
        for my $in (@$vin) {
            $in->{txid} or next;
            my $k = "in:$in->{txid}:$in->{vout}";
            $multi->hget($k, "outs");
            $multi->hget($k, "txid");
            $multi->hsetnx($k, outs => $outs_sha);
            $multi->hsetnx($k, txid => $txid);
            $multi->expire($k, 3*3600);
        }
        my $resp = $multi->exec;
        my $i =0;
        # my @seen = @$vin[ grep { !($i++ %3) and !$resp->[$_] } 0 .. $#$resp ];
        my $r = $resp;
        my $nth = 5;
        my @groups = map [ @$r[$_*$nth .. $_*$nth+$nth-1] ], 0.. @$r/$nth-1;
# print Dumper \@groups;

        for my $v (@groups) {
            my $outs = $v->[0] or next;
            # $outs eq $outs_sha or next;
            next if $outs eq $outs_sha;
            next if $v->[1] eq $href->{txid};
            print Dumper $v->[1], $href;
        }
# print Dumper \@seen if @seen;
# exit;
        #TODO: provjeri hsetnx rezultate, i spremi DS ako se 'outs' razlikuje
        #TODO: notifikacija ako $isMyAddr
        # print Dumper \@r;
    }
}

sub checkIncomingOutputAddress {
    my ($redis, $txid, $addr, $out) = @_;

            $addr =~ s/^ \w+://x;
            my $xpub_sha = $redis->hget("watching:xpub", $addr) or return;
            # print Dumper [ $xpub_sha ];
            my $idx = $out->{n};
            my $value = $out->{value};

            my $multi = $redis->multi;
            $multi->hdel("watching:xpub", $addr);
            $multi->zrem("watching:addr", $addr);
            # TODO+: brisati iz confirmations hash-a
            $multi->hset("confirmations", $addr, 0);

            # balance sum
            $multi->hincrbyfloat("xpub:$xpub_sha", balance => $value);
            #
            my $k = "check:$addr";
            $multi->lpush($k, "$txid:$idx:$value");
            $multi->expire($k, 24*3600);
            # txid => addr lookup
            $multi->setex("tx2a:$txid", 24*3600, $addr);
            # print Dumper
            return $multi->exec;
}


sub zmqRestart {
    my $redis = connectRedis();

    my ($res, $err);
    while (1) {
        my ($time, $n) = split /-/, $redis->brpop("zmqrestart", 0)->[1];
        $redis->del("zmqrestart");
        # print Dumper $xpub; exit;
        #push @jobs, fasync { $0 = "new:$_"; generateAddresses($_); } for $xpub->[1];
        #@jobs = grep { $_->() } @jobs;

        ($res, $err) = get("getrawmempool");
        # print Dumper $res->json->{result};
        checkTx($res->json->{result});

        ($res, $err) = get("getinfo");
        my $height = $res->json->{result}->{blocks};

        ($res, $err) = get("getblockhash", $height);
        my $hashblock = $res->json->{result};

        for (1..3) {
            (undef, $res, $err) = get("in:hashblock", $hashblock); # ->{tx} {previousblockhash} {confirmations}
            # print Dumper $res->json->{result}{tx};
            checkTx($res->json->{result}{tx});
            $hashblock = $res->json->{result}{previousblockhash};
        }
    }
}
sub checkTx {
    my ($arr) = @_;
    my $redis = connectRedis();

    my $multi = $redis->multi;

    $multi->setnx("tx:$_", 1) for @$arr;
    my $resp = $multi->exec;

    # only tx which are new
    my @idx = grep { $resp->[$_] } 0 .. $#$resp;
    for (@$arr[ @idx ]) {
        $multi->expire("tx:$_", 2*3600);
        $multi->lpush("in:hashtx", "tx:$_");
    }
    # print Dumper    
    $multi->exec;

    # print Dumper $resp, [ @$arr[ @idx ] ];
}

# once
sub waitNewXpub {

    my $redis = connectRedis();
    my @jobs;
    while (1) {
        my $xpub = $redis->brpop("xpub:new", 0);
        # print Dumper $xpub; exit;
        push @jobs, fasync { $0 = "new:$_"; generateAddresses($_, 8); } for $xpub->[1];

        @jobs = grep { $_->() } @jobs;
    }
}

# every nth sec
sub checkUnusedAddresses {

    my $redis = connectRedis();
    my $arr = $redis->smembers("xpub:all");
    generateAddresses($_) for @$arr;
}

sub generateAddresses {

    my ($xpub, $howmany) = @_;

    use BitcoinCash;
    my $redis = connectRedis();
    my $xpub_sha = sha256_hex($xpub);

    my $xpub_hash = "xpub:$xpub_sha";
    my %defaults = (
        xpub => $xpub,
        minaddr => 100,
        generate => 50,
    );
    $redis->hsetnx($xpub_hash, $_ => $defaults{$_}) for keys %defaults;
    my %opt = @{ $redis->hgetall($xpub_hash) };
    my $llen = $redis->llen("unused:$xpub");
    my $n = $opt{minaddr} - $llen;
    return if $n <= 0;

    if ($howmany) { $n = $howmany }
    else {
        $n = $opt{generate} if $n < $opt{generate};
    }
    #print Dumper \%opt, $llen; exit;
    for (1 .. $n) {
        my $idx = $redis->hincrby($xpub_hash, "index", 1);

        my $addr = eval { BitcoinCash::getaddress($xpub, $idx) };
        # invalid xpub
        if (!$addr) {
            $redis->srem("xpub:all", $xpub);
            $redis->lpush("unused:$xpub", "err:cant_generate_address");
            die "$@\n";
        }
        $addr =~ s/^\w+://;
        $redis->lpush("unused:$xpub", $addr);
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
        return $res ? ($res, undef) : (undef, $tx->error->{code} // -1);

        # if (!$res) { warn "$_->{message} ($_->{code})" for $tx->error; return undef }
        # warn Dumper $res->to_string if $Debug;

        # return $res->to_string;
        #return $res->body;
        # return $res->json->{result};
    }
}

__DATA__
44
