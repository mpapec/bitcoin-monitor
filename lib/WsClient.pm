# 
# auto reconnecting ws client class
#
{
package WsClient;

    # "-base" => ne inherita nikoga (base class)
    use Mojo::Base -base;

    use Mojo::UserAgent;
    use Mojo::IOLoop;
    use Mojo::JSON qw();

    # ws url
    has "url";
    # user agent
    has "ua";
    has "uaString" => "Apache-HttpClient/4.2.3 (java 1.8)";
    # hadle za slanje poruka
    has "tx";
    # spojen da|ne
    has "connected";
    # eventi 
    has "events" => sub { return {} };
    has "debug" => 0;

    #

    sub connect {

        my ($self) = @_;

        my $go = sub {
            say "Connecting.." if $self->debug;
            my $ua = Mojo::UserAgent
                ->new
                ->inactivity_timeout(0);

            $self->ua($ua);
            # promjeni user-agent string
            $ua->on(start => sub {
              my ($ua, $tx) = @_;
              $tx->req->headers->user_agent($self->uaString);
            });
            #
            $ua->websocket($self->url, sub{
                $self->_onStatusChange(@_);
            });
        };

        # N-th time connect
        if ($self->ua) {
            say "I'll try in a sec.." if $self->debug;
            Mojo::IOLoop->timer(2 => $go);
        }
        # first time connect
        else {
            $go->();
        }

        return $self;
    };

    sub on {
        my ($self, %events) = @_;
        
        my $e = $self->events;
        # -finish
        for my $event (qw(binary drain frame json message resume text _finish _connect)) {
            next if ref($events{$event}) ne "CODE";
            # next if !exists($events{$event});
            $e->{$event} = $events{$event};
        }

        return $self;
    }

    #
    sub _onStatusChange {
        my ($self, $ua, $tx) = @_;

        my $e = $self->events;

        if (!$tx->is_websocket) {
            my $err = 'WebSocket handshake failed!';

            say  $err if $self->debug;
            $e->{_finish}->(@_, $err) if $e->{_finish};

            return $self->connected(0)->connect;
        }
        $self->connected(1);
        say "Connected!" if $self->debug;
        $e->{_connect}->(@_) if $e->{_connect};

        $self->tx($tx);

        $tx->on(finish => sub {
            my ($tx, $code, $reason) = @_;

            my $err = "WebSocket closed with status $code";
            say $err if $self->debug;
            $e->{_finish}->(@_, $err) if $e->{_finish};

            return $self->connected(0)->connect;
        });
=pod
        $tx->on(json => sub {
            my ($tx, $json) = @_;
            say "WebSocket message: $json" if $self->debug;
            # $tx->finish;
        });
        # $tx->send('Hi!');
=cut

        for my $event (keys %$e) {
            # postavi samo sluzbene evente za Mojo::UserAgent (bez _)
            next if $event =~ /^_/;

            $tx->on($event => $e->{$event});
        }
    }

    sub send {
        my ($self, $msg, $cb) = @_;

        return if !$self->connected;

        if (ref($msg)) {
            $msg = Mojo::JSON::encode_json($msg);
        }

        $self->tx->send($msg, $cb ? $cb : ());
    }
}

1;
