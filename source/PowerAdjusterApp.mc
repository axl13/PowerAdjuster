using Toybox.Application as App;
using Toybox.WatchUi as Ui;


class PowerAdjuster extends App.AppBase {
    var mView;

    function initialize() {
        AppBase.initialize();
    }

    function onStart(state) {
        return false;
    }

    function getInitialView() {
        mView = new PowerDataField();
        return [mView];
    }

    function onStop(state) {
        // Persist the acclimatization model so it survives power cycles
        if (mView != null && mView has :saveState) {
            mView.saveState();
        }
        return false;
    }

    function onSettingsChanged()
    {
        if (mView != null && mView has :onSettingsChanged) {
            mView.onSettingsChanged();
        }
        Ui.requestUpdate();
    }
}
