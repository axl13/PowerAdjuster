using Toybox.WatchUi as Ui;
using Toybox.System as Sys;
using Toybox.Math as Math;
using Toybox.AntPlus as AntPlus;
using Toybox.Graphics as Gfx;


const a0 = -174.1448622d;
const a1 = 1.0899959d;
const a2 = -0.0015119d;
const a3 = 0.00000072674d;
const rainbow = [
    Gfx.COLOR_LT_GRAY,
    Gfx.COLOR_DK_BLUE,
    Gfx.COLOR_DK_GREEN,
    Gfx.COLOR_YELLOW,
    Gfx.COLOR_ORANGE,
    Gfx.COLOR_RED,
    Gfx.COLOR_PURPLE ];
// Color of the zone above the last value in myZones_prop.
const nightmare_color = Gfx.COLOR_BLACK;

function altPower(watts, alt) {
  if (alt > 0) {
    // pbar [mbar]= 0.76*EXP( -alt[m] / 7000 )*1000
    var pbar = 0.76 * Math.pow(Math.E, alt / -7000.00) * 1000.00;
    // %Vo2max= a0 + a1 * pbar + a2 * pbar ^2 + a3 * pbar ^3 (with pbar in mbar)
    var vo2maxPCT = a0 + pbar * (a1 + pbar * (a2 + a3 * pbar));
    return (watts / vo2maxPCT) * 100;
  } else {
    return watts;
  }
}

function chkPcnt(percent) {
  return (percent >= 0) and (percent <= 100);
}

function min(first, second) {
  return (first < second) ? first : second;
}

class Slope {
  var x_values = [0];
  var y_values = [0];
  var valid = false;

  function initialize(config) {
    try {
      self.SlopeToDict(config);
      self.sort();
    } finally {
      valid = true;
    }
  }

  function getX(i) {
    return x_values[i];
  }

  function getY(i) {
    return y_values[i];
  }

  function size() {
    return x_values.size();
  }

  function sort() {
    for (var i=0; i<(self.size()-1); i++){
      for(var j=i;j<(self.size()-1); j++){
        var x_tmp = self.x_values[j];
        var y_tmp = self.y_values[j];
        if( self.getX(j+1) < self.getX(j)) {
          self.x_values[j] = self.getX(j+1);
          self.y_values[j] = self.getY(j+1);
          self.x_values[j+1] = x_tmp;
          self.y_values[j+1] = y_tmp;
        }
      }
    }
  }

  // to parse something like 192:202,286:306,333:351,388:407,616:644,1068:1079
  function SlopeToDict(slope_string) {
    var p, n;
    slope_string += ",";
    p = slope_string.find(",");
    while(p != null){
      n = slope_string.find(":");
      self.x_values.add(slope_string.substring(0,n).toNumber());
      self.y_values.add(slope_string.substring(n+1,p).toNumber());
      slope_string = slope_string.substring(p+1,slope_string.length());
      p = slope_string.find(",");
    }
    self.x_values.add(10000);
    self.y_values.add(10000);
  }

  function linear_interpolation(x0, y0, x1, y1, x) {
    var a = (y1 - y0).toFloat() / (x1 - x0);
    var b = -a*x0 + y0;
    return a * x + b;
  }

  function interpolate(x) {
    var i = 0;
    while ((x > self.x_values[i]) && (i < self.x_values.size())) {
      i++;
    }
    if (i > 0){
      return self.linear_interpolation(
          self.x_values[i-1], self.y_values[i-1],
          self.x_values[i], self.y_values[i], x);
    }
    return 0;
  }

}

// Unused now, will replace items in power_chart_array and power_chart_color_array below.
class PowerValue {
  var value;
  var color;
  var chart_height;
}

class PowerDataField extends Ui.DataField {
  const POWER_MULTIPLIER = Application.getApp().getProperty("multiplier").toFloat();
  const DURATION = Application.getApp().getProperty("duration").toNumber();
  const SLOPE = new Slope(Application.getApp().getProperty("slope"));
  const ALTPOWER = Application.getApp().getProperty("altPower_prop");
  const PURE_POWER = Application.getApp().getProperty("purePower_prop");
  const HOMEALT = Application.getApp().getProperty("homeElevation_prop").toNumber();
  const ALT_FONT = Application.getApp().getProperty("altFont_prop");

  // This is the maximum chart width we can draw on this device.
  const CHART_MARGIN = 8;
  const CHART_WIDTH = System.getDeviceSettings().screenWidth - 2 * CHART_MARGIN;
  var homealt_factor = 1;
  var dc_height = 0;

  var power_chart_array = new [CHART_WIDTH];
  var power_chart_color_array = new [CHART_WIDTH];
  var power_chart_array_complete = false;
  var power_chart_array_next_index = 0;
  var power_array = new [DURATION];
  var power_array_next_index = 0;
  var power_sum = 0;
  var power_array_complete = false;
  var bikePower;
  var bikePowerListener;
  var label;
  // Power numbers for the end of the zone. 0 is implicitly the beginning of the first zone.
  var my_zones = [];
  var my_rainbow = [];
  var font_o, font2_o;

  var powerValue = -1;
  var cadence_value = -1;

  function AddPowerToChart(power, color) {
    var power_factor = dc_height.toFloat() / my_zones[my_zones.size() - 1];
    power_chart_array[power_chart_array_next_index] = (power_factor * power).toNumber();
    power_chart_color_array[power_chart_array_next_index] = color;
    ++power_chart_array_next_index;
    if (power_chart_array_next_index >= CHART_WIDTH) {
      power_chart_array_next_index = 0;
      power_chart_array_complete = true;
    }
  }

  function MyZonesToDict(myzones_string)  {
    var p;
    myzones_string += ",";
    //Sys.println(myzones_string);
    p = myzones_string.find(",");
    while (p != null) {
      var zone_power = myzones_string.substring(0, p).toNumber();
      if (zone_power != null) {
        self.my_zones.add(zone_power);
      }
      myzones_string = myzones_string.substring(p+1, myzones_string.length());
      p = myzones_string.find(",");
    }
    if (my_zones.size() == 0) {
      return;
    }
    var rainbow_ratio = rainbow.size().toFloat() / my_zones.size();
    for (var i = 0; i < my_zones.size(); ++i) {
      var index = Math.floor(i * rainbow_ratio).toNumber();
      var color = rainbow[index];
      my_rainbow.add(color);
      // Sys.println("my_rainbow at " + i + " is " + index + " index, " + color);
    }
  }

  function getPowerZone(power) {
    for (var i = 0; i < my_zones.size(); i++) {
      if (power < my_zones[i]) { return i; }
    }
    // Means we're at the last zone.
    return my_zones.size();
  }

  function ColorMyZone(zone) {
    if (zone >= my_rainbow.size()) {
      return nightmare_color;
    }
    if (zone < 0) {
      zone = 0;
    }
    return my_rainbow[zone];
  }

  // Constructor
  function initialize() {
    Ui.DataField.initialize();
    if (ALT_FONT) {
      font_o = Ui.loadResource(Rez.Fonts.outline_fnt);
      font2_o = Ui.loadResource(Rez.Fonts.outline2_fnt);
    }
    if (PURE_POWER) {
      bikePowerListener = new AntPlus.BikePowerListener();
      bikePower = new AntPlus.BikePower(bikePowerListener);
    }
    label = "Pwr." + DURATION.toString() + "s " +
            (ALTPOWER ? "(a)" : "") + (PURE_POWER ? "(p)" : "");
    for (var i = 0; i < DURATION; i += 1) {
      power_array[i] = 0;
    }
    MyZonesToDict(Application.getApp().getProperty("myZones_prop"));
    power_array_complete = false;
    power_array_next_index = 0;
    power_sum = 0;
    homealt_factor = altPower(1.0, HOMEALT);
  }

  function compute(info) {
    var avgPower = 0;
    
    if (info.currentCadence != null) {
      cadence_value = info.currentCadence;
    } else {
      cadence_value = -1;
    }

    if (info.currentPower != null) {
      avgPower = POWER_MULTIPLIER * SLOPE.interpolate(info.currentPower);

      if (PURE_POWER) {
        var PB = bikePower.getPedalPowerBalance();
        var TE = bikePower.getTorqueEffectivenessPedalSmoothness();
        if ((PB != null) and (TE != null)) {
          var PP = PB.pedalPowerPercent;
          var Er = TE.rightTorqueEffectiveness;
          var El = TE.leftTorqueEffectiveness;
          if ((chkPcnt(Er) and chkPcnt(El)) and chkPcnt(PP)) {
            avgPower = (PP/El + (100 - PP)/Er) * avgPower;
          }
        }
      }
      if (ALTPOWER) {
        avgPower = altPower(avgPower, info.altitude) / homealt_factor;
      }
    } else {
      powerValue = -1;
      return;
    }

    power_sum -= power_array[power_array_next_index];
    power_array[power_array_next_index] = avgPower;
    power_sum += avgPower;
    ++power_array_next_index;
    if (power_array_next_index == DURATION) {
      power_array_next_index = 0;
      power_array_complete = true;
    }

    var watts = power_sum / (power_array_complete ? DURATION : power_array_next_index);
    powerValue = Math.round(watts).toNumber();
    
    if (my_zones.size() > 0 && dc_height != null) {
      AddPowerToChart(powerValue, ColorMyZone(getPowerZone(powerValue)));
    }
  }

  function onLayout(dc) {
    var setting = System.getDeviceSettings();
    if (setting.screenShape == System.SCREEN_SHAPE_ROUND ||
        setting.screenShape == System.SCREEN_SHAPE_SEMI_ROUND) {
      if (dc.getWidth() > dc.getHeight() * 2.1 &&
          getObscurityFlags() ==
              (WatchUi.DataField.OBSCURE_LEFT | WatchUi.DataField.OBSCURE_RIGHT)) {
        // Wide middle field from the 3A layout.
        setLayout(Rez.Layouts.PowerFieldWideWatchLayout(dc));
      } else {
        //Sys.println("PowerFieldWatchLayout");
        setLayout(Rez.Layouts.PowerFieldWatchLayout(dc));
      }
    } else {
      // Narrow fields are 1/5 or 1/4 of the screen height, wide fields are 1/3 or taller.
      if (dc.getHeight() * 3.5 > setting.screenHeight) {
        setLayout(Rez.Layouts.PowerFieldEdgeChartLayout(dc));
      } else {
        setLayout(Rez.Layouts.PowerFieldEdgeLayout(dc));
      }
    }
    dc_height = dc.getHeight();
  }

  function onUpdate(dc) {
    View.onUpdate(dc);
    var zone_label = "";
    var bg_color = getBackgroundColor();
    var fg_color = 0xFFFFFF ^ bg_color;
    var v = Ui.View.findDrawableById("value");
    var l = Ui.View.findDrawableById("label");
    l.setColor(fg_color);
    v.setColor(fg_color);
    dc.setColor(fg_color, bg_color);
    dc.clear();
    
    var has_chart = Ui.View.findDrawableById("chart") != null;
    
    if (has_chart && my_zones.size() > 0) {
      var width = power_chart_array_complete ? CHART_WIDTH : power_chart_array_next_index;
      var usable_dc_width = dc.getWidth() - 2 * CHART_MARGIN;
      var to_draw = min(width, usable_dc_width);
      
      var index = power_chart_array_next_index - to_draw;
      if (index < 0) {
        index += CHART_WIDTH;
      }
      var current_x = dc.getWidth() - CHART_MARGIN - to_draw;
      var previous_color = null; 
      for (var i = 0; i < to_draw; ++i, ++index, ++current_x) {
        // Sys.println("drawing line. " + i);
        if (index >= CHART_WIDTH) {
          index -= CHART_WIDTH;
        }
        if (previous_color != power_chart_color_array[index]) {
          dc.setColor(power_chart_color_array[index], bg_color);
          previous_color = power_chart_color_array[index];
        }
        dc.drawLine(
            current_x, dc_height, current_x,
            dc_height - min(power_chart_array[index], dc_height));
      }
    }
    
    var c = Ui.View.findDrawableById("cadence");
    if (c != null) {
      c.setColor(fg_color);
      // Cadence.
      if (cadence_value < 0) {
        c.setText("-");
      } else {
        c.setText(cadence_value.toString());
      }
      c.draw(dc);
    }
    // Power.
    if (powerValue > -1) {
      if (ALT_FONT && has_chart && c == null) {
        dc.setColor(bg_color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(dc.getWidth() /2 , dc.getHeight()/2, font_o,
                    powerValue.toString(),
                    Gfx.TEXT_JUSTIFY_CENTER | Gfx.TEXT_JUSTIFY_VCENTER);

        dc.setColor(fg_color, Graphics.COLOR_TRANSPARENT);
        dc.drawText(dc.getWidth() /2 , dc.getHeight()/2, font2_o,
                    powerValue.toString(),
                    Gfx.TEXT_JUSTIFY_CENTER | Gfx.TEXT_JUSTIFY_VCENTER);
      } else {
        v.setText(powerValue.toString());
        v.draw(dc);
      }
    } else {
      v.setText("-");
      v.draw(dc);
    }
    l.setText(label + zone_label);
    l.draw(dc);
  }
}
