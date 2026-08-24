// One category. Everything the page shows is read from and written to `upkeep config` (Task W4),
// so the plasmoid keeps no settings of its own - a value the widget cached would drift the moment
// the same box was configured from the CLI.
// `source` resolves against contents/ui/.
import org.kde.plasma.configuration

ConfigModel {
    ConfigCategory {
        name: i18n("General")
        icon: "configure"
        source: "configGeneral.qml"
    }
}
