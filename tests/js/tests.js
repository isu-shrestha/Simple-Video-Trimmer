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
  hist = [];
  mode = "video"; vOk = true;
  selPlay = false; skipGuardUntil = 0; restarting = false;
  playStart = 0; dragging = null; saving = false;
  TOKSEQ = 0;
  TIMERS = []; FETCHES = [];
  var vEl = FAKE.el("v");
  vEl.paused = true; vEl.currentTime = 0; vEl.style.display = "block";
}
function addTracks() {
  for (var i = 0; i < arguments.length; i++) {
    var a = arguments[i];
    if (typeof a === "number") acceptTrack(mkTrack(a));
    else acceptTrack(mkTrack(a[0], { token: a[1], fps: a[2] }));
  }
}
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
