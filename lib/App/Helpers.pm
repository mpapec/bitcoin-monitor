{
package App::Helpers;

    use Mojo::Base 'Mojolicious::Plugin';

    use Delay2;
    use Scalar::Util qw(blessed weaken);

    use Mojo::JSON qw(decode_json encode_json);
    use Data::UUID;
    use Digest::SHA;
    # use Crypt::Random qw( makerandom ); 
    # use Mojo::IOLoop::ReadWriteFork;
    use Carp;


    # register helpers
    sub register {
        my ($self, $app) = @_;

        $app->helper( log => \&log );
        $app->helper( mystash => \&mystash );
        $app->helper( iodelay => \&iodelay );
        $app->helper( ioErr => \&ioErr );
        $app->helper( remoteAddress => \&remoteAddress );
        # $app->helper( peerComm => \&peerComm );
        $app->helper( sessionCheck => \&sessionCheck );
        $app->helper( sessionStart => \&sessionStart );
        $app->helper( getWorker => \&getWorker );
    }

    #
    #
    #

    # http://mojolicious.org/perldoc/Mojo/Log (debug/info/warn/error/fatal)
    sub log {

        my ($c) = @_;

        state $log;

        state $r_ip;
        $r_ip = $c->tx->remote_address // "-";
        if (!$log) {
            $log = Mojo::Log->new(%{
                $c->cfg->{log} || {}
            });
            $log->format(sub{
                 my ($time, $level, @lines) = @_;
                 return "[" . localtime(time) . "] [$$:$level] [$r_ip] " . join("\n", @lines) ."\n";
            });
            $c->app->log($log);
        }
        return $log;
    };

    sub mystash {

        state $stash = {};
        return $stash;
    }

    sub iodelay {
        my $cb = pop @_;
        my ($c, @steps) = @_;

        push @steps, sub {
            shift @_;
            my ($err) = @_;
            $c->log->debug("iodelay catched error:". $c->dumper($err)) if $err;
            $cb->($c, @_);
        };

        # zadnji korak u @steps i catch func su isti
        my $delay = Delay2->new;
        weaken $delay->ioloop(Mojo::IOLoop->singleton)->{ioloop};
        return @steps ? $delay->steps(@steps)->catch($steps[-1]) : $delay;
    }

    # errors are at odd indices
    sub ioErr {
        my ($c, @arr) = @_;

        # rethrow exception
        die($arr[1]) if ref($arr[1]);

        my $i = 0;
        my $err = join "; ",
            grep { $i++ %2 and $_ } @arr;

        die({err => $err}) if $err;
    }

    # ip adresa klijenta
    sub remoteAddress {
        my ($c) = @_;

        return $c->req->headers->header('X-Forwarded-For') || $c->tx->remote_address;
    }

    # dal postoji/nije istekao session
    sub sessionCheck {
        my $cb = pop(@_);
        my ($c, %arg) = @_;

        my $sessid = $arg{sessid} || $c->stash("sessid") || "";
        
        #
        $c->iodelay(
            sub {
                my ($d, $err) = @_;

                $c->redis->hgetall("sess:$sessid", $d->begin);
            },
            sub {
                my ($d, $err, $aref) = @_;

                $d->pass(undef, { @$aref });
            },
            $cb
        );
    }

    #
    sub sessionStart {
        my $cb = pop(@_);
        my ($c, %arg) = @_;

        # websocket po defaultu
        $arg{isWs} //= 1;
        # $arg{checkOnly} //= 0;
        my $sessid = $arg{sessid} || $c->stash("sessid") || "";

        #
        my $remote_address = $c->remoteAddress;
        my $remote_port = $c->tx->remote_port;
        $c->log->debug("Preparing to start session for $remote_address:$remote_port");

        # unique connection id
        my $id;

        my $checkGivenSession = (length($sessid) >40);
        my $makeNewSession = !$checkGivenSession;

        #
        $c->iodelay(
            sub {
                my ($d, $err) = @_;
                
                return $d->pass if !$checkGivenSession;

                $c->redis->hgetall("sess:$sessid", $d->begin);
            },
            sub {
                my ($d, $err, $aref) = @_;
                return $d->pass if !$checkGivenSession;

                #
                if (@$aref) {
                    my %sdata = @$aref;
                    $c->log->debug("Recovered session: $sessid");
                    $id = $sdata{wsid};
                    # provjeri propustene poruke
                    Mojo::IOLoop->timer(1 => sub{ $c->redisCheckMbox($id); });
                }
                else {
                    $makeNewSession = 1;
                    $c->log->debug("Can't recover session: $sessid");
                }
                $d->pass;
            },
            sub {
                my ($d, $err) = @_;
                return $d->pass if !$makeNewSession;

                my $user_agent = $c->tx->req->headers->user_agent // "[no user agent]";
                my $tmp = join("|",
                    $remote_address, $remote_port,
                    $user_agent,
                    # makerandom(Size =>512, Strength =>0),
                    rand(),
                    time(), $$, []
                );
                $sessid = Digest::SHA::sha256_hex($tmp);
                # TODO
                $c->log->debug("Starting new session ($user_agent): $sessid");

                $id ||= Data::UUID->new->create_from_name_hex($c->tx->local_address, "$remote_address:$remote_port");

                #
                my $skey = "sess:$sessid";
                $c->redis
                    # session related hash
                    ->hmset(
                        $skey,
                        "wsid" => $id,
                        $d->begin
                    )
                    # expire session after N sec
                    ->expire($skey, $c->cfg->{sesssTimeout}, $d->begin)
                ;
            },
            sub {
                my ($d) = @_;

                # thorw error if there are any
                $c->ioErr(@_);

                ## my $id = sprintf("%s", $self->tx);
                $c->log->debug("Registering ws connection: [id:$id] [sessid:$sessid]");

                #
                $d->pass(undef, {
                    id     => $id,
                    sessid => $sessid,
                    # ws disconnect/finish
                    $arg{isWs}
                        ? (onFinish => $c->wsRegister($id, $sessid))
                        : (),
                });
            },
            $cb
        );
    };

    sub _createForkedWorker {

        my ($c, $cmd) = @_;

        my ($kind) = @$cmd;
        my $cb;
        my $fork = Mojo::IOLoop::ReadWriteFork->new;

        # Emitted if something terrible happens
        $fork->on(error => sub {
            my (undef, $error) = @_;
            # warn $error;
            undef $fork;
            undef $cb;
            die {err => "${kind}Worker error, throwing it away!"};
        });

        # Emitted when the child completes
        $fork->on(close => sub {
            my (undef, $exit_value, $signal) = @_;
            # warn $error;
            undef $fork;
            undef $cb;
            die {err => "${kind}Worker terminates!"};
        });

        # Emitted when the child prints to STDOUT or STDERR
        $fork->on(read => sub {
            my (undef, $buf) = @_;

            # warn qq(Child process sent us:\n$buf);
            $c->$cb(undef, decode_json($buf)) if $cb;
        });

        # Need to set "conduit" for bash, ssh, and other programs that require a pty
        # $fork->conduit({type => "pty"});

        # longliving program iz komandne linije
        $fork->run(@$cmd);
        # $fork->run("node", "-e", $jScript);

        return sub {
            my %arg = @_;

            return $fork if $arg{get};
            $cb = $arg{setCB} if $arg{setCB};
        };
    }

    sub getWorker {
        # my $cb = pop(@_);
        my ($c, %arg) = @_;

        state $external = {
            js => {
                # TODO: maknuti visak idle workera
                # pool of workers
                workers => [],
                writeFunc => sub {
                    my ($json, $eval) = @_;
                    return qq(var _arg=JSON.parse("$json"); ($eval)(_arg);\n);
                },
                # izvrsi/eval svaku liniju na process.stdin, i ispisi/vrati kao json na stdout
                cmdLine => ["node", "-e", q(
                    global.STASH = {};
                    var readline = require('readline');
                    readline.createInterface({
                      input: process.stdin,
                      output: process.stdout,
                      terminal: false
                    })
                    .on('line', function(line){
                        console.log( JSON.stringify(eval(line)) );
                    });
                )],
            },
            php => {
                workers => [],
                writeFunc => sub {
                    my ($json, $eval) = @_;
                    my $ret = sprintf(q($_arg =json_decode("%s", 1); $_func =%s; print json_encode($_func($_arg));), $json, $eval);
                    return "$ret\n";
                },
                # izvrsi/eval svaku liniju na process.stdin, i ispisi/vrati kao json na stdout
                cmdLine => ["php", "-r", q(
                    $STASH = array();
                    while ($line = fgets(STDIN)){
                        eval($line);
                    }
                )],
            },
        };
        my $workers = $external->{ $arg{type} }{workers} or croak "wrong 'type'";
        my $cmdLine = $external->{ $arg{type} }{cmdLine} or croak;
        my $writeFunc = $external->{ $arg{type} }{writeFunc} or croak;
        my $rfork;

        return sub {
            my $cb = (@_ %2) ? pop(@_) : undef;
            my %arg = @_;

            #
            my $fork;
            GET_ANOTHER: {
                $rfork ||= pop(@$workers) || _createForkedWorker($c, $cmdLine);
                $fork = $rfork->(get => 1);
                if (!$fork) {
                    undef($rfork);
                    redo GET_ANOTHER;
                }
            }

            if ($arg{eval}) {
                $cb ||= sub { croak '$d->begin should be last parameter' };
                $rfork->(setCB => $cb);

                # backslashaj "
                my $json = encode_json($arg{arg}) =~ s! " !\\"!xgr;
                # sve u jedan red bez vodecih razmaka
                my $eval = $arg{eval} =~ s/^\s+ | [\r\n]+//xgmr;

                # posalji forku na stdin liniju za eval()
                $fork->write( $writeFunc->($json, $eval) );
            }
            # vrati workera natrag u pool
            elsif ($arg{release}) {
                push (@$workers, $rfork);
                undef $rfork;
            }
        };
    }

}

1;
