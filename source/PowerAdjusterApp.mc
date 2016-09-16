//
// Copyright 2016 by Garmin Ltd. or its subsidiaries.
// Subject to Garmin SDK License Agreement and Wearables
// Application Developer Agreement.
//

using Toybox.Application as App;

class PowerAdjuster extends App.AppBase {
    function onStart(state) {
        return false;
    }

    function getInitialView() {
        return [new DataField()];
    }

    function onStop(state) {
        return false;
    }
}
