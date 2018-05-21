#
# razmjena poruka s browserom (websocket)
#
{
package App::WsKurir;

    use Mojo::Base 'Mojolicious::Plugin';

    # register helpers
    sub register {
        my ($self, $app) = @_;


        $app->helper( connForWs => \&connForWs );
        $app->helper( sessionForConn => \&sessionForConn );
        $app->helper( registerWsEvents => \&registerWsEvents );
        $app->helper( wsRegister => \&wsRegister );
        $app->helper( wsHandle => \&wsHandle );
        $app->helper( wsSend => \&wsSend );
        # $app->helper( wsSendAll => \&wsSendAll );
        $app->helper( wsSendAllViaRedis => \&wsSendAllViaRedis );
    }

    #
    #
    #

    # websocket - public
    sub connForWs {
        # <connection ID> => <wsObject>
        state $h = {};
    }
    # user sessions - secret
    sub sessionForConn {
        # <session ID> => <connection ID>
        state $h = {};
    }

    sub registerWsEvents {
        my ($c) = @_;
        
        my $sess;

        # on disconnect/finish
        $c->on(finish => sub {

            $c->log->warn("browser ws closed/finished for node ". ($sess ? $sess->{id} : "[not yet initialized]"));
            return if !$sess;
            
            $sess->{onFinish}->();
            undef $sess;
        });
=pod
        $c->on(drain => sub {
            # my $ws = (@_);
            $c->log->debug("ws drain for $sess->{id}") if $sess;
        });
=cut

        my $errReply = sub {
            my ($errMsg, $msg) = @_;

            $errMsg = {err => $errMsg} if !ref($errMsg);

            $c->log->error("Browser request failed: ", $c->dumper($errMsg));
            # prava greska ima whitespace u sebi i takve nemoj slati browseru
            $errMsg->{err} = "TRY_AGAIN" if $errMsg->{err} =~ /\s/;

            $errMsg->{_smsid} = $msg->{_msid};
            $errMsg->{_event} = "error";
            # $sess->{id}||
            $c->wsSend($c->tx, $errMsg);
        };

        # on incoming json message
        $c->on(json => sub {
            my ($self, $envelope) = @_;
            my $msg = $envelope->[1];
            $msg->{_event} = $envelope->[0] // "";

            $c->log->debug("ws json (incoming!) from node ". ($sess ? $sess->{id} : "[not yet initialized]"));
            # redis mora biti dostupan
            if (!$c->redisFlags->{connected}) {
                $errReply->({ err => "TRY_AGAIN" }, $msg);
                return;
            }
            # vvv___sva logika za klijenta mora biti ispod___vvv
            
            my $chatTest = 0;
            # non-blocking koraci, slicno promisima
            Mojo::IOLoop->delay(
                # korak1; zapocni session ako vec nije
                sub {
                    my ($d) = @_;
                    
                    if (!$sess and $msg->{_event} eq "getSession") {  
                        return $c->sessionStart( $d->begin );
                    }
                    return $d->pass;
                },
                # korak2; dal je greska za prethodni korak i nastavi obradu ws poruke
                sub {
                    my ($d, $err, $rval) = @_;

                    # $c->log->debug($c->dumper([ XX => @_[1 .. $#_] ]));

                    # greska u prethodnom koraku
                    $c->ioErr(@_);
                    $sess ||= $rval;

                    # samo za chat test
                    $chatTest = $msg->{_event} eq "chat";
                    if ($chatTest) {
                        return $c->wsSendAllViaRedis("nodeX", $msg, $sess->{id}, $d->begin);
                    }
                    return $c->peerComm($msg, $sess, $d->begin);
                    # my $response = $c->peerComm($msg, $sess) or return;
                    # $c->wsSend($sess ? $sess->{id} : $c->tx, $response);
                },
                sub {
                    my ($d, $err, $rval) = @_;

                    # $c->log->debug($c->dumper([ XX => @_[1 .. $#_] ]));
                    
                    # greska u prethodnom koraku
                    $c->ioErr(@_);
                    
                    return $d->pass if $chatTest or !$rval;
                    $c->wsSend($sess ? $sess->{id} : $c->tx, $rval);
                },
            )
            # javi peeru da je doslo do greske kod zathtjeva
            # ->catch(sub{ $c->render(json => $@) });
            ->catch(sub{
                $errReply->($@, $msg);
            });
        });

    }
    
    # registracija nodeID i sessionID za websocket konekciju
    sub wsRegister {
        my ($c, $node, $sessid) = @_;

        $c->connForWs->{$node}        = $c->tx;
        $c->sessionForConn->{$sessid} = $node;
        $c->redisSubscribtions( subscribe => [$node] );

        # unregister
        return sub {
            # brise se iz evidencije aktivnih nodova
            delete $c->connForWs->{$node};
            delete $c->sessionForConn->{$sessid};
            $c->redisSubscribtions( unsubscribe => [$node] );
        };
    }

    # vrati handle prema nodeID
    sub wsHandle {
        my ($c, $node) = @_;

        return $c->connForWs->{$node};
    }

    # send to browser via ws
    sub wsSend {
        my ($c, $node, $msg) = @_;

        my $connForWs = $c->connForWs;
        # my $type = ref($msg) ? "json" : "text";   
        my $type = "text";
        if (ref($msg)) {
            $type = "json";
            my $event = delete($msg->{_event}) // "UNKNOWN";
            $msg = [$event, $msg];
        }

        my $toSend = { $type => $msg };
        my $refType = ref($node);

        # ako je hash-ref
        if ($refType eq "HASH") {
            # $c->log->debug( $c->dumper($node, [keys $connForWs]) );
            for my $v (values %$node) {
                if (my $ws = $connForWs->{$v}) {
                    $ws->send($toSend);
                }
                else { delete($node->{$v}); }
            }
        }
        # elsif ($refType eq "ARRAY") {
            # for my $v (@$node) {
                # $connForWs->{$v}->send($toSend);
            # }
        # }
        # ako je ws handler (mora biti ispod ostalih ref elsif-ova)
        elsif ($refType) {
            $node->send($toSend);
        }
        # obican string ciji ws handler je u $connForWs
        else {
            # $c->log->debug("Sending ws message to node $node: ". $c->dumper($msg));
            my $v = $connForWs->{$node};
            if ($v) { $v->send($toSend); }
            else { $c->log->error("Nothing to send, node $node passed away"); }
        }
    }

    # salji svima via redis (samo za test)
    sub wsSendAllViaRedis {
        my ($c, $nodeX, $msg, $id, $cb) = @_;

        # my @nodes = values %{$c->sessionForConn};

        $c->iodelay(
            ## gledaj dal je greska nakon svakog redisSend() poziva
            # sub {
                # my ($d, $err, $rval) = @_;

                # # $c->log->debug( $c->dumper($c->tx) );

                # die $err if $err;
                # return $d->pass if !@nodes;
                
                # # run current function again
                # unshift @{$d->remaining}, __SUB__;

                # my $node = shift(@nodes);
                # # for my $node (@nodes) { }
                # #$c->log->info();
                
                # $c->log->debug("wsSendAll: $id -> $node:". $c->dumper($msg));
                # $msg->{_smsid} = delete $msg->{_msid};
                # $c->redisSend($node, $msg, $id, $d->begin);
            # },
            ## gledaj za greske nakon sto su ispucani svi redisSend() pozivi
            sub {
                my ($d, $err) = @_;

                # $c->log->debug( $c->dumper($c->tx) );
                for my $node (values %{$c->sessionForConn}) {
                    #$c->log->info();
                    $c->log->debug("wsSendAll: $id -> $node:". $c->dumper($msg));
                    
                    $msg->{_smsid} = delete $msg->{_msid};
                    $c->redisSend($node, $msg, $id, $d->begin);
                }
            },
            $cb
        );
    }

}

1;
