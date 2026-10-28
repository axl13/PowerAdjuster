using Toybox.Math as Math;
using Toybox.Application as Application;

// ---------------------------------------------------------------------------
// Two-compartment altitude acclimatization model + learned home altitude
//
// FAST compartment  : ventilatory / plasma-volume / 2,3-DPG adaptation.
//                     tau_on ~4 d, tau_off ~6 d. Stimulus only above ~800 m.
// SLOW compartment  : erythropoietic (Hb-mass) adaptation. ~1 %/100 h above
//                     ~2,100 m (Gore et al. 2013), negligible below ~1,500 m.
//                     Onset lag ~3 d (gated by FAST progress), tau_on ~21 d,
//                     tau_off ~14 d (neocytolysis-dominated loss).
// Altitude memory   : repeated exposures within ~2 months re-acclimatize faster
//                     (tau_on shortened by up to 40 %).
// Effective acclimatized altitude A_eff mixes FAST and SLOW with an altitude
// dependent weight: up to 1,800 m acclimatization is essentially ventilatory,
// above that the hematological share grows (max 50 % at 4,800 m).
//
// Home altitude     : learned as the mode of a slowly-forgetting histogram of
//                     resting (off-device) hours per 100 m bin, i.e. where the
//                     athlete sleeps most. A 3-week camp never outweighs months
//                     at home; a relocation flips the mode after a few weeks.
//
// State survives power cycles via Application.Storage. Off-device gaps are
// integrated at the estimated resting (sleeping) altitude.
// ---------------------------------------------------------------------------

const ACC_FAST_MIN_ALT = 800.0;
const ACC_SLOW_MIN_ALT = 1500.0;
const ACC_SLOW_W_START = 1800.0;
const ACC_SLOW_W_SPAN = 3000.0;
const ACC_SLOW_W_MAX = 0.5;
const ACC_TAU_F_ON = 4.0 * 86400.0;
const ACC_TAU_F_OFF = 6.0 * 86400.0;
const ACC_TAU_S_ON = 21.0 * 86400.0;
const ACC_TAU_S_OFF = 14.0 * 86400.0;
const ACC_TAU_M_ON = 14.0 * 86400.0;
const ACC_TAU_M_OFF = 60.0 * 86400.0;
const ACC_MEM_GAIN = 0.4;
const ACC_SLOW_GATE_FRAC = 0.55;
const ACC_GAP_THRESHOLD = 1800.0;
const ACC_MAX_GAP = 90.0 * 86400.0;
const ACC_GAP_CHUNK_MIN = 7200.0;
const ACC_GAP_MAX_STEPS = 120;
const ACC_REST_ALT_TOL = 300.0;
const ACC_SHOW_MIN_ALT = 1000.0;
const ACC_SHOW_DEADBAND = 150.0;
const ACC_HOME_BINS = 31;                 // 0..3000 m in 100 m bins
const ACC_HOME_BIN_M = 100.0;
const ACC_HOME_TAU = 120.0 * 86400.0;     // forgetting time constant
const ACC_HOME_MIN_HOURS = 24.0;          // evidence needed before trusting the mode
const ACC_DEFAULT_HOME = 300.0;
const ACC_STORAGE_KEY = "acclState";
const ACC_HOME_KEY = "homeHist";
const ACC_E = 2.7182818;

class AcclModel {
  var home = ACC_DEFAULT_HOME;
  var homeAuto = true;
  var t = null;        // epoch seconds of last update (null = never updated)
  var fast = ACC_DEFAULT_HOME;    // m, fast compartment acclimatized altitude
  var slow = ACC_DEFAULT_HOME;    // m, slow compartment acclimatized altitude
  var mem = 0.0;                  // 0..1 altitude memory
  var lastAlt = ACC_DEFAULT_HOME; // m, last altitude seen (resting-altitude proxy)
  var homeHist = null;            // resting hours per 100 m bin
  var homeDirty = false;

  // cfgHome <= 0 -> learn home altitude, > 0 -> fixed
  function initialize(cfgHome) {
    homeHist = new [ACC_HOME_BINS];
    for (var i = 0; i < ACC_HOME_BINS; i++) { homeHist[i] = 0.0; }
    load();
    configureHome(cfgHome);
  }

  function configureHome(cfgHome) {
    if (cfgHome != null && cfgHome > 0) {
      homeAuto = false;
      setHome(cfgHome);
    } else {
      homeAuto = true;
      var h = learnedHome();
      if (h != null) {
        setHome(h);
      } else if (t != null) {
        setHome(lastAlt);   // no resting evidence yet: best guess is where we last were
      }
    }
  }

  function setHome(homeAlt) {
    home = (homeAlt != null) ? clampVal(homeAlt.toFloat(), -500.0, 5000.0) : ACC_DEFAULT_HOME;
    if (fast < home) { fast = home; }
    if (slow < home) { slow = home; }
  }

  // 1 - exp(-dt/tau), linearised for small steps (no pow() in the 1 Hz path)
  function kFactor(dt, tau) {
    var x = dt / tau;
    if (x < 0.05) { return x; }
    if (x > 20.0) { return 1.0; }
    return 1.0 - Math.pow(ACC_E, -x);
  }

  // Integrates one chunk of dt seconds spent at a constant altitude
  function advance(altIn, dt) {
    if (dt <= 0) { return; }
    var alt = clampVal(altIn.toFloat(), -500.0, 9000.0);
    var memSpeed = 1.0 - ACC_MEM_GAIN * mem;
    var tgt = (alt > home) ? alt : home;

    // FAST compartment
    if (alt >= ACC_FAST_MIN_ALT && alt > fast) {
      fast += (alt - fast) * kFactor(dt, ACC_TAU_F_ON * memSpeed);
    } else if (tgt < fast) {
      fast += (tgt - fast) * kFactor(dt, ACC_TAU_F_OFF);
    }

    // SLOW compartment (onset gated by FAST progress -> ~3 day lag)
    if (alt >= ACC_SLOW_MIN_ALT && alt > slow) {
      var span = alt - home;
      var frac = (span > 0) ? ((fast - home) / span) : 1.0;
      var gate = clampVal(frac / ACC_SLOW_GATE_FRAC, 0.0, 1.0);
      if (gate > 0) {
        slow += (alt - slow) * kFactor(dt * gate, ACC_TAU_S_ON * memSpeed);
      }
    } else if (tgt < slow) {
      slow += (tgt - slow) * kFactor(dt, ACC_TAU_S_OFF);
    }

    // Altitude memory
    if (alt >= ACC_SLOW_MIN_ALT) {
      mem += (1.0 - mem) * kFactor(dt, ACC_TAU_M_ON);
    } else {
      mem -= mem * kFactor(dt, ACC_TAU_M_OFF);
    }

    fast = clampVal(fast, home, 9000.0);
    slow = clampVal(slow, home, 9000.0);
    mem = clampVal(mem, 0.0, 1.0);
  }

  // Adds resting hours at restAlt to the home histogram (with forgetting)
  function accrueRest(restAlt, gapSec) {
    var decay = Math.pow(ACC_E, -(gapSec / ACC_HOME_TAU));
    for (var i = 0; i < ACC_HOME_BINS; i++) {
      homeHist[i] = homeHist[i] * decay;
    }
    var bin = Math.round(restAlt / ACC_HOME_BIN_M).toNumber();
    bin = clampVal(bin, 0, ACC_HOME_BINS - 1);
    homeHist[bin] = homeHist[bin] + gapSec / 3600.0;
    homeDirty = true;
  }

  // Mode of the resting-hours histogram, or null while evidence is thin
  function learnedHome() {
    if (homeHist == null) { return null; }
    var total = 0.0;
    var bestI = 0;
    var bestV = -1.0;
    for (var i = 0; i < ACC_HOME_BINS; i++) {
      total += homeHist[i];
      if (homeHist[i] > bestV) {
        bestV = homeHist[i];
        bestI = i;
      }
    }
    if (total < ACC_HOME_MIN_HOURS) { return null; }
    return bestI * ACC_HOME_BIN_M;
  }

  // Feed a live altitude sample (call about once per minute)
  function step(alt, now) {
    if (alt == null || now == null) { return; }
    if (t == null) {
      t = now;
      lastAlt = alt.toFloat();
      if (homeAuto && learnedHome() == null) {
        setHome(lastAlt);
        fast = home;
        slow = home;
      }
      return;
    }
    var dt = (now - t).toFloat();
    if (dt <= 0) {
      t = now;
      return;
    }
    if (dt > ACC_GAP_THRESHOLD) {
      // Device was off: integrate the gap at the estimated resting altitude.
      // If we moved a lot during the gap, assume the lower place (travel day,
      // ride that ended on a pass) to avoid crediting dose that was never taken.
      var a = alt.toFloat();
      var rest;
      if ((lastAlt - a).abs() > ACC_REST_ALT_TOL) {
        rest = (lastAlt < a) ? lastAlt : a;
      } else {
        rest = 0.5 * (lastAlt + a);
      }
      var gap = (dt > ACC_MAX_GAP) ? ACC_MAX_GAP : dt;
      accrueRest(rest, gap);
      if (homeAuto) {
        var h = learnedHome();
        if (h != null) { setHome(h); }
      }
      var chunk = gap / ACC_GAP_MAX_STEPS;
      if (chunk < ACC_GAP_CHUNK_MIN) { chunk = ACC_GAP_CHUNK_MIN; }
      var remaining = gap;
      while (remaining > 0) {
        var d = (remaining > chunk) ? chunk : remaining;
        advance(rest, d);
        remaining -= d;
      }
    } else {
      advance(alt, dt);
    }
    t = now;
    lastAlt = alt.toFloat();
  }

  // Altitude the body is currently adapted to, evaluated for the given altitude
  function effectiveAlt(alt) {
    var a = (alt != null) ? alt.toFloat() : home;
    var w = clampVal((a - ACC_SLOW_W_START) / ACC_SLOW_W_SPAN, 0.0, ACC_SLOW_W_MAX);
    return home + (1.0 - w) * (fast - home) + w * (slow - home);
  }

  // Acclimation % to the current altitude (Garmin convention): 100 at/below home
  function pctFor(acclAlt, alt) {
    if (alt == null) { return 100; }
    var span = alt.toFloat() - home;
    if (span <= 0) { return 100; }
    var f = clampVal((acclAlt.toFloat() - home) / span, 0.0, 1.0);
    return Math.round(f * 100.0).toNumber();
  }

  function isRelevant(alt) {
    if (alt == null) { return false; }
    return (alt >= ACC_SHOW_MIN_ALT) && (alt > home + ACC_SHOW_DEADBAND);
  }

  // ----- persistence -----
  function storageGet(key) {
    try {
      if (Application has :Storage) {
        return Application.Storage.getValue(key);
      }
      return Application.getApp().getProperty(key);
    } catch (e) {
      return null;
    }
  }

  function storageSet(key, val) {
    try {
      if (Application has :Storage) {
        Application.Storage.setValue(key, val);
      } else {
        Application.getApp().setProperty(key, val);
      }
    } catch (e) {}
  }

  function load() {
    var s = storageGet(ACC_STORAGE_KEY);
    if (s != null && (s instanceof Toybox.Lang.Array) && s.size() >= 5) {
      try {
        if (s[0] != null) { t = s[0].toNumber(); }
        if (s[1] != null) { fast = clampVal(s[1].toFloat(), -500.0, 9000.0); }
        if (s[2] != null) { slow = clampVal(s[2].toFloat(), -500.0, 9000.0); }
        if (s[3] != null) { mem = clampVal(s[3].toFloat(), 0.0, 1.0); }
        if (s[4] != null) { lastAlt = clampVal(s[4].toFloat(), -500.0, 9000.0); }
      } catch (e) {
        t = null;
        fast = ACC_DEFAULT_HOME;
        slow = ACC_DEFAULT_HOME;
        mem = 0.0;
        lastAlt = ACC_DEFAULT_HOME;
      }
    }
    var h = storageGet(ACC_HOME_KEY);
    if (h != null && (h instanceof Toybox.Lang.Array) && h.size() == ACC_HOME_BINS) {
      for (var i = 0; i < ACC_HOME_BINS; i++) {
        homeHist[i] = (h[i] != null) ? clampVal(h[i].toFloat(), 0.0, 100000.0) : 0.0;
      }
    }
  }

  function save() {
    if (t != null) {
      storageSet(ACC_STORAGE_KEY, [t, fast, slow, mem, lastAlt]);
    }
    if (homeDirty) {
      storageSet(ACC_HOME_KEY, homeHist);
      homeDirty = false;
    }
  }
}
