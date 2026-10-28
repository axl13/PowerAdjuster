using Toybox.WatchUi as Ui;
using Toybox.System as Sys;
using Toybox.Math as Math;
using Toybox.Graphics as Gfx;
using Toybox.FitContributor as Fit;
using Toybox.UserProfile as UserProfile;
using Toybox.Activity as Activity;
using Toybox.Application as Application;
using Toybox.Time as Time;

// Constants for acclimatized power model based on MacInnis et al. (2013).
// % decrease in sustainable threshold power = C2 * alt^2 + C1 * alt + C0
const C0 = -0.6d;
const C1 = 0.0027d;
const C2 = 0.00000011d;

// Unacclimatized power model:
// - VO2max domain slope (~6.3% per 1000m) from Wehrlin & Hallén (2006) in elite endurance athletes.
// - Submaximal / LT1 domain slope (~3.5% per 1000m) to avoid over-inflating Z2 power at altitude.
const UNACCLIMATIZED_VO2_FACTOR = 0.063d / 1000.0d;
const UNACCLIMATIZED_SUBMAX_FACTOR = 0.035d / 1000.0d;
const UNACCL_DEADBAND_M = 150.0d;

// Separate EIAH VO2max pivots:
// - Population baseline (~55 ml/kg/min) for the MacInnis acclimatized polynomial.
// - Elite cohort baseline (~68 ml/kg/min) for Wehrlin & Hallén's 6.3%/km slope so we don't double-count.
const VO2_PIVOT_ACCL = 55.0;
const VO2_PIVOT_UNACCL = 68.0;

const rainbow = [
    Gfx.COLOR_LT_GRAY,
    Gfx.COLOR_DK_BLUE,
    Gfx.COLOR_DK_GREEN,
    Gfx.COLOR_YELLOW,
    Gfx.COLOR_ORANGE,
    Gfx.COLOR_RED,
    Gfx.COLOR_PURPLE ];
// Color of the highest zone (never black, which disappears on dark backgrounds).
const nightmare_color = Gfx.COLOR_PURPLE;

function clampVal(val, lo, hi) {
    if (val < lo) { return lo; }
    if (val > hi) { return hi; }
    return val;
}

// Calculates the power reduction factor for a fully acclimatized athlete.
function getAcclimatizedReductionFactor(alt, vo2maxAcclScalar) {
    if (alt <= 0) { return 1.0; }
    var percent_decrease = C2 * alt * alt + C1 * alt + C0;
    if (percent_decrease < 0) { percent_decrease = 0.0; }
    percent_decrease = percent_decrease * vo2maxAcclScalar;
    var factor = 1.0 - (percent_decrease / 100.0);
    return clampVal(factor, 0.1, 1.0);
}

// Reads user VO2max once when settings change (not in the 1Hz compute loop).
function getUserVo2Max() {
    var profile = UserProfile.getProfile();
    if (profile == null) { return null; }

    var vo2max = null;
    if (profile has :vo2maxCycling) {
        vo2max = profile.vo2maxCycling;
    }
    if ((vo2max == null || vo2max <= 0) && (profile has :vo2maxRunning)) {
        vo2max = profile.vo2maxRunning;
    }
    if (vo2max == null || vo2max <= 0) {
        return null;
    }
    return vo2max.toFloat();
}

function getVo2ScalarForPivot(vo2max, pivot) {
    if (vo2max == null || vo2max <= 0) { return 1.0; }
    var scalar = 1.0 + (vo2max - pivot) * 0.015;
    return clampVal(scalar, 0.7, 1.45);
}

// Blends unacclimatized altitude slope by relative intensity (watts / CP)
// so Z2 rides aren't over-inflated while Threshold/VO2max climbs get full protection.
function getUnacclimatizedSlope(watts, cpRef, vo2UnacclScalar) {
    var rel = (cpRef != null && cpRef > 0) ? (watts.toFloat() / cpRef) : 1.0;
    var t = clampVal((rel - 0.65) / 0.45, 0.0, 1.0);
    var baseSlope = UNACCLIMATIZED_SUBMAX_FACTOR + t * (UNACCLIMATIZED_VO2_FACTOR - UNACCLIMATIZED_SUBMAX_FACTOR);
    return baseSlope * vo2UnacclScalar;
}

// Converts power at the current altitude into its home-altitude equivalent:
// the un-adapted part of the altitude (above acclAlt) carries the acute penalty,
// the adapted part carries the chronic (MacInnis) penalty, then the chronic
// penalty at home altitude is re-applied so zones set at home stay valid.
function altPower(watts, currentAlt, acclAlt, homeAlt, vo2AcclScalar, vo2UnacclScalar, cpRef) {
    if (currentAlt == null || watts == null || watts <= 0) { return watts; }

    var unacclimatized_factor = getUnacclimatizedSlope(watts, cpRef, vo2UnacclScalar);

    var sea_level_watts;
    if (currentAlt > acclAlt) {
        var eff_diff = currentAlt - acclAlt - UNACCL_DEADBAND_M;
        if (eff_diff < 0) { eff_diff = 0.0; }
        var unacclimatized_reduction = clampVal(1.0 - (unacclimatized_factor * eff_diff), 0.1, 1.0);
        var power_at_accl_level = watts / unacclimatized_reduction;

        var reduction_at_accl_level = getAcclimatizedReductionFactor(acclAlt, vo2AcclScalar);
        sea_level_watts = power_at_accl_level / reduction_at_accl_level;
    } else {
        var reduction_at_current = getAcclimatizedReductionFactor(currentAlt, vo2AcclScalar);
        sea_level_watts = watts / reduction_at_current;
    }

    var reduction_at_home = getAcclimatizedReductionFactor(homeAlt, vo2AcclScalar);
    var home_equiv = sea_level_watts * reduction_at_home;

    // Acclimatization can only shrink the altitude penalty: never display more than
    // the fully unacclimatized conversion from home (keeps Z2 monotonic at >2,500 m).
    var acute_diff = currentAlt - homeAlt - UNACCL_DEADBAND_M;
    if (acute_diff > 0) {
        var acute_only = watts / clampVal(1.0 - (unacclimatized_factor * acute_diff), 0.1, 1.0);
        if (home_equiv > acute_only) { home_equiv = acute_only; }
    }
    return home_equiv;
}

class PowerDataField extends Ui.DataField {
  // FIT Contributor Field Ids
  const ADJUSTED_POWER_FIELD_ID = 0;
  const WBAL_FIELD_ID = 1;
  const WPRIME_FIELD_ID = 2;

  var DURATION = 0;
  var ALTPOWER = true;
  var VO2_ACCL_SCALAR = 1.0;
  var VO2_UNACCL_SCALAR = 1.0;
  // Altitude the body is currently adapted to (from the acclimatization model)
  var ACCLIMATIZATION_ALT = 300.0;
  var HOME_ALT = 300.0;
  var HOME_AUTO = true;
  var CP_REF = 318;
  var W_PRIME = 16500.0;
  var wBal = 16500.0;
  var cpAlt = 318.0;
  // Skiba W'bal ODE in deficit form (not clamped, so over-expenditure is measurable)
  var wDeficit = 0.0;
  var sessMaxDeficit = 0.0;
  var WP_AUTO = true;
  var wpLearner = null;
  var nowSec = 0;

  // Auto acclimatization tracker (see AcclModel.mc)
  var acclModel = null;
  var acclPct = 100;
  var acclSuffix = "";
  var lastAcclStep = 0;
  var lastAcclSave = 0;

  var power_array;
  var power_array_next_index = 0;
  var power_sum = 0.0;
  var power_array_complete = false;
  var label = "";
  // Power numbers for the end of each zone (Z1..Z6 ceilings; Z7 is above the last threshold).
  var my_zones = [];
  var my_rainbow = [];
  var font_o, font2_o;

  var adjustedPowerField = null;
  var wbalField = null;
  var wprimeField = null;
  var powerValue = -1;

  // Cached layout drawables (zero per-frame lookup)
  var valueDrawable = null;
  var labelDrawable = null;

  function getRawProperty(key) {
    try {
      if (Application has :Properties) {
        return Application.Properties.getValue(key);
      }
    } catch (e) {}
    return Application.getApp().getProperty(key);
  }

  function getPropNumber(key, defaultVal) {
    var v = getRawProperty(key);
    if (v == null) { return defaultVal; }
    var n = v.toNumber();
    return (n != null) ? n : defaultVal;
  }

  function getPropBool(key, defaultVal) {
    var v = getRawProperty(key);
    if (v == null) { return defaultVal; }
    if (v instanceof Toybox.Lang.Boolean) { return v; }
    return defaultVal;
  }

  function getPropString(key, defaultVal) {
    var v = getRawProperty(key);
    if (v == null) { return defaultVal; }
    return v.toString();
  }

  // Uses SDK 9.1 (API 5.2.2) UserProfile.getCurrentSport2() when available
  function getActiveSport() {
    if (UserProfile has :getCurrentSport2) {
      var sp = UserProfile.getCurrentSport2();
      if (sp != null && sp.size() > 0 && sp[0] != null) {
        return sp[0];
      }
    }
    return Activity.SPORT_CYCLING;
  }

  function buildRainbowColors() {
    my_rainbow = [];
    if (my_zones.size() == 0) { return; }
    // N thresholds define N+1 zones (e.g. 6 thresholds -> Z1..Z7)
    var zoneCount = my_zones.size() + 1;
    var rainbow_ratio = rainbow.size().toFloat() / zoneCount;
    for (var i = 0; i < zoneCount; ++i) {
      var index = Math.floor(i * rainbow_ratio).toNumber();
      if (index >= rainbow.size()) { index = rainbow.size() - 1; }
      my_rainbow.add(rainbow[index]);
    }
  }

  function MyZonesToDict(myzones_string) {
    my_zones = [];
    if (myzones_string != null && myzones_string.length() > 0) {
      var s = myzones_string + ",";
      var p = s.find(",");
      while (p != null) {
        var zone_power = s.substring(0, p).toNumber();
        if (zone_power != null && zone_power > 0) {
          self.my_zones.add(zone_power);
        }
        s = s.substring(p + 1, s.length());
        p = s.find(",");
      }
    }

    // SDK 9.1+ (API 5.2.2): Auto-populate from Garmin native power zones if setting was left blank
    if (my_zones.size() == 0 && (UserProfile has :getPowerZones)) {
      var pz = UserProfile.getPowerZones(getActiveSport());
      // Garmin returns [z1_min, z1_max, z2_max, ..., z7_max]
      if (pz != null && pz.size() >= 3) {
        for (var i = 1; i < (pz.size() - 1); i++) {
          if (pz[i] != null && pz[i] > 0) {
            my_zones.add(pz[i].toNumber());
          }
        }
      }
    }

    // Fallback to CP-derived zones if device does not support getPowerZones and setting is blank
    if (my_zones.size() == 0 && CP_REF > 0) {
      var pcts = [ 56, 78, 90, 100, 111, 127 ];
      for (var j = 0; j < pcts.size(); j++) {
        my_zones.add(Math.round(CP_REF * pcts[j] / 100.0).toNumber());
      }
    }

    buildRainbowColors();
  }

  function getPowerZone(power) {
    for (var i = 0; i < my_zones.size(); i++) {
      if (power < my_zones[i]) { return i; }
    }
    return my_zones.size();
  }

  function ColorMyZone(zone) {
    if (my_rainbow.size() == 0) { return Gfx.COLOR_LT_GRAY; }
    if (zone >= my_rainbow.size()) {
      return nightmare_color;
    }
    if (zone < 0) {
      zone = 0;
    }
    return my_rainbow[zone];
  }

  function getContrastTextColor(bgZoneColor) {
    if (bgZoneColor == Gfx.COLOR_LT_GRAY ||
        bgZoneColor == Gfx.COLOR_YELLOW ||
        bgZoneColor == Gfx.COLOR_ORANGE ||
        bgZoneColor == Gfx.COLOR_WHITE) {
      return Gfx.COLOR_BLACK;
    }
    return Gfx.COLOR_WHITE;
  }

  function whereInTheZone(zone, power) {
    if (power < 0 || my_zones.size() == 0) { return 0.0; }
    var min_power = 0;
    var max_power;
    if (zone >= my_zones.size()) {
      max_power = my_zones[my_zones.size() - 1] * 2;
      if (my_zones.size() > 1) {
        max_power = max_power - my_zones[my_zones.size() - 2];
      }
    } else {
      max_power = my_zones[zone];
    }
    if (zone > 0) {
      min_power = my_zones[zone - 1];
    }
    if (power > max_power) {
      return 1.0;
    }
    if (max_power - min_power <= 0) {
      return 0.0;
    }
    var ratio = (power - min_power).toFloat() / (max_power - min_power);
    return clampVal(ratio, 0.0, 1.0);
  }

  // Constructor
  function initialize() {
    Ui.DataField.initialize();
    font_o = Ui.loadResource(Rez.Fonts.outline_fnt);
    font2_o = Ui.loadResource(Rez.Fonts.outline2_fnt);

    DURATION = 0;
    // Always create the FIT field at init so toggling ALTPOWER mid-ride never null-derefs
    adjustedPowerField = createField(
        "adjusted_power",
        ADJUSTED_POWER_FIELD_ID,
        Fit.DATA_TYPE_UINT16,
        {:mesgType => Fit.MESG_TYPE_RECORD, :units => "W"}
    );
    // W' balance stream (kJ) and the W' in use at the end of the session (kJ)
    try {
      wbalField = createField(
          "wbal",
          WBAL_FIELD_ID,
          Fit.DATA_TYPE_FLOAT,
          {:mesgType => Fit.MESG_TYPE_RECORD, :units => "kJ"}
      );
      wprimeField = createField(
          "wprime",
          WPRIME_FIELD_ID,
          Fit.DATA_TYPE_FLOAT,
          {:mesgType => Fit.MESG_TYPE_SESSION, :units => "kJ"}
      );
    } catch (e) {
      wbalField = null;
      wprimeField = null;
    }

    onSettingsChanged();
  }

  function onSettingsChanged() {
    var newDuration = clampVal(getPropNumber("duration", 5), 1, 300);
    if (DURATION != newDuration) {
      DURATION = newDuration;
      power_array = new [DURATION];
      for (var i = 0; i < DURATION; i += 1) {
        power_array[i] = 0;
      }
      power_array_next_index = 0;
      power_sum = 0.0;
      power_array_complete = false;
    }
    ALTPOWER = getPropBool("altPower_prop", true);

    // Home altitude: 0 = learned from resting hours, > 0 = fixed
    var cfgHome = clampVal(getPropNumber("homeAlt_prop", 0), 0, 5000);
    HOME_AUTO = (cfgHome <= 0);
    if (acclModel == null) {
      acclModel = new AcclModel(cfgHome);
    } else {
      acclModel.configureHome(cfgHome);
    }
    HOME_ALT = acclModel.home;
    ACCLIMATIZATION_ALT = acclModel.effectiveAlt(acclModel.lastAlt);
    lastAcclStep = 0;

    // EIAH scaling from the Garmin VO2max estimate (clamped 0.7..1.45, 1.0 if unknown)
    var vo2 = getUserVo2Max();
    VO2_ACCL_SCALAR = getVo2ScalarForPivot(vo2, VO2_PIVOT_ACCL);
    VO2_UNACCL_SCALAR = getVo2ScalarForPivot(vo2, VO2_PIVOT_UNACCL);

    // Resolve CP / FTP: explicit setting -> SDK 9.1 UserProfile FTP -> Z4 ceiling -> 318W
    var cfgCp = getPropNumber("cp_prop", 0);
    if (cfgCp <= 0 && (UserProfile has :getFunctionalThresholdPower)) {
      var profFtp = UserProfile.getFunctionalThresholdPower(getActiveSport());
      if (profFtp != null && profFtp > 0) {
        cfgCp = profFtp.toNumber();
      }
    }
    CP_REF = (cfgCp > 0) ? cfgCp : 318;

    MyZonesToDict(getPropString("myZones_prop", ""));
    if (cfgCp <= 0 && my_zones.size() >= 4) {
      CP_REF = my_zones[3];
    }
    cpAlt = CP_REF.toFloat();

    // W': 0 = hands-free learner (see WprimeLearner.mc), > 0 = manual fixed value
    if (wpLearner == null) {
      wpLearner = new WprimeLearner();
    }
    var cfgW = getPropNumber("wPrime_prop", 0);
    WP_AUTO = (cfgW <= 0);
    if (WP_AUTO) {
      W_PRIME = wpLearner.estimate(Time.now().value());
    } else {
      W_PRIME = clampVal(cfgW, 5000, 45000).toFloat();
    }
    wBal = clampVal(W_PRIME - wDeficit, 0.0, W_PRIME);

    label = DURATION.toString() + "s";
    // "a" = altitude adjustment on; "a75%" = acclimation to current altitude (above 1,000 m)
    acclSuffix = ALTPOWER ? " a" : "";
  }

  // Advances the acclimatization model (~1/min) and refreshes the derived outputs
  function updateAccl(alt, now) {
    if (alt == null || acclModel == null) { return; }
    if ((now - lastAcclStep) < 60) { return; }
    lastAcclStep = now;

    acclModel.step(alt, now);
    if (HOME_AUTO) {
      HOME_ALT = acclModel.home;
    }
    ACCLIMATIZATION_ALT = acclModel.effectiveAlt(alt);
    acclPct = acclModel.pctFor(ACCLIMATIZATION_ALT, alt);
    if (!ALTPOWER) {
      acclSuffix = "";
    } else if (acclModel.isRelevant(alt)) {
      acclSuffix = " a" + acclPct.toString() + "%";
    } else {
      acclSuffix = " a";
    }

    if ((now - lastAcclSave) >= 300) {
      lastAcclSave = now;
      checkpoint(now);
    }
  }

  // Persists learned state and lets slowly-aging W' evidence soften
  function checkpoint(now) {
    if (acclModel != null) {
      acclModel.save();
    }
    if (wpLearner != null) {
      wpLearner.save();
      if (WP_AUTO) {
        var est = wpLearner.estimate(now);
        if (est != W_PRIME) {
          W_PRIME = est;
          wBal = clampVal(W_PRIME - wDeficit, 0.0, W_PRIME);
        }
      }
    }
  }

  function saveState() {
    if (acclModel != null) {
      acclModel.save();
    }
    if (wpLearner != null) {
      wpLearner.save();
    }
  }

  function onTimerStop() {
    saveState();
  }

  function onTimerPause() {
    saveState();
  }

  // New activity: fresh W' balance and a new evidence slot for the learner
  function onTimerReset() {
    saveState();
    wDeficit = 0.0;
    sessMaxDeficit = 0.0;
    wBal = W_PRIME;
    if (wpLearner != null) {
      wpLearner.newSession();
    }
  }

  // SDK 9.1+ (API 5.2.2) ClimbPro / Interval Split hook
  function onTimerSplitStart(splitInfo) {
  }

  function updateWbal(rawWatts, currentAlt) {
    if (ALTPOWER && currentAlt != null) {
      // Derate CP at current altitude relative to home altitude
      var eqAtAlt = altPower(CP_REF.toFloat(), currentAlt, ACCLIMATIZATION_ALT, HOME_ALT, VO2_ACCL_SCALAR, VO2_UNACCL_SCALAR, CP_REF);
      if (eqAtAlt > 10.0) {
        cpAlt = (CP_REF.toFloat() * CP_REF.toFloat()) / eqAtAlt;
      }
    } else {
      cpAlt = CP_REF.toFloat();
    }

    var p = (rawWatts != null && rawWatts > 0) ? rawWatts.toFloat() : 0.0;
    if (p > cpAlt) {
      wDeficit += (p - cpAlt);
    } else {
      // Skiba (2015) ODE recovery: proportional to the deficit fraction, capped at 1
      var f = wDeficit / W_PRIME;
      if (f > 1.0) { f = 1.0; }
      wDeficit -= (cpAlt - p) * f;
      if (wDeficit < 0.0) { wDeficit = 0.0; }
    }

    if (wDeficit > sessMaxDeficit) {
      sessMaxDeficit = wDeficit;
      if (WP_AUTO && wpLearner != null && wDeficit >= WP_MIN_EVIDENCE) {
        wpLearner.observe(wDeficit, nowSec);
        // Going deeper than the current W' proves W' is larger: adopt immediately
        if (wDeficit > W_PRIME) {
          W_PRIME = (wDeficit > wpLearner.wMax) ? wpLearner.wMax : wDeficit;
        }
      }
    }
    wBal = clampVal(W_PRIME - wDeficit, 0.0, W_PRIME);
  }

  function compute(info) {
    var isRunning = true;
    if (info has :timerState && info.timerState != null) {
      isRunning = (info.timerState == Activity.TIMER_STATE_ON);
    }

    nowSec = Time.now().value();
    updateAccl(info.altitude, nowSec);

    if (info.currentPower != null) {
      var rawPower = info.currentPower;
      var avgPower = rawPower.toFloat();

      if (ALTPOWER) {
        avgPower = altPower(avgPower, info.altitude, ACCLIMATIZATION_ALT, HOME_ALT, VO2_ACCL_SCALAR, VO2_UNACCL_SCALAR, CP_REF);
      }

      if (isRunning) {
        updateWbal(rawPower, info.altitude);
      }

      if (isRunning || !power_array_complete) {
        var sampleWatts = Math.round(avgPower).toNumber();
        power_sum -= power_array[power_array_next_index];
        power_array[power_array_next_index] = sampleWatts;
        power_sum += sampleWatts;
        ++power_array_next_index;
        if (power_array_next_index >= DURATION) {
          power_array_next_index = 0;
          power_array_complete = true;
        }
      }
      var denom = power_array_complete ? DURATION : power_array_next_index;
      if (denom < 1) { denom = 1; }
      var watts = power_sum.toFloat() / denom;
      powerValue = Math.round(watts).toNumber();
    } else {
      powerValue = -1;
    }

    if (ALTPOWER && adjustedPowerField != null) {
      var valueToRecord = (powerValue >= 0) ? powerValue : 0;
      adjustedPowerField.setData(valueToRecord);
    }
    if (wbalField != null) {
      wbalField.setData(wBal / 1000.0);
    }
    if (wprimeField != null) {
      wprimeField.setData(W_PRIME / 1000.0);
    }
  }

  function onLayout(dc) {
    setLayout(Rez.Layouts.PowerFieldLayout(dc));
    valueDrawable = Ui.View.findDrawableById("value");
    labelDrawable = Ui.View.findDrawableById("label");
  }

  function drawZones(dc, zone, power) {
    var color = Gfx.COLOR_LT_GRAY;
    var m = whereInTheZone(zone, power);
    var w = dc.getWidth();
    var h = dc.getHeight();
    var zone_width = 0.8 * w; // 80% of the datafield. Don't go below 50%!
    var b1 = (w / 2.0) - (m * zone_width);
    var b2 = b1 + zone_width;

    if (b1 < 0) { b1 = 0; }
    if (b2 > w) { b2 = w; }

    if (b1 > 0) {
      dc.setColor(ColorMyZone(zone - 1), color);
      dc.fillRectangle(0, 0, b1, h);
    }
    dc.setColor(ColorMyZone(zone), color);
    dc.fillRectangle(b1, 0, b2 - b1, h);
    if (b2 < w) {
      dc.setColor(ColorMyZone(zone + 1), color);
      dc.fillRectangle(b2, 0, w - b2, h);
    }
  }

  function drawWbalBar(dc, wPct) {
    var w = dc.getWidth();
    var barH = 5;
    var fillW = Math.round((w * wPct) / 100.0).toNumber();
    var barColor = Gfx.COLOR_GREEN;
    if (wPct < 25) {
      barColor = Gfx.COLOR_RED;
    } else if (wPct < 55) {
      barColor = Gfx.COLOR_ORANGE;
    }
    dc.setColor(Gfx.COLOR_DK_GRAY, Gfx.COLOR_TRANSPARENT);
    dc.fillRectangle(0, 0, w, barH);
    if (fillW > 0) {
      dc.setColor(barColor, Gfx.COLOR_TRANSPARENT);
      dc.fillRectangle(0, 0, fillW, barH);
    }
  }

  function onUpdate(dc) {
    var bg_color = getBackgroundColor();
    var fg_color = (bg_color == Gfx.COLOR_BLACK) ? Gfx.COLOR_WHITE : Gfx.COLOR_BLACK;
    var v = (valueDrawable != null) ? valueDrawable : Ui.View.findDrawableById("value");
    var l = (labelDrawable != null) ? labelDrawable : Ui.View.findDrawableById("label");

    dc.setColor(fg_color, bg_color);
    dc.clear();

    var wPct = (W_PRIME > 0) ? Math.round((wBal / W_PRIME) * 100.0).toNumber() : 100;
    wPct = clampVal(wPct, 0, 100);

    var zone_prefix = "";
    var textColor = fg_color;

    if (powerValue > -1) {
      var powerStr = powerValue.toString();
      if (my_zones.size() > 0) {
        var zone = getPowerZone(powerValue);
        var activeZoneColor = ColorMyZone(zone);
        textColor = getContrastTextColor(activeZoneColor);
        zone_prefix = "Z" + (zone + 1).toString() + " ";

        drawZones(dc, zone, powerValue);
        drawWbalBar(dc, wPct);

        if (v != null) {
          v.setText("");
        }

        var cx = dc.getWidth() / 2;
        var cy = dc.getHeight() / 2;
        dc.setColor(Gfx.COLOR_WHITE, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, cy, font_o, powerStr,
                    Gfx.TEXT_JUSTIFY_CENTER | Gfx.TEXT_JUSTIFY_VCENTER);
        dc.setColor(Gfx.COLOR_BLACK, Gfx.COLOR_TRANSPARENT);
        dc.drawText(cx, cy, font2_o, powerStr,
                    Gfx.TEXT_JUSTIFY_CENTER | Gfx.TEXT_JUSTIFY_VCENTER);
      } else {
        drawWbalBar(dc, wPct);
        if (v != null) {
          v.setColor(fg_color);
          v.setText(powerStr);
          v.draw(dc);
        }
      }
    } else {
      drawWbalBar(dc, wPct);
      if (v != null) {
        v.setColor(fg_color);
        v.setText("-");
        v.draw(dc);
      }
    }

    if (l != null) {
      l.setColor(textColor);
      l.setText(zone_prefix + label + acclSuffix);
      l.draw(dc);
    }
  }
}
