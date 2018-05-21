{
package App::Main;

    use Mojo::Base 'Mojolicious::Plugin';

    # use Mojo::JSON qw(decode_json encode_json);
    # use Data::UUID;
    # use Digest::SHA;
    # use Crypt::Random qw( makerandom ); 
    # use Mojo::IOLoop::ReadWriteFork;
    # use Carp;
    use Time::HiRes ();

    # register helpers
    sub register {
        my ($self, $app) = @_;

        $app->helper( peerComm => \&peerComm );
    }

    # dolazne poruke od ws klijenta/vrati odgovor ili nista
    sub peerComm {
        my ($c, $msg, $sess, $cb) = @_;

        # my ($event, $msg) = @$envelope;
        my $event = $msg->{_event} // "";
        my $ret;

        # want his session data
        if ($event eq "__sync") {
            my $clientTime = $msg->{text};
            my $serverTimestamp = int(Time::HiRes::time() *1000);
            $ret = {
                diff => ($serverTimestamp - $clientTime),
                serverTimestamp => $serverTimestamp,
                _event => $event,
            };
        }
        elsif ($event eq "getSession") {

            $c->log->debug("peer looks for session info: ". $sess->{sessid});
            # shallow copy
            $ret = { %$sess };

            $ret->{_event} = "session";
            # return $ret;
        }
        # want to enter room
        # elsif (my $room = $msg->{enter}) 
        elsif ($event eq "enter") {
            my $room = $msg->{text} // "";
            $c->log->debug("peer wants to enter the room $room");

            my $err = $c->redisRoomSubscriptions(
                enter => $room,
                node => $sess->{id},
            );
            $ret = $err ? {_event => "error", err => $err} : 0;
            # return $err ? {_event => "error", err => $err} : undef;
        }
        # want to leave room
        # elsif ($room = $msg->{leave})
        elsif ($event eq "leave") {
            my $room = $msg->{text} // "";
            $c->log->debug("peer wants to leave the room $room");

            my $err = $c->redisRoomSubscriptions(
                leave => $room,
                node => $sess->{id},
            );
            $ret = $err ? {_event => "error", err => $err} : 0;
            # return $err ? {_event => "error", err => $err} : undef;
        }
        #
        # elsif ($event eq "foo") {
            # # TODO: tiket poruka od klijenta
            # return _foo($c, {}, $event, $cb);
            # # $ret = 0;
        # }

        # nothing to do..
        # return {_event => "error", err => "DONT_UNDERSTAND"};
        $ret //= {_event => "error", err => "DONT_UNDERSTAND"};
        return $c->$cb(undef, $ret);
    }

    #
    sub _foo {
        my ($c, $msg, $event, $cb) = @_;

        # TODO
        $msg = {
            "siffoo" => 5002,"usifra" => 9907,"uname" => "WebFooWriter","money" => 
            {"uplata" => 1.1,"ulog" => 10,"tax1" => 0.01,"tax2" => 0},"betstring" => "1,2,3,4,5,6,7,8,9"
        };

        $c->iodelay(
            sub {
                my ($d, $err, $rval) = @_;

                my $tsp = $c->cfg->{TSP};
                $c->ua
                    # ->ca($tsp->{cert})
                    # ->cert($tsp->{cert})
                    ->post($tsp->{restUrl}, json => $msg, $d->begin);
            },
            sub {
                my ($d, $tx) = @_;

                my $res = $tx->success or die({ err => "foo_FAILED", detail => $tx->error });
                my $json = $res->json or die({ err => "foo_FAILED", detail => "NO_JSON_RESPONSE" });
                $json->{_event} = $event;

                #
                $d->pass(undef, $json);

                # if (my $res = $tx->success) { say $res->body }
                # else {
                    # my $err = $tx->error;
                    # die "$err->{code} response: $err->{message}" if $err->{code};
                    # die "Connection error: $err->{message}";
                # }
            },
            $cb
        );

    }

}

1;
