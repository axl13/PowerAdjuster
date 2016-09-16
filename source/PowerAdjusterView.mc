using Toybox.WatchUi as Ui;
using Toybox.System as Sys;
using Toybox.Math as Math;

class DataField extends Ui.SimpleDataField {
	const POWER_MULTIPLIER = Application.getApp().getProperty("multiplier");
	const DURATION = Application.getApp().getProperty("duration");
	var power_array = new [DURATION];
	// Constructor
	function initialize() {
		label = "adjPwr. " + DURATION.toString() +"s";
		for( var i = 0; i < DURATION; i += 1 ) {
			power_array[i] = 0;
		}
	}

	// Handle the update event
	function compute(info) {
		var a_power = 0;
		var t_power = 0;

		if(info.currentPower != null) {
			a_power = info.currentPower * POWER_MULTIPLIER;
		}
		for( var i = 0; i < DURATION - 1; i += 1 ) {
			t_power += power_array[i];
			power_array[i] = power_array[i+1];
		}
		power_array[DURATION-1] = a_power;

		return (Math.round(t_power+a_power)/DURATION).toNumber();
	}
}
