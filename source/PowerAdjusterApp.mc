using Toybox.Application as App;

class PowerAdjuster extends App.AppBase {
    function initialize() {
        AppBase.initialize();
    }

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
