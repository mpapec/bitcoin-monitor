#!/usr/bin/env perl

use lib "lib";
# let the framework use the best event loop
use EV;
# http://tempi.re/a-mojolicious-non-blocking-web-service-why-
use Mojolicious::Lite;
use Mojo::JSON qw(decode_json encode_json);
use Mojo::Redis2;
# use Mojo::Pg;
# use Moops; use utf8;
# BEGIN { $ENV{MOJO_USERAGENT_DEBUG} =1; }
# BEGIN { $ENV{MOJO_REDIS_DEBUG} =1; }

use Digest::SHA 'sha256_hex';

use IO::Socket::SSL;
IO::Socket::SSL::set_defaults(
    # ignoriraj serverske certifikate
    # SSL_verify_mode => IO::Socket::SSL::SSL_VERIFY_NONE,
    
    # https://metacpan.org/source/SULLR/IO-Socket-SSL-2.033/lib/IO/Socket/SSL.pod#L1030
    SSL_verify_callback => sub {
        # [
          # 0,
          # '140736362954784',
          # "/C=--/ST=SomeState/L=SomeCity/O=SomeOrganization/OU=SomeOrganizationalUnit/CN=srv.test.com/emailAddress=root\@srv.test.com/C=--/ST=SomeState/L=SomeCity/O=SomeOrganization/OU=SomeOrganizationalUnit/CN=srv.test.com/emailAddress=root\@srv.test.com",
          # "error:00000015:lib(0):func(0):reason(21)",
          # 63405968,
          # 0
        # ]
        # say app->dumper(\@_);
        return !!1;
    },
);


# http://mojolicious.org/perldoc/Mojolicious/Plugin/Config
helper cfg => sub {
    state $CFG = plugin(Config => {file => "server.conf"});
    return $CFG;
};
app->config( hypnotoad => app->cfg->{production} );

# http://mojolicious.org/perldoc/Mojolicious/Plugin/DefaultHelpers
plugin 'DefaultHelpers';
# https://metacpan.org/pod/Mojolicious::Plugin::JSON::XS (C json parser)
plugin 'JSON::XS';
#plugin "SecureCORS";

#
plugin "App::Helpers";
plugin "App::WsKurir";
plugin "App::RedisKurir";
plugin "App::Main";


app->log->info("STARTING server..\n\n");

# http://mojolicious.org/perldoc/Mojolicious/Guides/FAQ#What-does-Your-secret-passphrase-needs-to-be-changed-mean
app->secrets(app->cfg->{secrets});

# https://metacpan.org/pod/Mojo::Pg
# my $pg = Mojo::Pg->new(app->cfg->{"Mojo::Pg"});
# $pg->db->query('select now() as now')->hash->{now},


Mojo::IOLoop->timer(0 => sub{
    app->redis->backend->time;
    app->redisSubscribtions( subscribe => app->cfg->{redisPsubscribe}, pattern =>1 );
    app->redisSubscribtions( subscribe => [ app->cfg->{mojoWorkerRoom} ] );
});


# https://metacpan.org/pod/Mojolicious::Plugin::NYTProf#CONFIGURATION 
# check /nytprof url
plugin NYTProf => {
    nytprof => app->cfg->{profiling},

} if app->cfg->{profiling};


# http://mojolicious.org/perldoc/Mojolicious/Routes/Route#under
# ne treba jer ce nginx staviti svoj http server header prema klijentu
=pod
under sub {
    my ($c) = @_;

    $c->tx->res->headers->server($c->cfg->{Server});
};
=cut

get '/chat' => 'chat';
get '/chatlp' => 'chatlp';

# any '/:path' => [ path => qr/favico/i ] => sub { shift->render(json => {}); };
hook before_dispatch => sub {
    my ($c) = @_;
    $c->render(text => '/-o-/')
        if $c->req->url->path->to_route =~ /favico/;
};

# patch '/getPatch' => sub { };
# options '/getOptions' => sub { };

#/*******************************************************
#
# websocket url
#
#********************************************************/
websocket '/ws/:sessid' => sub {
    my ($c) = @_;

    # disconnect ws after wsTimeout
    $c->inactivity_timeout($c->cfg->{wsTimeout});
    $c->registerWsEvents;
};

get '/payment_info/:addr' => sub {
    my ($c) = @_;

    $c->inactivity_timeout(15*60);

    my $addr = $c->stash("addr");
    # return if lc($addr) =~ /^favico/;

    #TODO+: is addr even in watch list?
    my $k = "check:$addr";
    # $c->log->debug("k : $k");

    my $redis = $c->redisnew;
    $c->iodelay(
        sub {
            my ($d) = @_;

            # valid address should be either in $k or watch hash
            $redis->()
                ->hget("watching:xpub", $addr, $d->begin)
                ->rpoplpush($k, $k, $d->begin)
            ;
        },
        sub {
            my ($d, undef, $isWatched, undef, $utxo) = @_;
            # shift; $c->log->debug($c->dumper(\@_));

            die { err => "no_such_address" } if !$isWatched and !$utxo;

            if ($utxo) {
                $d->pass("", $utxo);
            }
            else {
                $redis->()->brpoplpush($k, $k, 5*60, $d->begin);
            }
            $redis->()->hget("confirmations", $addr, $d->begin);
        },
        # TODO:request node info if confirmation is undef
        sub {
            my ($d, $err, $utxo, undef, $confirmations) = @_;

            $redis->("close");
            my %hash;
            @hash{qw( txid idx value )} = split /:/, ref($utxo) ? '' : $utxo;
            $c->render(json => $err ? $err : {
                #
                %hash,
                # u => $utxo,
                confirmations => $confirmations // 0,
                # x=>\@_
            });
        },
    );

};

get '/new_payment/:xpub' => sub {
    my ($c) = @_;

    my $xpub = $c->stash("xpub");
    my $xpub_sha = sha256_hex($xpub);
    my $addr;

    my $redis = $c->redisnew;

    $c->iodelay(
        sub {
            my ($d) = @_;
            $redis->()->sadd("xpub:all", $xpub, $d->begin);
        },
        sub {
            my ($d, $err, $rval) = @_;
            # new xpub
            $redis->()->lpush("xpub:new", $xpub, $d->begin) if $rval;
            $redis->()->brpop("unused:$xpub", 10, $d->begin);
        },
        sub {
            my ($d, $err, $rval) = @_;
            $rval = pop;
            # $c->log->debug($c->dumper("@_"));
            my $tmp = ref($rval) ? $rval->[1]//"" : "";
            # $d->pass, return if !$tmp;

            if ($tmp =~ s/^err://) { die { err => $tmp }  }
            $addr = $tmp or return $d->pass;

            $redis->()
                ->hset("watching:xpub", $addr, $xpub_sha, $d->begin)
                ->zadd("watching:addr", time(), $addr, $d->begin)
            ;
        },
        sub {
            my ($d, $err, $rval) = @_;
            # $rval = pop;

            $redis->("close");
            $c->render(json => $err ? $err : {
                # xpub => $xpub,
                address => $addr,
                # x=>\@_
            });
        },
    )
    ;
};

get '/__status' => sub {
    my ($c) = @_;

    my $req = {
        request => "activeClients",
    };
    delete $c->mystash->{ $req->{request} };

    my $redis = $c->redis;
    my $onStatusChange;

    $c->delay(
        # prvo stavi u node mbox (list queue)
        sub {
            my ($d, $err) = @_;

            $redis
                ->subscribe([$c->cfg->{mojoWorkerRespondRoom}], $onStatusChange=$d->begin)
        },
        sub {
            my ($d, $err) = @_;
            $redis
                ->publish($c->cfg->{mojoWorkerRoom}, encode_json($req), $d->begin)
            ;
            # pricekaj N sekundi da dodju odgovori
            Mojo::IOLoop->timer(2 => $d->begin);
        },
        sub {
            my ($d) = @_;
            
            # thorw error if there are any
            $c->ioErr(@_);

            $redis->unsubscribe([$c->cfg->{mojoWorkerRespondRoom}], $onStatusChange);
            my $result = {
                me => $$,
                report => delete $c->mystash->{ $req->{request} }
            };
            $c->render(json => $result);
        },
    );
};

# default 404 page
any '*' => sub { my ($c) = @_; $c->render(text => $c->cfg->{Server}) };
any '/' => sub { my ($c) = @_; $c->render(text => $c->cfg->{Server}) };

#/*******************************************************
#
# start event loop
#
#*******************************************************/
app->start;


__DATA__

# samo za long polling
get '/lpoll/session' => sub {
    my ($c) = @_;

    $c->iodelay(
        sub {
            my ($d) = @_;
            $c->sessionStart( isWs =>0, $d->begin );
        },
        # $cb
        sub {
            my ($d, $err, $rval) = @_;
            
            # $c->ioErr(@_);

            $c->render(json => $err||$rval);
        }
    );
};

# provjeri mbox na long polling nacin
get '/lpoll/:sessid/mbox' => sub {
    my ($c) = @_;

    $c->iodelay(
        sub {
            my ($d) = @_;
            $c->sessionCheck( $d->begin );
        },
        sub {
            my ($d, $err, $rval) = @_;

            # die { err => $err } if $err;
            $c->ioErr(@_);
            die { err => "IDONTKNOWYOU" } if !%$rval;

            # wait for N sec for message to arrive in mbox
            $c->getFifoMbox($rval->{wsid}, wait =>120, $d->begin);
        },
        # $cb
        sub {
            my ($d, $err, $rval) = @_;
            # die { err => $err } if $err;
            # $c->ioErr(@_);

            $rval ||= {msg => "EMPTY_MBOX"};
            # imamo poruku!
            $c->render(json => $err||$rval);
        }
    );
};
