#include <KPluginFactory>
#include <KQuickConfigModule>

class ThorchHardwareKcm : public KQuickConfigModule
{
    Q_OBJECT

public:
    ThorchHardwareKcm(QObject *parent, const KPluginMetaData &metaData)
        : KQuickConfigModule(parent, metaData)
    {
        setButtons(NoAdditionalButton);
    }
};

K_PLUGIN_CLASS_WITH_JSON(ThorchHardwareKcm, "kcm_thorch_hardware.json")

#include "thorchhardwarekcm.moc"
