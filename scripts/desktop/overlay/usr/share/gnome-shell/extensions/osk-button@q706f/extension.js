// On-screen keyboard toggle for the top panel (q706f tablet).
// GNOME only shows the keyboard when an app reports a focused text field and the last
// input came from a finger. Remote-desktop clients and XWayland apps never report one,
// and the pen does not count as touch. This button forces the keyboard on or off.
import Gio from 'gi://Gio';
import St from 'gi://St';
import Clutter from 'gi://Clutter';
import * as Main from 'resource:///org/gnome/shell/ui/main.js';
import * as PanelMenu from 'resource:///org/gnome/shell/ui/panelMenu.js';
import {Extension} from 'resource:///org/gnome/shell/extensions/extension.js';

const A11Y_SCHEMA = 'org.gnome.desktop.a11y.applications';
const A11Y_KEY = 'screen-keyboard-enabled';

export default class OskButtonExtension extends Extension {
    enable() {
        this._a11y = new Gio.Settings({schema_id: A11Y_SCHEMA});
        this._forced = false;
        this._button = new PanelMenu.Button(0.0, 'On-screen keyboard', true);
        this._button.add_child(new St.Icon({
            icon_name: 'input-keyboard-symbolic',
            style_class: 'system-status-icon',
        }));
        this._button.connect('event', (_actor, event) => {
            const type = event.type();
            if (type === Clutter.EventType.BUTTON_RELEASE ||
                type === Clutter.EventType.TOUCH_END) {
                this._toggle();
                return Clutter.EVENT_STOP;
            }
            return Clutter.EVENT_PROPAGATE;
        });
        Main.panel.addToStatusArea('q706f-osk-button', this._button, 0, 'right');
        // When the GJS OSK extension is enabled it brings its own panel button and
        // keyboard; hide this one so there are not two keyboard buttons.
        this._shell = new Gio.Settings({schema_id: 'org.gnome.shell'});
        const sync = () => {
            this._button.visible = !this._shell.get_strv('enabled-extensions')
                .includes('gjsosk@vishram1123.com');
        };
        this._shellId = this._shell.connect('changed::enabled-extensions', sync);
        sync();

        // The remote-desktop client opens a small window; maximise it (it scales its
        // content), keeping the panel and this button visible.
        this._windowCreatedId = global.display.connect('window-created', (_d, win) => {
            const check = () => {
                const cls = win.get_wm_class() ?? '';
                if (!cls.includes('freerdp'))
                    return;
                if (win.maximize.length === 0)
                    win.maximize();
                else
                    win.maximize(3);
            };
            // wm_class is not always set yet when the signal fires.
            const id = win.connect('shown', () => { win.disconnect(id); check(); });
        });
    }

    _toggle() {
        if (Main.keyboard.visible) {
            Main.keyboard.close();
            if (this._forced) {
                this._a11y.set_boolean(A11Y_KEY, false);
                this._forced = false;
            }
            return;
        }
        // The keyboard object only exists while the keyboard is enabled.
        if (!this._a11y.get_boolean(A11Y_KEY)) {
            this._a11y.set_boolean(A11Y_KEY, true);
            this._forced = true;
        }
        Main.keyboard.open(Main.layoutManager.focusIndex);
    }

    disable() {
        if (this._forced)
            this._a11y.set_boolean(A11Y_KEY, false);
        if (this._windowCreatedId) {
            global.display.disconnect(this._windowCreatedId);
            this._windowCreatedId = 0;
        }
        if (this._shellId) {
            this._shell.disconnect(this._shellId);
            this._shellId = 0;
        }
        this._shell = null;
        this._button?.destroy();
        this._button = null;
        this._a11y = null;
    }
}
