#
# razmjena poruka s redisom
#
{
package App::RedisKurir;

    use v5.16;
    use Mojo::Base 'Mojolicious::Plugin';

    use Mojo::JSON qw(decode_json encode_json);
    use Data::UUID;


    # register helpers
    sub register {
        my ($self, $app) = @_;

        # vraca redis handler
        $app->helper( redis => \&redis );
        # postavi listenere i ostale event handlere vezane za redis
        $app->helper( registerRedisEvents => \&registerRedisEvents );

        # interni flagovi za pracenje stanja konekcije
        $app->helper( redisFlags => \&redisFlags );

        # postavlja stanje connected/disconnected
        $app->helper( redisSetConnected => \&redisSetConnected );
        $app->helper( redisSetDisconnected => \&redisSetDisconnected );

        # slanje na privatni redis mbox, plus publish
        $app->helper( redisSend => \&redisSend );
        # preuzmi poruku ako ima iz privatnog mboxa
        $app->helper( getFifoMbox => \&getFifoMbox );
        #
        $app->helper( redisCheckMbox => \&redisCheckMbox );

        # obradjuje dolaznu privatnu redis poruku
        $app->helper( handleRedisMessage => \&handleRedisMessage );

        # opceniti subscriber za privatne/osobne i javne/room dolazne poruke
        $app->helper( redisSubscribtions => \&redisSubscribtions );

        # manager za ulaz/izlaz iz javne sobe
        $app->helper( redisRoomSubscriptions => \&redisRoomSubscriptions );
        $app->helper( handleRedisRoomMessage => \&handleRedisRoomMessage );
    }

    #
    #
    #

    # javni kanali
    sub redisRoomSubscriptions {
        my ($c, %arg) = @_;

        # defaultni member
        # $arg{node} ||=
        my $memberID = $arg{node};

        # state $roomMembers = {
            # # "roomID" => [members..]
        # };
        state $members = {
            # "roomID" => {
            #       "memberID" => "memberID"
            # }
        };

        # get all room members
        if (my $room = $arg{get}) {
            # return $roomMembers->{$room} || [];
            return $members->{$room} || {};
        }
        # enter the room
        elsif ($room = $arg{enter}) {
            # soba pocinje s 0 ili underscore
            if ($room =~ /^[0_]/) {
                $c->log->warn("Member $memberID tried to spy on private node $room");
                return "FORBIDDEN";
            }
            if (!$memberID) {
                $c->log->warn("No member given to enter the room $room");
                return "NEED_MEMBER";
            }
            my $roomRef = $members->{$room} ||= {};
            if ($roomRef->{$memberID}) {
                $c->log->warn("Member $memberID already in the room $room");
                return "ALREADY_THERE";
            }
            $roomRef->{$memberID} = $memberID;
        }
        # leave the room
        elsif ($room = $arg{leave}) {
            if (!$memberID) {
                $c->log->warn("No member given to leave the room $room");
                return "NEED_MEMBER";
            }
            # my $roomRef = $members->{$room};
            # remove $memberID from room
            if (!delete($members->{$room}{$memberID})) {
                $c->log->warn("Member $memberID not in the room $room");
                return "NOT_THERE";
            }
        }
        # ok!
        return "";
    }

    sub redisFlags {

        state $hash = {
            connected => 0,
            registerRedisEvents => 0,
        };
    }

    sub redisSetConnected {
        my ($c) = @_;

        $c->redisFlags->{connected} = 1;
    }
    sub redisSetDisconnected {
        my ($c, $err) = @_;

        # release redis handle
        $c->redis({reset => 1});

        $c->redisFlags->{connected} = 0;    
        # flag to re-register redis events
        $c->redisFlags->{registerRedisEvents} = 0;

        $c->log->error("Disconnected from redis: ". ($err ||""));
        
        # reconnect
        Mojo::IOLoop->timer(1 => sub{ $c->redis; });
    }

    # https://metacpan.org/pod/Mojo::Redis2
    # https://metacpan.org/pod/Mojo::Redis2#protocol_class
    # connect to redis
    sub redis {

        my ($c, $arg) = @_;
        state $redis;

        if ($arg->{reset}) {
            undef $redis;
            return undef;
        }
        if (!$redis) {
            my $cfg = $c->cfg;
            $c->log->warn("Connecting to server [". $cfg->{"Mojo::Redis2"} ."]");

            # my $redis = Mojo::Redis2->new(url => 'redis://127.0.0.1:6379/3');
            $redis = Mojo::Redis2
                ->new(url => $cfg->{"Mojo::Redis2"})
                ->protocol_class("Protocol::Redis::XS")
            ;

            #
            $c->registerRedisEvents;
            $c->redisSubscribtions(repeated =>1);
        }

        return $redis;
    }

    # subscribe to redis channels
    sub redisSubscribtions {

        my ($c, %arg) = @_;

        $arg{repeated} //= 0;
        $arg{pattern} //= 0;
        #TODO: subscribanje za internu kom. izmedju workera!

        # kanali
        state $channels = {
            plain => {},
            pattern => {},
        };
        #
        my $filtered = {
            plain => [],
            pattern => [],
        };

        my $kind = $arg{pattern} ? "pattern" : "plain";
        my $channels_kind = $channels->{$kind};

        if ($arg{repeated}) {
            $filtered->{plain}   = [ values %{ $channels->{plain} } ];
            $filtered->{pattern} = [ values %{ $channels->{pattern} } ];
        }
        elsif (my $arr = $arg{subscribe}) {
            # samo kanali koji se vec ne gledaju
            my @tmp = grep { !$channels_kind->{$_} } @$arr;
            push @{ $filtered->{$kind} }, @tmp;
            @$channels_kind{@tmp} = @tmp;
        }
        elsif ($arr = $arg{unsubscribe}) {
            # samo kanali koji se vec gledaju
            my @tmp = grep { $channels_kind->{$_} } @$arr;
            push @{ $filtered->{$kind} }, @tmp;
            delete @$channels_kind{@tmp};
        }
        else {
            $c->log->debug("Nothing to do");
            return;
        }
        
        # $c->log->debug( $c->dumper(\%arg, $filtered) );
        my $somethingTodo = grep { @$_ } values %$filtered;
        if (!$somethingTodo) {
            $c->log->warn("Have no redis channels to subscribe to");
            return;
        }

        my $onStatusChange = sub {
            my ($self, $err, $res) = @_;

            if ($err) {
                $c->redisSetDisconnected("error on redis ch (un)subscribe: $err") if $c;
                # $c->log->error("error on redis subscribe: $err");
            }
        };

        for my $kind (keys %$filtered) {
            my $tmp = $filtered->{$kind};
            next if !@$tmp;

            # subscribe
            if ($arg{subscribe} or $arg{repeated}) {
                $c->log->debug("'$kind' subscribing to redis ch: [@$tmp]");

                # plain
                if ($kind eq "plain") { $c->redis->subscribe($tmp, $onStatusChange); }
                # pattern
                else { $c->redis->psubscribe($tmp, $onStatusChange); }
            }
            # unsubscribe
            elsif ($arg{unsubscribe}) {
                $c->log->debug("'$kind' unsubscribing from redis ch: [@$tmp]");

                # plain
                if ($kind eq "plain") { $c->redis->unsubscribe($tmp, $onStatusChange); }
                # pattern
                else { $c->redis->punsubscribe($tmp, $onStatusChange); }
            }
        }
    }

    # publish to private redis channel and mbox
    sub redisSend {

        my ($c, $node, $msg, $snode, $cb) = @_;
        # source node
        $msg->{_snode} = $snode;
        $msg->{_msid} = lc( Data::UUID->new->create_str );

        # $c->log->debug("redisSend: ". $c->dumper($msg));
        my $msgTxt = encode_json($msg);

        $c->iodelay(
            # prvo stavi u node mbox (list queue)
            sub {
                my ($d, $err) = @_;

                my $mbox = "lq:$node";
                $c->redis
                    ->lpush($mbox, $msgTxt, $d->begin)
                    ->expire($mbox, $c->cfg->{sesssTimeout}, $d->begin)
                    ->publish($node, "[snode:$snode]", $d->begin)
                ;
            },
            sub {
                my ($d) = @_;
                
                # thorw error if there are any
                $c->ioErr(@_);

                # salji notifikaciju nakon spremanja u mbox
                # $c->redis->publish($node => $msgTxt);
                # $c->redis->publish($node => "[snode:$snode]");
                $d->pass(undef, my $ok=1);
            },
            $cb
        );
    }

    #
    sub redisCheckMbox {

        my ($c, $node, %arg) = @_;

        # $c->log->debug("Catch up with mbox messages for node $node");

        my $mbox = "lq:$node";
        $c->iodelay(
            sub {
                my ($d, $err) = @_;

                $c->redis->llen($mbox, $d->begin);
            },
            sub {
                my ($d, $err, $rval) = @_;
                return $d->pass if !$rval;

                $c->log->debug("Catch up with mbox $mbox ($rval messages)");

                $c->redis
                    ->publish($node, "[catchup]", $d->begin);
            },
            # $cb
            sub {},
        );
    }

    # preuzmi jednu poruku iz node mboxa
    sub getFifoMbox {
        my $cb = pop(@_);
        my ($c, $node, %arg) = @_;

        my $waiting = defined $arg{wait};

        $c->iodelay(
            # prvo stavi u node mbox (list queue)
            sub {
                my ($d, $err) = @_;

                my $mbox = "lq:$node";
                # blocking/waiting RPOP
                # http://redis.io/commands/BRPOP
                if ($waiting) {
                    $c->redis->brpop($mbox, $arg{wait}, $d->begin);
                }
                else {
                    $c->redis
                        ->rpop($mbox, $d->begin)
                        # ->llen($mbox, $d->begin)
                    ;
                }
            },
            sub {
                my ($d, $err, $rval) = @_;
                
                # die $err if $err;
                $c->ioErr(@_);
                
                if ($waiting) {
                    $rval = @$rval ? $rval->[-1] : undef;
                }

                $rval = decode_json($rval) if $rval;
                # return value
                $d->pass(undef, $rval);
            },
            $cb
        );
    }

    sub handleRedisRoomMessage {
        my ($c, $node, $msg) = @_;

        # nadji privatne nodove koji su subscribani na javni $node kanal
        my $nodes = $c->redisRoomSubscriptions(get => $node);
        # $c->wsSend($nodes, $msg);
        $c->wsSend($nodes, { json => $msg, _event => $node });
    }

    sub handleRedisMessage {
        my ($c, $node, $msg) = @_;

        # $msg => we don't care for it as we'll read everything from node mbox
        
        # odustani ako nema aktivnog noda kojem se salje poruka
        if (!$c->wsHandle($node)) {

            $c->log->warn("node $node not active, skipping mbox message");
            return;
        }

        # my @arr;
        my $whileStep = 0;

        $c->iodelay(
            # vv__while loop :-)
            sub {
                my ($d, $err, $rval) = @_;
                
                if ($whileStep++) {
                    # die $err if $err;
                    $c->ioErr(@_);
                    # goto next step
                    return $d->pass if !$rval;

                    $c->wsSend($node, $rval);
                    # TODO: log to pg
                }
                # run current function again
                unshift @{$d->remaining}, __SUB__;
                
                $c->getFifoMbox($node, $d->begin);
            },
            # $cb
            sub {
                my ($d, $err, $rval) = @_;
                $c->log->error("handleRedisMessage() exception: $err") if $err;
            }
        );
    }

    sub _handleMojoWorkerRedisMessage {

        my ($c, $msg) = @_;

        # handle requests
        if (my $request = $msg->{request}) {
            $msg->{response} = delete $msg->{request};

            if ($request eq "activeClients") {
                $msg->{result} = scalar(keys %{$c->connForWs});
                $msg->{pid} = $$;
            }
            # elsif {}
            return $msg if exists $msg->{result};
        }
        # handle responses
        elsif (my $response = $msg->{response}) {
            # my $request = $msg->{request}; # or last
            if ($response eq "activeClients") {
                # $c->stash( $$ => $msg );
                my $arr = $c->mystash->{ $response } ||= [];
                # my $h = $c->stash;
                push @$arr, $msg;
            }
            return;
        }

        # nothing to do..
        # $msg->{response} = { err => "DONT_UNDERSTAND"};
        $c->log->warn("Don't understand ". $c->dumper($msg));
        return;
    }
    sub registerRedisEvents {

        my ($c) = @_;

        return if $c->redisFlags->{registerRedisEvents}++;
        # return if $c->redisFlags->{connected};
        
        #
        state $redisEvents = {
            # redis connection event
            connection => sub {
                my ($redis, $conn) = @_;

                # $c->redisFlags->{connected} = 1;
                $c->log->info("Connected to redis! [$conn->{id}]");
                $c->redisSetConnected;
            },
            # handle redis errors
            error => sub {
                my ($redis, $err) = @_;

                # $c->log->error("Disconnected from redis: $err");
                $c->redisSetDisconnected($err);
            },
            # incoming redis messages => to browser via ws
            message => sub {
                my ($redis, $msg, $node) = @_;

                if (!$node) {
                    return $c->log->error("Incoming redis message: NO_DESTINATION_NODE");
                }
                $c->log->debug("Incoming redis message for node $node: $msg");

                my $cfg = $c->cfg;
                # interna mojo worker komunikacija
                if ($node eq $cfg->{mojoWorkerRoom} or $node eq $cfg->{mojoWorkerRespondRoom}) {

                    my $resp = _handleMojoWorkerRedisMessage($c, decode_json($msg))
                        or return;
                    $c->redis
                        ->publish($cfg->{mojoWorkerRespondRoom}, encode_json($resp), sub {});

                    return;
                }
                $c->handleRedisMessage($node, $msg);
            },
            # dolazne redis pattern poruke; samo za javne sobe
            pmessage => sub {
                my ($redis, $msg, $node, $pattern) = @_;

                $c->log->debug("Incoming redis pmessage for node $node: $msg");

                $c->handleRedisRoomMessage($node, $msg, $pattern);
            },
        };

        my @eventNames = keys %$redisEvents;
        for my $event (@eventNames) {

            $c->redis->on($event => $redisEvents->{$event});
        }
        $c->log->debug("redis events in place: ". join(",", @eventNames));
    }

}

1;
