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

class PowerDataField extends Ui.DataField {
  const POWER_MULTIPLIER = Application.getApp().getProperty("multiplier").toFloat();
  const DURATION = Application.getApp().getProperty("duration").toNumber();
  const SLOPE = new Slope(Application.getApp().getProperty("slope"));
  const ALTPOWER = Application.getApp().getProperty("altPower_prop");
  const PURE_POWER = Application.getApp().getProperty("purePower_prop");
  const HOMEALT = Application.getApp().getProperty("homeElevation_prop").toNumber();
  const CHART_WIDTH = 220;
  var homealt_factor = 1;
  var dc_height = null;
  var power_chart_array = new [CHART_WIDTH];
  var power_chart_color_array = new [CHART_WIDTH];
  var power_chart_array_complete = false;
  var power_chart_array_next_index = 0;
  var chart_bitmap = null;
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
      if(power < my_zones[i]) { return i; }
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

  function whereInTheZone(zone, power) {
    if (power < 0 || my_zones.size() == 0) { return 0.0; }
    var min_power = 0;
    var max_power;
    if (zone >= my_zones.size()) {
      // Effectively the scale on this next-to-last zone will be the same as the last one.
      max_power = my_zones[my_zones.size() - 1] * 2;
      if (my_zones.size() > 1) {
        max_power = max_power - my_zones[my_zones.size() - 2];
      }
      // The max conputation above can be done only once.
    } else {
      max_power = my_zones[zone];
    }
    if (zone > 0) {
      min_power = my_zones[zone-1];
    }
    if (power > max_power) {
      return 1.0;
    }
    if (max_power - min_power == 0) {
      // Error in settings?
      return 0.0;
    }
    var ratio = (power - min_power).toFloat() / (max_power - min_power);
    if (ratio > 1.0) {
      return 1.0;
    } else {
      return ratio;
    }
  }

  // Constructor
  function initialize() {
    //Sys.println(POWER_MULTIPLIER);
    //Sys.println(Application.getApp().getProperty("slope"));
    Ui.DataField.initialize();
    font_o = Ui.loadResource(Rez.Fonts.outline_fnt);
    font2_o = Ui.loadResource(Rez.Fonts.outline2_fnt);
    if (PURE_POWER) {
      bikePowerListener = new AntPlus.BikePowerListener();
      bikePower = new AntPlus.BikePower(bikePowerListener);
    }
    label = "Pwr." + DURATION.toString() + "s " + (ALTPOWER ? "(a)" : "") + (PURE_POWER ? "(p)" : "");
    for( var i = 0; i < DURATION; i += 1 ) {
      power_array[i] = 0;
    }
    //MyZonesToDict(Application.getApp().getProperty("myZones_prop"));
    MyZonesToDict("140,190,228,250,265,303,500");
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

    if(info.currentPower != null) {
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

    //Sys.println(POWER_MULTIPLIER);
    // Sys.println("" + power_sum + "," + avgPower + "," + DURATION + "," + info.altitude);
    var watts = power_sum / (power_array_complete ? DURATION : power_array_next_index);
    //Sys.println(info.currentPower);
    //Sys.println(watts);
    //Sys.println(my_zones);
    powerValue = Math.round(watts).toNumber();
    
    if (my_zones.size() > 0 && dc_height != null) {
      AddPowerToChart(powerValue, ColorMyZone(getPowerZone(powerValue)));
    }
  }

  function onLayout(dc) {
    var setting = System.getDeviceSettings();
    if (setting.screenShape == System.SCREEN_SHAPE_ROUND || setting.screenShape == System.SCREEN_SHAPE_SEMI_ROUND) {
      if (dc.getWidth() > dc.getHeight() * 1.2) {
        //Sys.println("PowerFieldWideWatchLayout");
        setLayout(Rez.Layouts.PowerFieldWideWatchLayout(dc));
      } else {
        //Sys.println("PowerFieldWatchLayout");
        setLayout(Rez.Layouts.PowerFieldWatchLayout(dc));
      }
    } else {
      //Sys.println("PowerFieldEdgeLayout");
      setLayout(Rez.Layouts.PowerFieldEdgeLayout(dc));
    }
    dc_height = dc.getHeight();
  }

  function drawZones(dc, zone, power) {
    var color = Gfx.COLOR_LT_GRAY;
    var m = whereInTheZone(zone, power);
    var w = dc.getWidth();
    var h = dc.getHeight();
    var zone_width = 0.8 * w; // 80% of the datafield. Don't go below 50%!
    var b1 = w / 2 - m * zone_width;
    var b2 = b1 + zone_width;
    // Sys.println("z:" + zone + " p:" + power + " %" + m + " b1:" + b1 + " b2:" + b2 + " w:" + w);

    // Clip so that fillRectangle doesn't get confused.
    if (b1 < 0) { b1 = 0; }
    if (b2 > w) { b2 = w; }

    if (b1 > 0) {
      dc.setColor(ColorMyZone(zone - 1), color);
      dc.fillRectangle(0, 0, b1, h);
    }
    dc.setColor(ColorMyZone(zone), color);
    dc.fillRectangle(b1, 0, b2, h);
    if (b2 < w) {
      dc.setColor(ColorMyZone(zone + 1), color);
      dc.fillRectangle(b2, 0, w, h);
    }
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
    
    if (my_zones.size() > 0) {
      if (chart_bitmap != null) {
//      var b = chart_bitmap.getDc();
//      b.clear();
//      var power_factor = b.getHeight().toFloat() / my_zones[my_zones.size() - 1];
//      var width = power_chart_array_next_index > CHART_WIDTH ?
//                      CHART_WIDTH :
//                      power_chart_array_next_index;
//      for (var i = 0; i < width; ++i) {
//        // Sys.println("drawing line. " + i);
//        b.setColor(power_chart_color_array[i], bg_color);
//        var bar_height = (power_factor * power_chart_array[i]).toNumber();
//        
//        b.drawLine(i, 0, i, bar_height > b.getHeight() ? b.getHeight() : bar_height);
//      }
//      dc.drawBitmap(100, 0, chart_bitmap);
      } else {
        var width = power_chart_array_complete ? CHART_WIDTH : power_chart_array_next_index;
        var lowest_x = CHART_WIDTH - width + (dc.getWidth() - CHART_WIDTH) / 2;
        var index = power_chart_array_complete ? power_chart_array_next_index : 0;
        for (var i = 0; i < width; ++i, ++index) {
          // Sys.println("drawing line. " + i);
          if (index >= CHART_WIDTH) {
            index -= CHART_WIDTH;
          }
          dc.setColor(power_chart_color_array[index], bg_color);
          dc.drawLine(lowest_x + i, dc_height, lowest_x + i, dc_height - (power_chart_array[index] > dc_height ? dc_height : power_chart_array[index]));
        }
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
      //Sys.println("drawing c. " + cadence_value + ", locX " + c.locX + ", locY " + c.locY + ", width " + c.width + ", height " + c.height);
    }
    // Power.
    if (powerValue > -1) {
      if (false && my_zones.size() > 0) {
        v.setText("");
        var zone = getPowerZone(powerValue);
        var bar_height = powerValue.toFloat() / my_zones[my_zones.size() - 1];
        if (bar_height > 1) { bar_height = 1; }
        dc.setColor(ColorMyZone(zone), Graphics.COLOR_TRANSPARENT);
        dc.fillRectangle(0, 0, 100, dc.getHeight() * bar_height);
        dc.setColor(Graphics.COLOR_WHITE, Graphics.COLOR_TRANSPARENT);
        l.setColor(Gfx.COLOR_WHITE);
        //m.setColor(Gfx.COLOR_WHITE);
        zone_label = " z" + (zone+1);
        // drawZones(dc, zone, powerValue);
        var m = Ui.View.findDrawableById("mark");
        if (m != null) {
          m.setText("^");
          m.draw(dc);
        }
        dc.drawText(dc.getWidth(), dc.getHeight() / 2, font_o,
                    powerValue.toString(),
                    Gfx.TEXT_JUSTIFY_RIGHT | Gfx.TEXT_JUSTIFY_VCENTER);

        dc.setColor(Graphics.COLOR_BLACK, Graphics.COLOR_TRANSPARENT);
        dc.drawText(dc.getWidth(), dc.getHeight()/2, font2_o,
                    powerValue.toString(),
                    Gfx.TEXT_JUSTIFY_RIGHT | Gfx.TEXT_JUSTIFY_VCENTER);
      } else {
        v.setText(powerValue.toString());
        v.draw(dc);
      }
    } else {
      v.setText("-");
    }
    v.draw(dc);
    l.setText(label + zone_label);
    l.draw(dc);
  }
}
