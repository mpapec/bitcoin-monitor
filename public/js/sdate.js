// server date && sync
var sdate = (function(){
	"use strict";

	// http://stackoverflow.com/a/15785110/223226
	var dateClass = function (socket) {
		var that = this;

		that.diffMsec = 0;
		that.syncEvery = 5*60 *1000;
		that.synced = false;

/*
		var clientTimestamp = (new Date()).getTime();
		$.getJSON('http://yourhost.com/getdatetimejson/?ct='+clientTimestamp, function( data ) {
			var nowTimeStamp = (new Date()).getTime();
			var serverClientResponseDiffTime = nowTimeStamp - data.serverTimestamp;
			var responseTime = (data.diff - nowTimeStamp + clientTimestamp - serverClientResponseDiffTime)/2;

			var syncedServerTime = new Date((new Date()).getTime() + (serverClientResponseDiffTime - responseTime));
			alert(syncedServerTime);
		});
*/
		var clientTimestamp;

		//
		socket.on('__sync', function(data) {
			var nowTimeStamp = (new Date()).getTime();
			var serverClientResponseDiffTime = nowTimeStamp - data.serverTimestamp;
			var responseTime = (data.diff - nowTimeStamp + clientTimestamp - serverClientResponseDiffTime)/2;

			that.diffMsec = serverClientResponseDiffTime - responseTime;
			that.synced = true;
		});

		var _sync = function() {
			clientTimestamp = (new Date()).getTime();
			socket.emit("__sync", clientTimestamp);
		};
		_sync();
		setInterval(_sync, that.syncEvery);
		
		that.diff = function () {
			//
			return that.synced ? that.diffMsec : false;
		};
		that.getTime = function () {
			//
			return that.synced ? ((new Date()).getTime() + that.diffMsec *1) : false;
		};
		that.Date = function () {
			//
			return that.synced ? new Date(that.getTime()) : false;
		};

	};

	return function (socket) {

		return new dateClass(socket);
	};

})();
