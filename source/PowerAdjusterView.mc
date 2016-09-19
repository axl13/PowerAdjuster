using Toybox.WatchUi as Ui;
using Toybox.System as Sys;
using Toybox.Math as Math;

function linear_interpolation(x0, y0, x1, y1, x) {
    var a = (y1 - y0) / (x1 - x0);
    var b = -a*x0 + y0;
    return a * x + b;
}

class Slope {
    var x_values = [0];
    var y_values = [0];

    function initialize(config) {
        self.SlopeToDict(config);
        self.sort();
        Sys.println(x_values.toString());
        Sys.println(y_values.toString());
        Sys.println(self.interpolate(100));
        Sys.println(self.interpolate(200));
        Sys.println(self.interpolate(300));
        Sys.println(self.interpolate(400));
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

    //192:202,286:306,333:351,388:407,616:644,1068:1079
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
        self.x_values.add(3000);
        self.y_values.add(3000);
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
    var power_array = new [DURATION];

    // Constructor
    function initialize() {
        Ui.SimpleDataField.initialize();
        label = "adjPwr. " + DURATION.toString() +"s";
        for( var i = 0; i < DURATION; i += 1 ) {
            power_array[i] = 0;
        }
    }

    function compute(info) {
        var a_power = 0;
        var t_power = 0;

        if(info.currentPower != null) {
            a_power = POWER_MULTIPLIER * SLOPE.interpolate(info.currentPower);
        }
        for( var i = 0; i < DURATION - 1; i += 1 ) {
            t_power += power_array[i];
            power_array[i] = power_array[i+1];
        }
        power_array[DURATION-1] = a_power;

        return ((Math.round(t_power+a_power)/DURATION).toNumber());
    }
}
