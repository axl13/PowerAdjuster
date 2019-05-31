using Toybox.Application as App;
using Toybox.WatchUi as Ui;


class PowerAdjuster extends App.AppBase {
    function initialize() {
        AppBase.initialize();
    }

    function onStart(state) {
        return false;
    }

    function getInitialView() {
        return [new PowerDataField()];
    }

    function onStop(state) {
        return false;
    }

    function onSettingsChanged()
    {
        Ui.requestUpdate();
    }
}
