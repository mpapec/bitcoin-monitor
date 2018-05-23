$(function () {

	$('#msg').focus();
	chat ();
});

function chat () {
	"use strict";

	var sessid;

	// url ili funkcija koja vraca url
	var myurl = function () {
        var url = "ws://192.168.192.180:3001/ws/new";
        url = 'ws'+ window.location.href.replace(/^[^s\W]+|\w+\/?$/g, "") +"ws/"+ (sessid || "new");
        console.log(url);
		return url;
	};
	var socket = wsio(myurl);
    // debug
    // socket.log = function(msg) { console.log(msg); };

	// server time
	// var serverDate = sdate(socket);

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
		socket.emit("enter", "bch.block");
		socket.emit("enter", "bch.tx");
	})
	.on('bch.block', function(msg){
        var block = JSON.parse(msg.json).result;
		console.log(block);
        // log('<' + msg.json + '>');
	})
	.on('bch.tx', function(msg){
        var tx = JSON.parse(msg.json).result;
		console.log(tx);
        var values = $.map( tx.vout, function( v, i ) {
            return v.value;
        });

        log('['+ tx.txid +' '+ values.join(", ") +' BCH]');
	})
	.on('error', function(err){
		console.log(err);
	})
	;

}

function log (text) {
       $('#log').val( $('#log').val() + text + "\n");
}


/* http://stackoverflow.com/a/2117523/223226 */
/*
function UUID () {

    return 'xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'.replace(/[xy]/g, function(c) {
        var r = Math.random()*16|0, v = c == 'x' ? r : (r&0x3|0x8);
        return v.toString(16);
    });
}
*/
