using Toybox.Application as Application;
using Toybox.UserProfile as UserProfile;

// ---------------------------------------------------------------------------
// Hands-free W' (anaerobic work capacity) learner
//
// Evidence: the largest W' depletion observed in a session, taken from the
// un-clamped Skiba W'bal ODE that the data field integrates anyway. Every
// depletion is a lower bound of the athlete's true W', so the estimate is the
// best valid piece of evidence in the history.
//
// Detraining / invalidation: evidence is taken at full value for 42 days, then
// softened linearly to 80 % by day 90 and dropped afterwards, so W' glides down
// unless it is re-proven by a new hard effort. Increases are adopted at once.
// Without any evidence the estimate falls back to a weight-scaled prior
// (~0.21 kJ/kg, typical for a low-VLamax endurance profile).
// ---------------------------------------------------------------------------

const WP_DAY = 86400;
const WP_FRESH_DAYS = 42;
const WP_VALID_DAYS = 90;
const WP_SOFT_MIN = 0.8;
const WP_MIN_EVIDENCE = 3000.0;
const WP_MAX_ENTRIES = 6;
const WP_PRIOR_PER_KG = 210.0;
const WP_MIN_PER_KG = 100.0;
const WP_MAX_PER_KG = 450.0;
const WP_DEFAULT_PRIOR = 16500.0;
const WP_DEFAULT_MIN = 6000.0;
const WP_DEFAULT_MAX = 35000.0;
const WP_STORAGE_KEY = "wpHist";

class WprimeLearner {
  var prior = WP_DEFAULT_PRIOR;
  var wMin = WP_DEFAULT_MIN;
  var wMax = WP_DEFAULT_MAX;
  var hist = [];      // flat: [depletion J, epoch s, depletion J, epoch s, ...]
  var sessIdx = -1;   // position of this session's entry in hist (-1 = none yet)

  function initialize() {
    var kg = null;
    try {
      var prof = UserProfile.getProfile();
      if (prof != null && prof.weight != null && prof.weight > 20000) {
        kg = prof.weight / 1000.0;
      }
    } catch (e) {
      kg = null;
    }
    if (kg != null) {
      prior = WP_PRIOR_PER_KG * kg;
      wMin = WP_MIN_PER_KG * kg;
      wMax = WP_MAX_PER_KG * kg;
    }
    load();
  }

  // 1.0 while fresh, 0.8 at the validity horizon, 0 (invalid) beyond it
  function softness(ageSec) {
    var days = ageSec / WP_DAY;
    if (days <= WP_FRESH_DAYS) { return 1.0; }
    if (days >= WP_VALID_DAYS) { return 0.0; }
    return 1.0 - (1.0 - WP_SOFT_MIN) * (days - WP_FRESH_DAYS).toFloat() / (WP_VALID_DAYS - WP_FRESH_DAYS);
  }

  // Current best estimate of W' in joules
  function estimate(now) {
    var best = 0.0;
    for (var i = 0; i + 1 < hist.size(); i += 2) {
      var v = hist[i] * softness(now - hist[i + 1]);
      if (v > best) { best = v; }
    }
    var w = (best > 0.0) ? best : prior;
    return clampVal(w, wMin, wMax);
  }

  // Feed the session's running maximum depletion (call only when it grows)
  function observe(deficit, now) {
    if (deficit < WP_MIN_EVIDENCE) { return; }
    var v = (deficit > wMax) ? wMax : deficit;
    if (sessIdx >= 0 && sessIdx + 1 < hist.size()) {
      if (v > hist[sessIdx]) {
        hist[sessIdx] = v;
        hist[sessIdx + 1] = now;
      }
      return;
    }
    prune(now);
    if (hist.size() >= WP_MAX_ENTRIES * 2) {
      // replace the weakest (softened) entry
      var worstI = 0;
      var worstV = 1.0e12;
      for (var i = 0; i + 1 < hist.size(); i += 2) {
        var sv = hist[i] * softness(now - hist[i + 1]);
        if (sv < worstV) {
          worstV = sv;
          worstI = i;
        }
      }
      hist[worstI] = v;
      hist[worstI + 1] = now;
      sessIdx = worstI;
      return;
    }
    sessIdx = hist.size();
    hist.add(v);
    hist.add(now);
  }

  // Drop entries older than the validity horizon
  function prune(now) {
    var kept = [];
    var newSess = -1;
    for (var i = 0; i + 1 < hist.size(); i += 2) {
      if ((now - hist[i + 1]) < WP_VALID_DAYS * WP_DAY) {
        if (i == sessIdx) { newSess = kept.size(); }
        kept.add(hist[i]);
        kept.add(hist[i + 1]);
      }
    }
    hist = kept;
    sessIdx = newSess;
  }

  function newSession() {
    sessIdx = -1;
  }

  // ----- persistence -----
  function load() {
    var s = null;
    try {
      if (Application has :Storage) {
        s = Application.Storage.getValue(WP_STORAGE_KEY);
      } else {
        s = Application.getApp().getProperty(WP_STORAGE_KEY);
      }
    } catch (e) {
      s = null;
    }
    if (s == null || !(s instanceof Toybox.Lang.Array)) { return; }
    var clean = [];
    for (var i = 0; i + 1 < s.size(); i += 2) {
      if (s[i] != null && s[i + 1] != null) {
        clean.add(clampVal(s[i].toFloat(), 0.0, wMax));
        clean.add(s[i + 1].toNumber());
      }
    }
    hist = clean;
    sessIdx = -1;
  }

  function save() {
    try {
      if (Application has :Storage) {
        Application.Storage.setValue(WP_STORAGE_KEY, hist);
      } else {
        Application.getApp().setProperty(WP_STORAGE_KEY, hist);
      }
    } catch (e) {}
  }
}
