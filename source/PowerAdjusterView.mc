using Toybox.WatchUi as Ui;
using Toybox.System as Sys;
using Toybox.Math as Math;


function exp(x) {
  x = 1.0 + x / 256.0;
  x *= x; x *= x; x *= x; x *= x;
  x *= x; x *= x; x *= x; x *= x;
  return x;
}

function linear_interpolation(x0, y0, x1, y1, x) {
    var a = (y1 - y0).toFloat() / (x1 - x0);
    var b = -a*x0 + y0;
    return a * x + b;
}

function altPower(watts, alt) {
    var a0  = -174.1448622d;
    var a1  = 1.0899959d;
    var a2  = -0.0015119d;
    var a3  = 0.00000072674d;

    if (alt > 0) {
      // pbar [mbar]= 0.76*EXP( -alt[m] / 7000 )*1000
      var pbar = 0.76 * exp(alt / -7000.00) * 1000.00;
      // %Vo2max= a0 + a1 * pbar + a2 * pbar ^2 + a3 * pbar ^3 (with pbar in mbar)
      var vo2maxPCT = a0 + (a1 * pbar) + (a2 * Math.pow(pbar,2)) + (a3 * Math.pow(pbar,3));
      return (watts / vo2maxPCT) * 100;
    } else {
      return watts;
    }
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

        /*Sys.println(x_values.toString());
        Sys.println(y_values.toString());
        Sys.println(self.interpolate(190));
        Sys.println(self.interpolate(280));
        Sys.println(self.interpolate(330));
        Sys.println(self.interpolate(400));*/
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

class DataField extends Ui.SimpleDataField {
    const POWER_MULTIPLIER = Application.getApp().getProperty("multiplier");
    const DURATION = Application.getApp().getProperty("duration");
    const SLOPE = new Slope(Application.getApp().getProperty("slope"));
    const ALTPOWER = Application.getApp().getProperty("altPower_prop");
    const HOMEALT = Application.getApp().getProperty("homeElevation_prop");
    const HOMEALT_FACTOR = altPower(1.0, HOMEALT);
    var power_array = new [DURATION];

    // Constructor
    function initialize() {
        //Sys.println(POWER_MULTIPLIER);
        //Sys.println(Application.getApp().getProperty("slope"));
        Ui.SimpleDataField.initialize();
        label = "adjPwr. " + DURATION.toString() + "s" + (ALTPOWER ? ",alt" : "");
        for( var i = 0; i < DURATION; i += 1 ) {
            power_array[i] = 0;
        }
    }

    function compute(info) {
        var avgPower = 0;
        var tmpPower = 0;

        if(info.currentPower != null) {
            avgPower = POWER_MULTIPLIER * SLOPE.interpolate(info.currentPower);
        }
        for( var i = 0; i < DURATION - 1; i += 1 ) {
            tmpPower += power_array[i];
            power_array[i] = power_array[i+1];
        }
        power_array[DURATION-1] = avgPower;
        //Sys.println(POWER_MULTIPLIER);
        //Sys.println((tmpPower+avgPower)/DURATION);
        var watts = (tmpPower+avgPower)/DURATION;
        //Sys.println(info.currentPower);
        //Sys.println(watts);
        if (ALTPOWER) {
          watts = altPower(watts, info.altitude) / HOMEALT_FACTOR;
          //Sys.println(watts);
          //Sys.println(info.altitude);
        }
        return Math.round(watts).toNumber();
    }
}
