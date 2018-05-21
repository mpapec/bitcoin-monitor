// websocket factory
var wsio = (function(){
	"use strict";

	var wsClass = function (myurl) {
		var that = this;
		if (typeof myurl === 'string') {
			myurl = function () { return myurl };
		}
		var url = myurl();

		that.ws = undefined;
		that.connected = false;
		that.reconnect = 3 *1000;
		that.log = undefined;
		// that.log = function(msg) { console.log(msg); };
		that.events = {};
		that.queue = [];

		that.flush = function () {
			if (!that.queue.length || !that.connected) return;

			that.log && that.log(['Flushing message queue!', that.queue]);

			var arr = that.queue;
			that.queue = [];
			for (var i =0; i <arr.length; i++) {
				that.ws.send(arr[i]);
			}
		};
		var _onmessage = function (event) {
			//
			var res = JSON.parse(event.data);

			if (that.events.message) { that.events.message(res); }
			if (that.log) {
				that.log('Message received: '+ url);
				that.log(res);
			}
			if (!Array.isArray(res)) {
				that.log && that.log("Not an array, skipping");
				return;
			}
			for (var i =0; i <res.length; i++) {
				var eventStr = res[i];
				if (typeof eventStr !== 'string') continue;

				var msg = res[++i];
				var callback = that.events[eventStr];

				if (!callback) {
					that.log && that.log("No event handler for "+ eventStr);
					continue;
				}
				callback(msg);
			}
		};

		var nthConnect = 0;
		var _onopen = function () {
			that.log && that.log('Connection opened: '+ url);
			that.connected = true;
			//
			if (that.events.connect) { that.events.connect(nthConnect); }
			nthConnect++;
			// _flushMessageQueue();
			
		};
		var _onclose = function () {
			that.log && that.log('Connection closed: '+ url);
			that.connected = false;

			if (that.reconnect) {
				setTimeout(function(){
					that.log && that.log('Reconnecting: '+ url);
					_start();
				}, that.reconnect);
			}
		};

		var _start = function () {
			//
			that.ws = new WebSocket(myurl());
			that.ws.onmessage = _onmessage;
			that.ws.onopen    = _onopen;
			that.ws.onclose   = _onclose;
		};
		_start();

		//
		that.on = function (eventStr, callback) {
			that.events[eventStr] = callback;
			return that;
		};
		//
		that.emit = function (eventStr, msg) {

			if (eventStr) {
				if (typeof msg !== 'object') { msg = {text: msg}; }
				msg = [ eventStr, msg||{} ];
			}
			var toSend = JSON.stringify(msg);

			if (that.connected) { that.ws.send(toSend); }
			else { that.queue.push(toSend); }
		};

	};

	return function (myurl) {

		return new wsClass(myurl);
	};

})();
