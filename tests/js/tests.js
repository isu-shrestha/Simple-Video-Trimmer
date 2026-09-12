/* ============================================================================
   tests.js - headless regression suite for the client-side JavaScript in
   SimpleVideoTrimmer.bat.

   Loaded AFTER shim.js and the app source, in one global scope, so every test
   drives the real TR / recalc / segments / keptParts machinery directly.

   Tests whose name starts with [REGRESSION] pin a defect that adversarial
   testing found and that has since been fixed. They assert the CORRECT
   behaviour, so a failure means the bug came back. Do not "fix" one by
   relaxing its assertion.
   ========================================================================= */

var PASSED = 0, FAILED = 0, FAILED_KNOWN = 0, CURRENT = "", PROBLEMS = [];

function test(name, fn) {
  CURRENT = name;
  var err = null;
  try { fn(); } catch (e) { err = (e && e.message) ? e.message : String(e); }
  if (err === null) {
    PASSED++;
    say("PASS  " + name);
  } else {
    FAILED++;
    if (name.indexOf("[REGRESSION]") === 0) FAILED_KNOWN++;
    say("FAIL  " + name);
    say("        " + err);
    PROBLEMS.push(name + "\n        " + err);
  }
}

function fail(msg) { throw new Error(msg); }
function ok(cond, msg) { if (!cond) fail(msg || "expected truthy"); }
function eq(actual, expected, msg) {
  if (actual !== expected) fail((msg ? msg + ": " : "") + "expected " + expected + ", got " + actual);
}
function near(actual, expected, tol, msg) {
  if (!(Math.abs(actual - expected) <= (tol === undefined ? 1e-9 : tol)))
    fail((msg ? msg + ": " : "") + "expected ~" + expected + " (tol " + tol + "), got " + actual);
}
function eqJson(actual, expected, msg) {
  var a = JSON.stringify(actual), b = JSON.stringify(expected);
  if (a !== b) fail((msg ? msg + ": " : "") + "\n          expected " + b + "\n          actual   " + a);
}

/* --------------------------- state helpers ------------------------------- */
/* The app is one big module of globals; reset every one a test can observe. */
function reset() {
  clearProgram();
  clearSoundtrack(); userMuted = false; applyMute();
  FAKE.el("snd").paused = true; FAKE.el("snd").currentTime = 0;
  hist = [];
  mode = "video"; vOk = true;
  selPlay = false; skipGuardUntil = 0; restarting = false;
  playStart = 0; dragging = null; saving = false;
  TOKSEQ = 0;
  TIMERS = []; FETCHES = [];
  var vEl = FAKE.el("v");
  vEl.paused = true; vEl.currentTime = 0; vEl.style.display = "block";
  var els = [vEl, FAKE.el("v2")];
  for (var i = 0; i < els.length; i++) {
    els[i].ended = false; els[i].readyState = 0; els[i]._key = ""; els[i]._seekTo = -1;
    els[i].style.visibility = "";
  }
  FAKE.el("v2").paused = true; FAKE.el("v2").style.display = "none";
}
function addTracks() {
  for (var i = 0; i < arguments.length; i++) {
    var a = arguments[i];
    if (typeof a === "number") acceptTrack(mkTrack(a));
    else acceptTrack(mkTrack(a[0], { token: a[1], fps: a[2] }));
  }
  metaLanded();
}
/* the active player's file finished loading, as the browser would report it */
function metaLanded() { v.dispatch("loadedmetadata"); }
/* compact readable view of segments(): [start, end, "k"|"D"] */
function segView() {
  var s = segments(), o = [];
  for (var i = 0; i < s.length; i++) o.push([s[i].s, s[i].e, s[i].del ? "D" : "k"]);
  return o;
}
function partsSum() {
  var kp = keptParts(), t = 0;
  for (var i = 0; i < kp.length; i++) t += kp[i].e - kp[i].s;
  return t;
}
/* select the section containing t, then run Delete/Restore */
function pickAndDelete(t) { selSeg = segAt(t); doDelete(); }
function clickReset() { FAKE.el("bReset").onclick(); }
function pressKey(key, ctrl) {
  document.dispatch("keydown", {
    target: { tagName: "BODY" }, key: key, ctrlKey: !!ctrl,
    altKey: false, metaKey: false, shiftKey: false, preventDefault: function () { }
  });
}

say("");
say("Simple Video Trimmer - JavaScript regression suite");
say("==================================================");
say("");
say("--- single-track editing ---");

test("split at the playhead makes a cut and two sections", function () {
  reset(); addTracks(10);
  eq(segments().length, 1, "one section before the split");
  PH = 4; doSplit();
  eqJson(TR[0].cuts, [4], "the cut is stored in the track's own source time");
  eqJson(cutsP, [4], "and mirrored into program time");
  eqJson(segView(), [[0, 4, "k"], [4, 10, "k"]]);
});

test("split is refused on an existing cut", function () {
  reset(); addTracks(10);
  PH = 4; doSplit();
  eq(canSplitAt(4), false, "canSplitAt on the cut");
  PH = 4; doSplit();
  eqJson(TR[0].cuts, [4], "a second split at the same spot must be a no-op");
});

test("split is refused at 0 and at D", function () {
  reset(); addTracks(10);
  eq(canSplitAt(0), false, "at 0");
  eq(canSplitAt(D), false, "at D");
  eq(canSplitAt(0.001), false, "inside one frame of 0");
  eq(canSplitAt(D - 0.001), false, "inside one frame of D");
  PH = 0; doSplit(); PH = D; doSplit();
  eq(TR[0].cuts.length, 0, "no cut may be created at either end");
});

test("split is refused within one frame of an existing cut", function () {
  reset(); addTracks([10, "T1", 25]);          // frameEps = max(0.02, 0.5/25) = 0.02
  PH = 4; doSplit();
  eq(canSplitAt(4.01), false, "10ms away - inside a frame");
  eq(canSplitAt(4.03), true, "30ms away - a distinct frame");
});

test("delete a middle section", function () {
  reset(); addTracks(12);
  PH = 3; doSplit(); PH = 6; doSplit();
  pickAndDelete(4.5);
  eqJson(segView(), [[0, 3, "k"], [3, 6, "D"], [6, 12, "k"]]);
  eqJson(TR[0].dels, [[3, 6]], "stored in the track's source time");
  eqJson(delsP, [[3, 6]], "and in program time");
  near(outLen(), 9, 1e-9, "output length closes the hole up");
});

test("restore a deleted section", function () {
  reset(); addTracks(12);
  PH = 3; doSplit(); PH = 6; doSplit();
  pickAndDelete(4.5);
  pickAndDelete(4.5);                           // second Delete press = Restore
  eqJson(segView(), [[0, 3, "k"], [3, 6, "k"], [6, 12, "k"]]);
  eqJson(TR[0].dels, [], "the range is gone from the track, not just hidden");
  near(outLen(), 12, 1e-9);
});

test("deletions survive a later split elsewhere", function () {
  reset(); addTracks(12);
  PH = 3; doSplit(); PH = 6; doSplit();
  pickAndDelete(4.5);
  PH = 9; doSplit();                            // split well away from the hole
  eqJson(segView(), [[0, 3, "k"], [3, 6, "D"], [6, 9, "k"], [9, 12, "k"]]);
  eqJson(TR[0].dels, [[3, 6]], "the deleted RANGE must not be remapped by a new cut");
});

test("splitting inside a deleted section leaves both halves deleted", function () {
  reset(); addTracks(12);
  PH = 3; doSplit(); PH = 9; doSplit();
  pickAndDelete(6);                             // delete [3,9]
  eq(canSplitAt(6), true, "a deleted section is still splittable");
  PH = 6; doSplit();
  eqJson(segView(), [[0, 3, "k"], [3, 6, "D"], [6, 9, "D"], [9, 12, "k"]]);
  eqJson(TR[0].dels, [[3, 9]], "one range, not two");
  near(outLen(), 6, 1e-9);
});

test("adjacent deletions merge into one range", function () {
  reset(); addTracks(12);
  PH = 3; doSplit(); PH = 6; doSplit(); PH = 9; doSplit();
  pickAndDelete(4.5);
  pickAndDelete(7.5);
  eqJson(TR[0].dels, [[3, 9]], "normTrackDels must coalesce them");
  eqJson(delsP, [[3, 9]]);
  near(outLen(), 6, 1e-9);
});

test("the last surviving section cannot be deleted", function () {
  reset(); addTracks(10);
  PH = 5; doSplit();
  pickAndDelete(2.5);
  eqJson(segView(), [[0, 5, "D"], [5, 10, "k"]]);
  pickAndDelete(7.5);                           // would leave nothing
  eqJson(segView(), [[0, 5, "D"], [5, 10, "k"]], "the second delete must be refused");
  near(outLen(), 5, 1e-9);
});

test("undo of a split", function () {
  reset(); addTracks(10);
  PH = 4; doSplit();
  eq(hist.length, 2, "acceptTrack + doSplit each snapshot");
  doUndo();
  eqJson(TR[0].cuts, []);
  eqJson(segView(), [[0, 10, "k"]]);
});

test("undo of a delete", function () {
  reset(); addTracks(10);
  PH = 4; doSplit();
  pickAndDelete(2);
  eqJson(TR[0].dels, [[0, 4]]);
  doUndo();
  eqJson(TR[0].dels, [], "the deletion is gone");
  eqJson(TR[0].cuts, [4], "but the split it was made against survives");
});

test("undo of a split does not disturb trim handles moved since", function () {
  reset(); addTracks(10);
  PH = 4; doSplit();
  setA(2, true); setB(8, true);
  doUndo();
  near(A, 2, 1e-9, "A"); near(B, 8, 1e-9, "B");
});

test("Reset clears every cut and deletion and reselects the whole program", function () {
  reset(); addTracks([10, "T1"], [5, "T2"]);
  PH = 4; doSplit();
  pickAndDelete(2);
  setA(1, true); setB(12, true);
  clickReset();
  eqJson(TR[0].cuts, []); eqJson(TR[0].dels, []);
  eqJson(segView(), [[0, 10, "k"], [10, 15, "k"]], "only the join is left");
  near(A, 0, 1e-9, "A"); near(B, D, 1e-9, "B");
  eq(selSeg, -1);
  near(outLen(), 15, 1e-9);
});

test("undo of Reset brings back cuts, deletions and the trim range", function () {
  reset(); addTracks([10, "T1"], [5, "T2"]);
  PH = 4; doSplit();
  pickAndDelete(2);
  setA(1, true); setB(12, true);
  clickReset();
  doUndo();
  eqJson(TR[0].cuts, [4]); eqJson(TR[0].dels, [[0, 4]]);
  near(A, 1, 1e-9, "A"); near(B, 12, 1e-9, "B");
});

test("undo past the start is a harmless no-op", function () {
  reset(); addTracks(10);
  PH = 4; doSplit();
  for (var i = 0; i < 8; i++) doUndo();
  eq(TR.length, 0); eq(D, 0); eq(M, null); eq(cur, -1);
  eq(hist.length, 0);
  eqJson(segView(), []);
});

say("");
say("--- multi-track program time ---");

test("trackOff / trackAt / toLocal round-trip", function () {
  reset(); addTracks([5, "T1"], [3, "T2"], [2, "T3"]);
  near(trackOff(0), 0); near(trackOff(1), 5); near(trackOff(2), 8); near(trackOff(3), 10);
  var probe = [0, 1, 4.9, 5.1, 7.9, 8.1, 9.9];
  for (var i = 0; i < probe.length; i++) {
    var t = probe[i], L = toLocal(t);
    near(trackOff(L.i) + L.t, t, 1e-9, "round-trip at " + t);
  }
});

test("trackAt at exact boundaries, 0, D and beyond", function () {
  reset(); addTracks([5, "T1"], [3, "T2"], [2, "T3"]);
  eq(trackAt(0), 0, "t=0");
  eq(trackAt(4.999), 0, "just before the first join");
  eq(trackAt(5), 1, "a boundary belongs to the track that STARTS there");
  eq(trackAt(7.999), 1);
  eq(trackAt(8), 2, "second join");
  eq(trackAt(D), 2, "t=D clamps into the last track");
  eq(trackAt(1e9), 2, "far past the end clamps too");
  eq(trackAt(-1), 0, "negative clamps to the first track");
  eqJson(toLocal(5), { i: 1, t: 0 });
  eqJson(toLocal(D), { i: 2, t: 2 });
});

test("trackAt returns -1 and toLocal null with no tracks", function () {
  reset();
  eq(trackAt(0), -1);
  eq(toLocal(0), null);
  eqJson(segView(), []);
});

test("every join shows up in cutsP and can never be split again", function () {
  reset(); addTracks([5, "T1"], [3, "T2"], [2, "T3"]);
  eqJson(cutsP, [5, 8], "the two joins");
  eq(canSplitAt(5), false, "a join is already a boundary");
  eq(canSplitAt(8), false);
  PH = 5; doSplit();
  eq(TR[1].cuts.length, 0, "no cut may be added on top of a join");
});

test("no section ever spans two tracks", function () {
  reset(); addTracks([5, "T1"], [3, "T2"], [2, "T3"]);
  PH = 2; doSplit(); PH = 6.5; doSplit(); PH = 9; doSplit();
  var sg = segments();
  for (var i = 0; i < sg.length; i++) {
    var a = trackAt(sg[i].s + 1e-6), b = trackAt(sg[i].e - 1e-6);
    eq(a, b, "section " + i + " [" + sg[i].s + "," + sg[i].e + "] straddles a join");
  }
});

test("keptParts maps each section back to the right track and source range", function () {
  reset(); addTracks([6, "T1"], [4, "T2"]);
  PH = 2; doSplit();                            // T1 local cut at 2
  PH = 8; doSplit();                            // T2 local cut at 2
  eqJson(keptParts(), [
    { t: "T1", s: 0, e: 2 }, { t: "T1", s: 2, e: 6 },
    { t: "T2", s: 0, e: 2 }, { t: "T2", s: 2, e: 4 }
  ]);
});

test("outLen equals the summed length of keptParts", function () {
  reset(); addTracks([6, "T1"], [4, "T2"], [5, "T3"]);
  PH = 2; doSplit(); PH = 12; doSplit();
  pickAndDelete(1);
  setA(0.5, true); setB(13.5, true);
  near(partsSum(), outLen(), 1e-5, "sum of exported parts vs the reported clip length");
});

test("reorder carries a track's cuts and deletions with it", function () {
  reset(); addTracks([5, "T1"], [3, "T2"]);
  PH = 2; doSplit();
  pickAndDelete(1);                             // delete T1's [0,2]
  eqJson(segView(), [[0, 2, "D"], [2, 5, "k"], [5, 8, "k"]]);
  moveTrack(0, 1);                              // T1 now plays second
  eqJson(segView(), [[0, 3, "k"], [3, 5, "D"], [5, 8, "k"]],
    "the hole must follow T1 to its new position");
  eqJson(TR[1].cuts, [2], "cuts stay in T1's own source time");
  eqJson(TR[1].dels, [[0, 2]]);
  eqJson(keptParts(), [{ t: "T2", s: 0, e: 3 }, { t: "T1", s: 2, e: 5 }]);
});

test("moveTrack refuses to run off either end", function () {
  reset(); addTracks([5, "T1"], [3, "T2"]);
  var h = hist.length;
  moveTrack(0, -1); moveTrack(1, 1);
  eq(TR[0].token, "T1"); eq(TR[1].token, "T2");
  eq(hist.length, h, "a refused move must not push an undo entry");
});

test("removing a middle track keeps the other tracks' edits correct", function () {
  reset(); addTracks([6, "T1"], [4, "T2"], [6, "T3"]);
  PH = 2; doSplit(); pickAndDelete(1);          // T1: cut 2, del [0,2]
  PH = 13; doSplit(); pickAndDelete(14);        // T3: cut 3, del [3,6]
  eqJson(segView(), [[0, 2, "D"], [2, 6, "k"], [6, 10, "k"], [10, 13, "k"], [13, 16, "D"]]);
  removeTrack(1);
  eq(D, 12);
  eqJson(TR[0].dels, [[0, 2]], "T1 untouched");
  eqJson(TR[1].dels, [[3, 6]], "T3 untouched");
  eqJson(segView(), [[0, 2, "D"], [2, 6, "k"], [6, 9, "k"], [9, 12, "D"]]);
  eqJson(keptParts(), [{ t: "T1", s: 2, e: 6 }, { t: "T3", s: 0, e: 3 }]);
});

test("removing the last track clears the whole program", function () {
  reset(); addTracks([5, "T1"]);
  PH = 2; doSplit();
  removeTrack(0);
  eq(TR.length, 0); eq(D, 0); eq(cur, -1); eq(M, null);
  eq(PH, 0); eq(A, 0); eq(B, 0); eq(selSeg, -1);
  eqJson(cutsP, []); eqJson(delsP, []);
  eq(FAKE.el("empty").style.display, "block", "the empty-state panel comes back");
  eq(FAKE.el("bSave").disabled, true, "Save is switched off");
});

test("removeTrack ignores an out-of-range index", function () {
  reset(); addTracks([5, "T1"], [3, "T2"]);
  var h = hist.length;
  removeTrack(-1); removeTrack(2); removeTrack(99);
  eq(TR.length, 2); eq(hist.length, h);
});

test("undo restores an added track", function () {
  reset(); addTracks([5, "T1"]);
  PH = 2; doSplit();
  acceptTrack(mkTrack(3, { token: "T2" }));
  eq(TR.length, 2); eq(D, 8);
  doUndo();
  eq(TR.length, 1); eq(D, 5);
  eq(TR[0].token, "T1");
  eqJson(TR[0].cuts, [2], "the earlier split is still there");
});

test("undo restores a removed track, in place, with its edits", function () {
  reset(); addTracks([6, "T1"], [4, "T2"], [5, "T3"]);
  PH = 8; doSplit();                            // T2 local cut at 2
  removeTrack(1);
  eq(TR.length, 2); eq(D, 11);
  doUndo();
  eq(TR.length, 3);
  eq(TR[1].token, "T2", "restored at its original index");
  eqJson(TR[1].cuts, [2], "with its cut");
  eq(D, 15);
});

test("undo restores a reorder", function () {
  reset(); addTracks([5, "T1"], [3, "T2"], [2, "T3"]);
  moveTrack(0, 1);
  eq(TR[0].token, "T2");
  doUndo();
  eqJson([TR[0].token, TR[1].token, TR[2].token], ["T1", "T2", "T3"]);
});

test("cur and M stay valid through interleaved edits and a full undo unwind", function () {
  reset();
  addTracks([6, "T1"], [4, "T2"]);
  PH = 2; doSplit();
  pickAndDelete(1);
  acceptTrack(mkTrack(2, { token: "T3" }));
  moveTrack(2, -1);
  PH = 9; doSplit();
  removeTrack(0);
  var guard = 0;
  while (hist.length && guard++ < 40) {
    doUndo();
    if (TR.length) {
      ok(cur >= 0 && cur < TR.length, "cur out of range: " + cur + " of " + TR.length);
      ok(M !== null, "M is null while tracks exist");
      ok(TR.indexOf(M) >= 0, "M points at a track that is no longer in TR");
      eq(TR.indexOf(M), cur, "cur and M disagree");
    } else {
      eq(cur, -1); eq(M, null);
    }
  }
  eq(TR.length, 0, "the unwind reaches the empty program");
});

test("A/B trim spanning a join splits into one part per track", function () {
  reset(); addTracks([5, "T1"], [5, "T2"]);
  setA(2, true); setB(7, true);
  eqJson(keptRanges(), [[2, 7]], "program time is one continuous run");
  eqJson(keptParts(), [{ t: "T1", s: 2, e: 5 }, { t: "T2", s: 0, e: 2 }],
    "but export must stay split per track");
  near(outLen(), 5, 1e-9);
  near(partsSum(), 5, 1e-6);
});

test("A exactly on a join keeps only the second track", function () {
  reset(); addTracks([5, "T1"], [5, "T2"]);
  setA(5, true); setB(10, true);
  eqJson(keptParts(), [{ t: "T2", s: 0, e: 5 }]);
  near(outLen(), 5, 1e-9);
});

test("B exactly on a join keeps only the first track", function () {
  reset(); addTracks([5, "T1"], [5, "T2"]);
  setA(0, true); setB(5, true);
  eqJson(keptParts(), [{ t: "T1", s: 0, e: 5 }]);
  near(outLen(), 5, 1e-9);
});

test("A and B can never cross", function () {
  reset(); addTracks(10);
  setA(3, true); setB(3, true);
  ok(B >= A + MIN_LEN - 1e-9, "setB must be floored at A + MIN_LEN, got A=" + A + " B=" + B);
  setB(8, true); setA(9, true);
  ok(A <= B - MIN_LEN + 1e-9, "setA must be capped at B - MIN_LEN, got A=" + A + " B=" + B);
  setA(-5, true); near(A, 0, 1e-9, "A clamps at 0");
  setB(1e6, true); near(B, D, 1e-9, "B clamps at D");
});

test("a selection that ran to the end grows over a newly added track", function () {
  reset(); addTracks([10, "T1"]);
  near(B, 10, 1e-9);
  acceptTrack(mkTrack(4, { token: "T2" }));
  near(B, 14, 1e-9, "B follows D when it was already at the end");
});

test("a shortened selection is left alone when a track is added", function () {
  reset(); addTracks([10, "T1"]);
  setB(6, true);
  acceptTrack(mkTrack(4, { token: "T2" }));
  near(B, 6, 1e-9, "B must not jump to the new end");
  near(D, 14, 1e-9);
});

test("deletions either side of a join merge in delsP but stay separate per track", function () {
  reset(); addTracks([5, "T1"], [5, "T2"]);
  PH = 4; doSplit(); PH = 6; doSplit();
  pickAndDelete(4.5);                           // T1's tail
  pickAndDelete(5.5);                           // T2's head
  eqJson(delsP, [[4, 6]], "program view is one hole so playback skips it in one jump");
  eqJson(TR[0].dels, [[4, 5]], "but T1 keeps its own range...");
  eqJson(TR[1].dels, [[0, 1]], "...and T2 keeps its own");
  eqJson(keptParts(), [{ t: "T1", s: 0, e: 4 }, { t: "T2", s: 1, e: 5 }]);
  near(outLen(), 8, 1e-9);
});

test("restoring one side of a merged cross-join hole leaves the other deleted", function () {
  reset(); addTracks([5, "T1"], [5, "T2"]);
  PH = 4; doSplit(); PH = 6; doSplit();
  pickAndDelete(4.5); pickAndDelete(5.5);
  pickAndDelete(4.5);                           // restore T1's half only
  eqJson(TR[0].dels, []);
  eqJson(TR[1].dels, [[0, 1]]);
  eqJson(segView(), [[0, 4, "k"], [4, 5, "k"], [5, 6, "D"], [6, 10, "k"]]);
});

test("a whole track can be deleted and restored", function () {
  reset(); addTracks([5, "T1"], [5, "T2"]);
  pickAndDelete(2.5);
  eqJson(TR[0].dels, [[0, 5]], "the deletion spans exactly the track");
  eqJson(keptParts(), [{ t: "T2", s: 0, e: 5 }]);
  pickAndDelete(2.5);
  eqJson(TR[0].dels, []);
  eqJson(keptParts(), [{ t: "T1", s: 0, e: 5 }, { t: "T2", s: 0, e: 5 }]);
});

test("save() posts the track order and the parts in play order", function () {
  reset(); addTracks([6, "T1"], [4, "T2"]);
  PH = 2; doSplit();
  pickAndDelete(1);
  FETCHES = [];
  save();
  ok(FETCHES.length > 0, "save() must POST");
  var last = FETCHES[FETCHES.length - 1];
  ok(last.url.indexOf("/api/save") === 0, "url: " + last.url);
  eq(last.opts.method, "POST");
  eq(last.opts.body,
    '{"tokens":["T1","T2"],"parts":[{"t":"T1","s":2,"e":6},{"t":"T2","s":0,"e":4}]}');
});

say("");
say("--- floating point and awkward durations ---");

test("33 tracks of 0.1s: offsets stay consistent and no part is empty", function () {
  reset();
  for (var i = 0; i < 33; i++) acceptTrack(mkTrack(0.1, { token: "K" + i }));
  eq(TR.length, 33);
  eq(cutsP.length, 32, "one join per boundary");
  eq(segments().length, 33, "no boundary collapses under EPS");
  /* every join must sit exactly on the offset trackAt/keptParts computes,
     otherwise a section would map to the neighbouring clip */
  for (i = 1; i < 33; i++) eq(cutsP[i - 1], trackOff(i), "join " + i + " vs trackOff");
  var kp = keptParts();
  eq(kp.length, 33);
  for (i = 0; i < 33; i++) {
    eq(kp[i].t, TR[i].token, "part " + i + " maps to the wrong track");
    ok(kp[i].e > kp[i].s, "part " + i + " is empty: " + JSON.stringify(kp[i]));
    near(kp[i].e - kp[i].s, 0.1, 1e-6, "part " + i + " length");
  }
  near(partsSum(), outLen(), 1e-4, "accumulated rounding must stay under a tenth of a ms");
  near(D, 3.3, 1e-9, "D");
});

test("33 tracks of 0.1s: every boundary lands in the expected track", function () {
  reset();
  for (var i = 0; i < 33; i++) acceptTrack(mkTrack(0.1, { token: "K" + i }));
  for (i = 0; i < 33; i++) {
    eq(trackAt(trackOff(i)), i, "the start of track " + i);
    eq(trackAt(trackOff(i) + 0.05), i, "the middle of track " + i);
  }
  eq(trackAt(D), 32, "t=D");
});

test("durations of 1/3 keep trackOff and recalc in step", function () {
  reset();
  for (var i = 0; i < 7; i++) acceptTrack(mkTrack(1 / 3, { token: "Q" + i }));
  near(D, 7 / 3, 1e-12, "D");
  for (i = 0; i < 7; i++) near(trackOff(i), i / 3, 1e-12, "trackOff(" + i + ")");
  var kp = keptParts();
  eq(kp.length, 7);
  for (i = 0; i < 7; i++) {
    eq(kp[i].t, "Q" + i);
    near(kp[i].e - kp[i].s, 1 / 3, 1e-5, "part " + i);
  }
  near(partsSum(), outLen(), 1e-4);
});

test("a long chain of splits never produces an out-of-order or empty part", function () {
  reset(); addTracks([37.123, "T1"], [11.007, "T2"], [3.3, "T3"]);
  for (var i = 1; i < 60; i++) { PH = i * 0.851; if (canSplitAt(PH)) doSplit(); }
  var kp = keptParts(), prevTok = null, prevEnd = -1;
  ok(kp.length > 20, "expected plenty of parts, got " + kp.length);
  for (i = 0; i < kp.length; i++) {
    ok(kp[i].e > kp[i].s, "empty part " + i + ": " + JSON.stringify(kp[i]));
    if (kp[i].t === prevTok) ok(kp[i].s >= prevEnd - 1e-6, "part " + i + " runs backwards inside a track");
    prevTok = kp[i].t; prevEnd = kp[i].e;
  }
  near(partsSum(), outLen(), 1e-3);
});

say("");
say("--- skip logic ---");

test("delEndAt boundaries", function () {
  reset(); addTracks(10);
  PH = 3; doSplit(); PH = 6; doSplit();
  pickAndDelete(4.5);                           // hole [3,6]
  eq(delEndAt(2.999), -1, "just before the hole");
  eq(delEndAt(3), 6, "the very first instant of the hole still needs a skip");
  eq(delEndAt(4.5), 6, "inside");
  eq(delEndAt(5.999), 6, "just inside the far edge");
  eq(delEndAt(6), -1, "the far edge itself is kept footage");
  eq(delEndAt(9), -1, "past the hole");
});

test("skipIfDeleted diverts the playhead exactly once", function () {
  reset(); addTracks(10);
  PH = 3; doSplit(); PH = 6; doSplit();
  pickAndDelete(4.5);
  seek(1); skipGuardUntil = 0;
  PH = 3.5;
  eq(skipIfDeleted(), true, "the first crossing must divert");
  near(PH, 6, 1e-9, "playhead lands on the far edge");
  near(skipGuardUntil, 6, 1e-9, "and arms the guard");
  eq(skipIfDeleted(), false, "a second call at the far edge must not divert again");
});

test("skipGuardUntil survives a stream rewind to a keyframe before the join", function () {
  reset(); addTracks(10);
  PH = 3; doSplit(); PH = 6; doSplit();
  pickAndDelete(4.5);
  seek(1); skipGuardUntil = 0;
  PH = 3.5; skipIfDeleted();
  /* the remuxed stream can only start on a keyframe, so it replays footage
     from before the hole - that must NOT retrigger the same jump */
  PH = 3.2;
  eq(skipIfDeleted(), false, "guard held");
  near(PH, 3.2, 1e-9, "and the playhead was left alone");
  near(skipGuardUntil, 6, 1e-9, "guard still armed");
  PH = 2.0;
  eq(skipIfDeleted(), false, "still held even further back");
  PH = 6.05;
  eq(skipIfDeleted(), false, "past the hole - nothing to do");
  eq(skipGuardUntil, 0, "and the guard is disarmed");
});

test("skipIfDeleted pauses instead of looping when the hole runs to the end", function () {
  reset(); addTracks(10);
  PH = 7; doSplit();
  pickAndDelete(8.5);                           // hole [7,10] = the tail
  var vEl = FAKE.el("v");
  vEl.paused = false;
  skipGuardUntil = 0; PH = 8;
  eq(skipIfDeleted(), true);
  near(PH, 10, 1e-9, "the playhead parks on D rather than looping inside the hole");
  eq(vEl.paused, true, "playback stopped rather than skipping past D");
  eq(selPlay, false);
  eq(skipGuardUntil, 0, "the guard is left disarmed");
  eq(skipIfDeleted(), false, "and a further tick cannot restart the skip");
});

test("skipIfDeleted is inert with no deletions and with no track", function () {
  reset(); addTracks(10);
  PH = 5;
  eq(skipIfDeleted(), false, "no deletions");
  reset();
  eq(skipIfDeleted(), false, "no tracks");
});

test("the timeupdate handler drives the skip end to end", function () {
  reset(); addTracks(10);
  PH = 3; doSplit(); PH = 6; doSplit();
  pickAndDelete(4.5);
  seek(2);
  var vEl = FAKE.el("v");
  vEl.paused = false; vEl.style.display = "block";
  vEl.currentTime = 3.5; vEl.dispatch("timeupdate");
  near(PH, 6, 1e-9, "diverted out of the hole");
  vEl.currentTime = 3.2; vEl.dispatch("timeupdate");
  near(PH, 3.2, 1e-9, "a rewind is reported but not re-diverted");
  vEl.currentTime = 6.1; vEl.dispatch("timeupdate");
  near(PH, 6.1, 1e-9);
  eq(skipGuardUntil, 0);
});

test("the ended handler steps onto the next track and stops on the last", function () {
  reset(); addTracks([6, "T1"], [4, "T2"]);
  seek(0);
  eq(cur, 0); eq(M.token, "T1");
  FAKE.el("v").dispatch("ended");
  eq(cur, 1, "crossed the join"); eq(M.token, "T2");
  near(PH, 6, 1e-9);
  FAKE.el("v").dispatch("ended");
  eq(cur, 1, "there is nowhere further to go");
});

say("");
say("--- timeline interaction ---");

test("clicking the timeline moves the playhead and picks the section under it", function () {
  reset(); addTracks([10, "T1"], [10, "T2"]);   // rect width 1000 -> 50 px per second
  PH = 4; doSplit();
  var tl = FAKE.el("tl");
  tl.dispatch("pointerdown", { target: tl, clientX: 350, pointerId: 1, preventDefault: function () { } });
  near(PH, 7, 1e-9, "playhead");
  eq(selSeg, 1, "the section [4,10] is selected");
  doDelete();
  eqJson(segView(), [[0, 4, "k"], [4, 10, "D"], [10, 20, "k"]], "Delete acts on the clicked section");
});

test("clicking at 0 and at D pick the first and last sections", function () {
  reset(); addTracks([10, "T1"], [10, "T2"]);
  var tl = FAKE.el("tl");
  tl.dispatch("pointerdown", { target: tl, clientX: 0, pointerId: 1, preventDefault: function () { } });
  eq(selSeg, 0); near(PH, 0, 1e-9);
  tl.dispatch("pointerdown", { target: tl, clientX: 1000, pointerId: 1, preventDefault: function () { } });
  eq(selSeg, 1); near(PH, 20, 1e-9);
});

test("selSeg is dropped when the track list changes underneath it", function () {
  reset(); addTracks([9, "T1"]);
  PH = 3; doSplit(); PH = 6; doSplit();
  selSeg = 2;
  acceptTrack(mkTrack(4, { token: "T2" }));
  eq(selSeg, -1, "after add");
  selSeg = 2; moveTrack(0, 1);
  eq(selSeg, -1, "after reorder");
  selSeg = 2; removeTrack(1);
  eq(selSeg, -1, "after remove");
});

test("Delete with no section selected changes nothing", function () {
  reset(); addTracks(10);
  PH = 5; doSplit();
  selSeg = -1;
  var h = hist.length;
  doDelete();
  eq(hist.length, h, "no undo entry");
  eqJson(TR[0].dels, []);
});

test("parseTime accepts the documented formats and rejects the rest", function () {
  near(parseTime("83.5"), 83.5);
  near(parseTime("1:23"), 83);
  near(parseTime("1:23.5"), 83.5);
  near(parseTime("00:01:23.500"), 83.5);
  near(parseTime("1:23,5"), 83.5, 1e-9, "comma decimal");
  ok(isNaN(parseTime("")), "empty");
  ok(isNaN(parseTime("abc")), "junk");
  ok(isNaN(parseTime("-5")), "negative");
  ok(isNaN(parseTime("1:2:3:4")), "too many fields");
});

test("fmt renders whole milliseconds and copes with junk", function () {
  eq(fmt(4.05), "00:00:04.050");
  eq(fmt(3661.999), "01:01:01.999");
  eq(fmt(-1), "00:00:00.000");
  eq(fmt(NaN), "00:00:00.000");
  eq(fmt(65, false), "00:01:05");
});

say("");
say("--- randomised invariant sweep ---");

test("2000 random edit sequences never break a model invariant", function () {
  var seed = 20240607;
  function rnd() { seed = (seed * 1103515245 + 12345) % 2147483648; return seed / 2147483648; }
  var checks = 0, firstFailure = null;
  for (var iter = 0; iter < 2000 && !firstFailure; iter++) {
    reset();
    var n = 1 + Math.floor(rnd() * 4);
    for (var i = 0; i < n; i++)
      acceptTrack(mkTrack(0.5 + rnd() * 8, { token: "K" + i, fps: [24, 25, 30, 60][Math.floor(rnd() * 4)] }));
    for (var op = 0; op < 10 && !firstFailure; op++) {
      var r = rnd(), sg;
      if (r < 0.30) { PH = rnd() * D; if (canSplitAt(PH)) doSplit(); }
      else if (r < 0.55) { sg = segments(); if (sg.length) { selSeg = Math.floor(rnd() * sg.length); doDelete(); } }
      else if (r < 0.63) setA(rnd() * D, true);
      else if (r < 0.71) setB(rnd() * D, true);
      else if (r < 0.80) moveTrack(Math.floor(rnd() * TR.length), rnd() < 0.5 ? -1 : 1);
      else if (r < 0.86) { if (TR.length > 1) removeTrack(Math.floor(rnd() * TR.length)); }
      else if (r < 0.90) { PH = rnd() * D; skipGuardUntil = 0; skipIfDeleted(); }
      else if (r < 0.94) clickReset();
      else doUndo();
      checks++;

      var bad = [], q, kp = keptParts(), sum = 0;
      for (q = 0; q < kp.length; q++) {
        if (!(kp[q].e > kp[q].s)) bad.push("empty/reversed part " + JSON.stringify(kp[q]));
        if (kp[q].s < -1e-9) bad.push("negative part start");
        var tk = null;
        for (var z = 0; z < TR.length; z++) if (TR[z].token === kp[q].t) tk = TR[z];
        if (!tk) bad.push("part refers to a track that is gone: " + kp[q].t);
        else if (kp[q].e > tk.dur + 1e-6) bad.push("part runs past its track's duration");
        sum += kp[q].e - kp[q].s;
      }
      if (Math.abs(sum - outLen()) > 1e-6 * (kp.length + 1)) bad.push("keptParts sum " + sum + " != outLen " + outLen());
      if (outLen() > B - A + 1e-6) bad.push("outLen exceeds the trim range");
      if (TR.length) {
        if (!M || TR.indexOf(M) < 0) bad.push("M is not a member of TR");
        if (cur < 0 || cur >= TR.length) bad.push("cur out of range: " + cur);
      } else if (D !== 0 || cutsP.length || delsP.length) bad.push("empty program with stale cutsP/delsP/D");
      if (A > B + 1e-9) bad.push("A > B");
      var kr = keptRanges();
      for (q = 1; q < kr.length; q++) if (kr[q][0] < kr[q - 1][1] - 1e-9) bad.push("keptRanges overlap");
      for (q = 1; q < cutsP.length; q++) if (cutsP[q] < cutsP[q - 1] - 1e-12) bad.push("cutsP unsorted");
      for (q = 0; q < delsP.length; q++) {
        if (delsP[q][1] <= delsP[q][0]) bad.push("empty delsP range");
        if (q && delsP[q][0] < delsP[q - 1][1] - 1e-12) bad.push("delsP overlap - recalc failed to merge");
      }
      for (q = 0; q < TR.length; q++) {
        var d = TR[q].dels, c = TR[q].cuts, w;
        for (w = 0; w < d.length; w++) if (d[w][0] < -1e-9 || d[w][1] > TR[q].dur + 1e-9) bad.push("track deletion out of source bounds");
        for (w = 0; w < c.length; w++) if (c[w] <= 0 || c[w] >= TR[q].dur) bad.push("track cut out of source bounds: " + c[w] + " of " + TR[q].dur);
        for (w = 1; w < c.length; w++) if (c[w] < c[w - 1]) bad.push("track cuts unsorted");
      }
      var sg2 = segments();
      if (sg2.length) {
        if (Math.abs(sg2[0].s) > 1e-9) bad.push("segments do not start at 0");
        if (Math.abs(sg2[sg2.length - 1].e - D) > 1e-9) bad.push("segments do not end at D");
        for (q = 1; q < sg2.length; q++) if (Math.abs(sg2[q].s - sg2[q - 1].e) > 1e-9) bad.push("gap between sections");
      } else if (TR.length && D > EPS) bad.push("no sections despite D > 0");

      if (bad.length) firstFailure = "iter " + iter + " op " + op + ": " + bad.join("; ") +
        "\n          segs=" + JSON.stringify(segView()) + " A=" + A + " B=" + B + " D=" + D + " tracks=" + TR.length;
    }
  }
  if (firstFailure) fail(firstFailure);
  ok(checks > 15000, "expected a decent sweep, only ran " + checks + " checks");
});

say("");
say("--- defects found by adversarial testing, now fixed and pinned ---");

test("[REGRESSION] segAt(t) below 0 must return the first section, not the last", function () {
  reset(); addTracks([5, "T1"], [5, "T2"]);
  eq(segments().length, 2);
  /* segAt falls through its loop for any t < 0 and returns sg.length - 1,
     the same answer it gives for t past D. trackAt(-1) correctly says 0. */
  eq(segAt(-1), 0, "segAt(-1)");
  eq(segAt(-0.0001), 0, "segAt just below zero");
  eq(segAt(0), 0, "segAt(0) - the working case, for contrast");
  eq(segAt(D + 5), 1, "past the end really should clamp to the last section");
});

test("[REGRESSION] the Undo button must agree with what Ctrl+Z actually does", function () {
  reset();
  acceptTrack(mkTrack(5, { token: "GONE" }));
  PH = 2; doSplit();
  removeTrack(0);                               // last track out -> clearProgram()
  eq(TR.length, 0, "precondition: the program is empty");
  /* syncEditButtons gates bUndo on !!M; the Ctrl+Z keydown handler calls
     doUndo() directly with no such guard. Whatever the button claims, the
     shortcut must do the same thing - assert the agreement itself rather than
     one particular side of it. */
  var says = FAKE.el("bUndo").disabled;      // true = "nothing to undo"
  var before = TR.length;
  pressKey("z", true);
  var did = (TR.length !== before);
  eq(did, !says,
    says ? "Undo is disabled, yet Ctrl+Z restored " + TR.length + " track(s)"
         : "Undo is enabled, yet Ctrl+Z did nothing");
});

test("[REGRESSION] Ctrl+Z after opening a new file must not resurrect the previous one", function () {
  reset();
  acceptTrack(mkTrack(5, { token: "OLD" }));
  removeTrack(0);                               // program cleared
  acceptTrack(mkTrack(3, { token: "NEW" }));    // user opens a different file
  pressKey("z", true);                          // undo the open -> empty again
  pressKey("z", true);                          // one more press
  for (var i = 0; i < TR.length; i++)
    ok(TR[i].token !== "OLD",
      "a file the user removed before opening NEW came back as track " + (i + 1));
});

test("[REGRESSION] a second skip must cancel the first skip's restarting timer", function () {
  reset(); addTracks([20, "T1"]);
  PH = 3; doSplit(); PH = 5; doSplit(); PH = 10; doSplit(); PH = 12; doSplit();
  pickAndDelete(4);                             // hole [3,5]
  pickAndDelete(11);                            // hole [10,12]
  restarting = false; TIMERS = [];
  skipTo(5, true);
  eq(TIMERS.length, 1, "the first skip arms a 3s reset");
  skipTo(12, true);
  eq(restarting, true, "the second skip is now in flight");
  eq(TIMERS.length, 2, "and arms its own reset without cancelling the first");
  TIMERS[0].fn();                               // the FIRST skip's timer expires
  /* restarting is what tells the pause handler that a stream teardown is ours
     rather than the user's. Cleared early, the teardown for skip 2 clears
     selPlay and Play Selection stops at the second hole. */
  eq(restarting, true,
    "the stale timer from skip 1 cleared restarting while skip 2 was still respinning");
});

say("");
say("--- looping Play Selection ---");

/* park the idle player as a browser would: metadata, then the seek landing */
function landPark() {
  var sb = vIdle();
  sb.readyState = 1;
  sb.dispatch("loadedmetadata");
  sb.dispatch("seeked");
}

test("Play Selection loops: at B it swaps to the parked player at A", function () {
  reset(); addTracks([20, "T1"]);
  setA(4, true); setB(9, true);
  FAKE.el("bSel").onclick();
  eq(selPlay, true); eq(LOOP.on, true);
  eq(v, vMain);
  PH = 5; loopStep(false);
  eq(vAux._key, "T1@4.0000", "the idle player is parked on the loop start");
  eq(LOOP.ready, false, "not usable until the seek lands");
  landPark();
  near(vAux.currentTime, 4, 1e-9);
  eq(LOOP.ready, true);
  PH = 9 - 0.001; loopStep(false);
  eq(v, vAux, "the players swapped");
  eq(vAux.paused, false, "the parked one is playing");
  eq(vMain.paused, true, "the old one stopped");
  eq(vMain.style.display, "none"); eq(vAux.style.visibility, "");
  near(PH, 4, 1e-9); eq(selPlay, true, "and it keeps looping");
});

test("the swapped-out player is parked for the next time round", function () {
  reset(); addTracks([20, "T1"]);
  setA(4, true); setB(9, true);
  FAKE.el("bSel").onclick();
  PH = 5; loopStep(false); landPark();
  PH = 9; loopStep(false);
  eq(v, vAux);
  vMain.readyState = 1;
  PH = 5; loopStep(false);
  eq(vMain._key, "T1@4.0000"); near(vMain.currentTime, 4, 1e-9);
  vMain.dispatch("seeked");
  PH = 9; loopStep(false);
  eq(v, vMain, "and back again");
  near(PH, 4, 1e-9);
});

test("with nothing parked the loop still goes round by jumping", function () {
  reset(); addTracks([20, "T1"]);
  setA(4, true); setB(9, true);
  FAKE.el("bSel").onclick();
  PH = 9; loopStep(false);
  eq(v, vMain, "no swap");
  near(PH, 4, 1e-9, "jumped back to the start");
  near(vMain.currentTime, 4, 1e-9);
  eq(selPlay, true);
});

test("the loop goes over a deleted hole and wraps past it", function () {
  reset(); addTracks([20, "T1"]);
  PH = 6; doSplit(); PH = 8; doSplit();
  pickAndDelete(7);
  setA(4, true); setB(12, true);
  eqJson(loopPieces(), [{ i: 0, s: 4, e: 6 }, { i: 0, s: 8, e: 12 }]);
  FAKE.el("bSel").onclick();
  PH = 5; loopStep(false);
  eq(vAux._key, "T1@8.0000", "parked after the hole");
  landPark();
  PH = 6; loopStep(false);
  near(PH, 8, 1e-9); eq(v, vAux);
  PH = 10; loopStep(false);
  eq(vMain._key, "T1@4.0000", "next park is the wrap back to A");
});

test("timeupdate at B no longer stops Play Selection", function () {
  reset(); addTracks([20, "T1"]);
  setA(4, true); setB(9, true);
  FAKE.el("bSel").onclick();
  vMain.currentTime = 9.2; vMain.dispatch("timeupdate");
  eq(selPlay, true);
  near(PH, 4, 1e-9, "went round instead of pausing");
});

test("running off the end of the clip goes round instead of stopping", function () {
  reset(); addTracks([10, "T1"]);
  setA(2, true); setB(10, true);
  FAKE.el("bSel").onclick();
  vMain.ended = true; vMain.paused = true;
  vMain.dispatch("pause");
  eq(selPlay, true, "the end-of-clip pause is not the user's");
  vMain.dispatch("ended");
  vMain.ended = false;
  near(PH, 2, 1e-9);
  eq(vMain.paused, false, "playing again");
});

test("pausing stops the loop and unparks the idle player", function () {
  reset(); addTracks([20, "T1"]);
  setA(4, true); setB(9, true);
  FAKE.el("bSel").onclick();
  PH = 5; loopStep(false);
  ok(vAux._url, "parked");
  togglePlay();
  vMain.dispatch("pause");                      /* the shim's pause() fires no event */
  eq(selPlay, false); eq(LOOP.on, false);
  eq(vAux._url, "", "released");
  eq(FAKE.el("bSel").classList.contains("on"), false);
});

test("the loop crosses onto another track by swapping", function () {
  reset(); addTracks([10, "T1"], [10, "T2"]);
  setA(8, true); setB(13, true);
  eqJson(loopPieces(), [{ i: 0, s: 8, e: 10 }, { i: 1, s: 10, e: 13 }]);
  FAKE.el("bSel").onclick();
  PH = 9; loopStep(false);
  eq(vAux._key, "T2@10.0000");
  near(vAux._seekTo, 0, 1e-9, "track-local start, placed once metadata lands");
  landPark();
  near(vAux.currentTime, 0, 1e-9);
  PH = 10; loopStep(false);
  eq(cur, 1); eq(M.token, "T2"); eq(v, vAux);
});

test("clearing the program puts the main player back in charge", function () {
  reset(); addTracks([20, "T1"]);
  setA(4, true); setB(9, true);
  FAKE.el("bSel").onclick();
  PH = 5; loopStep(false); landPark();
  PH = 9; loopStep(false);
  eq(v, vAux);
  clearProgram();
  eq(v, vMain); eq(LOOP.on, false);
});

test("the END label jumps the scrubber to the end point", function () {
  reset(); addTracks([20, "T1"]);
  eq(FAKE.el("bGoB").disabled, false, "live once a track is loaded");
  setA(3, true); setB(12, true);
  FAKE.el("bGoB").onclick();
  near(PH, 12, 1e-9);
  FAKE.el("bGoA").onclick();
  near(PH, 3, 1e-9);
  clearProgram();
  eq(FAKE.el("bGoB").disabled, true, "and dead again with nothing loaded");
});

say("");
say("--- the same file added twice ---");

/* video 1, video 2, video 1 again - keep the head of the first copy and the
   middle of the second */
function sandwich() {
  reset();
  acceptTrack(mkTrack(10, { token: "V1a", name: "one.mp4" }));
  acceptTrack(mkTrack(10, { token: "V2",  name: "two.mp4" }));
  acceptTrack(mkTrack(10, { token: "V1b", name: "one.mp4" }));
  metaLanded();
  PH = 4;  doSplit(); pickAndDelete(7);        // track 1: keep [0,4]
  PH = 23; doSplit(); PH = 27; doSplit();
  pickAndDelete(21);                            // track 3: drop [20,23]
  pickAndDelete(28);                            //          and [27,30]
}

test("[REGRESSION] entering a track whose head is deleted plays its kept cut", function () {
  sandwich();
  seek(12); metaLanded();
  var vEl = v;
  vEl.paused = false;
  vEl.dispatch("ended");                        // video 2 runs out
  eq(cur, 2, "on the second copy of video 1"); eq(M.token, "V1b");
  near(pendingSeek, 3, 1e-9, "aimed past the deleted head, not at 0");
  vEl.currentTime = 0; vEl.dispatch("timeupdate");  // browser resets to 0 while loading
  near(pendingSeek, 3, 1e-9, "the loading-time 0 must not re-aim the seek");
  metaLanded();
  near(vEl.currentTime, 3, 1e-9, "playback starts at the kept cut");
  vEl.dispatch("timeupdate");
  near(PH, 23, 1e-9);
});

test("[REGRESSION] a skip made while a track is loading is not undone by loadedmetadata", function () {
  sandwich();
  activate(2, 0, true);
  goTo(24, true);
  metaLanded();
  near(v.currentTime, 4, 1e-9, "the later seek wins");
});

test("the loop plays video 1, video 2, then video 1's second cut", function () {
  sandwich();
  eqJson(loopPieces(), [{ i: 0, s: 0, e: 4 }, { i: 1, s: 10, e: 20 }, { i: 2, s: 23, e: 27 }]);
});

test("[REGRESSION] the loop holds the last frame before B and swaps once it has been shown", function () {
  reset(); addTracks([20, "T1"]);               // 25 fps: a frame is 40ms
  setA(4, true); setB(9, true);
  var cbs = [];
  vMain.requestVideoFrameCallback = function (fn) { cbs.push(fn); return cbs.length; };
  vMain.cancelVideoFrameCallback = function () { };
  try {
    FAKE.el("bSel").onclick();
    eq(cbs.length, 1, "watching presented frames");
    PH = 8.995; loopStep(false);
    near(PH, 8.995, 1e-9,
      "no swap on the clock alone - the compositor may already be showing frames past B");
    cbs[cbs.length - 1](0, { mediaTime: 8.88, expectedDisplayTime: 1000 });
    eq(LOOP.holding, false, "8.88 is not the last frame before 9.0");
    cbs[cbs.length - 1](0, { mediaTime: 8.96, expectedDisplayTime: 1040 });
    eq(LOOP.holding, true, "8.96 is");
    eq(vMain.paused, true, "and playback is parked on it, so nothing past B is ever shown");
    vMain.dispatch("pause");
    eq(selPlay, true, "that pause is the loop's own, not the user's");
    loopTick(1050);
    eq(LOOP.holding, true, "it gets its full 40ms on screen");
    loopTick(1080);
    eq(LOOP.holding, false);
    near(PH, 4, 1e-9, "then the loop goes round");
  } finally {
    delete vMain.requestVideoFrameCallback; delete vMain.cancelVideoFrameCallback;
    selPlay = false; loopStop();
  }
});

test("a held last frame is released by a timer if animation frames stop", function () {
  reset(); addTracks([20, "T1"]);
  setA(4, true); setB(9, true);
  var cbs = [];
  vMain.requestVideoFrameCallback = function (fn) { cbs.push(fn); return cbs.length; };
  try {
    FAKE.el("bSel").onclick();
    TIMERS = [];
    cbs[cbs.length - 1](0, { mediaTime: 8.96, expectedDisplayTime: 1040 });
    eq(TIMERS.length, 1, "a backstop timer is armed");
    TIMERS[0].fn();
    eq(LOOP.holding, false); near(PH, 4, 1e-9);
  } finally {
    delete vMain.requestVideoFrameCallback;
    selPlay = false; loopStop();
  }
});

say("");
say("--- per-track loops and ping-pong ---");

test("a track set to loop 3 times saves its kept parts 3 times", function () {
  reset(); addTracks([10, "T1"], [5, "T2"]);
  PH = 4; doSplit(); pickAndDelete(7);          // T1 keeps [0,4]
  setLoops(0, 3);
  eqJson(keptParts(), [{ t: "T1", s: 0, e: 4 }, { t: "T1", s: 0, e: 4 }, { t: "T1", s: 0, e: 4 },
                       { t: "T2", s: 0, e: 5 }]);
  near(outLen(), 17, 1e-6, "Clip length counts every pass");
});

test("ping-pong follows each pass with the same parts backwards", function () {
  reset(); addTracks([10, "T1"]);
  PH = 3; doSplit(); PH = 6; doSplit();
  pickAndDelete(4.5);                           // keeps [0,3] and [6,10]
  setPong(0, true); setLoops(0, 2);
  var pass = [{ t: "T1", s: 0, e: 3 }, { t: "T1", s: 6, e: 10 },
              { t: "T1", s: 6, e: 10, r: 1 }, { t: "T1", s: 0, e: 3, r: 1 }];
  eqJson(keptParts(), pass.concat(pass));
  near(outLen(), 28, 1e-6);
});

test("loops and ping-pong are undoable", function () {
  reset(); addTracks([10, "T1"]);
  setLoops(0, 4); setPong(0, true);
  doUndo(); eq(TR[0].pong, false); eq(TR[0].loops, 4);
  doUndo(); eq(TR[0].loops, 1);
});

test("the track row carries the loop dropdown and the ping-pong toggle", function () {
  reset(); addTracks([10, "T1"]);
  var row = FAKE.el("tkList").childNodes[0];
  var line = row.childNodes[row.childNodes.length - 1];
  eq(line.className, "tkloop");
  var sel = line.childNodes[1], pp = line.childNodes[2];
  eq(sel.childNodes.length, 10, "x1 to x10");
  sel.value = "5"; sel.onchange.call(sel);
  eq(TR[0].loops, 5);
  pp.onclick();
  eq(TR[0].pong, true);
  row = FAKE.el("tkList").childNodes[0];
  line = row.childNodes[row.childNodes.length - 1];
  eq(line.childNodes[2].className, "pong on", "the redrawn toggle shows it is on");
  eq(line.childNodes[1].value, "5");
});

test("Play Selection goes backwards on a ping-pong track by swapping to a reversed stream", function () {
  reset(); addTracks([10, "T1"]);
  setA(2, true); setB(5, true); setPong(0, true);
  eqJson(loopPieces(), [{ i: 0, s: 2, e: 5 }, { i: 0, s: 2, e: 5, rev: true }]);
  FAKE.el("bSel").onclick();
  PH = 3; loopStep(false);
  ok(vAux._url.indexOf("start=2.000000&end=5.000000&rev=1") >= 0, "reverse stream parked: " + vAux._url);
  vAux.dispatch("loadeddata");
  eq(LOOP.ready, true);
  PH = 5; loopStep(false);
  eq(v, vAux); ok(revPiece, "running backwards"); near(PH, 5, 1e-9);
  v.currentTime = 1;
  near(playPos(), 4, 1e-9, "the playhead runs back down the timeline");
  vMain.readyState = 1;
  loopStep(false);
  eq(vMain._key, "T1@2.0000", "forward pass parked next");
  vMain.dispatch("seeked");
  v.currentTime = 3; loopStep(false);
  eq(v, vMain); eq(revPiece, null); near(PH, 2, 1e-9);
});

test("with nothing parked a backwards pass streams on the active player", function () {
  reset(); addTracks([10, "T1"]);
  setA(2, true); setB(5, true); setPong(0, true);
  FAKE.el("bSel").onclick();
  PH = 5; loopStep(false);
  eq(v, vMain);
  ok(v._url.indexOf("rev=1") >= 0, "reversed stream on the active player");
  ok(revPiece); eq(selPlay, true);
});

test("pausing during a backwards pass puts the real source back", function () {
  reset(); addTracks([10, "T1"]);
  setA(2, true); setB(5, true); setPong(0, true);
  FAKE.el("bSel").onclick();
  PH = 5; loopStep(false);                      // backwards stream, no park
  v.currentTime = 1; PH = playPos();
  togglePlay(); v.dispatch("pause");
  eq(selPlay, false); eq(revPiece, null);
  ok(v._url.indexOf("/api/stream") >= 0, "back on the file: " + v._url);
  near(pendingSeek, 4, 1e-9, "at the frame the playhead was on");
});

say("");
say("--- cloning a track ---");

test("a clone keeps its original's splits, deletions and loops, and plays right after it", function () {
  reset(); addTracks([10, "T1"], [5, "T2"]);
  PH = 4; doSplit(); pickAndDelete(7);
  setLoops(0, 2);
  insertClone(0, "T1c");
  eq(TR.length, 3); eq(TR[1].token, "T1c"); eq(TR[2].token, "T2");
  eqJson(TR[1].cuts, [4]); eqJson(TR[1].dels, [[4, 10]]); eq(TR[1].loops, 2);
  eqJson(segView(), [[0, 4, "k"], [4, 10, "D"], [10, 14, "k"], [14, 20, "D"], [20, 25, "k"]]);
  TR[1].cuts.push(2);
  eqJson(TR[0].cuts, [4], "the clone's edits are its own");
});

test("cloning keeps the trim points and playhead on the same footage", function () {
  reset(); addTracks([10, "T1"], [5, "T2"]);
  setA(11, true);                               // inside T2; B is at the end
  PH = 12;
  insertClone(0, "T1c");
  near(A, 21, 1e-9); near(B, 25, 1e-9); near(PH, 22, 1e-9);
});

test("clone asks the server for a second token for the same file", function () {
  reset(); addTracks([10, "T1"]);
  FETCHES = [];
  cloneTrack(0);
  eq(FETCHES.length, 1);
  ok(FETCHES[0].url.indexOf("/api/clone") === 0 && FETCHES[0].url.indexOf("t=T1") > 0, FETCHES[0].url);
});

test("a clone is undoable", function () {
  reset(); addTracks([10, "T1"]);
  insertClone(0, "c");
  doUndo();
  eq(TR.length, 1); eq(TR[0].token, "T1");
});

test("a clone can be moved after another track", function () {
  reset(); addTracks([10, "T1"], [5, "T2"]);
  insertClone(0, "c");
  moveTrack(1, 1);
  eq(TR[1].token, "T2"); eq(TR[2].token, "c");
});

say("");
say("--- soundtrack ---");

function sndJ(dur, tok) {
  return { ok: true, token: tok || "S1", name: "song.m4a", path: "C:\\m\\song.m4a", duration: dur };
}

test("a soundtrack mutes the tracks and goes out with the save", function () {
  reset(); addTracks([10, "T1"]);
  setSoundtrack(sndJ(4));
  eq(vMain.muted, true); eq(vAux.muted, true);
  ok(snd.src.indexOf("/api/audiofile") >= 0 && snd.src.indexOf("t=S1") > 0, snd.src);
  eq(FAKE.el("sndRow").style.display, "flex");
  FETCHES = [];
  save();
  eq(JSON.parse(FETCHES[FETCHES.length - 1].opts.body).audio, "S1");
  clearSoundtrack();
  eq(vMain.muted, false, "the tracks' own sound is back");
  eq(FAKE.el("sndRow").style.display, "none");
});

test("the soundtrack follows the saved video's clock, holes skipped, and wraps", function () {
  reset(); addTracks([10, "T1"]);
  PH = 4; doSplit(); PH = 6; doSplit(); pickAndDelete(5);   // hole [4,6]
  setSoundtrack(sndJ(3));
  PH = 7;
  near(outputTime(), 5, 1e-9, "the deleted 2s does not count");
  vMain.paused = false; vMain.style.display = "block";
  sndSync();
  near(snd.currentTime, 2, 1e-9, "5s in is 2s into the second pass of a 3s song");
  eq(snd.paused, false);
});

test("small drift is left alone; a real jump is corrected", function () {
  reset(); addTracks([10, "T1"]);
  setSoundtrack(sndJ(3));
  vMain.paused = false; vMain.style.display = "block";
  PH = 5; sndSync();
  snd.currentTime = 2.1; sndSync();
  near(snd.currentTime, 2.1, 1e-9, "a tenth out is not worth an audible skip");
  snd.currentTime = 0.5; sndSync();
  near(snd.currentTime, 2, 1e-9);
  snd.currentTime = 2.99; PH = 3.02; sndSync();
  near(snd.currentTime, 2.99, 1e-9, "either side of the wrap point counts as close");
});

test("pausing the video pauses the soundtrack", function () {
  reset(); addTracks([10, "T1"]);
  setSoundtrack(sndJ(3));
  vMain.paused = false; vMain.style.display = "block";
  sndSync(); eq(snd.paused, false);
  vMain.paused = true; sndSync();
  eq(snd.paused, true);
});

test("Play Selection counts every loop pass on the soundtrack clock", function () {
  reset(); addTracks([10, "T1"]);
  setA(2, true); setB(5, true); setLoops(0, 3);
  FAKE.el("bSel").onclick();
  LOOP.into = 2; PH = 3;
  near(outputTime(), 7, 1e-9, "two 3s passes done, 1s into the third");
});

test("the mute button silences the soundtrack; the tracks stay muted under it", function () {
  reset(); addTracks([10, "T1"]);
  setSoundtrack(sndJ(3));
  FAKE.el("bMute").onclick();
  eq(snd.muted, true); eq(vMain.muted, true);
  FAKE.el("bMute").onclick();
  eq(snd.muted, false); eq(vMain.muted, true);
});

test("a soundtrack is saved with the session and comes back with it", function () {
  reset(); addTracks([10, "T1"]);
  TR[0].path = "C:\\v\\a.mp4";
  setSoundtrack(sndJ(4));
  var s = JSON.parse(JSON.stringify(sessionData()));
  eq(s.audio.path, "C:\\m\\song.m4a");
  clearSoundtrack();
  applySession(s, [mkTrack(10, { token: "N0" })], sndJ(4, "S2"));
  eq(SND.token, "S2"); eq(vMain.muted, true);
  applySession(s, [mkTrack(10, { token: "N1" })], null);
  eq(SND, null, "a soundtrack that has gone missing is dropped");
});

say("");
say("--- per-track mute ---");

/* the row's controls: [meta, jump, mute, clone, remove] */
function muteBtn(k) {
  var row = FAKE.el("tkList").childNodes[k];
  return row.childNodes[row.childNodes.length - 2].childNodes[2];
}

test("only a muted track's parts are marked, and only when something is muted", function () {
  reset(); addTracks([10, "T1"], [5, "T2"]);
  eqJson(keptParts(), [{ t: "T1", s: 0, e: 10 }, { t: "T2", s: 0, e: 5 }]);
  setMute(1, true);
  eqJson(keptParts(), [{ t: "T1", s: 0, e: 10 }, { t: "T2", s: 0, e: 5, m: 1 }]);
});

test("every pass of a muted loop is marked, backwards ones included", function () {
  reset(); addTracks([10, "T1"]);
  PH = 4; doSplit(); pickAndDelete(7);          // keeps [0,4]
  setMute(0, true); setPong(0, true); setLoops(0, 2);
  var pass = [{ t: "T1", s: 0, e: 4, m: 1 }, { t: "T1", s: 0, e: 4, r: 1, m: 1 }];
  eqJson(keptParts(), pass.concat(pass));
});

test("the row's mute button toggles the track and comes back lit", function () {
  reset(); addTracks([10, "T1"]);
  var b = muteBtn(0);
  eq(b.className, "mute");
  eq(b.disabled, false);
  b.onclick();
  eq(TR[0].mute, true);
  eq(muteBtn(0).className, "mute on", "the redrawn button shows it is muted");
  muteBtn(0).onclick();
  eq(TR[0].mute, false);
});

test("muting is undoable", function () {
  reset(); addTracks([10, "T1"], [5, "T2"]);
  setMute(0, true); setMute(1, true);
  doUndo(); eq(TR[1].mute, false); eq(TR[0].mute, true);
  doUndo(); eq(TR[0].mute, false);
});

test("a muted track is silent while it is the one showing", function () {
  reset(); addTracks([10, "T1"], [5, "T2"]);
  setMute(0, true);
  eq(cur, 0); eq(vMain.muted, true, "track 1 is muted, so the player is");
  activate(1, 0, false);
  eq(vMain.muted, false, "track 2 is not muted");
  activate(0, 0, false);
  eq(vMain.muted, true);
});

test("the volume bar's mute and a track's mute do not undo each other", function () {
  reset(); addTracks([10, "T1"]);
  setMute(0, true);
  FAKE.el("bMute").onclick();                   // volume mute on
  eq(userMuted, true); eq(vMain.muted, true);
  FAKE.el("vol").oninput({ target: { value: "0.5" } });
  eq(userMuted, false, "moving the slider clears the volume mute");
  eq(vMain.muted, true, "but the track is still muted on its own account");
  setMute(0, false);
  eq(vMain.muted, false);
});

test("a track with no sound of its own has the button disabled", function () {
  reset();
  acceptTrack(mkTrack(10, { token: "Q", hasAudio: false }));
  metaLanded();
  var b = muteBtn(0);
  eq(b.disabled, true);
  eq(b.className, "mute", "disabled, not lit");
  eq(vMain.muted, false, "nothing to mute, so nothing is muted");
});

test("a soundtrack takes the mute buttons out of play, and gives them back", function () {
  reset(); addTracks([10, "T1"]);
  setMute(0, true);
  setSoundtrack(sndJ(3));
  eq(muteBtn(0).disabled, true, "the soundtrack has replaced the track's sound");
  eq(muteBtn(0).className, "mute", "so the button does not claim to be doing anything");
  clearSoundtrack();
  eq(muteBtn(0).disabled, false);
  eq(muteBtn(0).className, "mute on", "the track's own mute was remembered");
  eq(vMain.muted, true);
});

test("mute is saved with the session and comes back with it", function () {
  reset(); addTracks([10, "T1"], [5, "T2"]);
  TR[0].path = "C:\v\a.mp4"; TR[1].path = "C:\v\b.mp4";
  setMute(1, true);
  var s = JSON.parse(JSON.stringify(sessionData()));
  eq(s.tracks[0].mute, false); eq(s.tracks[1].mute, true);
  applySession(s, [mkTrack(10, { token: "N0" }), mkTrack(5, { token: "N1" })], null);
  eq(TR[0].mute, false); eq(TR[1].mute, true);
});

test("a clone of a muted track is muted too", function () {
  reset(); addTracks([10, "T1"]);
  setMute(0, true);
  insertClone(0, "C1");
  eq(TR.length, 2);
  eq(TR[1].mute, true);
  eqJson(keptParts(), [{ t: "T1", s: 0, e: 10, m: 1 }, { t: "C1", s: 0, e: 10, m: 1 }]);
});

say("");
say("--- the track list keeps its place ---");

/* the shim's focus() does nothing; make it behave like a browser for a moment */
function withFocus(fn) {
  var was = FakeEl.prototype.focus;
  FakeEl.prototype.focus = function () { document.activeElement = this; };
  try { fn(); } finally { FakeEl.prototype.focus = was; document.activeElement = null; }
}
function loopLine(k) {
  var row = FAKE.el("tkList").childNodes[k];
  return row.childNodes[row.childNodes.length - 1];
}

test("[REGRESSION] changing a loop count keeps the list scrolled and the dropdown focused", function () {
  reset(); addTracks([10, "T1"], [5, "T2"], [3, "T3"]);
  var host = FAKE.el("tkList");
  host.scrollTop = 120;
  withFocus(function () {
    var sel = loopLine(2).childNodes[1];
    document.activeElement = sel;
    sel.value = "4"; sel.onchange.call(sel);
    eq(TR[2].loops, 4);
    eq(host.scrollTop, 120, "the list was thrown back to the top");
    var now = loopLine(2).childNodes[1];
    ok(now !== sel, "(the row really was rebuilt)");
    ok(document.activeElement === now, "focus is back on track 3's loop dropdown");
  });
});

test("[REGRESSION] toggling ping-pong keeps the list scrolled and the toggle focused", function () {
  reset(); addTracks([10, "T1"], [5, "T2"], [3, "T3"]);
  var host = FAKE.el("tkList");
  host.scrollTop = 80;
  withFocus(function () {
    var pp = loopLine(1).childNodes[2];
    document.activeElement = pp;
    pp.onclick();
    eq(TR[1].pong, true);
    eq(host.scrollTop, 80);
    ok(document.activeElement === loopLine(1).childNodes[2], "focus is back on track 2's ping-pong toggle");
  });
});

test("a rebuild with nothing focused in the list leaves focus alone", function () {
  reset(); addTracks([10, "T1"], [5, "T2"]);
  withFocus(function () {
    var other = FAKE.el("inA");
    document.activeElement = other;
    setLoops(0, 2);
    ok(document.activeElement === other, "focus was taken from outside the list");
  });
});

say("");
say("--- reordering tracks by drag ---");

function order() {
  var o = [];
  for (var i = 0; i < TR.length; i++) o.push(TR[i].token);
  return o;
}
/* lay the rows out 40px tall, one under another, as the sidebar would */
function rowsAt() {
  var rows = FAKE.el("tkList").childNodes;
  for (var k = 0; k < rows.length; k++) (function (k) {
    rows[k].getBoundingClientRect = function () {
      return { top: k * 40, height: 40, bottom: k * 40 + 40, left: 0, width: 240, right: 240 };
    };
  })(k);
  return rows;
}
function press(row, target) {
  row.dispatch("pointerdown", { target: target || row, clientY: 0, button: 0 });
}
function dragTo(from, y) {
  var rows = rowsAt();
  rows[from].dispatch("pointerdown", { target: rows[from], clientY: from * 40 + 20, button: 0 });
  document.dispatch("pointermove", { clientY: y, preventDefault: function () { } });
  document.dispatch("pointerup", {});
}

test("dragging a track below the last one moves it to the end", function () {
  reset(); addTracks([10, "T1"], [5, "T2"], [3, "T3"]);
  dragTo(0, 110);                               // past T3's middle
  eqJson(order(), ["T2", "T3", "T1"]);
});

test("dragging a track to the top moves it first", function () {
  reset(); addTracks([10, "T1"], [5, "T2"], [3, "T3"]);
  dragTo(2, 10);
  eqJson(order(), ["T3", "T1", "T2"]);
});

test("dropping between two tracks lands it between them", function () {
  reset(); addTracks([10, "T1"], [5, "T2"], [3, "T3"]);
  dragTo(0, 70);                                // between T2 and T3
  eqJson(order(), ["T2", "T1", "T3"]);
});

test("dropping a track back where it was changes nothing", function () {
  reset(); addTracks([10, "T1"], [5, "T2"], [3, "T3"]);
  var h = hist.length;
  dragTo(1, 50);
  eqJson(order(), ["T1", "T2", "T3"]); eq(hist.length, h, "no undo step for a no-op");
});

test("a small wobble is a click, not a move", function () {
  reset(); addTracks([10, "T1"], [5, "T2"]);
  var rows = rowsAt();
  rows[0].dispatch("pointerdown", { target: rows[0], clientY: 20, button: 0 });
  document.dispatch("pointermove", { clientY: 23, preventDefault: function () { } });
  document.dispatch("pointerup", {});
  eqJson(order(), ["T1", "T2"]);
});

test("pressing a row's own button or dropdown never starts a drag", function () {
  reset(); addTracks([10, "T1"], [5, "T2"]);
  var rows = rowsAt();
  var btn = rows[0].childNodes[rows[0].childNodes.length - 2].childNodes[1];   // a button in the footer
  eq(btn.tagName, "BUTTON");
  rows[0].dispatch("pointerdown", { target: btn, clientY: 20, button: 0 });
  document.dispatch("pointermove", { clientY: 90, preventDefault: function () { } });
  document.dispatch("pointerup", {});
  eqJson(order(), ["T1", "T2"]);
});

test("while held, the row fades and a line marks where it will land", function () {
  reset(); addTracks([10, "T1"], [5, "T2"], [3, "T3"]);
  var rows = rowsAt();
  rows[0].dispatch("pointerdown", { target: rows[0], clientY: 20, button: 0 });
  document.dispatch("pointermove", { clientY: 110, preventDefault: function () { } });
  ok(rows[0].className.indexOf("drag") >= 0, rows[0].className);
  ok(rows[2].className.indexOf("dropAfter") >= 0, rows[2].className);
  document.dispatch("pointerup", {});
  eqJson(order(), ["T2", "T3", "T1"]);
});

test("a drag-reorder is undoable", function () {
  reset(); addTracks([10, "T1"], [5, "T2"], [3, "T3"]);
  dragTo(0, 110);
  doUndo();
  eqJson(order(), ["T1", "T2", "T3"]);
});

test("the up and down buttons are gone", function () {
  reset(); addTracks([10, "T1"], [5, "T2"]);
  var foot = FAKE.el("tkList").childNodes[0].childNodes;
  var titles = [];
  for (var k = 0; k < foot.length; k++)
    for (var j = 0; j < (foot[k].childNodes || []).length; j++) titles.push(foot[k].childNodes[j].title || "");
  ok(titles.join("|").indexOf("Move earlier") < 0 && titles.join("|").indexOf("Move later") < 0, titles.join("|"));
});

say("");
say("--- sessions ---");

/* what the server hands back for the program as it stands: the saved JSON, and
   each track re-registered under a fresh token */
function reopen() {
  var s = JSON.parse(JSON.stringify(sessionData())), files = [];
  for (var i = 0; i < TR.length; i++) {
    files.push(mkTrack(TR[i].dur, { token: "N" + i, name: TR[i].name }));
    files[i].path = TR[i].path;
  }
  return { s: s, files: files };
}

test("a saved session reopens with every track and edit", function () {
  reset(); addTracks([10, "T1"], [5, "T2"]);
  TR[0].path = "C:\\v\\one.mp4"; TR[1].path = "C:\\v\\two.mp4";
  PH = 4; doSplit(); pickAndDelete(7);
  setLoops(1, 3); setPong(0, true);
  setA(1, true); setB(13, true);
  var before = segView();
  var parts = JSON.stringify(keptParts()).replace(/T1/g, "N0").replace(/T2/g, "N1");
  var r = reopen();
  eq(r.s.tracks[0].path, "C:\\v\\one.mp4");
  applySession(r.s, r.files);
  eq(TR.length, 2); eq(TR[0].token, "N0");
  eqJson(segView(), before);
  near(A, 1, 1e-9); near(B, 13, 1e-9);
  eq(TR[1].loops, 3); eq(TR[0].pong, true);
  eq(JSON.stringify(keptParts()), parts, "it would save exactly the same video");
  eq(hist.length, 0, "opening is not an undo step on top of the old work");
});

test("a session track whose file has gone is skipped and the rest still opens", function () {
  reset(); addTracks([10, "T1"], [5, "T2"]);
  var r = reopen();
  r.files[0] = null;
  applySession(r.s, r.files);
  eq(TR.length, 1); eq(TR[0].token, "N1");
  near(A, 0, 1e-9); near(B, D, 1e-9);
});

test("a clone comes back from a session as its own track", function () {
  reset(); addTracks([10, "T1"]);
  PH = 4; doSplit(); pickAndDelete(7);
  insertClone(0, "c");
  var r = reopen();
  applySession(r.s, r.files);
  eq(TR.length, 2); eqJson(TR[1].dels, [[4, 10]]);
});

test("garbage edits in a session file are dropped rather than trusted", function () {
  reset(); addTracks([10, "T1"]);
  var r = reopen();
  r.s.tracks[0].cuts = [-1, "x", 4, 99];
  r.s.tracks[0].dels = [[4, 99], "nope", [7]];
  r.s.tracks[0].loops = 500;
  applySession(r.s, r.files);
  eqJson(TR[0].cuts, [4]); eqJson(TR[0].dels, [[4, 10]]); eq(TR[0].loops, 10);
});

test("edits are autosaved a moment after they stop, never with nothing loaded", function () {
  reset(); TIMERS = [];
  render();
  eq(TIMERS.length, 0, "an empty program schedules nothing");
  addTracks([10, "T1"]);
  ok(TIMERS.length > 0 && TIMERS[TIMERS.length - 1].ms === 1500, "debounced");
  FETCHES = [];
  TIMERS[TIMERS.length - 1].fn();
  eq(FETCHES.length, 1); ok(FETCHES[0].url.indexOf("/api/autosave") === 0);
  eq(JSON.parse(FETCHES[0].opts.body).tracks.length, 1);
});

say("");
say("--- a dialog that never shows up ---");

test("waiting on a dialog can always be abandoned", function () {
  reset(); TIMERS = [];
  FAKE.el("toast").childNodes = []; FAKE.el("toast").firstChild = null;
  addTrack();
  eq(FAKE.el("bAdd").disabled, true, "disabled while the dialog is up");
  var t = FAKE.el("toast").childNodes[0];
  var btn = t.childNodes[t.childNodes.length - 1];
  eq(btn.textContent, "Stop waiting");
  eq(TIMERS.length, 0, "the notice does not time out and vanish on its own");
  btn.onclick();
  eq(FAKE.el("bAdd").disabled, false, "Add is usable again");
});

test("video comes from the media host, the API does not", function () {
  eq(media("/api/stream", "t=x"), api("/api/stream", "t=x"), "no media host outside the app");
  var saved = MEDIA;
  MEDIA = "http://localhost:8731";
  try {
    reset(); addTracks([10, "T1"]);
    ok(v._url.indexOf("http://localhost:8731/api/stream") === 0, v._url);
  } finally { MEDIA = saved; }
});

say("");
say("--- deleted sections shrink to placeholders ---");

test("with nothing deleted the timeline stays linear", function () {
  reset(); addTracks([20, "T1"]);
  PH = 5; doSplit();
  near(tlX(5), 0.25, 1e-9); near(tlT(0.5), 10, 1e-9);
});

test("a deleted section takes a 16px placeholder and the kept parts share the rest", function () {
  reset(); addTracks([100, "T1"]);
  PH = 10; doSplit(); PH = 90; doSplit();
  pickAndDelete(50);                            // an 80s hole in a 100s clip
  var sp = tlSpans();                           // bar is 1000px in the shim
  near(sp[1].x1 - sp[1].x0, 0.016, 1e-9, "placeholder width");
  near(sp[0].x1 - sp[0].x0, 0.492, 1e-9, "10s of the 20s kept");
  near(tlX(10), 0.492, 1e-9); near(tlX(90), 0.508, 1e-9);
  near(tlT(0.246), 5, 1e-9, "maps back through the kept part");
  near(tlT(tlX(95)), 95, 1e-9);
});

test("clicking the placeholder picks the deleted section so it can be restored", function () {
  reset(); addTracks([100, "T1"]);
  PH = 10; doSplit(); PH = 90; doSplit();
  pickAndDelete(50);
  var tl = FAKE.el("tl");
  tl.dispatch("pointerdown", { target: tl, clientX: 500, pointerId: 1, preventDefault: function () { } });
  eq(selSeg, 1);
  doDelete();
  eqJson(segView(), [[0, 10, "k"], [10, 90, "k"], [90, 100, "k"]], "restored");
  near(tlX(50), 0.5, 1e-9, "and the bar is linear again");
});

test("filmstrip slices show only kept stretches, lined up with their source", function () {
  reset(); addTracks([100, "T1"]);
  PH = 10; doSplit(); PH = 90; doSplit();
  pickAndDelete(50);
  var kids = FAKE.el("strip").childNodes;
  eq(kids.length, 2, "no slice for the hole");
  eq(kids[1].style.backgroundSize, "1000% 100%", "10s of 100s is a tenth of the strip");
  eq(kids[1].style.backgroundPosition, "100% 0", "the last tenth");
  eq(kids[0].style.backgroundPosition, "0% 0");
});

test("many placeholders never take more than 30% of the bar", function () {
  reset(); addTracks([100, "T1"]);
  var i;
  for (i = 1; i < 40; i++){ PH = i; doSplit(); }
  for (i = 0; i < 38; i += 2) pickAndDelete(i + 0.5);
  var sp = tlSpans(), g = 0;
  for (i = 0; i < sp.length; i++) if (sp[i].del) g += sp[i].x1 - sp[i].x0;
  ok(g <= 0.3 + 1e-9, "placeholders took " + g);
});

say("");
say("--- crop and output size (the Advanced panel) ---");

say("");
say("--- setting a trim point when the other is in the way ---");

/* An explicit set is taken at its word and shoves the far point aside; a drag
   stops against it instead. Everything else about the two is identical. */

test("Set Start past the end pushes the end along instead of clamping", function () {
  reset(); addTracks([20, "T1"]);
  setA(2, true); setB(6, true);
  setA(12);                                  /* explicit: no drag flag */
  near(A, 12, 1e-9, "the start lands exactly where it was put");
  ok(B >= A + MIN_LEN - 1e-9, "and the end was moved out of the way, not left behind: B=" + B);
  near(B, 12 + MIN_LEN, 1e-9, "just far enough to keep a legal clip");
});

test("Set End before the start pulls the start back", function () {
  reset(); addTracks([20, "T1"]);
  setA(10, true); setB(15, true);
  setB(4);
  near(B, 4, 1e-9, "the end lands exactly where it was put");
  near(A, 4 - MIN_LEN, 1e-9, "and the start gave way");
  ok(A >= 0, "without going negative");
});

test("the far point is left alone when it is not in the way", function () {
  reset(); addTracks([20, "T1"]);
  setA(2, true); setB(18, true);
  setA(5);
  near(A, 5, 1e-9, "start moved");
  near(B, 18, 1e-9, "end untouched");
  setB(9);
  near(B, 9, 1e-9, "end moved");
  near(A, 5, 1e-9, "start untouched");
});

test("[REGRESSION] a DRAG still stops against the far point", function () {
  /* The handle is under the pointer and visibly stops. Pushing here would let
     an overshoot silently wipe out a mark the user was not aiming at. */
  reset(); addTracks([20, "T1"]);
  setA(2, true); setB(6, true);
  setA(12, true);
  near(B, 6, 1e-9, "the end must not have moved");
  near(A, 6 - MIN_LEN, 1e-9, "and the start stopped against it");
  setB(1, true);
  near(A, 6 - MIN_LEN, 1e-9, "the start must not have moved");
  near(B, A + MIN_LEN, 1e-9, "and the end stopped against it");
});

test("a start set against the very end of the programme still leaves a clip", function () {
  reset(); addTracks([20, "T1"]);
  setA(0, true); setB(5, true);
  setA(20);
  ok(A <= 20 - MIN_LEN + 1e-9, "the start cannot sit closer than MIN_LEN to the end: A=" + A);
  near(B, 20, 1e-9, "so the end goes to the end of the programme");
  ok(outLen() >= MIN_LEN - 1e-9, "and something is left to save: " + outLen());
});

test("an end set against zero still leaves a clip", function () {
  reset(); addTracks([20, "T1"]);
  setA(10, true); setB(15, true);
  setB(0);
  near(A, 0, 1e-9, "the start goes to zero");
  ok(B >= MIN_LEN - 1e-9, "and the end keeps MIN_LEN clear of it: B=" + B);
  ok(outLen() >= MIN_LEN - 1e-9, "leaving something to save: " + outLen());
});

test("pushing never produces a reversed or sub-minimum selection", function () {
  reset(); addTracks([20, "T1"]);
  var spots = [-5, 0, 0.01, 3, 9.999, 10, 10.001, 19.99, 20, 1e6];
  for (var i = 0; i < spots.length; i++) {
    for (var j = 0; j < spots.length; j++) {
      setA(spots[i]); setB(spots[j]);
      ok(B - A >= MIN_LEN - 1e-9, "A=" + spots[i] + " then B=" + spots[j] + " gave " + A + ".." + B);
      ok(A >= -1e-9 && B <= D + 1e-9, "A=" + A + " B=" + B + " left the programme");
      setB(spots[j]); setA(spots[i]);
      ok(B - A >= MIN_LEN - 1e-9, "B=" + spots[j] + " then A=" + spots[i] + " gave " + A + ".." + B);
      ok(A >= -1e-9 && B <= D + 1e-9, "A=" + A + " B=" + B + " left the programme");
    }
  }
});

test("the I and O keys push the same way the buttons do", function () {
  reset(); addTracks([20, "T1"]);
  setA(2, true); setB(6, true);
  PH = 14; pressKey("i");
  near(A, 14, 1e-9, "I put the start under the playhead");
  ok(B >= A + MIN_LEN - 1e-9, "and the end moved aside: B=" + B);

  reset(); addTracks([20, "T1"]);
  setA(10, true); setB(15, true);
  PH = 3; pressKey("o");
  near(B, 3, 1e-9, "O put the end under the playhead");
  ok(A <= B - MIN_LEN + 1e-9, "and the start moved aside: A=" + A);
});

test("the Set Start button pushes the end when it has to", function () {
  reset(); addTracks([20, "T1"]);
  setA(1, true); setB(4, true);
  PH = 16;
  FAKE.el("bSetA").onclick();
  near(A, 16, 1e-9, "the button honoured the playhead");
  ok(B >= 16 + MIN_LEN - 1e-9, "and shifted the end: B=" + B);
});

test("a typed start time pushes the end too", function () {
  reset(); addTracks([20, "T1"]);
  setA(1, true); setB(4, true);
  FAKE.el("inA").value = "00:00:11.000";
  FAKE.el("inA").dispatch("change", { target: FAKE.el("inA") });
  near(A, 11, 1e-9, "the typed time was honoured");
  ok(B >= 11 + MIN_LEN - 1e-9, "and the end moved: B=" + B);
});


/* ======================= crop and output size ============================= */
/* The Advanced panel. The size control is a pixel BUDGET taken out of the
   source at 1:1 - 512 means a 512x512 chunk of the real picture - so a bigger
   budget means a BIGGER box on screen, and nothing is ever resampled. */

/* A 1600x900 stage means a 16:9 frame fills it exactly, so one normalised unit
   is 1600px across and 900px down and drag arithmetic stays readable. */
function stageSize(w, h) {
  FAKE.el("stage").getBoundingClientRect = function () {
    return { left: 0, top: 0, width: w, height: h, right: w, bottom: h };
  };
}
function cropReset() {
  reset();
  stageSize(1600, 900);
  CROP = { on: false, ar: "src", px: 512, x: 0, y: 0, w: 1, h: 1, capped: false };
  cdrag = null;
}
/* a track of a chosen shape, since the default mkTrack is always 1920x1080 */
function addShaped(dur, w, h, tok) {
  acceptTrack(mkTrack(dur, { width: w, height: h, token: tok }));
}
function enableCrop() {
  FAKE.el("cbCrop").checked = true;
  FAKE.el("cbCrop").dispatch("change", { target: FAKE.el("cbCrop") });
}
function corner(g) {
  var e = new FakeEl("SPAN");
  e.setAttribute("data-g", g);
  return e;
}
function pointer(type, target, x, y) {
  FAKE.el("cropBox").dispatch(type, {
    target: target, clientX: x, clientY: y, pointerId: 1,
    preventDefault: function () { }, stopPropagation: function () { }
  });
}

/* --- the budget is a chunk of the source, not an output resolution -------- */

test("a square budget takes exactly that square out of the picture", function () {
  cropReset(); addShaped(10, 3840, 2160); enableCrop();
  setAR("1x1");
  var want = PX_PRESETS;
  for (var i = 0; i < want.length; i++) {
    setPX(want[i]);
    var d = outDims();
    eq(d.w, want[i], "width at " + want[i]);
    eq(d.h, want[i], "height at " + want[i]);
  }
});

test("[REGRESSION] a bigger budget covers MORE of the picture, not the same area larger", function () {
  /* The first cut of this feature changed only the output resolution, so 512
     and 1024 framed an identical region and the box never moved. The budget is
     a chunk of the source: doubling it has to widen the box on screen. */
  cropReset(); addShaped(10, 1920, 1080); enableCrop();
  setAR("1x1");
  setPX(512);
  var at512 = CROP.w, box512 = outDims();
  setPX(1024);
  var at1024 = CROP.w, box1024 = outDims();
  ok(at1024 > at512 * 1.9,
     "1024 should cover about twice the width of 512 (" + at512 + " then " + at1024 + ")");
  eq(box512.w, 512, "and 512 really is 512 source pixels");
  eq(box1024.w, 1024, "while 1024 really is 1024 of them");
});

test("the slider shrinks the region as it moves left", function () {
  cropReset(); addShaped(10, 1920, 1080); enableCrop();
  setAR("1x1");
  var prevW = 0, prevBox = 0;
  for (var pos = 0; pos <= 1000; pos += 125) {
    FAKE.el("pxSlide").dispatch("input", { target: { value: String(pos) } });
    ok(CROP.w > prevW, "the box grows with the slider at " + pos);
    ok(outDims().w > prevBox, "and so does the saved size at " + pos);
    prevW = CROP.w; prevBox = outDims().w;
  }
});

test("the slider runs from the smallest budget to the whole frame", function () {
  cropReset(); addShaped(10, 1920, 1080); enableCrop();
  setAR("1x1");
  FAKE.el("pxSlide").dispatch("input", { target: { value: "0" } });
  eq(CROP.px, PX_MIN, "fully left is the smallest budget");
  FAKE.el("pxSlide").dispatch("input", { target: { value: "1000" } });
  eq(CROP.px, pxCeiling(), "fully right is everything this clip can give");
  near(CROP.h, 1, 1e-9, "which for a square on 16:9 is the whole height");
});

test("the slider is logarithmic, so the small end keeps its travel", function () {
  /* A linear track from 256 to 2880 would leave 256-to-512 with under 10% of
     the travel - the end that most needs fine control. Each doubling should
     get roughly the same room instead. */
  cropReset(); addShaped(10, 3840, 2160); enableCrop();
  setAR("1x1");                      /* ceiling 2160: a shade over three doublings */
  var half = posToPx(500);
  near(Math.log(half / PX_MIN) / Math.log(pxCeiling() / PX_MIN), 0.5, 0.002,
       "halfway along the track is halfway in doublings, not in pixels");
  ok(half < (PX_MIN + pxCeiling()) / 2,
     "and well below the linear midpoint (" + half + ")");
  eq(pxToPos(posToPx(750)), 750, "the mapping round-trips");
});

test("a shape spends its budget on area, it does not use it as a width", function () {
  cropReset(); addShaped(10, 1920, 1080); enableCrop();
  setAR("16x9"); setPX(512);
  eqJson(outDims(), { w: 682, h: 384 }, "16:9 at 512");
  setAR("9x16"); setPX(512);
  eqJson(outDims(), { w: 384, h: 682 }, "9:16 at 512 is the mirror of it");
});

test("every shape at a given budget costs about the same to encode", function () {
  cropReset(); addShaped(10, 3840, 2160); enableCrop();   /* big enough for any shape */
  setPX(768);
  for (var i = 0; i < ARS.length; i++) {
    setAR(ARS[i].k);
    var d = outDims(), px = d.w * d.h, budget = 768 * 768;
    ok(Math.abs(px - budget) / budget < 0.02,
       ARS[i].lab + " costs " + px + " pixels against a budget of " + budget);
  }
});

test("no shape or budget can produce an odd dimension", function () {
  /* x264 at yuv420p refuses one outright, so this holds for every combination
     the panel can reach, not just the round presets. */
  cropReset(); addShaped(10, 3840, 2160); enableCrop();
  for (var i = 0; i < ARS.length; i++) {
    setAR(ARS[i].k);
    for (var p = PX_MIN; p <= 2880; p += 8) {
      CROP.px = p;                       /* outDims is what is under test here */
      var d = outDims();
      eq(d.w % 2, 0, ARS[i].lab + " at " + p + " gave an odd width " + d.w);
      eq(d.h % 2, 0, ARS[i].lab + " at " + p + " gave an odd height " + d.h);
      ok(d.w >= 2 && d.h >= 2, ARS[i].lab + " at " + p + " collapsed to " + d.w + "x" + d.h);
    }
  }
});

test("the budget is held between the smallest and what the clip can give", function () {
  cropReset(); addShaped(10, 1920, 1080); enableCrop();
  setAR("1x1");
  setPX(50);    eq(CROP.px, PX_MIN, "below the bottom");
  setPX(99999); eq(CROP.px, pxCeiling(), "above what the clip holds");
  var at = CROP.px;
  setPX(NaN);   eq(CROP.px, at, "a nonsense value leaves it alone");
});

test("[REGRESSION] the ceiling is the clip, not a fixed number of pixels", function () {
  /* 1024 used to be the hard maximum, which locked a 1080p source out of the
     1440 its 16:9 frame can actually supply. The limit has to come from the
     picture. */
  cropReset(); addShaped(10, 1920, 1080); enableCrop();
  setAR("16x9");
  eq(pxCeiling(), 1440, "16:9 out of 1080p reaches 1440");
  setPX(9999);
  eqJson(outDims(), { w: 1920, h: 1080 }, "and Max really is the whole frame");
  ok(CROP.px > 1024, "which is past the old ceiling: " + CROP.px);

  setAR("1x1");
  eq(pxCeiling(), 1080, "a square out of the same clip stops at its height");
  setAR("9x16");
  eq(pxCeiling(), 810, "and a portrait slice sooner still");
});

test("a 4K clip can be cropped far past the old limit", function () {
  cropReset(); addShaped(10, 3840, 2160); enableCrop();
  setAR("16x9"); setPX(9999);
  eq(pxCeiling(), 2880, "4K at 16:9 reaches 2880");
  eqJson(outDims(), { w: 3840, h: 2160 }, "the whole frame, uncropped and unscaled");
  setAR("1x1"); setPX(2048);
  eqJson(outDims(), { w: 2048, h: 2048 }, "and a 2048 square is comfortably inside it");
});

/* --- never upscale -------------------------------------------------------- */

test("[REGRESSION] a budget the clip cannot fill is capped, never upscaled", function () {
  cropReset(); addShaped(10, 640, 360); enableCrop();
  setAR("1x1"); setPX(1024);
  var d = outDims();
  eq(d.w, 360, "the biggest square in a 640x360 clip is 360 wide");
  eq(d.h, 360, "and 360 tall");
  near(CROP.h, 1, 1e-9, "the box fills the height, because that is all there is");
});

test("a budget below the clip's ceiling is not reported as capped", function () {
  cropReset(); addShaped(10, 1920, 1080); enableCrop();
  setAR("1x1"); setPX(1024);
  eq(CROP.capped, false, "1024 square fits inside 1080 of height");
  setPX(pxCeiling());
  eq(CROP.capped, false, "and landing exactly on the ceiling is not capping either");
});

test("only a clip smaller than the smallest budget reports capping", function () {
  cropReset(); addShaped(10, 200, 200); enableCrop();
  setAR("1x1"); setPX(256);
  eq(CROP.capped, true, "200x200 cannot supply even 256");
  eqJson(outDims(), { w: 200, h: 200 }, "so it gives what it has");
  ok(FAKE.el("cropHint").textContent.indexOf("only reaches") >= 0,
     "and says so: " + FAKE.el("cropHint").textContent);
});

test("a capped budget keeps the shape that was asked for", function () {
  cropReset(); addShaped(10, 640, 360); enableCrop();
  setAR("9x16"); setPX(9999);
  var d = outDims();
  near(d.w / d.h, 9 / 16, 0.02, "still 9:16 after capping, not stretched to the frame");
  ok(d.h <= 360, "and inside the picture: " + d.h);
});

test("every shape and budget stays inside the source, on any size of clip", function () {
  var clips = [[640, 360], [1920, 1080], [320, 240], [3840, 2160], [200, 200]];
  for (var c = 0; c < clips.length; c++) {
    cropReset(); addShaped(10, clips[c][0], clips[c][1]); enableCrop();
    for (var i = 0; i < ARS.length; i++) {
      setAR(ARS[i].k);
      for (var p = 0; p < PX_PRESETS.length; p++) {
        setPX(PX_PRESETS[p]);
        var d = outDims(), tag = clips[c] + " " + ARS[i].lab + " @" + PX_PRESETS[p];
        ok(d.w <= clips[c][0], tag + ": width " + d.w + " exceeds the source");
        ok(d.h <= clips[c][1], tag + ": height " + d.h + " exceeds the source");
        ok(CROP.x >= -1e-9 && CROP.x + CROP.w <= 1 + 1e-9, tag + ": box off the frame");
        ok(CROP.y >= -1e-9 && CROP.y + CROP.h <= 1 + 1e-9, tag + ": box off the frame");
      }
    }
  }
});

test("the Max button takes the whole frame at the chosen shape", function () {
  cropReset(); addShaped(10, 1920, 1080); enableCrop();
  setAR("16x9");
  var maxPill = null, kids = FAKE.el("pxList").childNodes;
  for (var i = 0; i < kids.length; i++) {
    if (kids[i].getAttribute && kids[i].getAttribute("data-px") === "max") maxPill = kids[i];
  }
  ok(maxPill, "the panel offers a Max button");
  maxPill.onclick.call(maxPill);
  eqJson(outDims(), { w: 1920, h: 1080 }, "the entire picture");
  near(CROP.w, 1, 1e-9, "and the box covers all of it");
  near(CROP.x, 0, 1e-9, "sitting at the origin");
});

test("[REGRESSION] the lit preset is never one that cannot be picked", function () {
  /* Switching to a narrower shape lowers the ceiling. Leaving the budget above
     it lit a greyed-out button AND Max at the same time, which said two
     different things about one setting. */
  cropReset(); addShaped(10, 1920, 1080); enableCrop();
  setAR("16x9"); setPX(1440);        /* the whole frame at 16:9 */
  setAR("9x16");                     /* ceiling drops to 810 */
  eq(CROP.px, 810, "the budget comes down with the ceiling");
  var kids = FAKE.el("pxList").childNodes, lit = [], i, el;
  for (i = 0; i < kids.length; i++) {
    el = kids[i];
    if (!el.getAttribute || el.getAttribute("data-px") === null) continue;
    if (el.className.indexOf("on") >= 0) {
      lit.push(el.getAttribute("data-px"));
      eq(el.disabled, false, "a lit preset must be pickable, but " +
         el.getAttribute("data-px") + " is disabled");
    }
  }
  eqJson(lit, ["max"], "exactly one control is lit, and it is Max");
});

test("a preset the clip cannot reach is offered but disabled", function () {
  cropReset(); addShaped(10, 1920, 1080); enableCrop();
  setAR("1x1");                     /* ceiling 1080 */
  var kids = FAKE.el("pxList").childNodes, seen = 0, i, key, el;
  for (i = 0; i < kids.length; i++) {
    el = kids[i];
    if (!el.getAttribute) continue;
    key = el.getAttribute("data-px");
    if (key === null || key === "max") continue;
    seen++;
    if (parseInt(key, 10) > 1080) {
      eq(el.disabled, true, key + " is more than this clip holds, so it must be disabled");
      ok(el.title.indexOf("the most is 1080") >= 0, key + " should explain itself: " + el.title);
    } else {
      eq(el.disabled, false, key + " fits, so it must stay live");
    }
  }
  eq(seen, PX_PRESETS.length, "every preset was checked");
});

/* --- the shape of the box ------------------------------------------------- */

test("the box keeps the shape it was given, whatever the budget", function () {
  cropReset(); addShaped(10, 1920, 1080); enableCrop();
  var f = 1920 / 1080;
  for (var i = 0; i < ARS.length; i++) {
    setAR(ARS[i].k);
    setPX(512);
    near(CROP.w / CROP.h * f, cropAR(), 1e-9, ARS[i].lab + " lost its shape");
  }
});

test("changing the shape keeps the box where the user had put it", function () {
  cropReset(); addShaped(10, 1920, 1080); enableCrop();
  setAR("1x1"); setPX(512); cropCentre();
  CROP.x = 0.05; cropSync();
  var cx = CROP.x + CROP.w / 2, cy = CROP.y + CROP.h / 2;
  setAR("4x3");
  near(CROP.x + CROP.w / 2, cx, 0.02, "the centre barely moves horizontally");
  near(CROP.y + CROP.h / 2, cy, 0.02, "or vertically");
});

test("growing the budget grows the box around its middle", function () {
  cropReset(); addShaped(10, 1920, 1080); enableCrop();
  setAR("1x1"); setPX(256); cropCentre();
  var cx = CROP.x + CROP.w / 2, cy = CROP.y + CROP.h / 2;
  setPX(768);
  near(CROP.x + CROP.w / 2, cx, 1e-9, "the middle stays put horizontally");
  near(CROP.y + CROP.h / 2, cy, 1e-9, "and vertically");
});

/* --- dragging ------------------------------------------------------------- */

test("dragging the box moves it by the distance the pointer moved", function () {
  cropReset(); addShaped(10, 1920, 1080); enableCrop();
  setAR("1x1"); setPX(512); cropCentre();
  var x0 = CROP.x, y0 = CROP.y;
  pointer("pointerdown", FAKE.el("cropBox"), 800, 450);
  pointer("pointermove", FAKE.el("cropBox"), 960, 450);   /* +160px of 1600 */
  near(CROP.x, x0 + 0.1, 1e-9, "moved a tenth of the frame across");
  near(CROP.y, y0, 1e-9, "and not at all down");
  pointer("pointerup", FAKE.el("cropBox"), 960, 450);
  eq(cdrag, null, "the drag ends");
});

test("dragging cannot push the box off the edge of the frame", function () {
  cropReset(); addShaped(10, 1920, 1080); enableCrop();
  setAR("1x1"); setPX(512); cropCentre();
  pointer("pointerdown", FAKE.el("cropBox"), 800, 450);
  pointer("pointermove", FAKE.el("cropBox"), 99999, 99999);
  near(CROP.x + CROP.w, 1, 1e-9, "it stops flush against the right edge");
  near(CROP.y + CROP.h, 1, 1e-9, "and against the bottom");
  pointer("pointermove", FAKE.el("cropBox"), -99999, -99999);
  near(CROP.x, 0, 1e-9, "and flush against the left going the other way");
  near(CROP.y, 0, 1e-9, "and the top");
});

test("a corner drag resizes the box and moves the budget with it", function () {
  /* The corner and the slider are the same control reached two ways, so a
     drag has to leave the panel showing the size it produced. */
  cropReset(); addShaped(10, 1920, 1080); enableCrop();
  setAR("1x1"); setPX(512); cropCentre();
  var left = CROP.x, top = CROP.y, before = CROP.px;
  pointer("pointerdown", corner("se"), 0, 0);
  pointer("pointermove", corner("se"), 160, 0);      /* +0.1 of the frame width */
  near(CROP.x, left, 1e-9, "the left edge does not move");
  near(CROP.y, top, 1e-9, "nor does the top");
  ok(CROP.px > before, "the budget grew with the box: " + before + " to " + CROP.px);
  near(CROP.w / CROP.h * (16 / 9), 1, 1e-9, "and it is still square");
  eq(FAKE.el("pxSlide").value, String(pxToPos(CROP.px)), "the slider followed the drag");
});

test("the north-west handle pins the bottom right instead", function () {
  cropReset(); addShaped(10, 1920, 1080); enableCrop();
  setAR("1x1"); setPX(384); cropCentre();
  var right = CROP.x + CROP.w, bottom = CROP.y + CROP.h, before = CROP.px;
  pointer("pointerdown", corner("nw"), 0, 0);
  pointer("pointermove", corner("nw"), -160, 0);     /* dragging out to the left grows it */
  near(CROP.x + CROP.w, right, 1e-9, "the right edge is pinned");
  near(CROP.y + CROP.h, bottom, 1e-9, "and so is the bottom");
  ok(CROP.px > before, "the box grew");
});

test("a corner drag cannot pull the box out of the frame or past the budget", function () {
  cropReset(); addShaped(10, 1920, 1080); enableCrop();
  setAR("1x1"); setPX(512); cropCentre();
  pointer("pointerdown", corner("se"), 0, 0);
  pointer("pointermove", corner("se"), 99999, 99999);
  ok(CROP.x + CROP.w <= 1 + 1e-9, "still inside horizontally: " + (CROP.x + CROP.w));
  ok(CROP.y + CROP.h <= 1 + 1e-9, "still inside vertically: " + (CROP.y + CROP.h));
  ok(CROP.px <= PX_MAX, "and the budget respects its ceiling: " + CROP.px);
  near(CROP.w / CROP.h * (16 / 9), 1, 1e-9, "and it is still square");
});

test("a corner drag cannot shrink the box below the smallest budget", function () {
  cropReset(); addShaped(10, 1920, 1080); enableCrop();
  setAR("1x1"); setPX(512); cropCentre();
  pointer("pointerdown", corner("se"), 0, 0);
  pointer("pointermove", corner("se"), -99999, -99999);
  eq(CROP.px, PX_MIN, "the budget holds at the floor");
  eq(outDims().w, PX_MIN, "and so does the size that would be saved");
});

test("a pointermove with no drag in flight does nothing", function () {
  cropReset(); addShaped(10, 1920, 1080); enableCrop();
  setAR("1x1"); setPX(512); cropCentre();
  var before = [CROP.x, CROP.y, CROP.w];
  pointer("pointermove", FAKE.el("cropBox"), 1, 1);
  eqJson([CROP.x, CROP.y, CROP.w], before, "the box is untouched");
});

/* --- which frame the rectangle is measured against ------------------------ */

test("one track: the crop is measured against that track's own frame", function () {
  cropReset(); addShaped(10, 640, 360, "T1"); enableCrop();
  near(frameAR(), 640 / 360, 1e-9, "16:9");
  eq(frameTrack().token, "T1", "the only track");
});

test("several tracks: the crop is measured against track 1, the one they fit into", function () {
  cropReset();
  addShaped(10, 640, 360, "T1");
  addShaped(10, 480, 360, "T2");
  enableCrop();
  eq(frameTrack().token, "T1", "track 1 sets the output format");
  near(frameAR(), 640 / 360, 1e-9, "so its shape is the one being cropped");
});

test("[REGRESSION] trimming track 1 away moves the crop onto the clip that is left", function () {
  /* The server does not letterbox anything when only ONE file ends up
     contributing - the output simply is that file's frame. Measuring the
     rectangle against track 1 regardless would then cut a different part of
     the picture than the overlay drew. */
  cropReset();
  addShaped(10, 640, 360, "T1");     /* 16:9 */
  addShaped(10, 480, 360, "T2");     /* 4:3  */
  enableCrop();
  eq(frameTrack().token, "T1", "both tracks are in play to start with");
  pickAndDelete(5);                  /* the whole of track 1 */
  var toks = {}, kp = keptParts();
  for (var i = 0; i < kp.length; i++) toks[kp[i].t] = true;
  ok(!toks["T1"], "track 1 really is out of the export");
  eq(frameTrack().token, "T2", "so the frame being cropped is track 2's");
  near(frameAR(), 480 / 360, 1e-9, "4:3, which is what will actually come out");
});

/* --- what goes on the wire ------------------------------------------------ */

test("with the panel off, a save posts no crop at all", function () {
  cropReset(); addShaped(10, 1920, 1080);
  eq(cropPayload(), null, "nothing to send");
  FETCHES = [];
  save();
  var body = JSON.parse(FETCHES[FETCHES.length - 1].opts.body);
  ok(!body.hasOwnProperty("crop"), "the key is absent, not null: " + FETCHES[0].opts.body);
});

test("with the panel on, the save carries the offset and the size in real pixels", function () {
  cropReset(); addShaped(10, 1920, 1080); enableCrop();
  setAR("1x1"); setPX(512); cropCentre();
  FETCHES = [];
  save();
  var body = JSON.parse(FETCHES[FETCHES.length - 1].opts.body);
  ok(body.crop, "a crop was posted");
  eq(body.crop.ow, 512, "512 source pixels across");
  eq(body.crop.oh, 512, "and down");
  near(body.crop.x, (1 - 512 / 1920) / 2, 1e-9, "centred horizontally");
  ok(!body.crop.hasOwnProperty("w"), "no normalised size - the server works in whole pixels");
  ok(body.tokens.length === 1 && body.parts.length === 1, "the trim itself is unchanged");
});

test("whatever the user does, the posted rectangle is a legal one", function () {
  cropReset(); addShaped(10, 640, 360); enableCrop();
  var shapes = ["src", "1x1", "16x9", "9x16", "3x4", "4x5", "5x4"];
  for (var i = 0; i < shapes.length; i++) {
    setAR(shapes[i]);
    setPX(9999);                       /* deliberately more than this clip holds */
    /* drag it as far out of bounds as the handlers allow, then post */
    pointer("pointerdown", corner("se"), 0, 0);
    pointer("pointermove", corner("se"), 99999, 99999);
    pointer("pointerup", corner("se"), 0, 0);
    pointer("pointerdown", FAKE.el("cropBox"), 800, 450);
    pointer("pointermove", FAKE.el("cropBox"), -99999, 99999);
    pointer("pointerup", FAKE.el("cropBox"), 0, 0);
    var c = cropPayload();
    ok(c.x >= -1e-9 && c.y >= -1e-9, shapes[i] + ": negative offset");
    ok(c.x <= 1 + 1e-9 && c.y <= 1 + 1e-9, shapes[i] + ": offset past the frame");
    eq(c.ow % 2, 0, shapes[i] + ": odd width");
    eq(c.oh % 2, 0, shapes[i] + ": odd height");
    ok(c.ow >= 2 && c.oh >= 2, shapes[i] + ": empty rectangle");
    ok(c.ow <= 640, shapes[i] + ": width " + c.ow + " exceeds the 640px source");
    ok(c.oh <= 360, shapes[i] + ": height " + c.oh + " exceeds the 360px source");
  }
});

/* --- the panel itself ----------------------------------------------------- */

test("the panel starts closed and off, and reports as much", function () {
  cropReset(); addShaped(10, 1920, 1080);
  renderAdv();
  eq(CROP.on, false, "off by default");
  eq(FAKE.el("advChip").textContent, "off", "the chip says so");
  ok(!FAKE.el("adv").classList.contains("open"), "and the section is collapsed");
});

test("the header button opens and closes the section", function () {
  cropReset();
  FAKE.el("bAdv").onclick();
  ok(FAKE.el("adv").classList.contains("open"), "opened");
  FAKE.el("bAdv").onclick();
  ok(!FAKE.el("adv").classList.contains("open"), "and closed again");
});

test("turning the crop on shows the overlay and names the size", function () {
  cropReset(); addShaped(10, 1920, 1080);
  ok(!FAKE.el("cropWrap").classList.contains("on"), "hidden while off");
  enableCrop();
  setAR("1x1"); setPX(768);
  ok(FAKE.el("cropWrap").classList.contains("on"), "the overlay is shown");
  eq(FAKE.el("outDim").textContent, "768 x 768", "the panel names the size");
  eq(FAKE.el("advChip").textContent, "768 x 768", "and so does the collapsed header");
  eq(FAKE.el("cropLab").textContent, "768 x 768", "and the box itself");
});

test("a budget past what the clip holds settles at the clip's own maximum", function () {
  cropReset(); addShaped(10, 640, 360); enableCrop();
  setAR("1x1"); setPX(1024);
  eq(CROP.px, 360, "the request is brought down to what is actually there");
  eq(FAKE.el("outDim").textContent, "360 x 360", "and the panel shows the real size");
});

test("the overlay stays hidden until there is something to crop", function () {
  cropReset();
  CROP.on = true;
  renderCrop();
  ok(!FAKE.el("cropWrap").classList.contains("on"), "no tracks, no overlay");
});

test("the overlay is laid out over the frame, letterbox and all", function () {
  /* A 4:3 clip in a 16:9 stage is pillarboxed, and the box has to follow the
     picture rather than the stage. 900 tall at 4:3 is 1200 wide, leaving
     200px of bar down each side. */
  cropReset(); addShaped(10, 480, 360); enableCrop();
  setAR("4x3"); setPX(9999);           /* the whole frame at the clip's own shape */
  var f = frameRect();
  near(f.w, 1200, 1e-6, "the picture is 1200 wide");
  near(f.left, 200, 1e-6, "with a 200px bar on the left");
  near(parseFloat(FAKE.el("cropBox").style.left), 200, 0.01,
       "so a full-width crop starts at the picture, not the stage");
  near(parseFloat(FAKE.el("cropBox").style.width), 1200, 0.01, "and is as wide as the picture");
  eqJson(outDims(), { w: 480, h: 360 }, "and Max keeps every pixel, not two columns short");
});

test("the Save button owns up to the crop", function () {
  cropReset(); addShaped(10, 1920, 1080);
  eq(FAKE.el("txSave").textContent, "Save Trimmed Video", "plain trim");
  enableCrop(); setAR("1x1"); setPX(512);
  eq(FAKE.el("txSave").textContent, "Save Cropped Video", "with a crop");
  ok(FAKE.el("bSave").title.indexOf("512 x 512") >= 0,
     "and the size is in the tooltip: " + FAKE.el("bSave").title);
});

test("Centre only does anything while the crop is on", function () {
  cropReset(); addShaped(10, 1920, 1080);
  CROP.x = 0;
  FAKE.el("bCropCentre").onclick();
  near(CROP.x, 0, 1e-9, "Centre is inert while the panel is off");
  enableCrop(); setAR("1x1"); setPX(512);
  CROP.x = 0; cropSync();
  FAKE.el("bCropCentre").onclick();
  near(CROP.x, (1 - CROP.w) / 2, 1e-9, "and centres once it is on");
});

test("clearing the program leaves the crop settings alone but hides the overlay", function () {
  cropReset(); addShaped(10, 1920, 1080); enableCrop();
  setAR("1x1"); setPX(768);
  clearProgram();
  eq(CROP.on, true, "the panel stays as the user set it");
  eq(CROP.px, 768, "and so does the size");
  ok(!FAKE.el("cropWrap").classList.contains("on"), "but there is nothing to draw on");
});

/* ------------------------------- summary --------------------------------- */
say("");
say("==================================================");
say("total " + (PASSED + FAILED) + "   PASS " + PASSED + "   FAIL " + FAILED +
    "  (of which known bugs: " + FAILED_KNOWN + ", regressions: " + (FAILED - FAILED_KNOWN) + ")");
if (PROBLEMS.length) {
  say("");
  say("failures:");
  for (var pi = 0; pi < PROBLEMS.length; pi++) say("  " + (pi + 1) + ". " + PROBLEMS[pi]);
}
say("");
WScript.Quit(FAILED ? 1 : 0);
