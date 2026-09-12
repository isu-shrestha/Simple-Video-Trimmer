/* ============================================================================
   shim.js - ES3 polyfills + a fake DOM, so the REAL app JavaScript extracted
   from SimpleVideoTrimmer.bat can be loaded unmodified under
   `cscript //nologo //E:JScript`.

   Nothing here may know anything about the app's editing model - the point is
   that the code under test is the shipping code, byte for byte.
   ========================================================================= */

/* ---------------------------- ES3 polyfills ------------------------------ */
if (!Array.prototype.map) {
  Array.prototype.map = function (f, self) {
    var r = [], i;
    for (i = 0; i < this.length; i++) r[i] = f.call(self, this[i], i, this);
    return r;
  };
}
if (!Array.prototype.forEach) {
  Array.prototype.forEach = function (f, self) {
    for (var i = 0; i < this.length; i++) f.call(self, this[i], i, this);
  };
}
if (!Array.prototype.filter) {
  Array.prototype.filter = function (f, self) {
    var r = [], i;
    for (i = 0; i < this.length; i++) if (f.call(self, this[i], i, this)) r.push(this[i]);
    return r;
  };
}
if (!Array.prototype.some) {
  Array.prototype.some = function (f, self) {
    for (var i = 0; i < this.length; i++) if (f.call(self, this[i], i, this)) return true;
    return false;
  };
}
if (!Array.prototype.every) {
  Array.prototype.every = function (f, self) {
    for (var i = 0; i < this.length; i++) if (!f.call(self, this[i], i, this)) return false;
    return true;
  };
}
if (!Array.prototype.indexOf) {
  Array.prototype.indexOf = function (x, from) {
    var i = from || 0;
    if (i < 0) i += this.length;
    for (; i < this.length; i++) if (this[i] === x) return i;
    return -1;
  };
}
if (!Array.prototype.reduce) {
  Array.prototype.reduce = function (f, seed) {
    var i = 0, acc;
    if (arguments.length > 1) acc = seed;
    else { if (!this.length) throw new Error("reduce of empty array"); acc = this[i++]; }
    for (; i < this.length; i++) acc = f(acc, this[i], i, this);
    return acc;
  };
}
if (!String.prototype.trim) {
  String.prototype.trim = function () { return this.replace(/^\s+/, "").replace(/\s+$/, ""); };
}
if (!Array.isArray) {
  Array.isArray = function (o) { return Object.prototype.toString.call(o) === "[object Array]"; };
}
if (typeof JSON === "undefined") {
  JSON = {
    stringify: function (o) {
      var t = typeof o, i, k, parts;
      if (o === null) return "null";
      if (t === "number") return isFinite(o) ? String(o) : "null";
      if (t === "boolean") return String(o);
      if (t === "string") {
        return '"' + o.replace(/\\/g, "\\\\").replace(/"/g, '\\"')
                      .replace(/\n/g, "\\n").replace(/\r/g, "\\r").replace(/\t/g, "\\t") + '"';
      }
      if (t === "undefined" || t === "function") return undefined;
      if (Array.isArray(o)) {
        parts = [];
        for (i = 0; i < o.length; i++) {
          var vv = JSON.stringify(o[i]);
          parts.push(vv === undefined ? "null" : vv);
        }
        return "[" + parts.join(",") + "]";
      }
      parts = [];
      for (k in o) {
        if (!Object.prototype.hasOwnProperty.call(o, k)) continue;
        var pv = JSON.stringify(o[k]);
        if (pv !== undefined) parts.push(JSON.stringify(String(k)) + ":" + pv);
      }
      return "{" + parts.join(",") + "}";
    }
  };
}

/* The JScript host predates JSON.parse. Tests use it to read back what the app
   would have POSTed; the only input is a body the app itself just built, so
   eval is enough and nothing in the shipping source relies on it. */
if (typeof JSON !== "undefined" && !JSON.parse) {
  JSON.parse = function (s) { return eval("(" + String(s) + ")"); };
}

/* -------------------------------- output --------------------------------- */
function say(s) { WScript.Echo(String(s)); }

/* ------------------------------- fake DOM -------------------------------- */
/* Only what the app actually touches. Everything is a plain object so tests
   can inspect it (e.g. FAKE.el("tLen").textContent). */

function FakeStyle() {
  this.left = ""; this.width = ""; this.display = ""; this.opacity = "";
  this.transition = ""; this.right = ""; this.backgroundImage = "";
  this.backgroundSize = ""; this.backgroundPosition = "";
}

function FakeClassList(el) {
  this._el = el; this._set = {};
}
FakeClassList.prototype.add = function (c) { this._set[c] = true; };
FakeClassList.prototype.remove = function (c) { delete this._set[c]; };
FakeClassList.prototype.contains = function (c) { return !!this._set[c]; };

function FakeEl(tag, id) {
  this.tagName = String(tag || "DIV").toUpperCase();
  this.id = id || "";
  this.style = new FakeStyle();
  this.className = "";
  this.classList = new FakeClassList(this);
  this.childNodes = [];
  this.firstChild = null;
  this.parentNode = null;
  this.innerHTML = "";
  this.textContent = "";
  this.title = "";
  this.disabled = false;
  this.value = "";
  this.src = "";
  this.onclick = null;
  this.oninput = null;
  this.muted = false;
  this.volume = 1;
  this.paused = true;
  this.currentTime = 0;
  this._attrs = {};
  this._listeners = {};
}
FakeEl.prototype.appendChild = function (c) {
  if (c.parentNode && c.parentNode !== this) c.parentNode.removeChild(c);
  this.childNodes.push(c);
  c.parentNode = this;
  this.firstChild = this.childNodes[0];
  return c;
};
FakeEl.prototype.removeChild = function (c) {
  for (var i = 0; i < this.childNodes.length; i++) {
    if (this.childNodes[i] === c) {
      this.childNodes.splice(i, 1);
      c.parentNode = null;
      break;
    }
  }
  this.firstChild = this.childNodes.length ? this.childNodes[0] : null;
  return c;
};
FakeEl.prototype.setAttribute = function (k, v) { this._attrs[k] = v; if (k === "src") this.src = v; };
FakeEl.prototype.getAttribute = function (k) { return this._attrs.hasOwnProperty(k) ? this._attrs[k] : null; };
FakeEl.prototype.removeAttribute = function (k) { delete this._attrs[k]; if (k === "src") this.src = ""; };
FakeEl.prototype.addEventListener = function (n, fn) {
  if (!this._listeners[n]) this._listeners[n] = [];
  this._listeners[n].push(fn);
};
FakeEl.prototype.removeEventListener = function (n, fn) {
  var a = this._listeners[n]; if (!a) return;
  for (var i = 0; i < a.length; i++) if (a[i] === fn) { a.splice(i, 1); return; }
};
/* tests fire DOM events by hand */
FakeEl.prototype.dispatch = function (n, ev) {
  var a = this._listeners[n]; if (!a) return;
  for (var i = 0; i < a.slice().length; i++) a[i].call(this, ev || { target: this });
};
FakeEl.prototype.getBoundingClientRect = function () {
  return { left: 0, top: 0, width: 1000, height: 40, right: 1000, bottom: 40 };
};
FakeEl.prototype.setPointerCapture = function () { };
FakeEl.prototype.releasePointerCapture = function () { };
FakeEl.prototype.blur = function () { };
FakeEl.prototype.focus = function () { };
/* <video> bits */
FakeEl.prototype.play = function () {
  this.paused = false;
  var self = this;
  return { then: function () { return this; }, "catch": function () { return this; } };
};
FakeEl.prototype.pause = function () { this.paused = true; };
FakeEl.prototype.load = function () { };

function FakeTextNode(text) {
  this.nodeType = 3;
  this.textContent = String(text);
  this.parentNode = null;
}

var FAKE = {
  byId: {},
  created: [],
  el: function (id) {
    if (!this.byId[id]) this.byId[id] = new FakeEl(id === "v" || id === "v2" ? "VIDEO" : "DIV", id);
    return this.byId[id];
  },
  reset: function () { this.created = []; }
};

var document = {
  activeElement: null,
  body: new FakeEl("body", "body"),
  getElementById: function (id) { return FAKE.el(id); },
  createElement: function (tag) { var e = new FakeEl(tag); FAKE.created.push(e); return e; },
  createTextNode: function (t) { return new FakeTextNode(t); },
  addEventListener: function (n, fn) { FAKE.el("#document").addEventListener(n, fn); },
  removeEventListener: function (n, fn) { FAKE.el("#document").removeEventListener(n, fn); },
  dispatch: function (n, ev) { FAKE.el("#document").dispatch(n, ev); }
};

/* the <video> element the app grabs as `v` - pre-created so tests can reach it */
FAKE.el("v");

var window = {
  addEventListener: function (n, fn) { FAKE.el("#window").addEventListener(n, fn); },
  removeEventListener: function (n, fn) { FAKE.el("#window").removeEventListener(n, fn); },
  document: document
};

/* ---------------------------- browser globals ---------------------------- */
/* fetch never settles: no test may depend on a server round trip. Calls are
   recorded so a test can assert what WOULD have been sent. */
var FETCHES = [];
function NeverPromise() { }
NeverPromise.prototype.then = function () { return this; };
NeverPromise.prototype["catch"] = function () { return this; };
function fetch(url, opts) { FETCHES.push({ url: url, opts: opts || null }); return new NeverPromise(); }

/* setTimeout/setInterval: record, never fire. Firing them would make undo and
   skip tests depend on wall-clock ordering. */
var TIMERS = [];
var TIMER_SEQ = 0;
/* A cancelled timer must be inert even when a test fires it by hand out of
   TIMERS - that is exactly what a real event loop does, and without it
   clearTimeout is untestable. */
function makeTimer(fn, ms, repeat) {
  var e = { id: ++TIMER_SEQ, ms: ms, repeat: !!repeat, cancelled: false, raw: fn };
  e.fn = function () { if (!e.cancelled) e.raw(); };
  TIMERS.push(e);
  return e.id;
}
function cancelTimer(id) {
  for (var i = 0; i < TIMERS.length; i++) if (TIMERS[i].id === id) TIMERS[i].cancelled = true;
}
/* animation frames: recorded like timers, fired by hand */
function requestAnimationFrame(fn) { return makeTimer(fn, 16, false); }
function cancelAnimationFrame(id) { cancelTimer(id); }
function setTimeout(fn, ms) { return makeTimer(fn, ms, false); }
function clearTimeout(id) { cancelTimer(id); }
function setInterval(fn, ms) { return makeTimer(fn, ms, true); }
function clearInterval(id) { cancelTimer(id); }

function Image() {
  this.onload = null; this.onerror = null;
  this._src = "";
}
/* JScript has no accessors on function objects; the app only assigns .src and
   never reads it back, so a plain property is enough. */

function confirm(msg) { return false; }
function alert(msg) { }

/* -------------------------- test-side helpers ---------------------------- */
/* Build a track payload shaped like the server's /api/open response. */
var TOKSEQ = 0;
function mkTrack(dur, opts) {
  TOKSEQ++;
  var o = opts || {};
  return {
    ok: true,
    token: o.token || ("tok" + TOKSEQ),
    name: o.name || ("clip" + TOKSEQ + ".mp4"),
    duration: dur,
    width: o.width || 1920,
    height: o.height || 1080,
    fps: o.fps === undefined ? 25 : o.fps,
    sizeText: o.sizeText || "10 MB",
    playable: o.playable === undefined ? true : o.playable,
    hasAudio: o.hasAudio === undefined ? true : o.hasAudio,
    why: o.why || "",
    tiles: o.tiles || 40,
    tileW: o.tileW || 160,
    tileH: o.tileH || 90
  };
}
