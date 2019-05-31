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
     Gfx.COLOR_BLUE,
     Gfx.COLOR_GREEN,
     Gfx.COLOR_YELLOW,
     Gfx.COLOR_ORANGE,
     Gfx.COLOR_RED,
     Gfx.COLOR_DK_RED,
     Gfx.COLOR_PURPLE ];

function linear_interpolation(x0, y0, x1, y1, x) {
    var a = (y1 - y0).toFloat() / (x1 - x0);
    var b = -a*x0 + y0;
    return a * x + b;
}

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
        }
        finally {
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
    
 
    function interpolate(x) {
        var i = 0;
        while ((x > self.x_values[i]) && (i < self.x_values.size())) {
            i++;
        }
        if (i > 0){
            return linear_interpolation(self.x_values[i-1], self.y_values[i-1],
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
    var homealt_factor = 1;
    var power_array = new [DURATION];
    var power_array_next_index = 0;
    var power_sum = 0;
    var power_array_complete = false;
    var bikePower;
    var bikePowerListener;
    var label;
    var my_zones = [0];
    var rainbow_ratio;
    
    hidden var powerValue;
    
    function MyZonesToDict(myzones_string)  {
       var p;
       myzones_string += ",";
       //Sys.println(myzones_string);
       p = myzones_string.find(",");
       while (p != null) {
         self.my_zones.add(myzones_string.substring(0, p).toNumber());
         myzones_string = myzones_string.substring(p+1, myzones_string.length());
         p = myzones_string.find(",");
       }
       rainbow_ratio = (rainbow.size()-1)/my_zones.size();
    }
    
    function getPowerZone(power) {
      var i;
      for(i = 0; i < my_zones.size(); i++) {
        if(power < my_zones[i]) { break; }
      }
      return i;
    }
        

    function ColorMyZone(zone) {
      // Let's be flexible with number of zones.
      return rainbow[zone * rainbow_ratio];
    }
     
    // Constructor
    function initialize() {
        //Sys.println(POWER_MULTIPLIER);
        //Sys.println(Application.getApp().getProperty("slope"));
        Ui.DataField.initialize();
        bikePowerListener = new AntPlus.BikePowerListener();
        bikePower = new AntPlus.BikePower(bikePowerListener);
        label = "adjPwr. " + DURATION.toString() + "s" + (ALTPOWER ? ",a" : "") + (PURE_POWER ? ",p" : "");
        for( var i = 0; i < DURATION; i += 1 ) {
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
    }
    function onLayout(dc) {
        setLayout(Rez.Layouts.PowerFieldLayout(dc));
     }
    
    function onUpdate(dc) {
      var color =  ColorMyZone(getPowerZone(powerValue));
      View.onUpdate(dc);
      dc.setColor(color, color);
      dc.clear();
        var l = Ui.View.findDrawableById("label");
      l.setText(label);
      l.draw(dc); 
      var v = Ui.View.findDrawableById("value");
      v.setText(powerValue.toString());
      v.draw(dc);
    }
}
