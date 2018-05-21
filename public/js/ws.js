$(function () {

	$('#msg').focus();
	if (window.LPOLL) { chatlp (); }
	else { chat (); }
});

function chat () {
	"use strict";

	var sessid;

	// url ili funkcija koja vraca url
	var myurl = function () {
		return 'ws'+ window.location.href.replace(/^[^s\W]+|\w+\/?$/g, "") +"ws/"+ (sessid || "new");
	};
	var socket = wsio(myurl);

	// server time
	var serverDate = sdate(socket);

	//
	socket
	// pri uspostavi ws-a
	.on('connect', function(){
		socket.emit("getSession");
	})
	// store sessid, flush queue, enter/subscribe..
	.on('session', function(msg){
		if (msg.sessid) { sessid = msg.sessid; }
		socket.flush();
		// subscribe/enter into 'race1' events
		socket.emit("enter", "vgames.lotto3");
	})
	// specijalni event - za sve poruke
	.on('message', function(msg){
		console.log(msg);
		console.log( {serverDate: serverDate.Date(), "serverDate.getTime": serverDate.getTime() } );
	})
	.on('error', function(err){
		console.log(err);
	})
	.on('NextEvent', function(msg){
		// console.log(msg);
		console.log((new Date()).toISOString(), msg);
	})
	.on('chat', function(msg){
		if (msg.err) {
			// greska, treba ponoviti zahtjev ID res._smsid 
			// (reference:source message id)
			console.log(msg.err);
			return;
		}
		log('[' + msg._snode + '] ' + msg.text); 
	})
	;


	$('#msg').keydown(function (e) {
		if (e.keyCode == 13 && $('#msg').val()) {

			var node = $("#node").val();
			var msg = (!node)
				? JSON.parse( $('#msg').val() )
				: {
					text: $('#msg').val(),
					hms: (new Date).getTime()
				};
			socket.emit(node, msg);
			$('#msg').val('');
		}
	});
}
function chatlp () {
	"use strict";
	// alert(33);
}

function log (text) {
	$('#log').val( $('#log').val() + text + "\n");
}

/* http://stackoverflow.com/a/2117523/223226 */
function UUID () {

    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
        var r = Math.random()*16|0, v = c == 'x' ? r : (r&0x3|0x8);
        return v.toString(16);
    });
}
