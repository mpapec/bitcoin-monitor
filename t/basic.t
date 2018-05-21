#/************************************************************
#
#
# run "carton exec prove" from main folder to run tests
#
#
#************************************************************/
# use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

use Mojo::JSON qw(encode_json decode_json);

use FindBin;
require "$FindBin::Bin/../server.pl";

my $t = Test::Mojo->new; # ('App');

# WebSocket
$t->websocket_ok('/ws/new')
    ->send_ok(encode_json({
        _node   => "wspeer",
        get     => "sessid",
        _msid   => "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
    }))
    ->message_ok
    ->json_message_like('/sessid' => qr/^\w{60,}\z/, "at least 60 chars for sessionID")
    ->finish_ok;

done_testing();









__DATA__
use Mojo::Base -strict;

use Test::More;
use Test::Mojo;

my $t   = Test::Mojo->new('MojoForum');
my $app = $t->app;

$app->db_url('mongodb://localhost/test');
$app->model->storage->db->command('dropDatabase');
$app->users->create({name => "Joel"})->save;

my ($err, $user);
$app->find_user("Joel" => sub {
  my $c = shift;
  ($err, $user) = @_;
});

is $err, undef, 'No error';
isa_ok $user, 'MojoForum::Model::User';
is $user->name, "Joel";

done_testing;

__DATA__
# https://gist.github.com/kraih/1227900
#
#!/usr/bin/env perl
use Mojo::Base -strict;

use utf8;

use Test::More tests => 4;
use Mojolicious::Lite;
use Test::Mojo;

# Tiny echo web service
websocket '/echo' => sub {
  my $self = shift;
  $self->on(message => sub {
    my ($self, $message) = @_;
    $self->send("echo: $message");
  });
};

# Send message and receive echo
my $t = Test::Mojo->new;
$t->websocket_ok('/echo')
  ->send_ok('I x Mojolicious')
  ->message_ok
  ->message_is('echo: I x Mojolicious')
  ->finish_ok;
